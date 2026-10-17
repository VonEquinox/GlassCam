"""Exercise the new memory/file sharpness path against original Phocus outputs."""
import argparse
import ctypes as c
import itertools
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

import numpy as np
from audit_phocus_input_spatial import Filters, delta, sha
from audit_phocus_sharpness_settings import native_settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=19102026)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    ref, out = args.reference_root.resolve(), args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sys.path[:0] = [str(ref), str(ref / "work/hncs-phocus-audit")]
    from native_chain_probe import Native
    from native_config_probe import verified_framework
    from preset_curves_probe import NativeCurves, correction_payload
    import phocus_presets as p
    paths = [root/name for name in ["core/hncs_spatial.cpp", "core/hncs_spatial.h", "core/hncs_phocus_sharpness.hpp",
        "core/hncs_spatial_assets.inc", "core/hncs_numpy_rng.cpp", "tools/native_phocus_filters_bridge.cpp",
        "tools/verify_phocus_spatial_integration.py", "tools/audit_phocus_sharpness_settings.py",
        "tools/audit_phocus_input_spatial.py"]]
    hashes = {str(path): sha(path) for path in paths}
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-O3", "-fno-fast-math", "-ffp-contract=off",
        "-Wall", "-Wextra", "-Werror", "-dynamiclib", str(root/"core/hncs_spatial.cpp"),
        str(root/"core/hncs_numpy_rng.cpp"), "-o", str(out/"spatial.dylib")], check=True)
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-O2", "-dynamiclib",
        str(root/"tools/native_phocus_filters_bridge.cpp"), "-o", str(out/"native.dylib")], check=True)
    lib = c.CDLL(str(out/"spatial.dylib"))
    cb = c.CFUNCTYPE(c.c_int, c.c_void_p)
    null_callback = cb()
    mem = lib.hncs_apply_spatial_native_sharpness
    disk = lib.hncs_apply_spatial_native_sharpness_file
    mem.argtypes = [c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_int, c.c_int, c.c_double]
    disk.argtypes = [c.c_char_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_int, c.c_int, c.c_double, c.c_char_p, cb, c.c_void_p]
    n = Native(); filters = Filters(n, out/"native.dylib")
    storage = c.CDLL(str(verified_framework("HBStorage")))
    ctor = n.fn(n.image, "_ZN16CSharpnessFilterC1Eidiiidd",
                [c.c_void_p, c.c_int, c.c_double, c.c_int, c.c_int, c.c_int, c.c_double, c.c_double])
    amount = n.fn(storage, "_ZNK16CImageCorrection24EffectiveSharpnessAmountEdi", [c.c_void_p, c.c_double, c.c_int], c.c_double)
    factory = Path("/Volumes/Phocus/Phocus.app/Contents/Resources/Settings/Standard")
    baseline = plistlib.loads((factory/"Standard.xml").read_bytes())["ImageSetting"]["ImageCorrection"]
    records=[]; grain_checks=[]; rng=np.random.default_rng(args.seed)
    with tempfile.TemporaryDirectory(prefix="native-sharpness-integration-") as temporary:
        temporary=Path(temporary);work_path=temporary/"work.rgbf"
        def run(source,key,base,grain,sharp):
            h,w=source.shape[:2];actual=source.copy()
            assert mem(actual.ctypes.data,w,h,key.encode(),grain,sharp,base)==0
            source.tofile(work_path)
            assert disk(str(work_path).encode(),w,h,key.encode(),grain,sharp,base,str(temporary).encode(),null_callback,None)==0
            file=np.fromfile(work_path,dtype=np.float32).reshape(source.shape)
            np.testing.assert_array_equal(actual.view(np.uint32),file.view(np.uint32))
            return actual
        for index,key in enumerate(sorted(set(p.preset_key(k) for k in p.PRESET_CHOICES))):
            cfg=p.settings(key);file=p.FACTORY_SETTING_FILES[cfg['name']]
            entry={'plist':plistlib.loads((factory/file).read_bytes())}
            payload=correction_payload(entry,baseline,True);settings=NativeCurves(n,storage,payload)
            try:
                native_sharpness=native_settings(n,storage,settings.correction)
                shape=[(1,1,3),(1,17,3),(19,1,3),(33,37,3),(5,4099,3),(67,7,3)][index%6]
                source=rng.integers(0,65536,shape,dtype=np.uint16)
                work=source.astype(np.float32)/np.float32(65535.)
                for base in [0.,1.5]:
                    effective=amount(settings.correction,base,0)
                    if native_sharpness['enabled'] and effective>0:
                        obj=c.create_string_buffer(0x1000)
                        ctor(obj,int(effective),native_sharpness['radius']/10.,native_sharpness['noise_limit'],native_sharpness['dark_limit'],shape[1],1.,1.)
                        try:
                            halo=max(4,c.c_int.from_buffer(obj,0x70).value)
                            padded=filters.pad(source,halo)
                            expected=filters.run(obj,'_ZNK16CSharpnessFilter12FilterResultE6CXRectS0_NSt3__110unique_ptrI14CBufferedImageNS1_14default_deleteIS3_EEEES6_',padded,(halo,halo,shape[1],shape[0]))
                        finally:filters.destroy(obj)
                    else:expected=source
                    actual=run(work,key,base,0,1)
                    quantized=np.rint(np.clip(actual,0,1)*np.float32(65535.)).astype(np.uint16)
                    error=delta(quantized,expected)
                    assert error['maximum_uint16_error']==0,(key,base,error)
                    np.testing.assert_array_equal(actual.view(np.uint32),(expected.astype(np.float32)/np.float32(65535.)).view(np.uint32))
                    np.testing.assert_array_equal(run(work,key,base,0,0).view(np.uint32),work.view(np.uint32))
                    records.append({'preset':key,'baseline_sharpness':base,'shape':list(shape),'native_effective_amount':effective,**error})
                    if cfg['film_grain'].get('ApplyFilmGrain') and cfg['film_grain'].get('FilmGrainAmount'):
                        expected_work,_=p._apply_film_grain(expected.astype(np.float32)/np.float32(65535.),cfg['film_grain'],p.preset_key(key))
                        composed=run(work,key,base,1,1)
                        np.testing.assert_array_equal(composed.view(np.uint32),expected_work.view(np.uint32))
                        grain_checks.append({'preset':key,'baseline_sharpness':base,'order':'original sharpness then portable grain','float_bit_mismatches':0})
            finally:settings.close()
        valid=rng.random((19,23,3),dtype=np.float32)
        valid.tofile(work_path)
        assert mem(valid.ctypes.data,23,19,b'standard',0,1,float('nan'))==-1
        assert disk(str(work_path).encode(),24,19,b'standard',0,1,1.5,str(temporary).encode(),null_callback,None)==-1
        stops=[]
        for stop in [1,3,15,30]:
            valid.tofile(work_path);seen=[0]
            def cancel(_):seen[0]+=1;return int(seen[0]>=stop)
            callback=cb(cancel)
            assert disk(str(work_path).encode(),23,19,b'standard',0,1,1.5,str(temporary).encode(),callback,None)==-3
            assert not list(temporary.glob('hncs-spatial-*'))
            stops.append(stop)
    n.close();assert hashes=={str(path):sha(path) for path in paths}
    report={'status':'passed','source_sha256':hashes,'seed':args.seed,'native_sharpness':records,'portable_grain_order':grain_checks,
        'summary':{'native_cases':len(records),'native_channel_comparisons':sum(r['channels'] for r in records),
                   'maximum_uint16_error':0,'memory_file_bit_mismatches':0,'grain_order_cases':len(grain_checks)},
        'invalid_baseline_and_file_size':'rejected','cancellation_checks':stops,
        'scope':'Original CPU sharpness with original factory parameters, BaselineSharpness 0/1.5, full-resolution scale, explicit replicated halo; memory/file/tile boundaries and portable grain order. Apple decoder and full Phocus RAW pipeline are separate.'}
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report['summary'],indent=2))


if __name__=='__main__':main()
