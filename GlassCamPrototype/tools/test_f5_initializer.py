"""Compare the Metal initializer with an independent demosaic implementation."""
from pathlib import Path
import argparse
import json
import subprocess

import numpy as np
from colour_demosaicing import demosaicing_CFA_Bayer_Malvar2004

from f5_lucky_baseline import upsample
from f5_linear_fusion import radiance
from f5_quality_report import read_rgb
from f5_real_quality import dump, sha


def run(args):
    args.output.mkdir(parents=True,exist_ok=True);results=[]
    rng=np.random.default_rng(6102706);w,h=35,33
    patterns={'RGGB':[0,1,2,3],'BGGR':[3,1,2,0],'GRBG':[1,0,3,2],'GBRG':[1,3,0,2]}
    for pattern,cfa in patterns.items():
        yy,xx=np.mgrid[:h,:w];signal=.3+.025*np.sin(xx*.5+yy*.3)+rng.normal(0,.01,(h,w))
        codes=np.rint((signal*3567+528)*4).astype(int)
        frames=[dict(index=i,codes=codes.ravel().tolist(),black=528,whiteScale=3567,exposureRatio=1,kappa=.0001,readSigma=.0005,
            divisor=4,nativeWhite=16380,used=i==1,cfa=cfa,translation=[0,0],
            gain=dict(rows=2,columns=2,originX=0,originY=0,spacingX=1,spacingY=1,values=[1,1.4,2,4])) for i in range(5)]
        source=dict(revision='f5-synthetic-roi-v1',synthetic=True,qualification='UNQUALIFIED_DIAGNOSTIC',name=pattern.lower(),width=w,height=h,
            reference=1,frames=frames,maximumCycles=1,maximumSeconds=90,cardinalInitialization=True,malvarInitialization=True,attemptHigh=False)
        folder=args.output/pattern;folder.mkdir(exist_ok=True);dump(folder/'input.json',source)
        with (folder/'run.log').open('w') as log:
            subprocess.run([str(args.renderer.resolve()),str(folder/'input.json'),str(folder),str(args.shader.resolve())],stdout=log,stderr=subprocess.STDOUT,check=True)
        report,actual=read_rgb(folder/f'{pattern.lower()}-metal-report.json','initial_rgb')
        if report['cardinal_initialization_fraction']!=1:raise AssertionError('Positive initializer unexpectedly needed a feasibility blend')
        values,_,_=radiance(frames[1],w,h)
        expected=upsample(np.maximum(1e-6,demosaicing_CFA_Bayer_Malvar2004(values,pattern)))
        error=float(np.max(abs(actual-expected)))
        if error>2e-6:raise AssertionError(f'{pattern}: wrong CFA, edge stencil, radiometry, or spline conversion ({error})')
        results.append(dict(pattern=pattern,width=w,height=h,maximum_error=error,input_sha256=sha(folder/'input.json')))
        print(pattern,error,flush=True)
    dump(args.output/'results.json',dict(camera_used=False,oracle='colour-demosaicing Malvar2004 plus common bilinear sampling',
        shader_sha256=sha(args.shader),renderer_sha256=sha(args.renderer),results=results))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--renderer',type=Path,required=True)
    p.add_argument('--shader',type=Path,required=True);p.add_argument('--output',type=Path,required=True);run(p.parse_args())
