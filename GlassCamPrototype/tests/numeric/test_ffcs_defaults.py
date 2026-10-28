"""The default FFCS constructor selects the explicit neutral configuration."""
from contextlib import contextmanager
import ctypes as c

import numpy as np
import pytest

from support.native import ROOT

SIZES = [(1, 1), (1, 7), (9, 1), (7, 3), (131, 19)]
EXPOSURE_SEEDS = [(-2, 0), (.7, 37), (2, 0xffffffff)]
ASSETS = ROOT / 'reference_ffcs/implementation/ffcs/data/xh2s'
CALLBACK = c.CFUNCTYPE(None, c.c_char_p, c.c_void_p, c.c_size_t, c.c_size_t, c.c_void_p)


@pytest.fixture(scope='module')
def ffcs_defaults(native):
    native.ffcs_process_linear_rgb.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_size_t, c.c_size_t,
        c.c_float, c.c_uint32, c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t]
    native.ffcs_process_encoded_double.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_size_t,
        c.c_size_t, c.c_uint32, c.c_void_p, c.c_size_t, CALLBACK, c.c_void_p, c.c_void_p, c.c_size_t]
    return native


def sample(look, width, height):
    source = np.array([((i * 3919 + look * 13) % 8191) / 6000 - .1
                       for i in range(width * height * 3)], np.float32)
    source[:3] = [0, .0031308, 1]
    return source


@contextmanager
def contexts(native, look):
    error = c.create_string_buffer(1024)
    default = native.ffcs_create(str(ASSETS).encode(), look, error, len(error))
    assert default, error.value
    try:
        neutral = native.ffcs_create_config(str(ASSETS).encode(), look, 1, 1, 0, 1, error, len(error))
        assert neutral, error.value
        try:
            yield default, neutral
        finally:
            native.ffcs_destroy(neutral)
    finally:
        native.ffcs_destroy(default)


@pytest.mark.parametrize('look', range(19))
@pytest.mark.parametrize('width,height', SIZES)
@pytest.mark.parametrize('exposure,seed', EXPOSURE_SEEDS)
def test_default_linear_and_preview_equal_explicit_neutral(ffcs_defaults, look, width, height, exposure, seed):
    source = sample(look, width, height)
    error = c.create_string_buffer(1024)
    outputs = []
    with contexts(ffcs_defaults, look) as pair:
        for ctx in pair:
            linear = np.empty_like(source)
            preview = np.empty(width * height * 4, np.uint8)
            status = ffcs_defaults.ffcs_process_linear_rgb(ctx, source.ctypes.data, source.size, width, height,
                exposure, seed, linear.ctypes.data, linear.size, preview.ctypes.data, preview.size, error, len(error))
            assert status == 1, error.value
            outputs.append((linear.tobytes(), preview.tobytes()))

    assert outputs[0] == outputs[1]


@pytest.mark.parametrize('look', range(19))
@pytest.mark.parametrize('width,height', SIZES)
def test_default_encoded_stages_equal_explicit_neutral(ffcs_defaults, look, width, height):
    source = sample(look, width, height).astype(np.float64)
    error = c.create_string_buffer(1024)
    outputs = []
    with contexts(ffcs_defaults, look) as pair:
        for ctx in pair:
            stages = []
            @CALLBACK
            def record(stage, values, stage_width, stage_height, _):
                stages.append((stage, c.string_at(values, stage_width * stage_height * 3 * c.sizeof(c.c_double))))
            output = np.empty_like(source)
            status = ffcs_defaults.ffcs_process_encoded_double(ctx, source.ctypes.data, source.size, width, height,
                0xffffffff, output.ctypes.data, output.size, record, None, error, len(error))
            assert status == 1, error.value
            outputs.append((output.tobytes(), stages))

    assert outputs[0] == outputs[1]
