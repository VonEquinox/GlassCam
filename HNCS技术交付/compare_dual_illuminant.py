"""Verify eight experimental exports and compare them with the adaptive version."""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageCms
import hncs_pipeline as h
import hncs_dual_illuminant as d


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir",type=Path,default=d.CASE/"output")
    parser.add_argument("--previous-dir",type=Path,default=h.ROOT/"work/hncs-adaptive-2026-10-03")
    args=parser.parse_args()
    reports=json.loads((args.output_dir/"batch_verification.json").read_text())
    records=[];tiles=[]
    assets=h.load_assets()
    for entry in reports:
        folder=Path(entry["output"]);stem=folder.name;old=args.previous_dir/stem
        run=json.loads((folder/f"{stem}_hncs.json").read_text())
        prior=json.loads((old/f"{stem}_hncs.json").read_text())
        assert run["experimental_dual_illuminant"] and run["illuminant_mode"]=="dual"
        assert run["dual_model_sha256"]==h.digest(d.MODEL)
        assert entry["verification"]["dng_cfa_samples_identical"]
        assert h.digest(Path(entry["source"]))==entry["verification"]["source_sha256"]
        neutral_error=float(np.max(abs(np.array(run["matrix"])@np.ones(3)-1)))
        assert neutral_error<1e-12
        for suffix in ("hncs","original"):
            with Image.open(folder/f"{stem}_{suffix}.jpg") as image:
                assert image.size==tuple(entry["verification"]["jpeg_shape"][1::-1])
                assert image.info.get("icc_profile");image.verify()
        master_check=h.validate_output(folder/f"{stem}_hncs.tif",assets)
        srgb_check=h.validate_output(folder/f"{stem}_hncs_srgb.tif",assets,"srgb")
        new_codes=h.tifffile.memmap(folder/f"{stem}_hncs_srgb.tif",mode="r")
        old_codes=h.tifffile.memmap(old/f"{stem}_hncs_srgb.tif",mode="r")
        assert new_codes.shape==old_codes.shape
        total=0;maximum=0;changed=0
        for start in range(0,len(new_codes),96):
            difference=np.abs(new_codes[start:start+96].astype(np.int32)-old_codes[start:start+96].astype(np.int32))
            total+=int(difference.sum());maximum=max(maximum,int(difference.max()));changed+=int(np.count_nonzero(difference))
        new_normal=h.tifffile.memmap(folder/f"{stem}_original_srgb.tif",mode="r")
        old_normal=h.tifffile.memmap(old/f"{stem}_original_srgb.tif",mode="r")
        assert new_normal.shape==old_normal.shape
        for start in range(0,len(new_normal),96):
            assert np.array_equal(new_normal[start:start+96],old_normal[start:start+96])
        records.append({"photo":stem,"previous_factory_cct":prior["cct"],"dual_factory_cct":run["cct"],
            "estimated_source_cct":run["source_estimated_cct"],
            "sony_A_weight":run["source_low_illuminant_weight"],"hasselblad_A_weight":run["target_low_illuminant_weight"],
            "sony_range_clamped":run["source_profile_range_clamped"],"hasselblad_range_clamped":run["target_profile_range_clamped"],
            "source_unchanged":True,"dng_cfa_identical":True,"normal_srgb_all_pixels_identical":True,
            "neutral_matrix_error":neutral_error,"master_tiff":master_check,"srgb_tiff":srgb_check,
            "old_vs_new_mean_uint16_difference":total/new_codes.size,"old_vs_new_max_uint16_difference":maximum,
            "old_vs_new_changed_channel_samples":changed,"clipping":run["clipping"],
            "interpretation":"Differences between two model renderings; not accuracy against physical X2D II ground truth"})
        images=[]
        for base in (old,folder):
            with Image.open(base/f"{stem}_hncs_display.preview.jpg") as image:thumbnail=image.copy()
            thumbnail.thumbnail((600,680));images.append(thumbnail)
        tile=Image.new("RGB",(1200,max(im.height for im in images)+48),"#eeeeee")
        draw=ImageDraw.Draw(tile)
        draw.text((12,12),f"{stem} | previous adaptive {prior['cct']} K",fill="black")
        draw.text((612,12),f"Dual experiment {run['cct']} K",fill="black")
        for i,image in enumerate(images):tile.paste(image,(i*600+(600-image.width)//2,44))
        tiles.append(tile)
        print(stem,": factory",prior["cct"],"->",run["cct"],"K; original all pixels unchanged",flush=True)
    row_heights=[max(t.height for t in tiles[i:i+2])+12 for i in range(0,len(tiles),2)]
    sheet=Image.new("RGB",(2400,sum(row_heights)),"#eeeeee")
    for i,tile in enumerate(tiles):sheet.paste(tile,((i%2)*1200,sum(row_heights[:i//2])))
    sheet.save(args.output_dir/"adaptive_vs_dual.jpg",quality=95,
               icc_profile=ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes())
    h.save_json(d.CASE/"output_verification.json",{"photos":records,"count":len(records)})


if __name__=="__main__":main()
