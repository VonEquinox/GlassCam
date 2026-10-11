"""Parse the real plist with Phocus's CXMLLut and evaluate native interpolation.

Requires the verified arm64 4.2.2 frameworks. Does not inject Python matrices
or LUT values into the native object. ABI sizes come from the saved disassembly.
"""
import ctypes as c
import json
import sys
from pathlib import Path
import numpy as np

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
import hncs_pipeline as h

FRAMEWORK_HASHES={
    'HBUtil':'0786d740ad4d6455ee5c5a0d53339f960deabc32b931ecff3186719d627dcf1c',
    'HBRawCorrections':'887d4c3823362c5e89ae3fb14939b85eb5fe85db60913c9d99836ad007c636f0',
    'HBImageProcessing':'125dd5b0bf0cc1ad00d1cf959eeeea82aa24acee117c2b2bcb55fa44f430d010',
    'HBStorage':'c311cedfe841f757a3154713f24e08de1601f0ad6a57d601c25e21cd1ce87826',
}


def verified_framework(name):
    path=Path('/Volumes/Phocus/Phocus.app/Contents/Frameworks')/f'{name}.framework/Versions/A/{name}'
    if h.digest(path)!=FRAMEWORK_HASHES[name]:
        raise ValueError(f'Unrecognised Phocus binary: {path}')
    return path


class LUT(c.Structure):
    _fields_=[('owner',c.c_void_p),('data',c.c_void_p),('width',c.c_int),('height',c.c_int),
              ('stride',c.c_int),('padding',c.c_int),('offset',c.c_double*2),
              ('scale',c.c_double*2),('divisor',c.c_double)]


def main():
    util=c.CDLL(str(verified_framework('HBUtil')))
    raw=c.CDLL(str(verified_framework('HBRawCorrections')))
    cf=c.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    def fn(lib,name,args,ret=None):
        f=getattr(lib,name);f.argtypes=args;f.restype=ret;return f
    data_create=fn(cf,'CFDataCreate',[c.c_void_p,c.c_void_p,c.c_long],c.c_void_p)
    parse=fn(cf,'CFPropertyListCreateWithData',[c.c_void_p,c.c_void_p,c.c_ulong,c.c_void_p,c.c_void_p],c.c_void_p)
    release=fn(cf,'CFRelease',[c.c_void_p])
    payload=(ROOT/'work/hncs-phocus-correction/evidence/colormaps_plain/bohnjuhtuvuvtxyydb56.bin').read_bytes()
    buf=c.create_string_buffer(payload);data=data_create(None,buf,len(payload));dictionary=parse(None,data,0,None,None)
    if not dictionary:raise ValueError('Native plist parser failed')
    coder=c.create_string_buffer(0x20)
    fn(util,'_ZN12CKeyCoderMacC1EP14__CFDictionaryb',[c.c_void_p,c.c_void_p,c.c_bool])(coder,dictionary,False)
    config=c.create_string_buffer(0x330)
    fn(raw,'_ZN7CXMLLutC1Ev',[c.c_void_p])(config)
    fn(raw,'_ZN7CXMLLut10DecodeFromEP9CKeyCoder',[c.c_void_p,c.c_void_p])(config,coder)
    calculate_matrix=fn(raw,'_ZNK7CXMLLut15CalculateMatrixEPdi',[c.c_void_p,c.c_void_p,c.c_int])
    calculate_lut=fn(raw,'_ZNK7CXMLLut12CalculateLUTEib',[c.c_void_p,c.c_int,c.c_bool],LUT)
    delete=fn(util,'_ZdaPv',[c.c_void_p])
    assets=h.load_assets();records=[]
    for temperature in (1000,2000,2400,3050,4000,5550,7000,8543,9100,10000,11000):
        matrix=np.empty((3,3),dtype='float64')
        calculate_matrix(config,matrix.ctypes.data,temperature)
        expected=h.lerp_table(np.clip(temperature,2000,10000),assets['matrix_temperatures'],assets['camera_to_xyz'],clamp=False)
        record={'cct':temperature,'matrix_max_abs_error':float(np.max(abs(matrix-expected))),'luts':{}}
        assert record['matrix_max_abs_error']<1e-12
        for repro in (False,True):
            lut=calculate_lut(config,temperature,repro)
            assert (lut.width,lut.height,lut.stride)==(105,89,210),(lut.width,lut.height,lut.stride)
            native=np.ctypeslib.as_array((c.c_double*(89*105*2)).from_address(lut.data)).reshape(89,105,2).copy()
            # FromCbCrData stores mapped coordinates in the original DivFactor units.
            expected=h.lerp_table(np.clip(temperature,2000,10000),assets['wb_temperatures'],assets['lut_repro' if repro else 'lut_std'],clamp=False)
            record['luts']['reproduction' if repro else 'standard']={'maximum_error':float(np.max(abs(native-expected))),
                'scale':list(lut.scale),'offset':list(lut.offset),'divisor':lut.divisor}
            assert record['luts']['reproduction' if repro else 'standard']['maximum_error']<1e-12
            delete(lut.owner)
        records.append(record);print(record,flush=True)
    fn(raw,'_ZN7CXMLLutD1Ev',[c.c_void_p])(config)
    fn(util,'_ZN12CKeyCoderMacD1Ev',[c.c_void_p])(coder)
    release(dictionary);release(data)
    h.save_json(ROOT/'work/hncs-phocus-audit/evidence/native_config.json',records)


if __name__=='__main__':main()
