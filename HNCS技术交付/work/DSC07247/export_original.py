"""Preserve Sony CFA samples in DNG, then develop the DNG and export JPEGs."""
from pathlib import Path
import hashlib
import json
import numpy as np
import rawpy
import tifffile
from PIL import Image, ImageCms, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
SOURCE = ROOT / "DSC07247.ARW"
DNG = OUT / "DSC07247_original.dng"
ICC = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()

def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1048576), b""):
            h.update(block)
    return h.hexdigest()

def develop(path):
    with rawpy.imread(str(path)) as raw:
        whites = raw.camera_white_level_per_channel
        saturation = min(v for v in whites if v > 0) if whites else raw.white_level
        return raw.postprocess(use_camera_wb=True, use_auto_wb=False,
            no_auto_bright=True, output_color=rawpy.ColorSpace.sRGB,
            output_bps=16, gamma=(2.4, 12.92), bright=1,
            demosaic_algorithm=rawpy.DemosaicAlgorithm.AHD,
            adjust_maximum_thr=0, user_sat=int(saturation-max(raw.black_level_per_channel)),
            fbdd_noise_reduction=rawpy.FBDDNoiseReductionMode.Off,
            median_filter_passes=0)

def jpeg(image, path):
    Image.fromarray(np.uint8((image.astype(np.uint32)+128)//257)).save(
        path, quality=98, subsampling=0, icc_profile=ICC)

def main():
    original_hash = sha(SOURCE)
    with tifffile.TiffFile(SOURCE) as t:
        original_tags = t.pages[0].tags
        make = str(original_tags[271].value)
        model = str(original_tags[272].value)
        date = original_tags.get(306)
        date = str(date.value) if date else None
    with rawpy.imread(str(SOURCE)) as raw:
        sizes = raw.sizes
        samples = raw.raw_image.copy()
        visible = raw.raw_image_visible.copy()
        matrix = raw.rgb_xyz_matrix[:3].astype(float)
        wb = np.array(raw.camera_whitebalance[:3], dtype=float)
        neutral = wb[1]/wb
        # DNG ColorMatrix converts XYZ to camera RGB (LibRaw cam_xyz).
        matrix_pairs = tuple(x for v in matrix.flat for x in (int(round(v*1000000)), 1000000))
        neutral_pairs = tuple(x for v in neutral for x in (int(round(v*100000000)), 100000000))
        orientation = {0:1, 3:3, 5:8, 6:6}[sizes.flip]
        # The Sony green channels 1 and 3 represent the same CFA colour.
        pattern = tuple(1 if v == 3 else int(v) for v in raw.raw_colors[:2,:2].flat)
        black = tuple(int(raw.black_level_per_channel[v]) for v in raw.raw_colors[:2,:2].flat)
        whites = raw.camera_white_level_per_channel
        saturation = min(v for v in whites if v > 0) if whites else raw.white_level
        active = (sizes.top_margin, sizes.left_margin,
                  sizes.top_margin+sizes.height, sizes.left_margin+sizes.width)
        tags = [(254,"I",1,0,False), (271,"s",0,make,False),
            (272,"s",0,model,False), (274,"H",1,orientation,False),
            (33421,"H",2,(2,2),False), (33422,"B",4,pattern,False),
            (50706,"B",4,(1,4,0,0),False), (50707,"B",4,(1,1,0,0),False),
            (50708,"s",0,model,False), (50710,"B",3,(0,1,2),False),
            (50711,"H",1,1,False), (50713,"H",2,(2,2),False),
            (50714,"I",4,black,False), (50717,"I",1,int(saturation),False),
            (50718,"2I",2,(1,1,1,1),False),
            (50719,"I",2,(sizes.crop_left_margin, sizes.crop_top_margin),False),
            (50720,"I",2,(sizes.crop_width,sizes.crop_height),False),
            (50721,"2i",9,matrix_pairs,False), (50728,"2I",3,neutral_pairs,False),
            (50730,"2i",1,(0,1),False), (50778,"H",1,21,False),
            (50827,"s",0,SOURCE.name,False), (50829,"I",4,active,False)]
        if date:
            tags.append((306,"s",0,date,False))
        tifffile.imwrite(DNG, samples, photometric=32803, metadata=None,
            compression=None, extratags=tags,
            software="HNCS project CFA-preserving DNG export")
    del samples
    with rawpy.imread(str(DNG)) as dng:
        assert np.array_equal(dng.raw_image_visible, visible), "DNG changed CFA samples"
        assert dng.sizes.flip == sizes.flip
        dng_wb = np.array(dng.camera_whitebalance[:3], dtype=float)
        wb_error = float(np.max(np.abs(dng_wb/dng_wb[1]-wb/wb[1])))
        assert wb_error < 1e-6
        assert np.max(np.abs(dng.rgb_xyz_matrix[:3]-matrix)) < 1e-6
    del visible
    print("DNG re-opened: CFA samples identical, WB and matrix preserved", flush=True)
    normal = develop(DNG)
    original = develop(SOURCE)
    rgb_error = int(np.max(np.abs(normal.astype(np.int32)-original.astype(np.int32))))
    differences = np.abs(normal.astype(np.int32)-original.astype(np.int32))
    rgb_mean = float(differences.mean())
    rgb_p99 = float(np.percentile(differences,99))
    del differences
    jpeg(normal, OUT / "DSC07247_original.jpg")
    tifffile.imwrite(OUT / "DSC07247_original_srgb.tif", normal, photometric="rgb",
        metadata=None, extratags=[(34675,"B",len(ICC),ICC,False)])
    small = Image.fromarray(np.uint8((normal.astype(np.uint32)+128)//257))
    small.thumbnail((1800,1800))
    small.save(OUT / "DSC07247_original.preview.jpg", quality=95, icc_profile=ICC)
    del normal, original
    hncs = tifffile.memmap(OUT / "DSC07247_hncs_srgb.tif", mode="r")
    # Pipeline master is in sensor orientation; JPEG follows capture orientation.
    oriented = np.rot90(hncs, 1) if orientation == 8 else (
        np.rot90(hncs, 3) if orientation == 6 else np.rot90(hncs, 2) if orientation == 3 else hncs)
    jpeg(oriented, OUT / "DSC07247_hncs.jpg")
    left = Image.open(OUT / "DSC07247_original.preview.jpg")
    right = Image.open(OUT / "DSC07247_hncs.preview.jpg")
    if orientation == 8: right = right.transpose(Image.Transpose.ROTATE_90)
    elif orientation == 6: right = right.transpose(Image.Transpose.ROTATE_270)
    elif orientation == 3: right = right.transpose(Image.Transpose.ROTATE_180)
    right.save(OUT / "DSC07247_hncs_display.preview.jpg", quality=95, icc_profile=ICC)
    left.thumbnail((900,1200)); right.thumbnail((900,1200))
    canvas = Image.new("RGB", (left.width+right.width, max(left.height,right.height)+40), "white")
    canvas.paste(left,(0,40)); canvas.paste(right,(left.width,40))
    draw = ImageDraw.Draw(canvas)
    draw.text((15,12),"Original: DNG -> sRGB",fill="black")
    draw.text((left.width+15,12),"HNCS pipeline -> sRGB",fill="black")
    canvas.save(OUT / "DSC07247_comparison.jpg", quality=95, icc_profile=ICC)
    assert sha(SOURCE) == original_hash
    report = {"source_sha256":original_hash,"dng_cfa_samples_identical":True,
        "dng_white_balance_relative_max_error":wb_error,
        "original_arw_vs_dng_srgb_uint16_max_difference":rgb_error,
        "original_arw_vs_dng_srgb_uint16_mean_difference":rgb_mean,
        "original_arw_vs_dng_srgb_uint16_p99_difference":rgb_p99,
        "jpeg_shape":list(oriented.shape), "orientation":orientation,
        "dng_white_level":int(saturation), "arw_container_white_level":16383,
        "normal_render":"LibRaw AHD, capture WB, camera matrix, sRGB transfer, no automatic brightening",
        "dng":"Uncompressed original CFA samples, active area, black/white levels, capture WB, D65 camera matrix; not an Adobe Converter export; proprietary Sony MakerNotes are not migrated",
        "hncs":"Existing calibrated pipeline; source capture WB; other-scene factory CCT remains calibration default; full Phocus equivalence unverified",
        "files":{p.name:{"bytes":p.stat().st_size,"sha256":sha(p)} for p in sorted(OUT.iterdir()) if p.is_file() and p.suffix.lower() in (".dng",".jpg",".tif")}}
    (OUT / "verification.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report,indent=2), flush=True)

if __name__ == "__main__":
    main()
