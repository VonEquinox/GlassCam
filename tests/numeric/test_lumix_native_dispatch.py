"""LUMIX dispatch and integer stages match fixed original-program outputs."""
import ctypes as c
import hashlib
import json
import os
import zipfile

import numpy as np
import pytest

from support.native import ROOT

ARCHIVE = ROOT / "tests/fixtures/lumix/native-dispatch-vectors.zip"
ARCHIVE_SHA256 = "c4c441ba73e227940b3aef4b6e5767e9ce7984eed2ed6480645ae3d9ac149e34"
with zipfile.ZipFile(ARCHIVE) as archive:
    MANIFEST = json.loads(archive.read("manifest.json"))


@pytest.fixture(scope="module")
def native_dispatch_vectors():
    assert hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() == ARCHIVE_SHA256
    with zipfile.ZipFile(ARCHIVE) as archive:
        yield archive


@pytest.mark.parametrize("case", MANIFEST["cases"], ids=lambda case: case["id"])
def test_native_dispatch_produces_original_integer_outputs(native, lumix_resources, native_dispatch_vectors, case):
    source, expected = (
        np.frombuffer(native_dispatch_vectors.read(case[key]), dtype="<u2").reshape(case["pixels"], 3)
        for key in ("input", "expected")
    )
    output = np.empty_like(source)
    settings = case["settings"]
    error = c.create_string_buffer(1024)
    context = native.lumix_create_pipeline(os.fsencode(lumix_resources), settings["look"],
        settings["kelvin"], settings["contrast"], settings["saturation"], settings["iso"],
        error, len(error))
    assert context, error.value
    try:
        if settings["mode"] == 12:
            status = native.lumix_process_rgb12(context, source.ctypes.data, len(source),
                output.ctypes.data, error, len(error))
        else:
            status = native.lumix_process_rgb16(context, source.ctypes.data, len(source),
                settings["white"], settings["ev"], settings["space"],
                output.ctypes.data, error, len(error))
    finally:
        native.lumix_destroy(context)

    assert status == 1, error.value
    np.testing.assert_array_equal(output, expected)
