"""Production FFCS integer mapping and float adapter consume factory vectors."""
import ctypes as c
import hashlib
import json
import os
import shutil
import struct
import zipfile

import numpy as np
import pytest

from support.native import ROOT

ARCHIVE = ROOT / "tests/fixtures/ffcs/native-mapping-vectors.zip"
ARCHIVE_SHA256 = "bee57df3e36a8a66ae4bf0a1dc0565bf5ef3b1bd9dfc981f2ae1e84d16fb652a"
RESOURCES = ROOT / "App/GlassCam/Resources/FFCS"
with zipfile.ZipFile(ARCHIVE) as archive:
    MANIFEST = json.loads(archive.read("manifest.json"))

# Only standard transfer functions convert the measured UInt16 output into the
# declared sRGB storage domain; 2e-7 covers Float32 transfer-library rounding.
TRANSFER_TOLERANCE = 2e-7


@pytest.fixture(scope="module")
def vectors():
    assert hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() == ARCHIVE_SHA256
    with zipfile.ZipFile(ARCHIVE) as archive:
        yield archive


@pytest.fixture(scope="module")
def library(native):
    native.ffcs_simulation_asset.argtypes = [c.c_size_t]
    native.ffcs_simulation_asset.restype = c.c_char_p
    native.ffcs_create_native_family_config.argtypes = [
        c.c_char_p, c.c_char_p, c.c_size_t, c.c_int, c.c_int, c.c_int,
        c.c_double, c.c_void_p, c.c_size_t,
    ]
    native.ffcs_create_native_family_config.restype = c.c_void_p
    native.ffcs_process_native_codes.argtypes = [c.c_void_p, c.c_void_p, c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t]
    return native


def create(library, selector, details=0):
    family, name = selector.split("/")
    index = next(i for i in range(20) if library.ffcs_simulation_asset(i).decode() == name + ".lutz")
    error = c.create_string_buffer(1024)
    context = library.ffcs_create_native_family_config(
        os.fsencode(RESOURCES), family.encode(), index, 0, 0, details, 1., error, len(error))
    assert context, error.value
    return context


@pytest.mark.parametrize("case", MANIFEST["cases"], ids=lambda case: case["selector"])
def test_native_mapping_matches_original_integer_outputs(library, vectors, case):
    source = np.frombuffer(vectors.read(MANIFEST["input"]), "<u2").reshape(-1, 3)
    expected = np.frombuffer(vectors.read(case["expected"]), "<u2").reshape(-1, 3)
    output = np.empty_like(source)
    error = c.create_string_buffer(1024)
    context = create(library, case["selector"])
    try:
        status = library.ffcs_process_native_codes(
            context, source.ctypes.data, output.ctypes.data, len(source), error, len(error))
    finally:
        library.ffcs_destroy(context)

    assert status == 1, error.value
    np.testing.assert_array_equal(output, expected)


@pytest.mark.parametrize("details", [0, 1])
@pytest.mark.parametrize("case", MANIFEST["cases"], ids=lambda case: case["selector"])
def test_float_adapter_preserves_original_colour_without_duplicate_tone(library, vectors, case, details):
    source = np.frombuffer(vectors.read(case["selector"] + ".input.rgb32"), "<f4").reshape(-1, 3)
    expected = np.frombuffer(vectors.read(case["selector"] + ".expected.rgb32"), "<f4").reshape(-1, 3)
    output = np.empty_like(source)
    error = c.create_string_buffer(1024)
    context = create(library, case["selector"], details)
    try:
        status = library.ffcs_process_linear_rgb_optimized(
            context, source.ctypes.data, source.size, len(source), 1, 0, 0,
            output.ctypes.data, output.size, None, 0, 1, error, len(error))
    finally:
        library.ffcs_destroy(context)

    assert status == 1, error.value
    np.testing.assert_allclose(output, expected, rtol=0, atol=TRANSFER_TOLERANCE)


@pytest.mark.parametrize("damage", ["truncated", "trailing", "checksum", "gamma"])
def test_invalid_native_mapping_is_rejected(library, tmp_path, damage):
    directory = tmp_path / "xh2s"
    directory.mkdir()
    shutil.copyfile(RESOURCES / "xh2s/provia.lutz", directory / "provia.lutz")
    packed = bytearray((RESOURCES / "xh2s/provia.ffcm").read_bytes())
    if damage == "truncated":
        packed = packed[:-1]
    elif damage == "trailing":
        packed += b"\0"
    elif damage == "checksum":
        packed[32] ^= 1
    else:
        struct.pack_into("<d", packed, 20, float("nan"))
    (directory / "provia.ffcm").write_bytes(packed)
    error = c.create_string_buffer(1024)

    context = library.ffcs_create_native_family_config(
        os.fsencode(tmp_path), b"XH2S", 0, 0, 0, 0, 1., error, len(error))
    if context:
        library.ffcs_destroy(context)

    assert context is None


@pytest.mark.parametrize("offset", [0, 1, 3])
def test_native_code_overlap_is_rejected_without_writes(library, offset):
    pixels = 7
    storage = np.arange(pixels * 3 + offset, dtype=np.uint16)
    before = storage.copy()
    error = c.create_string_buffer(1024)
    context = create(library, "xh2s/provia")
    try:
        status = library.ffcs_process_native_codes(
            context, storage.ctypes.data, storage.ctypes.data + offset * storage.itemsize,
            pixels, error, len(error))
    finally:
        library.ffcs_destroy(context)

    assert status == 0
    np.testing.assert_array_equal(storage, before)
