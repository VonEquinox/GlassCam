"""Tool-only cube export. Does not register assets or enable an app feature."""
import argparse,ctypes as C,hashlib,json,subprocess
from pathlib import Path
import numpy as np
from lut_proxy_study import ROOT,COMMAND,decode

def main():
    p=argparse.ArgumentParser();p.add_argument('--look',choices=['HNCS','PROVIA','ACROS','HNCS_PROVIA','HNCS_ACROS'],required=True);p.add_argument('--nodes',type=int,choices=[17,33,65],required=True);p.add_argument('--shaper',choices=['linear','srgb'],required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    subprocess.run(COMMAND,cwd=ROOT,check=True);lib=C.CDLL(str(ROOT/'build/lut_proxy.so'))
    ptr=np.ctypeslib.ndpointer(dtype=np.float32,flags='C_CONTIGUOUS');vp=C.c_void_p
    lib.hncs_create.argtypes=[C.c_double,C.c_double];lib.hncs_create.restype=vp;lib.hncs_process_linear_rgba.argtypes=[vp,ptr,ptr,C.c_size_t];lib.hncs_destroy.argtypes=[vp]
    lib.lut_proxy_create.argtypes=[C.c_char_p,C.c_int];lib.lut_proxy_create.restype=vp;lib.lut_proxy_render.argtypes=[vp,ptr,ptr,C.c_size_t];lib.lut_proxy_destroy.argtypes=[vp]
    axis=np.linspace(0,1,a.nodes,dtype=np.float32)
    rgb=np.stack(np.meshgrid(axis,axis,axis,indexing='ij'),axis=-1).reshape(-1,3)
    rgb=np.ascontiguousarray(rgb if a.shaper=='linear' else decode(rgb),dtype=np.float32)
    if 'HNCS' in a.look:
        ctx=lib.hncs_create(0,5500);assert ctx;rgba=np.empty((len(rgb),4),np.float32);assert lib.hncs_process_linear_rgba(ctx,rgb,rgba,len(rgb))==0;rgb=rgba[:,:3].copy();lib.hncs_destroy(ctx)
    ff=next((x for x in ['PROVIA','ACROS'] if x in a.look),None)
    if ff:
        ctx=lib.lut_proxy_create(str(ROOT/'reference_ffcs/implementation/ffcs/data/xh2s').encode(),0 if ff=='PROVIA' else 8);assert ctx
        result=np.empty_like(rgb);assert lib.lut_proxy_render(ctx,rgb,result,len(rgb));rgb=result;lib.lut_proxy_destroy(ctx)
    rgba=np.ones((a.nodes,a.nodes,a.nodes,4),np.float32);rgba[...,:3]=rgb.reshape(a.nodes,a.nodes,a.nodes,3)
    # File index = ((B*N + G)*N + R)*4: R fastest, RGBA, alpha 1.
    blob=np.ascontiguousarray(rgba.transpose(2,1,0,3),dtype='<f4').tobytes()
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_bytes(blob)
    meta=dict(look=a.look,nodes=a.nodes,shaper=a.shaper,format='little-endian Float32 RGBA; R fastest, G next, B slowest; alpha=1',input='finite linear-sRGB [0,1]; coordinate = input for linear, sRGB OETF(input) for srgb',output='display-linear sRGB RGB, alpha 1',fixed_parameters=dict(ev=0,hncs_kelvin=5500,hncs_mode='legacy/standard',ffcs_grain=0,ffcs_sharp=0),bytes=len(blob),sha256=hashlib.sha256(blob).hexdigest(),warning='sRGB-shaped cube MUST NOT be used as a plain linear-coordinate CIColorCube. Accuracy study is synthetic and not device certification.')
    a.output.with_suffix(a.output.suffix+'.json').write_text(json.dumps(meta,indent=2)+'\n');print(a.output)
if __name__=='__main__':main()
