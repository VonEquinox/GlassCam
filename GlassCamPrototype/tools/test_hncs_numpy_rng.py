#!/usr/bin/env python3
"""Compare self-contained C++ SeedSequence/PCG64/normal stream with NumPy."""
import argparse, ctypes, json, os, pathlib, subprocess, tempfile, time
import numpy as np
from hncs_spatial_evidence import snapshot, environment


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--draws',type=int,default=1000003);ap.add_argument('--output',type=pathlib.Path);args=ap.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1]
    before=snapshot(root)
    started=time.monotonic()
    with tempfile.TemporaryDirectory(prefix='hncs-rng-') as tmp:
        libpath=pathlib.Path(tmp)/'rng.so'
        command=[os.environ.get('CXX','c++'),'-std=c++17','-shared','-fPIC','-O3','-fno-fast-math','-ffp-contract=off','-Wall','-Wextra','-Werror',str(root/'tests/hncs_numpy_rng_bridge.cpp'),'-o',str(libpath)]
        subprocess.run(command,check=True)
        lib=ctypes.CDLL(str(libpath))
        for name in ['hncs_rng_normals','hncs_rng_floats']:getattr(lib,name).argtypes=[ctypes.c_uint64,ctypes.c_size_t,ctypes.c_void_p]
        lib.hncs_rng_seed.argtypes=[ctypes.c_uint64,ctypes.c_void_p]
        seeds=[0,1,2,42,12345,2**32-1,2**32,2**32+1,2**63,2**64-1,0xdeadbeefcafebabe]
        seeds+=np.random.default_rng(91302).integers(0,2**64,size=21,dtype=np.uint64).tolist()
        allseed=seeds+np.random.default_rng(84639).integers(0,2**64,size=10000,dtype=np.uint64).tolist()
        for seed in allseed:
            out=np.empty(4,np.uint64);lib.hncs_rng_seed(seed,out.ctypes.data)
            np.testing.assert_array_equal(out,np.random.SeedSequence(seed).generate_state(4,dtype=np.uint64))
        for seed in seeds:
            out=np.empty(args.draws,np.float64);lib.hncs_rng_normals(seed,args.draws,out.ctypes.data)
            ref=np.random.default_rng(seed).standard_normal(args.draws)
            np.testing.assert_array_equal(out.view(np.uint64),ref.view(np.uint64))
            f32=np.empty(args.draws,np.float32);lib.hncs_rng_floats(seed,args.draws,f32.ctypes.data)
            np.testing.assert_array_equal(f32.view(np.uint32),ref.astype(np.float32).view(np.uint32))
    report={'passed':True,'numpy':np.__version__,'seed_sequence_seeds':len(allseed),'normal_seeds':len(seeds),'double_values':len(seeds)*args.draws,'float32_values':len(seeds)*args.draws,'bit_mismatches':0,'seconds':round(time.monotonic()-started,3)}
    assert snapshot(root)==before, 'Test sources changed during run'
    report.update(environment());report['source_sha256']=before
    if args.output:args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
