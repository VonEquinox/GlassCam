"""The native per-photo white balance adapter matches the pinned oracle."""
from contextlib import contextmanager
import ctypes as c

import numpy as np
import pytest

from support import reference_runtime as reference

# Existing double whitepoint/matrix budgets and Float32 neutral-axis budget.
GAIN_TOLERANCE = 3e-15
MATRIX_TOLERANCE = 4e-15
NEUTRAL_TOLERANCE = 4e-7
NATURE_TOLERANCE = 1e-7
TEMPERATURE_TINT = ((.44757, .40745), (.34567, .35850), (.3127, .3290),
    (.285, .299), (.339429795742, .352590560913), (.34, .32), (.34, .38))
ADAPTER_WHITES = ((.44757, .40745), (.3127, .3290), (.34, .32), (.34, .38))
ADAPTER_PRESETS = ('standard', 'tungsten', 'daylight', 'cloudy', 'flash', 'square-crop', 'film-grain-artistic')
PHOTO_WHITES = ((.33209389448165894, .36442223191261292),
    (.33567193150520325, .37427031993865967), (.33416590094566345, .3648126423358917),
    (.44757, .40745), (.3127, .3290), (.34, .32), (.34, .38))
PHOTO_PRESETS = ('standard', 'nature', 'tungsten', 'daylight', 'cloudy', 'saturated', 'square-crop')


@pytest.fixture(scope='module')
def white_balance(native):
    native.hncs_whitepoint_parameters.argtypes = [c.c_double, c.c_double, c.c_void_p, c.c_void_p]
    native.hncs_create_preset_whitepoint.argtypes = [c.c_double] * 4 + [c.c_int] * 4 + [c.c_char_p, c.c_int]
    native.hncs_create_preset_whitepoint.restype = c.c_void_p
    native.hncs_create_preset_whitepoint_with_policy.argtypes = native.hncs_create_preset_whitepoint.argtypes + [c.c_int]
    native.hncs_create_preset_whitepoint_with_policy.restype = c.c_void_p
    native.hncs_process_phocus_linear_rgba.argtypes = [c.c_void_p] * 3 + [c.c_size_t]
    return native


def parameters(lib, x, y):
    gains, kelvin = np.zeros(3, dtype=np.float64), c.c_double()
    status = lib.hncs_whitepoint_parameters(x, y, gains.ctypes.data, c.byref(kelvin))
    return status, gains, kelvin.value


@contextmanager
def whitepoint_context(lib, x, y, key='standard', override=0, lstar=0, policy=None):
    args = [0, x, y, override, lstar, 0, 4, 2, key.encode(), 1]
    ctx = (lib.hncs_create_preset_whitepoint(*args) if policy is None
        else lib.hncs_create_preset_whitepoint_with_policy(*args, policy))
    assert ctx
    try:
        yield ctx
    finally:
        lib.hncs_destroy(ctx)


@pytest.mark.parametrize('x,y', TEMPERATURE_TINT)
def test_gains_and_cct_match_reference_for_temperature_and_tint(white_balance, reference_assets, x, y):
    response = reference_assets['camera_to_xyz'][2] @ np.diag(reference_assets['factory_wb'][1])
    neutral = np.linalg.solve(response, [x / y, 1, (1 - x - y) / y])
    expected = neutral[1] / neutral
    reference_cct, _ = reference.estimate_cct(expected, reference_assets)

    status, actual, kelvin = parameters(white_balance, x, y)

    assert status == 0
    np.testing.assert_allclose(actual, expected, rtol=0, atol=GAIN_TOLERANCE)
    assert kelvin == np.clip(reference_cct, 2000, 10000)


@pytest.fixture(scope='module')
def adapter_output(white_balance, reference_assets):
    cache = {}
    def observe(x, y, key):
        if (x, y, key) not in cache:
            response = reference_assets['camera_to_xyz'][2] @ np.diag(reference_assets['factory_wb'][1])
            white = np.array([x / y, 1, (1 - x - y) / y])
            neutral = np.linalg.solve(response, white)
            parameter_status, baseline, _ = parameters(white_balance, x, y)
            cat = np.linalg.inv(reference.BRADFORD) @ np.diag((reference.BRADFORD @ white)
                / (reference.BRADFORD @ reference.D65)) @ reference.BRADFORD
            unbalanced = np.linalg.solve(response, cat @ reference.SRGB_TO_XYZ)
            configured = reference.presets.settings(key).get('native_wb_gains')
            desired = baseline if configured is None else np.array(configured) / configured[1]
            with whitepoint_context(white_balance, x, y, key) as ctx:
                capture, target, factory, actual = np.zeros(3), np.zeros(3), c.c_double(), np.zeros((3, 3))
                gain_status = white_balance.hncs_preset_white_balance(ctx, capture.ctypes.data, target.ctypes.data, c.byref(factory))
                matrix_status = white_balance.hncs_source_to_native_matrix(ctx, actual.ctypes.data)
            cache[x, y, key] = dict(parameter_status=parameter_status, gain_status=gain_status,
                matrix_status=matrix_status, capture=capture, baseline=baseline, target=target, desired=desired,
                actual=actual, expected=np.diag(desired / neutral[1]) @ unbalanced)
        return cache[x, y, key]
    return observe


@pytest.mark.parametrize('x,y', ADAPTER_WHITES)
@pytest.mark.parametrize('key', ADAPTER_PRESETS)
def test_absolute_preset_gains_replace_capture_gain(adapter_output, x, y, key):
    observed = adapter_output(x, y, key)
    assert observed['parameter_status'] == 0
    assert observed['gain_status'] == 0
    np.testing.assert_allclose(observed['capture'], observed['baseline'], rtol=0, atol=GAIN_TOLERANCE)
    np.testing.assert_allclose(observed['target'], observed['desired'], rtol=0, atol=GAIN_TOLERANCE)


@pytest.mark.parametrize('x,y', ADAPTER_WHITES)
@pytest.mark.parametrize('key', ADAPTER_PRESETS)
def test_adapter_matrix_matches_absolute_gain_reference(adapter_output, x, y, key):
    observed = adapter_output(x, y, key)
    assert observed['matrix_status'] == 0
    np.testing.assert_allclose(observed['actual'], observed['expected'], rtol=0, atol=MATRIX_TOLERANCE)


@pytest.mark.parametrize('x,y', ADAPTER_WHITES)
def test_standard_white_balance_preserves_neutral_axis(adapter_output, x, y):
    matrix = adapter_output(x, y, 'standard')['actual']
    np.testing.assert_allclose(matrix @ np.ones(3), 1, rtol=0, atol=NEUTRAL_TOLERANCE)


def test_adapter_matrix_responds_to_tint(adapter_output):
    low = adapter_output(.34, .32, 'standard')['actual']
    high = adapter_output(.34, .38, 'standard')['actual']
    assert np.max(np.abs(high - low)) > .01


@pytest.mark.parametrize('x,y', [(np.nan, .3), (.3, np.inf), (0, .3), (.3, 0), (-.3, .3), (.7, .4), (.99, .001)])
def test_invalid_whitepoints_reject_parameters_and_context(white_balance, x, y):
    status, _, _ = parameters(white_balance, x, y)
    ctx = white_balance.hncs_create_preset_whitepoint(0, x, y, 0, 0, 0, 4, 2, b'standard', 1)
    if ctx:
        white_balance.hncs_destroy(ctx)
    assert status == -1
    assert not ctx


@pytest.mark.parametrize('exposure,key', [(np.nan, b'standard'), (0, b'missing')])
def test_invalid_whitepoint_constructor_arguments_are_rejected(white_balance, exposure, key):
    ctx = white_balance.hncs_create_preset_whitepoint(exposure, .3127, .329, 0, 0, 0, 4, 2, key, 1)
    if ctx:
        white_balance.hncs_destroy(ctx)
    assert not ctx


@pytest.fixture(scope='module')
def photo_output(white_balance):
    cache = {}
    def observe(x, y, preset, override):
        key = (x, y, preset, override)
        if key not in cache:
            parameter_status, capture, temperature = parameters(white_balance, x, y)
            with whitepoint_context(white_balance, x, y, preset, override, lstar=1, policy=1) as ctx:
                baseline, target, factory, matrix = np.zeros(3), np.zeros(3), c.c_double(), np.zeros((3, 3))
                gain_status = white_balance.hncs_preset_white_balance(ctx, baseline.ctypes.data, target.ctypes.data, c.byref(factory))
                matrix_status = white_balance.hncs_source_to_native_matrix(ctx, matrix.ctypes.data)
            cache[key] = dict(parameter_status=parameter_status, capture=capture, temperature=temperature,
                baseline=baseline, target=target, factory=factory.value, matrix=matrix,
                gain_status=gain_status, matrix_status=matrix_status)
        return cache[key]
    return observe


@pytest.mark.parametrize('x,y', PHOTO_WHITES)
@pytest.mark.parametrize('preset', PHOTO_PRESETS)
@pytest.mark.parametrize('override', [0, 3500, 7900])
def test_photo_policy_preserves_capture_gain_and_effective_cct(photo_output, x, y, preset, override):
    observed = photo_output(x, y, preset, override)
    assert observed['parameter_status'] == 0
    assert observed['gain_status'] == 0
    np.testing.assert_array_equal(observed['baseline'], observed['capture'])
    np.testing.assert_array_equal(observed['target'], observed['capture'])
    assert observed['factory'] == (override or observed['temperature'])


@pytest.mark.parametrize('x,y', PHOTO_WHITES)
@pytest.mark.parametrize('preset', PHOTO_PRESETS)
@pytest.mark.parametrize('override', [0, 3500, 7900])
def test_photo_policy_preserves_tint_neutral_axis(photo_output, x, y, preset, override):
    observed = photo_output(x, y, preset, override)
    assert observed['matrix_status'] == 0
    np.testing.assert_allclose(observed['matrix'] @ np.ones(3), 1, rtol=0, atol=NEUTRAL_TOLERANCE)


@pytest.fixture(scope='module')
def nature_output(white_balance):
    gray = np.full((16, 3), .18, np.float32)
    outputs = {}
    for key, policy in [('nature', 0), ('nature', 1), ('standard', 1)]:
        with whitepoint_context(white_balance, .33567193150520325, .37427031993865967,
                key, lstar=1, policy=policy) as ctx:
            out = np.empty((len(gray), 4), np.float32)
            status = white_balance.hncs_process_phocus_linear_rgba(ctx, gray.ctypes.data, out.ctypes.data, len(gray))
            outputs[key, policy] = status, out[0, :3]
    return outputs


@pytest.mark.parametrize('key,policy', [('nature', 0), ('nature', 1), ('standard', 1)])
def test_nature_policy_renders_gray_successfully(nature_output, key, policy):
    assert nature_output[key, policy][0] == 0


def test_fixed_nature_policy_matches_reported_neutral_cast(nature_output):
    fixed = nature_output['nature', 0][1]
    np.testing.assert_allclose(fixed, [.26048735, .33648133, .23170701], rtol=0, atol=NATURE_TOLERANCE)
    assert fixed[1] / ((fixed[0] + fixed[2]) / 2) > 1.25


def test_photo_nature_policy_removes_neutral_cast_and_retains_tone_response(nature_output):
    corrected = nature_output['nature', 1][1]
    assert abs(corrected[1] / ((corrected[0] + corrected[2]) / 2) - 1) < .025
    assert np.max(np.abs(corrected - nature_output['standard', 1][1])) > .01


@pytest.mark.parametrize('policy', [-1, 2, 255])
def test_unknown_white_balance_policy_is_rejected(white_balance, policy):
    ctx = white_balance.hncs_create_preset_whitepoint_with_policy(0, .3127, .3290, 0, 1, 0, 4, 2, b'nature', 1, policy)
    if ctx:
        white_balance.hncs_destroy(ctx)
    assert not ctx
