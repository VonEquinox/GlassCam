"""Independent SciPy oracle and tile-boundary checks for the local Metal filter."""
from pathlib import Path
import argparse
import json
import subprocess
import numpy as np

from f5_local_dct import denoise
from f5_real_quality import dump, sha


def run(args):
    args.output.mkdir(parents=True,exist_ok=True)
    rng=np.random.default_rng(6102703);results=[]
    cases=[('identity',67,91,0),('noisy',64,64,1e-4),('tile_boundary',133,160,2e-4),('hdr_constant',47,37,.002)]
    for name,height,width,variance in cases:
        y,x=np.mgrid[:height,:width]
        image=np.stack([.3+.08*np.sin(x*.23+y*.11),.32+.07*np.cos(x*.17-y*.12),.25+.05*np.sin(y*.21)],axis=-1)
        image+=rng.normal(0,np.sqrt(variance),image.shape)
        if name=='hdr_constant':image[:]=[2.2,1.7,.9]
        noise=np.broadcast_to(np.array([.7,1,1.3])*variance,image.shape).copy()
        if name=='tile_boundary':noise*=1+x[...,None]/width
        rgba=np.concatenate([image,np.ones((height,width,1))],axis=-1).astype('<f4')
        variances=np.concatenate([noise,np.zeros((height,width,1))],axis=-1).astype('<f4')
        folder=args.output/name;folder.mkdir(exist_ok=True);rgba.tofile(folder/'image.f32');variances.tofile(folder/'variance.f32')
        expected=denoise(rgba[...,:3],variances[...,:3],patch=32,stride=8)
        outputs=[]
        for tile,stream in [(64,False),(256,False),(64,True),(256,True)]:
            path=folder/f'output-{tile}-{stream}.f32'
            command=[str(args.renderer.resolve()),str(width),str(height),str(folder/'image.f32'),str(folder/'variance.f32'),str(path),str(tile),str(args.shader.resolve())]
            if stream:command.append('stream')
            result=subprocess.run(command,capture_output=True,text=True,check=True)
            report=json.loads(result.stdout);actual=np.fromfile(path,dtype='<f4').reshape(height,width,4)[...,:3]
            error=float(np.max(abs(actual-expected)))
            if not np.isfinite(actual).all() or error>3e-6:raise AssertionError(f'{name}/{tile} differs from independent DCT oracle: {error}')
            if name in ['identity','hdr_constant'] and np.max(abs(actual-rgba[...,:3]))>3e-6:raise AssertionError('DCT changed noise-free radiometry')
            outputs.append(actual);results.append(dict(case=name,max_error=error,**report))
            print(name,tile,'error',error,'seconds',report['seconds'],flush=True)
        if any(not np.array_equal(outputs[0],v) for v in outputs[1:]):raise AssertionError('Tile partition or streaming changed output pixels')
    dump(args.output/'results.json',dict(camera_used=False,oracle='SciPy orthonormal DCT with explicit overlap aggregation',
        shader_sha256=sha(args.shader),renderer_sha256=sha(args.renderer),results=results))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--renderer',type=Path,required=True);p.add_argument('--shader',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    run(p.parse_args())
