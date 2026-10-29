"""Float display-linear export retains reference precision and tiled identity."""
import ctypes as c
import itertools

import numpy as np
import pytest

from support import reference_runtime as r
from support.native import context, render

# The original Float32 export comparison allows 1e-7 against the double reference.
LINEAR_REFERENCE_TOLERANCE = 1e-7
CASES = tuple(itertools.product(('legacy', 'lstar'), ('standard', 'reproduction'), (2000, 5500, 10000), (-2, 0, 2)))


@pytest.fixture(scope='module')
def linear_pixels():
    return np.random.default_rng(1717).uniform(-.1, 1.2, (8192, 3)).astype(np.float32)


@pytest.mark.parametrize('space,intent,kelvin,exposure', CASES)
def test_float_export_matches_double_reference(native, reference_assets, linear_pixels, space, intent, kelvin, exposure):
    source = r.experimental_adapter(linear_pixels, kelvin, reference_assets, exposure)
    codes = r.hncs_codes(source, kelvin, reference_assets, intent, working_space=space)
    encoded = r.srgb_from_hncs(codes, reference_assets, space)
    expected = np.where(encoded <= .04045, encoded / 12.92, ((encoded + .055) / 1.055)**2.4)

    with context(native, kelvin=kelvin, ev=exposure, lstar=int(space == 'lstar'), repro=int(intent == 'reproduction')) as ctx:
        output_status, output = render(native, 'hncs_process_linear_rgba', ctx, linear_pixels)
        assert output_status == 0

    np.testing.assert_allclose(output[:, :3], expected, rtol=0, atol=LINEAR_REFERENCE_TOLERANCE)


@pytest.mark.parametrize('space,intent,kelvin,exposure', CASES)
def test_float_export_is_finite_bounded_and_opaque(native, linear_pixels, space, intent, kelvin, exposure):
    with context(native, kelvin=kelvin, ev=exposure, lstar=int(space == 'lstar'), repro=int(intent == 'reproduction')) as ctx:
        output_status, output = render(native, 'hncs_process_linear_rgba', ctx, linear_pixels)
        assert output_status == 0

    assert np.isfinite(output).all()
    assert np.logical_and(output >= 0, output <= 1).all()
    np.testing.assert_array_equal(output[:, 3], 1)


@pytest.mark.parametrize('space,intent,kelvin,exposure', CASES)
def test_float_export_tiles_match_full_raster(native, linear_pixels, space, intent, kelvin, exposure):
    with context(native, kelvin=kelvin, ev=exposure, lstar=int(space == 'lstar'), repro=int(intent == 'reproduction')) as ctx:
        expected_status, expected = render(native, 'hncs_process_linear_rgba', ctx, linear_pixels)
        assert expected_status == 0

        results = [render(native, 'hncs_process_linear_rgba', ctx, linear_pixels[start:start + 1000])
                   for start in range(0, len(linear_pixels), 1000)]
        output = np.concatenate([pixels for _, pixels in results])
        assert [status for status, _ in results] == [0] * len(results)

    np.testing.assert_array_equal(output, expected)


def test_gray_ramp_preserves_more_than_ten_bit_levels(native):
    source = np.repeat(np.linspace(0, 1, 4096, dtype=np.float32)[:, None], 3, axis=1)

    with context(native, kelvin=5500) as ctx:
        output_status, output = render(native, 'hncs_process_linear_rgba', ctx, source)
        assert output_status == 0

    assert min(np.unique(output[:, channel]).size for channel in range(3)) > 1024
    assert np.count_nonzero(np.abs(output[:, :3] * 255 - np.rint(output[:, :3] * 255)) > 1e-4) > 0


@pytest.mark.parametrize('case,expected', [('null-context', -1), ('empty', 0), ('null-input', -1),
                                          ('overflow', -1), ('nonfinite', -1)])
def test_invalid_float_export_arguments_fail(native, case, expected):
    source = np.zeros((1, 3), np.float32)
    output = np.empty((1, 4), np.float32)
    if case == 'nonfinite':
        source[0, 0] = np.nan
    with context(native, kelvin=5500) as ctx:
        args = [ctx, source.ctypes.data, output.ctypes.data, 1]
        if case == 'null-context': args = [None, None, None, 0]
        elif case == 'empty': args = [ctx, None, None, 0]
        elif case == 'null-input': args = [ctx, None, None, 1]
        elif case == 'overflow': args[-1] = c.c_size_t(-1).value

        status = native.hncs_process_linear_rgba(*args)

    assert status == expected
