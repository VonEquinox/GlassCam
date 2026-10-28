"""Parallel linear export agrees exactly with the serial production API."""
import ctypes as c
import itertools

import numpy as np
import pytest

from support.native import context, render

MODES = tuple(itertools.product((0, 1), (0, 1), ((-2, 2000), (0, 5500), (2, 10000))))
BOUNDARY_COUNTS = (0, 1, 13, 65535, 65536, 65539, 8064 * 64)


@pytest.fixture(scope='module')
def parallel_samples():
    rng = np.random.default_rng(928)
    boundaries = {}
    for lstar, repro, controls in MODES:
        for count in BOUNDARY_COUNTS:
            boundaries[lstar, repro, controls, count] = rng.uniform(-.2, 1.2, (count, 3)).astype(np.float32)
    large = {shape: rng.random((shape[1], shape[0], 3), dtype=np.float32)
             for shape in ((8064, 64), (4000, 3000))}
    return boundaries, large


@pytest.mark.parametrize('lstar,repro,exposure_kelvin', MODES)
@pytest.mark.parametrize('count', BOUNDARY_COUNTS)
@pytest.mark.parametrize('workers', [1, 2, 3, 4])
def test_parallel_boundaries_match_serial_bits(native, parallel_samples, lstar, repro, exposure_kelvin, count, workers):
    exposure, kelvin = exposure_kelvin
    source = parallel_samples[0][lstar, repro, exposure_kelvin, count]
    with context(native, kelvin=kelvin, ev=exposure, lstar=lstar, repro=repro) as ctx:
        expected = render(native, 'hncs_process_linear_rgba', ctx, source)

        output = render(native, 'hncs_process_linear_rgba_parallel', ctx, source, np.float32, 4, workers)

    assert output.tobytes() == expected.tobytes()


@pytest.mark.parametrize('width,height', [(8064, 64), (4000, 3000)])
@pytest.mark.parametrize('workers', [1, 2, 4])
def test_large_parallel_raster_matches_serial_bits(native, parallel_samples, width, height, workers):
    source = parallel_samples[1][width, height]
    with context(native, kelvin=5500) as ctx:
        expected = render(native, 'hncs_process_linear_rgba', ctx, source)

        output = render(native, 'hncs_process_linear_rgba_parallel', ctx, source, np.float32, 4, workers)

    assert output.tobytes() == expected.tobytes()


@pytest.mark.parametrize('lstar,repro,exposure_kelvin', MODES)
@pytest.mark.parametrize('workers', [0, 5, 4294967295])
def test_invalid_worker_count_fails(native, lstar, repro, exposure_kelvin, workers):
    exposure, kelvin = exposure_kelvin
    with context(native, kelvin=kelvin, ev=exposure, lstar=lstar, repro=repro) as ctx:
        status = native.hncs_process_linear_rgba_parallel(ctx, None, None, 0, workers)
    assert status == -1


@pytest.mark.parametrize('lstar,repro,exposure_kelvin', MODES)
@pytest.mark.parametrize('workers', [1, 4])
@pytest.mark.parametrize('case,expected', [('empty', 0), ('null-input', -1), ('late-nan', -1), ('overflow', -1)])
def test_parallel_invalid_inputs_fail(native, lstar, repro, exposure_kelvin, workers, case, expected):
    exposure, kelvin = exposure_kelvin
    source = np.zeros((65539, 3), np.float32)
    output = np.zeros((65539, 4), np.float32)
    if case == 'late-nan': source[-1, 1] = np.nan
    with context(native, kelvin=kelvin, ev=exposure, lstar=lstar, repro=repro) as ctx:
        args = [ctx, source.ctypes.data, output.ctypes.data, len(source), workers]
        if case == 'empty': args[1:4] = [None, None, 0]
        elif case == 'null-input': args[1:4] = [None, None, 1]
        elif case == 'overflow': args[3] = c.c_size_t(-1).value

        status = native.hncs_process_linear_rgba_parallel(*args)

    assert status == expected


def test_parallel_null_context_fails(native):
    assert native.hncs_process_linear_rgba_parallel(None, None, None, 0, 4) == -1
