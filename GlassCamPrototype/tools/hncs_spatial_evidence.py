"""Reproducible source/compiler stamps for portable HNCS spatial tests."""
import datetime, hashlib, os, pathlib, platform, subprocess


def snapshot(root, reference=None):
    paths=[root/name for name in [
        'core/hncs_spatial.h','core/hncs_spatial.cpp','core/hncs_spatial_assets.inc',
        'core/hncs_numpy_rng.h','core/hncs_numpy_rng.cpp',
        'tools/generate_hncs_spatial_assets.py','tools/test_hncs_spatial.py',
        'tools/test_hncs_numpy_rng.py','tools/test_hncs_spatial_sanitizers.py',
        'tools/hncs_spatial_evidence.py','tests/hncs_numpy_rng_bridge.cpp',
        'tests/hncs_spatial_smoke.cpp']]
    if reference:
        paths += [reference/'phocus_presets.py',reference/'work/hncs-pipeline/phocus_presets.json']
    return {str(p.relative_to(root) if p.is_relative_to(root) else p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def environment():
    compiler=os.environ.get('CXX','c++')
    return {'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'platform':platform.platform(),'machine':platform.machine(),
            'compiler':subprocess.check_output([compiler,'--version'],text=True).splitlines()[0],
            'strict_fp_flags':['-fno-fast-math','-ffp-contract=off'],
            'runtime_note':'Tests executed on Linux; Apple/device execution and cross-libm bitwise identity are not established.'}
