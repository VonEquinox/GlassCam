#!/usr/bin/env python3
"""Verify legacy live cube nodes/output stay bit-identical with revision-8 defaults.
This does not execute Core Image/Metal and does not approve new preset cubes.
"""
import ctypes as c
import hashlib
import json
from pathlib import Path
import subprocess
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['core/hncs.cpp', 'core/hncs_c.h', 'core/hncs_assets.inc', 'core/hncs_preset_assets.inc',
           'tools/verify_hncs_revision8_live.py']
def hashes(): return {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in SOURCES}
def main():
    before = hashes()
    libpath = ROOT/'build/libhncs_revision8_live.so'
    libpath.parent.mkdir(exist_ok=True)
    command = ['g++','-std=c++17','-O3','-fno-fast-math','-ffp-contract=off','-pthread','-shared','-fPIC',str(ROOT/'core/hncs.cpp'),'-o',str(libpath)]
    subprocess.run(command, check=True)
    lib=c.CDLL(str(libpath));ptr=c.c_void_p;fp=c.POINTER(c.c_float)
    lib.hncs_create.argtypes=[c.c_double,c.c_double];lib.hncs_create.restype=ptr
    lib.hncs_create_preset.argtypes=[c.c_double,c.c_double,c.c_double,c.c_int,c.c_int,c.c_int,c.c_int,c.c_char_p,c.c_int,ptr,ptr];lib.hncs_create_preset.restype=ptr
    lib.hncs_process_linear_rgba.argtypes=[ptr,fp,fp,c.c_size_t];lib.hncs_destroy.argtypes=[ptr]
    grid=np.indices((65,65,65)).reshape(3,-1).T.astype(np.float64)/64
    nodes=np.where(grid<=.04045,grid/12.92,((grid+.055)/1.055)**2.4).astype(np.float32)
    random=np.random.default_rng(810132).uniform(-.05,1.05,(200003,3)).astype(np.float32)
    results=[]
    for kelvin in (5500,6500):
        old=lib.hncs_create(0,kelvin);new=lib.hncs_create_preset(0,kelvin,0,0,0,4,2,b'standard',1,None,None)
        assert old and new
        try:
            for label,source in [('all_65_cubed_shaped_nodes',nodes),('independent_random_negative_superwhite',random)]:
                out=[]
                for ctx in (old,new):
                    dest=np.empty((len(source),4),np.float32)
                    assert lib.hncs_process_linear_rgba(ctx,source.ctypes.data_as(fp),dest.ctypes.data_as(fp),len(source))==0
                    out.append(dest)
                assert np.array_equal(out[0].view(np.uint32),out[1].view(np.uint32))
                results.append({'virtual_capture_kelvin':kelvin,'case':label,'pixels':len(source),'bit_mismatches':0,'rgba_sha256':hashlib.sha256(out[1].tobytes()).hexdigest()})
        finally:lib.hncs_destroy(old);lib.hncs_destroy(new)
    assert hashes()==before
    report={'status':'pass','scope':'revision8 Standard default versus unchanged legacy constructor; no GPU/new preset accuracy claim','checks':results,'source_sha256':before,'numpy':np.__version__,'compiler':subprocess.check_output(['g++','--version'],text=True).splitlines()[0],'compile_command':command}
    path=ROOT/'validation/hncs_revision8_live_identity.json';path.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'status':'pass','pixels':sum(x['pixels'] for x in results),'bit_mismatches':0}))
if __name__=='__main__':main()
