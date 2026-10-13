#!/usr/bin/env python3
"""Execute all eight HNCS stage-switch routes against revision-8 Python.

This portable audit composes the real native C++ color/work/spatial/finish APIs,
with caller-owned crop and Standard bypass. It does not run Swift or Apple APIs.
"""
import argparse
import ctypes as c
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

import numpy as np

import reference_runtime as r
from test_hncs_spatial import reference_apply

ROOT = Path(__file__).resolve().parents[1]
PRESETS = ('standard', 'nature', 'square-crop', 'film-grain-artistic', 'sharpness-high')
P = c.c_void_p


def inputs_sha256():
    paths = [ROOT / name for name in (
        'core/hncs.cpp', 'core/hncs_c.h', 'core/hncs_assets.inc', 'core/hncs_preset_assets.inc',
        'core/hncs_spatial.cpp', 'core/hncs_spatial.h', 'core/hncs_spatial_assets.inc',
        'core/hncs_numpy_rng.cpp', 'core/hncs_numpy_rng.h',
        'reference/phocus_presets.py', 'reference/hncs_pipeline.py',
        'reference/work/hncs-pipeline/phocus_presets.json',
        'tools/reference_runtime.py', 'tools/test_hncs_spatial.py',
        'tools/verify_effect_toggle_hncs.py', 'tests/test_effect_toggle_native.py')]
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def verify():
    before = inputs_sha256()
    compiler = os.environ.get('CXX', 'g++')
    report = {
        'passed': False,
        'scope': 'synthetic white-balanced native RGB; caller crop and Standard bypass; C++ core/work/spatial/finish vs revision-8 Python',
        'cases': 0, 'memory_spatial_cases': 0, 'file_spatial_cases': 0,
        'pointwise_bypass_cases': 0, 'native_code_mismatches': 0, 'final_code_mismatches': 0,
        'spatial_float_bit_mismatches': 0, 'memory_file_bit_mismatches': 0,
        'max_display_absolute_error': 0., 'display_tolerance': 1e-7,
        'cases_detail': [], 'source_sha256': before,
        'apple_executed': False, 'swift_executed': False,
        'platform': platform.platform(), 'numpy': np.__version__,
        'compiler': subprocess.check_output([compiler, '--version'], text=True).splitlines()[0],
    }
    assets = r.assets()
    rng = np.random.default_rng(831701)
    callback_type = c.CFUNCTYPE(c.c_int, P)
    null_callback = callback_type()
    with tempfile.TemporaryDirectory(prefix='hncs-effect-toggles-') as temporary:
        temporary = Path(temporary)
        library = temporary / 'effects.so'
        command = [compiler, '-std=c++17', '-O3', '-fno-fast-math', '-ffp-contract=off',
                   '-shared', '-fPIC', '-pthread', '-Wall', '-Wextra', '-Werror',
                   str(ROOT / 'core/hncs.cpp'), str(ROOT / 'core/hncs_spatial.cpp'),
                   str(ROOT / 'core/hncs_numpy_rng.cpp'), '-o', str(library)]
        subprocess.run(command, check=True)
        report['compile_flags'] = command[1:11]
        lib = c.CDLL(str(library))
        lib.hncs_create_preset.argtypes = [c.c_double, c.c_double, c.c_double, c.c_int, c.c_int,
                                          c.c_int, c.c_int, c.c_char_p, c.c_int, P, P]
        lib.hncs_create_preset.restype = P
        lib.hncs_destroy.argtypes = [P]
        for name in ('hncs_render_native', 'hncs_render_native_preset', 'hncs_finish_preset_work_linear'):
            getattr(lib, name).argtypes = [P, P, P, c.c_size_t]
        lib.hncs_apply_preset_work_float.argtypes = [c.c_char_p, c.c_int, P, P, c.c_size_t]
        lib.hncs_preset_flags.argtypes = [c.c_char_p]
        lib.hncs_preset_flags.restype = c.c_uint
        lib.hncs_preset_settings_json.argtypes = [c.c_char_p]
        lib.hncs_preset_settings_json.restype = c.c_char_p
        lib.hncs_apply_spatial_preset.argtypes = [P, c.c_size_t, c.c_size_t, c.c_char_p, c.c_int, c.c_int]
        lib.hncs_apply_spatial_preset_file.argtypes = [c.c_char_p, c.c_size_t, c.c_size_t,
                                                      c.c_char_p, c.c_int, c.c_int, c.c_char_p,
                                                      callback_type, P]
        for height, width in ((17, 23), (23, 17)):
            full_source = rng.uniform(-.03, 1.03, (height, width, 3)).astype(np.float64)
            full_source[0, :3] = [[0, 1, .5], [.001, .02, .75], [.25, .75, 1.05]]
            for preset, (grain, sharp, crop_on) in itertools.product(PRESETS, itertools.product((False, True), repeat=3)):
                cfg = r.presets.settings(preset)
                frozen_cfg = json.dumps(cfg, sort_keys=True)
                key = preset.encode()
                # Compare the unchanged original parameters, never synthesizing
                # parameters from a true switch for a stage this preset lacks.
                catalog = json.loads(lib.hncs_preset_settings_json(key))
                for name, value in cfg.items():
                    if name != 'name':
                        assert catalog[name] == value, (preset, name)
                crop = r.presets.resolve_crop(full_source.shape, cfg) if crop_on else None
                if crop is None:
                    bounds = [0, 0, width, height]
                else:
                    bounds = crop['pixel_bounds']
                left, top, right, bottom = bounds
                source = np.ascontiguousarray(full_source[top:bottom, left:right])
                h, w = source.shape[:2]
                assert (w, h) == ((min(width, height),) * 2 if preset == 'square-crop' and crop_on else (width, height))
                ctx = lib.hncs_create_preset(0, 6500, 6500, 0, 0, 4, 2, key, 1, None, None)
                assert ctx
                try:
                    native = np.empty(source.shape, dtype=np.uint16)
                    assert lib.hncs_render_native(ctx, source.ctypes.data, native.ctypes.data, h * w) == 0
                    expected_native = r.hncs_codes(source, 6500, assets, 'standard', working_space='legacy',
                                                   film_curve='as-shot', raw_film_curve=2)
                    np.testing.assert_array_equal(native, expected_native)
                    flags = lib.hncs_preset_flags(key)
                    needs_spatial = preset != 'standard' and ((grain and flags & 4) or (sharp and flags & (8 | 16)))
                    if preset == 'standard':
                        expected = expected_native
                    else:
                        expected, _ = r.presets.apply_preset(expected_native, preset,
                                                            apply_grain=grain, apply_sharpness=sharp,
                                                            apply_tone_curve=True)
                    work = np.empty(source.shape, dtype=np.float32)
                    assert lib.hncs_apply_preset_work_float(key, 1, native.ctypes.data, work.ctypes.data, h * w) == 0
                    initial_work = work.copy()
                    if needs_spatial:
                        oracle_work = reference_apply(r.presets, work.copy(), preset, grain, sharp)
                        assert lib.hncs_apply_spatial_preset(work.ctypes.data, w, h, key, grain, sharp) == 0
                        np.testing.assert_array_equal(work.view(np.uint32), oracle_work.view(np.uint32))
                        report['memory_spatial_cases'] += 1
                        work_path = temporary / 'work.rgbf'
                        initial_work.tofile(work_path)
                        assert lib.hncs_apply_spatial_preset_file(os.fsencode(work_path), w, h, key, grain, sharp,
                                                                 os.fsencode(temporary), null_callback, None) == 0
                        disk_work = np.fromfile(work_path, dtype=np.float32).reshape(work.shape)
                        np.testing.assert_array_equal(work.view(np.uint32), disk_work.view(np.uint32))
                        report['file_spatial_cases'] += 1
                    else:
                        report['pointwise_bypass_cases'] += 1
                        direct = np.empty(source.shape, dtype=np.uint16)
                        assert lib.hncs_render_native_preset(ctx, source.ctypes.data, direct.ctypes.data, h * w) == 0
                        np.testing.assert_array_equal(direct, expected)
                    actual_codes = np.rint(np.clip(work, 0, 1) * 65535).astype(np.uint16)
                    np.testing.assert_array_equal(actual_codes, expected)
                    # The actual C++ finish performs its own final UInt16 round
                    # and display transform. Comparing it avoids claiming a
                    # Python quantization alone exercised the final native API.
                    output = np.empty((h, w, 4), dtype=np.float32)
                    assert lib.hncs_finish_preset_work_linear(ctx, work.ctypes.data, output.ctypes.data, h * w) == 0
                    encoded = r.srgb_from_hncs(expected, assets, 'legacy')
                    linear = np.where(encoded <= .04045, encoded / 12.92, ((encoded + .055) / 1.055) ** 2.4)
                    error = float(np.max(np.abs(output[..., :3].astype(np.float64) - linear)))
                    assert error <= report['display_tolerance'], (preset, grain, sharp, crop_on, error)
                    assert np.isfinite(output).all() and np.all((output >= 0) & (output <= 1))
                    assert np.all(output[..., 3] == 1)
                    assert json.dumps(r.presets.settings(preset), sort_keys=True) == frozen_cfg
                    report['max_display_absolute_error'] = max(report['max_display_absolute_error'], error)
                    report['cases'] += 1
                    report['cases_detail'].append({
                        'preset': preset, 'effects': {'applyGrain': grain, 'applySharpness': sharp, 'applyExtraCrop': crop_on},
                        'source_width': width, 'source_height': height, 'output_width': w, 'output_height': h,
                        'crop_bounds': bounds, 'spatial_route': bool(needs_spatial),
                        'native_codes': 'exact', 'final_codes': 'exact', 'alpha': 1,
                        'display_max_absolute_error': error,
                    })
                finally:
                    lib.hncs_destroy(ctx)
    assert inputs_sha256() == before, 'Inputs changed during HNCS switch audit'
    assert report['cases'] == 80
    report['passed'] = True
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = verify()
    serialized = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.write_text(serialized)
    print(serialized)


if __name__ == '__main__':
    main()
