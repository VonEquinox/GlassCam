"""FFCS strip processing preserves full-frame output and rejects invalid slices."""
import ctypes as c
import random

import numpy as np
import pytest

from support.native import ROOT

SIZES = [(1, 1), (1, 2), (1, 13), (7, 1), (11, 3), (19, 17), (131, 19)]
EXPOSURE_SEEDS = [(0, -2), (37, .7), (0xffffffff, 2)]
ASSETS = ROOT / 'vendor/ffcs/implementation/ffcs/data/xh2s'


@pytest.fixture
def ffcs_context(native, request):
    index = getattr(request, 'param', 0)
    error = c.create_string_buffer(1024)
    value = native.ffcs_create_config(str(ASSETS).encode(), index, 1, 1, 1, 1.5, error, len(error))
    assert value, error.value
    try:
        yield value
    finally:
        native.ffcs_destroy(value)


def partitions(rng, height, halo):
    result = {}
    for workers in range(1, 5):
        spans = []
        y = 0
        while y < height:
            rows = 1 if workers == 1 else min(height - y, rng.randint(1, 7))
            first = max(0, y - halo - rng.randint(0, 2))
            last = min(height, y + rows + halo + rng.randint(0, 2))
            spans.append((first, last, y, rows))
            y += rows
        result[workers] = spans
    return result


@pytest.mark.parametrize('ffcs_context', range(19), indirect=True)
@pytest.mark.parametrize('width,height', SIZES)
@pytest.mark.parametrize('seed,exposure', EXPOSURE_SEEDS)
@pytest.mark.parametrize('workers', [1, 2, 3, 4])
def test_strips_match_full_frame(native, ffcs_context, width, height, seed, exposure, workers, request):
    index = request.node.callspec.params['ffcs_context']
    rng = random.Random(index * 911 + width * 29 + height + seed)
    source = np.array([rng.uniform(-.1, 1.3) for _ in range(width * height * 3)], np.float32).reshape(height, width, 3)
    expected = np.empty_like(source)
    error = c.create_string_buffer(1024)
    assert native.ffcs_process_linear_rgb_optimized(ffcs_context, source.ctypes.data, source.size, width,
        height, exposure, seed, expected.ctypes.data, expected.size, None, 0, 1, error, len(error)), error.value
    spans = partitions(rng, height, native.ffcs_required_halo(ffcs_context))[workers]
    output = np.empty_like(source)
    statuses = []

    for first, last, y, rows in spans:
        strip = np.ascontiguousarray(source[first:last])
        out = np.empty((rows, width, 3), np.float32)
        statuses.append(native.ffcs_process_linear_rgb_strip(ffcs_context, strip.ctypes.data, strip.size,
            width, height, first, last - first, y, rows, exposure, seed, out.ctypes.data, out.size,
            workers, error, len(error)))
        output[y:y + rows] = out

    assert statuses == [1] * len(spans)
    np.testing.assert_array_equal(output.view(np.uint32), expected.view(np.uint32))


INVALID_ARGUMENTS = [(0, None), (1, None), (2, 89), (3, 0), (4, 0), (5, 10), (6, 0), (6, 11),
    (7, 10), (8, 0), (8, 9), (9, float('nan')), (9, 33), (11, None), (12, 26), (13, 0), (13, 5)]


@pytest.mark.parametrize('case', list(range(len(INVALID_ARGUMENTS))) + ['missing-upper-halo', 'missing-lower-halo', 'alias', 'nonfinite'])
def test_invalid_strip_preserves_output_and_returns_diagnostic(native, ffcs_context, case):
    source = np.full(90, .2, np.float32)
    output = np.full(90, .123, np.float32)
    error = c.create_string_buffer(1024)
    args = [ffcs_context, source.ctypes.data, 90, 3, 10, 0, 10, 2, 3, 0, 0, output.ctypes.data, 90, 1, error, len(error)]
    if isinstance(case, int):
        position, value = INVALID_ARGUMENTS[case]
        args[position] = value
    elif case == 'missing-upper-halo': args[5:7] = [2, 8]
    elif case == 'missing-lower-halo': args[6] = 5
    elif case == 'alias': args[11] = source.ctypes.data
    elif case == 'nonfinite': source.fill(np.inf)
    before = output.tobytes()

    status = native.ffcs_process_linear_rgb_strip(*args)

    assert status == 0
    assert output.tobytes() == before
    assert error.value
