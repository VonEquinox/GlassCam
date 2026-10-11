"""Additive, offline HNCS default-CCT cube study; never changes app/core sources.

Run from the prototype root:
    OPENBLAS_NUM_THREADS=1 python tools/lut_proxy_default_kelvin.py
The original 5500 K study and its saved results remain frozen. This script
reproduces its holdouts, verifies a 5500 K control against that saved report,
and separately measures the app default 6500 K at EV=0.
"""
import ctypes as C
import hashlib
import json
import math
import platform
import subprocess
from pathlib import Path

import numpy as np

from lut_proxy_study import COMMAND, ROOT, decode, encode, lab_d65, stats

NODES = 65
SEED = 20261011
SOURCE_PATHS = [
    'core/hncs.cpp', 'core/hncs_c.h', 'core/hncs_assets.inc',
    'core/ffcs.cpp', 'core/ffcs_c.h',
    'tools/lut_proxy_oracle.cpp', 'tools/lut_proxy_study.py',
    'tools/lut_proxy_default_kelvin.py',
]
FROZEN_PATHS = ['tools/lut_proxy_study.py', 'validation/lut-proxy-study.json']


def sha256(path):
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def probes():
    # Deliberately preserve the original RNG call order, not just its seed.
    rng = np.random.default_rng(SEED)
    gray = np.linspace(0, 1, 8193, dtype=np.float32)[:, None].repeat(3, axis=1)
    boundary = rng.random((20000, 3), dtype=np.float32)
    boundary[np.arange(len(boundary)), np.arange(len(boundary)) % 3] = rng.choice(
        np.array([0, 1, 1e-7, 1 - 1e-7], np.float32), len(boundary))
    sat = rng.random((20000, 3), dtype=np.float32)
    sat[np.arange(len(sat)), np.arange(len(sat)) % 3] = 0
    sat[np.arange(len(sat)), (np.arange(len(sat)) + 1) % 3] = 1
    return {
        'random': rng.random((100000, 3), dtype=np.float32),
        'gray': gray,
        'dark': np.exp(rng.uniform(np.log(1e-7), np.log(.02), (20000, 3))).astype(np.float32),
        'saturated': sat,
        'boundary': boundary,
    }


def metrics(actual, reference):
    result = stats(actual, reference)
    error = np.abs(actual.astype(np.float64) - reference.astype(np.float64))
    result.update(mean_abs_channel=float(error.mean()),
                  mean_pixel_max=float(error.max(axis=1).mean()))
    return result


def summarize(x, exact, output, start_index=0):
    encoded_exact, encoded_output = encode(exact), encode(output)
    encoded_error = np.abs(encoded_output.astype(np.float64) - encoded_exact.astype(np.float64))
    delta_e = np.linalg.norm(lab_d65(output) - lab_d65(exact), axis=1)

    def vector(index):
        return {
            'sample_index': start_index + index,
            'input_linear': x[index].tolist(),
            'oracle_linear': exact[index].tolist(),
            'proxy_linear': output[index].tolist(),
            'oracle_encoded_srgb': encoded_exact[index].tolist(),
            'proxy_encoded_srgb': encoded_output[index].tolist(),
            'encoded_abs_channel_error': encoded_error[index].tolist(),
            'encoded_pixel_max_error': float(encoded_error[index].max()),
            'delta_e76_d65': float(delta_e[index]),
        }

    return {
        'display_linear': metrics(output, exact),
        'encoded_srgb_float': metrics(encoded_output, encoded_exact),
        'delta_e76_d65': dict(max=float(delta_e.max()), mean=float(delta_e.mean()),
                             p95=float(np.quantile(delta_e, .95)),
                             p99=float(np.quantile(delta_e, .99))),
        'worst_encoded_vector': vector(int(np.argmax(encoded_error.max(axis=1)))),
        'worst_delta_e76_vector': vector(int(np.argmax(delta_e))),
    }


def main():
    before = {p: sha256(p) for p in dict.fromkeys(SOURCE_PATHS + FROZEN_PATHS)}
    frozen = json.loads((ROOT / 'validation/lut-proxy-study.json').read_text())
    for p in ['core/hncs.cpp', 'core/hncs_assets.inc', 'tools/lut_proxy_oracle.cpp', 'tools/lut_proxy_study.py']:
        assert before[p] == frozen['source_sha256'][p], f'Frozen oracle dependency changed: {p}'
    (ROOT / 'build').mkdir(exist_ok=True)
    command = [*COMMAND[:-1], 'build/lut_proxy_default_kelvin.so']
    subprocess.run(command, cwd=ROOT, check=True)
    lib = C.CDLL(str(ROOT / command[-1]))
    ptr = np.ctypeslib.ndpointer(dtype=np.float32, flags='C_CONTIGUOUS')
    lib.hncs_create.argtypes = [C.c_double, C.c_double]
    lib.hncs_create.restype = C.c_void_p
    lib.hncs_process_linear_rgba.argtypes = [C.c_void_p, ptr, ptr, C.c_size_t]
    lib.hncs_process_linear_rgba.restype = C.c_int
    lib.hncs_destroy.argtypes = [C.c_void_p]
    lib.hncs_destroy.restype = None
    lib.lut_proxy_lookup.argtypes = [ptr, C.c_int, ptr, ptr, C.c_size_t]
    lib.lut_proxy_lookup.restype = None
    contexts = {k: lib.hncs_create(0, k) for k in [5500, 6500]}
    assert all(contexts.values())

    def oracle(x, kelvin=6500):
        out = np.empty((len(x), 4), np.float32)
        assert lib.hncs_process_linear_rgba(contexts[kelvin], np.ascontiguousarray(x), out, len(x)) == 0
        assert np.isfinite(out).all() and np.all((out >= 0) & (out <= 1))
        assert np.all(out[:, 3] == 1)
        return out

    def lookup(lut, coords):
        out = np.empty_like(coords)
        lib.lut_proxy_lookup(np.ascontiguousarray(lut), NODES, np.ascontiguousarray(coords), out, len(coords))
        return out

    try:
        categories = probes()
        x = np.concatenate(list(categories.values()))
        ranges, offset = {}, 0
        for name, values in categories.items():
            ranges[name] = slice(offset, offset + len(values))
            offset += len(values)
        coords = np.ascontiguousarray(encode(x), dtype=np.float32)
        axis = np.linspace(0, 1, NODES, dtype=np.float32)
        node_coords = np.stack(np.meshgrid(axis, axis, axis, indexing='ij'), axis=-1).reshape(-1, 3)
        study_grid = np.ascontiguousarray(decode(node_coords), dtype=np.float32)
        # Match the app's inverseSRGB: Double arithmetic, then one Float cast.
        app_axis = np.array([
            q / 12.92 if q <= .04045 else math.pow((q + .055) / 1.055, 2.4)
            for q in [i / (NODES - 1) for i in range(NODES)]
        ], dtype=np.float32)
        app_grid = np.stack(np.meshgrid(app_axis, app_axis, app_axis, indexing='ij'), axis=-1).reshape(-1, 3)
        exact = oracle(x)[:, :3].copy()

        # The unchanged 5500 K control proves generation, ordering and metrics
        # reproduce the saved study, rather than merely using a similar seed.
        control_lut = oracle(study_grid, 5500)[:, :3].copy()
        control_exact = oracle(x, 5500)[:, :3].copy()
        control_out = lookup(control_lut, coords)
        control = summarize(x, control_exact, control_out)
        frozen_row = next(row for row in frozen['results'] if
                          row['look'] == 'HNCS' and row['shaper'] == 'srgb' and
                          row['nodes'] == NODES and row['storage'] == 'float32' and
                          row['interpolation'] == 'trilinear')
        comparisons = []
        for group in ['display_linear', 'encoded_srgb_float', 'delta_e76_d65']:
            for metric, expected in frozen_row['metrics']['all'][group].items():
                observed = control[group][metric]
                np.testing.assert_allclose(observed, expected, rtol=0, atol=1e-14)
                comparisons.append({'metric': group + '.' + metric,
                                    'saved': expected, 'observed': observed,
                                    'absolute_difference': abs(observed - expected)})
        assert control['worst_encoded_vector']['input_linear'] == frozen_row['metrics']['all']['worst_encoded_vector']['input_linear']

        results, bakes = [], {}
        for node_evaluation, grid in [('frozen_study_float32', study_grid), ('app_double_then_float32', app_grid)]:
            baked_rgba = oracle(grid)
            baked = baked_rgba[:, :3].copy()
            bakes[node_evaluation] = baked
            # Export/CI layout and an independently generated app traversal must
            # both agree with the exact oracle at every one of the 274625 nodes.
            rgba_rfast = np.ascontiguousarray(baked_rgba.reshape(NODES, NODES, NODES, 4).transpose(2, 1, 0, 3), dtype='<f4')
            b, g, r = np.indices((NODES, NODES, NODES))
            source_axis = decode(axis) if node_evaluation == 'frozen_study_float32' else app_axis
            independent_rfast_input = np.ascontiguousarray(np.stack([source_axis[r], source_axis[g], source_axis[b]], axis=-1).reshape(-1, 3))
            independent_rgba = oracle(independent_rfast_input)
            np.testing.assert_array_equal(rgba_rfast.reshape(-1, 4), independent_rgba)
            assert np.all(rgba_rfast[..., 3] == 1)
            assert len(rgba_rfast.tobytes()) == NODES ** 3 * 4 * 4
            for storage in ['float32', 'float16']:
                lut = baked if storage == 'float32' else baked.astype(np.float16).astype(np.float32)
                output = lookup(lut, coords)
                node_output = lookup(lut, node_coords)
                np.testing.assert_array_equal(node_output, lut)
                rows = {'all': summarize(x, exact, output)}
                for name, part in ranges.items():
                    rows[name] = summarize(x[part], exact[part], output[part], part.start)
                results.append(dict(
                    look='HNCS', fixed_parameters=dict(ev=0, hncs_kelvin=6500, hncs_mode='legacy/standard'),
                    shaper='srgb', nodes=NODES, node_evaluation=node_evaluation,
                    storage=storage, interpolation='trilinear',
                    node_storage_max_abs=float(np.max(np.abs(lut - baked))),
                    rgba_texture_bytes=NODES ** 3 * 4 * (4 if storage == 'float32' else 2),
                    metrics=rows,
                    verification=dict(all_stored_nodes_exact=True, checked_node_count=NODES ** 3,
                                      exact_oracle_alpha_one=True, all_nodes_finite_in_unit_interval=True,
                                      rgba_rfast_all_nodes_match_independent_oracle=True,
                                      rgba_rfast_alpha_one=True, rgba32f_bytes=rgba_rfast.nbytes,
                                      rgba32f_sha256=hashlib.sha256(rgba_rfast.tobytes()).hexdigest()),
                ))

        # Check the CPU interpolator's axis mapping independently of HNCS.
        identity_out = lookup(node_coords, coords)
        identity_max = float(np.max(np.abs(identity_out - coords)))
        assert identity_max < 2e-7
        np.testing.assert_allclose(lab_d65(np.array([[0, 0, 0], [1, 1, 1]], np.float32)),
                                   [[0, 0, 0], [100, 0, 0]], atol=2e-5)
        after = {p: sha256(p) for p in before}
        assert before == after, 'A source or frozen baseline changed during the run'
        report = dict(
            status='passed',
            purpose='Additive default-6500-K accuracy evidence; no app/core changes or production acceptance claim',
            domain='finite linear-sRGB Float32 RGB [0,1]^3; HNCS EV=0, CCT=6500 K, legacy/standard',
            output='display-linear sRGB Float32; encoded metrics use Float32 sRGB OETF with no integer quantization',
            method=dict(
                seed=SEED, probes={name: len(values) for name, values in categories.items()},
                sample_count=len(x),
                generated_input_sha256=hashlib.sha256(np.ascontiguousarray(x, dtype='<f4').tobytes()).hexdigest(),
                probe_order=list(categories),
                probe_generation='Exact frozen-study RNG call order; 5500 K control independently reproduced against saved metrics',
                interpolation='Existing CPU float32 trilinear oracle; internal R-major/B-fast; exported RGBA R-fast/G-next/B-slowest',
                node_evaluation='Both frozen-study Float32 inverse sRGB and app-style Double inverse sRGB followed by Float32 cast',
                storage='Float32 main result; optional binary16 node rounding promoted to Float32 before CPU interpolation',
                metrics='Max/mean absolute RGB channel; mean and p95/p99 of per-pixel maximum absolute RGB channel; per-channel RMSE. DeltaE76 is CIELAB D65, not DeltaE2000.',
                limitations='Synthetic holdouts, not a formal worst-case bound, photo/camera validation, GPU arithmetic verification, or perceptual acceptance threshold. No Apple execution or device performance claim.'),
            verification=dict(
                frozen_files_unchanged=True, frozen_files_sha256={p: before[p] for p in FROZEN_PATHS},
                frozen_hncs_oracle_dependencies_match=True, core_sources_unchanged=True,
                control_5500_saved_metrics_match=True, control_5500_comparisons=comparisons,
                control_5500_worst_encoded_input_matches=True,
                identity_lookup_max_abs=identity_max, lab_black_white_sanity=True,
                grid_input_max_abs_between_node_evaluations=float(np.max(np.abs(study_grid - app_grid))),
                baked_node_max_abs_between_node_evaluations=float(np.max(np.abs(bakes['frozen_study_float32'] - bakes['app_double_then_float32'])))),
            environment=dict(platform=platform.platform(), numpy=np.__version__,
                             compiler=subprocess.check_output(['g++', '--version'], text=True).splitlines()[0],
                             command=command),
            source_sha256={p: before[p] for p in SOURCE_PATHS}, results=results,
        )
        path = ROOT / 'validation/lut-proxy-default-kelvin.json'
        path.write_text(json.dumps(report, indent=2) + '\n')
        for result in results:
            all_metrics = result['metrics']['all']
            print(result['node_evaluation'], result['storage'],
                  json.dumps({'encoded': all_metrics['encoded_srgb_float'],
                              'delta_e76': all_metrics['delta_e76_d65']}))
        print(path)
    finally:
        for context in contexts.values():
            lib.hncs_destroy(context)


if __name__ == '__main__':
    main()
