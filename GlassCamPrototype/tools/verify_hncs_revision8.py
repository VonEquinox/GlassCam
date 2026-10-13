#!/usr/bin/env python3
"""Independent revision-8 C++ pointwise, film and synthetic-source-bridge audit.

Native postcurve parity is distinct from the experimental Apple input adapter.
The old native core/golden suite also runs; no device calibration is implied.
"""
import ctypes as c
import hashlib
import json
import platform
import subprocess
from pathlib import Path
import numpy as np
import reference_runtime as r
import verify_cpp

ROOT = r.ROOT
LIB = ROOT/'build/libhncs_revision8.so'
P = c.c_void_p

def library():
    command=['g++','-std=c++17','-O3','-ffp-contract=off','-fno-fast-math','-pthread','-shared','-fPIC','-Wall','-Wextra','-Wpedantic',str(ROOT/'core/hncs.cpp'),'-o',str(LIB)]
    subprocess.run(command,check=True)
    lib=c.CDLL(str(LIB))
    lib.hncs_create_mode.argtypes=[c.c_double,c.c_double,c.c_int,c.c_int];lib.hncs_create_mode.restype=P
    lib.hncs_create_preset.argtypes=[c.c_double,c.c_double,c.c_double,c.c_int,c.c_int,c.c_int,c.c_int,c.c_char_p,c.c_int,P,P];lib.hncs_create_preset.restype=P
    lib.hncs_destroy.argtypes=[P]
    for name in ('hncs_apply_post_curves','hncs_apply_preset_pointwise','hncs_apply_preset_work_float'):
        getattr(lib,name).argtypes=[c.c_char_p,c.c_int,P,P,c.c_size_t]
    for name in ('hncs_process_srgb','hncs_process_srgb_fast','hncs_process_linear_rgba','hncs_render_native','hncs_render_native_preset','hncs_process_preset_work_float','hncs_finish_preset_work_linear'):
        getattr(lib,name).argtypes=[P,P,P,c.c_size_t]
    for name in ('hncs_process_linear_rgba_parallel','hncs_process_srgb_fast_parallel'):
        getattr(lib,name).argtypes=[P,P,P,c.c_size_t,c.c_uint]
    lib.hncs_preset_count.restype=c.c_size_t
    for name in ('hncs_preset_key','hncs_preset_name'):
        getattr(lib,name).argtypes=[c.c_size_t];getattr(lib,name).restype=c.c_char_p
    lib.hncs_preset_settings_json.argtypes=[c.c_char_p];lib.hncs_preset_settings_json.restype=c.c_char_p
    lib.hncs_preset_flags.argtypes=[c.c_char_p];lib.hncs_preset_flags.restype=c.c_uint
    lib.hncs_source_to_native_matrix.argtypes=[P,P]
    lib.hncs_preset_white_balance.argtypes=[P,P,P,P]
    return lib,command

def create(lib,key='standard',film=4,raw=2,cct=6500,ev=0,lstar=0,repro=0,tone=1,factory=0,baseline=None,target=None):
    baseline=None if baseline is None else np.ascontiguousarray(baseline,dtype=np.float64)
    target=None if target is None else np.ascontiguousarray(target,dtype=np.float64)
    ctx=lib.hncs_create_preset(ev,cct,factory,lstar,repro,film,raw,key.encode(),tone,None if baseline is None else baseline.ctypes.data,None if target is None else target.ctypes.data)
    assert ctx,(key,film,raw,cct,ev,lstar,repro,tone)
    return ctx

def run(lib,name,ctx,pixels,dtype,channels=3,*extra):
    out=np.empty((*pixels.shape[:-1],channels),dtype=dtype)
    status=getattr(lib,name)(ctx,pixels.ctypes.data,out.ctypes.data,pixels.size//3,*extra)
    assert status==0,(name,status)
    return out

def preset(lib,name,key,tone,pixels,dtype=np.uint16):
    out=np.empty_like(pixels,dtype=dtype)
    assert getattr(lib,name)(key.encode(),tone,pixels.ctypes.data,out.ctypes.data,pixels.size//3)==0
    return out

def bridge(lib,ctx):
    out=np.empty((3,3),dtype=np.float64);assert lib.hncs_source_to_native_matrix(ctx,out.ctypes.data)==0
    return out

def verify(lib):
    s=r.presets;a=r.assets();rng=np.random.default_rng(8137)
    report={}
    assert lib.hncs_preset_count()==43
    all_keys=[lib.hncs_preset_key(i).decode() for i in range(lib.hncs_preset_count())]
    assert len(set(all_keys))==43
    assert lib.hncs_preset_key(43) is None and lib.hncs_preset_name(43) is None
    for key in s.FACTORY_SETTING_FILES:
        actual=json.loads(lib.hncs_preset_settings_json(key.encode()))
        cfg=s.settings(key)
        for field,value in cfg.items():
            if field!='name': assert actual[field]==value,(key,field)
    assert lib.hncs_preset_flags(b'unknown')==2**32-1
    assert lib.hncs_preset_settings_json(b'unknown') is None
    report['catalog']={'unique_xml_payloads':43,'accepted_source_names':len(s.FACTORY_SETTING_FILES),'exact_parameters':'passed'}
    vector_path=r.REFERENCE/'work/hncs-pipeline/evidence/native_preset_vectors.npz'
    assert hashlib.sha256(vector_path.read_bytes()).hexdigest()==s.catalog()['binary_evidence']['post_curves']['native_vector_sha256']
    vectors=np.load(vector_path)
    active_pixels=0;inactive_pixels=0;vector_checks=[]
    ramp=np.repeat(np.arange(65536,dtype=np.uint16)[:,None],3,axis=1)
    for key in ('standard','nature','lighten','extra-contrast'):
        for tone in (0,1):
            record=s.catalog()['binary_evidence']['post_curves']['source_files'][s.FACTORY_SETTING_FILES[key]]['modes']['tone' if tone else 'no_tone']
            prefix=record['vector_key']
            active=json.loads(lib.hncs_preset_settings_json(key.encode()))['post_curve_modes'][tone]['active']
            for group in ('source','ramp'):
                source=vectors[prefix+'_source'] if group=='source' else ramp
                native=vectors[prefix+'_output'] if group=='source' else vectors[prefix+'_ramp']
                expected,_=s.apply_post_curves(source,key,apply_tone_curve=bool(tone))
                actual=preset(lib,'hncs_apply_post_curves',key,tone,source)
                np.testing.assert_array_equal(actual,expected)
                if active:
                    np.testing.assert_array_equal(actual,native);active_pixels+=len(source)
                else:
                    np.testing.assert_array_equal(actual,source);inactive_pixels+=len(source)
                vector_checks.append(dict(preset=key,tone=bool(tone),group=group,pixels=len(source),active=active,python_max_code_difference=0,native_max_code_difference=int(np.abs(actual.astype(int)-native.astype(int)).max())))
    report['native_postcurves']={'active_pixels':active_pixels,'active_max_code_difference':0,'inactive_bypass_pixels':inactive_pixels,'inactive_note':'Revision-8 Python bypasses inactive gradation. Unconditional native filter probe artifacts are intentionally not applied.','checks':vector_checks}
    x=rng.integers(0,65536,(97,99,3),dtype=np.uint16)
    checks=0
    for key in s.FACTORY_SETTING_FILES:
        for tone in (0,1):
            expected,_=s.apply_preset(x,key,apply_sharpness=False,apply_grain=False,apply_tone_curve=bool(tone))
            actual=preset(lib,'hncs_apply_preset_pointwise',key,tone,x)
            np.testing.assert_array_equal(actual,expected)
            checks+=x.size
    # Exhaustive neutral input codes for all unique payloads and both tone modes.
    for key in all_keys:
        for tone in (0,1):
            expected,_=s.apply_preset(ramp.reshape(256,256,3),key,apply_sharpness=False,apply_grain=False,apply_tone_curve=bool(tone))
            np.testing.assert_array_equal(preset(lib,'hncs_apply_preset_pointwise',key,tone,ramp).reshape(256,256,3),expected)
            checks+=ramp.size
    report['pointwise']={'channel_comparisons':checks,'max_code_difference':0,'stages':'Float32 saturation → ties-even UInt16 → native postcurves/hue/truncation → Float32 grayscale → final ties-even UInt16; grain/USM excluded'}
    native=rng.uniform(-.2,1.2,(64,129,3)).astype(np.float64)
    film_names={0:'old-standard',1:'high-contrast',2:'standard',4:'as-shot',6:'low-contrast',7:'linear'}
    film_cases=0
    for lstar in (0,1):
        for repro in (0,1):
            for film,name in film_names.items():
                for raw in ((0,2,4,7,99) if film==4 else (2,)):
                    for kelvin in (2000,5550,10000):
                        ctx=create(lib,film=film,raw=raw,cct=kelvin,lstar=lstar,repro=repro)
                        actual=run(lib,'hncs_render_native',ctx,native,np.uint16)
                        expected=r.hncs_codes(native,kelvin,a,intent='reproduction' if repro else 'standard',working_space='lstar' if lstar else 'legacy',film_curve=name,raw_film_curve=raw)
                        np.testing.assert_array_equal(actual,expected)
                        lib.hncs_destroy(ctx);film_cases+=1
    report['film_resolution']={'cases':film_cases,'max_code_difference':0,'covered':'all six menu types; as-shot raw0/raw2/raw4/raw7/raw99; both spaces/intents; original gamma distinct only legacy; reproduction pure regardless request'}
    native_combined=0
    for key in all_keys:
        for tone in (0,1):
            ctx=create(lib,key=key,cct=6500,tone=tone)
            actual=run(lib,'hncs_render_native_preset',ctx,native,np.uint16)
            cfg=s.settings(key);kelvin=cfg['color_temperature'] or 6500
            codes=r.hncs_codes(native,kelvin,a,working_space='legacy')
            expected,_=s.apply_preset(codes,key,apply_sharpness=False,apply_grain=False,apply_tone_curve=bool(tone))
            np.testing.assert_array_equal(actual,expected)
            lib.hncs_destroy(ctx);native_combined+=1
    report['native_combined']={'cases':native_combined,'max_code_difference':0,'scope':'caller-supplied white-balanced native RGB → selected kernel CCT/film → pointwise preset; source bridge/WB replacement excluded'}
    pixels=rng.uniform(-.1,1.1,(257,259,3)).astype(np.float32)
    defaults=0
    for kelvin in (1000,2000,5500,6500,10000,15000):
        for ev in (-2,0,2):
            old=lib.hncs_create_mode(ev,kelvin,0,0);new=create(lib,cct=kelvin,ev=ev)
            np.testing.assert_array_equal(bridge(lib,old),bridge(lib,new))
            for name,dtype in [('hncs_process_srgb',np.uint8),('hncs_process_srgb_fast',np.uint8),('hncs_process_linear_rgba',np.float32)]:
                np.testing.assert_array_equal(run(lib,name,new,pixels,dtype,4),run(lib,name,old,pixels,dtype,4));defaults+=1
            lib.hncs_destroy(old);lib.hncs_destroy(new)
    report['old_new_default_equivalence']={'cases':defaults,'result':'bit-exact; adapter matrix and UInt8/Float outputs unchanged'}
    split_cases=0
    for key in all_keys:
        ctx=create(lib,key=key)
        small=np.ascontiguousarray(pixels[:13,:19])
        direct=run(lib,'hncs_process_linear_rgba',ctx,small,np.float32,4)
        work=run(lib,'hncs_process_preset_work_float',ctx,small,np.float32)
        finished=run(lib,'hncs_finish_preset_work_linear',ctx,work,np.float32,4)
        np.testing.assert_array_equal(direct,finished)
        # The full-frame spatial handoff itself introduces no output changes.
        lib.hncs_destroy(ctx);split_cases+=1
    ctx=create(lib,key='extra-contrast')
    direct=run(lib,'hncs_process_linear_rgba',ctx,pixels,np.float32,4)
    for workers in (1,2,3,4):
        np.testing.assert_array_equal(direct,run(lib,'hncs_process_linear_rgba_parallel',ctx,pixels,np.float32,4,workers))
    lib.hncs_destroy(ctx)
    report['spatial_boundary']={'catalog_cases':split_cases,'result':'no-spatial Float32 work/finish split bit-exact to direct pointwise processing','parallel_workers':[1,2,3,4]}
    wb_cases=0
    for capture in (2000,3050,5550,6500,9100,10000):
        plain=create(lib,cct=capture);base_matrix=bridge(lib,plain);lib.hncs_destroy(plain)
        base=r.namespace['lerp_table'](capture,a['wb_temperatures'],a['factory_wb']);base=base/base[1]
        for key in all_keys:
            cfg=s.settings(key);desired=cfg['native_wb_gains']
            ctx=create(lib,key=key,cct=capture)
            actual=bridge(lib,ctx);expected=base_matrix if desired is None else base_matrix*(np.asarray(desired)/base)[:,None]
            np.testing.assert_array_equal(actual,expected)
            actual_base=np.empty(3);actual_target=np.empty(3);factory=np.empty(1)
            assert lib.hncs_preset_white_balance(ctx,actual_base.ctypes.data,actual_target.ctypes.data,factory.ctypes.data)==0
            np.testing.assert_array_equal(actual_base,base)
            np.testing.assert_array_equal(actual_target,base if desired is None else desired)
            assert factory[0]==(cfg['color_temperature'] or capture)
            lib.hncs_destroy(ctx);wb_cases+=1
    explicit_base=np.array([4.,2.,3.]);explicit_target=np.array([9.,3.,6.])
    first=create(lib,cct=6500,baseline=explicit_base,target=explicit_target,factory=5500)
    second=create(lib,cct=6500,baseline=explicit_base,target=explicit_target,factory=2850)
    plain=create(lib,cct=6500)
    expected=bridge(lib,plain)*((explicit_target/explicit_target[1])/(explicit_base/explicit_base[1]))[:,None]
    np.testing.assert_array_equal(bridge(lib,first),expected);np.testing.assert_array_equal(bridge(lib,second),expected)
    for ctx in (first,second,plain):lib.hncs_destroy(ctx)
    report['synthetic_apple_bridge']={'cases':wb_cases+2,'matrix_ratio_contract':'bit-exact','baseline':'factory_wb at truncated/clamped capture CCT, interpolation clamped to original WB table endpoints, normalized to green=1','target':'explicit gains or exact configured preset absolute gains, normalized to green=1','formula':'diag(desired/baseline) × A(capture CCT); factory kernel CCT separate','calibrated_for_apple':False}
    # Invalid settings, dimensions and nonfinite work never cross C++ exceptions.
    def bad(**kwargs):
        values=dict(ev=0.,capture=6500.,factory=0.,lstar=0,repro=0,film=4,raw=2,key=b'standard',tone=1,base=None,target=None);values.update(kwargs)
        return lib.hncs_create_preset(*values.values())
    for kwargs in ({'ev':np.nan},{'capture':np.inf},{'factory':np.nan},{'ev':21},{'lstar':2},{'repro':-1},{'film':3},{'tone':2},{'key':b'unknown'}):assert not bad(**kwargs)
    for gains in ([0,1,1],[-1,1,1],[1,np.nan,1],[1,np.inf,1],[1e308,1e-308,1]):
        gains=np.asarray(gains,dtype=np.float64)
        assert not bad(base=gains.ctypes.data);assert not bad(target=gains.ctypes.data)
    huge=(2**(c.sizeof(c.c_size_t)*8)-1)//4
    for name in ('hncs_apply_post_curves','hncs_apply_preset_pointwise','hncs_apply_preset_work_float'):
        fn=getattr(lib,name);assert fn(b'standard',1,None,None,0)==0;assert fn(b'unknown',1,None,None,0)==-1
        assert fn(b'standard',2,None,None,0)==-1;assert fn(b'standard',1,None,None,1)==-1;assert fn(b'standard',1,1,1,huge)==-1
    ctx=create(lib)
    nonfinite=np.array([[np.nan,0,0]],dtype=np.float32);out=np.zeros((1,4),dtype=np.float32)
    assert lib.hncs_process_preset_work_float(ctx,nonfinite.ctypes.data,out.ctypes.data,1)==-1
    assert lib.hncs_finish_preset_work_linear(ctx,nonfinite.ctypes.data,out.ctypes.data,1)==-1
    lib.hncs_destroy(ctx)
    report['invalid_arguments']='passed'
    return report

def main():
    lib,command=library()
    report=verify(lib)
    # Reuse original golden/random boundary verifier without its benchmark.
    old=verify_cpp.verify(lib)
    report['unchanged_core']={key:value for key,value in old.items() if key!='golden_checks'}
    report['status']='passed'
    report['environment']={'platform':platform.platform(),'numpy':np.__version__,'compiler':subprocess.check_output(['g++','--version'],text=True).splitlines()[0],'command':command}
    report['assets']={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in [ROOT/'core/hncs_assets.inc',ROOT/'core/hncs_preset_assets.inc',ROOT/'reference/work/hncs-pipeline/phocus_post_curves.npz',ROOT/'reference/work/hncs-pipeline/evidence/native_preset_vectors.npz']}
    report['implementation_sha256']={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in [ROOT/'core/hncs.cpp',ROOT/'core/hncs_c.h',ROOT/'core/generate_preset_assets.py',ROOT/'core/hncs_preset_catalog.json',Path(__file__),ROOT/'tests/hncs_revision8_sanitizer.cpp',ROOT/'tools/reference_runtime.py',ROOT/'reference/hncs_pipeline.py',ROOT/'reference/phocus_presets.py',ROOT/'reference/work/hncs-pipeline/phocus_presets.json']}
    (ROOT/'validation/hncs_revision8.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ('assets','environment','native_postcurves')},indent=2))

if __name__=='__main__':main()
