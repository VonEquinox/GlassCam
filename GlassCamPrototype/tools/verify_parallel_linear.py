"""Validate exact parallel Float export and measure actual 8064x64 strips."""
import ctypes as c
import hashlib,json,statistics,time,subprocess
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
COMMAND=['g++','-std=c++17','-O3','-ffp-contract=off','-fno-fast-math','-pthread','-shared','-fPIC',str(ROOT/'core/hncs.cpp'),'-o',str(ROOT/'build/libhncs_parallel_profile.so')]
def main():
 subprocess.run(COMMAND,check=True);lib=c.CDLL(COMMAND[-1]);fptr=c.POINTER(c.c_float)
 lib.hncs_create_mode.argtypes=[c.c_double,c.c_double,c.c_int,c.c_int];lib.hncs_create_mode.restype=c.c_void_p;lib.hncs_destroy.argtypes=[c.c_void_p]
 serial=lib.hncs_process_linear_rgba;serial.argtypes=[c.c_void_p,fptr,fptr,c.c_size_t];serial.restype=c.c_int
 parallel=lib.hncs_process_linear_rgba_parallel;parallel.argtypes=serial.argtypes+[c.c_uint];parallel.restype=c.c_int
 rng=np.random.default_rng(928);cases=0
 for lstar in (0,1):
  for repro in (0,1):
   for ev,cct in ((-2,2000),(0,5500),(2,10000)):
    ctx=lib.hncs_create_mode(ev,cct,lstar,repro);assert ctx
    try:
     for count in (0,1,13,65535,65536,65539,8064*64):
      x=rng.uniform(-.2,1.2,(count,3)).astype(np.float32);expected=np.empty((count,4),np.float32);actual=np.empty_like(expected)
      args=(ctx,x.ctypes.data_as(fptr),expected.ctypes.data_as(fptr),count);assert serial(*args)==0
      for workers in (1,2,3,4):
       assert parallel(ctx,x.ctypes.data_as(fptr),actual.ctypes.data_as(fptr),count,workers)==0
       assert expected.tobytes()==actual.tobytes();cases+=1
     for workers in (0,5,4294967295):assert parallel(ctx,None,None,0,workers)==-1
     for workers in (1,4):
      assert parallel(ctx,None,None,0,workers)==0
      assert parallel(ctx,None,None,1,workers)==-1
      x=np.zeros((65539,3),np.float32);x[-1,1]=np.nan;out=np.zeros((65539,4),np.float32)
      assert parallel(ctx,x.ctypes.data_as(fptr),out.ctypes.data_as(fptr),len(x),workers)==-1
      assert parallel(ctx,x.ctypes.data_as(fptr),out.ctypes.data_as(fptr),c.c_size_t(-1).value,workers)==-1
    finally:lib.hncs_destroy(ctx)
 assert parallel(None,None,None,0,4)==-1
 rows=[];ctx=lib.hncs_create_mode(0,5500,0,0)
 try:
  for width,height in ((8064,64),(4000,3000)):
   count=width*height;x=rng.random((count,3),dtype=np.float32);expected=np.empty((count,4),np.float32);out=np.empty_like(expected);args=(ctx,x.ctypes.data_as(fptr),out.ctypes.data_as(fptr),count)
   assert serial(ctx,x.ctypes.data_as(fptr),expected.ctypes.data_as(fptr),count)==0;digest=hashlib.sha256(expected).hexdigest()
   samples={n:{'wall_ms':[],'cpu_ms':[]} for n in (1,2,4)}
   for n in samples:assert parallel(*args,n)==0
   # Rotate order per round to reduce fixed-order bias. Only one measurement runs at once.
   for order in ((1,2,4),(4,1,2),(2,4,1),(4,2,1),(1,4,2)):
    for n in order:
     wall=time.perf_counter();cpu=time.process_time();assert parallel(*args,n)==0;cpu=time.process_time()-cpu;wall=time.perf_counter()-wall
     samples[n]['wall_ms'].append(wall*1000);samples[n]['cpu_ms'].append(cpu*1000)
     assert hashlib.sha256(out).hexdigest()==digest
   for n,s in samples.items():s.update(wall_median_ms=statistics.median(s['wall_ms']),cpu_median_ms=statistics.median(s['cpu_ms']))
   rows.append(dict(width=width,height=height,pixels=count,output_sha256=digest,timings=samples));print(json.dumps(rows[-1]),flush=True)
 finally:lib.hncs_destroy(ctx)
 report={'status':'passed','compile_command':COMMAND,'bit_exact_cases':cases,'modes':'legacy/Lstar x standard/reproduction x EV,CCT(-2,2000),(0,5500),(2,10000)','workers_tested':[1,2,3,4],'edge_checks':'zero/null, thread counts, nonfinite in late tile, oversized count','launch_failure':'fallback/join code inspected; launch failure not fault-injected','benchmark':rows,'scope':'Cloud CPU C API only; input/output/context creation excluded, actual thread startup/join included on every invocation. Five rotated-order samples after warm-up. No HEIF encoding, iPhone, Apple compile or48MP measurement.','source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in ('core/hncs.cpp','core/hncs_c.h','ios/GlassCam/HNCSEngine.swift')}}
 (ROOT/'validation/parallel-linear-export.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps({k:v for k,v in report.items() if k!='benchmark'},indent=2))
if __name__=='__main__':main()
