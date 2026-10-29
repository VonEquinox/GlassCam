"""Native HNCS stage switches preserve independent reference output."""
import ctypes as c
import itertools
import json
import os

import numpy as np
import pytest

from support import reference_runtime as reference
from support.native import context
from support.phocus_binary_reference import presets as binary_presets
from support.spatial import reference_apply

PRESETS = ('standard', 'nature', 'square-crop', 'film-grain-artistic', 'sharpness-high')
SHAPES = ((17, 23), (23, 17))
CASES = tuple(itertools.product(SHAPES, PRESETS, (False, True), (False, True), (False, True)))
# Existing native Float32 finish versus double-precision display oracle budget.
DISPLAY_TOLERANCE = 1e-7
CALLBACK = c.CFUNCTYPE(c.c_int, c.c_void_p)


@pytest.fixture(scope='module')
def toggle_inputs():
    rng = np.random.default_rng(831701)
    sources = {}
    for height, width in SHAPES:
        source = rng.uniform(-.03, 1.03, (height, width, 3)).astype(np.float64)
        source[0, :3] = [[0, 1, .5], [.001, .02, .75], [.25, .75, 1.05]]
        sources[height, width] = source
    return sources


@pytest.fixture(scope='module')
def toggle_native(native_library_path):
    # A separate CDLL keeps this callback signature local to these observations.
    from support.native import configure
    lib = configure(c.CDLL(str(native_library_path)))
    lib.hncs_apply_spatial_preset.argtypes = [c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_int, c.c_int]
    lib.hncs_apply_spatial_preset_file.argtypes = [c.c_char_p, c.c_size_t, c.c_size_t,
        c.c_char_p, c.c_int, c.c_int, c.c_char_p, CALLBACK, c.c_void_p]
    return lib


@pytest.fixture(scope='module', params=CASES,
    ids=lambda case: f'{case[0][0]}x{case[0][1]}-{case[1]}-grain{int(case[2])}-sharp{int(case[3])}-crop{int(case[4])}')
def toggle_output(request, toggle_native, toggle_inputs, reference_assets, tmp_path_factory):
    shape, preset, grain, sharp, crop_on = request.param
    height, width = shape
    lib = toggle_native
    cfg = reference.presets.settings(preset)
    key = preset.encode()
    full_source = toggle_inputs[shape]
    crop = reference.presets.resolve_crop(full_source.shape, cfg) if crop_on else None
    bounds = [0, 0, width, height] if crop is None else crop['pixel_bounds']
    left, top, right, bottom = bounds
    source = np.ascontiguousarray(full_source[top:bottom, left:right])
    h, w = source.shape[:2]
    statuses = {}
    with context(lib, key=preset, kelvin=6500, factory=6500) as ctx:
        native = np.empty(source.shape, dtype=np.uint16)
        statuses['native'] = lib.hncs_render_native(ctx, source.ctypes.data, native.ctypes.data, h * w)
        expected_native = reference.hncs_codes(source, 6500, reference_assets, 'standard',
            working_space='legacy', film_curve='as-shot', raw_film_curve=2)
        flags = lib.hncs_preset_flags(key)
        needs_spatial = preset != 'standard' and ((grain and flags & 4) or (sharp and flags & (8 | 16)))
        expected, _ = binary_presets.apply_preset(expected_native, preset,
            apply_grain=grain and preset != 'standard', apply_sharpness=sharp and preset != 'standard',
            apply_tone_curve=True)
        work = np.empty(source.shape, dtype=np.float32)
        statuses['work'] = lib.hncs_apply_preset_work_float(key, 1, native.ctypes.data, work.ctypes.data, h * w)
        initial_work = work.copy()
        oracle_work = disk_work = direct = None
        if needs_spatial:
            oracle_work = reference_apply(reference.presets, work.copy(), preset, grain, sharp)
            statuses['memory'] = lib.hncs_apply_spatial_preset(work.ctypes.data, w, h, key, grain, sharp)
            temporary = tmp_path_factory.mktemp('effect-toggle')
            path = temporary / 'work.rgbf'
            initial_work.tofile(path)
            statuses['file'] = lib.hncs_apply_spatial_preset_file(os.fsencode(path), w, h, key,
                grain, sharp, os.fsencode(temporary), CALLBACK(), None)
            disk_work = np.fromfile(path, dtype=np.float32).reshape(work.shape)
        else:
            direct = np.empty(source.shape, dtype=np.uint16)
            statuses['direct'] = lib.hncs_render_native_preset(ctx, source.ctypes.data, direct.ctypes.data, h * w)
        actual_codes = np.rint(np.clip(work, 0, 1) * 65535).astype(np.uint16)
        output = np.empty((h, w, 4), dtype=np.float32)
        statuses['finish'] = lib.hncs_finish_preset_work_linear(ctx, work.ctypes.data, output.ctypes.data, h * w)
    encoded = reference.srgb_from_hncs(expected, reference_assets, 'legacy')
    linear = np.where(encoded <= .04045, encoded / 12.92, ((encoded + .055) / 1.055) ** 2.4)
    return dict(statuses=statuses, native=native, expected_native=expected_native, work=work,
        oracle_work=oracle_work, disk_work=disk_work, direct=direct, actual_codes=actual_codes,
        expected=expected, output=output, linear=linear, spatial=bool(needs_spatial),
        cfg=cfg, catalog=json.loads(lib.hncs_preset_settings_json(key)))


def test_switch_native_codes_match_reference(toggle_output):
    observed = toggle_output
    assert observed['statuses']['native'] == 0
    np.testing.assert_array_equal(observed['native'], observed['expected_native'])


def test_switch_work_and_final_codes_match_reference(toggle_output):
    observed = toggle_output
    assert observed['statuses']['work'] == 0
    np.testing.assert_array_equal(observed['actual_codes'], observed['expected'])


def test_switch_spatial_or_pointwise_route_matches_reference(toggle_output):
    observed = toggle_output
    if observed['spatial']:
        assert observed['statuses']['memory'] == 0
        np.testing.assert_array_equal(observed['work'].view(np.uint32), observed['oracle_work'].view(np.uint32))
        assert observed['statuses']['file'] == 0
        np.testing.assert_array_equal(observed['disk_work'].view(np.uint32), observed['work'].view(np.uint32))
    else:
        assert observed['statuses']['direct'] == 0
        np.testing.assert_array_equal(observed['direct'], observed['expected'])


def test_switch_native_finish_matches_display_reference(toggle_output):
    observed = toggle_output
    assert observed['statuses']['finish'] == 0
    np.testing.assert_allclose(observed['output'][..., :3].astype(np.float64), observed['linear'], rtol=0, atol=DISPLAY_TOLERANCE)


def test_switch_native_finish_is_finite_bounded_and_opaque(toggle_output):
    output = toggle_output['output']
    assert np.isfinite(output).all()
    assert ((output >= 0) & (output <= 1)).all()
    np.testing.assert_array_equal(output[..., 3], 1)


def test_switch_preserves_native_preset_parameters(toggle_output):
    observed = toggle_output
    expected = {name: value for name, value in observed['cfg'].items() if name != 'name'}
    assert {name: observed['catalog'][name] for name in expected} == expected
