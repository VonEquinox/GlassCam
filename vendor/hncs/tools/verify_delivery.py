"""Check current file hashes and independent native colour/preset fixtures."""
from pathlib import Path
import json
import platform
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import numpy as np
import scipy, rawpy, tifffile, PIL
import hncs_pipeline as h
import hncs_paired_illuminants as paired
from phocus_presets import catalog, apply_post_curves, post_curve_tables
from reference_color_core import render


def verify_manifest():
    manifest = json.loads((ROOT/'validation/delivery_manifest.json').read_text())
    for name, record in manifest['files'].items():
        path = ROOT/name
        if not path.is_file() or path.stat().st_size != record['bytes'] or h.digest(path) != record['sha256']:
            raise ValueError('Delivery hash mismatch: '+name)
    return len(manifest['files'])


def verify_numerics():
    assets = h.load_assets()
    profile = json.loads(h.PROFILE.read_text())
    paired.colour_parameters(profile, assets, profile['source_wb'], 'calibration')
    checks = []
    with np.load(ROOT/'work/hncs-phocus-audit/evidence/native_kernel_vectors.npz', allow_pickle=False) as vectors:
        for key in vectors.files:
            if not key.endswith('_source'):
                continue
            space, intent, cct, _ = key.split('_')
            source = vectors[key].astype(np.float64)/65535
            reference = vectors[key.replace('_source', '_output')]
            actual = render(source, int(cct), assets, space, intent)
            np.testing.assert_array_equal(actual, reference)
            np.testing.assert_array_equal(actual, h.hncs_codes(source, int(cct), assets, intent, working_space=space))
            checks.append({'key': key, 'pixels': len(source), 'max_uint16_difference': 0})
    post_curve_tables()
    evidence = catalog()['binary_evidence']['post_curves']
    fixture = ROOT/'work/hncs-pipeline/evidence/native_preset_vectors.npz'
    if h.digest(fixture) != evidence['native_vector_sha256']:
        raise ValueError('Native preset fixtures changed')
    preset_checks = []
    with np.load(fixture, allow_pickle=False) as vectors:
        ramp = np.repeat(np.arange(65536, dtype=np.uint16)[:, None], 3, axis=1)
        for rel, name in (('Nature.xml','nature'), ('Gradation Curves/Lighten.xml','lighten'), ('Exposure/Extra contrast.xml','extra-contrast')):
            for tone in (True, False):
                mode = evidence['source_files'][rel]['modes']['tone' if tone else 'no_tone']
                key = mode['vector_key']
                source = vectors[key+'_source']
                actual, _ = apply_post_curves(source, name, apply_tone_curve=tone)
                if not tone and name != 'extra-contrast':
                    np.testing.assert_array_equal(actual, source)
                    continue
                np.testing.assert_array_equal(actual, vectors[key+'_output'])
                actual_ramp, _ = apply_post_curves(ramp, name, apply_tone_curve=tone)
                np.testing.assert_array_equal(actual_ramp, vectors[key+'_ramp'])
                preset_checks.append({'preset': name, 'tone_enabled': tone, 'pixels': len(source)+len(ramp), 'max_uint16_difference': 0})
    return {'colour_core_groups': len(checks), 'colour_core_pixels': sum(x['pixels'] for x in checks),
            'colour_core_max_uint16_difference': 0, 'preset_groups': len(preset_checks),
            'preset_pixels': sum(x['pixels'] for x in preset_checks), 'preset_max_uint16_difference': 0,
            'factory_presets': len(evidence['source_files']), 'unique_post_curve_tables': evidence['unique_tables'],
            'colour_checks': checks, 'preset_checks': preset_checks}


def main():
    report = {'status': 'passed', 'render_revision': h.RENDER_PATH_REVISION,
              'manifest_files_checked': verify_manifest(), **verify_numerics(),
              'environment': {'python': sys.version, 'platform': platform.platform(),
                              'numpy': np.__version__, 'scipy': scipy.__version__,
                              'rawpy': rawpy.__version__, 'libraw': rawpy.libraw_version,
                              'pillow': PIL.__version__, 'tifffile': tifffile.__version__}}
    h.save_json(ROOT/'validation/delivery_verification.json', report)
    print(json.dumps({k:v for k,v in report.items() if not k.endswith('_checks') and k != 'environment'}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
