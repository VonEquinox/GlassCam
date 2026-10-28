"""Audit the input/output contract of an external B2/B3/B4 result.

This does not execute or endorse the external method. It rejects mismatched
bursts, exposure normalization, white balance, geometry and altered rasters.
"""
from pathlib import Path
import argparse
import hashlib
import json
import numpy as np


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--burst",type=Path,required=True,help="Immutable burst.json")
    ap.add_argument("--result",type=Path,required=True,help="External result manifest")
    ap.add_argument("--output",type=Path,required=True)
    args=ap.parse_args();burst=json.loads(args.burst.read_text());result=json.loads(args.result.read_text())
    errors=[];frames=sorted(burst["frames"],key=lambda f:f["burstIndex"])
    reference=next((f for f in frames if f["id"]==result.get("referenceFrameID")),None)
    if result.get("revision")!="f5-external-v2" or result.get("baseline") not in ("B2","B3","B4"):errors.append("Unsupported external adapter revision/baseline")
    if result.get("burstManifestSHA256")!=sha(args.burst):errors.append("Different burst manifest")
    if result.get("frameSHA256")!=[f["dng"]["sha256"] for f in frames]:errors.append("Different five RAW deliveries or ordering")
    if result.get("mosaicSHA256")!=[f["mosaic"]["sha256"] for f in frames]:errors.append("Different original integer Bayer buffers")
    main=float(np.median([f["actualExposure"] for f in frames if f["role"]=="L"]))
    if result.get("mainExposure")!=main or result.get("exposureRatios")!=[f["actualExposure"]/main for f in frames]:errors.append("Different exposure normalization")
    if reference is None or reference["role"]!="L":errors.append("Reference must be one of the four main exposures")
    profile=burst.get("profile") or {}
    if not profile:errors.append("A bound normalization/noise profile is required for comparison")
    if result.get("whiteScale")!=profile.get("whiteScale"):errors.append("Different W0 normalization")
    if result.get("bufferCodeMapping")!=profile.get("bufferCodeMapping") or result.get("decoderRevision")!=profile.get("decoderRevision"):
        errors.append("Different native/DNG code mapping or decoder revision")
    if result.get("whiteBalanceApplied") is not False or result.get("colorSemantics")!="camera_linear_no_wb":errors.append("Rendered/white-balanced RGB cannot be compared as camera-linear evidence")
    if result.get("extraFramesUsed")!=0:errors.append("The external method exceeded the five-frame input budget")
    if result.get("postGeometry")!="DNG_after_reconstruction_once":errors.append("Unknown output geometry ownership")
    if result.get("postOpcodes")!="ordered_stage3_after_reconstruction_once" or result.get("opcodeRangePolicy")!="f5-scene-linear-unclipped-v1":
        errors.append("Different opcode ordering, gain ownership, or HDR range policy")
    method=result.get("method",{})
    if not method.get("name") or not method.get("revision") or not method.get("sourceURL"):errors.append("Missing implementation provenance")
    if result.get("baseline")=="B4" and (not method.get("weightsSHA256") or method.get("trainingDataOverlap")!="none_declared"):
        errors.append("Learned baseline must identify weights and declare dataset separation")
    raster=result.get("raster",{});base=args.result.parent.resolve()
    file=(base/raster.get("path","")).resolve()
    if not file.is_relative_to(base) or not file.is_file():errors.append("Raster path is unavailable or escapes the result package")
    else:
        if sha(file)!=raster.get("sha256"):errors.append("Raster checksum mismatch")
        if raster.get("dtype")!="float32_le" or raster.get("layout")!="interleaved_top_to_bottom" or raster.get("channels")!=3:errors.append("Unsupported raster layout")
        w,h=raster.get("width",0),raster.get("height",0)
        if not isinstance(w,int) or not isinstance(h,int) or w<=0 or h<=0 or w*h*12!=file.stat().st_size:errors.append("Raster size mismatch")
        if reference:
            size=reference["metadata"]["cropSize"]
            if [w,h]!=[int(size[0]*2),int(size[1]*2)] or raster.get("orientation")!=reference["raster"]["orientation"]:errors.append("Reference crop, 2x grid, or orientation differs")
        values=np.fromfile(file,dtype="<f4")
        if not np.isfinite(values).all():errors.append("Nonfinite external output")
    report=dict(revision="f5-external-audit-v2",same_input_contract="PASS" if not errors else "FAIL",errors=errors,
        input_burst_sha256=sha(args.burst),external_manifest_sha256=sha(args.result),synthetic=burst["synthetic"],
        image_quality_gate="NOT_RUN",training_separation="declaration_only",method=method)
    args.output.write_text(json.dumps(report,indent=2)+"\n")
    if errors:raise SystemExit("External comparison rejected: "+"; ".join(errors))
    print(args.output)


if __name__=="__main__":main()
