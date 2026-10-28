"""Desktop-only Lucky/RAW-fusion diagnostics for a retained real burst.

Never controls a camera or qualifies a profile. The DNG NoiseProfile is an
uncalibrated noise estimate. An incompatible short frame is retained in the
audit and explicitly excluded from the four-main-frame computational controls.
"""
from pathlib import Path
import argparse
import base64
import ctypes as C
import hashlib
import json
import math
import struct
import subprocess
import time
import numpy as np
from scipy import ndimage as ndi
from PIL import Image, ImageDraw
from skimage.registration import phase_cross_correlation
from colour_demosaicing import demosaicing_CFA_Bayer_Malvar2004
from f5_offline import Observation, Options, Report


def dump(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def sha(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for data in iter(lambda: f.read(4 * 1024 * 1024), b""):
            h.update(data)
    return h.hexdigest()


def load(bundle):
    manifest = json.loads((bundle / "burst.json").read_text())
    if manifest["synthetic"] or len(manifest["frames"]) != 5:
        raise ValueError("Expected a retained real five-frame burst")
    return manifest, sorted(manifest["frames"], key=lambda f: f["burstIndex"])


def raw(bundle, frame, divisor):
    r = frame["raster"]; a = r["activeArea"]
    p = (bundle / frame["mosaic"]["path"]).resolve()
    if not p.is_relative_to(bundle.resolve()):
        raise ValueError("RAW path escapes bundle")
    values = np.memmap(p, mode="r", dtype="<u2" if r["byteOrder"] == "little" else ">u2",
                       shape=(r["height"], r["rowBytes"] // 2))
    values = values[a["top"]:a["bottom"], a["left"]:a["right"]]
    m = frame["metadata"]
    if m["linearization"] or m["blackDeltaH"] or m["blackDeltaV"] or len(set(m["blackLevel"])) != 1:
        raise ValueError("This diagnostic currently needs the audited linear, constant-black layout")
    scale = m["whiteLevel"][0] - m["blackLevel"][0]
    normalized = (values.astype(np.float32) / divisor - m["blackLevel"][0]) / scale
    return values, normalized, scale


def gain(frame, x, y):
    """Evaluate actual stage-3 maps at original ActiveArea pixel centers."""
    m = frame["metadata"]; area = m["activeArea"]
    width, height = area["right"] - area["left"], area["bottom"] - area["top"]
    result = np.ones(np.broadcast_shapes(np.shape(x), np.shape(y)), np.float32)
    for op in m["opcodes"]:
        if op["list"] != 3 or op["id"] != 9:
            raise ValueError("Unimplemented opcode in this real-data diagnostic")
        b = base64.b64decode(op["parameters"], validate=True)
        top, left, bottom, right, plane, planes, rp, cp, rows, cols = struct.unpack_from(">10I", b)
        sy, sx, oy, ox, channels = struct.unpack_from(">4dI", b, 40)
        maps = np.frombuffer(b, dtype=">f4", offset=76).reshape(rows, cols, channels)
        if (top, left, bottom, right, plane, planes, rp, cp) != (0, 0, height, width, 0, 3, 1, 1) or not np.all(maps == maps[:, :, :1]):
            raise ValueError("The four-main diagnostic requires a full-area achromatic gain map")
        u = np.clip((np.asarray(x) / width - ox) / sx, 0, cols - 1)
        v = np.clip((np.asarray(y) / height - oy) / sy, 0, rows - 1)
        u, v = np.broadcast_arrays(u, v); ix, iy = u.astype(int), v.astype(int)
        fx, fy = u - ix, v - iy; ix1, iy1 = np.minimum(ix + 1, cols - 1), np.minimum(iy + 1, rows - 1)
        result *= ((1 - fx) * maps[iy, ix, 0] + fx * maps[iy, ix1, 0]) * (1 - fy) + ((1 - fx) * maps[iy1, ix, 0] + fx * maps[iy1, ix1, 0]) * fy
    return result


def green_guide(frame, values):
    # BGGR: each non-overlapping 2x2 cell averages its two independent greens.
    if frame["metadata"]["cfa"] != [3, 1, 2, 0]:
        raise ValueError("Unexpected Bayer arrangement")
    g0, g1 = values[::2, 1::2], values[1::2, ::2]
    a, b = frame["metadata"]["noiseProfile"]
    y, x = np.mgrid[:g0.shape[0], :g0.shape[1]]
    shading = gain(frame, (x + .5) * 2, (y + .5) * 2)
    image = (g0 + g1) * .5 * shading
    variance = (a * np.maximum(g0, 0) + a * np.maximum(g1, 0) + 2 * b) * .25 * shading**2
    return image.astype(np.float32), variance.astype(np.float32)


def sharpness_tiles(image, variance):
    y, x = np.mgrid[-3:4, -3:4]
    kernels = [np.exp(-(x*x + y*y) * 4 / (2 * sigma*sigma)) for sigma in (.7, 1.4)]
    k0, k1 = [k/k.sum() for k in kernels]; band = k0-k1
    padded = np.pad(k1, 1); gxk = np.zeros_like(padded); gyk = np.zeros_like(padded)
    gxk[:, 1:] += padded[:, :-1]/4; gxk[:, :-1] -= padded[:, 1:]/4
    gyk[1:] += padded[:-1]/4; gyk[:-1] -= padded[1:]/4
    high = ndi.convolve(image, band, mode="reflect")**2 - ndi.convolve(variance, band**2, mode="reflect")
    gradient = ndi.convolve(image, gxk, mode="reflect")**2 + ndi.convolve(image, gyk, mode="reflect")**2
    floor = ndi.convolve(variance, gxk**2+gyk**2, mode="reflect")
    tiles = []
    for top in range(16, image.shape[0]-48, 48):
        for left in range(16, image.shape[1]-48, 48):
            r = np.s_[top:top+32, left:left+32]
            valid = image[r] > 4*np.sqrt(variance[r])
            h, g, n = float(high[r][valid].sum()), float((gradient-floor)[r][valid].sum()), float(floor[r][valid].sum())
            tiles.append(dict(x=left*2, y=top*2, mean=float(image[r].mean()),
                              high=h, gradient=g, noise=n, valid_fraction=float(valid.mean()),
                              score=max(0, h)/max(g, n, 1e-12)))
    return tiles


def preview(rgb, matrix, path, maximum=1400, exposure=1):
    step = max(1, math.ceil(max(rgb.shape[:2])/maximum))
    linear = np.asarray(rgb[::step, ::step], np.float32) @ matrix.T * exposure
    v = np.clip(linear, 0, 1)
    v = np.where(v <= .0031308, 12.92*v, 1.055*v**(1/2.4)-.055)
    Image.fromarray(np.round(v*255).astype(np.uint8)).save(path)


def prepare(args):
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    bundle = args.bundle.resolve(); manifest, frames = load(bundle)
    audit = json.loads(args.input_audit.read_text())
    if audit["manifest_sha256"] != sha(bundle/"burst.json") or not audit["all_blob_hashes_verified"]:
        raise ValueError("Input code-domain audit does not belong to this immutable burst")
    divisor = audit["native_to_dng_divisor"]
    mains = [f["burstIndex"] for f in frames if f["role"] == "L"]
    if len({frames[i]["actualISO"] for i in mains}) != 1:
        raise ValueError("Main frames themselves do not share ISO")
    guides, variances, rankings = {}, {}, {}
    for i in mains:
        frame = frames[i]
        for blob in (frame["mosaic"], frame["dng"]):
            path = bundle/blob["path"]
            if path.stat().st_size != blob["bytes"] or sha(path) != blob["sha256"]:
                raise ValueError("Original bytes changed")
        _, signal, scale = raw(bundle, frame, divisor)
        guides[i], variances[i] = green_guide(frame, signal)
        rankings[i] = sharpness_tiles(guides[i], variances[i])
        path = out/f"camera-main-{i}.npy"
        if not path.exists():
            camera = demosaicing_CFA_Bayer_Malvar2004(signal, "BGGR").astype(np.float32)
            height, width = signal.shape
            for row in range(0, height, 64):
                y, x = np.mgrid[row:min(row+64,height), :width]
                camera[row:row+64] *= gain(frame, x+.5, y+.5)[:, :, None]
            np.save(path, camera); del camera
        print(f"Prepared native 14-bit main frame {i}", flush=True)
    mask = np.array([[t["valid_fraction"]>.9 and t["gradient"]>4*t["noise"] for t in rankings[i]] for i in mains]).all(axis=0)
    scores = np.array([[t["score"] for t in rankings[i]] for i in mains])[:, mask]
    if scores.shape[1] < 8:
        raise ValueError("Too few reliable texture tiles to choose a Lucky frame")
    relative = scores/np.maximum(np.median(scores, axis=0), 1e-12)
    aggregate = np.median(relative, axis=1); lucky = mains[int(np.argmax(aggregate))]
    rng = np.random.default_rng(61027)
    boots = np.median(relative[:, rng.integers(0, relative.shape[1], (500, relative.shape[1]))], axis=2)
    intervals = np.percentile(boots, [2.5, 97.5], axis=1).T
    oracle = json.loads(subprocess.run([str(args.sdk_oracle.resolve()), str(bundle/frames[lucky]["dng"]["path"])], check=True, capture_output=True, text=True).stdout)
    d50_to_srgb = np.array([[3.1338561,-1.6168667,-.4906146],[-.9787684,1.9161415,.0334540],[.0719453,-.2289914,1.4052427]])
    matrix = d50_to_srgb @ np.array(oracle["camera_to_xyz_d50"]).reshape(3,3)
    translations, alignment = {}, []
    reference = ndi.gaussian_filter(guides[lucky], .6)[::2, ::2]
    h, w = reference.shape; crop = np.s_[h//8:7*h//8, w//8:7*w//8]
    for i in mains:
        moving = ndi.gaussian_filter(guides[i], .6)[::2, ::2]
        shift, error, _ = phase_cross_correlation(reference[crop], moving[crop], upsample_factor=50, normalization="phase")
        translations[i] = [float(shift[1]*4), float(shift[0]*4)]
        aligned = ndi.shift(moving, shift, order=1, mode="nearest")
        ncc = float(np.corrcoef(reference[crop].ravel(), aligned[crop].ravel())[0,1])
        alignment.append(dict(index=i, translation_native_xy=translations[i], guide_ncc=ncc))
        preview(np.load(out/f"camera-main-{i}.npy", mmap_mode="r"), matrix, out/f"main-{i}-preview.png")
    tiles = rankings[lucky]
    height, width = guides[lucky].shape[0]*2, guides[lucky].shape[1]*2
    def eligible(t): return 64 < t["x"] < width-128 and 64 < t["y"] < height-128
    available = [t for t in tiles if eligible(t)]
    choices = [
        ("flat_bright", min((t for t in available if t["mean"]>.08 and t["y"]<height*.45), key=lambda t:t["gradient"])),
        ("flat_dark", min((t for t in available if .003<t["mean"]<.05 and t["y"]>height*.4), key=lambda t:t["gradient"])),
        ("texture_left", max((t for t in available if t["x"]<width*.45 and t["y"]>height*.3), key=lambda t:t["high"])),
        ("texture_right", max((t for t in available if t["x"]>width*.55 and t["y"]>height*.3), key=lambda t:t["high"]))]
    rois = [dict(name=name, x=int(t["x"]), y=int(t["y"]), size=64, selection="fixed_before_fusion_from_lucky_texture_statistics") for name,t in choices]
    result = dict(revision="f5-desktop-real-quality-v1", synthetic=False, qualification="UNQUALIFIED_DIAGNOSTIC",
        camera_control_used=False, bundle=str(bundle), input_audit_sha256=sha(args.input_audit),
        native_to_dng_divisor=divisor, white_scale=scale, used_frames=mains, excluded_frames=[2],
        exclusion_reason="Short ISO 64 differs from main ISO 80; four-main computational control only",
        lucky_index=lucky, lucky_method="median noise-corrected DoG/gradient ratio over common valid texture tiles",
        ranking_tiles=int(mask.sum()), ranking=[dict(index=i,score=float(aggregate[j]),bootstrap_95=intervals[j].tolist()) for j,i in enumerate(mains)],
        alignment=alignment, matrix_camera_to_linear_srgb=matrix.tolist(), rois=rois,
        display=dict(orientation="sensor_native", recorded_exif_orientation=frames[lucky]["raster"]["orientation"], exposure_multiplier=1, tone_curve="sRGB encoding, common linear clamp for preview only", sharpening=False),
        assumptions=["DNG NoiseProfile used as an estimate, not a device calibration.",
            "Native samples retain low bits; B0 uses Malvar 2004 demosaic before the real Stage3 gain map.",
            "RAW computational controls approximate the smooth achromatic gain map as a radiometric response.",
            "Global translation initialization is estimated from the same main frames, not ground-truth motion.",
            "Real-scene PSNR/SSIM cannot establish accuracy without independent ground truth."])
    dump(out/"preparation.json", result)
    image = Image.open(out/f"main-{lucky}-preview.png").convert("RGB"); draw = ImageDraw.Draw(image)
    sx, sy = image.width/width, image.height/height
    for roi in rois:
        x,y,s=roi["x"]*sx,roi["y"]*sy,roi["size"]*sx
        draw.rectangle((x,y,x+s,y+s), outline="yellow", width=2);draw.text((x,y-12),roi["name"],fill="yellow")
    image.save(out/"lucky-roi-map.png")
    print("Lucky main:", lucky, "scores:", result["ranking"], "ROIs:", rois, flush=True)


def solve(args):
    out = args.output.resolve(); preparation = json.loads((out/"preparation.json").read_text())
    bundle = Path(preparation["bundle"]); _, frames = load(bundle)
    lucky = preparation["lucky_index"]; divisor = preparation["native_to_dng_divisor"]
    shifts = {v["index"]:np.array(v["translation_native_xy"]) for v in preparation["alignment"]}
    lib = C.CDLL(str(args.library.resolve())); fn = lib.f5_reference_reconstruct
    fn.argtypes = [C.POINTER(Observation), C.c_size_t, C.POINTER(C.c_double), Options, C.POINTER(C.c_double), C.c_size_t, C.POINTER(Report)]; fn.restype=C.c_int
    matrix = np.array(preparation["matrix_camera_to_linear_srgb"])
    reports = []
    for roi in preparation["rois"]:
        if args.roi and roi["name"] != args.roi: continue
        size = args.size; origin = np.array([roi["x"],roi["y"]]); observations = (Observation*(5*size*size))(); translations = np.zeros((5,2))
        locations=[]
        for i,frame in enumerate(frames):
            codes,signal,scale=raw(bundle,frame,divisor)
            selected = i in preparation["used_frames"]
            start=(np.floor((origin-shifts.get(i,np.zeros(2)))/2)*2).astype(int) if selected else origin.copy()
            translations[i]=start+shifts.get(i,np.zeros(2))-origin
            locations.append(dict(index=i,origin_native_xy=start.tolist(),translation_roi_xy=translations[i].tolist(),used=selected))
            x0,y0=start; patch=codes[y0:y0+size,x0:x0+size]
            values=(patch.astype(np.float64)/divisor-frame["metadata"]["blackLevel"][0])/scale
            if patch.shape!=(size,size):raise ValueError("Diagnostic crop exits the retained raster")
            yy,xx=np.mgrid[:size,:size]; response=1/gain(frame,xx+x0+.5,yy+y0+.5)
            kappa,variance=frame["metadata"]["noiseProfile"]; phase=np.array(frame["metadata"]["cfa"])[((yy+y0)&1)*2+((xx+x0)&1)]
            half=.5/divisor/scale
            for y in range(size):
                for x in range(size):
                    p=int(phase[y,x]); color=0 if p==0 else 2 if p==3 else 1
                    kind=0 if selected else 3
                    if patch[y,x]==0 or patch[y,x]>=frame["metadata"]["whiteLevel"][0]*divisor:kind=3
                    observations[(i*size+y)*size+x]=Observation(x+.5,y+.5,float(values[y,x]-half),float(values[y,x]+half),
                        frame["actualExposure"]/frames[lucky]["actualExposure"],float(response[y,x]),kappa,math.sqrt(variance),1/16384,color,p,i,kind)
        motion=(C.c_double*10)(*translations.ravel())
        lucky_rgb=np.load(out/f"camera-main-{lucky}.npy",mmap_mode="r")[origin[1]:origin[1]+size,origin[0]:origin[0]+size]
        y,x=np.mgrid[:size*2,:size*2]
        baseline=np.stack([ndi.map_coordinates(lucky_rgb[:,:,c],[(y+.5)/2-.5,(x+.5)/2-.5],order=1,mode="nearest") for c in range(3)],axis=-1)
        np.save(out/f"{roi['name']}-lucky-{size}.npy",baseline)
        preview(baseline,matrix,out/f"{roi['name']}-lucky-{size}.png",maximum=size*2)
        for b in ([1,5] if args.baseline=="both" else [int(args.baseline)]):
            pixels=np.zeros((size*2,size*2,3),dtype=np.float64); report=Report()
            options=Options(size,size,lucky,b,args.cycles,min(256,size*2),3,1e-4,4e-4,1e-5,.001,1e-5,.01)
            print(f"Starting {roi['name']} {size}x{size} B{b}, exact FP64 PG, {args.cycles} cycles",flush=True)
            started=time.monotonic();status=fn(observations,len(observations),motion,options,pixels.ctypes.data_as(C.POINTER(C.c_double)),pixels.size,C.byref(report))
            result=dict(roi=roi["name"],size=size,baseline=f"B{b}",exit_status=status,stop=report.stop.decode(),native_stop=report.native_stop.decode(),
                cycles=report.cycles,native_cycles=report.native_cycles,gradient=report.gradient,motion_gradient=report.motion_gradient,
                seconds=time.monotonic()-started,objectives=list(report.objectives)[:report.objective_count],used_frames=preparation["used_frames"],
                geometry_rounds=3,block_size=min(256,size*2),noise_source="DNG_NOISE_PROFILE_UNCALIBRATED",locations=locations)
            if status==0:
                path=out/f"{roi['name']}-B{b}-{size}.npy";np.save(path,pixels);preview(pixels,matrix,path.with_suffix(".png"),maximum=size*2)
            reports.append(result);dump(out/f"solve-{roi['name']}-{size}-B{b}.json",result)
            print(result,flush=True)
    dump(out/"latest-solve-run.json",dict(synthetic=False,qualification="UNQUALIFIED_DIAGNOSTIC",results=reports))


def metal_inputs(args):
    out=args.output.resolve();preparation=json.loads((out/"preparation.json").read_text());bundle=Path(preparation["bundle"])
    _,frames=load(bundle);lucky=preparation["lucky_index"];divisor=preparation["native_to_dng_divisor"]
    shifts={v["index"]:np.array(v["translation_native_xy"]) for v in preparation["alignment"]}
    for roi in preparation["rois"]:
        size=args.size;origin=np.array([roi["x"],roi["y"]]);inputs=[]
        for i,frame in enumerate(frames):
            used=i in preparation["used_frames"];start=(np.floor((origin-shifts.get(i,np.zeros(2)))/2)*2).astype(int) if used else origin.copy()
            codes,_,scale=raw(bundle,frame,divisor);x,y=start
            m=frame["metadata"];op=m["opcodes"][0]
            if len(m["opcodes"])!=1 or op["list"]!=3 or op["id"]!=9:raise ValueError("Unsupported radiometric diagnostic map")
            data=base64.b64decode(op["parameters"]);fields=struct.unpack_from(">10I",data);sy,sx,oy,ox,planes=struct.unpack_from(">4dI",data,40)
            rows,columns=fields[-2:];values=np.frombuffer(data,dtype=">f4",offset=76).reshape(rows,columns,planes)
            if not np.all(values==values[:,:,:1]):raise ValueError("Non-achromatic radiometric map")
            active=m["activeArea"];w,h=active["right"]-active["left"],active["bottom"]-active["top"]
            inputs.append(dict(index=i,codes=codes[y:y+size,x:x+size].ravel().tolist(),black=m["blackLevel"][0],whiteScale=scale,
                exposureRatio=frame["actualExposure"]/frames[lucky]["actualExposure"],kappa=m["noiseProfile"][0],readSigma=math.sqrt(m["noiseProfile"][1]),
                divisor=divisor,nativeWhite=int(m["whiteLevel"][0]*divisor),used=used,cfa=m["cfa"],translation=(start+shifts.get(i,np.zeros(2))-origin).tolist(),
                gain=dict(rows=rows,columns=columns,originX=(ox*w-x)/size,originY=(oy*h-y)/size,spacingX=sx*w/size,spacingY=sy*h/size,values=values[:,:,0].ravel().tolist()),
                original_dng_sha256=frame["dng"]["sha256"],original_native_sha256=frame["mosaic"]["sha256"],crop_origin=start.tolist()))
        record=dict(revision="f5-real-roi-v1",synthetic=False,qualification="UNQUALIFIED_DIAGNOSTIC",name=roi["name"],width=size,height=size,
                    reference=lucky,frames=inputs,maximumCycles=args.cycles,maximumSeconds=args.seconds)
        dump(out/f"{roi['name']}-metal-input.json",record)
    print("Desktop GPU inputs prepared",flush=True)


def mean_control(args):
    out=args.output.resolve();p=json.loads((out/"preparation.json").read_text());frames=p["used_frames"]
    matrix=np.array(p["matrix_camera_to_linear_srgb"]);shift={v["index"]:v["translation_native_xy"] for v in p["alignment"]}
    images={i:np.load(out/f"camera-main-{i}.npy",mmap_mode="r") for i in frames}
    height,width,_=images[frames[0]].shape
    result=np.lib.format.open_memmap(out/"four-main-registered-mean-control.npy",mode="w+",dtype=np.float32,shape=(height,width,3))
    for top in range(0,height,64):
        y,x=np.mgrid[top:min(height,top+64),:width];total=np.zeros((*x.shape,3),np.float32)
        for i in frames:
            sx,sy=shift[i]
            for c in range(3):total[:,:,c]+=ndi.map_coordinates(images[i][:,:,c],[y-sy,x-sx],order=1,mode="nearest",prefilter=False)
        result[top:top+64]=total/len(frames)
    result.flush();preview(result,matrix,out/"four-main-registered-mean-control-preview.png")
    dump(out/"mean-control.json",dict(method="registered arithmetic mean after common native Malvar demosaic and each DNG gain map",
         used_frames=frames,reference=p["lucky_index"],production_F5_output=False,motion_rejection=False,qualification="UNQUALIFIED_DIAGNOSTIC"))
    print("Four-main registered mean control exported",flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest="command",required=True)
    p=sub.add_parser("prepare");p.add_argument("--bundle",type=Path,required=True);p.add_argument("--input-audit",type=Path,required=True);p.add_argument("--sdk-oracle",type=Path,required=True);p.add_argument("--output",type=Path,required=True);p.set_defaults(run=prepare)
    p=sub.add_parser("solve");p.add_argument("--output",type=Path,required=True);p.add_argument("--library",type=Path,required=True);p.add_argument("--roi");p.add_argument("--size",type=int,choices=[16,32,64],default=64);p.add_argument("--cycles",type=int,default=50);p.add_argument("--baseline",choices=["1","5","both"],default="both");p.set_defaults(run=solve)
    p=sub.add_parser("metal-inputs");p.add_argument("--output",type=Path,required=True);p.add_argument("--size",type=int,choices=[32,64,128],default=64);p.add_argument("--cycles",type=int,default=50);p.add_argument("--seconds",type=float,default=120);p.set_defaults(run=metal_inputs)
    p=sub.add_parser("mean-control");p.add_argument("--output",type=Path,required=True);p.set_defaults(run=mean_control)
    args=parser.parse_args();args.run(args)


if __name__=="__main__":main()
