"""Recover the declared continuous synthetic scene, before output resampling."""
from pathlib import Path
import hashlib

import numpy as np
from PIL import Image
from scipy import ndimage as ndi
import skimage

from f5_quality_benchmark import scene


def field(source):
    observed=np.array([f['translation'] for f in source['frames']]);reference=source['reference']
    layouts=[np.array([[.21,.13],[0,0],[-.18,.23],[.37,-.16],[-.28,-.21]]),
        np.array([[.081,.162],[0,0],[.03,.08],[-.104,-.296],[.041,-.156]]),
        np.array([[0,0],[.5,0],[.25,.25],[0,.5],[.5,.5]])]
    matches=[x for x in layouts if np.max(abs(x-x[reference]-observed))<1e-10]
    if len(matches)!=1:raise ValueError('The declared synthetic geometry is not recognized')
    origin=matches[0][reference]+np.array(source.get('parent_crop_xy',[0,0]))
    if 'scene_source_sha256' not in source:
        name=source['name'].removesuffix('_patch')
        return lambda x,y:scene(x+origin[0],y+origin[1],name,source.get('scene_transform'))
    directory=Path(skimage.__file__).parent/'data';source_path=None
    for name in ['astronaut.png','chelsea.png','brick.png','coffee.png','grass.png','rocket.jpg','camera.png']:
        p=directory/name
        if p.exists() and hashlib.sha256(p.read_bytes()).hexdigest()==source['scene_source_sha256']:source_path=p;break
    if source_path is None:raise ValueError('The archived natural-scene content was not found')
    image=np.asarray(Image.open(source_path).convert('RGB'),float)/255
    linear=np.where(image<=.04045,image/12.92,((image+.055)/1.055)**2.4)
    if source_path.name=='brick.png':linear*=np.array([.8,1,.7])
    optical=ndi.gaussian_filter(linear,(.72,.72,0),mode='reflect')
    coefficients=[ndi.spline_filter(optical[...,c],order=3,mode='reflect') for c in range(3)]
    nodes,weights=np.polynomial.legendre.leggauss(4);left,top=source['source_crop_xy']
    def evaluate(x,y):
        x=np.asarray(x)+origin[0];y=np.asarray(y)+origin[1];result=np.zeros((*np.broadcast_shapes(x.shape,y.shape),3))
        for a,wa in zip(nodes,weights):
            for b,wb in zip(nodes,weights):
                coordinates=[2*(y+b/2)-.5+top,2*(x+a/2)-.5+left]
                for c in range(3):result[...,c]+=wa*wb/4*ndi.map_coordinates(coefficients[c],coordinates,order=3,mode='reflect',prefilter=False)
        return source['scene_floor']+source['scene_scale']*result
    return evaluate


def undo_known_bilinear(image):
    """Left-invert the archived 2x bilinear map; check reconstruction exactly."""
    height,width,_=image.shape
    if height%2 or width%2:raise ValueError('Expected a common 2x output')
    def matrix(length):
        p=np.clip((np.arange(length*2)+.5)/2-.5,0,length-1);a=p.astype(int);b=np.minimum(a+1,length-1);f=p-a
        u=np.zeros((length*2,length));u[np.arange(length*2),a]+=1-f;u[np.arange(length*2),b]+=f
        return u
    uy=matrix(height//2);ux=matrix(width//2);ly=np.linalg.pinv(uy);lx=np.linalg.pinv(ux)
    native=np.stack([ly@image[...,c]@lx.T for c in range(3)],axis=-1)
    restored=np.stack([uy@native[...,c]@ux.T for c in range(3)],axis=-1)
    error=float(np.max(abs(restored-image)))
    if error>1e-7:raise ValueError('Archived output is not this bilinear map')
    return native,error
