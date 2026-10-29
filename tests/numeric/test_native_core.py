"""HNCS native core preserves golden values, bounds, and display output."""
import ctypes as c

import numpy as np
import pytest

from support import reference_runtime as r
from support.native import context, render

# The existing 8-bit display adapter gate allows one final rounding code.
DISPLAY_CODE_TOLERANCE = 1
GOLDEN_PATH = r.REFERENCE / 'work/hncs-phocus-audit/evidence/native_kernel_vectors.npz'
with np.load(GOLDEN_PATH, allow_pickle=False) as vectors:
    GOLDEN_KEYS = tuple(key for key in vectors.files if key.endswith('_source'))


@pytest.mark.parametrize('key', GOLDEN_KEYS)
def test_original_native_golden_vectors_match(native, key):
    space, intent, kelvin, _ = key.split('_')
    with np.load(GOLDEN_PATH, allow_pickle=False) as vectors:
        source = vectors[key].astype(float) / 65535
        expected = vectors[key.replace('_source', '_output')]

    with context(native, kelvin=int(kelvin), lstar=int(space == 'lstar'), repro=int(intent == 'reproduction')) as ctx:
        output_status, output = render(native, 'hncs_render_native', ctx, source, np.uint16, 3)
        assert output_status == 0

    np.testing.assert_array_equal(output, expected)


@pytest.fixture(scope='module')
def core_samples():
    rng = np.random.default_rng(928)
    boundaries = np.concatenate([rng.uniform(-.2, 1.2, (8000, 3)),
        np.repeat((np.arange(256) + .5)[:, None] / 65535, 3, axis=1),
        np.array([[0, 0, 0], [1, 1, 1], [-1, -1, -1], [2, 2, 2]])])
    return boundaries, rng.uniform(0, 1, (103, 97, 3)).astype(np.float32)


@pytest.mark.parametrize('space', ['legacy', 'lstar'])
@pytest.mark.parametrize('intent', ['standard', 'reproduction'])
@pytest.mark.parametrize('kelvin', [1000, 2000, 2400, 2716, 3050, 5500, 7625, 10000, 15000])
def test_random_and_boundary_native_codes_match_reference(native, reference_assets, core_samples, space, intent, kelvin):
    source = core_samples[0]
    expected = r.reference.render(source, kelvin, reference_assets, space, intent)

    with context(native, kelvin=kelvin, lstar=int(space == 'lstar'), repro=int(intent == 'reproduction')) as ctx:
        output_status, output = render(native, 'hncs_render_native', ctx, source, np.uint16, 3)
        assert output_status == 0

    np.testing.assert_array_equal(output, expected)


@pytest.mark.parametrize('kelvin', [2000, 5500, 10000])
@pytest.mark.parametrize('exposure', [-2, 0, 2])
def test_display_adapter_matches_reference_with_byte_rounding(native, reference_assets, core_samples, kelvin, exposure):
    source = core_samples[1]
    expected = np.uint8(np.rint(r.effect(source, kelvin, reference_assets, exposure) * 255))

    with context(native, kelvin=kelvin, ev=exposure) as ctx:
        output_status, output = render(native, 'hncs_process_srgb', ctx, source, np.uint8, 4)
        assert output_status == 0

    assert np.abs(output[..., :3].astype(int) - expected.astype(int)).max() <= DISPLAY_CODE_TOLERANCE
    np.testing.assert_array_equal(output[..., 3], 255)


def test_display_tiles_preserve_full_output(native, core_samples):
    source = core_samples[1]
    with context(native, kelvin=5500) as ctx:
        expected_status, expected = render(native, 'hncs_process_srgb', ctx, source, np.uint8, 4)
        assert expected_status == 0

        results = [render(native, 'hncs_process_srgb', ctx, part, np.uint8, 4)
                   for part in np.array_split(source, 11)]
        output = np.concatenate([pixels for _, pixels in results])
        assert [status for status, _ in results] == [0] * len(results)

    np.testing.assert_array_equal(output, expected)


@pytest.mark.parametrize('bad', [np.nan, np.inf])
def test_nonfinite_kelvin_rejects_context(native, bad):
    assert not native.hncs_create_mode(0, bad, 0, 0)


@pytest.mark.parametrize('function,dtype', [('hncs_render_native', np.float64), ('hncs_process_srgb', np.float32)])
@pytest.mark.parametrize('bad', [np.nan, np.inf])
def test_nonfinite_pixel_is_rejected(native, function, dtype, bad):
    source = np.array([[bad, 0, 0]], dtype=dtype)
    output = np.empty((1, 4), np.float64)
    with context(native, kelvin=5500) as ctx:
        status = getattr(native, function)(ctx, source.ctypes.data, output.ctypes.data, 1)
    assert status == -1


def test_invalid_working_space_rejects_context(native):
    assert not native.hncs_create_mode(0, 5500, 2, 0)


@pytest.mark.parametrize('has_context,count,expected', [(False, 0, -1), (True, 0, 0), (True, 1, -1)])
def test_native_null_buffer_contract(native, has_context, count, expected):
    with context(native, kelvin=5500) as ctx:
        status = native.hncs_render_native(ctx if has_context else None, None, None, count)
    assert status == expected
