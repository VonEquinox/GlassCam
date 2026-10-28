"""C ABI declarations shared by pytest numerical checks."""
from contextlib import contextmanager
from pathlib import Path
import ctypes as c

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
P = c.c_void_p
S = c.c_size_t


def configure(lib):
    lib.hncs_create.argtypes = [c.c_double, c.c_double]
    lib.hncs_create.restype = P
    lib.hncs_create_mode.argtypes = [c.c_double, c.c_double, c.c_int, c.c_int]
    lib.hncs_create_mode.restype = P
    lib.hncs_create_preset.argtypes = [c.c_double] * 3 + [c.c_int] * 4 + [c.c_char_p, c.c_int, P, P]
    lib.hncs_create_preset.restype = P
    lib.hncs_destroy.argtypes = [P]
    for name in ('hncs_apply_post_curves', 'hncs_apply_preset_pointwise', 'hncs_apply_preset_work_float'):
        getattr(lib, name).argtypes = [c.c_char_p, c.c_int, P, P, S]
    for name in ('hncs_process_srgb', 'hncs_process_srgb_fast', 'hncs_process_linear_rgba',
                 'hncs_render_native', 'hncs_render_native_preset', 'hncs_process_preset_work_float',
                 'hncs_finish_preset_work_linear'):
        getattr(lib, name).argtypes = [P, P, P, S]
    for name in ('hncs_process_linear_rgba_parallel', 'hncs_process_srgb_fast_parallel'):
        getattr(lib, name).argtypes = [P, P, P, S, c.c_uint]
    lib.hncs_source_to_native_matrix.argtypes = [P, P]
    lib.hncs_preset_white_balance.argtypes = [P, P, P, P]
    lib.hncs_preset_count.restype = S
    for name in ('hncs_preset_key', 'hncs_preset_name'):
        getattr(lib, name).argtypes = [S]
        getattr(lib, name).restype = c.c_char_p
    lib.hncs_preset_settings_json.argtypes = [c.c_char_p]
    lib.hncs_preset_settings_json.restype = c.c_char_p
    lib.hncs_preset_flags.argtypes = [c.c_char_p]
    lib.hncs_preset_flags.restype = c.c_uint
    lib.ffcs_create.argtypes = [c.c_char_p, S, P, S]
    lib.ffcs_create.restype = P
    lib.ffcs_create_config.argtypes = [c.c_char_p, S, c.c_int, c.c_int, c.c_int, c.c_double, P, S]
    lib.ffcs_create_config.restype = P
    lib.ffcs_destroy.argtypes = [P]
    lib.ffcs_required_halo.argtypes = [P]
    lib.ffcs_required_halo.restype = S
    lib.ffcs_process_linear_rgb_optimized.argtypes = [P, P, S, S, S, c.c_float, c.c_uint32, P, S, P, S, c.c_uint, P, S]
    lib.ffcs_process_linear_rgb_strip.argtypes = [P, P, S, S, S, S, S, S, S, c.c_float, c.c_uint32, P, S, c.c_uint, P, S]
    lib.lumix_look_count.restype = S
    lib.lumix_look_key.argtypes = [S]
    lib.lumix_look_key.restype = c.c_char_p
    lib.lumix_create.argtypes = [c.c_char_p, S, P, S]
    lib.lumix_create.restype = P
    lib.lumix_destroy.argtypes = [P]
    lib.lumix_process_rgb12.argtypes = [P, P, S, P, P, S]
    lib.lumix_process_linear_rgba.argtypes = [P, P, S, S, c.c_double, P, S, P, S]
    return lib


@contextmanager
def context(lib, *, key=None, ev=0, kelvin=6500, lstar=0, repro=0, film=4, raw=2,
            tone=1, factory=0, baseline=None, target=None):
    baseline = None if baseline is None else np.ascontiguousarray(baseline, dtype=np.float64)
    target = None if target is None else np.ascontiguousarray(target, dtype=np.float64)
    if key is None:
        value = lib.hncs_create_mode(ev, kelvin, lstar, repro)
    else:
        value = lib.hncs_create_preset(ev, kelvin, factory, lstar, repro, film, raw, key.encode(), tone,
            None if baseline is None else baseline.ctypes.data, None if target is None else target.ctypes.data)
    assert value
    try:
        yield value
    finally:
        lib.hncs_destroy(value)


def render(lib, name, ctx, pixels, dtype=np.float32, channels=4, *extra):
    output = np.empty((*pixels.shape[:-1], channels), dtype=dtype)
    status = getattr(lib, name)(ctx, pixels.ctypes.data, output.ctypes.data, pixels.size // 3, *extra)
    assert status == 0
    return output


def preset(lib, name, key, tone, pixels, dtype=np.uint16):
    output = np.empty_like(pixels, dtype=dtype)
    assert getattr(lib, name)(key.encode(), tone, pixels.ctypes.data, output.ctypes.data, pixels.size // 3) == 0
    return output


def bridge(lib, ctx):
    output = np.empty((3, 3), dtype=np.float64)
    assert lib.hncs_source_to_native_matrix(ctx, output.ctypes.data) == 0
    return output
