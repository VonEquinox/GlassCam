"""Frozen FFCS stages, mobile output, worker modes, and strip boundaries."""
import ctypes as c
import itertools
import json
import math
import random
import struct
import zlib

import numpy as np
import pytest

from support import verify_ffcs_v020 as ffcs

# Preserve the delivered double-stage gate and Float32 mobile rounding budget.
STAGE_TOLERANCE = 1e-12
LINEAR_TOLERANCE = 2e-7
PREVIEW_CODE_TOLERANCE = 1
GOLDEN = json.loads((ffcs.V / 'ffcs-v020-stage-goldens.json').read_text())
STAGES = tuple(GOLDEN['records'][0]['stages'])
REPRESENTATIVES = (('XH2S', 0, .1, 1, 9), ('XA3', 12, .5, 9, 1),
    ('GFX100', 13, 1., 7, 13), ('GFX100S', 5, 1.5, 131, 9),
    ('GFX100II', 19, 2.25, 11, 17), ('GFX100II', 3, 3., 3, 2))
SWITCH_CASES = tuple(itertools.product(range(6), (False, True), (0, 1), (0, 1)))
WORKERS = (1, 2, 3, 4)
OUTPUT_MODES = ('both', 'float', 'preview')
BENCH_SHAPES = ((1, 1), (13, 1), (1, 13), (3, 7), (9, 131), (17, 29))


def case_id(case):
    index, overlay, grain, sharp = case
    camera, look, radius, width, height = REPRESENTATIVES[index]
    return f'{camera}-{look}-overlay{int(overlay)}-grain{grain}-sharp{sharp}-radius{radius}'


def strip_cases():
    cases = []
    for case in SWITCH_CASES:
        index, overlay, grain, sharp = case
        _, _, radius, width, height = REPRESENTATIVES[index]
        halo = math.ceil(3 * max(.1, radius)) if overlay and sharp else 0
        # This stream is shared across workers exactly as in the original gate.
        rng = random.Random(index + grain * 100 + sharp * 1000)
        for workers in WORKERS:
            y = 0
            while y < height:
                rows = min(height - y, 1 if workers == 1 else rng.randint(1, 5))
                first = max(0, y - halo - rng.randint(0, 2))
                last = min(height, y + rows + halo + rng.randint(0, 2))
                cases.append(pytest.param(case, workers, first, last, y, rows,
                    id=f'{case_id(case)}-workers{workers}-rows{y}:{y + rows}'))
                y += rows
    return cases


@pytest.fixture(scope='module')
def runtime(ffcs_resources):
    source = ffcs.load()
    if ffcs.source_stamp(source) != GOLDEN['source']:
        raise ValueError('Pinned FFCS source does not match the frozen stage vectors')
    lib, callback, _ = ffcs.build()
    return source, lib, callback


@pytest.fixture(scope='module')
def frozen_output(runtime):
    source, lib, callback = runtime
    cache = {}
    def observe(index):
        if index not in cache:
            record = GOLDEN['records'][index]
            error = c.create_string_buffer(1024)
            ctx = lib.ffcs_create_family_config(str(source / 'implementation/ffcs/data').encode(),
                record['camera'].encode(), record['index'], 1, 1, 0, 1, error, len(error))
            assert ctx, error.value
            try:
                cache[index] = (ffcs.encoded(lib, callback, ctx, np.asarray(GOLDEN['input'])),
                    lib.ffcs_asset_family(ctx).decode(), lib.ffcs_required_halo(ctx))
            finally:
                lib.ffcs_destroy(ctx)
        return cache[index]
    return observe


@pytest.mark.parametrize('index', range(len(GOLDEN['records'])),
    ids=[f"{r['camera']}-{r['look']}" for r in GOLDEN['records']])
@pytest.mark.parametrize('stage', STAGES)
def test_frozen_native_stage_matches_reference(frozen_output, index, stage):
    record = GOLDEN['records'][index]
    (status, output, stages, error), _, _ = frozen_output(index)
    expected = np.asarray(record['stages'][stage])

    assert status == 1, error
    # The former native comparison was strict (<), rather than inclusive (<=).
    np.testing.assert_array_less(np.abs(stages[stage] - expected), STAGE_TOLERANCE)


@pytest.mark.parametrize('index', range(len(GOLDEN['records'])))
def test_frozen_encoded_output_and_stage_map_are_complete(frozen_output, index):
    (status, output, stages, error), _, _ = frozen_output(index)

    assert set(stages) == set(STAGES)
    np.testing.assert_array_equal(output, stages['output_icc'])


@pytest.mark.parametrize('index', range(len(GOLDEN['records'])))
def test_frozen_family_and_bundled_asset_match_manifest(runtime, frozen_output, index):
    source, _, _ = runtime
    record = GOLDEN['records'][index]
    _, family, halo = frozen_output(index)

    assert family == record['asset'].split('/')[0]
    assert halo == 0
    assert ffcs.sha(source / 'implementation/ffcs/data' / record['asset']) == record['asset_sha256']
    assert ffcs.sha(ffcs.ROOT / 'App/GlassCam/Resources/FFCS' / record['asset']) == record['asset_sha256']


def test_native_simulation_catalog_matches_reference(runtime):
    _, lib, _ = runtime
    assert lib.ffcs_simulation_count() == len(ffcs.NAMES)
    assert tuple(lib.ffcs_simulation_name(i).decode() for i in range(len(ffcs.NAMES))) == ffcs.NAMES


@pytest.mark.parametrize('camera,index', tuple(itertools.product(ffcs.FAMILIES, range(20))))
def test_native_family_availability_matches_reference(runtime, camera, index):
    source, lib, _ = runtime
    available = {(cam, look) for cam, look, _ in ffcs.configured(source)}
    actual = lib.ffcs_simulation_available(str(source / 'implementation/ffcs/data').encode(), camera.encode(), index)
    assert bool(actual) == ((camera, index) in available)


@pytest.fixture(scope='module')
def switch_output(runtime):
    source, lib, callback = runtime
    from ffcs.color import srgb_decode, srgb_encode
    cache, contexts = {}, []
    def observe(case):
        if case not in cache:
            index, overlay, grain, sharp = case
            camera, look, radius, width, height = REPRESENTATIVES[index]
            error = c.create_string_buffer(1024)
            ctx = lib.ffcs_create_family_config(str(source / 'implementation/ffcs/data').encode(),
                camera.encode(), look, grain, sharp, overlay, radius, error, len(error))
            assert ctx, error.value
            contexts.append(ctx)
            data = ffcs.pixels(width, height)
            seed = (0, 37, 0xffffffff)[index % 3]
            exposure = c.c_float((-2, .7, 2)[index % 3]).value
            reference = ffcs.reference(data, camera, ffcs.NAMES[look], overlay, radius, grain, sharp, seed)
            linear = np.asarray(data, dtype=np.float32)
            exposed = np.clip(linear.astype(np.float64) * 2. ** exposure, 0, 1)
            encoded_input = np.vectorize(srgb_encode)(exposed)
            ref = ffcs.reference(encoded_input, camera, ffcs.NAMES[look], overlay, radius, grain, sharp, seed)
            direct = ffcs.reference(exposed, camera, ffcs.NAMES[look], overlay, radius, grain, sharp, seed, True)
            expected = np.asarray([[[srgb_decode(v) for v in rgb] for rgb in row] for row in ref.pixels], dtype=np.float32)
            cache[case] = dict(ctx=ctx, linear=linear, exposure=exposure, seed=seed,
                encoded=ffcs.encoded(lib, callback, ctx, data, seed), reference=reference,
                baseline=ffcs.linear(lib, ctx, linear, exposure, seed), expected=expected,
                reference_pixels=np.asarray(ref.pixels),
                direct_expected=np.asarray([[[srgb_decode(v) for v in rgb] for rgb in row]
                    for row in direct.pixels], dtype=np.float32),
                halo=lib.ffcs_required_halo(ctx))
        return cache[case]
    yield observe
    for ctx in contexts:
        lib.ffcs_destroy(ctx)


@pytest.mark.parametrize('case', SWITCH_CASES, ids=case_id)
@pytest.mark.parametrize('stage', STAGES)
def test_switch_encoded_stage_matches_reference(switch_output, case, stage):
    observed = switch_output(case)
    status, _, stages, error = observed['encoded']
    expected = np.asarray(observed['reference'].stage_pixels[stage])

    assert status == 1, error
    np.testing.assert_array_less(np.abs(stages[stage] - expected), STAGE_TOLERANCE)


@pytest.mark.parametrize('case', SWITCH_CASES, ids=case_id)
def test_switch_encoded_output_matches_final_stage(switch_output, case):
    observed = switch_output(case)
    _, output, stages, _ = observed['encoded']

    assert set(stages) == set(observed['reference'].stage_pixels)
    np.testing.assert_array_equal(output, stages['output_icc'])


@pytest.mark.parametrize('case', SWITCH_CASES, ids=case_id)
def test_mobile_linear_output_matches_both_reference_input_domains(switch_output, case):
    observed = switch_output(case)
    status, output, _, error = observed['baseline']

    assert status == 1, error
    np.testing.assert_allclose(output, observed['direct_expected'], rtol=0, atol=LINEAR_TOLERANCE)
    np.testing.assert_allclose(output, observed['expected'], rtol=0, atol=LINEAR_TOLERANCE)


@pytest.mark.parametrize('case', SWITCH_CASES, ids=case_id)
def test_mobile_preview_matches_reference_codes_and_opaque_alpha(switch_output, case):
    observed = switch_output(case)
    _, _, preview, _ = observed['baseline']
    expected = np.rint(observed['reference_pixels'] * 255).astype(np.int16)

    np.testing.assert_allclose(preview[..., :3].astype(np.int16), expected, rtol=0, atol=PREVIEW_CODE_TOLERANCE)
    np.testing.assert_array_equal(preview[..., 3], 255)


@pytest.mark.parametrize('case', SWITCH_CASES, ids=case_id)
@pytest.mark.parametrize('workers', WORKERS)
@pytest.mark.parametrize('mode', OUTPUT_MODES)
def test_switch_optimized_output_modes_preserve_baseline_bits(runtime, switch_output, case, workers, mode):
    _, lib, _ = runtime
    observed = switch_output(case)

    status, output, preview, error = ffcs.linear(lib, observed['ctx'], observed['linear'],
        observed['exposure'], observed['seed'], workers, mode, unused_capacity=True)

    assert status == 1, error
    if output is not None:
        np.testing.assert_array_equal(output.view(np.uint32), observed['baseline'][1].view(np.uint32))
    if preview is not None:
        np.testing.assert_array_equal(preview, observed['baseline'][2])


@pytest.mark.parametrize('case', SWITCH_CASES, ids=case_id)
def test_required_halo_matches_reference_radius(switch_output, case):
    index, overlay, _, sharp = case
    radius = REPRESENTATIVES[index][2]
    expected = math.ceil(3 * max(.1, radius)) if overlay and sharp else 0
    assert switch_output(case)['halo'] == expected


@pytest.mark.parametrize('case,workers,first,last,y,rows', strip_cases())
def test_switch_strips_preserve_full_frame_bits(runtime, switch_output, case, workers, first, last, y, rows):
    _, lib, _ = runtime
    observed = switch_output(case)
    height, width = observed['linear'].shape[:2]
    source = np.ascontiguousarray(observed['linear'][first:last])

    status, output, error = ffcs.strip(lib, observed['ctx'], source, width, height, first, y, rows,
        observed['exposure'], observed['seed'], workers)

    assert status == 1, error
    np.testing.assert_array_equal(output.view(np.uint32), observed['baseline'][1][y:y + rows].view(np.uint32))


@pytest.mark.parametrize('case', [case for case in SWITCH_CASES
    if case[1] and case[3] and REPRESENTATIVES[case[0]][4] > 2], ids=case_id)
def test_missing_required_halo_preserves_output_and_returns_diagnostic(runtime, switch_output, case):
    _, lib, _ = runtime
    observed = switch_output(case)
    height, width = observed['linear'].shape[:2]
    source = np.ascontiguousarray(observed['linear'][1:2])

    status, output, error = ffcs.strip(lib, observed['ctx'], source, width, height, 1, 1, 1,
        observed['exposure'], observed['seed'], 1)

    assert status == 0
    np.testing.assert_array_equal(output, np.full_like(source, -7))
    assert error


@pytest.fixture(scope='module')
def benchmark_inputs():
    rng = np.random.default_rng(48219)
    samples = {}
    # One original stream, consumed look first and shape second.
    for look in range(19):
        for height, width in BENCH_SHAPES:
            source = rng.uniform(-.3, 1.4, (height, width, 3)).astype(np.float32)
            source[0, 0] = [0., .0031308, 1.]
            samples[look, height, width] = source
    return samples


@pytest.fixture(scope='module')
def benchmark_output(runtime, benchmark_inputs):
    source, lib, _ = runtime
    cache, contexts = {}, {}
    def observe(look, height, width):
        if look not in contexts:
            error = c.create_string_buffer(1024)
            contexts[look] = lib.ffcs_create(str(source / 'implementation/ffcs/data/xh2s').encode(),
                look, error, len(error))
            assert contexts[look], error.value
        key = (look, height, width)
        if key not in cache:
            cache[key] = ffcs.linear(lib, contexts[look], benchmark_inputs[key])
        return contexts[look], benchmark_inputs[key], cache[key]
    yield observe
    for ctx in contexts.values():
        lib.ffcs_destroy(ctx)


@pytest.mark.parametrize('look', range(19))
@pytest.mark.parametrize('height,width', BENCH_SHAPES)
@pytest.mark.parametrize('workers', WORKERS)
@pytest.mark.parametrize('mode', OUTPUT_MODES)
def test_original_benchmark_borders_and_modes_preserve_baseline_bits(runtime, benchmark_output, look, height, width, workers, mode):
    _, lib, _ = runtime
    ctx, source, baseline = benchmark_output(look, height, width)

    status, output, preview, error = ffcs.linear(lib, ctx, source, workers=workers, mode=mode)

    assert baseline[0] == 1, baseline[3]
    assert status == 1, error
    if output is not None:
        np.testing.assert_array_equal(output.view(np.uint32), baseline[1].view(np.uint32))
    if preview is not None:
        np.testing.assert_array_equal(preview, baseline[2])


@pytest.mark.parametrize('look', range(19))
@pytest.mark.parametrize('invalid,value', [('workers', 0), ('workers', 5), ('workers', 4294967295),
    ('mode', 'neither'), ('exposure', np.nan), ('exposure', np.inf), ('exposure', -33.),
    ('exposure', 33.), ('pixel', np.nan)])
def test_original_benchmark_invalid_inputs_are_rejected(runtime, benchmark_output, look, invalid, value):
    _, lib, _ = runtime
    ctx, source, _ = benchmark_output(look, *BENCH_SHAPES[-1])
    kwargs = {'workers': 1}
    if invalid == 'pixel':
        source = source.copy()
        source[0, 0, 0] = value
    else:
        kwargs[invalid] = value

    status, _, _, _ = ffcs.linear(lib, ctx, source, **kwargs)

    assert status == 0


def corrupt_container(original, case):
    header = 60 if original[:8] == b'FFCSLUT2' else 56
    length_offset = 56 if header == 60 else 52
    def compressed(blob):
        data = bytearray(original[:header])
        struct.pack_into('<I', data, length_offset, len(blob))
        return bytes(data) + blob
    blobs = {'bad_magic': b'INVALID!' + original[8:], 'truncated_header': original[:20],
        'truncated_file': original[:-1], 'trailing_file': original + b'x',
        'trailing_stream': compressed(original[header:] + b'x'),
        'concatenated_stream': compressed(original[header:] + zlib.compress(b'extra')),
        'incomplete_stream': compressed(original[header:-3]),
        'short_payload': compressed(zlib.compress(b'\0' * 6))}
    if case in blobs:
        return blobs[case]
    changes = {'bad_channels': (10, 'H', 4), 'zero_size': (8, 'H', 0),
        'nan_scale': (12, 'f', np.nan), 'zero_scale': (12, 'f', 0),
        'nan_matrix': (16, 'f', np.nan), 'unknown_flags': (52, 'B', 2)}
    if case == 'unknown_flags' and header != 60:
        pytest.skip('The pinned container has no flags field')
    offset, format, value = changes[case]
    data = bytearray(original)
    struct.pack_into('<' + format, data, offset, value)
    return bytes(data)


@pytest.mark.parametrize('case', ['bad_magic', 'truncated_header', 'truncated_file', 'trailing_file',
    'trailing_stream', 'concatenated_stream', 'incomplete_stream', 'short_payload', 'bad_channels',
    'zero_size', 'nan_scale', 'zero_scale', 'nan_matrix', 'unknown_flags'])
def test_invalid_lut_container_returns_diagnostic(runtime, tmp_path, case):
    source, lib, _ = runtime
    original = (source / 'implementation/ffcs/data/xh2s/provia.lutz').read_bytes()
    (tmp_path / 'provia.lutz').write_bytes(corrupt_container(original, case))
    error = c.create_string_buffer(1024)

    ctx = lib.ffcs_create_config(str(tmp_path).encode(), 0, 1, 1, 0, 1, error, len(error))
    if ctx:
        lib.ffcs_destroy(ctx)

    assert not ctx
    assert error.value


@pytest.mark.parametrize('grain,sharp,overlay,radius', [(1, 1, 1, radius) for radius in (0, -1, np.nan, np.inf, 65)]
    + [(grain, sharp, overlay, 1) for grain, sharp, overlay in ((2, 1, 1), (1, -1, 1), (1, 1, 2))])
def test_invalid_radius_or_flags_return_diagnostic(runtime, tmp_path, grain, sharp, overlay, radius):
    source, lib, _ = runtime
    (tmp_path / 'provia.lutz').write_bytes((source / 'implementation/ffcs/data/xh2s/provia.lutz').read_bytes())
    error = c.create_string_buffer(1024)

    ctx = lib.ffcs_create_config(str(tmp_path).encode(), 0, grain, sharp, overlay, radius, error, len(error))
    if ctx:
        lib.ffcs_destroy(ctx)

    assert not ctx
    assert error.value
