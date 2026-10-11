"""Offline approximate preview study. Never enables or modifies app paths."""
import ctypes as C
import hashlib,json,platform,subprocess,time
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
FLAGS=['-std=c++17','-O3','-ffp-contract=off','-fno-fast-math','-pthread','-shared','-fPIC']
COMMAND=['g++',*FLAGS,'tools/lut_proxy_oracle.cpp','core/hncs.cpp','-lz','-o','build/lut_proxy.so']

def encode(x): return np.where(x<=.0031308,12.92*x,1.055*np.maximum(x,0)**(1/2.4)-.055)
def decode(x): return np.where(x<=.04045,x/12.92,((x+.055)/1.055)**2.4)
def stats(a,b):
    d=np.abs(a.astype(np.float64)-b.astype(np.float64)); pixel=d.max(axis=1)
    return dict(max_channel=float(d.max()),p95_pixel_max=float(np.quantile(pixel,.95)),p99_pixel_max=float(np.quantile(pixel,.99)),rmse_channel=float(np.sqrt(np.mean(d*d))))
def lab_d65(x):
    # Display-linear sRGB -> CIE XYZ D65 -> CIELAB D65; no adaptation needed.
    m=np.array([[.4124564,.3575761,.1804375],[.2126729,.7151522,.0721750],[.0193339,.1191920,.9503041]])
    xyz=x.astype(np.float64)@m.T / np.array([.95047,1,1.08883])
    d=6/29;f=np.where(xyz>d**3,np.cbrt(xyz),xyz/(3*d*d)+4/29)
    return np.stack([116*f[:,1]-16,500*(f[:,0]-f[:,1]),200*(f[:,1]-f[:,2])],axis=1)
def de76(a,b):
    d=np.linalg.norm(lab_d65(a)-lab_d65(b),axis=1)
    return dict(max=float(d.max()),p95=float(np.quantile(d,.95)),p99=float(np.quantile(d,.99)),mean=float(d.mean()))
def main():
    subprocess.run(COMMAND,cwd=ROOT,check=True);lib=C.CDLL(str(ROOT/'build/lut_proxy.so'))
    ptr=np.ctypeslib.ndpointer(dtype=np.float32,flags='C_CONTIGUOUS');vp=C.c_void_p;sz=C.c_size_t
    lib.lut_proxy_create.argtypes=[C.c_char_p,C.c_int];lib.lut_proxy_create.restype=vp
    lib.lut_proxy_render.argtypes=[vp,ptr,ptr,sz]
    lib.lut_proxy_lookup.argtypes=[ptr,C.c_int,ptr,ptr,sz]
    lib.lut_proxy_tetra.argtypes=lib.lut_proxy_lookup.argtypes
    lib.hncs_create.argtypes=[C.c_double,C.c_double];lib.hncs_create.restype=vp
    lib.hncs_process_linear_rgba.argtypes=[vp,ptr,ptr,sz]
    lib.ffcs_process_linear_rgb.argtypes=[vp,ptr,sz,sz,sz,C.c_float,C.c_uint32,ptr,sz,vp,sz,C.c_char_p,sz]
    lib.lut_proxy_destroy.argtypes=[vp];lib.hncs_destroy.argtypes=[vp]
    assets=ROOT/'reference_ffcs/implementation/ffcs/data/xh2s'
    hn=lib.hncs_create(0,5500);contexts={name:lib.lut_proxy_create(str(assets).encode(),i) for name,i in [('PROVIA',0),('ACROS',8)]}
    assert hn and all(contexts.values())
    def oracle(x,name):
        if 'HNCS' in name:
            rgba=np.empty((len(x),4),np.float32);assert lib.hncs_process_linear_rgba(hn,x,rgba,len(x))==0;x=rgba[:,:3].copy()
        ff=next((k for k in contexts if k in name),None)
        if ff:
            out=np.empty_like(x);assert lib.lut_proxy_render(contexts[ff],x,out,len(x));x=out
        return x
    rng=np.random.default_rng(20261011)
    gray=np.linspace(0,1,8193,dtype=np.float32)[:,None].repeat(3,axis=1)
    boundary=rng.random((20000,3),dtype=np.float32)
    boundary[np.arange(len(boundary)),np.arange(len(boundary))%3]=rng.choice(np.array([0,1,1e-7,1-1e-7],np.float32),len(boundary))
    sat=rng.random((20000,3),dtype=np.float32);sat[np.arange(len(sat)),np.arange(len(sat))%3]=0;sat[np.arange(len(sat)),(np.arange(len(sat))+1)%3]=1
    probes={'random':rng.random((100000,3),dtype=np.float32),'gray':gray,'dark':np.exp(rng.uniform(np.log(1e-7),np.log(.02),(20000,3))).astype(np.float32),'saturated':sat,'boundary':boundary}
    x=np.concatenate(list(probes.values()));slices={};offset=0
    for k,v in probes.items():slices[k]=slice(offset,offset+len(v));offset+=len(v)
    # Independent production serial render with spatial coefficients zero verifies
    # the pointwise extraction. Grain/sharpen are never disabled in real contexts.
    for name,c in contexts.items():
        check=probes['random'][:1000].copy();out=np.empty_like(check);err=C.create_string_buffer(1024)
        assert lib.ffcs_process_linear_rgb(c,check,check.size,1000,1,0,0,out,out.size,None,0,err,1024),err.value
        np.testing.assert_array_equal(out,oracle(check,name))
    results=[]
    for name in ['HNCS','PROVIA','ACROS','HNCS_PROVIA','HNCS_ACROS']:
        exact=oracle(x,name)
        for shaper in ['linear','srgb']:
            coords=np.ascontiguousarray(x if shaper=='linear' else encode(x),dtype=np.float32)
            for size in [17,33,65]:
                axis=np.linspace(0,1,size,dtype=np.float32)
                grid=np.stack(np.meshgrid(axis,axis,axis,indexing='ij'),axis=-1).reshape(-1,3)
                grid=np.ascontiguousarray(grid if shaper=='linear' else decode(grid),dtype=np.float32)
                times=[]
                for _ in range(3):
                    start=time.perf_counter();baked=oracle(grid,name);times.append((time.perf_counter()-start)*1000)
                for storage,interpolation in ([('float32','trilinear'),('float16','trilinear')]+([('float16','tetrahedral')] if shaper=='srgb' and size in [33,65] else [])):
                    lookup_fn=lib.lut_proxy_lookup if interpolation=='trilinear' else lib.lut_proxy_tetra
                    lut=baked if storage=='float32' else baked.astype(np.float16).astype(np.float32)
                    out=np.empty_like(x);lookup=[]
                    for _ in range(4):
                        start=time.perf_counter();lookup_fn(lut,size,coords,out,len(x));lookup.append((time.perf_counter()-start)*1000)
                    # Nodal lookup must reproduce stored values (at representable nodes).
                    if True:
                        nodecoords=np.stack(np.meshgrid(axis,axis,axis,indexing='ij'),axis=-1).reshape(-1,3)
                        nodeout=np.empty_like(lut);lookup_fn(lut,size,nodecoords,nodeout,len(lut));np.testing.assert_array_equal(nodeout,lut)
                    rows={}
                    for category,sl in {'all':slice(None),**slices}.items():
                        rows[category]={'display_linear':stats(out[sl],exact[sl]),'encoded_srgb_float':stats(encode(out[sl]),encode(exact[sl]))}
                        worst=int(np.argmax(np.max(np.abs(encode(out[sl])-encode(exact[sl])),axis=1)))
                        rows[category]['worst_encoded_vector']={'input_linear':x[sl][worst].tolist(),'oracle_linear':exact[sl][worst].tolist(),'proxy_linear':out[sl][worst].tolist()}
                    rows['all']['delta_e76_d65']=de76(out,exact)
                    results.append(dict(look=name,shaper=shaper,nodes=size,storage=storage,interpolation=interpolation,node_storage_max_abs=float(np.max(np.abs(lut-baked))),rgba_texture_bytes=size**3*4*(4 if storage=='float32' else 2),bake_ms=times,lookup_cpu_ms=lookup[1:],metrics=rows))
    paths=['core/hncs.cpp','core/hncs_assets.inc','core/ffcs.cpp','tools/lut_proxy_oracle.cpp','tools/lut_proxy_study.py']
    report=dict(status='passed',domain='finite linear-sRGB RGB [0,1]^3, fixed EV=0, HNCS 5500 K legacy/standard; FFCS direct EV=0; optional HNCS then FFCS chain',output='display-linear sRGB float; supplementary encoded-sRGB float metrics with no integer quantization',method=dict(seed=20261011,probes={k:len(v) for k,v in probes.items()},interpolation='CPU float32 trilinear plus selected tetrahedral comparison, R-major B-fast grid; half stored nodes promoted to float32 before interpolation',spatial='FFCS grain=0 and sharp=0 in tool-private contexts only; full serial production API matches extracted pointwise oracle bit for bit on 1000 colors per FFCS look',shapers='linear or encoded-sRGB coordinates, both evaluate the same linear-sRGB input domain',timing='3 bake calls; lookup warmup plus 3 timed calls; excludes context/asset load, grid generation, quantization, coordinate shaping, allocation, I/O and GPU upload. CPU reference only; not GPU or device measurements',metric='max absolute channel; p95/p99 of per-pixel max absolute RGB channel; per-channel RMSE. DeltaE76 uses standard linear-sRGB to XYZ D65 and Lab D65, no chromatic adaptation; diagnostic only, not DeltaE2000 or a universal visibility threshold. All normalized [0,1].',limits='Synthetic holdouts are not a formal worst-case bound or photographic/camera validation. No GPU filtering arithmetic or camera-match claim.'),environment=dict(platform=platform.platform(),compiler=subprocess.check_output(['g++','--version'],text=True).splitlines()[0],command=COMMAND),source_sha256={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths},asset_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [assets/'provia.lutz',assets/'acros.lutz']},results=results)
    path=ROOT/'validation/lut-proxy-study.json';path.write_text(json.dumps(report,indent=2)+'\n')
    for c in contexts.values():lib.lut_proxy_destroy(c)
    lib.hncs_destroy(hn);print(path)
if __name__=='__main__':main()
