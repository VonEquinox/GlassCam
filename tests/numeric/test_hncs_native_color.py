"""Current HNCS contexts and HDR output replay independent Phocus arrays."""
import ctypes as c
import hashlib
import json

import numpy as np
import pytest

from support.native import ROOT

DIRECTORY = ROOT / "tests/fixtures/hncs"
MANIFEST = json.loads((DIRECTORY / "phocus-native-color.json").read_text())


@pytest.fixture(scope="module")
def vectors():
    path = DIRECTORY / MANIFEST["vectors"]
    assert hashlib.sha256(path.read_bytes()).hexdigest() == MANIFEST["vectorsSHA256"]
    with np.load(path) as values:
        yield values


@pytest.fixture(scope="module")
def library(native):
    native.hncs_create_preset_native_color.argtypes = native.hncs_create_preset.argtypes
    native.hncs_create_preset_native_color.restype = c.c_void_p
    native.hncs_create_preset_whitepoint_native_color.argtypes = [
        c.c_double, c.c_double, c.c_double, c.c_double,
        c.c_int, c.c_int, c.c_int, c.c_int, c.c_char_p, c.c_int, c.c_int,
    ]
    native.hncs_create_preset_whitepoint_native_color.restype = c.c_void_p
    native.hncs_clone_with_apple_hdr_work_scale.argtypes = [c.c_void_p, c.c_double]
    native.hncs_clone_with_apple_hdr_work_scale.restype = c.c_void_p
    native.hncs_finish_apple_hdr_work_linear.argtypes = [
        c.c_void_p, c.c_void_p, c.c_void_p, c.c_size_t, c.c_double,
    ]
    return native


@pytest.mark.parametrize("index,case", list(enumerate(MANIFEST["whitepointCases"])))
def test_photo_whitepoint_context_matches_original_gains_and_colour(library, vectors, index, case):
    x, y = MANIFEST["whitepoints"][case["white"]]["xy"]
    source = np.ascontiguousarray(vectors["native_pixels"].astype(np.float64) / 65535.)
    output = np.empty_like(vectors["codes"][index])
    capture, target, kelvin = np.empty(3), np.empty(3), np.empty(1)
    context = library.hncs_create_preset_whitepoint_native_color(
        0, x, y, 0, case["space"], case["model"], 4, 2,
        case["preset"].encode(), 1, case["policy"])
    assert context
    try:
        status = library.hncs_preset_white_balance(
            context, capture.ctypes.data, target.ctypes.data, kelvin.ctypes.data)
        color_status = library.hncs_render_native(context, source.ctypes.data, output.ctypes.data, len(source))
    finally:
        library.hncs_destroy(context)

    assert (status, color_status) == (0, 0)
    np.testing.assert_array_equal(
        np.r_[capture, target, kelvin].view(np.uint64),
        np.r_[vectors["capture_wb"][index], vectors["target_wb"][index], vectors["cct"][index]].view(np.uint64))
    np.testing.assert_array_equal(output, vectors["codes"][index])


@pytest.mark.parametrize("case", MANIFEST["outputCases"], ids=lambda case: case["id"])
def test_working_profile_output_matches_original_float_bits(library, vectors, case):
    source = np.ascontiguousarray(vectors[case["input"]].astype(np.float32) / np.float32(65535))
    output = np.empty((len(source), 4), dtype=np.float32)
    base = library.hncs_create_preset_native_color(0, 6500, 0, case["lstar"], 0, 4, 2, b"standard", 1, None, None)
    assert base
    context = library.hncs_clone_with_apple_hdr_work_scale(base, case["scale"])
    library.hncs_destroy(base)
    assert context
    try:
        status = library.hncs_finish_apple_hdr_work_linear(
            context, source.ctypes.data, output.ctypes.data, len(source), case["scale"])
    finally:
        library.hncs_destroy(context)

    assert status == 0
    np.testing.assert_array_equal(output[:, :3].view(np.uint32), vectors[case["expected"]].view(np.uint32))
    np.testing.assert_array_equal(output[:, 3], 1.)
