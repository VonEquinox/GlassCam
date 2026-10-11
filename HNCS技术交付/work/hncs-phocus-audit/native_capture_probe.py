"""Read the actual 3FR through Phocus's binary, without launching its UI.

Objects are constructed and destroyed by their native functions. Oversized
aligned Python-owned buffers are used only for storage of opaque C++ objects.
The file specification uses native read-only permission (bool false => 1).
"""
import ctypes as c
import json
import math
import plistlib
import tifffile
from pathlib import Path
from native_chain_probe import Native, Vec3
from native_config_probe import verified_framework

ROOT=Path(__file__).resolve().parents[2]


def main():
    n=Native()
    storage=c.CDLL(str(verified_framework('HBStorage')))
    stream=c.create_string_buffer(0x1000)
    n.fn(storage,'_ZN17CStreamFactoryMacC1Ev',[c.c_void_p])(stream)
    c.c_void_p.in_dll(n.util,'gStreamFactory').value=c.addressof(stream)
    spec=c.create_string_buffer(0x40)
    n.fn(n.util,'_ZN9CFileSpecC1EPKcbii',[c.c_void_p,c.c_char_p,c.c_bool,c.c_int,c.c_int])(
        spec,str(ROOT/'7fbb1471e0cf4b22858cd9a161fb83a8.3fr').encode(),False,0,0)
    raw=c.create_string_buffer(0x4000)
    print('Constructing native read-only 3FR',flush=True)
    n.fn(n.image,'_ZN11CRaw3FRFileC1E9CFileSpec',[c.c_void_p,c.c_void_p])(raw,spec)
    print('3FR constructor completed',flush=True)
    values={}
    for name,ret in [('GetSensitivityGain',c.c_double),('GetAnalogGain',c.c_double),
                     ('GetIsoGain',c.c_double),('GetFilmCurveType',c.c_int),('GetBlackLevel',c.c_int)]:
        values[name]=n.fn(storage,f'_ZN13CRawImageFile{len(name)}{name}Ev',[c.c_void_p],ret)(raw)
    values['GetDNGWhiteLevel']=n.fn(storage,'_ZNK13CRawImageFile16GetDNGWhiteLevelEv',[c.c_void_p],c.c_int)(raw)
    gain=(c.c_double*3)()
    values['GetNeutralGain_success']=n.fn(storage,'_ZN13CRawImageFile14GetNeutralGainEPd',[c.c_void_p,c.c_void_p],c.c_bool)(raw,gain)
    values['GetNeutralGain']=list(gain)
    description=c.create_string_buffer(0x1000)
    n.fn(storage,'_ZN15sRawDescriptionC1EP13CRawImageFileP15CRawCaptureInfo',
         [c.c_void_p,c.c_void_p,c.c_void_p])(description,raw,None)
    values['raw_description']={
        'sensitivity_gain':c.c_double.from_buffer(description,0x18).value,
        'iso_gain':c.c_double.from_buffer(description,0x40).value,
        'analog_gain':c.c_double.from_buffer(description,0x50).value,
        'film_curve':c.c_int.from_buffer(description,0xb0).value,
        'black_level':c.c_int.from_buffer(description,0x130).value,
        'sensor':c.c_int.from_buffer(description,0x344).value,
        'ir_filter':c.c_int.from_buffer(description,0x348).value,
    }
    # Parse the exported sidecar's selected settings through CImageCorrection.
    # These are user/application settings, not matrices copied from Python.
    sidecar=plistlib.loads((ROOT/'work/hncs-phocus-audit/evidence/actual_export.phos').read_bytes())
    selected=sidecar['ImageSettings'][sidecar['CurrentIx']]['ImageCorrection']
    payload=plistlib.dumps(selected,fmt=plistlib.FMT_XML)
    data=n.fn(n.cf,'CFDataCreate',[c.c_void_p,c.c_void_p,c.c_long],c.c_void_p)(None,payload,len(payload))
    dictionary=n.fn(n.cf,'CFPropertyListCreateWithData',[c.c_void_p,c.c_void_p,c.c_ulong,c.c_void_p,c.c_void_p],c.c_void_p)(None,data,0,None,None)
    assert dictionary
    coder=c.create_string_buffer(0x20)
    n.fn(n.util,'_ZN12CKeyCoderMacC1EP14__CFDictionaryb',[c.c_void_p,c.c_void_p,c.c_bool])(coder,dictionary,False)
    correction=c.create_string_buffer(0x1000)
    n.fn(storage,'_ZN16CImageCorrectionC1Ev',[c.c_void_p])(correction)
    n.fn(storage,'_ZN16CImageCorrection10DecodeFromEP9CKeyCoder',[c.c_void_p,c.c_void_p])(correction,coder)
    native_settings={
        'working_space':c.c_int.from_buffer(correction,0xbc).value,
        'cct':c.c_int.from_buffer(correction,0x27c).value,
        'tint':c.c_double.from_buffer(correction,0x280).value,
        'ev_multiplier':c.c_double.from_buffer(correction,0x288).value,
        'hdr':bool(c.c_ubyte.from_buffer(correction,0x290).value),
        'color_model':c.c_int.from_buffer(correction,0x2a8).value,
        'film_curve_selection':c.c_int.from_buffer(correction,0x2ac).value,
        'closed_loop_configuration_present':bool(c.c_void_p.from_buffer(correction,0x2d0).value),
        'exposure_tool_version':c.c_int.from_buffer(correction,0x408).value,
    }
    native_settings['effective_film_curve']=n.fn(storage,'_ZNK16CImageCorrection18EffectiveFilmCurveE14eFilmCurveType',
        [c.c_void_p,c.c_int],c.c_int)(correction,values['GetFilmCurveType'])
    native_settings['local_white_balance_filter_active']=bool(n.fn(n.image,'_ZN12CCameraImage19LocalWBFilterActiveEPK16CImageCorrection',
        [c.c_void_p],c.c_bool)(correction))
    wb=n.fn(n.image,'_ZNK20CColorTempConversion17TempAndTintToGainEid',
            [c.c_void_p,c.c_int,c.c_double],Vec3)(n.temp_object,native_settings['cct'],native_settings['tint'])
    native_settings['resolved_white_balance']=[wb.x,wb.y,wb.z]
    values['selected_native_settings']=native_settings
    with tifffile.TiffFile(ROOT/'7fbb1471e0cf4b22858cd9a161fb83a8.3fr') as tf:
        rational=lambda value:value[0]/value[1]
        baseline=rational(tf.pages[0].tags[0xc62a].value)
        offset=rational(tf.pages[0].tags[0xc7a5].value)
    predicted_iso=65535/(values['GetDNGWhiteLevel']-values['GetBlackLevel'])*2**(baseline+offset)
    assert math.isclose(predicted_iso,values['GetIsoGain'],abs_tol=1e-12)
    values['iso_gain_formula']={'baseline_exposure':baseline,'baseline_exposure_offset':offset,
        'computed_native_code_gain':predicted_iso,
        'white_normalised_gain':2**(baseline+offset),
        'note':'Native code-unit gain includes white/black normalization; it cannot be applied again to white-normalized LibRaw data. This getter alone does not establish the complete preprocessing exposure chain.'}
    assert native_settings['working_space']==0 and not native_settings['hdr']
    assert native_settings['effective_film_curve']==2
    assert not native_settings['closed_loop_configuration_present']
    n.fn(storage,'_ZN16CImageCorrectionD1Ev',[c.c_void_p])(correction)
    n.fn(n.util,'_ZN12CKeyCoderMacD1Ev',[c.c_void_p])(coder)
    for obj in (dictionary,data):n.fn(n.cf,'CFRelease',[c.c_void_p])(obj)
    storage_base=c.cast(n.fn(storage,'_ZN16CImageCorrectionC1Ev',[c.c_void_p]),c.c_void_p).value-0x318b8
    c.CFUNCTYPE(None,c.c_void_p)(storage_base+0x51a88)(description)
    print(json.dumps(values,indent=2),flush=True)
    (ROOT/'work/hncs-phocus-audit/evidence/native_capture.json').write_text(json.dumps(values,indent=2)+'\n')
    # D1 is not exported; vtable slot zero is the complete, non-deleting
    # destructor. Slot one deletes memory and must not receive Python storage.
    vtable=c.c_void_p.from_buffer(raw).value
    destructor=c.c_void_p.from_address(vtable).value
    c.CFUNCTYPE(None,c.c_void_p)(destructor)(raw)
    n.fn(n.util,'_ZN9CFileSpecD1Ev',[c.c_void_p])(spec)
    c.c_void_p.in_dll(n.util,'gStreamFactory').value=None
    n.fn(storage,'_ZN17CStreamFactoryMacD1Ev',[c.c_void_p])(stream)
    n.close()


if __name__=='__main__':main()
