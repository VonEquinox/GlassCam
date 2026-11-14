"""Portable LUMIX interpolation and Float32 adapter match independent vectors."""
from concurrent.futures import ThreadPoolExecutor
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import struct
import zlib

import numpy as np
import pytest

from support.native import ROOT

# Existing independent double-reference to Float32 adapter bound.
LINEAR_TOLERANCE = 3e-8


@pytest.fixture(scope='module')
def lumix_manifest(lumix_resources):
    return json.loads((lumix_resources / 'manifest.json').read_text())


@pytest.fixture(params=range(16))
def lumix_case(request, native, lumix_resources, lumix_manifest):
    index = request.param
    look = lumix_manifest['looks'][index]
    data = (ROOT / 'tests/fixtures/lumix/native-vectors' / (Path(look['asset']).stem + '.rgb12')).read_bytes()
    assert hashlib.sha256(data).hexdigest() == look['goldenSHA256']
    probes = np.frombuffer(data, dtype='<u2').reshape(-1, 6)
    error = c.create_string_buffer(1024)
    ctx = native.lumix_create(os.fsencode(lumix_resources), index, error, len(error))
    assert ctx, error.value
    try:
        yield ctx, np.ascontiguousarray(probes[:, :3]), np.ascontiguousarray(probes[:, 3:])
    finally:
        native.lumix_destroy(ctx)


def linear(native, ctx, source):
    output = np.empty((len(source), 4), np.float32)
    error = c.create_string_buffer(1024)
    status = native.lumix_process_linear_rgba(ctx, source.ctypes.data, source.size, len(source), 0,
        output.ctypes.data, output.size, error, len(error))
    return status, output, error.value


def test_lumix_catalog_matches_manifest(native, lumix_manifest):
    assert native.lumix_look_count() == len(lumix_manifest['looks']) == 16
    assert native.lumix_look_key(16) is None


def test_rgb12_interpolation_matches_native_vectors(native, lumix_case):
    ctx, source, expected = lumix_case
    output = np.empty_like(source)
    error = c.create_string_buffer(1024)

    status = native.lumix_process_rgb12(ctx, source.ctypes.data, len(source), output.ctypes.data, error, len(error))

    assert status == 1
    np.testing.assert_array_equal(output, expected)


def test_linear_adapter_matches_native_vector_decode(native, lumix_case):
    ctx, rgb, golden = lumix_case
    source = (rgb.astype(np.float64) / 4095).astype(np.float32)
    encoded = np.clip(golden.astype(np.float64) / 4095, 0, 1)
    expected = np.where(encoded <= .04045, encoded / 12.92, ((encoded + .055) / 1.055)**2.4)

    status, output, error = linear(native, ctx, source)

    assert status == 1, error
    np.testing.assert_array_less(np.abs(output[:, :3] - expected), LINEAR_TOLERANCE)
    np.testing.assert_array_equal(output[:, 3], 1)


def test_concurrent_linear_strips_preserve_full_raster(native, lumix_case):
    ctx, rgb, _ = lumix_case
    source = (rgb.astype(np.float64) / 4095).astype(np.float32)
    expected_status, expected, expected_error = linear(native, ctx, source)
    split = [0, 1, 64, 131, 4096, len(source)]

    with ThreadPoolExecutor(max_workers=4) as executor:
        chunks = list(executor.map(lambda pair: linear(native, ctx, source[pair[0]:pair[1]]), zip(split, split[1:])))
    output = np.concatenate([pixels for _, pixels, _ in chunks])

    assert expected_status == 1, expected_error
    assert [status for status, _, _ in chunks] == [1] * len(chunks)
    np.testing.assert_array_equal(output.view(np.uint32), expected.view(np.uint32))


@pytest.mark.parametrize('case', ['nonfinite-exposure', 'nonfinite-pixel', 'rgb12-overflow'])
def test_invalid_lumix_inputs_fail(native, lumix_case, case):
    ctx, rgb, _ = lumix_case
    source = (rgb.astype(np.float64) / 4095).astype(np.float32)
    output = np.empty((len(source), 4), np.float32)
    error = c.create_string_buffer(1024)
    if case == 'nonfinite-pixel': source[0, 0] = np.nan
    if case == 'rgb12-overflow':
        rgb[0, 0] = 4096
        status = native.lumix_process_rgb12(ctx, rgb.ctypes.data, len(rgb), output.ctypes.data, error, len(error))
    else:
        status = native.lumix_process_linear_rgba(ctx, source.ctypes.data, source.size, len(source),
            np.nan if case == 'nonfinite-exposure' else 0, output.ctypes.data, output.size, error, len(error))
    assert status == 0


def test_unknown_lumix_look_fails(native, lumix_resources):
    error = c.create_string_buffer(1024)
    assert not native.lumix_create(os.fsencode(lumix_resources), 16, error, len(error))


@pytest.mark.parametrize('case', ['missing', 'truncated', 'corrupt', 'wrong-grid', 'trailing-data'])
def test_invalid_lumix_resource_fails(native, lumix_resources, tmp_path, case):
    source = (lumix_resources / 'L00801.lmx').read_bytes()
    variants = {'truncated': source[:-100], 'corrupt': source[:50] + bytes([source[50] ^ 1]) + source[51:],
                'wrong-grid': source[:8] + struct.pack('<I', 257) + source[12:], 'trailing-data': source + b'junk'}
    if case != 'missing': (tmp_path / 'L00801.lmx').write_bytes(variants[case])
    error = c.create_string_buffer(1024)

    value = native.lumix_create(os.fsencode(tmp_path), 0, error, len(error))

    assert not value


@pytest.mark.parametrize('case', ['nonfinite', 'repeated-position', 'descending-position'])
def test_invalid_temperature_curve_with_valid_checksum_is_rejected(native, lumix_resources, tmp_path, case):
    for path in lumix_resources.glob('*.lmx'):
        (tmp_path / path.name).symlink_to(path)
    registers = bytearray((lumix_resources / 'pipeline.lmp').read_bytes())
    offset = len(registers) - 64
    if case == 'nonfinite':
        struct.pack_into('<d', registers, offset + 2*16 + 8, float('nan'))
    else:
        struct.pack_into('<d', registers, offset + 2*16, 5000 if case == 'repeated-position' else 4000)
    struct.pack_into('<I', registers, 16, zlib.crc32(registers[24:]))
    (tmp_path / 'pipeline.lmp').write_bytes(registers)
    error = c.create_string_buffer(1024)

    context = native.lumix_create_pipeline(os.fsencode(tmp_path), 0, 6500, 10, 10, 100, error, len(error))

    try:
        assert not context
    finally:
        if context: native.lumix_destroy(context)


@pytest.mark.parametrize('offset', [0, 1, 3])
def test_overlapping_rgb_rgba_is_rejected_without_writes(native, lumix_case, offset):
    context, _, _ = lumix_case
    pixels = 3
    storage = np.linspace(0.1, 0.9, pixels*4 + offset, dtype=np.float32)
    before = storage.copy()
    error = c.create_string_buffer(1024)

    status = native.lumix_process_linear_rgba(context, storage.ctypes.data, pixels*3, pixels, 0,
        storage[offset:].ctypes.data, pixels*4, error, len(error))

    assert status == 0
    np.testing.assert_array_equal(storage, before)
