"""Verify the CFA patch-fit scale against the actual linear RAW demosaic."""
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import hncs_pipeline as pipeline


def main():
    profile = json.loads(pipeline.PROFILE.read_text())
    records = []
    for key in ("source", "target"):
        meta = profile[key]
        image, decoded_meta = pipeline.demosaic(meta["path"], meta["model"])
        if tuple(image.shape[:2]) != tuple(meta["visible_shape"]):
            raise ValueError("Demosaic crop differs from visible CFA coordinate space")
        region = profile["chart_config"]["sony" if key == "source" else "hasselblad"]
        polygons = pipeline.patch_polygons(region["corners"],region["roi_fraction"])
        height, width = image.shape[:2]
        medians = []
        for poly in polygons:
            xy = poly * [width,height]
            x0,y0 = np.ceil(xy.min(axis=0)).astype(int)
            x1,y1 = np.floor(xy.max(axis=0)).astype(int)
            # Shrink further to suppress AHD edge effects; the fixed ROIs are rectangles.
            medians.append(np.median(image[y0+2:y1-2,x0+2:x1-2],axis=(0,1))/65535)
        expected = np.array([p[key+"_native"] for p in profile["patches"]])
        ratio = np.array(medians)/expected
        records.append({"camera":meta["model"],"shape":list(image.shape),
                        "median_scale_ratio":np.median(ratio,axis=0).tolist(),
                        "demosaic_medians":np.array(medians).tolist(),
                        "cfa_medians":expected.tolist(),
                        "maximum_absolute_response_difference":float(np.max(np.abs(medians-expected)))})
        print(records[-1],flush=True)
        pipeline.save_json(pipeline.WORK/"evidence/raw_normalisation.json",records)
        if not np.all(np.abs(np.median(ratio,axis=0)-1)<.005):
            raise ValueError("CFA sampling and linear demosaic scales disagree by >0.5%")
        del image
    pipeline.save_json(pipeline.WORK/"evidence/raw_normalisation.json",records)


if __name__ == "__main__":main()
