"""Native HNCS preset stages match the pinned independent references."""
import ctypes as c
import hashlib
import itertools
import json

import numpy as np
import pytest

from support import reference_runtime as r
from support.phocus_binary_reference import presets
from support.native import bridge, context, preset, render

FACTORY_PRESETS = tuple(presets.FACTORY_SETTING_FILES)
UNIQUE_PRESETS = tuple(next(key for key, path in presets.FACTORY_SETTING_FILES.items() if path == filename)
                      for filename in dict.fromkeys(presets.FACTORY_SETTING_FILES.values()))
FILMS = {0: 'old-standard', 1: 'high-contrast', 2: 'standard', 4: 'as-shot', 6: 'low-contrast', 7: 'linear'}
FILM_RAW_CASES = [(film, raw) for film in FILMS for raw in ((0, 2, 4, 7, 99) if film == 4 else (2,))]
# Existing display checks permit Float32 rounding to 1e-7 and one fast byte code.
FLOAT_TOLERANCE = 1e-7
FAST_BYTE_TOLERANCE = 1


@pytest.fixture(scope='module')
def preset_inputs():
    rng = np.random.default_rng(8137)
    return (rng.integers(0, 65536, (97, 99, 3), dtype=np.uint16),
            rng.uniform(-.2, 1.2, (64, 129, 3)).astype(np.float64),
            rng.uniform(-.1, 1.1, (257, 259, 3)).astype(np.float32))


@pytest.fixture(scope='module')
def postcurve_vectors():
    path = r.REFERENCE / 'work/hncs-pipeline/evidence/native_preset_vectors.npz'
    assert hashlib.sha256(path.read_bytes()).hexdigest() == presets.catalog()['binary_evidence']['post_curves']['native_vector_sha256']
    with np.load(path, allow_pickle=False) as vectors:
        yield vectors


def test_preset_catalog_has_unique_factory_payloads(native):
    keys = [native.hncs_preset_key(index).decode() for index in range(native.hncs_preset_count())]
    assert len(keys) == 43
    assert len(set(keys)) == 43
    assert {presets.FACTORY_SETTING_FILES[key] for key in keys} == set(presets.FACTORY_SETTING_FILES.values())


@pytest.mark.parametrize('function,argument,expected', [('hncs_preset_key', 43, None), ('hncs_preset_name', 43, None),
    ('hncs_preset_flags', b'unknown', 2**32 - 1), ('hncs_preset_settings_json', b'unknown', None)])
def test_unknown_preset_lookup_is_rejected(native, function, argument, expected):
    assert getattr(native, function)(argument) == expected


@pytest.mark.parametrize('key', FACTORY_PRESETS)
def test_factory_parameters_match_reference(native, key):
    expected = {field: value for field, value in presets.settings(key).items() if field != 'name'}

    actual = json.loads(native.hncs_preset_settings_json(key.encode()))

    assert {field: actual[field] for field in expected} == expected


@pytest.mark.parametrize('key', ['standard', 'nature', 'lighten', 'extra-contrast'])
@pytest.mark.parametrize('tone', [0, 1])
@pytest.mark.parametrize('group', ['source', 'ramp'])
def test_native_postcurves_match_original_vectors(native, postcurve_vectors, key, tone, group):
    record = presets.catalog()['binary_evidence']['post_curves']['source_files'][presets.FACTORY_SETTING_FILES[key]]['modes']['tone' if tone else 'no_tone']
    prefix = record['vector_key']
    source = postcurve_vectors[prefix + '_source'] if group == 'source' else np.repeat(np.arange(65536, dtype=np.uint16)[:, None], 3, axis=1)
    original = postcurve_vectors[prefix + ('_output' if group == 'source' else '_ramp')]
    expected, _ = presets.apply_post_curves(source, key, apply_tone_curve=bool(tone))

    output = preset(native, 'hncs_apply_post_curves', key, tone, source)

    np.testing.assert_array_equal(output, expected)
    np.testing.assert_array_equal(output, original)


@pytest.mark.parametrize('key', FACTORY_PRESETS)
@pytest.mark.parametrize('tone', [0, 1])
def test_pointwise_preset_matches_reference(native, preset_inputs, key, tone):
    source = preset_inputs[0]
    expected, _ = presets.apply_preset(source, key, apply_sharpness=False, apply_grain=False, apply_tone_curve=bool(tone))

    output = preset(native, 'hncs_apply_preset_pointwise', key, tone, source)

    np.testing.assert_array_equal(output, expected)


@pytest.mark.parametrize('key', UNIQUE_PRESETS)
@pytest.mark.parametrize('tone', [0, 1])
def test_all_neutral_codes_match_preset_reference(native, key, tone):
    source = np.repeat(np.arange(65536, dtype=np.uint16)[:, None], 3, axis=1)
    expected, _ = presets.apply_preset(source.reshape(256, 256, 3), key, apply_sharpness=False, apply_grain=False, apply_tone_curve=bool(tone))

    output = preset(native, 'hncs_apply_preset_pointwise', key, tone, source)

    np.testing.assert_array_equal(output.reshape(256, 256, 3), expected)


@pytest.mark.parametrize('lstar,repro,kelvin', tuple(itertools.product((0, 1), (0, 1), (2000, 5550, 10000))))
@pytest.mark.parametrize('film,raw', FILM_RAW_CASES)
def test_film_resolution_matches_reference(native, reference_assets, preset_inputs, lstar, repro, kelvin, film, raw):
    source = preset_inputs[1]
    expected = r.hncs_codes(source, kelvin, reference_assets, intent='reproduction' if repro else 'standard',
        working_space='lstar' if lstar else 'legacy', film_curve=FILMS[film], raw_film_curve=raw)

    with context(native, key='standard', kelvin=kelvin, lstar=lstar, repro=repro, film=film, raw=raw) as ctx:
        output = render(native, 'hncs_render_native', ctx, source, np.uint16, 3)

    np.testing.assert_array_equal(output, expected)


@pytest.mark.parametrize('key', UNIQUE_PRESETS)
@pytest.mark.parametrize('tone', [0, 1])
def test_native_core_and_preset_composition_matches_reference(native, reference_assets, preset_inputs, key, tone):
    source = preset_inputs[1]
    kelvin = presets.settings(key)['color_temperature'] or 6500
    codes = r.hncs_codes(source, kelvin, reference_assets, working_space='legacy')
    expected, _ = presets.apply_preset(codes, key, apply_sharpness=False, apply_grain=False, apply_tone_curve=bool(tone))

    with context(native, key=key, tone=tone) as ctx:
        output = render(native, 'hncs_render_native_preset', ctx, source, np.uint16, 3)

    np.testing.assert_array_equal(output, expected)


@pytest.mark.parametrize('kelvin,exposure', tuple(itertools.product((1000, 2000, 5500, 6500, 10000, 15000), (-2, 0, 2))))
@pytest.mark.parametrize('function,dtype,tolerance', [('hncs_process_srgb', np.uint8, 0),
    ('hncs_process_srgb_fast', np.uint8, FAST_BYTE_TOLERANCE), ('hncs_process_linear_rgba', np.float32, FLOAT_TOLERANCE)])
def test_standard_display_matches_corrected_gradation(native, reference_assets, preset_inputs, kelvin, exposure, function, dtype, tolerance):
    source = preset_inputs[2]
    converted = r.experimental_adapter(source, kelvin, reference_assets, exposure)
    codes = r.hncs_codes(converted, kelvin, reference_assets, working_space='legacy')
    codes, _ = presets.apply_preset(codes, 'standard', apply_sharpness=False, apply_grain=False)
    encoded = r.srgb_from_hncs(codes, reference_assets, 'legacy')
    expected = np.where(encoded <= .04045, encoded / 12.92, ((encoded + .055) / 1.055)**2.4) if dtype == np.float32 else np.rint(encoded * 255).astype(np.uint8)

    with context(native, key='standard', kelvin=kelvin, ev=exposure) as ctx:
        output = render(native, function, ctx, source, dtype, 4)

    np.testing.assert_allclose(output[..., :3], expected, rtol=0, atol=tolerance)
    np.testing.assert_array_equal(output[..., 3], 1 if dtype == np.float32 else 255)


@pytest.mark.parametrize('kelvin,exposure', tuple(itertools.product((1000, 2000, 5500, 6500, 10000, 15000), (-2, 0, 2))))
def test_standard_preset_preserves_bare_adapter_matrix(native, kelvin, exposure):
    with context(native, kelvin=kelvin, ev=exposure) as old, context(native, key='standard', kelvin=kelvin, ev=exposure) as new:
        expected = bridge(native, old)

        actual = bridge(native, new)

    np.testing.assert_array_equal(actual, expected)


@pytest.mark.parametrize('key', UNIQUE_PRESETS)
def test_work_finish_split_preserves_direct_output(native, preset_inputs, key):
    source = np.ascontiguousarray(preset_inputs[2][:13, :19])
    with context(native, key=key) as ctx:
        expected = render(native, 'hncs_process_linear_rgba', ctx, source)

        work = render(native, 'hncs_process_preset_work_float', ctx, source, np.float32, 3)
        output = render(native, 'hncs_finish_preset_work_linear', ctx, work)

    np.testing.assert_array_equal(output, expected)


@pytest.mark.parametrize('workers', [1, 2, 3, 4])
def test_preset_parallel_output_matches_direct(native, preset_inputs, workers):
    source = preset_inputs[2]
    with context(native, key='extra-contrast') as ctx:
        expected = render(native, 'hncs_process_linear_rgba', ctx, source)

        output = render(native, 'hncs_process_linear_rgba_parallel', ctx, source, np.float32, 4, workers)

    np.testing.assert_array_equal(output, expected)


@pytest.mark.parametrize('capture', [2000, 3050, 5550, 6500, 9100, 10000])
@pytest.mark.parametrize('key', UNIQUE_PRESETS)
def test_absolute_preset_white_balance_replaces_capture_gain(native, reference_assets, capture, key):
    cfg = presets.settings(key)
    baseline = r.namespace['lerp_table'](capture, reference_assets['wb_temperatures'], reference_assets['factory_wb'])
    baseline = baseline / baseline[1]
    desired = cfg['native_wb_gains']
    with context(native, key='standard', kelvin=capture) as plain:
        expected = bridge(native, plain)
    if desired is not None: expected = expected * (np.asarray(desired) / baseline)[:, None]
    with context(native, key=key, kelvin=capture) as ctx:
        actual_baseline, actual_target, factory = np.empty(3), np.empty(3), np.empty(1)

        actual = bridge(native, ctx)
        status = native.hncs_preset_white_balance(ctx, actual_baseline.ctypes.data, actual_target.ctypes.data, factory.ctypes.data)

    assert status == 0
    np.testing.assert_array_equal(actual, expected)
    np.testing.assert_array_equal(actual_baseline, baseline)
    np.testing.assert_array_equal(actual_target, baseline if desired is None else desired)
    assert factory[0] == (cfg['color_temperature'] or capture)


@pytest.mark.parametrize('factory', [5500, 2850])
def test_explicit_gain_ratio_is_independent_of_factory_kelvin(native, factory):
    baseline, target = np.array([4., 2., 3.]), np.array([9., 3., 6.])
    with context(native, key='standard') as plain:
        expected = bridge(native, plain) * ((target / target[1]) / (baseline / baseline[1]))[:, None]

    with context(native, key='standard', baseline=baseline, target=target, factory=factory) as ctx:
        actual = bridge(native, ctx)

    np.testing.assert_array_equal(actual, expected)


def invalid_context(native, **changes):
    values = dict(ev=0., capture=6500., factory=0., lstar=0, repro=0, film=4, raw=2, key=b'standard', tone=1, base=None, target=None)
    values.update(changes)
    return native.hncs_create_preset(*values.values())


@pytest.mark.parametrize('changes', [{'ev': np.nan}, {'capture': np.inf}, {'factory': np.nan}, {'ev': 21},
    {'lstar': 2}, {'repro': -1}, {'film': 3}, {'tone': 2}, {'key': b'unknown'}])
def test_invalid_preset_settings_reject_context(native, changes):
    assert not invalid_context(native, **changes)


@pytest.mark.parametrize('gain', [[0, 1, 1], [-1, 1, 1], [1, np.nan, 1], [1, np.inf, 1], [1e308, 1e-308, 1]])
@pytest.mark.parametrize('field', ['base', 'target'])
def test_invalid_white_balance_gain_rejects_context(native, gain, field):
    values = np.array(gain, dtype=np.float64)
    assert not invalid_context(native, **{field: values.ctypes.data})


@pytest.mark.parametrize('function', ['hncs_apply_post_curves', 'hncs_apply_preset_pointwise', 'hncs_apply_preset_work_float'])
@pytest.mark.parametrize('key,tone,source,output,count,expected', [(b'standard', 1, None, None, 0, 0),
    (b'unknown', 1, None, None, 0, -1), (b'standard', 2, None, None, 0, -1),
    (b'standard', 1, None, None, 1, -1), (b'standard', 1, 1, 1, (2**(c.sizeof(c.c_size_t)*8)-1)//4, -1)])
def test_preset_invalid_buffer_contract(native, function, key, tone, source, output, count, expected):
    assert getattr(native, function)(key, tone, source, output, count) == expected


@pytest.mark.parametrize('function', ['hncs_process_preset_work_float', 'hncs_finish_preset_work_linear'])
def test_nonfinite_preset_work_is_rejected(native, function):
    source = np.array([[np.nan, 0, 0]], np.float32)
    output = np.zeros((1, 4), np.float32)
    with context(native, key='standard') as ctx:
        status = getattr(native, function)(ctx, source.ctypes.data, output.ctypes.data, 1)
    assert status == -1
