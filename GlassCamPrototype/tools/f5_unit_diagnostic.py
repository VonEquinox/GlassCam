"""Lossless PG-unit and physical-prior grid-spacing controls."""
from pathlib import Path
import argparse
import ctypes as C
import hashlib
import json
import numpy as np


class Event(C.Structure):
    _fields_=[(s,C.c_double) for s in ['lower','upper','kappa','read_sigma','uniform_probability']]+[('kind',C.c_uint32)]


class Value(C.Structure):
    _fields_=[(s,C.c_double) for s in ['nll','score','curvature','probability']]


def run(args):
    lib=C.CDLL(str(args.library.resolve()));fn=lib.f5_pg_event;fn.argtypes=[Event,C.c_double,C.POINTER(Value)];fn.restype=C.c_int
    rows=[];kappa=.00010030885;sigma=.0005210402
    for code,kind,mu in [(2113,0,.0002),(4096,0,.14),(13544,0,.8),(16380,1,1.02),(0,2,.0002)]:
        lo=1 if kind==1 else ((code-.5)/4-528)/3567;hi=-528/3567 if kind==2 else ((code+.5)/4-528)/3567;values=[]
        for unit in [1.,3567.,14268.]:
            event=Event(lo*unit,hi*unit,kappa*unit,sigma*unit,1/16384,kind);v=Value()
            if fn(event,mu*unit,C.byref(v)):raise AssertionError('PG primitive failed')
            values.append([v.nll,v.score*unit,v.curvature*unit*unit,v.probability])
        delta=np.max(abs(np.array(values)-values[0]),axis=0);variance=kappa*mu+sigma*sigma
        standardized=[float(delta[1]*np.sqrt(variance)),float(delta[2]*variance)]
        if delta[0]>1e-10 or max(standardized)>1e-8:raise AssertionError('Lossless measurement-unit conversion changed the likelihood')
        rows.append(dict(code=code,kind=kind,max_absolute_difference_nll_score_curvature_probability=delta.tolist(),
            standardized_score_and_curvature_difference=standardized))
    spatial=[]
    for scale in [1,2,4]:
        h=1/scale;yy,xx=np.mgrid[:8*scale,:8*scale];x=(xx+.5)*h;y=(yy+.5)*h;u=.3+.0002*x*x+.00015*x*y+.0001*y*y
        xxh=(u[1:-1,2:]-2*u[1:-1,1:-1]+u[1:-1,:-2])/h**2;yyh=(u[2:,1:-1]-2*u[1:-1,1:-1]+u[:-2,1:-1])/h**2
        xyh=(u[2:,2:]-u[2:,:-2]-u[:-2,2:]+u[:-2,:-2])/(np.sqrt(8)*h*h)
        mask=(x[1:-1,1:-1]>=2)&(x[1:-1,1:-1]<6)&(y[1:-1,1:-1]>=2)&(y[1:-1,1:-1]<6)
        rho=np.sqrt(1+(xxh**2+xyh**2+yyh**2)/.02**2)-1
        spatial.append(dict(scale=scale,spacing=h,physical_prior_integral=float(np.sum(rho[mask])*h*h),
            physical_hessian_mean=[float(a[mask].mean()) for a in [xxh,xyh,yyh]]))
    if np.ptp([r['physical_prior_integral'] for r in spatial])>1e-12:raise AssertionError('Grid spacing changed the physical polynomial prior')
    out=dict(revision='f5-design-review-units-spacing-v1',camera_used=False,pg_unit_conversion=rows,
        library_sha256=hashlib.sha256(args.library.read_bytes()).hexdigest(),code_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        units=['normalized radiance','black-subtracted DNG units','black-subtracted native-code units'],
        quantization='The full half-code interval and divisor are transformed without flooring native codes.',spacing_control=spatial,
        scope='PG likelihood unit conversion via production C++ primitive and independent physical-prior quadrature. Not a high-resolution image-quality test.')
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(out,indent=2,allow_nan=False));print(args.output)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--library',type=Path,required=True);p.add_argument('--output',type=Path,required=True);run(p.parse_args())
