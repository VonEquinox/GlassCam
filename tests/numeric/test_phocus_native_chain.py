"""Replay frozen original-Phocus outputs through the shipping C++ stage APIs."""
import ctypes as c

import numpy as np
import pytest

from support import golden_vectors

GOLDEN = golden_vectors.manifest("phocus-native-chain-goldens.json")


@pytest.fixture(scope="module")
def phocus(native):
    native.hncs_process_phocus_work_float_parallel.argtypes = [c.c_void_p] * 3 + [c.c_size_t, c.c_uint]
    native.hncs_apply_spatial_native_sharpness.argtypes = [c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_int, c.c_int, c.c_double]
    native.hncs_apply_phocus_post_spatial.argtypes = [c.c_char_p, c.c_void_p, c.c_void_p, c.c_size_t]
    native.hncs_native_sharpness_enabled.argtypes = [c.c_char_p]
    return native


@pytest.fixture(scope="module")
def vectors():
    return golden_vectors.vectors(GOLDEN)


@pytest.fixture(scope="module", params=GOLDEN["cases"], ids=lambda case: case["preset"])
def chain_case(request):
    return request.param


@pytest.fixture(scope="module", params=[1, 4], ids=lambda workers: f"workers-{workers}")
def chain_observation(phocus, vectors, chain_case, request):
    case = chain_case
    key, name = case["preset"].encode(), case["vector_key"]
    source = vectors[name + "_source"]
    height, width = source.shape[:2]
    context = phocus.hncs_create_preset(case["exposure_ev"], case["capture_cct"], 0,
        case["space"], 0, 4, 2, key, int(case["tone"]), None, None)
    assert context
    try:
        work = np.empty_like(source)
        work_status = phocus.hncs_process_phocus_work_float_parallel(
            context, source.ctypes.data, work.ctypes.data, height * width, request.param)
        before_sharpness = work.copy()
        sharpness_status = phocus.hncs_apply_spatial_native_sharpness(
            work.ctypes.data, width, height, key, 0, 1, case["baseline_sharpness"])
        codes = np.rint(work * np.float32(65535.)).astype(np.uint16)
        final = np.empty_like(codes)
        final_status = phocus.hncs_apply_phocus_post_spatial(
            key, codes.ctypes.data, final.ctypes.data, height * width)
    finally:
        phocus.hncs_destroy(context)
    return {
        "work": (work_status, before_sharpness.view(np.uint32), vectors[name + "_work"].view(np.uint32)),
        "sharpness": (sharpness_status, work.view(np.uint32),
                      (vectors[name + "_sharpness"].astype(np.float32) / np.float32(65535.)).view(np.uint32)),
        "final": (final_status, final, vectors[name + "_final_codes"]),
    }


@pytest.mark.parametrize("stage", ["work", "sharpness", "final"])
def test_native_chain_stage_matches_frozen_output(chain_observation, stage):
    status, actual, expected = chain_observation[stage]

    assert status == 0
    np.testing.assert_array_equal(actual, expected)


@pytest.mark.parametrize("key,expected", [(b"standard", 1), (b"nature", 1), (b"cloudy", 1),
    (b"film-grain-artistic", 1), (b"grayscale-blue-filter", 1), (None, -1), (b"missing", -1)])
def test_native_sharpness_gate_matches_factory_preset(phocus, key, expected):
    actual = phocus.hncs_native_sharpness_enabled(key)

    assert actual == expected


@pytest.mark.parametrize("baseline", [-1., float("nan"), float("inf"), 1e308])
def test_invalid_native_sharpness_baseline_is_rejected(phocus, baseline):
    pixels = np.zeros((1, 1, 3), np.float32)

    status = phocus.hncs_apply_spatial_native_sharpness(pixels.ctypes.data, 1, 1, b"standard", 0, 1, baseline)

    assert status == -1
