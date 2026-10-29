"""Frozen original Phocus vectors and ownership of native-gain contexts."""
import ctypes as c

import numpy as np
import pytest

from support import golden_vectors

GOLDEN = golden_vectors.manifest("x2d-native-gain-goldens.json")


@pytest.fixture(scope="module")
def gain_library(native):
    native.hncs_clone_with_native_gain.argtypes = [c.c_void_p, c.c_double]
    native.hncs_clone_with_native_gain.restype = c.c_void_p
    return native


@pytest.fixture(scope="module")
def vectors():
    return golden_vectors.vectors(GOLDEN)


@pytest.mark.parametrize("case", GOLDEN["cases"], ids=lambda case: case["golden_prefix"])
def test_gain_clone_matches_original_vectors_and_preserves_parent(gain_library, vectors, case):
    lib = gain_library
    key = case["golden_prefix"]
    source = np.ascontiguousarray(vectors[key + "_input"].astype(np.float64) / 65535.)
    expected = vectors[key + "_expected"]
    original, actual, after = [np.empty_like(expected) for _ in range(3)]
    parent = lib.hncs_create_mode(0., case["cct"], case["space"], case["model"])
    assert parent
    child = None
    try:
        before_status = lib.hncs_render_native(parent, source.ctypes.data, original.ctypes.data, source.size // 3)
        child = lib.hncs_clone_with_native_gain(parent, case["gain"])
        assert child

        child_status = lib.hncs_render_native(child, source.ctypes.data, actual.ctypes.data, source.size // 3)
        after_status = lib.hncs_render_native(parent, source.ctypes.data, after.ctypes.data, source.size // 3)
    finally:
        lib.hncs_destroy(child)
        lib.hncs_destroy(parent)

    assert [before_status, child_status, after_status] == [0, 0, 0]
    np.testing.assert_array_equal(actual, expected)
    np.testing.assert_array_equal(after, original)


@pytest.mark.parametrize("gain", [0., -1., float("nan"), float("inf"), -float("inf"), 1e-308, 1e308])
def test_invalid_native_gain_rejects_clone(gain_library, gain):
    lib = gain_library
    parent = lib.hncs_create_mode(0., 7523., 0, 0)
    assert parent
    try:
        child = lib.hncs_clone_with_native_gain(parent, gain)
        if child:
            lib.hncs_destroy(child)
    finally:
        lib.hncs_destroy(parent)

    assert child is None


def test_null_parent_rejects_gain_clone(gain_library):
    child = gain_library.hncs_clone_with_native_gain(None, 1.)
    if child:
        gain_library.hncs_destroy(child)

    assert child is None


def test_gain_clone_remains_valid_after_parent_destruction(gain_library, vectors):
    lib = gain_library
    key = GOLDEN["cases"][0]["golden_prefix"]
    codes = vectors[key + "_input"]
    source = np.ascontiguousarray(codes.astype(np.float64) / 65535.)
    before, after = np.empty_like(codes), np.empty_like(codes)
    parent = lib.hncs_create_mode(0., 7523., 0, 0)
    assert parent
    try:
        before_status = lib.hncs_render_native(parent, source.ctypes.data, before.ctypes.data, source.size // 3)
        child = lib.hncs_clone_with_native_gain(parent, 1.)
        assert child
    finally:
        lib.hncs_destroy(parent)

    try:
        after_status = lib.hncs_render_native(child, source.ctypes.data, after.ctypes.data, source.size // 3)
    finally:
        lib.hncs_destroy(child)

    assert [before_status, after_status] == [0, 0]
    np.testing.assert_array_equal(after, before)
