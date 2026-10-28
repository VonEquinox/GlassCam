"""Precision-preserving RGB ICC transforms through LittleCMS."""
from __future__ import annotations

import ctypes
import ctypes.util
from functools import lru_cache
from pathlib import Path

import numpy as np
from PIL import ImageCms


@lru_cache(maxsize=1)
def _lcms():
    candidates = [ctypes.util.find_library("lcms2")]
    import PIL
    for directory in (Path(PIL.__file__).parent, Path(PIL.__file__).parent.parent / "pillow.libs", Path(PIL.__file__).parent / ".dylibs"):
        if directory.exists():
            candidates.extend(str(p) for p in directory.glob("*lcms*") if p.is_file())
    candidates.append(ImageCms.core.__file__)
    for name in candidates:
        if not name: continue
        try:
            lib = ctypes.CDLL(name)
            signatures = {
                "cmsOpenProfileFromMem": ([ctypes.c_void_p,ctypes.c_uint32],ctypes.c_void_p),
                "cmsGetColorSpace": ([ctypes.c_void_p],ctypes.c_uint32),
                "cmsCreateTransform": ([ctypes.c_void_p,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_uint32],ctypes.c_void_p),
                "cmsDoTransform": ([ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_uint32],None),
                "cmsDeleteTransform": ([ctypes.c_void_p],None),
                "cmsCloseProfile": ([ctypes.c_void_p],ctypes.c_int),
            }
            for symbol,(arguments,result) in signatures.items():
                fn = getattr(lib,symbol); fn.argtypes = arguments; fn.restype = result
            return lib
        except (OSError,AttributeError):
            continue
    return None


def transform_rgb(pixels, source_profile: bytes, target_profile: bytes, *, target_srgb=False):
    if source_profile == target_profile:
        return [list(map(tuple,row)) for row in pixels]
    import io
    try:
        ImageCms.ImageCmsProfile(io.BytesIO(source_profile))
        ImageCms.ImageCmsProfile(io.BytesIO(target_profile))
    except (OSError,ValueError) as exc:
        raise ValueError("Invalid embedded ICC profile") from exc
    if source_profile[16:20]!=b"RGB " or target_profile[16:20]!=b"RGB ":
        raise ValueError("RGB pixels require RGB ICC profiles")
    import imagecodecs
    if getattr(imagecodecs.CMS,"available",False):
        array = np.ascontiguousarray(pixels,dtype=np.float64)
        out = imagecodecs.cms_transform(array,source_profile,target_profile,colorspace="RGB",outcolorspace="RGB",outdtype="float64",intent=1,flags=0x0100)
        if not np.isfinite(out).all(): raise ValueError("ICC transform produced non-finite pixels")
        return [[tuple(rgb) for rgb in row] for row in np.clip(out,0,1).tolist()]
    engine = _lcms()
    if engine is None:
        from .color import adobe_rgb_to_srgb, srgb_to_adobe_rgb
        from .io import _icc_bytes
        if source_profile == _icc_bytes("AdobeRGB") and (target_srgb or target_profile == _icc_bytes("sRGB")):
            return [[adobe_rgb_to_srgb(rgb) for rgb in row] for row in pixels]
        if source_profile == _icc_bytes("sRGB") and target_profile == _icc_bytes("AdobeRGB"):
            return [[srgb_to_adobe_rgb(rgb) for rgb in row] for row in pixels]
        raise RuntimeError("This ICC profile requires LittleCMS 2; high-bit-depth input will not be silently quantized")
    buffers = [ctypes.create_string_buffer(p) for p in (source_profile,target_profile)]
    profiles, transform = [], None
    try:
        for buffer,profile in zip(buffers,(source_profile,target_profile)):
            handle = engine.cmsOpenProfileFromMem(buffer,len(profile))
            if not handle: raise ValueError("Cannot open ICC profile")
            profiles.append(handle)
            if engine.cmsGetColorSpace(handle) != 0x52474220:
                raise ValueError("RGB pixel data requires an RGB ICC profile")
        rgb_double = (1<<22)|(4<<16)|(3<<3)
        transform = engine.cmsCreateTransform(profiles[0],rgb_double,profiles[1],rgb_double,1,0x0100)
        if not transform: raise ValueError("Cannot construct RGB ICC transform")
        array = np.ascontiguousarray(pixels,dtype=np.float64)
        out = np.empty_like(array)
        engine.cmsDoTransform(transform,array.ctypes.data,out.ctypes.data,array.shape[0]*array.shape[1])
        if not np.isfinite(out).all(): raise ValueError("ICC transform produced non-finite pixels")
        return [[tuple(rgb) for rgb in row] for row in np.clip(out,0,1).tolist()]
    finally:
        if transform: engine.cmsDeleteTransform(transform)
        for handle in profiles: engine.cmsCloseProfile(handle)
