"""Audit subpixel diversity and conditional SR information without using a camera."""
from pathlib import Path
import argparse
import ctypes as C
import json
import time

import numpy as np

from f5_real_quality import dump, sha


class Sample(C.Structure):
    _fields_=[(n,C.c_double) for n in ['x','y','gain','mean','dx','dy','curvature']]+[(n,C.c_uint32) for n in ['color','phase','frame','kind']]


class Result(C.Structure):
    _fields_=[(n,C.c_double) for n in ['minimum','condition','short_information']]+[('motion_rank',C.c_int)]


def samples(shifts, gradients=False):
    result=[]
    for j,frame in enumerate([0,1,3,4]):
        for phase in range(4):
            for k in range(6):
                x=2*((k*5+phase*3)%16)+phase%2+.5+shifts[j][0]
                y=2*((k*7+phase)%16)+phase//2+.5+shifts[j][1]
                dx=.02*np.cos(.3*x+.1*y) if gradients else 0
                dy=.03*np.sin(.1*x-.2*y) if gradients else 0
                result.append(Sample(x,y,1,.3,dx,dy,1e5,[2,1,1,0][phase],phase,frame,0))
    return (Sample*len(result))(*result)


def oracle(values):
    colors=np.array([[1,1,1],[1,0,-1],[1,-2,1]])/np.sqrt([[3],[2],[6]])
    high=np.zeros((len(values),12));nuisance=np.zeros((len(values),20))
    for n,s in enumerate(values):
        weight=np.sqrt(s.curvature)*s.gain
        for c in range(3):
            for axis,position in enumerate([s.x,s.y]):
                i=c*4+axis*2;amplitude=.01*weight*colors[c,s.color]
                high[n,i:i+2]=amplitude*np.array([np.cos(2*np.pi*.65*position),np.sin(2*np.pi*.65*position)])
                nuisance[n,8+i:10+i]=amplitude*np.array([np.cos(2*np.pi*.35*position),np.sin(2*np.pi*.35*position)])
        if s.frame!=1:
            slot=s.frame-int(s.frame>1);nuisance[n,slot*2:slot*2+2]=weight*np.array([s.dx,s.dy])
    nuisance/=np.maximum(np.linalg.norm(nuisance,axis=0),1e-30)
    u,s,_=np.linalg.svd(nuisance,full_matrices=False)
    q=u[:,s>1e-8];residual=high-q@(q.T@high)
    return np.linalg.eigvalsh(residual.T@residual)


def phase_gram(shifts):
    shifts=np.array(shifts)
    design=np.exp(2j*np.pi*shifts@np.array([[0,0],[1,0],[0,1],[1,1]]).T)
    eigen=np.linalg.eigvalsh(design.conj().T@design/len(shifts))
    return dict(eigenvalues=eigen.tolist(),condition=float(eigen[-1]/eigen[0]) if eigen[0]>1e-12 else None,
                weakest_to_uniform_information=float(max(0,eigen[0])))


def run(args):
    library=C.CDLL(str(args.library.resolve()));fn=library.f5_information
    fn.argtypes=[C.POINTER(Sample),C.c_size_t,C.c_double,C.c_int,C.POINTER(Result)];fn.restype=C.c_int
    controls={'identical':[[0,0]]*4,'integer_only':[[0,0],[1,0],[0,1],[1,1]],
        'one_axis':[[0,0],[0,.2],[0,.4],[0,.6]],'balanced_half_pixel':[[0,0],[.5,0],[0,.5],[.5,.5]]}
    registration=json.loads(args.registration.read_text())
    for roi in registration['results']:
        if roi['roi'] in ['texture_left','texture_right']:
            controls[roi['roi']]=[f['shift_native'] for f in roi['frames'] if f['accepted']]
    results=[]
    for name,shifts in controls.items():
        for gradients in [False,True]:
            values=samples(shifts,gradients);r=Result()
            if fn(values,len(values),.01,1,C.byref(r)):raise AssertionError('C++ information calculation failed')
            eigen=oracle(values);error=abs(r.minimum-eigen[0])
            if error>2e-7*max(1,float(eigen[-1])):raise AssertionError(f'{name} differs from independent SVD oracle: {error}')
            results.append(dict(name=name,motion_nuisance=gradients,minimum=r.minimum,condition=r.condition,
                motion_rank=r.motion_rank,svd_oracle_absolute_error=error,
                shift_span_native=np.ptp(shifts,axis=0).tolist(),monochrome_2x_phase_gram=phase_gram(shifts)))
    start=time.perf_counter()
    for _ in range(1000):fn(values,len(values),.01,1,C.byref(r))
    timing=(time.perf_counter()-start)/1000
    report=dict(revision='f5-sampling-diversity-audit-v1',camera_used=False,library_sha256=sha(args.library),
        registration_sha256=sha(args.registration),results=results,seconds_per_96_sample_diagnostic=timing,
        limitations=['Real shifts are local guide estimates, not measured OIS actuator positions.',
            'The 4x4 phase Gram is an ideal monochrome sampling model, not a Bayer reconstruction quality score.',
            'Information comparisons use identical synthetic curvature and gradients to isolate sampling geometry.',
            'The 0.35/0.65 frequency pair is a necessary alias check, not a certificate over all frequencies.'])
    dump(args.output,report)
    for r in results:
        if not r['motion_nuisance']:print(r['name'],'conditional information',r['minimum'],'phase condition',r['monochrome_2x_phase_gram']['condition'])
    print('Seconds per local diagnostic',timing)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True);p.add_argument('--registration',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    run(p.parse_args())
