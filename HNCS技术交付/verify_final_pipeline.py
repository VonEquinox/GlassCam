"""Verify final photo files and build previous/paired comparison artifacts."""
import json
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageCms
import hncs_pipeline as h
import hncs_paired_illuminants as p

CASE=h.ROOT/"work/hncs-finalization"


def main():
    output=CASE/"output";reports=json.loads((output/"batch_verification.json").read_text())
    if len(reports)!=8:raise ValueError("Expected eight final photo outputs")
    assets=h.load_assets();records=[];tiles=[]
    for entry in reports:
        folder=Path(entry["output"]);stem=folder.name;old=h.ROOT/"work/hncs-adaptive-2026-10-03"/stem
        record=json.loads((folder/"verification.json").read_text())
        run=json.loads((folder/f"{stem}_hncs.json").read_text())
        assert run["illuminant_mode"]=="paired" and run["paired_model_sha256"]==h.digest(p.MODEL)
        assert record["dng_full_cfa_samples_identical"] and record["dng_cfa_samples_identical"]
        assert h.digest(Path(entry["source"]))==record["source_sha256"]
        orientation=run["input"]["orientation"]
        master=h.validate_output(folder/f"{stem}_hncs.tif",assets)
        srgb=h.validate_output(folder/f"{stem}_hncs_srgb.tif",assets,"srgb")
        assert master["orientation"]==orientation and srgb["orientation"]==orientation
        for suffix in ("hncs","original"):
            with Image.open(folder/f"{stem}_{suffix}.jpg") as im:
                assert im.size==tuple(record["jpeg_shape"][1::-1]);assert im.info.get("icc_profile");im.verify()
        with h.tifffile.TiffFile(folder/f"{stem}_original.dng") as tif:
            assert tif.pages[0].tags[50708].value=="Sony ILCE-7RM5"
            assert tif.pages[0].tags[274].value==orientation
        new_original=h.tifffile.memmap(folder/f"{stem}_original_srgb.tif",mode="r")
        old_original=h.tifffile.memmap(old/f"{stem}_original_srgb.tif",mode="r")
        maximum=0;total=0
        for start in range(0,len(new_original),96):
            difference=np.abs(new_original[start:start+96].astype(np.int32)-old_original[start:start+96].astype(np.int32))
            maximum=max(maximum,int(difference.max()));total+=int(difference.sum())
        records.append({"photo":stem,"cct":run["cct"],"source_estimated_cct":run["source_estimated_cct"],
            "warm_weight":run["paired_warm_weight"],"paired_range_clamped":run["paired_range_clamped"],
            "source_unchanged":True,"full_cfa_identical":True,"master":master,"srgb":srgb,
            "original_render_vs_previous_max_uint16_difference":maximum,
            "original_render_vs_previous_mean_uint16_difference":total/new_original.size})
        thumbnails=[]
        for base in (old,folder):
            with Image.open(base/f"{stem}_hncs_display.preview.jpg") as im:thumb=im.copy()
            thumb.thumbnail((600,680));thumbnails.append(thumb)
        tile=Image.new("RGB",(1200,max(im.height for im in thumbnails)+48),"#eeeeee");draw=ImageDraw.Draw(tile)
        draw.text((12,12),stem+" | previous adaptive",fill="black")
        draw.text((612,12),f"Final paired | {run['cct']} K",fill="black")
        for i,im in enumerate(thumbnails):tile.paste(im,(i*600+(600-im.width)//2,44))
        tiles.append(tile)
        print(stem,run["cct"],"K; CFA/ICC/orientation checked",flush=True)
    heights=[max(t.height for t in tiles[i:i+2])+12 for i in range(0,len(tiles),2)]
    sheet=Image.new("RGB",(2400,sum(heights)),"#eeeeee")
    for i,tile in enumerate(tiles):sheet.paste(tile,((i%2)*1200,sum(heights[:i//2])))
    sheet.save(output/"previous_vs_final.jpg",quality=95,
               icc_profile=ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes())
    h.save_json(CASE/"evidence/final_output_verification.json",{"count":len(records),"photos":records})


if __name__=="__main__":main()
