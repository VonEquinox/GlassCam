"""FFCS full-frame input remains intact when output storage overlaps it."""
import ctypes as c

import numpy as np
import pytest

from support.native import ROOT

PIXELS = 127
RGB_FLOATS = PIXELS * 3
RGB_BYTES = RGB_FLOATS * np.dtype(np.float32).itemsize


@pytest.mark.parametrize("output_kind", ["linear", "preview"])
@pytest.mark.parametrize("offset_bytes", [-4, 0, 4, RGB_BYTES - 4])
def test_full_frame_input_overlap_fails_before_writing(native, output_kind, offset_bytes):
    error = c.create_string_buffer(1024)
    directory = ROOT / "vendor/ffcs/implementation/ffcs/data/xh2s"
    context = native.ffcs_create_config(str(directory).encode(), 0, 0, 0, 0, 1,
                                        error, len(error))
    assert context, error.value
    storage = np.full(PIXELS * 8, .25, dtype=np.float32)
    separate = np.full(PIXELS * 4, -1, dtype=np.float32)
    source = storage.ctypes.data + storage.itemsize
    linear = source + offset_bytes if output_kind == "linear" else separate.ctypes.data
    preview = source + offset_bytes if output_kind == "preview" else None
    before = storage.copy()
    function = native.ffcs_process_linear_rgb
    function.argtypes = [
        c.c_void_p, c.c_void_p, c.c_size_t, c.c_size_t, c.c_size_t, c.c_float,
        c.c_uint32, c.c_void_p, c.c_size_t, c.c_void_p, c.c_size_t,
        c.c_void_p, c.c_size_t,
    ]

    try:
        status = function(context, source, RGB_FLOATS, PIXELS, 1, 0, 0,
                          linear, RGB_FLOATS, preview, PIXELS * 4, error, len(error))
    finally:
        native.ffcs_destroy(context)

    assert status == 0
    np.testing.assert_array_equal(storage, before)
    np.testing.assert_array_equal(separate, -1)
