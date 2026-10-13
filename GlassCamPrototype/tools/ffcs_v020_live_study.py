"""Diagnostic only: FFCS 0.2 native neutral live cube, public C API oracle.
No assets are registered and no app admission is changed by this script.
"""
from pathlib import Path
import ctypes as C
import hashlib,json,platform,subprocess,sys
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'reference_ffcs/implementation'))
N=65

def encode(x):
    return np.where(x<=.0031308,12.92*x,1.055*np.maximum(x,0)**(1/2.4)-.055)
def decode(x):
    return np.where(x<=.04045,x/12.92,((x+.055)/1.055)**2.4)
def lab(x):
    xyz=x.astype(np.float64)@np.array([[.4124564,.3575761,.1804375],[.2126729,.7151522,.0721750],[.0193339,.1191920,.9503041]]).T/np.array([.95047,1,1.08883])
    d=6/29; f=np.where(xyz>d**3,np.cbrt(xyz),xyz/(3*d*d)+4/29)
    return np.stack([116*f[:,1]-16,500*(f[:,0]-f[:,1]),200*(f[:,1]-f[:,2])],axis=1)
def metrics(a,b):
    diff=np.abs(encode(a.astype(np.float64))-encode(b.astype(np.float64)))
    de=np.linalg.norm(lab(a)-lab(b),axis=1)
    return dict(encoded_max=float(diff.max()),encoded_rmse=float(np.sqrt(np.mean(diff**2))),encoded_pixel_max_p99=float(np.quantile(diff.max(1),.99)),linear_max=float(np.abs(a-b).max()),delta_e76_p99=float(np.quantile(de,.99)),delta_e76_max=float(de.max()))
def lookup(cube,coords):
    """Explicit Float32 trilinear arithmetic, R-fast flat RGBA cube."""
    p=np.clip(coords,0,1).astype(np.float32)*(N-1)
    lo=p.astype(np.int32);hi=np.minimum(lo+1,N-1);f=p-lo.astype(np.float32)
    def at(r,g,b):return cube[(b*N+g)*N+r]
    r,g,b=lo.T;R,G,B=hi.T;fr,fg,fb=(f[:,i,None] for i in range(3))
    c00=at(r,g,b)*(1-fr)+at(R,g,b)*fr
    c10=at(r,G,b)*(1-fr)+at(R,G,b)*fr
    c01=at(r,g,B)*(1-fr)+at(R,g,B)*fr
    c11=at(r,G,B)*(1-fr)+at(R,G,B)*fr
    return (c00*(1-fg)+c10*fg)*(1-fb)+(c01*(1-fg)+c11*fg)*fb

def main():
    from PIL import Image
    from ffcs.pipeline import FFCS,PipelineConfig
    output=ROOT/'validation/ffcs-v020-live-study.json'
    cmd=['g++','-std=c++17','-O3','-ffp-contract=off','-fno-fast-math','-pthread','-shared','-fPIC','core/ffcs.cpp','-lz','-o','build/ffcs_v020_live.so']
    (ROOT/'build').mkdir(exist_ok=True);subprocess.run(cmd,cwd=ROOT,check=True)
    lib=C.CDLL(str(ROOT/'build/ffcs_v020_live.so'));ptr=np.ctypeslib.ndpointer(dtype=np.float32,flags='C_CONTIGUOUS');sz=C.c_size_t;vp=C.c_void_p
    lib.ffcs_create_family_config.argtypes=[C.c_char_p,C.c_char_p,sz,C.c_int,C.c_int,C.c_int,C.c_double,C.c_char_p,sz];lib.ffcs_create_family_config.restype=vp
    lib.ffcs_process_linear_rgb_color_only.argtypes=[vp,ptr,sz,sz,ptr,sz,C.c_char_p,sz]
    lib.ffcs_destroy.argtypes=[vp]
    lib.ffcs_process_linear_rgb.argtypes=[vp,ptr,sz,sz,sz,C.c_float,C.c_uint32,ptr,sz,vp,sz,C.c_char_p,sz]
    rng=np.random.default_rng(20261013)
    boundary=rng.random((40000,3),dtype=np.float32);boundary[np.arange(len(boundary)),np.arange(len(boundary))%3]=rng.choice(np.array([0,1,1e-7,1-1e-7],np.float32),len(boundary))
    saturated=rng.random((40000,3),dtype=np.float32);saturated[np.arange(len(saturated)),np.arange(len(saturated))%3]=0;saturated[np.arange(len(saturated)),(np.arange(len(saturated))+1)%3]=1
    axes=np.concatenate([np.eye(3,dtype=np.float32)[j][None,:]*np.linspace(0,1,8193,dtype=np.float32)[:,None] for j in range(3)])
    probes=dict(random_linear=rng.random((200000,3),dtype=np.float32),random_encoded=decode(rng.random((100000,3),dtype=np.float32)).astype(np.float32),boundary=boundary,saturated=saturated,dark=np.exp(rng.uniform(np.log(1e-8),np.log(.02),(40000,3))).astype(np.float32),gray=np.linspace(0,1,8193,dtype=np.float32)[:,None].repeat(3,axis=1),axes=axes,corners=np.array([(r,g,b) for b in [0,1] for g in [0,1] for r in [0,1]],np.float32))
    x=np.ascontiguousarray(np.concatenate(list(probes.values())));slices={};offset=0
    for key,value in probes.items():slices[key]=slice(offset,offset+len(value));offset+=len(value)
    axis=np.linspace(0,1,N,dtype=np.float32)
    b,g,r=np.meshgrid(axis,axis,axis,indexing='ij');grid=np.stack([r,g,b],-1).reshape(-1,3).copy();nodes=decode(grid.astype(np.float64)).astype(np.float32)
    identity=np.ones((len(grid),4),np.float32);identity[:,:3]=grid
    np.testing.assert_array_equal(lookup(identity,grid),identity)
    np.testing.assert_allclose(lookup(identity,encode(x).astype(np.float32))[:,:3],encode(x),atol=2e-7,rtol=0)
    results=[];err=C.create_string_buffer(1024)
    for name,index in [('PROVIA',0),('ACROS',8)]:
        ctx=lib.ffcs_create_family_config(str(ROOT/'reference_ffcs/implementation/ffcs/data').encode(),b'XH2S',index,1,1,0,1.0,err,1024);assert ctx,err.value
        def oracle(v):
            v=np.ascontiguousarray(v,np.float32);out=np.empty((len(v),4),np.float32)
            assert lib.ffcs_process_linear_rgb_color_only(ctx,v,v.size,len(v),out,out.size,err,1024),err.value
            assert np.all(out[:,3]==1);assert np.isfinite(out).all();return out
        cube=oracle(nodes);np.testing.assert_array_equal(lookup(cube,grid),cube)
        exact=oracle(x);approx=lookup(cube,encode(x).astype(np.float32));stored=approx.astype(np.float16).astype(np.float32)
        # Independent Python public pipeline, not copied stages or private FFCS.
        subset=np.concatenate([probes['random_linear'][:2048],probes['boundary'][:512],probes['dark'][:512],probes['saturated'][:512],probes['axes'][::64],probes['corners']])
        py=FFCS(PipelineConfig(camera='XH2S',simulation=name,input_is_linear=True)).apply(Image.new('RGB',(len(subset),1)),input_pixels=[subset.astype(float).tolist()])
        py_linear=decode(np.array(py.pixels[0],np.float64))
        native_subset=oracle(subset)[:,:3]
        python_metric=metrics(native_subset,py_linear)
        assert python_metric['linear_max']<2e-6,python_metric
        full=np.empty_like(subset);assert lib.ffcs_process_linear_rgb(ctx,subset,subset.size,len(subset),1,0,0,full,full.size,None,0,err,1024),err.value
        np.testing.assert_array_equal(full,native_subset)
        toggles=[]
        for grain,sharp in [(0,0),(0,1),(1,0)]:
            other=lib.ffcs_create_family_config(str(ROOT/'reference_ffcs/implementation/ffcs/data').encode(),b'XH2S',index,grain,sharp,0,1.0,err,1024);assert other
            out=np.empty((len(subset),4),np.float32);assert lib.ffcs_process_linear_rgb_color_only(other,subset,subset.size,len(subset),out,out.size,err,1024),err.value
            np.testing.assert_array_equal(out[:,:3],native_subset);lib.ffcs_destroy(other);toggles.append([grain,sharp])
        invalid=[]
        for val in [np.nan,np.inf,-np.inf,-.0001,1.0001]:
            inp=np.zeros((1,3),np.float32);inp[0,0]=val;out=np.full((1,4),-7,np.float32)
            assert not lib.ffcs_process_linear_rgb_color_only(ctx,inp,3,1,out,4,err,1024);assert np.all(out==-7);invalid.append(str(val))
        rows={}
        for key,sl in {'all':slice(None),**slices}.items():
            rows[key]=dict(float32_output=metrics(approx[sl,:3],exact[sl,:3]),rgba16float_output=metrics(stored[sl,:3],exact[sl,:3]))
        worst=int(np.argmax(np.abs(encode(stored[:,:3].astype(float))-encode(exact[:,:3].astype(float))).max(1)))
        results.append(dict(recipe=dict(camera_family='XH2S',simulation=name,simulation_index=index,apply_reference_adjustments=False,sharpen_radius=1.0,exposure_ev=0,grain_enabled=True,sharpness_enabled=True),cube_sha256=hashlib.sha256(cube.astype('<f4').tobytes()).hexdigest(),cube_bytes=cube.nbytes,python_comparison=dict(samples=len(subset),metrics=python_metric),full_api_bit_exact=True,nodal_bit_exact=True,neutral_toggle_equivalence=toggles,invalid_rejected_before_output=invalid,metrics=rows,worst_encoded_input=x[worst].tolist()))
        lib.ffcs_destroy(ctx)
    paths=['core/ffcs.cpp','core/ffcs_c.h','tools/ffcs_v020_live_study.py','reference_ffcs/implementation/ffcs/pipeline.py','reference_ffcs/implementation/ffcs/data/xh2s/provia.lutz','reference_ffcs/implementation/ffcs/data/xh2s/acros.lutz']
    report=dict(status='measured',reference_revision='c4b3383',contract='FFCS 0.2; XH2S native neutral PROVIA/ACROS only; EV=0; finite linear-sRGB [0,1]; sRGB-shaped 65^3; R-fast RGBA Float32 nodes; Float32 trilinear; final RGBA16Float',method=dict(seed=20261013,probe_counts={k:len(v) for k,v in probes.items()},total_samples=len(x),metrics='Normalized encoded sRGB max/channel RMSE; Lab D65 DeltaE76 p99/max, not CIEDE2000.',oracle='Public ffcs_process_linear_rgb_color_only; independent new Python FFCS.apply and full public native API checked',shaper='Node EOTF evaluated in double then Float32; lookup Float32 OETF, position*(N-1); R-fast index=((B*N+G)*N+R)*4',node_alpha=1,axis_identity_check=True,nodal_samples=N**3,limit='Synthetic CPU holdouts, not a formal uniform bound or camera-JPEG match. Apple GPU arithmetic, CI color handling, actual video, device performance and photographic match untested. No overlay, other family, other look, nonzero EV or HNCS chain admitted.'),environment=dict(platform=platform.platform(),command=cmd),source_sha256={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths},results=results)
    output.write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
    for result in results:print(result['recipe']['simulation'],json.dumps(result['metrics']['all']))
    print(output)
if __name__=='__main__':main()
