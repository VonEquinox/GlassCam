"""Image IO helpers, including a dependency-free 16-bit RGB TIFF writer."""

from __future__ import annotations

import io
import struct
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple

from PIL import Image, ImageCms, ImageOps

from .color import clamp

RGB = Tuple[float, float, float]


def _pixel_data(image: Image.Image):
    getter = getattr(image, "get_flattened_data", None)
    return list(getter()) if getter is not None else list(image.getdata())


def load_image(path: str | Path) -> Image.Image:
    with Image.open(path) as source:
        corrected = ImageOps.exif_transpose(source)
        # Preserve scalar 16-bit/float modes until normalisation; converting
        # them to RGB first would quantise to 8 bits.
        if corrected.mode in {"I;16", "I", "F"}:
            return corrected.copy()
        return corrected.convert("RGB")


def pixels_from_image(image: Image.Image) -> List[List[RGB]]:
    w, h = image.size
    if image.mode == "I;16":
        raw = _pixel_data(image)
        return [[(v/65535.0, v/65535.0, v/65535.0) for v in raw[y*w:(y+1)*w]] for y in range(h)]
    if image.mode == "I":
        raw = _pixel_data(image)
        return [[(max(0, min(65535, v))/65535.0,)*3 for v in raw[y*w:(y+1)*w]] for y in range(h)]
    if image.mode == "F":
        raw = _pixel_data(image)
        return [[(max(0.0, min(1.0, v)),)*3 for v in raw[y*w:(y+1)*w]] for y in range(h)]
    im = image.convert("RGB")
    raw = _pixel_data(im)
    return [[(r/255.0, g/255.0, b/255.0) for r, g, b in raw[y*w:(y+1)*w]] for y in range(h)]


def read_tiff16_pixels(path: str | Path) -> List[List[RGB]] | None:
    """Read uncompressed contiguous 16-bit RGB TIFF samples losslessly.

    This covers FFCS exports and common simple TIFF fixtures.  Pillow remains
    the fallback for tiled, compressed, planar, or non-RGB TIFF variants.
    """

    import struct
    data = Path(path).read_bytes()
    if len(data) < 10 or data[:2] not in {b"II", b"MM"}:
        return None
    endian = "<" if data[:2] == b"II" else ">"
    if struct.unpack_from(endian + "H", data, 2)[0] != 42:
        return None
    ifd = struct.unpack_from(endian + "I", data, 4)[0]
    if ifd + 2 > len(data): return None
    count = struct.unpack_from(endian + "H", data, ifd)[0]
    entries = {}
    sizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1}
    for i in range(count):
        off = ifd + 2 + i*12
        if off + 12 > len(data): return None
        tag, typ, n = struct.unpack_from(endian + "HHI", data, off)
        if typ not in sizes: continue
        total = sizes[typ] * n
        raw = data[off+8:off+12] if total <= 4 else data[struct.unpack_from(endian + "I", data, off+8)[0]:struct.unpack_from(endian + "I", data, off+8)[0] + total]
        if len(raw) < total: return None
        if typ == 3: vals = list(struct.unpack(endian + f"{n}H", raw[:2*n]))
        elif typ == 4: vals = list(struct.unpack(endian + f"{n}I", raw[:4*n]))
        elif typ in {1, 7}: vals = list(raw[:n])
        else: continue
        entries[tag] = vals
    width = (entries.get(256) or [0])[0]; height = (entries.get(257) or [0])[0]
    bits = entries.get(258) or []; strips = entries.get(273) or []; counts = entries.get(279) or []
    if width <= 0 or height <= 0 or bits != [16, 16, 16] or entries.get(259, [1])[0] != 1 or entries.get(277, [3])[0] != 3 or not strips:
        return None
    blob = b"".join(data[o:o+c] for o, c in zip(strips, counts or [len(data)-strips[0]]))
    expected = width * height * 6
    if len(blob) < expected: return None
    values = struct.unpack(endian + f"{width*height*3}H", blob[:expected])
    return [[tuple(values[(y*width+x)*3+c] / 65535.0 for c in range(3)) for x in range(width)] for y in range(height)]


def load_pixels(path: str | Path) -> List[List[RGB]]:
    """Load an image into normalised pixels without avoidable 16-bit loss."""

    path = Path(path)
    if path.suffix.lower() in {".tif", ".tiff"}:
        precise = read_tiff16_pixels(path)
        if precise is not None:
            return precise
    return pixels_from_image(load_image(path))


def image_from_pixels(pixels: Sequence[Sequence[Sequence[float]]], bits: int = 8) -> Image.Image:
    h = len(pixels); w = len(pixels[0]) if h else 0
    if bits <= 8:
        data = bytearray()
        for row in pixels:
            for rgb in row:
                data.extend(int(round(clamp(float(v))*255.0)) for v in rgb[:3])
        return Image.frombytes("RGB", (w, h), bytes(data))
    # Pillow has no packed RGB; keep an 8-bit display image for preview while
    # save_tiff16 writes the source pixels at full precision.
    data = bytearray()
    for row in pixels:
        for rgb in row:
            data.extend(int(round(clamp(float(v))*255.0)) for v in rgb[:3])
    return Image.frombytes("RGB", (w, h), bytes(data))


def _icc_bytes(space: str) -> bytes | None:
    try:
        requested = str(space).lower().replace(" ", "")
        bundled = Path(__file__).with_name("data") / "icc"
        bundled_profile = bundled / ("ISL-ARGB1998.icc" if requested in {"adobergb", "adobe-rgb", "adobergb1998"} else "ISL-sRGB.icc")
        if bundled_profile.exists():
            return bundled_profile.read_bytes()
        candidates = []
        if requested in {"adobergb", "adobe-rgb", "adobergb1998"}:
            candidates = [
                "/System/Library/ColorSync/Profiles/AdobeRGB1998.icc",
                "/Library/ColorSync/Profiles/AdobeRGB1998.icc",
            ]
        else:
            candidates = [
                "/System/Library/ColorSync/Profiles/sRGB Profile.icc",
                "/Library/ColorSync/Profiles/sRGB Profile.icc",
            ]
        for candidate in candidates:
            p = Path(candidate)
            if p.exists():
                return p.read_bytes()
        name = "sRGB" if str(space).lower() in {"srgb", "s-rgb"} else "Adobe RGB (1998)"
        return ImageCms.ImageCmsProfile(ImageCms.createProfile(name)).tobytes()
    except Exception:
        return None


def write_tiff16(path: str | Path, pixels: Sequence[Sequence[Sequence[float]]], colour_space: str = "sRGB") -> None:
    """Write contiguous little-endian RGB 16-bit TIFF (uncompressed)."""

    path = Path(path)
    h = len(pixels); w = len(pixels[0]) if h else 0
    samples = bytearray()
    for row in pixels:
        if len(row) != w:
            raise ValueError("Rows have different widths")
        for rgb in row:
            for v in rgb[:3]:
                samples.extend(struct.pack("<H", int(round(clamp(float(v))*65535.0))))

    # IFD entries are kept sorted by tag.  Extra arrays and ICC data are placed
    # after the directory so all offsets remain stable and easy to inspect.
    # Reserve room for the optional ICC directory entry as well.  Leaving a
    # few bytes of padding before the auxiliary arrays is valid TIFF and keeps
    # offsets independent of the selected profile.
    bits_off = 8 + 2 + 12 * 12 + 4
    sample_format_off = bits_off + 6
    icc = _icc_bytes(colour_space)
    icc_off = sample_format_off + 6
    pixel_off = icc_off + (len(icc) if icc else 0)
    if pixel_off % 2:
        pixel_off += 1
    entries = [
        (256, 4, 1, w), (257, 4, 1, h), (258, 3, 3, bits_off),
        (259, 3, 1, 1), (262, 3, 1, 2), (273, 4, 1, pixel_off),
        (277, 3, 1, 3), (278, 4, 1, h), (279, 4, 1, len(samples)),
        (284, 3, 1, 1), (339, 3, 3, sample_format_off),
    ]
    if icc:
        entries.append((34675, 7, len(icc), icc_off))
    entries.sort(key=lambda x: x[0])
    out = bytearray(b"II" + struct.pack("<H", 42) + struct.pack("<I", 8))
    out.extend(struct.pack("<H", len(entries)))
    for tag, typ, count, value in entries:
        out.extend(struct.pack("<HHI", tag, typ, count))
        if typ == 3 and count == 1:
            out.extend(struct.pack("<H", value)); out.extend(b"\x00\x00")
        else:
            out.extend(struct.pack("<I", value))
    out.extend(struct.pack("<I", 0))
    while len(out) < bits_off: out.append(0)
    out.extend(struct.pack("<HHH", 16, 16, 16))
    out.extend(struct.pack("<HHH", 1, 1, 1))
    if icc:
        out.extend(icc)
    while len(out) < pixel_off: out.append(0)
    out.extend(samples)
    path.write_bytes(bytes(out))


def save_image(path: str | Path, image: Image.Image, pixels: Sequence[Sequence[Sequence[float]]] | None = None, bits: int = 16, colour_space: str = "sRGB", quality: int = 95) -> None:
    path = Path(path)
    suffix = path.suffix.lower()
    if suffix in {".tif", ".tiff"} and bits > 8 and pixels is not None:
        write_tiff16(path, pixels, colour_space)
        return
    icc = _icc_bytes(colour_space)
    if suffix in {".jpg", ".jpeg"}:
        image.convert("RGB").save(path, format="JPEG", quality=quality, icc_profile=icc)
    elif suffix in {".tif", ".tiff"}:
        image.convert("RGB").save(path, format="TIFF", compression="tiff_lzw", icc_profile=icc)
    elif suffix == ".png":
        image.convert("RGB").save(path, format="PNG", icc_profile=icc)
    else:
        image.convert("RGB").save(path, quality=quality, icc_profile=icc)
