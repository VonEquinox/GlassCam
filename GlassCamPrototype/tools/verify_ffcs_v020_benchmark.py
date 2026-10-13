#!/usr/bin/env python3
"""Small cloud-CPU measurement; neutral and overlay are intentionally different math."""
import ctypes as c,json,platform,statistics,time
import numpy as np
import verify_ffcs_v020 as v

def run():
    lib,_,command=v.build();err=c.create_string_buffer(1024);fp=c.POINTER(c.c_float);rows=[]
    for w,h in ((256,144),(1024,1024)):
        data=np.random.default_rng(120).random((h,w,3),dtype=np.float32);output=np.empty_like(data)
        for overlay in (False,True):
            ctx=lib.ffcs_create_family_config(str(v.SOURCE/'implementation/ffcs/data').encode(),b'XH2S',0,1,1,overlay,1,err,len(err));assert ctx,err.value
            times=[]
            try:
                for sample in range(4):
                    start=time.perf_counter();assert lib.ffcs_process_linear_rgb_optimized(ctx,data.ctypes.data_as(fp),data.size,w,h,0,37,output.ctypes.data_as(fp),output.size,None,0,1,err,len(err)),err.value
                    elapsed=time.perf_counter()-start
                    if sample:times.append(elapsed)
                rows.append({'width':w,'height':h,'overlay':overlay,'grain_enabled':True,'sharpen_enabled':True,'radius':1,'workers':1,'samples_seconds':times,'median_seconds':statistics.median(times),'output_sha256':__import__('hashlib').sha256(output.tobytes()).hexdigest()})
            finally:lib.ffcs_destroy(ctx)
    report={'status':'pass','scope':'Linux cloud CPU only; no iPhone latency claim. Neutral and overlay compute intentionally different pixels, not equivalent optimizations.','platform':platform.platform(),'processor':platform.processor(),'source_sha256':v.sha(v.ROOT/'core/ffcs.cpp'),'compile_command':command,'warmups':1,'samples':3,'output':'full float32 linear RGB','measurements':rows}
    (v.V/'ffcs-v020-benchmark.json').write_text(json.dumps(report,indent=2)+'\n');return report
if __name__=='__main__':print(json.dumps(run(),indent=2))
