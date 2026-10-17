#!/usr/bin/env python3
"""Check dense Standard vectors after the native gradation correction.

The old bare-core/live-cube identity requirement was superseded by original
Phocus behavior. This compares against the explicitly corrected numerical
reference and reports the actual change; it does not approve HNCS live cubes.
"""
import ctypes as c
import hashlib
import json
from pathlib import Path
import subprocess
import numpy as np
import reference_runtime as r
from phocus_binary_reference import presets

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['core/hncs.cpp', 'core/hncs_c.h', 'core/hncs_assets.inc', 'core/hncs_preset_assets.inc',
           'tools/verify_hncs_revision8_live.py', 'tools/phocus_binary_reference.py',
           'tools/reference_runtime.py', 'reference/phocus_presets.py']
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
    # np.indices(...).reshape(...).T is column-major; the C ABI consumes packed
    # RGB triplets. The previous old/new-only check hid this layout mistake.
    nodes=np.ascontiguousarray(np.where(grid<=.04045,grid/12.92,((grid+.055)/1.055)**2.4),dtype=np.float32)
    random=np.random.default_rng(810132).uniform(-.05,1.05,(200003,3)).astype(np.float32)
    results=[];assets=r.assets()
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
                native=r.experimental_adapter(source,kelvin,assets)
                codes=r.hncs_codes(native,kelvin,assets,working_space='legacy')
                corrected,_=presets.apply_post_curves(codes,'standard')
                encoded=r.srgb_from_hncs(corrected,assets,'legacy')
                expected=np.where(encoded<=.04045,encoded/12.92,((encoded+.055)/1.055)**2.4)
                error=float(np.max(abs(out[1][:,:3].astype(float)-expected)))
                assert error<=1e-7,(kelvin,label,error)
                assert np.all(out[1][:,3]==1)
                results.append({'virtual_capture_kelvin':kelvin,'case':label,'pixels':len(source),
                    'maximum_float_error_vs_corrected_reference':error,
                    'changed_channels_from_bare_core':int(np.count_nonzero(out[0]!=out[1])),
                    'maximum_change_from_bare_core':float(np.max(abs(out[0]-out[1]))),
                    'rgba_sha256':hashlib.sha256(out[1].tobytes()).hexdigest()})
        finally:lib.hncs_destroy(old);lib.hncs_destroy(new)
    assert hashes()==before
    report={'status':'pass','scope':'revision9 Standard with original no-adjustment gradation; 65-cubed nodes and independent RGB values; no GPU/live-preview accuracy claim','checks':results,'source_sha256':before,'numpy':np.__version__,'compiler':subprocess.check_output(['g++','--version'],text=True).splitlines()[0],'compile_command':command}
    path=ROOT/'validation/hncs_binary_gradation_dense.json';path.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'status':'pass','pixels':sum(x['pixels'] for x in results),'maximum_float_error':max(x['maximum_float_error_vs_corrected_reference'] for x in results)}))
if __name__=='__main__':main()
