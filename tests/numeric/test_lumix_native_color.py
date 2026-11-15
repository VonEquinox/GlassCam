"""Current LUMIX colour uses the factory integer stages and processing white."""
import ctypes as c
import hashlib
import json
import os
import zipfile

import numpy as np
import pytest

from support.native import ROOT

ARCHIVE = ROOT / "tests/fixtures/lumix/native-color-vectors.zip"
ARCHIVE_SHA256 = "4abe94fa48111b6674c1ed08125614818e37a93f4390d844f2892093539e550b"
with zipfile.ZipFile(ARCHIVE) as archive:
    MANIFEST = json.loads(archive.read("manifest.json"))

# The frozen expected float values apply the standard sRGB EOTF to original
# integers; this only allows rounding differences in that transfer function.
TRANSFER_TOLERANCE = 2e-7


@pytest.fixture(scope="module")
def vectors():
    assert hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() == ARCHIVE_SHA256
    with zipfile.ZipFile(ARCHIVE) as archive:
        yield archive


@pytest.fixture(scope="module")
def library(native):
    native.lumix_create_native_pipeline.argtypes = native.lumix_create_pipeline.argtypes
    native.lumix_create_native_pipeline.restype = c.c_void_p
    native.lumix_process_native_rgba.argtypes = native.lumix_process_iphone_rgba.argtypes
    return native


def create(library, resources, case):
    error = c.create_string_buffer(1024)
    context = library.lumix_create_native_pipeline(
        os.fsencode(resources), case["look"], case["kelvin"], case["contrast"],
        case["saturation"], case["iso"], error, len(error))
    assert context, error.value
    return context


@pytest.mark.parametrize("case", MANIFEST["cases"], ids=lambda case: case["id"])
def test_production_white_and_controls_match_original_integer_stage(library, lumix_resources, vectors, case):
    source = np.frombuffer(vectors.read("input.rgb16"), "<u2").reshape(-1, 3)
    expected = np.frombuffer(vectors.read(case["id"] + ".rgb16"), "<u2").reshape(-1, 3)
    output = np.empty_like(source)
    error = c.create_string_buffer(1024)
    context = create(library, lumix_resources, case)
    try:
        status = library.lumix_process_rgb16(
            context, source.ctypes.data, len(source), MANIFEST["white"], 0, 0,
            output.ctypes.data, error, len(error))
    finally:
        library.lumix_destroy(context)

    assert status == 1, error.value
    np.testing.assert_array_equal(output, expected)


@pytest.mark.parametrize("case", MANIFEST["cases"], ids=lambda case: case["id"])
def test_float_adapter_replays_original_colour_saturation_and_contrast(library, lumix_resources, vectors, case):
    source = np.frombuffer(vectors.read("input.rgb32"), "<f4").reshape(-1, 3)
    expected = np.frombuffer(vectors.read(case["id"] + ".rgb32"), "<f4").reshape(-1, 3)
    output = np.empty((len(source), 4), dtype=np.float32)
    error = c.create_string_buffer(1024)
    context = create(library, lumix_resources, case)
    try:
        status = library.lumix_process_native_rgba(
            context, source.ctypes.data, source.size, len(source), 0,
            output.ctypes.data, output.size, error, len(error))
    finally:
        library.lumix_destroy(context)

    assert status == 1, error.value
    np.testing.assert_allclose(output[:, :3], expected, rtol=0, atol=TRANSFER_TOLERANCE)
    np.testing.assert_array_equal(output[:, 3], 1.)


@pytest.mark.parametrize("invalid", [np.nan, np.inf, -np.inf])
def test_invalid_source_leaves_native_output_unchanged(library, lumix_resources, invalid):
    source = np.array([[.1, .2, .3], [.4, invalid, .6]], dtype=np.float32)
    output = np.full((2, 4), -123., dtype=np.float32)
    error = c.create_string_buffer(1024)
    context = create(library, lumix_resources, MANIFEST["cases"][0])
    try:
        status = library.lumix_process_native_rgba(
            context, source.ctypes.data, source.size, 2, 0,
            output.ctypes.data, output.size, error, len(error))
    finally:
        library.lumix_destroy(context)

    assert status == 0
    np.testing.assert_array_equal(output, -123.)
