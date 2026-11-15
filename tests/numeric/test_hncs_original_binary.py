"""Replay independently sampled Phocus 4.2.2 stage outputs through the C ABI."""
import ctypes as c

import numpy as np
import pytest

from support import golden_vectors

GOLDEN = golden_vectors.manifest("phocus-422-independent.json")


@pytest.fixture(scope="module")
def independent_vectors():
    return golden_vectors.vectors(GOLDEN)


@pytest.fixture(scope="module")
def stage_library(native):
    native.hncs_clone_with_native_gain.argtypes = [c.c_void_p, c.c_double]
    native.hncs_clone_with_native_gain.restype = c.c_void_p
    native.hncs_render_x2d_hdr_color.argtypes = [c.c_void_p, c.c_double, c.c_void_p, c.c_void_p, c.c_size_t]
    native.hncs_render_x2d_hdr_post.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_double, c.c_double, c.c_int]
    native.hncs_apply_x2d_hdr_gradation.argtypes = [c.c_char_p, c.c_void_p, c.c_void_p, c.c_size_t]
    native.hncs_apply_phocus_post_spatial.argtypes = [c.c_char_p, c.c_void_p, c.c_void_p, c.c_size_t]
    native.hncs_apply_post_curves.argtypes = [c.c_char_p, c.c_int, c.c_void_p, c.c_void_p, c.c_size_t]
    native.hncs_render_x2d_hdr_sharpness.argtypes = [
        c.c_void_p, c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_double,
    ]
    native.hncs_apply_spatial_native_sharpness.argtypes = [
        c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_int, c.c_int, c.c_double,
    ]
    return native


def render_stage(library, source, case):
    stage = case["stage"]
    output = np.empty_like(source)
    count = source.size // 3
    if stage in ("color", "gain_color", "hdr_color"):
        normalized = np.ascontiguousarray(source.astype(np.float64) / 65535)
        context = library.hncs_create_preset(
            0, case["cct"], case["cct"], case["space"], case["model"],
            case["film"], case.get("raw_film", 2), b"standard", 1, None, None,
        )
        assert context
        try:
            if stage == "gain_color":
                scaled = library.hncs_clone_with_native_gain(context, case["gain"])
                library.hncs_destroy(context)
                context = scaled
                assert context
            if stage == "hdr_color":
                status = library.hncs_render_x2d_hdr_color(
                    context, case["gain"], normalized.ctypes.data, output.ctypes.data, count)
            else:
                status = library.hncs_render_native(context, normalized.ctypes.data, output.ctypes.data, count)
        finally:
            library.hncs_destroy(context)
    elif stage == "hdr_post":
        status = library.hncs_render_x2d_hdr_post(source.ctypes.data, output.ctypes.data, count,
                                                case["amount"], case["saturation"], case["space"])
    elif stage == "hdr_gradation":
        status = library.hncs_apply_x2d_hdr_gradation(
            case["preset"].encode(), source.ctypes.data, output.ctypes.data, count)
    elif stage == "gradation":
        status = library.hncs_apply_post_curves(
            case["preset"].encode(), int(case["tone"]), source.ctypes.data, output.ctypes.data, count)
    elif stage == "post":
        status = library.hncs_apply_phocus_post_spatial(
            case["preset"].encode(), source.ctypes.data, output.ctypes.data, count)
    elif stage == "sharpness":
        height, width, _ = source.shape
        if case.get("work_scale", 1) != 1:
            status = library.hncs_render_x2d_hdr_sharpness(
                source.ctypes.data, output.ctypes.data, width, height, case["preset"].encode(), case["baseline"])
            output = output.astype(np.float32) / np.float32(65535)
        else:
            output = source.astype(np.float32) / np.float32(65535)
            status = library.hncs_apply_spatial_native_sharpness(
                output.ctypes.data, width, height, case["preset"].encode(), 0, 1, case["baseline"])
    else:
        raise ValueError(f"Unknown fixed stage: {stage}")
    return status, output


@pytest.mark.parametrize("case", GOLDEN["cases"], ids=lambda case: case["id"])
def test_independent_native_input_matches_original_stage(stage_library, independent_vectors, case):
    source = independent_vectors[case["source"]]
    expected = independent_vectors[case["expected"]]

    status, actual = render_stage(stage_library, source, case)

    assert status == 0
    if expected.dtype == np.float32:
        np.testing.assert_array_equal(actual.view(np.uint32), expected.view(np.uint32))
    else:
        np.testing.assert_array_equal(actual, expected)
