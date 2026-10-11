#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy==2.5.3", "scipy==1.18.1", "rawpy==0.27.1", "pillow==12.3.0", "tifffile==2026.9.20"]
# ///
"""Fit paired A7R V / X2D II RAWs and render using recovered Phocus colour data.

uv run hncs_pipeline.py run
uv run hncs_pipeline.py render --input another.ARW --output output.tif

All runtime Phocus data are bundled in work/hncs-pipeline/assets. Phocus is
only needed to re-extract these data, not to calibrate or render.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import sys
from pathlib import Path

import numpy as np
import rawpy
import tifffile
from PIL import Image, ImageDraw, ImageCms, ImageFont
from scipy.optimize import minimize_scalar

ROOT = Path(__file__).resolve().parent
WORK = ROOT / "work/hncs-pipeline"
ASSETS = WORK / "assets"
SOURCE = ROOT / "19990c35cf194481a0093de2b02ed818.arw"
TARGET = ROOT / "7fbb1471e0cf4b22858cd9a161fb83a8.3fr"
PROFILE = WORK / "a7rv_to_x2dii.json"
CHART = WORK / "chart_regions.json"
PATCH_NAMES = ["dark skin", "light skin", "blue sky", "foliage", "blue flower", "bluish green",
               "orange", "purplish blue", "moderate red", "purple", "yellow green", "orange yellow",
               "blue", "green", "red", "yellow", "magenta", "cyan",
               "white", "neutral 8", "neutral 6.5", "neutral 5", "neutral 3.5", "black"]


def save_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False, allow_nan=False) + "\n", encoding="utf-8")


def digest(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def load_assets(directory=ASSETS):
    directory = Path(directory)
    provenance = json.loads((directory / "provenance.json").read_text())
    for name, expected in provenance["files"].items():
        if digest(directory / name) != expected:
            raise ValueError(f"HNCS asset hash mismatch: {name}")
    with np.load(directory / "x2dii_phocus_422.npz", allow_pickle=False) as data:
        result = {k: data[k] for k in data.files}
    result["icc"] = (directory / "HasselbladLStarRGB.icc").read_bytes()
    result["provenance"] = provenance
    return result


def lerp_table(cct, temperatures, values, clamp=True):
    cct = float(np.clip(cct, temperatures[0], temperatures[-1])) if clamp else float(cct)
    i = int(np.clip(np.searchsorted(temperatures, cct) - 1, 0, len(temperatures) - 2))
    f = (cct - temperatures[i]) / (temperatures[i + 1] - temperatures[i])
    return values[i] * (1 - f) + values[i + 1] * f


def estimate_cct(wb, assets):
    def loss(cct):
        candidate = lerp_table(cct, assets["wb_temperatures"], assets["factory_wb"])
        return np.sum((np.log(candidate[[0, 2]]) - np.log(np.array(wb)[[0, 2]])) ** 2)
    result = minimize_scalar(loss, bounds=(float(assets["wb_temperatures"][0]),
                                           float(assets["wb_temperatures"][-1])), method="bounded")
    return float(result.x), float(result.fun)


def lookup_chroma(chroma, lut, grid):
    """Scaled2DLUT::Lookup(...,true), including coordinate and value scaling."""
    cb0, cb1, cr0, cr1, divisor = grid
    pos = np.asarray(chroma, dtype=np.float64) * divisor - np.array([cb0, cr0])
    pos = np.clip(pos, 0, np.array([cb1 - cb0, cr1 - cr0]))
    low = np.floor(pos).astype(np.intp)
    high = np.minimum(low + 1, np.array([cb1 - cb0, cr1 - cr0], dtype=np.intp))
    f = pos - low
    x0, y0, x1, y1 = low[..., 0], low[..., 1], high[..., 0], high[..., 1]
    fx, fy = f[..., :1], f[..., 1:]
    return ((lut[y0, x0] * (1 - fy) + lut[y1, x0] * fy) * (1 - fx)
            + (lut[y0, x1] * (1 - fy) + lut[y1, x1] * fy) * fx) / divisor


def kernel_matrices(cct, assets):
    camera_xyz = lerp_table(np.clip(int(cct),2000,10000), assets["matrix_temperatures"], assets["camera_to_xyz"],clamp=False)
    matrix_in = assets["rgb_to_ycbcr"] @ assets["xyz_to_legacy_rgb"] @ camera_xyz
    matrix_out = (np.linalg.inv(assets["working_rgb_to_xyz"]) @ assets["legacy_rgb_to_xyz"]
                  @ np.linalg.inv(assets["rgb_to_ycbcr"]))
    return matrix_in, matrix_out


def hncs_codes(native_wb_rgb, cct, assets, intent="standard", use_lut=True, stats=None):
    """Recovered normal CPU kernel + gradation, with its uint16 stage boundaries.

    Input: black-subtracted, normalised, white-balanced X2D II native RGB.
    Shadow desaturation is disabled; low-saturation gray weighting is enabled.
    There is no unconditional legacy 1.7 exposure multiplication.
    """
    rgb = np.asarray(native_wb_rgb, dtype=np.float64)
    if not np.all(np.isfinite(rgb)):
        raise ValueError("Non-finite native RGB input")
    if stats is not None:
        stats["native_out_of_range_samples"] += int(np.count_nonzero((rgb < 0) | (rgb > 1)))
        stats["native_samples"] += rgb.size
    pixel = np.rint(np.clip(rgb, 0, 1) * 65535)
    matrix_in, matrix_out = kernel_matrices(cct, assets)
    ycbcr = pixel @ matrix_in.T
    y = ycbcr[..., :1]
    ratios = np.divide(ycbcr[..., 1:], y, out=np.zeros_like(ycbcr[..., 1:]), where=y > 0)
    if use_lut:
        lut = lerp_table(np.clip(int(cct), 2000, 10000), assets["wb_temperatures"],
                         assets["lut_repro" if intent == "reproduction" else "lut_std"],clamp=False)
        mapped_chroma = lookup_chroma(ratios, lut, assets["grid"])
    else:
        mapped_chroma = ratios
    mean = np.mean(pixel, axis=-1, keepdims=True)
    saturation = np.divide(np.max(np.abs(pixel - mean), axis=-1, keepdims=True), mean,
                           out=np.zeros_like(mean), where=mean > 0)
    upper, lower = assets["gray_thresholds"]
    gray_weight = np.clip((saturation - lower) / (upper - lower), 0, 1)
    # The native normal kernel uses Y as the neutral baseline, then columns 1/2.
    linear_codes = y + (y * gray_weight * mapped_chroma) @ matrix_out[:, 1:].T
    linear_codes = np.where(y > 0, linear_codes, 0)
    if stats is not None:
        stats["working_out_of_range_samples"] += int(np.count_nonzero((linear_codes < 0) | (linear_codes > 65535)))
        stats["working_samples"] += linear_codes.size
    indices = np.clip(linear_codes, 0, 65535).astype(np.intp)
    curve = assets["pure_lstar" if intent == "reproduction" else "v1_lstar"]
    return curve[indices]


def lstar_decode(encoded):
    encoded = np.asarray(encoded, dtype=np.float64)
    return np.where(encoded <= .08, encoded / (24389 / 2700), ((encoded + .16) / 1.16) ** 3)


def xyz_to_lab(xyz):
    x = np.asarray(xyz) / np.array([.9642, 1., .8249])
    f = np.where(x > (6/29)**3, np.cbrt(x), x / (3 * (6/29)**2) + 4/29)
    return np.stack([116*f[..., 1]-16, 500*(f[..., 0]-f[..., 1]), 200*(f[..., 1]-f[..., 2])], axis=-1)


def delta_e_2000(lab1, lab2):
    """CIEDE2000 with kL=kC=kH=1; validated against published Sharma pairs."""
    l1, a1, b1 = np.moveaxis(np.asarray(lab1, dtype=float), -1, 0)
    l2, a2, b2 = np.moveaxis(np.asarray(lab2, dtype=float), -1, 0)
    c1, c2 = np.hypot(a1, b1), np.hypot(a2, b2)
    cbar = (c1+c2)/2
    g = .5*(1-np.sqrt(cbar**7/(cbar**7+25**7)))
    ap1, ap2 = (1+g)*a1, (1+g)*a2
    cp1, cp2 = np.hypot(ap1,b1), np.hypot(ap2,b2)
    hp1, hp2 = np.mod(np.degrees(np.arctan2(b1,ap1)),360), np.mod(np.degrees(np.arctan2(b2,ap2)),360)
    dl, dc = l2-l1, cp2-cp1
    dh = hp2-hp1
    dh = np.where(dh>180,dh-360,np.where(dh< -180,dh+360,dh))
    dh = np.where(cp1*cp2 == 0,0,dh)
    dH = 2*np.sqrt(cp1*cp2)*np.sin(np.radians(dh/2))
    lp, cp = (l1+l2)/2, (cp1+cp2)/2
    hp = np.where(cp1*cp2==0,hp1+hp2,
                  np.where(np.abs(hp1-hp2)<=180,(hp1+hp2)/2,
                           np.where(hp1+hp2<360,(hp1+hp2+360)/2,(hp1+hp2-360)/2)))
    t = 1-.17*np.cos(np.radians(hp-30))+.24*np.cos(np.radians(2*hp))+.32*np.cos(np.radians(3*hp+6))-.20*np.cos(np.radians(4*hp-63))
    sl = 1+.015*(lp-50)**2/np.sqrt(20+(lp-50)**2)
    sc, sh = 1+.045*cp, 1+.015*cp*t
    rt = -2*np.sqrt(cp**7/(cp**7+25**7))*np.sin(np.radians(60*np.exp(-((hp-275)/25)**2)))
    return np.sqrt(np.maximum(0,(dl/sl)**2+(dc/sc)**2+(dH/sh)**2+rt*(dc/sc)*(dH/sh)))


def output_lab(native_rgb, cct, assets, intent="standard"):
    encoded = hncs_codes(native_rgb, cct, assets, intent).astype(float)/65535
    return xyz_to_lab(lstar_decode(encoded) @ assets["working_rgb_to_xyz"].T)


def raw_metadata(path, raw):
    with tifffile.TiffFile(path) as tif:
        make = str(tif.pages[0].tags["Make"].value)
        model = str(tif.pages[0].tags["Model"].value)
        date_tag = tif.pages[0].tags.get("DateTime")
        date = str(date_tag.value) if date_tag else None
    return {"path": str(Path(path).resolve()), "sha256": digest(path), "make": make, "model": model,
            "date": date,
            "visible_shape": list(raw.raw_image_visible.shape),
            "cfa": raw.raw_colors_visible[:2,:2].tolist(), "black": list(raw.black_level_per_channel),
            "white": int(raw.white_level), "camera_wb": list(raw.camera_whitebalance),
            "linear_white": int(raw.white_level-max(raw.black_level_per_channel)),
            "libraw": list(rawpy.libraw_version), "rawpy": rawpy.__version__}


def homography(corners):
    corners = np.asarray(corners, dtype=float)
    if corners.shape != (4,2) or not np.isfinite(corners).all() or np.any(corners<0) or np.any(corners>1):
        raise ValueError("Chart corners must be four normalised [x,y] coordinates in TL,TR,BR,BL order")
    equations, result = [], []
    for (u,v),(x,y) in zip([(0,0),(1,0),(1,1),(0,1)],corners):
        equations.extend([[u,v,1,0,0,0,-x*u,-x*v],[0,0,0,u,v,1,-y*u,-y*v]])
        result.extend([x,y])
    return np.append(np.linalg.solve(equations,result),1).reshape(3,3)


def project(points, matrix):
    points = np.column_stack([np.asarray(points),np.ones(len(points))]) @ matrix.T
    return points[:,:2]/points[:,2:]


def patch_polygons(corners, fraction=.48):
    if not .05 <= fraction <= .8:
        raise ValueError("ROI fraction must be between 0.05 and 0.8")
    matrix = homography(corners)
    result=[]
    for row in range(4):
        for col in range(6):
            u,v=(col+.5)/6,(row+.5)/4
            du,dv=fraction/12,fraction/8
            result.append(project([(u-du,v-dv),(u+du,v-dv),(u+du,v+dv),(u-du,v+dv)],matrix))
    return np.array(result)


def preview_sensor(raw):
    mosaic=raw.raw_image_visible
    h,w=mosaic.shape; h-=h%2;w-=w%2
    pattern=raw.raw_colors_visible[:2,:2]
    black=raw.black_level_per_channel;den=raw.white_level-max(black)
    channels=[]
    for channel in b"RGB":
        planes=[(mosaic[y:h:2,x:w:2].astype(np.float32)-black[int(pattern[y,x])])/den
                for y in range(2) for x in range(2) if raw.color_desc[int(pattern[y,x])]==channel]
        if not planes: raise ValueError("Only RGB Bayer RAWs are supported")
        channels.append(np.mean(planes,axis=0))
    image=np.stack(channels,axis=-1)
    wb=np.array(raw.camera_whitebalance[:3]);wb/=wb[1]
    image=np.uint8(np.clip(image*wb,0,1)**(1/2.2)*255)
    preview=Image.fromarray(image);preview.thumbnail((1800,1400))
    return preview


def extract_patches(path, region, expected_model, annotation):
    polygons=patch_polygons(region["corners"],region.get("roi_fraction",.48))
    with rawpy.imread(str(path)) as raw:
        metadata=raw_metadata(path,raw)
        if metadata["model"] != expected_model:
            raise ValueError(f"Expected {expected_model}, got {metadata['model']}")
        if region.get("sha256") != metadata["sha256"]:
            raise ValueError("Chart coordinates do not belong to this RAW; supply a chart JSON with its SHA-256")
        mosaic=raw.raw_image_visible
        h,w=mosaic.shape;pattern=raw.raw_colors_visible[:2,:2]
        black=raw.black_level_per_channel;den=raw.white_level-max(black)
        values,quality=[],[]
        for i,poly in enumerate(polygons):
            xy=poly*np.array([w,h]);x0,y0=np.floor(xy.min(axis=0)).astype(int);x1,y1=np.ceil(xy.max(axis=0)).astype(int)
            x0=max(0,x0);y0=max(0,y0);x1=min(w,x1);y1=min(h,y1)
            yy,xx=np.mgrid[y0:y1,x0:x1]
            points=np.stack([xx+.5,yy+.5],axis=-1)
            edges=np.roll(xy,-1,axis=0)-xy
            cross=edges[:,0,None,None]*(points[None,...,1]-xy[:,1,None,None])-edges[:,1,None,None]*(points[None,...,0]-xy[:,0,None,None])
            inside=np.all(cross>=0,axis=0)|np.all(cross<=0,axis=0)
            colours=pattern[yy%2,xx%2];sample=mosaic[y0:y1,x0:x1]
            patch=[];noise=[];clip=[];counts=[]
            for ch in b"RGB":
                ids=[k for k,v in enumerate(raw.color_desc) if v==ch]
                mask=inside & np.isin(colours,ids)
                codes=sample[mask].astype(float);ci=colours[mask]
                if len(codes)<100:raise ValueError(f"Too few CFA samples in patch {i+1}")
                linear=(codes-np.asarray(black)[ci])/den
                median=float(np.median(linear));patch.append(median)
                noise.append(float(np.median(np.abs(linear-median))*1.4826));clip.append(float(np.mean(codes>=raw.white_level-1)));counts.append(len(codes))
            values.append(patch);quality.append({"patch":i+1,"name":PATCH_NAMES[i],"rgb":patch,"mad_sigma":noise,"clipped_fraction":clip,"samples":counts})
        preview=preview_sensor(raw);draw=ImageDraw.Draw(preview)
        for i,poly in enumerate(polygons):
            coords=[tuple(p*np.array(preview.size)) for p in poly]
            draw.line(coords+[coords[0]],fill="yellow",width=2)
            draw.text(coords[0],str(i+1),fill="white",stroke_width=1,stroke_fill="black")
        annotation.parent.mkdir(parents=True,exist_ok=True);preview.save(annotation)
    return np.asarray(values),quality,metadata


def normalisation(patches, gray_level):
    neutral=patches[[19,20,21,22]]
    if np.any(neutral<=0):raise ValueError("Neutral patches contain non-positive sensor response")
    wb=np.array([np.median(neutral[:,1]/neutral[:,0]),1,np.median(neutral[:,1]/neutral[:,2])])
    scale=gray_level/float(np.mean(patches[21]*wb))
    return patches*wb*scale,wb,scale


def fit_matrix(source,target):
    """Six free coefficients, exact preservation of the neutral axis; no offset."""
    design=source[:,:2]-source[:,2:3]
    if np.linalg.matrix_rank(design)<2 or np.linalg.cond(design)>100:
        raise ValueError("Colour patches do not span a stable colour mapping")
    weights=1/np.sqrt(np.maximum(target.mean(axis=1),.03))
    solution=np.linalg.lstsq(design*weights[:,None],(target-source[:,2:3])*weights[:,None],rcond=None)[0]
    matrix=np.column_stack([solution.T,1-solution.sum(axis=0)])
    if np.linalg.det(matrix)<=0 or np.linalg.cond(matrix)>20:
        raise ValueError("Unstable or reversed fitted matrix; check chart registration")
    return matrix


def summary(values):
    return {"mean":float(np.mean(values)),"median":float(np.median(values)),
            "p95":float(np.percentile(values,95)),"maximum":float(np.max(values))}


def calibrate(args,assets):
    config=json.loads(Path(args.chart).read_text())
    source,source_quality,source_meta=extract_patches(args.sony,config["sony"],"ILCE-7RM5",WORK/"sony_chart_regions.jpg")
    target,target_quality,target_meta=extract_patches(args.hasselblad,config["hasselblad"],"X2D II 100C",WORK/"x2dii_chart_regions.jpg")
    for quality in (source_quality,target_quality):
        for item in quality:
            if max(item["clipped_fraction"])>.001:raise ValueError(f"Clipped calibration patch {item['patch']}")
    src,swb,sscale=normalisation(source,args.gray_level)
    tgt,twb,tscale=normalisation(target,args.gray_level)
    cct,residual=estimate_cct(twb,assets)
    if args.cct is not None:cct=args.cct
    cct=int(cct)
    # Chromatic patches train the matrix. Neutrals are explicit normalisation controls.
    train=np.arange(18);matrix=fit_matrix(src[train],tgt[train]);prediction=src@matrix.T
    heldout=[]
    for i in train:
        indices=train[train!=i]
        heldout.append(src[i]@fit_matrix(src[indices],tgt[indices]).T)
    heldout=np.array(heldout)
    target_lab=output_lab(tgt,cct,assets)
    baseline_de=delta_e_2000(output_lab(src,cct,assets),target_lab)
    fitted_de=delta_e_2000(output_lab(prediction,cct,assets),target_lab)
    cv_de=delta_e_2000(output_lab(heldout,cct,assets),target_lab[:18])
    matrix_accepted=float(cv_de.mean())<float(baseline_de[:18].mean())
    selected=matrix if matrix_accepted else np.eye(3)
    report={"schema":1,"source":source_meta,"target":target_meta,"chart_config":config,
            "source_quality":source_quality,"target_quality":target_quality,
            "source_wb":swb.tolist(),"target_wb":twb.tolist(),"source_scale":sscale,"target_scale":tscale,
            "gray_level":args.gray_level,"gray_patch":22,"target_cct":cct,"cct_wb_log_squared_error":residual,
            "cct_method":"estimated from neutral-patch WB against factory WB; not measured illuminant SPD",
            "mapping_convention":"target_column_rgb = matrix @ source_column_rgb; inputs are white-balanced and exposure-normalised",
            "matrix":selected.tolist(),"fitted_matrix":matrix.tolist(),"matrix_accepted":matrix_accepted,
            "matrix_condition_number":float(np.linalg.cond(matrix)),
            "metrics":{"baseline_all_patches_deltaE00":summary(baseline_de),
                       "fitted_all_patches_deltaE00":summary(fitted_de),
                       "baseline_chromatic_deltaE00":summary(baseline_de[:18]),
                       "leave_one_chromatic_patch_out_deltaE00":summary(cv_de),
                       "raw_rgb_rmse":float(np.sqrt(np.mean((prediction-tgt)**2)))},
            "patches":[{"patch":i+1,"name":PATCH_NAMES[i],"source_native":source[i].tolist(),"target_native":target[i].tolist(),
                        "source_normalised":src[i].tolist(),"target_normalised":tgt[i].tolist(),"predicted_target":prediction[i].tolist(),
                        "baseline_deltaE00":float(baseline_de[i]),"fitted_deltaE00":float(fitted_de[i]),
                        "heldout_deltaE00":float(cv_de[i]) if i<18 else None} for i in range(24)],
            "validation_scope":"18 chromatic patch LOOCV conditional on shared neutral calibration; not an independent-scene test. DeltaE compares this implementation's rendered target, not Phocus ground truth.",
            "limitations":["Captures are from 2022 and 2025; scene/illuminant changes remain confounded with sensor response.",
                           "One illumination and 24 patches cannot establish cross-scene or cross-illuminant accuracy.",
                           "Factory calibration only; no per-unit closed-loop calibration, spatial processing or Phocus TIFF comparison."],
            "assets_provenance":assets["provenance"]}
    save_json(args.profile,report)
    print("Calibration:",json.dumps(report["metrics"],indent=2),flush=True)
    print("Selected matrix:\n",selected,"\nCCT:",round(cct),"K",flush=True)
    if not matrix_accepted:print("Fitted matrix failed the held-out patch gate; using identity mapping.",flush=True)
    return report


def demosaic(path,expected_model):
    """LibRaw linear camera RGB, unity WB, fixed metadata white; no lens corrections."""
    with rawpy.imread(str(path)) as raw:
        metadata=raw_metadata(path,raw)
        if metadata["model"]!=expected_model:raise ValueError(f"Expected {expected_model}; got {metadata['model']}")
        if metadata["cfa"] not in ([[0,1],[3,2]],[[2,3],[1,0]],[[1,0],[2,3]],[[3,2],[0,1]]):
            raise ValueError("Unsupported Bayer layout")
        # dcraw_process subtracts black before applying user_sat. Its override
        # must therefore be in black-subtracted units, matching extract_patches.
        linear_white = raw.white_level-max(raw.black_level_per_channel)
        image=raw.postprocess(output_color=rawpy.ColorSpace.raw,output_bps=16,gamma=(1,1),
                              user_wb=[1,1,1,1],use_camera_wb=False,use_auto_wb=False,
                              no_auto_bright=True,adjust_maximum_thr=0,user_sat=linear_white,
                              bright=1,user_flip=0,demosaic_algorithm=rawpy.DemosaicAlgorithm.AHD,
                              fbdd_noise_reduction=rawpy.FBDDNoiseReductionMode.Off,median_filter_passes=0)
    return image,metadata


def srgb_from_hncs(codes,assets):
    # The output ICC decodes L*, not the complete scene-to-display V1 function.
    linear=lstar_decode(codes.astype(np.float64)/65535)
    xyz=linear@assets["working_rgb_to_xyz"].T
    bradford=np.array([[.8951,.2664,-.1614],[-.7502,1.7135,.0367],[.0389,-.0685,1.0296]])
    src_white=assets["working_rgb_to_xyz"].sum(axis=1)
    target_white=np.array([.95047,1,1.08883])
    cat=np.linalg.inv(bradford)@np.diag((bradford@target_white)/(bradford@src_white))@bradford
    xyz=xyz@cat.T
    xyz_to_srgb=np.array([[3.2404542,-1.5371385,-.4985314],[-.969266,1.8760108,.041556],[.0556434,-.2040259,1.0572252]])
    rgb=np.clip(xyz@xyz_to_srgb.T,0,1)
    return np.where(rgb<=.0031308,12.92*rgb,1.055*np.power(rgb,1/2.4)-.055)


def make_preview(codes, assets, maximum=1800):
    """Area-average the full image so thumbnail sampling does not introduce moiré."""
    height, width = codes.shape[:2]
    step = max(1, math.ceil(max(height, width) / maximum))
    small = np.empty((math.ceil(height / step), math.ceil(width / step), 3))
    for row, start in enumerate(range(0, height, step)):
        band = np.asarray(codes[start:start+step])
        complete = width // step
        if complete:
            small[row, :complete] = band[:, :complete*step].reshape(len(band), complete, step, 3).mean(axis=(0, 2))
        if width % step:
            small[row, complete] = band[:, complete*step:].mean(axis=(0, 1))
    return Image.fromarray(np.uint8(np.rint(srgb_from_hncs(small, assets) * 255)))


def render(args,assets,profile,target_reference=False):
    path=Path(args.input); output=Path(args.output)
    if output.suffix.lower() not in (".tif", ".tiff"):
        raise ValueError("Output must have a .tif or .tiff extension")
    if output.resolve() == path.resolve():
        raise ValueError("Output cannot overwrite the input RAW")
    metadata_key="target" if target_reference else "source"
    expected="X2D II 100C" if target_reference else "ILCE-7RM5"
    print("Demosaicing",path.name,flush=True)
    image,metadata=demosaic(path,expected)
    same_input=metadata["sha256"]==profile[metadata_key]["sha256"]
    wb_mode="calibration" if same_input and args.wb=="auto" else ("camera" if args.wb=="auto" else args.wb)
    wb=np.array(profile["target_wb" if target_reference else "source_wb"])
    if wb_mode=="camera":
        wb=np.array(metadata["camera_wb"][:3]);wb/=wb[1]
    scale=profile["target_scale" if target_reference else "source_scale"]*2**args.exposure
    cct=args.cct if args.cct is not None else profile["target_cct"]
    matrix=np.eye(3) if target_reference else np.array(profile["matrix"])
    output.parent.mkdir(parents=True,exist_ok=True)
    result=tifffile.memmap(output,shape=image.shape,dtype=np.uint16,photometric="rgb",metadata=None,
                          extratags=[(34675,"B",len(assets["icc"]),assets["icc"],False)],
                          description="HNCS factory-colour reconstruction; Hasselblad L*RGB; Phocus equivalence unverified")
    stats={"native_out_of_range_samples":0,"native_samples":0,"working_out_of_range_samples":0,"working_samples":0}
    for start in range(0,len(image),args.chunk_rows):
        rgb=image[start:start+args.chunk_rows].astype(np.float64)/65535
        native=(rgb*wb*scale)@matrix.T
        result[start:start+args.chunk_rows]=hncs_codes(native,cct,assets,args.intent,not args.no_lut,stats)
    result.flush()
    # Colour-managed delivery in two spaces: 16-bit L*RGB master and 16-bit sRGB TIFF.
    preview=make_preview(result,assets)
    srgb_icc=ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    preview_path=output.with_suffix(".preview.jpg");preview.save(preview_path,quality=95,icc_profile=srgb_icc)
    srgb_path=output.with_name(output.stem+"_srgb.tif")
    srgb=tifffile.memmap(srgb_path,shape=image.shape,dtype=np.uint16,photometric="rgb",metadata=None,
                        extratags=[(34675,"B",len(srgb_icc),srgb_icc,False)])
    for start in range(0,len(result),args.chunk_rows):
        srgb[start:start+args.chunk_rows]=np.uint16(np.rint(srgb_from_hncs(result[start:start+args.chunk_rows],assets)*65535))
    srgb.flush()
    run={"input":metadata,"output":str(output.resolve()),"output_space":"Hasselblad L*RGB, CIE L* encoded with V1 tone shaping" if args.intent=="standard" else "Hasselblad L*RGB, pure CIE L* encoding",
         "srgb_output":str(srgb_path.resolve()),"preview":str(preview_path.resolve()),"shape":list(image.shape),
         "profile_sha256":digest(args.profile),"cct":cct,"white_balance":wb.tolist(),"wb_mode":wb_mode,
         "scale":scale,"additional_ev":args.exposure,"intent":args.intent,"factory_lut_enabled":not args.no_lut,
         "matrix":matrix.tolist(),"clipping":stats,"limitations":profile["limitations"]}
    save_json(output.with_suffix(".json"),run)
    del srgb,result,image
    print("Saved",output,"and",srgb_path,flush=True)
    return run


def validate_output(path,assets,colour_space="hasselblad"):
    with tifffile.TiffFile(path) as tif:
        page=tif.pages[0]
        if page.dtype!=np.dtype("uint16") or page.samplesperpixel!=3:raise ValueError("Invalid output TIFF")
        icc = page.tags[34675].value
        if colour_space=="hasselblad":
            if icc!=assets["icc"]:raise ValueError("Output has incorrect Hasselblad ICC")
        else:
            profile = ImageCms.ImageCmsProfile(io.BytesIO(icc)).profile
            if profile.profile_description!="sRGB built-in" or profile.xcolor_space.strip()!="RGB":
                raise ValueError("Output has incorrect sRGB ICC")
        array=tifffile.memmap(path,mode="r")
        return {"shape":list(array.shape),"dtype":str(array.dtype),"icc_bytes":len(icc),"colour_space":colour_space,
                "minimum":int(array.min()),"maximum":int(array.max()),"bytes":Path(path).stat().st_size}


def comparison_preview(source, target, output):
    canvas = Image.new("RGB", (1800, 720), "#f4f4f4")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.load_default(size=22)
    titles = ("A7R V -> reconstructed HNCS", "X2D II -> same HNCS colour path")
    for i, path in enumerate((source, target)):
        draw.text((i*900+20,15),titles[i],fill="black",font=font)
        with Image.open(path) as image:
            image.thumbnail((880,655),Image.Resampling.LANCZOS)
            canvas.paste(image,(i*900+10+(880-image.width)//2,55+(655-image.height)//2))
    icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    canvas.save(output,quality=95,icc_profile=icc)


def parser():
    p=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    commands=p.add_subparsers(dest="command",required=True)
    for name in ("run","calibrate","render"):
        sub=commands.add_parser(name)
        sub.add_argument("--assets",type=Path,default=ASSETS)
        sub.add_argument("--profile",type=Path,default=PROFILE)
        sub.add_argument("--cct",type=float,help="Override target factory profile CCT in kelvin")
        if name in ("run","calibrate"):
            sub.add_argument("--sony",type=Path,default=SOURCE)
            sub.add_argument("--hasselblad",type=Path,default=TARGET)
            sub.add_argument("--chart",type=Path,default=CHART)
            sub.add_argument("--gray-level",type=float,default=.18,help="Chosen scene exposure anchor for neutral patch 22")
        if name in ("run","render"):
            if name == "render":
                sub.add_argument("--input",type=Path,default=SOURCE)
            sub.add_argument("--output",type=Path,default=WORK/"output/a7rv_hncs.tif")
            sub.add_argument("--chunk-rows",type=int,default=96)
            sub.add_argument("--exposure",type=float,default=0,help="Additional scene exposure in stops")
            sub.add_argument("--wb",choices=["auto","camera","calibration"],default="auto")
            sub.add_argument("--intent",choices=["standard","reproduction"],default="standard")
            sub.add_argument("--no-lut",action="store_true",help="Diagnostic matrix-only rendering")
            if name == "render":
                sub.add_argument("--target-reference",action="store_true",help="Render X2D II input without Sony mapping")
    return p


def main():
    args=parser().parse_args()
    if args.cct is not None and not 2000<=args.cct<=10000:raise ValueError("CCT must be 2000..10000 K")
    if hasattr(args,"gray_level") and not 0<args.gray_level<1:raise ValueError("gray-level must be between 0 and 1")
    if hasattr(args,"chunk_rows") and args.chunk_rows<1:raise ValueError("chunk-rows must be positive")
    if hasattr(args,"exposure") and (not math.isfinite(args.exposure) or abs(args.exposure)>20):
        raise ValueError("exposure must be finite and between -20 and 20 stops")
    assets=load_assets(args.assets)
    if args.command in ("run","calibrate"):
        profile=calibrate(args,assets)
    else:
        profile=json.loads(args.profile.read_text())
        if profile.get("schema")!=1:raise ValueError("Unsupported mapping profile schema")
    if args.command=="run":
        # Run renders the actual fitting input, even when --sony overrides it.
        args.input=args.sony
        render(args,assets,profile)
        target_args=argparse.Namespace(**vars(args));target_args.input=args.hasselblad
        target_args.output=args.output.with_name("x2dii_reference_hncs.tif")
        render(target_args,assets,profile,target_reference=True)
        checks={"sony":validate_output(args.output,assets),"hasselblad":validate_output(target_args.output,assets),
                "sony_srgb":validate_output(args.output.with_name(args.output.stem+"_srgb.tif"),assets,"srgb"),
                "hasselblad_srgb":validate_output(target_args.output.with_name(target_args.output.stem+"_srgb.tif"),assets,"srgb")}
        save_json(args.output.parent/"verification.json",checks)
        comparison_preview(args.output.with_suffix(".preview.jpg"),
                           target_args.output.with_suffix(".preview.jpg"),args.output.parent/"comparison.jpg")
        print("Verification:",json.dumps(checks,indent=2),flush=True)
    elif args.command=="render":
        render(args,assets,profile,args.target_reference)
        checks={"hncs":validate_output(args.output,assets),
                "srgb":validate_output(args.output.with_name(args.output.stem+"_srgb.tif"),assets,"srgb")}
        print("Verification:",json.dumps(checks,indent=2),flush=True)


if __name__=="__main__":
    try:main()
    except (ValueError,FileNotFoundError,KeyError) as error:
        print(f"ERROR: {error}",file=sys.stderr)
        sys.exit(2)
