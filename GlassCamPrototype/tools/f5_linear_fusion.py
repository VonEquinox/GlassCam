"""Lightweight native fusion diagnostic with explicit linear noise propagation.

Each frame's finite demosaic and cubic warp are composed before variance is
propagated, so shared RAW samples are counted once. This is a separate, unqualified
estimator experiment: motion uncertainty, occlusions and spatial covariance in
the following DCT stage are not certified by the propagated per-pixel covariance.
"""
from pathlib import Path
import argparse
import json
import time

import numpy as np
from scipy.fft import dctn, idctn
from colour_demosaicing import demosaicing_CFA_Bayer_Malvar2004

from f5_local_dct import OPPONENT, denoise
from f5_lucky_baseline import upsample
from f5_quality_benchmark import metrics
from f5_real_quality import dump, preview, sha


def keys(x):
    x=abs(x)
    return (1.5*x-2.5)*x*x+1 if x<=1 else ((-.5*x+2.5)*x-4)*x+2 if x<2 else 0


def demosaic_kernel(px,py,cfa):
    observed=cfa[(py%2)*2+px%2];observed=0 if observed==0 else 2 if observed==3 else 1
    result=np.zeros((5,5,3));result[2,2,observed]=1
    axes=[(0,2),(2,0),(2,4),(4,2)];cross=[(1,2),(2,1),(2,3),(3,2)];diagonal=[(1,1),(1,3),(3,1),(3,3)]
    if observed!=1:
        result[2,2,1]=.5;result[2,2,2-observed]=.75
        for y,x in axes:result[y,x,1]=-.125;result[y,x,2-observed]=-.1875
        for y,x in cross:result[y,x,1]=.25
        for y,x in diagonal:result[y,x,2-observed]=.25
    else:
        horizontal=0 if cfa[(py%2)*2+(px+1)%2]==0 else 2;vertical=2-horizontal
        result[2,2,horizontal]=result[2,2,vertical]=.625
        for y,x in diagonal:result[y,x,horizontal]=result[y,x,vertical]=-.125
        for y,x in [(2,1),(2,3)]:result[y,x,horizontal]=.5
        for y,x in [(1,2),(3,2)]:result[y,x,vertical]=.5
        for y,x in [(2,0),(2,4)]:result[y,x,horizontal]=-.125;result[y,x,vertical]=.0625
        for y,x in [(0,2),(4,2)]:result[y,x,vertical]=-.125;result[y,x,horizontal]=.0625
    return result


def composed_kernels(translation,cfa):
    dx,dy=-np.asarray(translation);ix,iy=int(np.floor(dx)),int(np.floor(dy));fx,fy=dx-ix,dy-iy
    kernels={}
    for py in range(2):
        for px in range(2):
            weights={}
            for y in range(-1,3):
                for x in range(-1,3):
                    weight=keys(x-fx)*keys(y-fy)
                    if weight==0:continue
                    local=demosaic_kernel(px+ix+x,py+iy+y,cfa)*weight
                    for ky in range(5):
                        for kx in range(5):
                            if not np.any(local[ky,kx]):continue
                            offset=(iy+y+ky-2,ix+x+kx-2)
                            weights[offset]=weights.get(offset,np.zeros(3))+local[ky,kx]
            kernels[py,px]={k:v for k,v in weights.items() if np.any(abs(v)>1e-15)}
    return kernels


def radiance(frame,width,height):
    yy,xx=np.mgrid[:height,:width];g=frame['gain'];values=np.asarray(g['values']).reshape(g['rows'],g['columns'])
    u=np.clip(((xx+.5)/width-g['originX'])/g['spacingX'],0,g['columns']-1)
    v=np.clip(((yy+.5)/height-g['originY'])/g['spacingY'],0,g['rows']-1)
    ix,iy=u.astype(int),v.astype(int);fx,fy=u-ix,v-iy;jx=np.minimum(ix+1,g['columns']-1);jy=np.minimum(iy+1,g['rows']-1)
    gain=((1-fx)*values[iy,ix]+fx*values[iy,jx])*(1-fy)+((1-fx)*values[jy,ix]+fx*values[jy,jx])*fy
    codes=np.asarray(frame['codes']).reshape(height,width)
    signal=(codes/frame['divisor']-frame['black'])/frame['whiteScale'];factor=gain/frame['exposureRatio']
    variance=(frame['kappa']*np.maximum(signal,0)+frame['readSigma']**2)*factor**2
    return signal*factor,variance,(codes>0)&(codes<frame['nativeWhite'])


def aligned_frame(frame,width,height):
    image,variance,eligible=radiance(frame,width,height);kernels=composed_kernels(frame['translation'],frame['cfa'])
    rgb=np.zeros((height,width,3));covariance=np.zeros((height,width,3,3));valid=np.ones((height,width),bool)
    for (py,px),kernel in kernels.items():
        yy,xx=np.mgrid[py:height:2,px:width:2];target=np.s_[py::2,px::2]
        for (dy,dx),weight in kernel.items():
            y,x=yy+dy,xx+dx;inside=(x>=0)&(x<width)&(y>=0)&(y<height);y=np.clip(y,0,height-1);x=np.clip(x,0,width-1)
            valid[target]&=inside&eligible[y,x]
            rgb[target]+=image[y,x,None]*weight
            covariance[target]+=variance[y,x,None,None]*np.outer(weight,weight)
    return rgb,covariance,valid


def opponent_spectrum(frame,variance,temporal_weight,patch=32):
    kernels=composed_kernels(frame['translation'],frame['cfa']);offsets=set().union(*(k.keys() for k in kernels.values()))
    ky,kx=np.mgrid[:patch,:patch]*np.pi/patch;power=np.zeros((patch,patch,3))
    weights={(py,px):float(temporal_weight[py::2,px::2].mean()) for py in range(2) for px in range(2)}
    for py in range(2):
        for px in range(2):
            for sign in [-1,1]:
                response=np.zeros((patch,patch,3),complex)
                for dy,dx in offsets:
                    q=((py-dy)%2,(px-dx)%2);coefficient=kernels[q].get((dy,dx))
                    if coefficient is None:continue
                    value=(OPPONENT@coefficient)*weights[q]
                    response+=np.exp(1j*(kx*dx+sign*ky*dy))[...,None]*value
                power+=float(variance[py::2,px::2].mean())*abs(response)**2/8
    return power


def fuse(source,spectral=False):
    width,height=source['width'],source['height'];reference=source['reference'];frames={}
    for frame in source['frames']:
        if frame['used']:frames[frame['index']]=aligned_frame(frame,width,height)
    total=np.zeros((height,width,3));mass=np.zeros((height,width));noise=np.zeros((height,width,3,3))
    temporal_weights={}
    for index,(rgb,covariance,valid) in frames.items():
        # Fixed radiometric precision, with source-boundary exclusion. This
        # development control deliberately does not claim occlusion rejection.
        luma_variance=np.einsum('i,...ij,j->...',OPPONENT[0],covariance,OPPONENT[0])
        weight=valid/np.maximum(luma_variance,1e-20)
        temporal_weights[index]=weight
        total+=weight[...,None]*rgb;mass+=weight;noise+=weight[...,None,None]**2*covariance
    ref,cov,_=frames[reference];image=np.where(mass[...,None]>0,total/np.maximum(mass[...,None],1e-20),ref)
    covariance=np.where(mass[...,None,None]>0,noise/np.maximum(mass[...,None,None]**2,1e-40),cov)
    opponent=np.einsum('ic,...cd,id->...i',OPPONENT,covariance,OPPONENT)
    power=None
    if spectral:
        power=sum(opponent_spectrum(frame,radiance(frame,width,height)[1],temporal_weights[frame['index']]/np.maximum(mass,1e-20)) for frame in source['frames'] if frame['used'])
        power/=np.maximum(power.mean(axis=(0,1)),1e-30)
    filtered=denoise(image,np.diagonal(covariance,axis1=-2,axis2=-1),patch=32,stride=8,opponent_variance=np.maximum(0,opponent),noise_spectrum=power)
    return image,filtered,covariance


def scalar_dct(image,variance,patch=32,stride=8,threshold=2.7,noise_spectrum=None):
    values=np.pad(image,patch,mode='reflect');noise=np.pad(variance,patch,mode='reflect')
    output=np.zeros_like(values);mass=np.zeros_like(values)
    for y in range(0,values.shape[0]-patch+1,stride):
        for x in range(0,values.shape[1]-patch+1,stride):
            region=np.s_[y:y+patch,x:x+patch];spectrum=dctn(values[region],norm='ortho')
            var=noise[region].mean()*(1 if noise_spectrum is None else noise_spectrum)
            keep=abs(spectrum)>=threshold*np.sqrt(np.maximum(0,var));keep[0,0]=True
            output[region]+=idctn(spectrum*keep,norm='ortho');mass[region]+=1
    return (output/mass)[patch:-patch,patch:-patch]


def fuse_cfa(source,spectral=False):
    width,height=source['width'],source['height'];reference=source['reference'];frames={}
    for f in source['frames']:
        if f['used']:frames[f['index']]=(f,*radiance(f,width,height))
    fused=np.zeros((height,width));filtered=np.zeros_like(fused);noise=np.zeros_like(fused)
    for py in range(2):
        for px in range(2):
            target=np.s_[py::2,px::2];yy,xx=np.mgrid[:height//2,:width//2]
            total=np.zeros(xx.shape);precision=np.zeros(xx.shape);noise_sum=np.zeros(xx.shape);responses=[]
            for index,(f,image,variance,eligible) in frames.items():
                image=image[target];variance=variance[target];eligible=eligible[target]
                dx,dy=-np.array(f['translation'])/2;ix,iy=int(np.floor(dx)),int(np.floor(dy));fx,fy=dx-ix,dy-iy
                value=np.zeros(xx.shape);var=np.zeros(xx.shape);valid=np.ones(xx.shape,bool);spectrum=np.zeros((32,32),complex)
                ky,kx=np.mgrid[:32,:32]*np.pi/32
                for y in range(-1,3):
                    for x in range(-1,3):
                        w=keys(x-fx)*keys(y-fy)
                        if w==0:continue
                        u,v=xx+ix+x,yy+iy+y;valid&=(u>=0)&(u<image.shape[1])&(v>=0)&(v<image.shape[0]);u=np.clip(u,0,image.shape[1]-1);v=np.clip(v,0,image.shape[0]-1)
                        valid&=eligible[v,u];value+=w*image[v,u];var+=w*w*variance[v,u]
                        spectrum+=w*np.exp(-1j*(kx*x+ky*y))
                weight=valid/np.maximum(var,1e-20)
                total+=weight*value;precision+=weight;noise_sum+=weight*weight*var
                responses.append((weight,float(variance.mean()),abs(spectrum)**2))
            mean=np.where(precision>0,total/np.maximum(precision,1e-20),frames[reference][1][target])
            covariance=np.where(precision>0,noise_sum/np.maximum(precision**2,1e-40),frames[reference][2][target])
            power=None
            if spectral:
                power=sum(float(np.mean(w/np.maximum(precision,1e-20)))**2*v*h for w,v,h in responses)
                power/=max(1e-20,float(power.mean()))
            fused[target]=mean;noise[target]=covariance;filtered[target]=scalar_dct(mean,covariance,noise_spectrum=power)
    return demosaicing_CFA_Bayer_Malvar2004(fused,'BGGR'),demosaicing_CFA_Bayer_Malvar2004(filtered,'BGGR'),noise


def run(args):
    args.output.mkdir(parents=True,exist_ok=True);results=[]
    for path in args.inputs:
        source=json.loads(path.read_text());start=time.perf_counter()
        native,filtered,covariance=fuse(source,spectral=args.method=='rgb-spectrum') if args.method.startswith('rgb') else fuse_cfa(source,spectral=args.method=='cfa-spectrum')
        folder=args.output/(path.parent.parent.name+'-'+source['name']);folder.mkdir(exist_ok=True)
        before,after=upsample(native),upsample(filtered)
        for name,a in [('native',before),('filtered',after)]:np.save(folder/(name+'.npy'),a)
        np.save(folder/'covariance.npy',covariance)
        row=dict(name=source['name'],method=args.method,input=str(path),input_sha256=sha(path),seconds=time.perf_counter()-start,
            negative_components=int(np.count_nonzero(after<0)),output=str(folder),qualified=False)
        truth_path=path.parent/'truth.npy'
        if truth_path.exists():
            truth=np.load(truth_path);row['native']=metrics(before,truth);row['filtered']=metrics(after,truth)
            row['lucky']={p.stem:metrics(np.load(p),truth) for p in path.parent.glob('lucky*.npy')}
        results.append(row);print(source['name'],row.get('filtered',{}).get('rmse'),row['seconds'],flush=True)
        dump(args.output/'comparison.json',dict(camera_used=False,qualification='UNQUALIFIED_LINEAR_ESTIMATOR_CONTROL',results=results))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--inputs',nargs='+',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--method',choices=['rgb','rgb-spectrum','cfa','cfa-spectrum'],default='rgb')
    run(p.parse_args())
