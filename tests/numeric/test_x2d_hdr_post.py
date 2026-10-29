"""Frozen HDR filter outputs, composition and public-buffer contracts."""
import ctypes as c

import numpy as np
import pytest

from native_build import build_product
from support import golden_vectors

POST = golden_vectors.manifest("x2d-hdr-post-goldens.json")
GRADATION = golden_vectors.manifest("x2d-hdr-gradation-goldens.json")
SHARPNESS = golden_vectors.manifest("x2d-hdr-sharpness-goldens.json")
OUTPUT_SENTINEL = 1973
INVALID_SHARPNESS = [-1., float("nan"), float("inf"), 1e308]
SHARP_PRESETS = [(b"standard", "a100_r1.0"), (b"nature", "a180_r0.8")]


@pytest.fixture(scope="module")
def post():
    library = c.CDLL(str(build_product("GlassCamNativeTestSupport")))
    library.hdr_post_model.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_int, c.c_double, c.c_double, c.c_int]
    library.hncs_render_x2d_hdr_post.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_double, c.c_double, c.c_int]
    library.hncs_apply_x2d_hdr_gradation.argtypes = [c.c_char_p, c.c_void_p, c.c_void_p, c.c_size_t]
    library.hncs_render_x2d_hdr_sharpness.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_double]
    return library


@pytest.fixture(scope="module")
def post_vectors():
    return golden_vectors.vectors(POST)


@pytest.fixture(scope="module")
def gradation_vectors():
    return golden_vectors.vectors(GRADATION)


@pytest.fixture(scope="module")
def sharpness_vectors():
    return golden_vectors.vectors(SHARPNESS)


@pytest.mark.parametrize("case", POST["cases"], ids=lambda case: case["prefix"])
def test_hdr_post_stage_matches_original_codes(post, post_vectors, case):
    source = np.ascontiguousarray(post_vectors[case["prefix"] + "_input"])
    expected = post_vectors[case["prefix"] + "_expected"]
    actual = np.empty_like(expected)

    status = post.hdr_post_model(source.ctypes.data, actual.ctypes.data, source.size // 3,
        case["stage"], case["amount"], case["saturation"], case["lstar"])

    assert status == 0
    np.testing.assert_array_equal(actual, expected)


@pytest.mark.parametrize("case", [case for case in POST["cases"] if case["stage"] == 2], ids=lambda case: case["prefix"])
def test_combined_hdr_post_api_supports_in_place_output(post, post_vectors, case):
    source = post_vectors[case["prefix"] + "_input"].copy()
    expected = post_vectors[case["prefix"] + "_expected"]

    status = post.hncs_render_x2d_hdr_post(source.ctypes.data, source.ctypes.data,
        source.size // 3, case["amount"], case["saturation"], case["lstar"])

    assert status == 0
    np.testing.assert_array_equal(source, expected)


@pytest.mark.parametrize("amount,saturation,space", [(-.1, 50., 0), (100.1, 50., 0), (50., -.1, 0),
    (50., 100.1, 0), (float("nan"), 50., 0), (50., float("inf"), 0), (50., 50., 2)])
def test_invalid_hdr_post_parameters_preserve_output(post, amount, saturation, space):
    source = np.arange(12, dtype=np.uint16)
    output = np.full(12, OUTPUT_SENTINEL, dtype=np.uint16)

    status = post.hncs_render_x2d_hdr_post(source.ctypes.data, output.ctypes.data, 4, amount, saturation, space)

    assert status == -1
    np.testing.assert_array_equal(output, np.full_like(output, OUTPUT_SENTINEL))


@pytest.mark.parametrize("case,expected", [("null-input", -1), ("null-output", -1), ("overflow", -1), ("empty", 0)])
def test_hdr_post_buffer_contract(post, case, expected):
    source = np.arange(12, dtype=np.uint16)
    output = np.full(12, OUTPUT_SENTINEL, dtype=np.uint16)
    input_pointer = None if case in ("null-input", "empty") else source.ctypes.data
    output_pointer = None if case in ("null-output", "empty") else output.ctypes.data
    count = c.c_size_t(-1).value if case == "overflow" else (0 if case == "empty" else 4)

    status = post.hncs_render_x2d_hdr_post(input_pointer, output_pointer, count, 50., 50., 0)

    assert status == expected


def test_hdr_post_partial_overlap_preserves_buffer(post):
    source = np.arange(12, dtype=np.uint16)
    before = source.copy()

    status = post.hncs_render_x2d_hdr_post(source.ctypes.data, source.ctypes.data + 2, 3, 50., 50., 0)

    assert status == -1
    np.testing.assert_array_equal(source, before)


@pytest.mark.parametrize("case", [case for case in GRADATION["cases"] if case["recover_hue"]], ids=lambda case: case["prefix"])
@pytest.mark.parametrize("in_place", [False, True], ids=["separate-output", "in-place"])
def test_hdr_gradation_matches_original_codes(post, gradation_vectors, case, in_place):
    source = gradation_vectors[case["prefix"] + "_input"].copy()
    expected = gradation_vectors[case["prefix"] + "_expected"]
    actual = source if in_place else np.empty_like(source)

    status = post.hncs_apply_x2d_hdr_gradation(case["preset"].encode(),
        source.ctypes.data, actual.ctypes.data, source.size // 3)

    assert status == 0
    np.testing.assert_array_equal(actual, expected)


@pytest.mark.parametrize("preset,key", SHARP_PRESETS)
def test_hdr_sharpness_factory_preset_matches_original_codes(post, sharpness_vectors, preset, key):
    source = np.ascontiguousarray(sharpness_vectors[key + "_source"])
    expected = sharpness_vectors[key + "_native"]
    actual = np.empty_like(source)
    height, width = source.shape[:2]

    status = post.hncs_render_x2d_hdr_sharpness(source.ctypes.data, actual.ctypes.data, width, height, preset, 1.5)

    assert status == 0
    np.testing.assert_array_equal(actual, expected)


@pytest.mark.parametrize("preset,key", SHARP_PRESETS)
@pytest.mark.parametrize("baseline", INVALID_SHARPNESS)
def test_invalid_hdr_sharpness_baseline_is_rejected(post, sharpness_vectors, preset, key, baseline):
    source = np.ascontiguousarray(sharpness_vectors[key + "_source"])
    actual = np.empty_like(source)
    height, width = source.shape[:2]

    status = post.hncs_render_x2d_hdr_sharpness(source.ctypes.data, actual.ctypes.data, width, height, preset, baseline)

    assert status == -1


@pytest.mark.parametrize("preset,key", SHARP_PRESETS)
def test_hdr_sharpness_rejects_aliased_output(post, sharpness_vectors, preset, key):
    source = sharpness_vectors[key + "_source"].copy()
    height, width = source.shape[:2]

    status = post.hncs_render_x2d_hdr_sharpness(source.ctypes.data, source.ctypes.data, width, height, preset, 1.5)

    assert status == -1
