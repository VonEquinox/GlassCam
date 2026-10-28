"""Fit four-phase photon-transfer calibration and certify PG lookup tables.

Calibration fitting always emits UNQUALIFIED candidates. Dataset identity,
optical response, timing, color, real-image and device gates remain separate.
"""
from pathlib import Path
import argparse
import ctypes as C
import hashlib
import json
import math
import struct
import numpy as np
from scipy.special import log_ndtr, gammaln, logsumexp


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def dump(path,value):Path(path).write_text(json.dumps(value,indent=2,allow_nan=False)+"\n")


def fit_arrays(data,config):
    required=["dark_fit","dark_validation","flat_fit","flat_validation"]
    arrays={key:np.asarray(data[key],dtype=float) for key in required}
    for name,a in arrays.items():
        if not np.isfinite(a).all() or a.shape[-2:]!=arrays["dark_fit"].shape[-2:]:raise ValueError("Nonfinite or inconsistent calibration rasters")
        if a.ndim!=(3 if name.startswith("dark") else 4) or a.shape[-3]<4:raise ValueError("At least four independent exposures per calibration level are required")
    if arrays["flat_fit"].shape[0]<4 or arrays["flat_validation"].shape[0]<2:raise ValueError("Use separate fit and held-out flat-field levels")
    h,w=arrays["dark_fit"].shape[-2:];yy,xx=np.mgrid[:h,:w]
    cfa=np.array(config["cfa_phase"]);phase=cfa[(yy%2)*2+xx%2]
    scale=float(config["white_scale"]);black=np.array(config["metadata_black_by_phase"],float)
    estimates=[];flat_means=[];checks=[]
    for p in range(4):
        mask=phase==p;dark=arrays["dark_fit"][:,mask];offset=float(dark.mean())
        read_variance=float(dark.var(axis=0,ddof=1).mean())
        levels=arrays["flat_fit"][:,:,mask];means=levels.mean(axis=(1,2))-offset
        variance=levels.var(axis=1,ddof=1).mean(axis=1)
        if np.min(means)<=0 or read_variance<=0:raise ValueError("Invalid dark/flat dynamic range")
        slope=float(np.dot(means,variance-read_variance)/np.dot(means,means))
        if slope<=0:raise ValueError("Photon-transfer slope is not positive")
        held=arrays["flat_validation"][:,:,mask];hm=held.mean(axis=(1,2))-offset;hv=held.var(axis=1,ddof=1).mean(axis=1)
        predicted=slope*hm+read_variance;relative=np.abs(hv-predicted)/predicted
        dark_held=arrays["dark_validation"][:,mask]
        mean_bias=float(abs(dark_held.mean()-offset)/math.sqrt(read_variance))
        checks.append(dict(phase=p,variance_relative_errors=relative.tolist(),dark_mean_bias_sigma=mean_bias,
            variance_pass=bool(relative.max()<=.05),dark_bias_pass=mean_bias<=.05))
        estimates.append(dict(kappa=slope/scale,readSigma=math.sqrt(read_variance)/scale,
            blackResidual=offset-black[p],gain=1.0))
        flat_means.append(float(means.mean()))
    green=(flat_means[1]+flat_means[2])/2
    estimates[1]["gain"]=flat_means[1]/green;estimates[2]["gain"]=flat_means[2]/green
    held_means=[]
    for p in (1,2):
        level=arrays["flat_validation"][:,:,(phase==p)]
        held_means.append((level.mean(axis=(1,2))-black[p]-estimates[p]["blackResidual"])/estimates[p]["gain"])
    green_error=float(np.max(abs(held_means[0]-held_means[1])/((held_means[0]+held_means[1])/2)))
    return dict(qualification="UNQUALIFIED",phases=estimates,holdout=checks,green_relative_error=green_error,
        green_merge_pass=green_error<=.005,statistical_checks_pass=all(x["variance_pass"] and x["dark_bias_pass"] for x in checks) and green_error<=.005,
        not_certified=["P0 independence/timing","G1 effective response/opcodes/preview/color","G2 device numerics","G3 real images","G4 resource/lifecycle"])


def fit(args):
    config=json.loads(args.config.read_text())
    if config.get("domain")!="dng_linearized_code_units_before_gain":raise ValueError("Calibration requires DNG linearized code units, after measured native-code conversion and before gain correction")
    mapping=config.get("buffer_code_mapping",{})
    if not config.get("synthetic"):
        evidence=mapping.get("evidenceSHA256","")
        if not isinstance(mapping.get("divisor"),int) or not 1<=mapping["divisor"]<=256 or mapping.get("dngStage1Rounding")!="floor" or len(evidence)!=64 or any(c not in "0123456789abcdef" for c in evidence):
            raise ValueError("Real calibration needs a measured native-buffer/DNG code mapping")
    if config.get("fit_capture_ids") is None or config.get("validation_capture_ids") is None or set(config["fit_capture_ids"])&set(config["validation_capture_ids"]):
        raise ValueError("Explicit disjoint fit/validation capture identities are required")
    with np.load(args.data,allow_pickle=False) as arrays:result=fit_arrays(arrays,config)
    result.update(synthetic=bool(config["synthetic"]),dataset_sha256=sha(args.data),config_sha256=sha(args.config),identity=config["identity"],
        code_domain=config["domain"],buffer_code_mapping=mapping)
    dump(args.output,result);print(args.output)


class Event(C.Structure):
    _fields_=[(x,C.c_double) for x in "lower upper kappa read_sigma uniform_probability".split()]+[("kind",C.c_uint32)]
class Value(C.Structure):
    _fields_=[(x,C.c_double) for x in "nll score curvature probability".split()]


def scipy_pg(mean,k,s,center,width,kind):
    lam=mean/k;radius=math.sqrt(72*(lam+1))+72
    end=max(math.ceil(lam+radius),math.ceil((center+12*s)/k));n=np.arange(max(0,end)+1)
    lp=np.where(n==0,0,-np.inf) if lam==0 else -lam+n*math.log(lam)-gammaln(n+1)
    def q(shift):
        z=(center-k*(n+shift))/s
        if kind==1:return log_ndtr(-z)
        if kind==2:return log_ndtr(z)
        half=width/(2*s);lo=z-half;hi=z+half
        # CDF subtraction on the well-conditioned side, with a local density
        # integral for sub-code intervals. Independent SciPy transcendental code.
        a=np.where(lo>0,log_ndtr(-lo),log_ndtr(hi));b=np.where(lo>0,log_ndtr(-hi),log_ndtr(lo))
        with np.errstate(divide="ignore",invalid="ignore"):
            answer=a+np.log(-np.expm1(b-a))
        small=(2*half<.05/np.maximum(1,abs(z)))
        correction=(z*z-1)*(2*half)**2/24+(z**4-6*z*z+3)*(2*half)**4/1920
        return np.where(small,math.log(2*half)-z*z/2-.5*math.log(2*np.pi)+np.log1p(correction),answer)
    a=logsumexp(lp+q(0));b=logsumexp(lp+q(1));return np.array([-a,(1-np.exp(b-a))/k])


def lut(args):
    profile=json.loads(args.profile.read_text());out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    if args.lambda_count<2 or args.z_count<2 or args.maximum_electrons<=0 or args.z_maximum<=0:raise ValueError("Invalid lookup domain")
    lib=C.CDLL(str(args.library.resolve()));fn=lib.f5_pg_event;fn.argtypes=[Event,C.c_double,C.POINTER(Value)];fn.restype=C.c_int
    nl,nz=args.lambda_count,args.z_count
    if 4*3*nl*nz*16>512*1024*1024:raise ValueError("LUT exceeds the 512 MiB generator limit")
    dl=float(np.float32(np.log1p(args.maximum_electrons)/(nl-1)));dz=float(np.float32(2*args.z_maximum/(nz-1)))
    divisor=profile.get("bufferCodeMapping",{}).get("divisor",1)
    if not isinstance(divisor,int) or not 1<=divisor<=256:raise ValueError("Invalid native/DNG code divisor")
    zmin=float(np.float32(-args.z_maximum));widths=[float(np.float32(1/(divisor*profile["whiteScale"])))]*4
    def reference(phase,kind,u,v,independent=False):
        noise=profile["noise"][phase];k,s=noise["kappa"],noise["readSigma"]
        lam=math.expm1(u*dl);mean=k*lam;center=mean+(zmin+v*dz)*math.sqrt(k*mean+s*s);width=widths[phase]
        if independent:return scipy_pg(mean,k,s,center,width,kind)
        event=Event(center-width/2 if kind==0 else center,center+width/2 if kind==0 else center,k,s,1/65536,kind);value=Value()
        status=fn(event,mean,C.byref(value))
        if status or not all(math.isfinite(x) for x in (value.nll,value.score,value.curvature,value.probability)):raise ValueError("Literal PG reference failed")
        return np.array([value.nll,value.score,value.curvature,value.probability])
    table=np.empty((4,3,nl,nz,4),dtype="<f4")
    for phase in range(4):
        for kind in range(3):
            for u in range(nl):
                for v in range(nz):table[phase,kind,u,v]=reference(phase,kind,u,v)
    rng=np.random.default_rng(20261027);nll_error=0.0;score_error=0.0;independent_error=0.0
    # Deterministic disjoint held-out locations, including grid-cell midpoints.
    for index in range(max(256,args.validation_points)):
        phase=index%4;kind=index//4%3;u=rng.uniform(0,nl-1);v=rng.uniform(0,nz-1)
        if index%2==0:u=math.floor(u)+.5;v=math.floor(v)+.5
        i,j=int(u),int(v);a,b=np.float32(u-i),np.float32(v-j)
        value=(table[phase,kind,i,j]*(1-a)+table[phase,kind,i+1,j]*a)*(1-b)+(table[phase,kind,i,j+1]*(1-a)+table[phase,kind,i+1,j+1]*a)*b
        exact=reference(phase,kind,u,v);noise=profile["noise"][phase];mean=noise["kappa"]*math.expm1(u*dl)
        standard=math.sqrt(noise["kappa"]*mean+noise["readSigma"]**2)
        nll_error=max(nll_error,abs(float(value[0])-exact[0]));score_error=max(score_error,abs(float(value[1])-exact[1])*standard)
        if index<64:
            independent=reference(phase,kind,u,v,True)
            independent_error=max(independent_error,abs(independent[0]-exact[0]),abs(independent[1]-exact[1])*standard)
    passed=bool(nll_error<1e-4 and score_error<1e-3 and independent_error<1e-7)
    certificate=dict(synthetic=profile["qualification"]=="SYNTHETIC_ONLY",passed=passed,nll_maximum_error=nll_error,
        standardized_score_maximum_error=score_error,independent_scipy_error=independent_error,
        validation_points=max(256,args.validation_points),profile_sha256=sha(args.profile),
        scope="Measured interpolation errors on the declared domain; outside-domain calls use the literal event model. This does not qualify hardware.")
    dump(out/"likelihood-validation.json",certificate)
    if not passed:raise SystemExit("LUT failed its error gates; increase grid density or narrow the declared domain. No certified table was emitted.")
    header=dict(revision="f5-pg-grid-v1",lambdaCount=nl,zCount=nz,logLambdaMinimum=0,logLambdaStep=dl,zMinimum=zmin,zStep=dz,
        intervalWidths=widths,nllError=nll_error,scoreError=score_error,generatorSHA256=sha(__file__),
        noiseKappa=[float(np.float32(x["kappa"])) for x in profile["noise"]],noiseReadSigma=[float(np.float32(x["readSigma"])) for x in profile["noise"]])
    encoded=json.dumps(header,separators=(",",":"),allow_nan=False).encode();path=out/"likelihood.f5lut"
    path.write_bytes(struct.pack("<I",len(encoded))+encoded+table.tobytes())
    dump(out/"likelihood-descriptor.json",dict(revision="f5-pg-v1",table=dict(path=path.name,sha256=sha(path),bytes=path.stat().st_size),
        nllMaximumError=nll_error,standardizedScoreMaximumError=score_error,exactMaximumElectrons=profile["likelihood"]["exactMaximumElectrons"]))
    print(path)


def self_test(args):
    rng=np.random.default_rng(991);h=w=64;black=512.0;gain=1.8;read=3.2
    def dark():return black+rng.normal(0,read,(32,h,w))
    def flats(levels):return np.stack([black+gain*rng.poisson(level/gain,(32,h,w))+rng.normal(0,read,(32,h,w)) for level in levels])
    data=dict(dark_fit=dark(),dark_validation=dark(),flat_fit=flats([200,500,900,1600,2500]),flat_validation=flats([350,1200,2100]))
    config=dict(cfa_phase=[0,1,2,3],white_scale=15871,metadata_black_by_phase=[black]*4)
    report=fit_arrays(data,config);report.update(synthetic=True,true_kappa=gain/15871,true_read_sigma=read/15871)
    error=max(abs(x["kappa"]/(gain/15871)-1) for x in report["phases"])
    if error>.03 or not report["statistical_checks_pass"]:raise AssertionError("Independent synthetic PTC recovery failed")
    report["maximum_gain_relative_error"]=error;dump(args.output,report);print(args.output)


def main():
    ap=argparse.ArgumentParser(description=__doc__);sub=ap.add_subparsers(required=True)
    p=sub.add_parser("fit");p.add_argument("--data",type=Path,required=True);p.add_argument("--config",type=Path,required=True);p.add_argument("--output",type=Path,required=True);p.set_defaults(run=fit)
    p=sub.add_parser("lut");p.add_argument("--profile",type=Path,required=True);p.add_argument("--library",type=Path,required=True);p.add_argument("--output",type=Path,required=True)
    p.add_argument("--lambda-count",type=int,default=33);p.add_argument("--z-count",type=int,default=129);p.add_argument("--maximum-electrons",type=float,default=.25);p.add_argument("--z-maximum",type=float,default=1)
    p.add_argument("--validation-points",type=int,default=1024);p.set_defaults(run=lut)
    p=sub.add_parser("self-test");p.add_argument("--output",type=Path,required=True);p.set_defaults(run=self_test)
    args=ap.parse_args();args.run(args)


if __name__=="__main__":main()
