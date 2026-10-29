"""Replay original native HDR colors without loading vendor frameworks."""
import ctypes as c

import numpy as np
import pytest

from support import golden_vectors

GOLDEN = golden_vectors.manifest("x2d-hdr-goldens.json")
OUTPUT_SENTINEL = 1773


@pytest.fixture(scope="module")
def hdr(native):
    native.hncs_render_x2d_hdr_color.argtypes = [c.c_void_p, c.c_double, c.c_void_p, c.c_void_p, c.c_size_t]
    return native


@pytest.fixture(scope="module")
def vectors():
    return golden_vectors.vectors(GOLDEN)


@pytest.mark.parametrize("case", GOLDEN["cases"], ids=lambda case: case["prefix"])
def test_original_hdr_colors_survive_context_reuse(hdr, vectors, case):
    key = case["prefix"]
    source = np.ascontiguousarray(vectors[key + "_input"].astype(np.float64) / 65535.)
    expected = vectors[key + "_expected"]
    outputs = np.empty((2, *expected.shape), dtype=expected.dtype)
    context = hdr.hncs_create_mode(0., case["cct"], case["space"], 0)
    assert context
    try:
        statuses = [hdr.hncs_render_x2d_hdr_color(context, case["gain"], source.ctypes.data,
                    output.ctypes.data, source.size // 3) for output in outputs]
    finally:
        hdr.hncs_destroy(context)

    assert statuses == [0, 0]
    np.testing.assert_array_equal(outputs, np.stack([expected, expected]))


@pytest.mark.parametrize("kind,gain", [("null", 1.), ("reproduction", 1.), ("standard", .24),
    ("standard", 32.01), ("standard", float("inf")), ("standard", float("nan")), ("nonfinite", 1.)])
def test_invalid_hdr_color_call_preserves_output(hdr, kind, gain):
    source = np.zeros((2, 3), np.float64)
    if kind == "nonfinite":
        source[1, 2] = np.nan
    output = np.full((2, 3), OUTPUT_SENTINEL, np.uint16)
    context = None if kind == "null" else hdr.hncs_create_mode(0., 5500., 0, int(kind == "reproduction"))
    if kind != "null":
        assert context
    try:
        status = hdr.hncs_render_x2d_hdr_color(context, gain, source.ctypes.data, output.ctypes.data, 2)
    finally:
        hdr.hncs_destroy(context)

    assert status == -1
    np.testing.assert_array_equal(output, np.full_like(output, OUTPUT_SENTINEL))
