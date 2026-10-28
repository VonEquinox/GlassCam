"""Frozen cross-frame color-prior experiment derived only from retained RAW.

No truth image or processed Lucky result enters this calculation. The guide is
an empirical prior, never an extra measurement or a certified noise profile.
"""
from pathlib import Path
import argparse
import hashlib
import json

import numpy as np
from scipy import ndimage as ndi

from f5_linear_fusion import radiance
from f5_real_quality import dump, sha


def raw_fingerprint(source):
    return hashlib.sha256(b''.join(np.asarray(f['codes'],dtype='<u2').tobytes() for f in source['frames'])).hexdigest()


def frame_guide(frame,width,height):
    signal,variance,eligible=radiance(frame,width,height)
    yy,xx=np.mgrid[:height,:width];phase=np.asarray(frame['cfa'])[(yy%2)*2+xx%2]
    colors=np.where(phase==0,0,np.where(phase==3,2,1));y,x=np.mgrid[-2:3,-2:3];kernel=1/(1+x*x+y*y)
    signed=[];clipped=[];noise=[]
    for channel in range(3):
        mask=(colors==channel)&eligible;mass=ndi.convolve(mask.astype(float),kernel,mode='reflect')
        signed.append(ndi.convolve(signal*mask,kernel,mode='reflect')/np.maximum(mass,1e-20))
        clipped.append(ndi.convolve(np.maximum(1e-6,signal)*mask,kernel,mode='reflect')/np.maximum(mass,1e-20))
        noise.append(ndi.convolve(variance*mask,kernel**2,mode='reflect')/np.maximum(mass*mass,1e-40))
    return np.stack(signed,axis=-1),np.stack(clipped,axis=-1),np.stack(noise,axis=-1)


def build(source):
    width,height=source['width'],source['height'];columns=(width+7)//8+1;rows=(height+7)//8+1
    yy,xx=np.mgrid[:height,:width];values=[];noises=[];valids=[];indices=[];reference=None
    for f in source['frames']:
        if not f['used']:continue
        value,clipped,noise=frame_guide(f,width,height);dx,dy=f['translation'];x=xx-dx;y=yy-dy
        values.append(np.stack([ndi.map_coordinates(value[...,c],[y,x],order=1,mode='nearest') for c in range(3)],axis=-1))
        # Linear interpolation of marginal variances is a conservative bound
        # for positive interpolation weights with unknown spatial covariance.
        noises.append(np.stack([ndi.map_coordinates(noise[...,c],[y,x],order=1,mode='nearest') for c in range(3)],axis=-1))
        valids.append((x>=2)&(x<=width-3)&(y>=2)&(y<=height-3));indices.append(f['index'])
        if f['index']==source['reference']:reference=(clipped,noise)
    values=np.stack(values);noises=np.stack(noises);valid=np.all(valids,axis=0)
    result=np.zeros((rows,columns,4));result[...,3]=-1;records=[]
    for row in range(rows):
        for col in range(columns):
            y,x=np.mgrid[row*8-4:row*8+4:2,col*8-4:col*8+4:2];y=y.ravel();x=x.ravel()
            inside=(x>=0)&(x<width)&(y>=0)&(y<height);x=x[inside];y=y[inside]
            keep=valid[y,x];x=x[keep];y=y[keep]
            if len(x)<8 or len(values)<2:continue
            v=values[:,y,x];noise=noises[:,y,x]
            weights=1/np.maximum(noise.sum(axis=2).mean(axis=1),1e-20);weights/=weights.sum()
            mean=np.einsum('f,fnc->nc',weights,v).mean(axis=0)
            axis=np.maximum(mean,1e-6);axis/=np.linalg.norm(axis)
            centered=v-v.mean(axis=1,keepdims=True);residual=centered-np.einsum('fnc,c->fn',centered,axis)[...,None]*axis
            individual=np.mean(np.sum(residual**2,axis=2),axis=1)
            phase_noise=np.mean(np.sum(noise*(1-axis*axis),axis=2),axis=1)
            cross=0.;mass=0.
            for i in range(len(v)):
                for j in range(i+1,len(v)):
                    w=weights[i]*weights[j];cross+=w*np.mean(np.sum(residual[i]*residual[j],axis=1));mass+=w
            coherent=max(0.,cross/max(1e-20,mass))
            inconsistent=max(0.,float(weights@(individual-phase_noise))-coherent)
            signal=coherent*coherent/max(coherent+inconsistent,1e-20)
            mean_noise=float(weights**2@phase_noise)
            confidence=(mean_noise/max(mean_noise+signal,1e-20))**2
            result[row,col,:3]=axis;result[row,col,3]=confidence
            old=reference[0][y,x];old_axis=np.maximum(old.mean(axis=0),1e-6);old_axis/=np.linalg.norm(old_axis)
            old_energy=float(np.mean(np.sum(old**2,axis=1)-(old@old_axis)**2))
            old_noise=float(np.mean(np.sum(reference[1][y,x]*(1-old_axis**2),axis=1)))
            old_confidence=min(1,old_noise/max(1e-20,old_energy))**2
            records.append(dict(x=col*8,y=row*8,confidence=confidence,reference_confidence=old_confidence,
                coherent_color_energy=coherent,inconsistent_color_energy=inconsistent,mean_noise=mean_noise,
                signed_mean=mean.tolist(),clipped_reference_mean=old.mean(axis=0).tolist()))
    guide=dict(revision='f5-cross-frame-color-prior-v1',columns=columns,rows=rows,rawSHA256=raw_fingerprint(source),values=result.ravel().tolist())
    return guide,dict(nodes=records,used_frames=indices,qualification='UNQUALIFIED_EMPIRICAL_PRIOR')


def run(args):
    args.output.mkdir(parents=True,exist_ok=True);results=[]
    for path in args.inputs:
        source=json.loads(path.read_text());guide,diagnostic=build(source);source['priorGuide']=guide
        group=path.parent.parent.name;folder=args.output/group/source['name'];folder.mkdir(parents=True,exist_ok=True)
        dump(folder/'input.json',source);dump(folder/'guide.json',diagnostic)
        summary=dict(group=group,scene=source['name'],source_input_sha256=sha(path),derived_input_sha256=sha(folder/'input.json'),
            nodes=len(diagnostic['nodes']),old_confidence=float(np.median([n['reference_confidence'] for n in diagnostic['nodes']])),
            new_confidence=float(np.median([n['confidence'] for n in diagnostic['nodes']])))
        results.append(summary);print(summary,flush=True)
    dump(args.output/'manifest.json',dict(camera_used=False,truth_used=False,method='signed RAW guide and cross-frame color covariance',results=results))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--inputs',type=Path,nargs='+',required=True)
    p.add_argument('--output',type=Path,required=True);run(p.parse_args())
