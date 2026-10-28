"""Natural-image synthetic RAW controls, independent of the sinusoid benchmark.

Bundled scikit-image photographs provide scene content, not real RAW ground
truth. Gaussian optics, pixel-area quadrature, CFA sampling and independent
Poisson/read noise generate the observations. Policies are fixed before these
cases are evaluated. Known displacement is a labelled geometry control.
"""
from pathlib import Path
import argparse
import json

import numpy as np
from scipy import ndimage as ndi
from PIL import Image
import skimage

from f5_quality_benchmark import baseline, main_frame_score
from f5_real_quality import dump, sha


def prepare(args):
    args.output.mkdir(parents=True,exist_ok=True)
    data=Path(skimage.__file__).parent/'data';seed=6102705 if args.scene_set=='development' else 6102706;rng=np.random.default_rng(seed)
    if args.scene_set=='development':
        cases=[('portrait','astronaut.png',160,30,.6,.002,'narrow'),('fur','chelsea.png',170,50,.5,.002,'balanced'),
            ('brick','brick.png',170,150,.45,.002,'narrow'),('dark_fur','chelsea.png',170,50,.02,.0005,'balanced')]
    else:
        cases=[('coffee_detail','coffee.png',240,130,.5,.002,'narrow'),('grass_detail','grass.png',160,190,.5,.002,'balanced'),
            ('rocket_edge','rocket.jpg',240,80,.5,.002,'narrow'),('camera_fabric','camera.png',200,180,.5,.002,'balanced')]
    records=[];size=64;yy,xx=np.mgrid[:size,:size];cfa=np.array([2,1,1,0])[(yy%2)*2+xx%2]
    gy,gx=np.mgrid[:size*2,:size*2];nodes,weights=np.polynomial.legendre.leggauss(4)
    kappa=.00010030885;read=.0005210402;scale=3567;black=528;divisor=4
    for name,file,left,top,gain,floor,motion in cases:
        source=data/file;image=np.array(Image.open(source).convert('RGB'),float)/255
        linear=np.where(image<=.04045,image/12.92,((image+.055)/1.055)**2.4)
        if file=='brick.png':linear*=np.array([.8,1,.7])
        optical=ndi.gaussian_filter(linear,(.72,.72,0),mode='reflect')
        coefficients=[ndi.spline_filter(optical[...,c],order=3,mode='reflect') for c in range(3)]
        def field(x,y):
            out=np.zeros((*np.shape(x),3))
            for a,wa in zip(nodes,weights):
                for b,wb in zip(nodes,weights):
                    coordinates=[2*(y+b/2)-.5+top,2*(x+a/2)-.5+left]
                    for c in range(3):out[...,c]+=wa*wb/4*ndi.map_coordinates(coefficients[c],coordinates,order=3,mode='reflect',prefilter=False)
            return floor+gain*out
        shifts=np.array([[.081,.162],[0,0],[.03,.08],[-.104,-.296],[.041,-.156]]) if motion=='narrow' else np.array([[0,0],[.5,0],[.25,.25],[0,.5],[.5,.5]])
        folder=args.output/name;folder.mkdir(exist_ok=True);frames=[];raws={};selection=[]
        for i in range(5):
            exposure=.125 if i==2 else 1;rgb=field(xx+.5+shifts[i,0],yy+.5+shifts[i,1]);mu=np.take_along_axis(rgb,cfa[...,None],axis=-1)[...,0]*exposure
            measured=kappa*rng.poisson(mu/kappa)+rng.normal(0,read,mu.shape)
            codes=np.rint((measured*scale+black)*divisor).clip(0,16380).astype(np.uint16);raw=(codes.astype(float)/divisor-black)/scale
            if i!=2:raws[i]=raw;selection.append((main_frame_score(raw,kappa,read**2),i))
            frames.append(dict(index=i,codes=codes.ravel().astype(int).tolist(),black=black,whiteScale=scale,exposureRatio=exposure,
                kappa=kappa,readSigma=read,divisor=divisor,nativeWhite=16380,used=True,cfa=[3,1,2,0],translation=shifts[i].tolist(),
                gain=dict(rows=1,columns=1,originX=0,originY=0,spacingX=1,spacingY=1,values=[1.])))
        reference=max(selection)[1];origin=shifts[reference].copy()
        for f in frames:f['translation']=(shifts[f['index']]-origin).tolist()
        truth=field((gx+.5)/2+origin[0],(gy+.5)/2+origin[1]);np.save(folder/'truth.npy',truth)
        inputs=dict(revision='f5-synthetic-roi-v1',synthetic=True,qualification='UNQUALIFIED_DIAGNOSTIC',name=name,width=size,height=size,
            reference=reference,frames=frames,maximumCycles=50,maximumSeconds=90,motion_source='known displacement control',
            scene_generator='bundled natural photograph, inverse sRGB, Gaussian optics and 4x4 pixel quadrature',
            scene_source_sha256=sha(source),source_crop_xy=[left,top],scene_scale=gain,scene_floor=floor,
            lucky_selection='maximum noise-corrected common green DoG; no truth used')
        dump(folder/'input.json',inputs)
        for strength in [.75,1,1.25]:
            value=baseline(raws[reference],kappa,read**2,strength);np.save(folder/f'lucky-bm3d-{strength:g}.npy',value)
            sharpened=value+.35*(value-ndi.gaussian_filter(value,(1.2,1.2,0)));np.save(folder/f'lucky-bm3d-{strength:g}-sharpened.npy',sharpened)
        records.append(dict(name=name,source=str(source),source_sha256=sha(source),input_sha256=sha(folder/'input.json'),truth_sha256=sha(folder/'truth.npy'),motion=motion))
        print('Prepared',name,flush=True)
    dump(args.output/'manifest.json',dict(revision='f5-natural-synthetic-v1',synthetic=True,camera_used=False,scene_set=args.scene_set,seed=seed,cases=records,
        limitations=['Natural content simulated through a CFA/noise model; not external real-RAW validation.','No sensor color spectral model or blind preference judgments.']))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--scene-set',choices=['development','extended'],default='development');prepare(p.parse_args())
