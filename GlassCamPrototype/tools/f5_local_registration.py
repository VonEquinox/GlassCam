"""Audit small local guide registration with the portable F5 C++ core.

The guides initialize geometry only. Original integer Bayer observations and
their gain-map coordinates are re-cropped without any RAW interpolation.
"""
from pathlib import Path
import argparse
import ctypes as C
import json

import numpy as np
from scipy import ndimage as ndi

from f5_real_quality import dump, load, raw, green_guide, sha


class Guide(C.Structure):
    _fields_=[('rgba',C.POINTER(C.c_float)),('width',C.c_uint32),('height',C.c_uint32),('pixel_size',C.c_double)]


class Result(C.Structure):
    _fields_=[('shift',C.c_double*2)]+[(name,C.c_double) for name in ['cycle_error','maximum_std','residual','normalized_correlation']]+[('samples',C.c_uint64),('reliable',C.c_int)]


def run(args):
    args.output.mkdir(parents=True,exist_ok=True)
    preparation=json.loads(args.preparation.read_text());bundle=Path(preparation['bundle']);_,frames=load(bundle)
    library=C.CDLL(str(args.library.resolve()));fn=library.f5_align_local
    fn.argtypes=[Guide,Guide,C.c_double,C.c_double,C.POINTER(Result)];fn.restype=C.c_int
    guides={};codes={}
    y,x=np.mgrid[-2:3,-2:3];kernel=np.exp(-(x*x+y*y)/(2*.6*.6));kernel/=kernel.sum()
    for i in preparation['used_frames']:
        frame=frames[i]
        if sha(bundle/frame['mosaic']['path'])!=frame['mosaic']['sha256']:raise ValueError('Original bytes changed')
        codes[i],values,_=raw(bundle,frame,preparation['native_to_dng_divisor'])
        g,v=green_guide(frame,values)
        filtered=ndi.convolve(g,kernel,mode='reflect');variance=ndi.convolve(v,kernel**2,mode='reflect')
        guides[i]=np.stack([filtered,variance,np.isfinite(filtered).astype(np.float32),np.ones_like(filtered)],axis=-1)
    reference=preparation['lucky_index'];report=[]
    for roi in preparation['rois']:
        name=roi['name'];size=roi['size'];x,y=roi['x']//2,roi['y']//2
        region=np.s_[y-32:y+size//2+32,x-32:x+size//2+32]
        arrays={i:np.ascontiguousarray(g[region],np.float32) for i,g in guides.items()}
        def desc(a):return Guide(a.ctypes.data_as(C.POINTER(C.c_float)),a.shape[1],a.shape[0],2)
        inputs=json.loads((args.preparation.parent/f'{name}-metal-input.json').read_text())
        inputs.update(lambdaY=.001,lambdaC=.04,colorGuide=True,adaptiveColorGuide=True,flatPriorBoost=256,
                      cardinalInitialization=True,geometryMode='joint',attemptHigh=False,maximumCycles=50,maximumSeconds=90)
        records=[]
        for i in preparation['used_frames']:
            result=Result()
            status=fn(desc(arrays[i]),desc(arrays[reference]),24,.25,C.byref(result))
            if status:raise ValueError('F5 local registration failed')
            shift=np.array(result.shift)
            if i==reference:shift=np.zeros(2)
            accepted=bool(result.reliable) or i==reference
            records.append(dict(index=i,shift_native=shift.tolist(),accepted=accepted,cycle_error=result.cycle_error,
                maximum_std=result.maximum_std,correlation=result.normalized_correlation,samples=result.samples))
            if not accepted:continue
            frame=inputs['frames'][i];origin=np.array([roi['x'],roi['y']]);start=(np.floor((origin-shift)/2)*2).astype(int)
            old=np.array(frame['crop_origin']);x0,y0=start
            if x0<0 or y0<0 or x0+size>codes[i].shape[1] or y0+size>codes[i].shape[0]:raise ValueError('Local crop leaves sensor')
            frame['codes']=codes[i][y0:y0+size,x0:x0+size].ravel().astype(int).tolist()
            frame['translation']=(start+shift-origin).tolist()
            frame['gain']['originX']+=float(old[0]-start[0])/size
            frame['gain']['originY']+=float(old[1]-start[1])/size
            frame['crop_origin']=start.tolist()
        inputs['local_registration']=records
        dump(args.output/f'{name}-input.json',inputs)
        report.append(dict(roi=name,frames=records))
        print(name,[(r['index'],r['accepted'],[round(v,3) for v in r['shift_native']],round(r['maximum_std'],3)) for r in records],flush=True)
    dump(args.output/'registration.json',dict(revision='f5-local-registration-v1',camera_used=False,synthetic=False,
        library_sha256=sha(args.library),preparation_sha256=sha(args.preparation),results=report,
        limitations=['Local guide approximation; final RAW-likelihood and occlusion validation still required.',
                     'Rejected local shifts retain the earlier initialization; they are not replaced with invented zero motion.']))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--preparation',type=Path,required=True)
    p.add_argument('--library',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    run(p.parse_args())
