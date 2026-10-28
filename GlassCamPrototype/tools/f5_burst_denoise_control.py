"""Static-scene information control for the same retained five-frame budget.

This is an explicitly separate computational experiment, not a production F5
render or an external implementation such as Google's burst SR. It tests whether
the available main frames can improve the noise/detail frontier before changing
the reconstruction prior. Moving regions require the production rejection model.
"""
from pathlib import Path
import argparse
import json
import time

import bm3d
import numpy as np
from scipy import ndimage as ndi

from f5_lucky_baseline import anscombe, inverse_anscombe, demosaic, upsample
from f5_real_quality import dump, gain, load, preview, raw, sha


def run(args):
    preparation = json.loads(args.preparation.read_text())
    bundle = Path(preparation["bundle"])
    _, frames = load(bundle)
    selected = preparation["used_frames"]
    reference = frames[preparation["lucky_index"]]
    shifts = {f["index"]: f["translation_native_xy"] for f in preparation["alignment"]}
    images = {}
    for i in selected:
        f = frames[i]
        for blob in (f["mosaic"], f["dng"]):
            if sha(bundle/blob["path"]) != blob["sha256"]:
                raise ValueError("Original burst bytes changed")
        if f["metadata"]["cfa"] != reference["metadata"]["cfa"]:
            raise ValueError("Different CFA layouts need explicit phase handling")
        images[i] = raw(bundle, f, preparation["native_to_dng_divisor"])[1]
    args.output.mkdir(parents=True, exist_ok=True)
    matrix = np.array(preparation["matrix_camera_to_linear_srgb"])
    profile = bm3d.BM3DProfile()
    profile.num_threads = 2
    report = dict(revision="f5-static-burst-denoising-control-v1", synthetic=False,
                  production_f5_output=False, qualification="UNQUALIFIED_DIAGNOSTIC",
                  preparation_sha256=sha(args.preparation), used_frames=selected,
                  excluded_frames=preparation["excluded_frames"], extra_frames=0,
                  method="CFA-plane registration, equal-weight main-frame radiance mean, GAT/BM3D, Malvar demosaic, reference gain map",
                  limitations=["No local motion/occlusion rejection; static-scene information control only.",
                               "NoiseProfile is uncalibrated; gain variation uses a local average noise approximation.",
                               "Bilinear registration introduces short-range noise correlations; scalar BM3D noise is approximate."],
                  results=[])
    for roi in preparation["rois"]:
        if args.roi and roi["name"] != args.roi:
            continue
        begin = time.monotonic()
        x, y, size = roi["x"], roi["y"], args.size
        height, width = images[selected[0]].shape
        left, top = max(0, x-128)//2*2, max(0, y-128)//2*2
        right, bottom = min(width, x+size+128)//2*2, min(height, y+size+128)//2*2
        fused = np.empty((bottom-top, right-left), np.float64)
        noise_parameters = []
        for py in range(2):
            for px in range(2):
                yy, xx = np.mgrid[top+py:bottom:2, left+px:right:2]
                reference_gain = gain(reference, xx+.5, yy+.5)
                total = np.zeros(xx.shape)
                noise_a, noise_b = 0.0, 0.0
                for i in selected:
                    frame = frames[i]
                    dx, dy = shifts[i]
                    sx, sy = (xx-px-dx)/2, (yy-py-dy)/2
                    plane = images[i][py::2, px::2]
                    values = ndi.map_coordinates(plane, [sy, sx], order=1, mode="nearest", prefilter=False)
                    exposure = frame["actualExposure"]/reference["actualExposure"]
                    radiometry = gain(frame, xx-dx+.5, yy-dy+.5)/reference_gain/exposure
                    total += values*radiometry/len(selected)
                    fx, fy = dx/2 % 1, dy/2 % 1
                    squared = ((1-fx)**2+fx**2)*((1-fy)**2+fy**2)
                    a, b = frame["metadata"]["noiseProfile"]
                    noise_a += a*float(np.mean(radiometry))*squared/len(selected)**2
                    noise_b += b*float(np.mean(radiometry**2))*squared/len(selected)**2
                transformed = anscombe(total, noise_a, noise_b)
                normalization = max(1, float(np.max(transformed)))
                result = bm3d.bm3d(transformed/normalization, args.strength/normalization, profile=profile)
                fused[py::2, px::2] = inverse_anscombe(result*normalization, noise_a, noise_b)
                noise_parameters.append([noise_a, noise_b])
        camera = demosaic(fused, reference, (left, top))[y-top:y-top+size, x-left:x-left+size]
        name = f"{roi['name']}-burst-bm3d-{args.strength:g}-{size}"
        path = args.output/(name+".npy")
        np.save(path, camera)
        preview(upsample(camera), matrix, path.with_suffix(".png"), maximum=size*2)
        report["results"].append(dict(roi=roi["name"], native_rgb=path.name, sha256=sha(path),
             noise_parameters=noise_parameters, seconds=time.monotonic()-begin))
        dump(args.output/"burst-denoising-control.json", report)
        print(roi["name"], "done", round(time.monotonic()-begin, 2), "s", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preparation", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--size", type=int, default=64)
    parser.add_argument("--roi")
    parser.add_argument("--strength", type=float, default=1)
    run(parser.parse_args())
