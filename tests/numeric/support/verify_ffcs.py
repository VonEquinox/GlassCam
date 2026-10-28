"""Source-backed FFCS verification; never replaces the supplied baseline.

Run --source PATH --generate to execute the nine original tests and original
historical 14-case reproduction (v0.2 uses verify_ffcs_v020.py), then capture exact Python-double maps for 19 LUT looks.
No pytest installation is needed: each original test gets its own temporary dir.
"""
from __future__ import annotations
import hashlib
import importlib.util
import inspect
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
VALIDATION = ROOT / 'tests/fixtures/ffcs'
NAMES = ('PROVIA', 'VELVIA', 'ASTIA', 'CLASSIC CHROME', 'CLASSIC NEG.',
         'NOSTALGIC NEG.', 'ETERNA', 'ETERNA BLEACH BYPASS', 'PRO NEG. HI',
         'PRO NEG. STD', 'ACROS', 'ACROS+G', 'ACROS+R', 'ACROS+Ye',
         'MONOCHROME', 'MONOCHROME+G', 'MONOCHROME+R', 'MONOCHROME+Ye', 'SEPIA')


def load_source(source):
    source = Path(source).resolve()
    implementation = source / 'implementation'
    if not (implementation / 'ffcs/pipeline.py').is_file():
        raise ValueError(f'No original FFCS implementation at {implementation}')
    sys.path.insert(0, str(implementation))
    return source


def original_tests(source):
    spec = importlib.util.spec_from_file_location('ffcs_original_tests', source / 'implementation/tests/test_pipeline.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    results = []
    for name, fn in inspect.getmembers(module, inspect.isfunction):
        if not name.startswith('test_'):
            continue
        params = inspect.signature(fn).parameters
        assert set(params) <= {'tmp_path'}, (name, params)
        with tempfile.TemporaryDirectory(prefix='ffcs-test-') as directory:
            fn(**({'tmp_path': Path(directory)} if params else {}))
        results.append({'test': name, 'status': 'pass'})
    assert len(results) == 9
    return {'status': 'pass', 'runner': 'direct original Python test functions; fresh tmp_path per test; pytest unavailable', 'tests': results}


def original_reproduction(source):
    baseline = source / 'validation/baseline_pixels.json'
    before = hashlib.sha256(baseline.read_bytes()).hexdigest()
    env = dict(os.environ, PYTHONPATH=os.pathsep.join([str(source / 'implementation'), os.environ.get('PYTHONPATH', '')]))
    run = subprocess.run([sys.executable, str(source / 'examples/reproduce.py')], env=env, capture_output=True, text=True, check=True)
    after = hashlib.sha256(baseline.read_bytes()).hexdigest()
    assert before == after, 'Original baseline was modified'
    report = json.loads(run.stdout)
    assert report['cases'] == 19 and report['stage_maps'] == 198
    return dict(report, baseline_sha256=before, baseline_unchanged=True)


def small_input():
    return [[(r / 255., g / 255., b / 255.) for r, g in
            ((0, 0), (255, 0), (0, 255), (128, 96), (32, 200), (255, 255))]
            for b in (0, 64, 192, 255)]


def rich_input(width=131, height=9):
    """Wide enough to exercise grain's coarse-noise interpolation (>125px)."""
    rng = random.Random(928)
    data = [[tuple(rng.uniform(-0.2, 1.2) for _ in range(3)) for _ in range(width)] for _ in range(height)]
    boundaries = [-0.2, 0., 1e-8, .0031308, .04045 - 1e-10, .04045,
                  .04045 + 1e-10, .18, .5, 1. - 1e-8, 1., 1.2]
    data[0][:len(boundaries)] = [(v, v, v) for v in boundaries]
    data[1][:8] = [(float(r), float(g), float(b)) for r in (0, 1) for g in (0, 1) for b in (0, 1)]
    return data


def reference(pixels, name, seed=0, linear=False):
    from PIL import Image
    from ffcs.pipeline import FFCS, PipelineConfig
    result = FFCS(PipelineConfig(camera='XH2S', simulation=name, seed=seed, input_is_linear=linear)).apply(
        Image.new('RGB', (len(pixels[0]), len(pixels))), input_pixels=pixels)
    assert result.metadata['approximation_metrics']['analytic_look']['status'] == 'not_used'
    assert result.validate_contract()['status'] == 'pass'
    return result




def build_library():
    import ctypes as c
    out = ROOT / 'build/libffcs_verify.so'
    out.parent.mkdir(exist_ok=True)
    command = ['g++', '-std=c++17', '-O3', '-ffp-contract=off', '-fno-fast-math',
               '-shared', '-fPIC', '-pthread', str(ROOT / 'core/ffcs.cpp'), '-lz', '-o', str(out)]
    subprocess.run(command, check=True)
    lib = c.CDLL(str(out))
    ptr = c.POINTER
    lib.ffcs_simulation_count.restype = c.c_size_t
    for fn in ('ffcs_simulation_name', 'ffcs_simulation_asset'):
        getattr(lib, fn).argtypes = [c.c_size_t]
        getattr(lib, fn).restype = c.c_char_p
    lib.ffcs_create.argtypes = [c.c_char_p, c.c_size_t, c.c_char_p, c.c_size_t]
    lib.ffcs_create.restype = c.c_void_p
    lib.ffcs_destroy.argtypes = [c.c_void_p]
    callback = c.CFUNCTYPE(None, c.c_char_p, ptr(c.c_double), c.c_size_t, c.c_size_t, c.c_void_p)
    lib.ffcs_process_encoded_double.argtypes = [c.c_void_p, ptr(c.c_double), c.c_size_t,
        c.c_size_t, c.c_size_t, c.c_uint32, ptr(c.c_double), c.c_size_t,
        callback, c.c_void_p, c.c_char_p, c.c_size_t]
    lib.ffcs_process_linear_rgb.argtypes = [c.c_void_p, ptr(c.c_float), c.c_size_t,
        c.c_size_t, c.c_size_t, c.c_float, c.c_uint32, ptr(c.c_float), c.c_size_t,
        ptr(c.c_uint8), c.c_size_t, c.c_char_p, c.c_size_t]
    return lib, callback, command


def compare_cpp(source):
    if json.loads((source / 'validation/delivery_manifest.json').read_text()).get('version') == '0.2.0':
        raise RuntimeError('Historical v0.1 comparison is superseded by verify_ffcs_v020.py --compare.')
    import ctypes as c
    import numpy as np
    from ffcs.color import srgb_decode, srgb_encode
    lib, callback_type, command = build_library()
    golden = json.loads((VALIDATION / 'ffcs_mobile_stage_goldens.json').read_text())
    checks = []
    max_error = 0.
    mobile_max = 0.
    preview_max = 0
    assets = str(source / 'implementation/ffcs/data/xh2s').encode()
    assert lib.ffcs_simulation_count() == len(NAMES)
    found = set()
    for index in range(lib.ffcs_simulation_count()):
        name = lib.ffcs_simulation_name(index).decode()
        found.add(name)
        err = c.create_string_buffer(1024)
        ctx = lib.ffcs_create(assets, index, err, len(err))
        assert ctx, err.value.decode()
        assert lib.ffcs_simulation_asset(index).decode() == golden['looks'][name]['asset']
        try:
            for case, pixels, seed in [('golden_6x4', golden['input'], 0),
                                      ('rich_131x9', rich_input(), 37),
                                      ('single_pixel', [[(.5, .18, .04045)]], 4294967295)]:
                array = np.ascontiguousarray(pixels, dtype=np.float64)
                output = np.empty_like(array)
                stages = {}
                @callback_type
                def cb(stage, values, width, height, user):
                    stages[stage.decode()] = np.ctypeslib.as_array(values, shape=(width*height*3,)).copy().reshape(height, width, 3)
                status = lib.ffcs_process_encoded_double(ctx, array.ctypes.data_as(c.POINTER(c.c_double)),
                    array.size, array.shape[1], array.shape[0], seed,
                    output.ctypes.data_as(c.POINTER(c.c_double)), output.size, cb, None, err, len(err))
                assert status, err.value.decode()
                expected = golden['looks'][name]['stages'] if case == 'golden_6x4' else reference(pixels, name, seed).stage_pixels
                assert set(stages) == set(expected), (name, case, stages.keys(), expected.keys())
                for stage, expected_pixels in expected.items():
                    error = float(np.max(np.abs(stages[stage] - np.asarray(expected_pixels))))
                    max_error = max(max_error, error)
                    checks.append({'look': name, 'case': case, 'stage': stage, 'max_error': error})
                    assert error < 1e-12, (name, case, stage, error)
                np.testing.assert_array_equal(output, stages['output_icc'])
            # Exact mobile contract: float32 linear input, EV, encode to original
            # FFCS, decode final display values to float32; not an 8-bit shortcut.
            linear = np.asarray(rich_input(17, 7), dtype=np.float32)
            for ev in (-2., 0., 2.):
                encoded = [[[srgb_encode(max(0., min(1., float(v) * 2.**ev))) for v in rgb]
                            for rgb in row] for row in linear]
                expected = reference(encoded, name, seed=37).pixels
                expected_linear = np.asarray([[[srgb_decode(v) for v in rgb] for rgb in row] for row in expected], dtype=np.float32)
                out = np.empty_like(linear)
                preview = np.empty((*linear.shape[:2], 4), dtype=np.uint8)
                status = lib.ffcs_process_linear_rgb(ctx, linear.ctypes.data_as(c.POINTER(c.c_float)),
                    linear.size, linear.shape[1], linear.shape[0], ev, 37,
                    out.ctypes.data_as(c.POINTER(c.c_float)), out.size,
                    preview.ctypes.data_as(c.POINTER(c.c_uint8)), preview.size, err, len(err))
                assert status, err.value.decode()
                error = float(np.max(np.abs(out - expected_linear)))
                mobile_max = max(mobile_max, error)
                assert error <= 2e-7, (name, ev, error)
                expected_preview = np.rint(np.asarray(expected) * 255).astype(np.int16)
                byte_error = int(np.max(np.abs(preview[..., :3].astype(np.int16) - expected_preview)))
                preview_max = max(preview_max, byte_error)
                assert byte_error <= 1 and np.all(preview[..., 3] == 255)
        finally:
            lib.ffcs_destroy(ctx)
    assert found == set(NAMES)
    report = {'status': 'pass', 'compile_command': command, 'presets': len(found),
              'stage_comparisons': len(checks), 'maximum_absolute_stage_error': max_error,
              'stage_tolerance': 1e-12, 'linear_mobile_cases': len(found)*3,
              'linear_mobile_max_error': mobile_max, 'linear_mobile_tolerance': 2e-7,
              'preview_max_byte_error': preview_max, 'checks': checks}
    return {k: v for k, v in report.items() if k != 'checks'}
