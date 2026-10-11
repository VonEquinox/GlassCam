"""Reproducible cube export/layout and interpolator smoke checks."""
import ctypes as C,json,subprocess,sys
from pathlib import Path
import numpy as np
from lut_proxy_study import ROOT,decode,de76,lab_d65

def main():
    p=ROOT/'build/lut-proxy-provia17.rgba32f'
    subprocess.run([sys.executable,str(ROOT/'tools/lut_proxy_bake.py'),'--look','PROVIA','--nodes','17','--shaper','srgb','--output',str(p)],check=True)
    meta=json.loads(p.with_suffix(p.suffix+'.json').read_text());v=np.fromfile(p,dtype='<f4').reshape(17,17,17,4)
    assert p.stat().st_size==17**3*16==meta['bytes'];assert np.all(v[...,3]==1);assert np.isfinite(v).all()
    lib=C.CDLL(str(ROOT/'build/lut_proxy.so'));ptr=np.ctypeslib.ndpointer(dtype=np.float32,flags='C_CONTIGUOUS');lib.lut_proxy_create.argtypes=[C.c_char_p,C.c_int];lib.lut_proxy_create.restype=C.c_void_p;lib.lut_proxy_render.argtypes=[C.c_void_p,ptr,ptr,C.c_size_t];lib.lut_proxy_destroy.argtypes=[C.c_void_p]
    c=lib.lut_proxy_create(str(ROOT/'reference_ffcs/implementation/ffcs/data/xh2s').encode(),0);assert c
    vectors=[(0,0,0),(16,0,0),(0,16,0),(0,0,16),(4,7,12),(16,16,16)]
    for r,g,b in vectors:
        x=np.ascontiguousarray(decode(np.array([[r/16,g/16,b/16]],np.float32)),dtype=np.float32);o=np.empty_like(x);assert lib.lut_proxy_render(c,x,o,1);np.testing.assert_array_equal(v[b,g,r,:3],o[0])
    lib.lut_proxy_destroy(c)
    errors={}
    for fn in ['lut_proxy_lookup','lut_proxy_tetra']:
        f=getattr(lib,fn);f.argtypes=[ptr,C.c_int,ptr,ptr,C.c_size_t]
        a=np.linspace(0,1,17,dtype=np.float32);lut=np.stack(np.meshgrid(a,a,a,indexing='ij'),axis=-1).reshape(-1,3);x=np.random.default_rng(7).random((10000,3),dtype=np.float32);o=np.empty_like(x);f(lut,17,x,o,len(x));errors[fn]=float(np.max(np.abs(x-o)));assert errors[fn]<2e-7
    assert de76(np.eye(3,dtype=np.float32),np.eye(3,dtype=np.float32))['max']==0
    np.testing.assert_allclose(lab_d65(np.array([[0,0,0],[1,1,1]],np.float32)),[[0,0,0],[100,0,0]],atol=2e-5)
    result=dict(status='passed',export=meta,checked_rgb_indices=vectors,alpha_one=True,finite=True,identity_random_samples=10000,identity_max_error=errors,lab_black_white_sanity=True)
    (ROOT/'validation/lut-proxy-verification.json').write_text(json.dumps(result,indent=2)+'\n');print('LUT proxy verification passed')
if __name__=='__main__':main()
