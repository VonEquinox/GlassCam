"""Independent controlled detail/color/noise cases for the F5 desktop renderer.

Analytic scenes are sampled independently of the reconstruction spline. The
best-of-four main-frame baseline uses only its chosen frame for GAT/BM3D and
Malvar demosaic. These development cases do not certify real-image superiority.
"""
from pathlib import Path
import argparse
import json
import subprocess
import time

import bm3d
import numpy as np
from scipy import ndimage as ndi, special
from colour_demosaicing import demosaicing_CFA_Bayer_Malvar2004

from f5_lucky_baseline import anscombe, inverse_anscombe, upsample
from f5_real_quality import dump, preview, sha


def scene(x, y, name, transform=None):
    # The effective radiance includes an optical/pixel response independent of
    # B-splines. We measure this effective image, not an unblurred latent scene.
    radius = .36
    if transform is None:
        transform = [1,0,0,0,1,0]
    m00,m01,tx,m10,m11,ty=transform
    u,v=m00*x+m01*y+tx,m10*x+m11*y+ty
    def wave(fx, fy, phase=0):
        native_fx,native_fy=fx*m00+fy*m10,fx*m01+fy*m11
        optical = np.exp(-2*np.pi**2*radius**2*(native_fx*native_fx+native_fy*native_fy))
        pixel = np.sinc(native_fx)*np.sinc(native_fy)
        return optical*pixel*np.sin(2*np.pi*(fx*u+fy*v)+phase)
    light = .32+.12*wave(.19,.03)+.08*wave(.035,.21)+.06*wave(.34,.0)
    if name == "constant_color":
        return light[..., None]*np.array([.65, 1, .8])
    if name == "chromatic_texture":
        return np.stack([.28+.10*wave(.22,.025), .28-.10*wave(.22,.025),
                         .28+.08*wave(.04,.18,.6)], axis=-1)
    if name == "shadow":
        light=.007+.0015*wave(.07,.025)+.001*wave(.025,.09)
        return light[..., None]*np.array([.65, 1, .8])
    if name == "color_edge":
        edge=special.ndtr((u-v*.3-22)/.55)
        a=np.array([.12,.4,.16]);b=np.array([.4,.12,.32])
        return a*(1-edge[...,None])+b*edge[...,None]+.02*wave(.17,.05)[...,None]
    raise ValueError(name)


def main_frame_score(raw, a, b):
    g0,g1=raw[::2,1::2],raw[1::2,::2]
    green=(g0+g1)*.5
    variance=(a*np.maximum(g0,0)+a*np.maximum(g1,0)+2*b)*.25
    y,x=np.mgrid[-3:4,-3:4]
    kernels=[np.exp(-(x*x+y*y)/(2*s*s)) for s in [.35,.7]]
    narrow,broad=[k/k.sum() for k in kernels];band=narrow-broad
    signal=np.maximum(0,ndi.convolve(green,band,mode='reflect')**2-ndi.convolve(variance,band*band,mode='reflect'))
    # The common interior avoids boundary support becoming a selection signal.
    return float(np.mean(signal[4:-4,4:-4]))


def baseline(raw, a, b, strength):
    profile=bm3d.BM3DProfile();profile.num_threads=2
    output=np.empty_like(raw)
    for y in range(2):
        for x in range(2):
            plane=anscombe(raw[y::2,x::2],a,b);normalization=max(1,float(plane.max()))
            filtered=bm3d.bm3d(plane/normalization,strength/normalization,profile=profile)
            output[y::2,x::2]=inverse_anscombe(filtered*normalization,a,b)
    return upsample(demosaicing_CFA_Bayer_Malvar2004(output,"BGGR"))


def prepare(args):
    args.output.mkdir(parents=True,exist_ok=True)
    rng=np.random.default_rng(args.seed);size=args.size
    yy,xx=np.mgrid[:size,:size];cfa=np.array([2,1,1,0])[(yy%2)*2+xx%2]
    shifts=np.array([[.21,.13],[0,0],[-.18,.23],[.37,-.16],[-.28,-.21]])
    kappa=.00010030885;read=.0005210402;scale=3567;black=528;divisor=4
    records=[]
    geometry_rng=np.random.default_rng(args.scene_variant)
    for name in args.scenes:
        folder=args.output/name;folder.mkdir(exist_ok=True)
        transform=[1,0,0,0,1,0]
        if args.scene_variant:
            theta=geometry_rng.uniform(-.18,.18);sx,sy=geometry_rng.uniform(.85,1.05,2)
            transform=[float(sx*np.cos(theta)),float(-sx*np.sin(theta)),float(geometry_rng.uniform(-3,3)),
                       float(sy*np.sin(theta)),float(sy*np.cos(theta)),float(geometry_rng.uniform(-3,3))]
        y,x=np.mgrid[:size*2,:size*2]
        truth=scene((x+.5)/2,(y+.5)/2,name,transform);np.save(folder/'truth.npy',truth)
        inputs=[];raws={};selection=[]
        for i in range(5):
            exposure=.125 if i==2 else 1
            rgb=scene(xx+.5+shifts[i,0],yy+.5+shifts[i,1],name,transform)
            mu=np.take_along_axis(rgb,cfa[...,None],axis=-1)[...,0]*exposure
            measurement=kappa*rng.poisson(mu/kappa)+rng.normal(0,read,mu.shape)
            codes=np.rint((measurement*scale+black)*divisor).clip(0,16380).astype(np.uint16)
            raw=(codes.astype(float)/divisor-black)/scale
            if i!=2:
                raws[i]=raw
                selection.append((main_frame_score(raw,kappa,read*read),i))
            inputs.append(dict(index=i,codes=codes.ravel().astype(int).tolist(),black=black,whiteScale=scale,
                exposureRatio=exposure,kappa=kappa,readSigma=read,divisor=divisor,nativeWhite=16380,used=True,
                cfa=[3,1,2,0],translation=shifts[i].tolist(),gain=dict(rows=1,columns=1,originX=0,originY=0,spacingX=1,spacingY=1,values=[1.])))
        lucky=max(selection)[1]
        # Baselines and fusion use the same physical reference coordinate. The
        # known displacement is a labelled computational control, not measured
        # real-scene registration evidence.
        origin=shifts[lucky].copy()
        truth=scene((x+.5)/2+origin[0],(y+.5)/2+origin[1],name,transform);np.save(folder/'truth.npy',truth)
        for f in inputs:f['translation']=(shifts[f['index']]-origin).tolist()
        record=dict(revision="f5-synthetic-roi-v1",synthetic=True,qualification="UNQUALIFIED_DIAGNOSTIC",
            name=name,width=size,height=size,reference=lucky,frames=inputs,maximumCycles=50,maximumSeconds=90,
            motion_source="known analytic displacement control",scene_generator="analytic Gaussian optical response and pixel sinc, independent PG integer observations",
            scene_transform=transform,lucky_selection="maximum noise-corrected common green DoG energy; no truth used in selection")
        dump(folder/'input.json',record)
        for strength in [.75,1,1.25]:
            image=baseline(raws[lucky],kappa,read*read,strength);path=folder/f'lucky-bm3d-{strength:g}.npy';np.save(path,image)
            sharp=image+.35*(image-ndi.gaussian_filter(image,(1.2,1.2,0)))
            np.save(folder/f'lucky-bm3d-{strength:g}-sharpened.npy',sharp)
        records.append(dict(name=name,lucky_index=lucky,input_sha256=sha(folder/'input.json'),truth_sha256=sha(folder/'truth.npy')))
        print('Prepared',name,flush=True)
    dump(args.output/'manifest.json',dict(synthetic=True,seed=args.seed,scene_variant=args.scene_variant,camera_used=False,cases=records,development_only=True))


def metrics(image, truth):
    border=16
    image=image[border:-border,border:-border];truth=truth[border:-border,border:-border]
    error=image-truth;y=error.mean(axis=-1)
    c1=(error[...,0]-error[...,2])/np.sqrt(2)
    c2=(error[...,0]-2*error[...,1]+error[...,2])/np.sqrt(6)
    low=ndi.gaussian_filter(image,(2,2,0))-ndi.gaussian_filter(truth,(2,2,0))
    return dict(rmse=float(np.sqrt(np.mean(error**2))),luma_rmse=float(np.sqrt(np.mean(y**2))),
        chroma_rmse=float(np.sqrt(np.mean(c1*c1+c2*c2))),lowband_rmse=float(np.sqrt(np.mean(low**2))),
        maximum_error=float(np.max(abs(error))),mean_error=float(error.mean()))


def run(args):
    policies=[dict(name="fixed",parameters=dict(colorGuide=False,lambdaY=.001,lambdaC=.04)),
              dict(name="guided",parameters=dict(colorGuide=True,lambdaY=.001,lambdaC=.04)),
              dict(name="guided_strong",parameters=dict(colorGuide=True,lambdaY=.003,lambdaC=.12))]
    if args.policy:
        policies=json.loads(args.policy.read_text())["policies"]
    allowed={"colorGuide","adaptiveColorGuide","flatPriorBoost","cardinalInitialization","lambdaY","lambdaC","geometryMode","attemptHigh","localDenoise","malvarInitialization","protectFineDetail","localStepLimit","parallelMotion","harmonicPrior","signalNoisePrior","feasibleGradientFallback"}
    for policy in policies:
        if not policy['name'] or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789_-' for c in policy['name']):
            raise ValueError('Unsafe policy name')
        if set(policy['parameters'])-allowed:
            raise ValueError('Policy can change solver settings, not the immutable burst')
    report=dict(synthetic=True,development_only=True,policies=policies,results=[])
    for name in args.scenes:
        folder=args.output/name;source=json.loads((folder/'input.json').read_text());truth=np.load(folder/'truth.npy')
        baselines={p.stem:metrics(np.load(p),truth) for p in folder.glob('lucky*.npy')}
        for policy in policies:
            label=policy['name']
            target=folder/label;target.mkdir(exist_ok=True)
            inputs=source | policy['parameters']
            dump(target/'input.json',inputs);start=time.monotonic()
            with (target/'run.log').open('w') as log:
                result=subprocess.run([str(args.renderer.resolve()),str((target/'input.json').resolve()),str(target.resolve()),str(args.shader.resolve())],stdout=log,stderr=subprocess.STDOUT)
            output=target/f'{name}-metal-report.json'
            row=dict(scene=name,policy=label,status=result.returncode,seconds=time.monotonic()-start,lucky=baselines)
            if output.exists():
                rendered=json.loads(output.read_text());row['stop']=rendered['native_stop']
                row['report_sha256']=sha(output)
                for key,label in [('native_rgb','F5_native'),('denoised_native_rgb','F5_local_denoise')]:
                    if key not in rendered:continue
                    raster=rendered[key];data=target/raster['path']
                    if sha(data)!=raster['sha256']:raise ValueError('Output hash changed')
                    image=np.fromfile(data,dtype='<f4').reshape(raster['height'],raster['width'],4)[...,:3]
                    if not np.isfinite(image).all():raise ValueError('Output is not finite')
                    row[label]=metrics(image,truth)
                    row[label]['negative_components']=int(np.count_nonzero(image<0))
                    preview(image,np.eye(3),target/(label+'-preview.png'),maximum=image.shape[0])
            report['results'].append(row);dump(args.output/'comparison.json',report)
            print(name,policy['name'],{k:row[k]['rmse'] for k in ['F5_native','F5_local_denoise'] if k in row},row.get('stop'),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=['prepare','run'])
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--renderer',type=Path)
    parser.add_argument('--shader',type=Path)
    parser.add_argument('--policy',type=Path,help='Explicit candidate policy JSON; cannot change observations')
    parser.add_argument('--size',type=int,default=64)
    parser.add_argument('--seed',type=int,default=6102701)
    parser.add_argument('--scene-variant',type=int,default=0)
    parser.add_argument('--scenes',nargs='+',default=['constant_color','chromatic_texture','shadow','color_edge'])
    args=parser.parse_args()
    (prepare if args.command=='prepare' else run)(args)
