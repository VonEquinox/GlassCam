"""Independently construct Phocus's factory parameter chain, including WB/CCT.

Runs against the original 4.2.2 arm64 frameworks. CXMLLut is decoded by native
code from the original recovered plist, then registered in the native cache.
No NumPy matrices, LUTs, or curves are injected into colour correction objects.
"""
import ctypes as c
import json
import sys
import itertools
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import hncs_pipeline as h
from native_config_probe import LUT, verified_framework


class Vec3(c.Structure):
    _fields_ = [('x', c.c_double), ('y', c.c_double), ('z', c.c_double)]


class Native:
    def __init__(self):
        self.util = c.CDLL(str(verified_framework('HBUtil')))
        self.raw = c.CDLL(str(verified_framework('HBRawCorrections')))
        self.image = c.CDLL(str(verified_framework('HBImageProcessing')))
        self.cf = c.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        self.config = c.create_string_buffer(0x330)
        self.fn(self.raw, '_ZN7CXMLLutC1Ev', [c.c_void_p])(self.config)
        payload = (ROOT/'work/hncs-phocus-correction/evidence/colormaps_plain/bohnjuhtuvuvtxyydb56.bin').read_bytes()
        data = self.fn(self.cf, 'CFDataCreate', [c.c_void_p,c.c_void_p,c.c_long],c.c_void_p)(None,payload,len(payload))
        dictionary = self.fn(self.cf, 'CFPropertyListCreateWithData', [c.c_void_p,c.c_void_p,c.c_ulong,c.c_void_p,c.c_void_p],c.c_void_p)(None,data,0,None,None)
        assert dictionary
        coder = c.create_string_buffer(0x20)
        self.fn(self.util,'_ZN12CKeyCoderMacC1EP14__CFDictionaryb',[c.c_void_p,c.c_void_p,c.c_bool])(coder,dictionary,False)
        self.fn(self.raw,'_ZN7CXMLLut10DecodeFromEP9CKeyCoder',[c.c_void_p,c.c_void_p])(self.config,coder)
        self.fn(self.util,'_ZN12CKeyCoderMacD1Ev',[c.c_void_p])(coder)
        for obj in (dictionary,data): self.fn(self.cf,'CFRelease',[c.c_void_p])(obj)
        cache = self.fn(self.raw,'_ZN15CRawColorParams11GetInstanceEv',[],c.c_void_p)()
        self.fn(self.raw,'_ZN15CRawColorParams16AddClosedLoopLUTEP7CXMLLut13uColorProfile',[c.c_void_p,c.c_void_p,c.c_uint])(cache,self.config,0x616)
        self.temp_object = c.create_string_buffer(0x98)
        self.fn(self.image,'_ZN20CColorTempConversionC1E9eCCDTypes13eIRFilterType',[c.c_void_p,c.c_int,c.c_int])(self.temp_object,22,6)
        basefn = self.fn(self.image,'_ZN20CColorTempConversion9TempTableEv',[],c.c_void_p)
        self.image_base = c.cast(basefn,c.c_void_p).value - 0xd3738

    @staticmethod
    def fn(lib, name, args, ret=None):
        function = getattr(lib,name);function.argtypes=args;function.restype=ret;return function

    def wb_to_cct(self, wb):
        temp=c.c_int();tint=c.c_double()
        self.fn(self.image,'_ZN20CColorTempConversion17GainToTempAndTintE9eCCDTypes13eIRFilterType6CArrayIdLi3E23Matrix3x1InitializationERiRdb',
            [c.c_int,c.c_int,Vec3,c.POINTER(c.c_int),c.POINTER(c.c_double),c.c_bool])(22,6,Vec3(*wb),c.byref(temp),c.byref(tint),False)
        return temp.value,tint.value

    def correction(self, cct, film=6, model=0, hdr=False, gain=1., space=1):
        return self.fn(self.raw,'_ZN19CRawColorCorrection21NewRawColorCorrectionE9eCCDTypes13eIRFilterTypedd14eFilmCurveType11eColorModelPK14CCLCalibration13eWorkingSpacebd',
            [c.c_int,c.c_int,c.c_double,c.c_double,c.c_int,c.c_int,c.c_void_p,c.c_int,c.c_bool,c.c_double],c.c_void_p)(22,6,cct,gain,film,model,None,space,hdr,gain)

    @staticmethod
    def array(address, offset, shape, dtype='float64'):
        size=int(np.prod(shape));typ=c.c_double if dtype=='float64' else c.c_float
        return np.ctypeslib.as_array((typ*size).from_address(address+offset)).reshape(shape).copy()

    def close(self):
        self.fn(self.image,'_ZN20CColorTempConversionD1Ev',[c.c_void_p])(self.temp_object)
        self.fn(self.raw,'_ZN7CXMLLutD1Ev',[c.c_void_p])(self.config)


def main():
    n=Native();assets=h.load_assets()
    profile=json.loads(h.PROFILE.read_text())
    # The first matrix is flash camera->XYZ with factory WB multiplied into columns.
    rgb_to_xyz=n.array(c.addressof(n.temp_object),8,(3,3))
    print('native WB matrix',rgb_to_xyz.tolist(),flush=True)
    expected=assets['camera_to_xyz'][2]@np.diag(assets['factory_wb'][1])
    assert np.max(abs(rgb_to_xyz-expected))<1e-12
    # Robertson table: mired, u, v, iso-temperature slope; all 31 native rows.
    robertson=n.array(n.image_base,0x189e10,(31,4))
    print('robertson',robertson.tolist(),flush=True)
    wbs=[profile['target_wb'],profile['target']['camera_wb'][:3],*assets['factory_wb'].tolist()]
    records=[]
    for wb in wbs:
        temp,tint=n.wb_to_cct(wb)
        pytemp,pytint=h.estimate_cct(wb,assets)
        assert temp==pytemp and abs(tint-pytint)<1e-12
        records.append({'wb':wb,'native_cct':temp,'native_tint':tint,'python_cct':pytemp,'tint_error':abs(tint-pytint)})
        print(records[-1],flush=True)
    chain=[];vectors={}
    rng=np.random.default_rng(20261003)
    tint_error=0
    for wb in rng.uniform(.4,8,(5000,3)):
        temp,tint=n.wb_to_cct(wb);pytemp,pytint=h.estimate_cct(wb,assets)
        assert temp==pytemp,(wb,temp,pytemp)
        tint_error=max(tint_error,abs(tint-pytint))
    assert tint_error<1e-12
    # FilmCurve=4 in the sidecar means automatic; this 3FR resolves it to 2.
    # Reproduction resolves it to 7. Verify the selected native tables as well
    # as the explicitly requested 4/6 paths that were tested previously.
    film_records=[]
    for space,model in itertools.product((0,1),(0,1)):
        for film in ((2,4,6) if model==0 else (7,)):
            outer=n.correction(7523,film=film,model=model,hdr=False,space=space)
            cc=c.c_void_p.from_address(outer+0xb0).value
            curve=n.array(c.c_void_p.from_address(cc+0x188).value,0,(65536,),'float32')
            key=('v1_' if model==0 else 'pure_')+('lstar' if space else 'gamma')
            error=float(np.max(abs(curve-assets[key])))
            assert error==0
            film_records.append({'working_space':space,'color_model':model,'film_curve':film,
                                 'hdr':False,'curve_entries':65536,'maximum_error':error})
            n.fn(n.raw,'_ZN19CRawColorCorrectionD0Ev',[c.c_void_p])(outer)
    temperatures=(1000,2000,2400,3050,4000,5550,7000,7523,7625,8543,9100,10000,11000)
    for space,model,temp in itertools.product((0,1),(0,1),temperatures):
        outer=n.correction(temp,film=4,model=model,hdr=False,space=space)
        assert outer
        cc=c.c_void_p.from_address(outer+0xb0).value
        mi=n.array(cc,8,(3,3));mo=n.array(cc,0x50,(3,3))
        curve=n.array(c.c_void_p.from_address(cc+0x188).value,0,(65536,),'float32')
        lut=LUT.from_address(cc+0x138)
        source=rng.integers(0,65536,(5000,3),dtype=np.uint16);source[:20]=np.arange(20)[:,None]*3000
        source[20:24]=[[65535,0,0],[0,65535,0],[0,0,65535],[0,0,0]]
        native=np.empty_like(source)
        n.fn(n.raw,'_ZN14CVectorMethods24ColorNormalCorrectPixelsEP16CColorCorrectionPtS2_ib',
            [c.c_void_p,c.c_void_p,c.c_void_p,c.c_void_p,c.c_int,c.c_bool])(None,cc,native.ctypes.data,source.ctypes.data,len(source),model==1)
        intent='standard' if model==0 else 'reproduction'
        working_space='legacy' if space==0 else 'lstar'
        py=h.hncs_codes(source.astype(float)/65535,temp,assets,intent,working_space=working_space)
        pymi,pymo=h.kernel_matrices(temp,assets,intent,working_space=working_space)
        native_lut=n.array(lut.data,0,(lut.height,lut.width,2))
        factory_lut=h.lerp_table(np.clip(temp,2000,10000),assets['wb_temperatures'],assets['lut_std' if model==0 else 'lut_repro'],clamp=False)
        py_lut,py_grid=(h.expand_lut(factory_lut,assets['grid'],assets['lut_expansion']) if space else (factory_lut,assets['grid']))
        curve_key=('v1_' if model==0 else 'pure_')+('lstar' if space else 'gamma')
        entry={'model':model,'working_space':working_space,'film_curve':4,'hdr':False,'cct':temp,
            'matrix_in_error':float(np.max(abs(mi-pymi))),
            'matrix_out_error':float(np.max(abs(mo-pymo))),
            'curve_error':float(np.max(abs(curve-assets[curve_key]))),
            'uint16_max_error':int(np.max(abs(native.astype(int)-py.astype(int)))),
            'pixels':len(source),'lut_max_error':float(np.max(abs(native_lut-py_lut))),
            'lut_geometry':[lut.width,lut.height,lut.stride,lut.divisor],
            'gray_thresholds':n.array(cc,0xe0,(2,)).tolist(),
            'shadow_parameters':n.array(cc,0x1b8,(4,)).tolist(),
            'shadow_bypass':model==1}
        assert entry['matrix_in_error']<1e-12 and entry['matrix_out_error']<1e-12
        assert entry['curve_error']==0 and entry['uint16_max_error']<=1
        assert entry['lut_max_error']<1e-12 and entry['gray_thresholds']==[0.,0.]
        vectors[f'{working_space}_{intent}_{temp}_source']=source[:128]
        vectors[f'{working_space}_{intent}_{temp}_output']=native[:128]
        chain.append(entry);print(entry,flush=True)
        n.fn(n.raw,'_ZN19CRawColorCorrectionD0Ev',[c.c_void_p])(outer)
    n.close()
    h.save_json(ROOT/'work/hncs-phocus-audit/evidence/native_chain.json',
        {'wb_matrix':rgb_to_xyz.tolist(),'robertson':robertson.tolist(),'white_balances':records,
         'random_white_balances':5000,'max_tint_error':tint_error,'film_curve_selection_checks':film_records,'chains':chain,
         'scope':'Native parsed factory config, WB conversion and constructor-selected matrices/expanded LUT/gray thresholds/gradation. Normal non-HDR CPU path, colorModel 0/1, filmCurve 4, legacy/LStar spaces 0/1, unit gain. Full RAW decoding and spatial pipeline are not compared by this test.'})
    np.savez_compressed(ROOT/'work/hncs-phocus-audit/evidence/native_kernel_vectors.npz',**vectors)


if __name__=='__main__':main()
