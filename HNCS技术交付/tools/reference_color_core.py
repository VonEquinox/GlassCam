"""Independent reference kernel: bundled numeric data, no production imports."""
import numpy as np

def interpolate(k,t,v):
 i=int(np.clip(np.searchsorted(t,k)-1,0,len(t)-2));f=(k-t[i])/(t[i+1]-t[i])
 return v[i]*(1-f)+v[i+1]*f

def extend(lut,grid,expansion):
 l,t,r,b=map(int,expansion);h,w=lut.shape[:2]
 out=np.empty((h+t+b,w+l+r,2),dtype=np.float64);out[t:t+h,l:l+w]=lut
 rows=out[t:t+h];rows[:,:l]=lut[:,:1];rows[:,:l,0]=(lut[:,:1,0]+np.arange(l)[None,:])-l
 rows[:,l+w:]=lut[:,-1:];rows[:,l+w:,0]=((lut[:,-1:,0]+np.arange(l+w,l+w+r)[None,:])-(l+w))+1
 out[:t]=out[t:t+1];out[:t,:,1]=(out[t:t+1,:,1]+np.arange(t)[:,None])-t
 out[t+h:]=out[t+h-1:t+h];out[t+h:,:,1]=((out[t+h-1:t+h,:,1]+np.arange(t+h,t+h+b)[:,None])-(t+h))+1
 cb0,cb1,cr0,cr1,d=grid
 return out,np.array([cb0-l,cb1+r,cr0-t,cr1+b,d])

def render(native,cct,a,space='legacy',intent='standard',curve_name=None,use_lut=True):
 rgb=np.asarray(native,dtype=np.float64)
 if not np.isfinite(rgb).all():raise ValueError('Non-finite RGB')
 k=int(np.clip(int(cct),2000,10000));p=np.rint(np.clip(rgb,0,1)*65535)
 incoming=a['rgb_to_ycbcr']@a['xyz_to_legacy_rgb']@interpolate(k,a['matrix_temperatures'],a['camera_to_xyz'])
 if intent=='reproduction':incoming*=1.7
 working=a['working_rgb_to_xyz'] if space=='lstar' else a['legacy_rgb_to_xyz']
 outgoing=np.linalg.inv(working)@a['legacy_rgb_to_xyz']@np.linalg.inv(a['rgb_to_ycbcr'])
 yuv=p@incoming.T;y=yuv[...,:1];ratio=np.divide(yuv[...,1:],y,out=np.zeros_like(yuv[...,1:]),where=y>0)
 if use_lut:
  lut=interpolate(k,a['wb_temperatures'],a['lut_repro' if intent=='reproduction' else 'lut_std']);grid=a['grid']
  if space=='lstar':lut,grid=extend(lut,grid,a['lut_expansion'])
  cb0,cb1,cr0,cr1,d=grid;pos=np.clip(ratio*d-np.array([cb0,cr0]),0,np.array([cb1-cb0,cr1-cr0]))
  low=np.floor(pos).astype(np.intp);high=np.minimum(low+1,np.array([cb1-cb0,cr1-cr0],dtype=np.intp));f=pos-low;fx,fy=f[...,:1],f[...,1:]
  x0,y0,x1,y1=low[...,0],low[...,1],high[...,0],high[...,1]
  mapped=((lut[y0,x0]*(1-fy)+lut[y1,x0]*fy)*(1-fx)+(lut[y0,x1]*(1-fy)+lut[y1,x1]*fy)*fx)/d
 else:mapped=ratio
 mean=p.mean(axis=-1,keepdims=True);sat=np.divide(np.max(np.abs(p-mean),axis=-1,keepdims=True),mean,out=np.zeros_like(mean),where=mean>0)
 upper,lower=a['gray_thresholds'];weight=np.clip((sat-lower)/(upper-lower),0,1) if upper>lower else np.ones_like(mean)
 if intent=='standard':
  t,amount=a['shadow_desaturation'];c=amount/(t*t);b=-2*c*t;constant=c*t*t+1
  weight=np.maximum(0.,np.minimum(weight,np.where(y<=t,(c*y)*y+b*y+constant,1.)))
 z=y+(y*weight*mapped)@outgoing[:,1:].T;index=np.clip(np.where(y>0,z,0),0,65535).astype(np.intp)
 name=curve_name or (('pure_' if intent=='reproduction' else 'v1_')+('lstar' if space=='lstar' else 'gamma'))
 return a[name][index]
