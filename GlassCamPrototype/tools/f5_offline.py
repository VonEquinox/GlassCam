"""Independent synthetic RAW generator, B0/B1/B5 controls, and honest comparison reports.

Requires NumPy and SciPy. The forward generator uses analytic optics and pixel
quadrature, never the reconstruction's cubic spline. These runs certify neither
an iPhone nor superiority over external methods.
"""
from pathlib import Path
import argparse
import ctypes as C
import hashlib
import json
import time
import numpy as np
from scipy import ndimage, special

KAPPA, READ_SIGMA, BLACK, WHITE_SCALE = .01, .015, 512, 65023


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


class Observation(C.Structure):
    _fields_ = [(x, C.c_double) for x in "x y lower upper exposure eta kappa read_sigma uniform_probability".split()] + [
        (x, C.c_uint32) for x in "color phase frame kind".split()]


class Options(C.Structure):
    _fields_ = [(x, C.c_int) for x in "width height reference baseline max_cycles block_size geometry_rounds".split()] + [
        (x, C.c_double) for x in "lambda_y lambda_c lambda_motion pi0 objective_tolerance gradient_tolerance".split()]


class Report(C.Structure):
    _fields_ = [(x, C.c_int) for x in "cycles native_cycles objective_count".split()] + [
        ("gradient", C.c_double), ("motion_gradient", C.c_double), ("objectives", C.c_double * 50),
        ("stop", C.c_char * 32), ("native_stop", C.c_char * 32)]


class InformationSample(C.Structure):
    _fields_ = [(x, C.c_double) for x in "x y gain mean dx dy curvature".split()] + [
        (x, C.c_uint32) for x in "color phase frame kind".split()]


class InformationResult(C.Structure):
    _fields_ = [("minimum", C.c_double), ("condition", C.c_double), ("short_information", C.c_double), ("motion_rank", C.c_int)]


def effective(x, y, channel, scene, width, height, frame=1):
    sigma = .18
    result = np.zeros(np.broadcast_shapes(np.shape(x), np.shape(y), np.shape(channel)))
    # Four by four quadrature of an optical response, independent of B-splines.
    for oy in (np.arange(4) + .5) / 4 - .5:
        for ox in (np.arange(4) + .5) / 4 - .5:
            u, v = x + ox, y + oy
            value = .5 + .025 * (channel - 1)
            if scene != "flat":
                for amplitude, fx, fy, phase in [(.11, .08, .07, .2), (.20, .65, 0, .6), (.10, 0, .57, .3)]:
                    value = value + amplitude * np.exp(-2 * np.pi**2 * sigma**2 * (fx**2 + fy**2)) * np.sin(2*np.pi*(fx*u+fy*v)+phase+.17*channel)
            if scene == "hdr":
                value = value + 1.5 * special.ndtr((u - width*.58) / sigma)
            if scene == "occlusion":
                center = width*.45 + (frame-1)*1.8
                mask = special.ndtr((u-center+1.8)/sigma)-special.ndtr((u-center-1.8)/sigma)
                value = value*(1-mask)+(.2+.35*(channel==0))*mask
            result += value / 16
    return result


def simulate(args):
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(args.seed); w, h = args.width, args.height
    yy, xx = np.mgrid[:h, :w]; phase = (yy % 2)*2+xx % 2; channel = np.array([0,1,1,2])[phase]
    motion = np.array([[.17,.22],[0,0],[-.23,.14],[.32,-.18],[-.22,-.24]])
    frames = []
    for f in range(5):
        ratio = .125 if f == 2 else 1
        mu = ratio * effective(xx+.5+motion[f,0], yy+.5+motion[f,1], channel, args.scene, w, h, f)
        sensor = KAPPA*rng.poisson(np.maximum(mu,0)/KAPPA)+rng.normal(0,READ_SIGMA,mu.shape)
        codes = np.rint(sensor*WHITE_SCALE+BLACK).clip(0,65535).astype(np.uint16)
        frames.append(codes.ravel().astype(int).tolist())
    scene = dict(synthetic=True, scene=args.scene, width=w, height=h, seed=args.seed,
        generator="analytic Gaussian optics + 4x4 pixel quadrature + independent PG + integer ADC",
        motion=motion.tolist(), kappa=KAPPA, read_sigma=READ_SIGMA, black=BLACK, white_scale=WHITE_SCALE,
        roles=["L","L","S","L","L"], frames=frames)
    write_json(out / "scene.json", scene)
    y, x, c = np.mgrid[:h*2, :w*2, :3]
    np.save(out / "truth.npy", effective((x+.5)/2, (y+.5)/2, c, args.scene, w, h))
    print(out / "scene.json")


def observations(scene):
    w, h = scene["width"], scene["height"]; records = []
    for f, codes in enumerate(scene["frames"]):
        for i, code in enumerate(codes):
            x, y = i % w, i // w; phase = (y % 2)*2+x % 2
            kind = 2 if code == 0 else 1 if code == 65535 else 0
            lower = 1 if kind == 1 else (code-.5-BLACK)/WHITE_SCALE
            upper = -BLACK/WHITE_SCALE if kind == 2 else (code+.5-BLACK)/WHITE_SCALE
            records.append(Observation(x+.5,y+.5,lower,upper,.125 if f==2 else 1,1,KAPPA,READ_SIGMA,
                1/65536,[0,1,1,2][phase],phase,f,kind))
    return (Observation * len(records))(*records)


def baseline_zero(scene):
    w, h = scene["width"], scene["height"]
    raw = (np.array(scene["frames"][1]).reshape(h,w)-BLACK)/WHITE_SCALE
    y,x = np.mgrid[:h,:w]; color = np.array([0,1,1,2])[(y%2)*2+x%2]
    kernel = np.array([[1,2,1],[2,4,2],[1,2,1]], float)
    result = np.empty((h*2,w*2,3)); yy,xx = np.mgrid[:h*2,:w*2]
    for c in range(3):
        mask = color==c
        image = ndimage.convolve(raw*mask,kernel,mode="mirror")/ndimage.convolve(mask.astype(float),kernel,mode="mirror")
        result[:,:,c] = ndimage.map_coordinates(image,[(yy+.5)/2-.5,(xx+.5)/2-.5],order=1,mode="nearest")
    return result


def baselines(args):
    scene = json.loads(args.scene.read_text()); out = args.output.resolve(); out.mkdir(parents=True,exist_ok=True)
    if not scene["synthetic"] or max(scene["width"],scene["height"])>64:
        raise SystemExit("This small FP64 control requires explicitly synthetic images up to 64 pixels per side.")
    lib = C.CDLL(str(args.library.resolve())); fn = lib.f5_reference_reconstruct
    fn.argtypes = [C.POINTER(Observation),C.c_size_t,C.POINTER(C.c_double),Options,C.POINTER(C.c_double),C.c_size_t,C.POINTER(Report)]
    fn.restype = C.c_int
    events = observations(scene); w,h = scene["width"],scene["height"]
    report = dict(synthetic=True, scene_sha256=digest(args.scene), motion="known ground truth control" if args.oracle_motion else "estimated from the same RAW guides", baselines={})
    np.save(out/"B0.npy",baseline_zero(scene)); report["baselines"]["B0"] = dict(stop="DIRECT_DEMOSAIC",same_five_frame_budget=True,used_frames=[1])
    motion = (C.c_double*10)(*np.array(scene["motion"]).ravel()) if args.oracle_motion else None
    for baseline in (1,5):
        pixels = np.zeros((h*2,w*2,3),dtype=np.float64); result = Report()
        options = Options(w,h,1,baseline,args.cycles,8,0 if args.oracle_motion else 3,1e-4,4e-4,1e-5,.001,1e-7,1e-4)
        start=time.monotonic(); status=fn(events,len(events),motion,options,pixels.ctypes.data_as(C.POINTER(C.c_double)),pixels.size,C.byref(result))
        value=dict(exit_status=status,stop=result.stop.decode(),native_stop=result.native_stop.decode(),cycles=result.cycles,
            native_cycles=result.native_cycles,standardized_gradient=result.gradient,standardized_motion_gradient=result.motion_gradient,
            seconds=time.monotonic()-start,objectives=list(result.objectives)[:result.objective_count])
        report["baselines"][f"B{baseline}"]=value
        if status==0: np.save(out/f"B{baseline}.npy",pixels)
        write_json(out/"baseline-report.json",report)
        print(f"B{baseline}",value["stop"],"status",status,flush=True)
        if status: raise SystemExit(f"FP64 B{baseline} failed; its report was retained.")


def compare(args):
    truth=np.load(args.truth); baseline=json.loads((args.baselines/"baseline-report.json").read_text())
    images={name:np.load(args.baselines/f"{name}.npy") for name in ("B0","B1","B5")}
    report=dict(synthetic=True, physical_camera_used=False, scene_sha256=baseline["scene_sha256"],
        external_same_input_baselines={"B2":"NOT_RUN","B3":"NOT_RUN","B4":"NOT_RUN"},
        physical_gates={"P0":"NOT_RUN","G1_physical":"NOT_RUN","G3_real_data":"NOT_RUN","G4_device":"NOT_RUN"}, metrics={})
    if args.candidate:
        paths=json.loads(args.candidate.read_text()); descriptor=json.loads(Path(paths["camera_rgb"]).with_suffix(".json").read_text())
        if paths["input_scene_sha256"]!=baseline["scene_sha256"]:raise ValueError("Candidate and controls used different five-frame inputs")
        shape=(descriptor["height"],descriptor["width"],4)
        if digest(paths["camera_rgb"]) != descriptor["sha256"]: raise ValueError("Candidate RGB hash changed")
        images["F5_Metal"]=np.fromfile(paths["camera_rgb"],dtype="<f4").reshape(shape)[:,:,:3]
        report["candidate_quality"]=json.loads(Path(paths["quality"]).read_text())
    for name,image in images.items():
        if image.shape!=truth.shape or not np.isfinite(image).all():raise ValueError(f"Invalid {name} comparison raster")
        delta=image-truth
        report["metrics"][name]=dict(rmse=float(np.sqrt(np.mean(delta**2))),mae=float(np.mean(abs(delta))),
            error_standard_deviation=float(np.std(delta)),mean_error=float(np.mean(delta)),minimum=float(image.min()),maximum=float(image.max()))
    qualified=baseline["baselines"]["B5"]["stop"]=="CONVERGED"
    report["B5_converged"]=qualified
    report["candidate_to_B5_relative_rmse"]=(float(np.linalg.norm(images["F5_Metal"]-images["B5"])/np.linalg.norm(images["B5"])) if "F5_Metal" in images and qualified else None)
    report["interpretation"]="Software/controlled-scene evidence only. B5 is a computational reference, not ground truth; this is not the external G3 or device G4 acceptance."
    write_json(args.output,report);print(args.output)


def schur(args):
    lib=C.CDLL(str(args.library.resolve()));fn=lib.f5_information
    fn.argtypes=[C.POINTER(InformationSample),C.c_size_t,C.c_double,C.c_int,C.POINTER(InformationResult)]
    rng=np.random.default_rng(714); results=[]
    basis=np.array([[1,1,1],[1,0,-1],[1,-2,1]],float)/np.sqrt([[3],[2],[6]])
    for rankless in (False,True):
        samples=[];aa=[];gg=[];ww=[];amplitude=.025
        for i in range(120):
            frame=i//24;phase=(i%24)//6;color=[0,1,1,2][phase];x,y=rng.uniform(0,32,2)
            gain=.125 if frame==2 else 1;dx,dy=(0,0) if rankless else rng.normal(0,.1,2);weight=rng.uniform(5,80)
            a=np.concatenate([amplitude*gain*basis[c,color]*np.array([np.cos(2*np.pi*.65*x),np.sin(2*np.pi*.65*x),np.cos(2*np.pi*.65*y),np.sin(2*np.pi*.65*y)]) for c in range(3)])
            g=np.zeros(8)
            if frame!=1:slot=frame-(frame>1);g[slot*2:slot*2+2]=gain*np.array([dx,dy])
            samples.append(InformationSample(x,y,gain,.3,dx,dy,weight,color,phase,frame,0));aa.append(a);gg.append(g);ww.append(weight)
        a=np.array(aa);g=np.array(gg);w=np.array(ww);A=a.T@(w[:,None]*a);G=g.T@(w[:,None]*g);B=a.T@(w[:,None]*g)
        expected=A-B@np.linalg.pinv(G,rcond=1e-8)@B.T;eigen=np.linalg.eigvalsh(expected)
        actual=InformationResult();array=(InformationSample*120)(*samples);status=fn(array,120,amplitude,1,C.byref(actual))
        error=abs(actual.minimum-max(0,eigen[0]));condition=max(0,eigen[-1])/eigen[0]
        if status or error>1e-9 or abs(actual.condition-condition)>1e-7:raise AssertionError("Production Schur reduction differs from NumPy's independent dense elimination")
        results.append(dict(rankless=rankless,motion_rank=actual.motion_rank,minimum_error=error,condition_error=abs(actual.condition-condition)))
    write_json(args.output,dict(synthetic=True,independent_oracle="NumPy dense Schur/pseudoinverse",results=results));print(args.output)


def main():
    ap=argparse.ArgumentParser(description=__doc__);sub=ap.add_subparsers(dest="command",required=True)
    p=sub.add_parser("simulate");p.add_argument("--output",type=Path,required=True);p.add_argument("--scene",choices=["chart","hdr","flat","occlusion"],default="chart")
    p.add_argument("--width",type=int,default=16);p.add_argument("--height",type=int,default=16);p.add_argument("--seed",type=int,default=20261027);p.set_defaults(run=simulate)
    p=sub.add_parser("baselines");p.add_argument("--scene",type=Path,required=True);p.add_argument("--library",type=Path,required=True);p.add_argument("--output",type=Path,required=True)
    p.add_argument("--cycles",type=int,default=50);p.add_argument("--oracle-motion",action="store_true");p.set_defaults(run=baselines)
    p=sub.add_parser("compare");p.add_argument("--truth",type=Path,required=True);p.add_argument("--baselines",type=Path,required=True);p.add_argument("--candidate",type=Path);p.add_argument("--output",type=Path,required=True);p.set_defaults(run=compare)
    p=sub.add_parser("schur");p.add_argument("--library",type=Path,required=True);p.add_argument("--output",type=Path,required=True);p.set_defaults(run=schur)
    args=ap.parse_args();args.run(args)


if __name__=="__main__":main()
