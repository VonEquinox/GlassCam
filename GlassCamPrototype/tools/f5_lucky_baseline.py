"""Reproducible, desktop-only denoised Lucky controls from retained native RAW.

BM3D sees only the selected frame. Denoising strengths are declared before any
fusion comparison; no reference, averaged burst or F5 output enters denoising.
"""
from pathlib import Path
import argparse
import importlib.metadata
import json
import time

import bm3d
import numpy as np
from scipy import ndimage as ndi
from colour_demosaicing import demosaicing_CFA_Bayer_Malvar2004

from f5_real_quality import dump, gain, load, preview, raw, sha


def anscombe(signal, a, b):
    return 2 * np.sqrt(np.maximum(signal / a + 3 / 8 + b / (a * a), 0))


def inverse_anscombe(stabilized, a, b):
    # Algebraic approximation to the unbiased inverse of the expectation,
    # rather than squaring a denoised value and subtracting 3/8.
    d = np.maximum(stabilized, 1)
    value = (d*d/4 - 1/8 - b/(a*a) + np.sqrt(3/2)/(4*d)
             - 11/(8*d*d) + 5*np.sqrt(3/2)/(8*d*d*d))
    return np.maximum(0, a * value)


def demosaic(signal, frame, origin):
    camera = demosaicing_CFA_Bayer_Malvar2004(signal, "BGGR")
    y, x = np.mgrid[:signal.shape[0], :signal.shape[1]]
    return (camera * gain(frame, x + origin[0] + .5, y + origin[1] + .5)[..., None]).astype(np.float32)


def upsample(image, scale=2):
    y, x = np.mgrid[:image.shape[0]*scale, :image.shape[1]*scale]
    return np.stack([ndi.map_coordinates(image[..., c], [(y+.5)/scale-.5, (x+.5)/scale-.5],
                     order=1, mode="nearest") for c in range(3)], axis=-1)


def create(args):
    preparation = json.loads(args.preparation.read_text())
    bundle = Path(preparation["bundle"])
    _, frames = load(bundle)
    index = preparation["lucky_index"]
    frame = frames[index]
    for blob in (frame["mosaic"], frame["dng"]):
        if sha(bundle/blob["path"]) != blob["sha256"]:
            raise ValueError("Lucky input hash changed")
    if frame["metadata"]["cfa"] != [3, 1, 2, 0]:
        raise ValueError("This baseline requires the audited BGGR layout")
    _, signal, _ = raw(bundle, frame, preparation["native_to_dng_divisor"])
    a, b = frame["metadata"]["noiseProfile"]
    matrix = np.array(preparation["matrix_camera_to_linear_srgb"])
    args.output.mkdir(parents=True, exist_ok=True)
    profile = bm3d.BM3DProfile()
    profile.num_threads = args.threads
    report = dict(revision="f5-lucky-bm3d-v1", synthetic=False, camera_used=False,
                  selected_frame=index, native_sha256=frame["mosaic"]["sha256"],
                  preparation_sha256=sha(args.preparation), bm3d_version=importlib.metadata.version("bm3d"),
                  method="generalized Anscombe, per-CFA-plane BM3D HT+Wiener, approximate unbiased inverse, Malvar demosaic, DNG gain map",
                  noise_source="DNG NoiseProfile; estimated, not independently calibrated", noise_profile=[a, b],
                  context_margin_native_pixels=args.margin, strengths=args.strengths,
                  postprocess="linear camera RGB; identical matrix/exposure/sRGB preview; common 2x bilinear enlargement",
                  results=[], qualification="UNQUALIFIED_REAL_IMAGE_DIAGNOSTIC")
    for roi in preparation["rois"]:
        if args.roi and roi["name"] != args.roi:
            continue
        size = args.size
        x, y = roi["x"], roi["y"]
        left, top = max(0, x-args.margin)//2*2, max(0, y-args.margin)//2*2
        right, bottom = min(signal.shape[1], x+size+args.margin)//2*2, min(signal.shape[0], y+size+args.margin)//2*2
        if right < x+size or bottom < y+size:
            raise ValueError("ROI leaves the original sensor image")
        patch = signal[top:bottom, left:right].astype(np.float64)
        crop = np.s_[y-top:y-top+size, x-left:x-left+size]
        unfiltered = demosaic(patch, frame, (left, top))[crop]
        for strength in args.strengths:
            begin = time.monotonic()
            filtered = patch.copy()
            for py in range(2):
                for px in range(2):
                    plane = patch[py::2, px::2]
                    stabilized = anscombe(plane, a, b)
                    # BM3D's numerical range is kept near 0..1; its sigma is
                    # scaled by exactly the same deterministic factor.
                    normalization = max(1, float(np.max(stabilized)))
                    denoised = bm3d.bm3d(stabilized/normalization, strength/normalization, profile=profile)
                    filtered[py::2, px::2] = inverse_anscombe(denoised*normalization, a, b)
            native = demosaic(filtered, frame, (left, top))[crop]
            tag = f"{roi['name']}-lucky-bm3d-{strength:g}-{size}"
            path = args.output/(tag+".npy")
            np.save(path, native)
            preview(upsample(native), matrix, args.output/(tag+".png"), maximum=size*2)
            # Retain a mild, fixed sharpening alternative as a separate
            # competitor, so a softer Lucky render cannot make F5 win by blur.
            sharpened = native + .35*(native-ndi.gaussian_filter(native, (.6, .6, 0)))
            sharp_path = args.output/(tag+"-sharpened.npy")
            np.save(sharp_path, sharpened)
            preview(upsample(sharpened), matrix, sharp_path.with_suffix(".png"), maximum=size*2)
            report["results"].append(dict(roi=roi["name"], strength=strength, size=size,
                native_rgb=path.name, sha256=sha(path), sharpened_rgb=sharp_path.name,
                sharpened_sha256=sha(sharp_path), seconds=time.monotonic()-begin,
                context_origin=[left, top], context_size=[right-left, bottom-top]))
            dump(args.output/"lucky-baselines.json", report)
            print(roi["name"], strength, round(time.monotonic()-begin, 2), "s", flush=True)
        np.save(args.output/f"{roi['name']}-lucky-unfiltered-{size}.npy", unfiltered)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preparation", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--size", type=int, default=64)
    parser.add_argument("--margin", type=int, default=128)
    parser.add_argument("--strengths", type=float, nargs="+", default=[.75, 1, 1.25])
    parser.add_argument("--roi")
    parser.add_argument("--threads", type=int, default=2)
    create(parser.parse_args())
