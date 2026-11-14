"""Invalid overlapping storage is rejected before any pixel is overwritten."""
import ctypes as c

import numpy as np
import pytest

from support.native import context

FLOAT_STAGES = (
    "hncs_process_linear_rgba",
    "hncs_process_preset_work_float",
    "hncs_finish_preset_work_linear",
    "hncs_process_phocus_work_float",
    "hncs_finish_phocus_work_linear",
    "hncs_process_phocus_linear_rgba",
)


@pytest.mark.parametrize("name", FLOAT_STAGES)
@pytest.mark.parametrize("workers", [None, 1, 4])
@pytest.mark.parametrize("offset", [-1, 0, 1, 3 * 32768])
def test_hncs_overlapping_float_ranges_fail_without_writes(native, name, workers, offset):
    # Crosses the 32768-pixel work claims and the 65536-pixel dispatch threshold.
    count = 65539
    storage = np.full(count * 8 + abs(offset), .25, dtype=np.float32)
    source = storage.ctypes.data + max(0, -offset) * storage.itemsize
    output = source + offset * storage.itemsize
    before = storage.copy()
    function = getattr(native, name + ("_parallel" if workers is not None else ""))
    function.argtypes = [c.c_void_p] * 3 + [c.c_size_t] + ([] if workers is None else [c.c_uint])
    with context(native, key="nature") as ctx:
        status = function(ctx, source, output, count, *([] if workers is None else [workers]))

    assert status == -1
    np.testing.assert_array_equal(storage, before)


@pytest.mark.parametrize("name", ["hncs_process_srgb", "hncs_process_srgb_fast",
                                  "hncs_process_srgb_fast_parallel"])
@pytest.mark.parametrize("offset", [-4, 0, 4, 8 * 65539])
def test_hncs_overlapping_byte_output_fails_without_writes(native, name, offset):
    count = 65539
    storage = np.full(count * 8, .25, dtype=np.float32)
    source = storage.ctypes.data + max(0, -offset)
    output = source + offset
    before = storage.copy()
    arguments = [source, output, count] + ([4] if name.endswith("_parallel") else [])
    with context(native) as ctx:
        status = getattr(native, name)(ctx, *arguments)

    assert status == -1
    np.testing.assert_array_equal(storage, before)


@pytest.mark.parametrize("offset", [-4, 0, 4])
def test_ffcs_overlapping_outputs_fail_without_writes(native, offset):
    from support.native import ROOT
    error = c.create_string_buffer(1024)
    directory = ROOT / "App/GlassCam/Resources/FFCS/xh2s"
    ctx = native.ffcs_create_config(str(directory).encode(), 0, 0, 0, 0, 1, error, len(error))
    assert ctx
    count = 127
    source = np.full(count * 3, .25, dtype=np.float32)
    storage = np.full(count * 4, -1, dtype=np.float32)
    before = storage.copy()
    output = storage.ctypes.data + max(0, -offset)
    function = native.ffcs_process_linear_rgb
    function.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.c_size_t, c.c_size_t,
                         c.c_float, c.c_uint32, c.c_void_p, c.c_size_t, c.c_void_p,
                         c.c_size_t, c.c_void_p, c.c_size_t]
    try:
        status = function(ctx, source.ctypes.data, source.size, count, 1, 0, 0,
                          output, source.size, output + offset, count * 4, error, len(error))
    finally:
        native.ffcs_destroy(ctx)

    assert status == 0
    np.testing.assert_array_equal(storage, before)
