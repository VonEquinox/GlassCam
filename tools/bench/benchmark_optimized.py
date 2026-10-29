"""Compare exact CPU output against explicitly bounded display-encoding optimization."""
import ctypes as c
import hashlib, json, subprocess, time
import numpy as np
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests/numeric"))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from support import verify_cpp as v
ROOT=v.ROOT

def main():
    output = Path.home() / "Library/Developer/GlassCamDiagnostics/bench"
    output.mkdir(parents=True, exist_ok=True)
    lib=v.library()
    for name in ('hncs_process_srgb_fast','hncs_process_srgb_fast_parallel'):
        f=getattr(lib,name);f.argtypes=lib.hncs_process_srgb.argtypes+([c.c_uint] if name.endswith('parallel') else []);f.restype=c.c_int
    # Re-run final native and source-adapter parity on the code under benchmark.
    verification_command = [sys.executable, '-m', 'pytest', 'tests/numeric/test_native_core.py']
    subprocess.run(verification_command, cwd=ROOT, check=True)
    verification = {'command': verification_command, 'status': 'passed'}
    cases=[];max_diff=0;changed=0;channels=0
    rng=np.random.default_rng(432)
    for cct in (2000,5500,10000):
        for ev in (-2,0,2):
            x=rng.uniform(-.1,1.1,(100001,3)).astype(np.float32)
            exact=np.empty((len(x),4),np.uint8);fast=np.empty_like(exact);parallel=np.empty_like(exact)
            ctx=lib.hncs_create_mode(ev,cct,0,0)
            args=(ctx,x.ctypes.data_as(c.POINTER(c.c_float)))
            assert lib.hncs_process_srgb(*args,exact.ctypes.data_as(c.POINTER(c.c_uint8)),len(x))==0
            assert lib.hncs_process_srgb_fast(*args,fast.ctypes.data_as(c.POINTER(c.c_uint8)),len(x))==0
            for n in (1,2,3,4):
                assert lib.hncs_process_srgb_fast_parallel(*args,parallel.ctypes.data_as(c.POINTER(c.c_uint8)),len(x),n)==0
                np.testing.assert_array_equal(fast,parallel)
            for n in (0,5):assert lib.hncs_process_srgb_fast_parallel(*args,parallel.ctypes.data_as(c.POINTER(c.c_uint8)),len(x),n)==-1
            diff=np.abs(exact[:,:3].astype(int)-fast[:,:3].astype(int))
            assert diff.max()<=1
            max_diff=max(max_diff,int(diff.max()));changed+=int(np.count_nonzero(diff));channels+=diff.size
            lib.hncs_destroy(ctx)
    # Validate the final transfer LUT at every boundary midpoint plus a dense grid.
    table_x=np.arange(65536,dtype=np.float64)/65535
    oetf=lambda x:np.where(x<=.0031308,12.92*x,1.055*np.power(x,1/2.4)-.055)
    table=np.rint(oetf(table_x)*255).astype(int)
    boundaries=(np.arange(65535,dtype=float)+.5)/65535
    x=np.concatenate([np.linspace(0,1,2000001),np.nextafter(boundaries,0),boundaries,np.nextafter(boundaries,1)])
    quant=np.rint(x*65535).astype(int)
    err=np.abs(np.rint(oetf(x)*255).astype(int)-table[quant]);assert err.max()<=1
    for width,height in ((1024,1024),(2048,1536),(4000,3000)):
        x=rng.random((height,width,3),dtype=np.float32);out=np.empty((height,width,4),np.uint8)
        ctx=lib.hncs_create_mode(0,5500,0,0)
        timings={}
        for mode,fn,n in [('exact',lib.hncs_process_srgb,None),('fast_1',lib.hncs_process_srgb_fast,None),('fast_2',lib.hncs_process_srgb_fast_parallel,2),('fast_4',lib.hncs_process_srgb_fast_parallel,4)]:
            args=[ctx,x.ctypes.data_as(c.POINTER(c.c_float)),out.ctypes.data_as(c.POINTER(c.c_uint8)),width*height]+([] if n is None else [n])
            assert fn(*args)==0
            times=[]
            for _ in range(3):
                start=time.perf_counter();assert fn(*args)==0;times.append(time.perf_counter()-start)
            timings[mode]={'median_ms':float(np.median(times)*1000),'p95_ms':float(np.percentile(times,95)*1000),'samples':3,'output_sha256':hashlib.sha256(out.tobytes()).hexdigest()}
        lib.hncs_destroy(ctx)
        for mode in ('fast_1','fast_2','fast_4'):timings[mode]['speedup_vs_exact']=timings['exact']['median_ms']/timings[mode]['median_ms']
        cases.append({'width':width,'height':height,'pixels':width*height,'timings':timings})
    report={'status':'passed','native_core':{k:v for k,v in verification.items() if k!='golden_checks'},'fast_display_max_byte_difference':max_diff,'fast_display_changed_channels':changed,'fast_display_total_compared_channels':channels,'parallel_vs_fast_single':'bit-exact for 1/2/3/4 workers','transfer_boundary_samples':2000001+3*65535,'transfer_boundary_max_byte_difference':int(err.max()),'bound':'Only final linear-sRGB to 8-bit sRGB encoding is approximated; nearest 16-bit linear sample error <=0.5/65535, continuous encoded byte error <=255*12.92*0.5/65535 (~0.0252), rounded byte difference <=1. Original HNCS UInt16 core unchanged.','scope':'warm single invocation C++ CPU stage; decoding, resize, Swift buffers, PNG export, context setup and UI excluded. 3 repetitions provide illustrative timings, not stable hardware characterization.','not_an_iphone_measurement':True,'cases':cases}
    (output/'optimization.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
