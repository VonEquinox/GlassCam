"""Compare the recovered NumPy kernel with the actual arm64 Phocus CPU kernel.

DYLD_FRAMEWORK_PATH=/Volumes/Phocus/Phocus.app/Contents/Frameworks \
  uv run --python 3.12 --with-requirements requirements.txt \
  python work/hncs-pipeline/native_validation.py
Run from the project root on Apple Silicon with the analysed Phocus volume mounted.
"""
import ctypes as c
import json
import sys
from pathlib import Path

import numpy as np

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
import hncs_pipeline as pipeline


class Vec2(c.Structure):
    _fields_=[("x",c.c_double),("y",c.c_double)]


class ScaledLUT(c.Structure):
    _fields_=[("owner",c.c_void_p),("data",c.c_void_p),("width",c.c_int),("height",c.c_int),
              ("stride",c.c_int),("padding",c.c_int),("offset",c.c_double*2),
              ("scale",c.c_double*2),("divisor",c.c_double)]


def main():
    assets=pipeline.load_assets()
    fw=Path("/Volumes/Phocus/Phocus.app/Contents/Frameworks")
    util=c.CDLL(str(fw/"HBUtil.framework/Versions/A/HBUtil"))
    library=c.CDLL(str(fw/"HBRawCorrections.framework/Versions/A/HBRawCorrections"))
    def function(lib,name,types,result=None):
        f=getattr(lib,name);f.argtypes=types;f.restype=result;return f
    create=function(util,"_ZN11Scaled2DLUT12FromCbCrDataEP5sCbCriiiii",[c.c_void_p]+[c.c_int]*5,ScaledLUT)
    lookup=function(util,"_ZNK11Scaled2DLUT6LookupE6CArrayIdLi2EdEb",[c.c_void_p,Vec2,c.c_bool],Vec2)
    ctor=function(library,"_ZN16CColorCorrectionC1Ev",[c.c_void_p])
    destructor=function(library,"_ZN16CColorCorrectionD1Ev",[c.c_void_p])
    pixels=function(library,"_ZN14CVectorMethods24ColorNormalCorrectPixelsEP16CColorCorrectionPtS2_ib",
                    [c.c_void_p,c.c_void_p,c.c_void_p,c.c_void_p,c.c_int,c.c_bool])
    rng=np.random.default_rng(20261002)
    records=[]
    for intent in ("standard","reproduction"):
        for cct in (2000,3050,5550,8543,9100,10000):
            table=np.ascontiguousarray(pipeline.lerp_table(cct,assets["wb_temperatures"],assets["lut_std" if intent=="standard" else "lut_repro"],clamp=False))
            grid=[int(v) for v in assets["grid"]]
            lut=create(table.ctypes.data,*grid)
            assert c.sizeof(lut)==72
            points=rng.uniform(-1.5,3.0,(250,2))
            native=np.array([[value.x,value.y] for point in points for value in [lookup(c.byref(lut),Vec2(*point),True)]])
            python=pipeline.lookup_chroma(points,table,assets["grid"])
            difference=float(np.max(np.abs(native-python)))
            assert difference<1e-12,difference
            correction=c.create_string_buffer(0x298);ctor(correction)
            matrix_in,matrix_out=pipeline.kernel_matrices(cct,assets)
            c.memmove(c.addressof(correction)+0x8,matrix_in.astype("float64").tobytes(),72)
            c.memmove(c.addressof(correction)+0x50,matrix_out.astype("float64").tobytes(),72)
            c.memmove(c.addressof(correction)+0x138,c.byref(lut),72)
            curve=assets["v1_lstar" if intent=="standard" else "pure_lstar"].astype(np.float32)
            pointer=c.c_void_p.from_buffer(correction,0x188).value
            c.memmove(pointer,curve.ctypes.data,curve.nbytes)
            source=rng.integers(0,65536,(3000,3),dtype=np.uint16)
            source[:20]=np.arange(20)[:,None]*3000
            source[20:24]=[[65535,0,0],[0,65535,0],[0,0,65535],[0,0,0]]
            output=np.empty_like(source)
            pixels(None,c.byref(correction),output.ctypes.data,source.ctypes.data,len(source),True)
            python=pipeline.hncs_codes(source.astype(float)/65535,cct,assets,intent)
            code_difference=int(np.max(np.abs(output.astype(int)-python.astype(int))))
            assert code_difference<=1,code_difference
            destructor(correction) # Owns and deletes the native LUT returned by FromCbCrData.
            records.append({"intent":intent,"cct":cct,"lookup_max_abs_error":difference,
                            "pixels":len(source),"uint16_max_difference":code_difference})
            print(records[-1],flush=True)
    # Initialise the real CGradationManager and read the native 65536-entry tables.
    init=function(util,"_ZN17CGradationManager19InitGradationCurvesEv",[c.c_void_p])
    manager_ctor=function(util,"_ZN17CGradationManagerC1E14eFilmCurveType11eCompanding",[c.c_void_p,c.c_int,c.c_int])
    manager=c.create_string_buffer(0x300);manager_ctor(manager,6,2)
    base=c.cast(init,c.c_void_p).value-0x2556c
    curves=[]
    for name,address in [("v1_lstar",0x1794208),("pure_lstar",0x1814208)]:
        native=np.ctypeslib.as_array((c.c_float*65536).from_address(base+address))
        difference=float(np.max(np.abs(native-assets[name].astype(float))))
        assert difference<=1,difference
        curves.append({"curve":name,"entries":65536,"maximum_native_difference":difference})
    result={"lookup_and_pixels":records,"gradation_curves":curves,
            "scope":"Exact native colour-kernel comparison with explicitly supplied matrices, interpolated factory LUTs and curves; not an end-to-end Phocus RAW/TIFF comparison."}
    pipeline.save_json(ROOT/"work/hncs-pipeline/evidence/native_validation.json",result)
    print(json.dumps(result,indent=2))


if __name__=="__main__":main()
