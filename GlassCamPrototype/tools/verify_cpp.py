"""Build and validate the portable C++ kernel against original supplied goldens."""
import ctypes as c
import hashlib, json, os, platform, subprocess, time
from pathlib import Path
import numpy as np
import reference_runtime as r
ROOT=r.ROOT
BUILD=ROOT/'build'; BUILD.mkdir(exist_ok=True)
LIB=BUILD/'libhncs.so'
COMMAND=['g++','-std=c++17','-O3','-ffp-contract=off','-fno-fast-math','-pthread','-shared','-fPIC',str(ROOT/'core/hncs.cpp'),'-o',str(LIB)]

def library():
    subprocess.run(COMMAND,check=True)
    lib=c.CDLL(str(LIB))
    lib.hncs_create_mode.argtypes=[c.c_double,c.c_double,c.c_int,c.c_int];lib.hncs_create_mode.restype=c.c_void_p
    lib.hncs_destroy.argtypes=[c.c_void_p]
    lib.hncs_render_native.argtypes=[c.c_void_p,c.POINTER(c.c_double),c.POINTER(c.c_uint16),c.c_size_t];lib.hncs_render_native.restype=c.c_int
    lib.hncs_process_srgb.argtypes=[c.c_void_p,c.POINTER(c.c_float),c.POINTER(c.c_uint8),c.c_size_t];lib.hncs_process_srgb.restype=c.c_int
    return lib

def native(lib,pixels,cct,space='legacy',intent='standard'):
    x=np.ascontiguousarray(pixels,dtype=np.float64); out=np.empty(x.shape,dtype=np.uint16)
    context=lib.hncs_create_mode(0,cct,int(space=='lstar'),int(intent=='reproduction'))
    assert context
    try:
        status=lib.hncs_render_native(context,x.ctypes.data_as(c.POINTER(c.c_double)),out.ctypes.data_as(c.POINTER(c.c_uint16)),x.size//3)
        if status: raise ValueError('Native C ABI error '+str(status))
    finally: lib.hncs_destroy(context)
    return out

def srgb(lib,x,cct=5500,ev=0):
    x=np.ascontiguousarray(x,dtype=np.float32);out=np.empty((*x.shape[:-1],4),dtype=np.uint8)
    ctx=lib.hncs_create_mode(ev,cct,0,0)
    assert ctx
    try:
        status=lib.hncs_process_srgb(ctx,x.ctypes.data_as(c.POINTER(c.c_float)),out.ctypes.data_as(c.POINTER(c.c_uint8)),x.size//3)
        if status:raise ValueError('Display C ABI error '+str(status))
    finally:lib.hncs_destroy(ctx)
    return out

def verify(lib):
    a=r.assets();checks=[];pixels=0
    with np.load(r.REFERENCE/'work/hncs-phocus-audit/evidence/native_kernel_vectors.npz',allow_pickle=False) as v:
        for key in v.files:
            if not key.endswith('_source'):continue
            space,intent,cct,_=key.split('_')
            src=v[key].astype(float)/65535; expected=v[key.replace('_source','_output')]
            out=native(lib,src,int(cct),space,intent)
            np.testing.assert_array_equal(out,expected)
            pixels+=len(src);checks.append({'key':key,'pixels':len(src),'max_code_difference':0})
    rng=np.random.default_rng(928)
    random=np.concatenate([rng.uniform(-.2,1.2,(8000,3)),np.repeat((np.arange(256)+.5)[:,None]/65535,3,axis=1),np.array([[0,0,0],[1,1,1],[-1,-1,-1],[2,2,2]])])
    random_comparisons=0
    for space in ('legacy','lstar'):
        for intent in ('standard','reproduction'):
            for cct in (1000,2000,2400,2716,3050,5500,7625,10000,15000):
                expected=r.reference.render(random,cct,a,space,intent)
                np.testing.assert_array_equal(native(lib,random,cct,space,intent),expected)
                random_comparisons+=random.size
    image=rng.uniform(0,1,(103,97,3)).astype(np.float32)
    display_max=0
    for cct in (2000,5500,10000):
        for ev in (-2,0,2):
            expected=np.uint8(np.rint(r.effect(image,cct,a,ev)*255))
            actual=srgb(lib,image,cct,ev)
            diff=int(np.abs(actual[...,:3].astype(int)-expected.astype(int)).max())
            assert diff<=1,(cct,ev,diff)
            display_max=max(display_max,diff)
            assert np.all(actual[...,3]==255)
    full=srgb(lib,image)
    tiled=np.concatenate([srgb(lib,part) for part in np.array_split(image,11)])
    np.testing.assert_array_equal(full,tiled)
    for bad in (float('nan'),float('inf')):
        assert not lib.hncs_create_mode(0,bad,0,0)
        with np.testing.assert_raises(ValueError):native(lib,[[bad,0,0]],5500)
        with np.testing.assert_raises(ValueError):srgb(lib,[[bad,0,0]])
    assert not lib.hncs_create_mode(0,5500,2,0)
    assert lib.hncs_render_native(None,None,None,0)==-1
    ctx=lib.hncs_create_mode(0,5500,0,0)
    assert lib.hncs_render_native(ctx,None,None,0)==0
    assert lib.hncs_render_native(ctx,None,None,1)==-1
    lib.hncs_destroy(ctx)
    return {'status':'passed','original_golden_groups':len(checks),'original_golden_pixels':pixels,'original_max_code_difference':0,'additional_random_boundary_channel_comparisons':random_comparisons,'additional_native_max_code_difference':0,'display_adapter_max_uint8_difference':display_max,'display_tolerance_uint8':1,'tile_equivalence':'bit-exact','nonfinite_null_and_invalid_mode':'passed','golden_checks':checks}

def benchmark(lib):
    rng=np.random.default_rng(884)
    rows=[]
    # Context setup excluded from steady-state timing and measured separately.
    starts=[]
    for _ in range(7):
        t=time.perf_counter();ctx=lib.hncs_create_mode(0,5500,0,0);starts.append(time.perf_counter()-t);lib.hncs_destroy(ctx)
    for width,height in ((1024,1024),(2048,1536),(4000,3000)):
        x=rng.random((height,width,3),dtype=np.float32);out=np.empty((height,width,4),dtype=np.uint8)
        ctx=lib.hncs_create_mode(0,5500,0,0)
        def run():
            result=lib.hncs_process_srgb(ctx,x.ctypes.data_as(c.POINTER(c.c_float)),out.ctypes.data_as(c.POINTER(c.c_uint8)),width*height)
            assert result==0
        run();times=[]
        for _ in range(5):
            start=time.perf_counter();run();times.append(time.perf_counter()-start)
        lib.hncs_destroy(ctx)
        rows.append({'width':width,'height':height,'pixels':width*height,'samples':5,'median_ms':float(np.median(times)*1000),'p95_ms':float(np.percentile(times,95)*1000),'megapixels_per_second':float(width*height/1e6/np.median(times)),'input_output_bytes':int(x.nbytes+out.nbytes),'output_sha256':hashlib.sha256(out.tobytes()).hexdigest()})
    return {'scope':'single-thread fused CPU kernel including experimental source bridge and sRGB encoding; decode, resize, Swift copies, PNG encoding and UI excluded','not_an_iphone_measurement':True,'context_setup_median_ms':float(np.median(starts)*1000),'rows':rows}

def main():
    lib=library();report=verify(lib);report['benchmark']=benchmark(lib)
    report['environment']={'platform':platform.platform(),'machine':platform.machine(),'python':platform.python_version(),'numpy':np.__version__,'compiler':subprocess.check_output(['g++','--version'],text=True).splitlines()[0],'build_command':'g++ -std=c++17 -O3 -ffp-contract=off -fno-fast-math -pthread -shared -fPIC core/hncs.cpp -o build/libhncs.so','cpu':next((l.split(':',1)[1].strip() for l in Path('/proc/cpuinfo').read_text().splitlines() if l.startswith('model name')),'unknown')}
    (ROOT/'validation/cpp-verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='golden_checks'},indent=2))
if __name__=='__main__':main()
