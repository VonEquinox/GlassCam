"""Controlled old/new FFCS kernel experiment, not an end-to-end phone claim."""
import argparse
import ctypes as c
import json
from pathlib import Path
import time

import numpy as np

from audit_x2d_identity import sha
from verify_x2d_color_gain import bind


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline",type=Path,required=True)
    parser.add_argument("--candidate",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    source=np.random.default_rng(20261018).random((1024,1024,3),dtype=np.float32)
    outputs=[np.empty_like(source),np.empty_like(source)]
    apis=[]
    for path in [args.baseline,args.candidate]:
        lib=c.CDLL(str(path.resolve()))
        apis.append((lib,
            bind(lib,"ffcs_create",[c.c_char_p,c.c_size_t,c.c_void_p,c.c_size_t],c.c_void_p),
            bind(lib,"ffcs_destroy",[c.c_void_p],None),
            bind(lib,"ffcs_process_linear_rgb_optimized",[c.c_void_p,c.c_void_p,c.c_size_t,c.c_size_t,c.c_size_t,c.c_float,c.c_uint32,
                 c.c_void_p,c.c_size_t,c.c_void_p,c.c_size_t,c.c_uint,c.c_void_p,c.c_size_t])))
    rows=[]
    for look,index in [("provia",0),("acros",8)]:
        contexts=[];cold=[];error=c.create_string_buffer(1024)
        for _,create,_,_ in apis:
            started=time.perf_counter();ctx=create(str(root/"reference_ffcs/implementation/ffcs/data/xh2s").encode(),index,error,len(error))
            cold.append(time.perf_counter()-started);assert ctx,error.value;contexts.append(ctx)
        try:
            for workers in [1,4]:
                times=[[],[]]
                for run in range(6):
                    for variant in ([0,1] if run%2==0 else [1,0]):
                        started=time.perf_counter()
                        ok=apis[variant][3](contexts[variant],source.ctypes.data,source.size,1024,1024,0.,0,outputs[variant].ctypes.data,source.size,None,0,workers,error,len(error))
                        elapsed=time.perf_counter()-started;assert ok,error.value
                        if run:times[variant].append(elapsed)
                    assert np.array_equal(outputs[0].view(np.uint32),outputs[1].view(np.uint32)),"Candidate changes output bits"
                rows.append({"look":look,"workers":workers,"pixels":1024*1024,"cold_context_seconds":cold,
                             "baseline_seconds":times[0],"candidate_seconds":times[1],
                             "baseline_median":float(np.median(times[0])),"candidate_median":float(np.median(times[1])),
                             "speedup":float(np.median(times[0])/np.median(times[1])),"different_float32_bits":0})
        finally:
            for (_,_,destroy,_),context in zip(apis,contexts):destroy(context)
    report={"status":"bit-exact-on-tested-input","scope":"1MP synthetic pointwise neutral recipes, no RAW decode/HEIF/preview; end-to-end measurements are still required.",
            "method":"One warm-up and five alternating measured runs; identical source, settings, worker count and output requirements.",
            "libraries_sha256":{"baseline":sha(args.baseline),"candidate":sha(args.candidate)},"source_sha256":sha(Path(__file__)),"rows":rows}
    args.output.write_text(json.dumps(report,indent=2)+"\n");print(json.dumps(rows,indent=2))


if __name__=="__main__":main()
