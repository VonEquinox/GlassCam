"""Pinned FFCS oracle loading, C ABI bindings, and observed native outputs."""
from __future__ import annotations

import ctypes as c
import hashlib
import json
from pathlib import Path
import random
import sys
from unittest.mock import patch

import numpy as np

from materialize_ffcs_reference import PREFIX, retained_reference_file, verified_archive
from native_build import build_product, build_command

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'vendor/ffcs'
V = ROOT / 'tests/fixtures/ffcs'
FAMILIES = ('XH2S', 'XA3', 'GFX100', 'GFX100S', 'GFX100II')
NAMES = ('PROVIA', 'VELVIA', 'ASTIA', 'CLASSIC CHROME', 'CLASSIC NEG.', 'NOSTALGIC NEG.',
    'ETERNA', 'ETERNA BLEACH BYPASS', 'ACROS', 'MONOCHROME', 'PRO NEG. HI', 'PRO NEG. STD',
    'SEPIA', 'ACROS+G', 'ACROS+R', 'ACROS+Ye', 'MONOCHROME+G', 'MONOCHROME+R',
    'MONOCHROME+Ye', 'REALA ACE')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_stamp(source):
    manifest_path = source / 'validation/delivery_manifest.json'
    manifest = json.loads(manifest_path.read_text())
    with verified_archive(source / 'source.zip') as archive:
        for entry in manifest['files']:
            path = entry['path']
            actual = (sha(source / path) if retained_reference_file(path)
                else hashlib.sha256(archive.read(PREFIX + path)).hexdigest())
            if actual != entry['sha256']:
                raise ValueError(f'Reference asset hash mismatch: {path}')
    return {
        'version': manifest['version'],
        'manifest_sha256': sha(manifest_path),
        'verified_manifest_files': len(manifest['files']),
        'implementation_sha256': {str(path.relative_to(source)): sha(path)
            for path in sorted((source / 'implementation/ffcs').glob('*.py'))},
    }


def load(source=SOURCE):
    sys.path.insert(0, str(source / 'implementation'))
    return source


def pixels(width=6, height=4):
    rng = random.Random(928)
    output = np.asarray([[[rng.uniform(-.2, 1.2) for _ in range(3)]
        for _ in range(width)] for _ in range(height)], dtype=np.float64)
    boundary = [-.2, 0, 1e-8, .0031308, .04045 - 1e-10, .04045,
        .04045 + 1e-10, .18, .5, 1 - 1e-8, 1, 1.2]
    for index, value in enumerate(boundary[:width * height]):
        output.reshape(-1, 3)[index] = value
    return output


def reference(data, camera, name, overlay=False, radius=1., grain=True, sharp=True, seed=0, linear=False):
    from PIL import Image
    from ffcs.pipeline import FFCS, PipelineConfig
    import ffcs.pipeline as pipeline

    original_grain = pipeline.apply_grain
    original_sharp = pipeline.apply_sharpen_pixels
    def apply_grain(pixels, settings, seed=0):
        return original_grain(pixels, settings, seed) if grain else pixels
    def apply_sharpness(pixels, amount, radius=1):
        return original_sharp(pixels, amount, radius) if sharp else pixels

    config = PipelineConfig(camera=camera, simulation=name, seed=seed, input_is_linear=linear,
        apply_reference_adjustments=overlay, sharpen_radius=radius)
    with patch.object(pipeline, 'apply_grain', side_effect=apply_grain), \
            patch.object(pipeline, 'apply_sharpen_pixels', side_effect=apply_sharpness):
        return FFCS(config).apply(Image.new('RGB', (len(data[0]), len(data))),
            input_pixels=data.tolist() if hasattr(data, 'tolist') else data)


def configured(source):
    from ffcs.lutdata import load_reference_lut
    return [(camera, index, loaded[2]) for camera in FAMILIES for index, name in enumerate(NAMES)
        if (loaded := load_reference_lut(camera, name)) is not None]


def build():
    lib = c.CDLL(str(build_product()))
    size, pointer, text = c.c_size_t, c.c_void_p, c.c_char_p
    floats, doubles, bytes_ = c.POINTER(c.c_float), c.POINTER(c.c_double), c.POINTER(c.c_uint8)
    callback = c.CFUNCTYPE(None, text, doubles, size, size, pointer)
    lib.ffcs_create.argtypes = [text, size, text, size]
    lib.ffcs_create.restype = pointer
    lib.ffcs_create_family_config.argtypes = [text, text, size, c.c_int, c.c_int, c.c_int, c.c_double, text, size]
    lib.ffcs_create_family_config.restype = pointer
    lib.ffcs_create_config.argtypes = [text, size, c.c_int, c.c_int, c.c_int, c.c_double, text, size]
    lib.ffcs_create_config.restype = pointer
    lib.ffcs_destroy.argtypes = [pointer]
    lib.ffcs_required_halo.argtypes = [pointer]
    lib.ffcs_required_halo.restype = size
    lib.ffcs_asset_family.argtypes = [pointer]
    lib.ffcs_asset_family.restype = text
    lib.ffcs_simulation_available.argtypes = [text, text, size]
    lib.ffcs_simulation_available.restype = c.c_int
    lib.ffcs_simulation_count.restype = size
    lib.ffcs_simulation_name.argtypes = [size]
    lib.ffcs_simulation_name.restype = text
    lib.ffcs_process_encoded_double.argtypes = [pointer, doubles, size, size, size,
        c.c_uint32, doubles, size, callback, pointer, text, size]
    base = [pointer, floats, size, size, size, c.c_float, c.c_uint32, floats, size, bytes_, size]
    lib.ffcs_process_linear_rgb.argtypes = base + [text, size]
    lib.ffcs_process_linear_rgb_optimized.argtypes = base + [c.c_uint, text, size]
    lib.ffcs_process_linear_rgb_strip.argtypes = [pointer, floats, size, size, size, size, size,
        size, size, c.c_float, c.c_uint32, floats, size, c.c_uint, text, size]
    return lib, callback, build_command('GlassCamNative')


def encoded(lib, callback, ctx, data, seed=0):
    output = np.empty_like(data)
    stages = {}
    @callback
    def capture(name, pointer, width, height, user):
        stages[name.decode()] = np.ctypeslib.as_array(pointer, shape=(width * height * 3,)).copy().reshape(height, width, 3)
    error = c.create_string_buffer(1024)
    pointer = c.POINTER(c.c_double)
    status = lib.ffcs_process_encoded_double(ctx, data.ctypes.data_as(pointer), data.size,
        data.shape[1], data.shape[0], seed, output.ctypes.data_as(pointer), output.size,
        capture, None, error, len(error))
    return status, output, stages, error.value


def linear(lib, ctx, data, exposure=.7, seed=0xffffffff, workers=None, mode='both', unused_capacity=False):
    output = np.empty_like(data) if mode in ('both', 'float') else None
    preview = np.empty((*data.shape[:2], 4), dtype=np.uint8) if mode in ('both', 'preview') else None
    error = c.create_string_buffer(1024)
    fp, bp = c.POINTER(c.c_float), c.POINTER(c.c_uint8)
    args = [ctx, data.ctypes.data_as(fp), data.size, data.shape[1], data.shape[0], exposure, seed,
        output.ctypes.data_as(fp) if output is not None else None,
        output.size if output is not None else (data.size if unused_capacity else 0),
        preview.ctypes.data_as(bp) if preview is not None else None,
        preview.size if preview is not None else (data.shape[0] * data.shape[1] * 4 if unused_capacity else 0)]
    if workers is None:
        status = lib.ffcs_process_linear_rgb(*args, error, len(error))
    else:
        status = lib.ffcs_process_linear_rgb_optimized(*args, workers, error, len(error))
    return status, output, preview, error.value


def strip(lib, ctx, data, width, height, first, y, rows, exposure, seed, workers):
    output = np.full((rows, width, 3), -7, dtype=np.float32)
    error = c.create_string_buffer(1024)
    fp = c.POINTER(c.c_float)
    status = lib.ffcs_process_linear_rgb_strip(ctx, data.ctypes.data_as(fp), data.size,
        width, height, first, len(data), y, rows, exposure, seed,
        output.ctypes.data_as(fp), output.size, workers, error, len(error))
    return status, output, error.value
