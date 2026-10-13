"""RGB image IO, explicit ICC management, and precise TIFF diagnostics."""
from __future__ import annotations

import io
from functools import lru_cache
from pathlib import Path

import numpy as np
import tifffile
from PIL import Image, ImageCms, ImageOps

from .color import clamp
from .validation import canonical_space, pixel_shape


def _pixel_data(image):
    getter = getattr(image,"get_flattened_data",None)
    return list(getter()) if getter is not None else list(image.getdata())


def _icc_bytes(space: str | None) -> bytes | None:
    if space is None: return None
    space = canonical_space(space)
    name = "ISL-ARGB1998.icc" if space == "AdobeRGB" else "ISL-sRGB.icc"
    profile = Path(__file__).with_name("data") / "icc" / name
    if profile.is_file(): return profile.read_bytes()
    if space == "sRGB":
        return ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    raise RuntimeError("AdobeRGB output requires its packaged ICC profile")


def _manage_pixels(pixels, profile, colour_manage):
    if not colour_manage or not profile: return pixels
    if profile==_icc_bytes("sRGB"): return pixels
    from .icc import transform_rgb
    return transform_rgb(pixels,profile,_working_srgb_profile(),target_srgb=True)


@lru_cache(maxsize=1)
def _working_srgb_profile():
    # A parametric TRC keeps float input precision. The vendor's sampled
    # 1024-point TRC is retained as an output asset, not used as this inverse.
    return ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def pixels_from_image(image):
    w,h = image.size
    if image.mode.startswith("I;16"):
        raw = _pixel_data(image); values = [float(v)/65535 for v in raw]
        return [[(v,)*3 for v in values[y*w:(y+1)*w]] for y in range(h)]
    if image.mode in {"I","F"}:
        scale = 65535 if image.mode == "I" else 1
        raw = _pixel_data(image)
        return [[(clamp(float(v)/scale),)*3 for v in raw[y*w:(y+1)*w]] for y in range(h)]
    rgb = image.convert("RGB"); raw = _pixel_data(rgb)
    return [[(r/255,g/255,b/255) for r,g,b in raw[y*w:(y+1)*w]] for y in range(h)]


def _orient_array(array, orientation):
    if orientation == 1: return array
    if orientation == 2: return array[:,::-1]
    if orientation == 3: return array[::-1,::-1]
    if orientation == 4: return array[::-1]
    if orientation == 5: return np.swapaxes(array,0,1)
    if orientation == 6: return np.rot90(array,-1,axes=(0,1))
    if orientation == 7: return np.swapaxes(array,0,1)[::-1,::-1]
    if orientation == 8: return np.rot90(array,1,axes=(0,1))
    raise ValueError(f"Invalid TIFF orientation {orientation}")


def _read_tiff(path, *, colour_manage=True):
    try:
        with tifffile.TiffFile(path) as file:
            page = file.pages[0]
            photo = int(page.photometric)
            if photo not in {0,1,2}:
                raise ValueError(f"Unsupported TIFF photometric interpretation {photo}; RGB or grayscale is required")
            array = page.asarray()
            if array.ndim==3 and int(page.planarconfig)==2:
                array = np.moveaxis(array,0,-1)
            if array.ndim==2: array = np.repeat(array[...,None],3,axis=2)
            if array.ndim!=3 or array.shape[-1] not in {3,4}:
                raise ValueError("Unsupported TIFF sample layout")
            bits = page.bitspersample
            if not isinstance(bits,int):
                if len(set(bits))!=1: raise ValueError("Mixed TIFF channel depths are unsupported")
                bits = bits[0]
            if array.dtype.kind == "u": array = array.astype(np.float64)/((1<<bits)-1)
            elif array.dtype.kind == "f": array = array.astype(np.float64)
            else: raise ValueError("TIFF samples must be unsigned integers or floats")
            if photo==0: array = 1-array
            if array.shape[-1]==4:
                if page.extrasamples and int(page.extrasamples[0])==1:
                    alpha = array[...,3:4]
                    array[...,:3] = np.divide(array[...,:3],alpha,out=np.zeros_like(array[...,:3]),where=alpha>0)
                array = array[...,:3]
            if not np.isfinite(array).all(): raise ValueError("TIFF contains non-finite samples")
            orientation = int(page.tags[274].value) if 274 in page.tags else 1
            array = _orient_array(array,orientation)
            profile = bytes(page.tags[34675].value) if 34675 in page.tags else None
            pixels = [[tuple(rgb) for rgb in row] for row in array.tolist()]
            return _manage_pixels(pixels,profile,colour_manage)
    except (tifffile.TiffFileError,IndexError) as exc:
        raise ValueError(f"Invalid TIFF: {path}") from exc


def read_tiff16_pixels(path, *, colour_manage=True):
    """Read RGB/grayscale TIFF at source precision, including planar/tiled data."""
    return _read_tiff(path,colour_manage=colour_manage)


def load_pixels(path, *, colour_manage=True):
    path = Path(path)
    if path.suffix.lower() in {".tif",".tiff"}:
        return _read_tiff(path,colour_manage=colour_manage)
    with Image.open(path) as source:
        profile = source.info.get("icc_profile")
        corrected = ImageOps.exif_transpose(source)
        if colour_manage and profile and corrected.mode in {"CMYK","LAB","L"}:
            corrected = ImageCms.profileToProfile(corrected,ImageCms.ImageCmsProfile(io.BytesIO(profile)),ImageCms.ImageCmsProfile(io.BytesIO(_icc_bytes("sRGB"))),outputMode="RGB")
            profile = _icc_bytes("sRGB")
        pixels = pixels_from_image(corrected)
        return _manage_pixels(pixels,profile,colour_manage)


def load_image(path, *, colour_manage=True):
    """Return an oriented, managed RGB preview of precisely loaded pixels."""
    return image_from_pixels(load_pixels(path,colour_manage=colour_manage))


def load_lab_pixels(path):
    """Read chart colours directly into D65 Lab without an sRGB gamut clip."""
    from .color import domain_to_lab,xyz_to_lab
    from .validation import pixel_shape
    pixels = load_pixels(path,colour_manage=False)
    pixel_shape(pixels)
    if any(not 0<=v<=1 for row in pixels for rgb in row for v in rgb):
        raise ValueError("ColorChecker input requires normalized display RGB values")
    if Path(path).suffix.lower() in {".tif",".tiff"}:
        with tifffile.TiffFile(path) as source:
            profile = bytes(source.pages[0].tags[34675].value) if 34675 in source.pages[0].tags else None
    else:
        with Image.open(path) as source:
            profile = source.info.get("icc_profile")
    if not profile or profile==_icc_bytes("sRGB"):
        return [[domain_to_lab(rgb,"sRGB") for rgb in row] for row in pixels]
    if profile==_icc_bytes("AdobeRGB"):
        return [[domain_to_lab(rgb,"AdobeRGB") for rgb in row] for row in pixels]
    import imagecodecs
    if not getattr(imagecodecs.CMS,"available",False):
        raise RuntimeError("Colorimetric comparison of this profile requires imagecodecs with LittleCMS")
    xyz_profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("XYZ")).tobytes()
    xyz = imagecodecs.cms_transform(np.asarray(pixels,dtype=np.float64),profile,xyz_profile,
                                   colorspace="RGB",outcolorspace="XYZ",outdtype="float64",intent=1)
    # Bradford adaptation from ICC PCS D50 to the renderer's D65 Lab white.
    adapt = np.array(((.9555766,-.0230393,.0631636),(-.0282895,1.0099416,.0210077),(.0122982,-.0204830,1.3299098)))
    xyz = xyz@adapt.T
    if not np.isfinite(xyz).all(): raise ValueError("ICC conversion produced non-finite XYZ")
    return [[xyz_to_lab(rgb) for rgb in row] for row in xyz.tolist()]


def image_from_pixels(pixels, bits=8):
    h,w = pixel_shape(pixels)
    data = bytes(round(clamp(float(v))*255) for row in pixels for rgb in row for v in rgb)
    return Image.frombytes("RGB",(w,h),data)


def _write_tiff(path,pixels,colour_space,dtype):
    pixel_shape(pixels)
    array = np.asarray(pixels,dtype=np.float64)
    if dtype==np.uint16: array = np.rint(np.clip(array,0,1)*65535).astype(np.uint16)
    else: array = array.astype(np.float32)
    profile = _icc_bytes(colour_space)
    tags = [(34675,"B",len(profile),profile,False)] if profile else []
    path = Path(path); path.parent.mkdir(parents=True,exist_ok=True)
    tifffile.imwrite(path,array,photometric="rgb",planarconfig="contig",byteorder="<",metadata=None,extratags=tags)


def write_tiff16(path,pixels,colour_space="sRGB"):
    _write_tiff(path,pixels,colour_space,np.uint16)


def write_float_tiff(path,pixels):
    """Preserve linear/sensor diagnostics as untagged IEEE float32 TIFF."""
    _write_tiff(path,pixels,None,np.float32)


def save_image(path,image,pixels=None,bits=16,colour_space="sRGB",quality=95):
    if bits not in {8,16}: raise ValueError("Output depth must be 8 or 16")
    path = Path(path); path.parent.mkdir(parents=True,exist_ok=True)
    suffix = path.suffix.lower()
    if suffix in {".tif",".tiff"} and bits==16 and pixels is not None:
        write_tiff16(path,pixels,colour_space); return
    icc = _icc_bytes(colour_space)
    if suffix in {".jpg",".jpeg"}:
        image.convert("RGB").save(path,format="JPEG",quality=quality,icc_profile=icc)
    elif suffix in {".tif",".tiff"}:
        image.convert("RGB").save(path,format="TIFF",compression="tiff_lzw",icc_profile=icc)
    elif suffix==".png": image.convert("RGB").save(path,format="PNG",icc_profile=icc)
    else: image.convert("RGB").save(path,quality=quality,icc_profile=icc)
