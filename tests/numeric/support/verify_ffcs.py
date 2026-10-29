"""FFCS C ABI binding retained for the standalone benchmark."""
from native_build import build_product, build_command
from .native import ROOT


def build_library():
    import ctypes as c
    out = build_product()
    command = build_command('GlassCamNative')
    lib = c.CDLL(str(out))
    ptr = c.POINTER
    lib.ffcs_simulation_count.restype = c.c_size_t
    for fn in ('ffcs_simulation_name', 'ffcs_simulation_asset'):
        getattr(lib, fn).argtypes = [c.c_size_t]
        getattr(lib, fn).restype = c.c_char_p
    lib.ffcs_create.argtypes = [c.c_char_p, c.c_size_t, c.c_char_p, c.c_size_t]
    lib.ffcs_create.restype = c.c_void_p
    lib.ffcs_destroy.argtypes = [c.c_void_p]
    callback = c.CFUNCTYPE(None, c.c_char_p, ptr(c.c_double), c.c_size_t, c.c_size_t, c.c_void_p)
    lib.ffcs_process_encoded_double.argtypes = [c.c_void_p, ptr(c.c_double), c.c_size_t,
        c.c_size_t, c.c_size_t, c.c_uint32, ptr(c.c_double), c.c_size_t,
        callback, c.c_void_p, c.c_char_p, c.c_size_t]
    lib.ffcs_process_linear_rgb.argtypes = [c.c_void_p, ptr(c.c_float), c.c_size_t,
        c.c_size_t, c.c_size_t, c.c_float, c.c_uint32, ptr(c.c_float), c.c_size_t,
        ptr(c.c_uint8), c.c_size_t, c.c_char_p, c.c_size_t]
    return lib, callback, command
