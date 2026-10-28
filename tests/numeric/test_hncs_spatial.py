"""Production spatial APIs retain pinned numerical results and file semantics."""
import ctypes as c
import os

import numpy as np
import pytest

from support import reference_runtime as r
from support.spatial import reference_apply

CALLBACK = c.CFUNCTYPE(c.c_int, c.c_void_p)
PRESETS = tuple(r.presets.PRESET_CHOICES)
GRAIN_PRESETS = tuple(key for key in PRESETS if r.presets.settings(key)['film_grain'].get('ApplyFilmGrain')
                     and r.presets.settings(key)['film_grain'].get('FilmGrainAmount'))
EDGE_SHAPES = ((1, 1, 3), (1, 7, 3), (7, 1, 3), (3, 5, 3), (127, 129, 3),
               (321, 511, 3), (5, 8193, 3), (4097, 3, 3))


@pytest.fixture(scope='module')
def spatial(native):
    native.hncs_apply_spatial_preset.argtypes = [c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_int, c.c_int]
    native.hncs_apply_spatial_preset_file.argtypes = [c.c_char_p, c.c_size_t, c.c_size_t, c.c_char_p,
        c.c_int, c.c_int, c.c_char_p, CALLBACK, c.c_void_p]
    return native


@pytest.fixture(scope='module')
def spatial_inputs():
    rng = np.random.default_rng(81047)
    initial = rng.uniform(-.03, 1.03, (17, 23, 3)).astype(np.float32)
    initial[0, :3] = [[0, 1, .5], [1/65535, 65534/65535, .5/65535], [-.2, 1.2, 0]]
    edges = {shape: rng.random(shape, dtype=np.float32) for shape in EDGE_SHAPES}
    megapixel = rng.random((1024, 1024, 3), dtype=np.float32)
    return initial, edges, megapixel, rng.bit_generator.state


def apply(spatial, tmp_path, source, key, grain, sharp, filemode):
    output = source.copy()
    height, width = source.shape[:2]
    if filemode:
        path = tmp_path / 'work.rgbf'
        output.tofile(path)
        status = spatial.hncs_apply_spatial_preset_file(os.fsencode(path), width, height, key.encode(),
            grain, sharp, os.fsencode(tmp_path), CALLBACK(), None)
        output = np.fromfile(path, np.float32).reshape(source.shape)
    else:
        status = spatial.hncs_apply_spatial_preset(output.ctypes.data, width, height, key.encode(), grain, sharp)
    assert status == 0
    return output


@pytest.mark.parametrize('key', PRESETS)
@pytest.mark.parametrize('grain,sharp', [(0, 0), (1, 0), (0, 1), (1, 1)])
def test_file_spatial_flags_match_reference_bits(spatial, spatial_inputs, tmp_path, key, grain, sharp):
    source = spatial_inputs[0]
    expected = reference_apply(r.presets, source.copy(), key, grain, sharp)

    output = apply(spatial, tmp_path, source, key, grain, sharp, True)

    np.testing.assert_array_equal(output.view(np.uint32), expected.view(np.uint32))


@pytest.mark.parametrize('shape', EDGE_SHAPES)
@pytest.mark.parametrize('key,grain,sharp', [(key, 1, 0) for key in GRAIN_PRESETS]
    + [(key, 0, 1) for key in ('standard', 'sharpness-high', 'sharpness-portrait')])
def test_spatial_edge_shapes_match_reference_bits(spatial, spatial_inputs, tmp_path, shape, key, grain, sharp):
    source = spatial_inputs[1][shape]
    expected = reference_apply(r.presets, source.copy(), key, grain, sharp)

    output = apply(spatial, tmp_path, source, key, grain, sharp, bool(grain and shape[1] > 4096))

    np.testing.assert_array_equal(output.view(np.uint32), expected.view(np.uint32))


@pytest.mark.parametrize('key', ['film-grain-artistic', 'film-grain-fine-texture', 'sharpness-high'])
@pytest.mark.parametrize('filemode', [False, True])
def test_megapixel_spatial_matches_reference_bits(spatial, spatial_inputs, tmp_path, key, filemode):
    source = spatial_inputs[2]
    expected = reference_apply(r.presets, source.copy(), key, 1, 1)

    output = apply(spatial, tmp_path, source, key, 1, 1, filemode)

    np.testing.assert_array_equal(output.view(np.uint32), expected.view(np.uint32))


def filecall(spatial, tmp_path, *, width=9, height=7, key=b'film-grain-artistic', grain=1, sharp=1,
             callback=None, directory=None):
    return spatial.hncs_apply_spatial_preset_file(os.fsencode(tmp_path / 'work.rgbf'), width, height, key,
        grain, sharp, os.fsencode(tmp_path if directory is None else directory), callback or CALLBACK(), None)


@pytest.mark.parametrize('kwargs', [{'width': 0}, {'width': 2**63, 'height': 3}, {'key': b'missing'},
                                  {'grain': 2}, {'sharp': -1}, {'width': 10}],
    ids=['zero-width', 'overflow', 'unknown-preset', 'invalid-grain', 'invalid-sharpness', 'wrong-size'])
def test_invalid_file_arguments_fail(spatial, tmp_path, kwargs):
    np.zeros((7, 9, 3), np.float32).tofile(tmp_path / 'work.rgbf')

    status = filecall(spatial, tmp_path, **kwargs)

    assert status == -1


def test_nonfinite_file_pixels_fail(spatial, tmp_path):
    pixels = np.zeros((7, 9, 3), np.float32)
    pixels[0, 0, 0] = np.nan
    pixels.tofile(tmp_path / 'work.rgbf')

    status = filecall(spatial, tmp_path)

    assert status == -1


def test_missing_scratch_directory_fails(spatial, tmp_path):
    np.zeros((7, 9, 3), np.float32).tofile(tmp_path / 'work.rgbf')

    status = filecall(spatial, tmp_path, directory=tmp_path / 'missing')

    assert status == -2


@pytest.mark.parametrize('stop', [1, 3, 14, 40])
def test_cancellation_removes_scratch_files(spatial, tmp_path, stop):
    np.zeros((7, 9, 3), np.float32).tofile(tmp_path / 'work.rgbf')
    calls = 0
    @CALLBACK
    def canceled(_):
        nonlocal calls
        calls += 1
        return int(calls >= stop)

    status = filecall(spatial, tmp_path, callback=canceled)

    assert status == -3
    assert list(tmp_path.glob('hncs-spatial-*')) == []


def test_completed_spatial_pass_removes_scratch_files(spatial, tmp_path):
    np.zeros((7, 9, 3), np.float32).tofile(tmp_path / 'work.rgbf')

    status = filecall(spatial, tmp_path)

    assert status == 0
    assert list(tmp_path.glob('hncs-spatial-*')) == []


LARGE_CASES = (((4097, 4097, 3), 'film-grain-artistic'),
               ((3073, 4097, 3), 'film-grain-tabular-grain'))


@pytest.mark.skipif(os.environ.get('GLASSCAM_LARGE_NUMERICS') != '1',
                    reason='Set GLASSCAM_LARGE_NUMERICS=1 to run large spatial fixtures')
@pytest.mark.parametrize('case', [0, 1], ids=['4097-square', '3073x4097'])
def test_large_file_spatial_matches_reference_bits(spatial, spatial_inputs, tmp_path, case):
    rng = np.random.default_rng()
    rng.bit_generator.state = spatial_inputs[3]
    for shape, key in LARGE_CASES[:case + 1]:
        source = rng.random(shape, dtype=np.float32)
    expected = reference_apply(r.presets, source.copy(), key, 1, 1)

    output = apply(spatial, tmp_path, source, key, 1, 1, True)

    np.testing.assert_array_equal(output.view(np.uint32), expected.view(np.uint32))
