"""Independent optimized FFCS regression and Linux CPU benchmark.

Runs all 19 looks through borders, random inputs, 1..4 workers and output modes;
compares byte-for-byte to the separately retained baseline API before timing.
"""
import argparse
import ctypes as c
import hashlib
import json
import platform
import statistics
import time
from pathlib import Path
import numpy as np
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests/numeric"))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from support import verify_ffcs as v


def setup():
    lib, _, command = v.build_library()
    lib.ffcs_process_linear_rgb_optimized.argtypes = lib.ffcs_process_linear_rgb.argtypes[:-2] + [c.c_uint] + lib.ffcs_process_linear_rgb.argtypes[-2:]
    return lib, command


def call(lib, ctx, x, workers=None, mode='both', ev=.7, seed=0xffffffff):
    y = np.empty_like(x) if mode in ('both', 'linear') else None
    rgba = np.empty((*x.shape[:2], 4), dtype=np.uint8) if mode in ('both', 'preview') else None
    err = c.create_string_buffer(1024)
    args = [ctx, x.ctypes.data_as(c.POINTER(c.c_float)), x.size, x.shape[1], x.shape[0], ev, seed,
            y.ctypes.data_as(c.POINTER(c.c_float)) if y is not None else None, y.size if y is not None else 0,
            rgba.ctypes.data_as(c.POINTER(c.c_uint8)) if rgba is not None else None, rgba.size if rgba is not None else 0]
    if workers is None:
        status = lib.ffcs_process_linear_rgb(*args, err, len(err))
    else:
        status = lib.ffcs_process_linear_rgb_optimized(*args, workers, err, len(err))
    return status, y, rgba, err.value.decode()


def regress(lib, assets):
    rng = np.random.default_rng(48219)
    cases = 0
    mode_cases = 0
    shapes = [(1,1), (13,1), (1,13), (3,7), (9,131), (17,29)]
    for index in range(19):
        err = c.create_string_buffer(1024)
        ctx = lib.ffcs_create(str(assets).encode(), index, err, len(err))
        assert ctx, err.value
        try:
            for h,w in shapes:
                x = rng.uniform(-.3, 1.4, (h,w,3)).astype(np.float32)
                x[0,0] = [0., .0031308, 1.]
                ok, expected, preview, error = call(lib, ctx, x)
                assert ok, error
                for workers in range(1,5):
                    ok, actual, actual_preview, error = call(lib, ctx, x, workers)
                    assert ok, error
                    assert expected.tobytes() == actual.tobytes(), (index,w,h,workers,'float')
                    assert preview.tobytes() == actual_preview.tobytes(), (index,w,h,workers,'preview')
                    cases += 1
                    for mode in ('linear', 'preview'):
                        ok, actual, actual_preview, error = call(lib, ctx, x, workers, mode)
                        assert ok, error
                        if actual is not None: assert expected.tobytes() == actual.tobytes()
                        if actual_preview is not None: assert preview.tobytes() == actual_preview.tobytes()
                        mode_cases += 1
            for workers in (0, 5, 4294967295):
                assert call(lib, ctx, x, workers)[0] == 0
            assert call(lib, ctx, x, 1, 'neither')[0] == 0
            for ev in (float('nan'), float('inf'), -33., 33.):
                assert call(lib, ctx, x, 1, ev=ev)[0] == 0
            bad = x.copy(); bad[0,0,0] = np.nan
            assert call(lib, ctx, bad, 1)[0] == 0
        finally:
            lib.ffcs_destroy(ctx)
    return {'status':'pass', 'presets':19, 'both_output_bit_exact_cases':cases,
            'single_output_bit_exact_cases':mode_cases, 'workers':[1,2,3,4],
            'dimensions_height_width':shapes, 'invalid_worker_missing_output_ev_nonfinite':'pass'}


def benchmarks(lib, assets, include_12mp=False):
    err = c.create_string_buffer(1024)
    ctx = lib.ffcs_create(str(assets).encode(), 0, err, len(err))
    assert ctx, err.value
    rng = np.random.default_rng(7625)
    rows = []
    sizes = [(1024,1024),(2048,1536)] + ([(4000,3000)] if include_12mp else [])
    try:
        for w,h in sizes:
            x = rng.random((h,w,3), dtype=np.float32)
            expected_hash = None
            timings = {}
            for label, workers in [('baseline',None), ('optimized_1',1), ('optimized_4',4)]:
                # Both outputs, identical input and settings; include caller buffer
                # allocation consistently in all calls. LUT context excluded.
                ok, y, rgba, error = call(lib, ctx, x, workers, ev=0, seed=0)
                assert ok, error
                digest = hashlib.sha256(y.tobytes() + rgba.tobytes()).hexdigest()
                if expected_hash is None: expected_hash = digest
                assert digest == expected_hash
                samples = []
                for _ in range(3):
                    start = time.perf_counter()
                    ok, y, rgba, error = call(lib, ctx, x, workers, ev=0, seed=0)
                    samples.append(time.perf_counter()-start)
                    assert ok, error
                    assert hashlib.sha256(y.tobytes()+rgba.tobytes()).hexdigest() == expected_hash
                timings[label] = {'samples_seconds':samples, 'median_seconds':statistics.median(samples)}
            row = {'width':w,'height':h,'output_float_and_preview_sha256':expected_hash,
                   'timings':timings,
                   'speedup_1':timings['baseline']['median_seconds']/timings['optimized_1']['median_seconds'],
                   'speedup_4':timings['baseline']['median_seconds']/timings['optimized_4']['median_seconds'],
                   'baseline_peak_image_scratch_bytes':2*w*h*3*8,
                   'optimized_row_scratch_bytes_1':3*w*3*8,
                   'optimized_row_scratch_bytes_4':4*3*w*3*8}
            rows.append(row)
            print(json.dumps(row), flush=True)
    finally:
        lib.ffcs_destroy(ctx)
    return rows


def main():
    output = Path.home() / "Library/Developer/GlassCamDiagnostics/bench"
    output.mkdir(parents=True, exist_ok=True)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--12mp', dest='large', action='store_true')
    args = p.parse_args()
    assets = v.ROOT / 'vendor/ffcs/implementation/ffcs/data/xh2s'
    lib, command = setup()
    regression = regress(lib, assets)
    print(json.dumps(regression), flush=True)
    report = {'status':'pass', 'platform':platform.platform(), 'processor':platform.processor(),
              'compile_command':command, 'regression':regression,
              'benchmark':benchmarks(lib, assets, args.large),
              'scratch_memory':'Optimized: 3 rows * width * 3 channels * 8 bytes * min(workers,height), excluding LUT/input/output. Baseline peak image scratch at sharpening: 2 * width * height * 3 * 8 bytes (source and destination RGB-double vectors).',
              'limitations':['Linux host CPU measurements only; no iPhone latency, energy, thermal or peak RSS claim.',
                             'Three measured samples after one warm-up; context/LUT loading excluded; caller output allocations included equally.',
                             'Row-buffer formula describes algorithm scratch, not total process memory.',
                             'Shared-host timings can vary strongly; these samples do not establish a consistent latency speedup.']}
    (output/'ffcs_optimization.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__ == '__main__': main()
