"""Independent RAW residual audit of an exported desktop F5 native state.

Residual standardization uses the PG mean/variance, not an exact likelihood.
These fitted residuals are diagnostics, not held-out quality or calibration.
"""
from pathlib import Path
import argparse
import ctypes as C
import hashlib
import json

import numpy as np
from PIL import Image

from f5_lucky_baseline import upsample
from f5_quality_report import read_rgb


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def mirror(x, length):
    x=np.asarray(x)% (2*length)
    return np.where(x<length,x,2*length-x-1)


def basis(x, derivative=False):
    a=np.abs(x)
    if derivative:
        return np.sign(x)*np.where(a<1,(-12*a+9*a*a)/6,np.where(a<2,-(2-a)**2/2,0))
    return np.where(a<1,(4-6*a*a+3*a*a*a)/6,np.where(a<2,(2-a)**3/6,0))


def sample(coefficients,x,y,channel,scale=1,derivatives=False):
    _,height,width=coefficients.shape;x=np.asarray(x)*scale-.5;y=np.asarray(y)*scale-.5
    left=np.floor(x).astype(int)-1;top=np.floor(y).astype(int)-1
    value=np.zeros(np.broadcast_shapes(x.shape,y.shape,np.shape(channel)));dx=np.zeros_like(value);dy=np.zeros_like(value)
    for j in range(4):
        for i in range(4):
            px=left+i;py=top+j;bx=basis(x-px);by=basis(y-py);c=coefficients[channel,mirror(py,height),mirror(px,width)]
            value+=c*bx*by
            if derivatives:
                dx+=c*basis(x-px,True)*by*scale;dy+=c*bx*basis(y-py,True)*scale
    return (value,dx,dy) if derivatives else value


def motion(nodes,x,y):
    rows,cols,_=nodes.shape;u=np.clip(x/32,0,cols-1);v=np.clip(y/32,0,rows-1)
    ix=np.minimum(u.astype(int),cols-2);iy=np.minimum(v.astype(int),rows-2);a=(u-ix)[...,None];b=(v-iy)[...,None]
    return (nodes[iy,ix]*(1-a)+nodes[iy,ix+1]*a)*(1-b)+(nodes[iy+1,ix]*(1-a)+nodes[iy+1,ix+1]*a)*b


def response(frame,x,y,width,height):
    g=frame['gain'];values=np.array(g['values']).reshape(g['rows'],g['columns'])
    u=np.clip((x/width-g['originX'])/g['spacingX'],0,g['columns']-1);v=np.clip((y/height-g['originY'])/g['spacingY'],0,g['rows']-1)
    ix=u.astype(int);iy=v.astype(int);a=u-ix;b=v-iy;jx=np.minimum(ix+1,g['columns']-1);jy=np.minimum(iy+1,g['rows']-1)
    gain=(values[iy,ix]*(1-a)+values[iy,jx]*a)*(1-b)+(values[jy,ix]*(1-a)+values[jy,jx]*a)*b
    return frame['exposureRatio']/gain


def stats(values):
    values=np.asarray(values)
    if not values.size:return dict(count=0)
    return dict(count=int(values.size),mean=float(values.mean()),rms=float(np.sqrt(np.mean(values**2))),
        median=float(np.median(values)),p95_absolute=float(np.quantile(abs(values),.95)),
        fraction_above_3=float(np.mean(abs(values)>3)),fraction_above_5=float(np.mean(abs(values)>5)))


def read_state(path):
    report=json.loads(path.read_text());state=report['native_state'];folder=path.parent
    if state['revision']!='f5-native-state-v1':raise ValueError('Unknown exported state')
    arrays={}
    for key in ['coefficients','motion_nodes','noise','color_axis','gradient','diagonal']:
        if key not in state:continue
        item=state[key];p=(folder/item['path']).resolve()
        if not p.is_relative_to(folder.resolve()) or sha(p)!=item['sha256']:raise ValueError('State content mismatch')
        a=np.fromfile(p,dtype='<f4').reshape(item['shape']).astype(float)
        if not np.all(np.isfinite(a)):raise ValueError('Nonfinite state')
        arrays[key]=a
    source=folder/'input.json'
    if sha(source)!=report['input_sha256']:raise ValueError('State input mismatch')
    return report,json.loads(source.read_text()),arrays


def audit(path,output,library=None):
    output.mkdir(parents=True,exist_ok=True);report,source,arrays=read_state(path)
    state=report['native_state'];width=source['width'];height=source['height'];scale=state['scale'];coefficients=arrays['coefficients']
    yy,xx=np.mgrid[:height,:width];px=xx+.5;py=yy+.5
    native=np.stack([sample(coefficients,px,py,c,scale) for c in range(3)],axis=-1)
    _,gpu=read_rgb(path);output_error=float(np.max(abs(upsample(native)-gpu)))
    if output_error>5e-6:raise AssertionError('Independent spline output differs from rendered native image')
    reference_error=None
    if library:
        lib=C.CDLL(str(library.resolve()));fn=lib.f5_reference_sample
        fn.argtypes=[C.POINTER(C.c_double),C.c_int,C.c_int,C.c_int,C.c_double,C.c_double,C.c_int]+[C.POINTER(C.c_double)]*3;fn.restype=C.c_int
        rng=np.random.default_rng(6102707);qx=rng.uniform(0,width,64);qy=rng.uniform(0,height,64);channels=rng.integers(0,3,64)
        values,dx,dy=sample(coefficients,qx,qy,channels,scale,True);reference_error=0
        for i in range(64):
            a,b,c=C.c_double(),C.c_double(),C.c_double()
            if fn(coefficients.ctypes.data_as(C.POINTER(C.c_double)),width*scale,height*scale,scale,float(qx[i]),float(qy[i]),int(channels[i]),C.byref(a),C.byref(b),C.byref(c)):raise ValueError('Reference sampling failed')
            reference_error=max(reference_error,abs(a.value-values[i]),abs(b.value-dx[i]),abs(c.value-dy[i]))
        if reference_error>1e-10:raise AssertionError('Spline audit differs from independent C++ sample and derivatives')
    records=[];maps={}
    for frame in source['frames']:
        if not frame['used']:continue
        index=frame['index'];codes=np.array(frame['codes']).reshape(height,width)
        phase=np.array(frame['cfa'])[(yy%2)*2+xx%2];channel=np.where(phase==0,0,np.where(phase==3,2,1))
        observed=(codes/frame['divisor']-frame['black'])/frame['whiteScale'];gain=response(frame,px,py,width,height)
        offsets=motion(arrays['motion_nodes'][index],px,py) if index!=source['reference'] else np.zeros((height,width,2))
        mx=px+offsets[...,0];my=py+offsets[...,1];initial=np.array(frame['translation']);ix=px+initial[0];iy=py+initial[1]
        signal,dx,dy=sample(coefficients,mx,my,channel,scale,True);mu=signal*gain
        initial_mu=sample(coefficients,ix,iy,channel,scale)*gain
        variance=frame['kappa']*np.maximum(mu,0)+frame['readSigma']**2+(1/frame['divisor']/frame['whiteScale'])**2/12
        sigma=np.sqrt(variance);residual=(observed-mu)/sigma;initial_residual=(observed-initial_mu)/sigma
        valid=(codes>0)&(codes<frame['nativeWhite'])&(mx>=0)&(mx<=width)&(my>=0)&(my<=height)&(ix>=0)&(ix<=width)&(iy>=0)&(iy<=height)
        interior=valid&(px>=4)&(px<width-4)&(py>=4)&(py<height-4)
        weights=interior& (abs(residual)<5);jacobian=np.stack([dx*gain/sigma,dy*gain/sigma],axis=-1)[weights];z=residual[weights]
        normal=jacobian.T@jacobian;solution=np.linalg.lstsq(normal,jacobian.T@z,rcond=1e-8)[0]
        record=dict(frame=index,reference=index==source['reference'],residual=stats(residual[interior]),
            initial_motion_same_image=stats(initial_residual[interior]),phases={str(p):stats(residual[interior&(phase==p)]) for p in range(4)},
            mean_motion=offsets[interior].mean(axis=0).tolist(),mean_motion_change=(offsets[interior]-initial).mean(axis=0).tolist(),
            motion_extent=np.ptp(offsets[interior],axis=0).tolist(),linearized_translation_correction=solution.tolist(),
            correction_condition=float(np.linalg.cond(normal)),censored=int(np.count_nonzero((codes==0)|(codes>=frame['nativeWhite']))))
        records.append(record);maps[str(index)]=np.where(interior,residual,np.nan)
        vis=np.zeros((height,width,3),np.uint8);q=np.clip(residual/5,-1,1);vis[...,0]=np.rint(np.maximum(q,0)*255).astype(np.uint8);vis[...,2]=np.rint(np.maximum(-q,0)*255).astype(np.uint8);vis[~interior]=24
        Image.fromarray(vis).save(output/f'frame-{index}-residual.png')
    np.savez(output/'residuals.npz',**maps)
    result=dict(revision='f5-native-residual-audit-v1',camera_used=False,qualification='DIAGNOSTIC_NOT_CALIBRATION',name=source['name'],
        report_sha256=sha(path),input_sha256=report['input_sha256'],output_max_error=output_error,cpp_sample_max_error=reference_error,
        native_stop=report['native_stop'],frames=records,limitations=['Fitted RAW residuals are not held-out error or real-image truth.',
            'Gaussian PG mean/variance standardization, not exact quantized mixture likelihood.',
            'Common support excludes a four-pixel source border and censored pixels.',
            'Local shift correction is a linearized diagnostic, not an accepted motion update.'])
    (output/'audit.json').write_text(json.dumps(result,indent=2,allow_nan=False))
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--report',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--library',type=Path)
    a=p.parse_args();r=audit(a.report,a.output,a.library)
    print(r['name'],[(f['frame'],round(f['residual']['rms'],3),np.round(f['mean_motion_change'],3).tolist()) for f in r['frames']])
