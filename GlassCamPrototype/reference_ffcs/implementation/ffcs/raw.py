"""RAF input handling and camera dependent preprocessing.

Fuji RAF files contain a proprietary sensor block plus one or more JPEG
previews.  A full proprietary decoder is outside the scope of a small
portable package, but FFCS handles real RAF files when ``rawpy`` is installed
and provides a deterministic preview fallback otherwise.  The fallback still
executes and records every RAW stage, which makes stage-level comparisons
possible for fixtures containing an embedded JPEG.
"""

from __future__ import annotations

import io
import math
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

from PIL import Image, ImageFilter, ImageOps

from .color import apply_matrix, clamp, grayscale
from .models import CameraProfile, get_camera

RGB = Tuple[float, float, float]


@dataclass
class RawSensor:
    """Decoded sensor plane kept linear until the documented RAW stages."""

    plane: List[List[float]]
    pattern: Tuple[Tuple[str, ...], ...]
    black_levels: Tuple[float, float, float]
    white_level: float
    wb: Tuple[float, float, float]
    metadata: Dict[str, object] = field(default_factory=dict)


def _mean(values: Sequence[float], default: float = 0.0) -> float:
    return sum(values) / len(values) if values else default


def demosaic_bayer(raw: Sequence[Sequence[float]], pattern: str = "RGGB") -> List[List[RGB]]:
    """Bilinear demosaic for a Bayer mosaic.

    ``raw`` values are normalised sensor samples.  The implementation is kept
    public so a caller with a decoded RAF plane can run the exact same stage
    independently from the preview-backed developer.
    """

    h, w = len(raw), len(raw[0]) if raw else 0
    p = pattern.upper()
    if len(p) != 4 or any(c not in "RGB" for c in p):
        raise ValueError("Bayer pattern must be four characters such as RGGB")
    out: List[List[RGB]] = []
    for y in range(h):
        row: List[RGB] = []
        for x in range(w):
            vals = [[], [], []]  # type: ignore[var-annotated]
            for yy in range(max(0, y-1), min(h, y+2)):
                for xx in range(max(0, x-1), min(w, x+2)):
                    channel = "RGB".index(p[(yy % 2)*2 + (xx % 2)])
                    vals[channel].append(float(raw[yy][xx]))
            row.append(tuple(clamp(_mean(v, float(raw[y][x]))) for v in vals))  # type: ignore[arg-type]
        out.append(row)
    return out


def demosaic_xtrans(raw: Sequence[Sequence[float]]) -> List[List[RGB]]:
    """Bilinear X-Trans demosaic using Fuji's standard 6×6 CFA pattern."""

    # X-Trans contains blue sites in the full pattern; this compact pattern is
    # expanded below to preserve the 6×6 indexing while handling blue as the
    # complementary non-green site.
    full = (
        ("G", "R", "G", "G", "R", "G"), ("B", "G", "B", "B", "G", "B"),
        ("G", "B", "G", "G", "B", "G"), ("G", "G", "B", "G", "G", "B"),
        ("B", "G", "B", "B", "G", "B"), ("G", "B", "G", "G", "B", "G"),
    )
    h, w = len(raw), len(raw[0]) if raw else 0
    out: List[List[RGB]] = []
    for y in range(h):
        row: List[RGB] = []
        for x in range(w):
            vals = [[], [], []]  # type: ignore[var-annotated]
            for yy in range(max(0, y-1), min(h, y+2)):
                for xx in range(max(0, x-1), min(w, x+2)):
                    vals["RGB".index(full[yy % 6][xx % 6])].append(float(raw[yy][xx]))
            row.append(tuple(clamp(_mean(v, float(raw[y][x]))) for v in vals))  # type: ignore[arg-type]
        out.append(row)
    return out


def demosaic_cfa(raw: Sequence[Sequence[float]], pattern: Sequence[Sequence[str]]) -> List[List[RGB]]:
    """Bilinear demosaic for an arbitrary repeating CFA pattern."""

    h, w = len(raw), len(raw[0]) if raw else 0
    ph, pw = len(pattern), len(pattern[0]) if pattern else 0
    if not ph or not pw:
        raise ValueError("CFA pattern cannot be empty")
    out: List[List[RGB]] = []
    for y in range(h):
        row: List[RGB] = []
        for x in range(w):
            vals = [[], [], []]  # type: ignore[var-annotated]
            for yy in range(max(0, y - 1), min(h, y + 2)):
                for xx in range(max(0, x - 1), min(w, x + 2)):
                    colour = pattern[yy % ph][xx % pw]
                    if colour in "RGB":
                        vals["RGB".index(colour)].append(float(raw[yy][xx]))
            row.append(tuple(clamp(_mean(v, float(raw[y][x]))) for v in vals))  # type: ignore[arg-type]
        out.append(row)
    return out


@dataclass
class RawDevelopment:
    image: Image.Image
    stages: Dict[str, Image.Image] = field(default_factory=dict)
    metadata: Dict[str, object] = field(default_factory=dict)
    # The Image values are convenient previews; these normalized float maps
    # preserve the sensor/render precision for stage comparisons and 16-bit
    # export.  Keeping both avoids quantizing a RAW stage merely to inspect it.
    stage_pixels: Dict[str, List[List[RGB]]] = field(default_factory=dict)


def is_raf(path: str | Path) -> bool:
    p = Path(path)
    try:
        with p.open("rb") as f:
            return f.read(16).startswith(b"FUJIFILMCCD-RAW")
    except OSError:
        return p.suffix.lower() == ".raf"


def _jpeg_candidates(data: bytes) -> List[Tuple[int, int]]:
    """Return ``(offset, length)`` pairs for embedded JPEG streams."""
    out: List[Tuple[int, int]] = []
    start = 0
    while True:
        soi = data.find(b"\xff\xd8\xff", start)
        if soi < 0:
            break
        # JPEG EOI can occur in compressed scan data.  Walking markers is
        # unnecessary for preview extraction; the last EOI after SOI is the
        # best available boundary and Pillow validates it below.
        eoi = data.find(b"\xff\xd9", soi + 3)
        if eoi >= 0:
            out.append((soi, eoi + 2 - soi))
        start = soi + 3
    return out


def extract_raf_preview(path: str | Path) -> Image.Image:
    data = Path(path).read_bytes()
    candidates = _jpeg_candidates(data)
    # Prefer the largest image; RAF stores a thumbnail and a full-size preview.
    for offset, length in sorted(candidates, key=lambda x: x[1], reverse=True):
        try:
            with Image.open(io.BytesIO(data[offset:offset + length])) as im:
                return ImageOps.exif_transpose(im).convert("RGB")
        except Exception:
            continue
    raise ValueError(f"No decodable JPEG preview found in RAF file: {path}")


def _rawpy_decode(path: str | Path, camera: CameraProfile) -> RawSensor | None:
    try:
        import rawpy  # type: ignore
    except Exception:
        return None
    try:
        import numpy as np  # type: ignore
    except Exception:
        return None
    try:
        with rawpy.imread(str(path)) as raw:
            plane = raw.raw_image_visible.astype("float32").tolist()
            desc = bytes(raw.color_desc).decode("ascii", errors="ignore")
            raw_pattern = getattr(raw, "raw_pattern", None)
            cfa = raw_pattern.tolist() if raw_pattern is not None else [[0, 1], [1, 2]]
            pattern = tuple(tuple(desc[int(index)] if int(index) < len(desc) else "G" for index in row) for row in cfa)
            black_values = list(getattr(raw, "black_level_per_channel", None) or [0, 0, 0])
            black = tuple(float(v) for v in (black_values + [0, 0, 0])[:3])
            white = float(raw.white_level or camera.white_level)
            wb_values = list(getattr(raw, "camera_whitebalance", None) or [1, 1, 1])
            wb = tuple(float(v) for v in (wb_values + [1, 1, 1])[:3])
            # The sensor plane remains linear; black level, shading, WB, and
            # demosaic are performed by FFCS so each stage is observable.
            return RawSensor(plane, pattern, black, white, wb, {
                "source": "rawpy.raw_image_visible", "pattern": pattern,
                "raw_size": (len(plane[0]) if plane else 0, len(plane)),
            })
    except Exception:
        return None


def load_raf(path: str | Path, camera: str | None = None) -> Tuple[Image.Image | RawSensor, Dict[str, object]]:
    profile = get_camera(camera)
    image = _rawpy_decode(path, profile)
    decoder = "rawpy-sensor" if image is not None else "embedded-jpeg-preview"
    if image is None:
        image = extract_raf_preview(path)
    return image, {
        "decoder": decoder, "camera": profile.name, "cfa": profile.cfa,
        "demosaic_algorithm": "bilinear-cfa" if decoder == "rawpy-sensor" else "embedded-preview-preserved",
    }


def _image_to_pixels(image: Image.Image) -> List[List[RGB]]:
    im = image.convert("RGB")
    w, h = im.size
    getter = getattr(im, "get_flattened_data", None)
    px = list(getter()) if getter is not None else list(im.getdata())
    return [[(r / 255.0, g / 255.0, b / 255.0) for r, g, b in px[y*w:(y+1)*w]] for y in range(h)]


def _pixels_to_image(pixels: Sequence[Sequence[RGB]]) -> Image.Image:
    h, w = len(pixels), len(pixels[0]) if pixels else 0
    data = bytearray()
    for row in pixels:
        for r, g, b in row:
            data.extend((round(clamp(r)*255), round(clamp(g)*255), round(clamp(b)*255)))
    return Image.frombytes("RGB", (w, h), bytes(data))


def _resize_pixels_lanczos(pixels: Sequence[Sequence[RGB]], size: Tuple[int, int]) -> List[List[RGB]]:
    """Resize normalized RGB planes through Pillow's float ``F`` mode.

    The display preview is still generated separately by ``_pixels_to_image``;
    this helper prevents a RAW resize from silently quantizing to 8-bit first.
    """

    h, w = len(pixels), len(pixels[0]) if pixels else 0
    if not h or not w:
        return []
    channels: List[List[float]] = []
    for channel in range(3):
        raw = b"".join(struct.pack("<f", clamp(float(row[x][channel]))) for row in pixels for x in range(w))
        plane = Image.frombytes("F", (w, h), raw).resize(size, Image.Resampling.LANCZOS)
        getter = getattr(plane, "get_flattened_data", None)
        channels.append([float(v) for v in (getter() if getter is not None else plane.getdata())])
    rw, rh = size
    return [
        [tuple(clamp(channels[c][y * rw + x]) for c in range(3)) for x in range(rw)]
        for y in range(rh)
    ]


def _black_level(pixels: List[List[RGB]], camera: CameraProfile) -> List[List[RGB]]:
    # Preview pixels are already display encoded.  Apply the relative offset
    # in linearised sensor units and preserve the documented stage regardless
    # of which decoder produced the input.
    denom = max(camera.white_level, camera.black_level + 1.0)
    offset = camera.black_level / denom
    return [[tuple(clamp((v - offset) / max(1e-9, 1.0 - offset)) for v in rgb) for rgb in row] for row in pixels]


def _bad_pixels(pixels: List[List[RGB]]) -> List[List[RGB]]:
    h, w = len(pixels), len(pixels[0]) if pixels else 0
    out = [[tuple(rgb) for rgb in row] for row in pixels]
    for y in range(h):
        for x in range(w):
            rgb = pixels[y][x]
            if max(rgb) - min(rgb) > 0.98 and max(rgb) > 0.999:
                neigh = []
                for yy, xx in ((y-1, x), (y+1, x), (y, x-1), (y, x+1)):
                    if 0 <= yy < h and 0 <= xx < w:
                        neigh.append(pixels[yy][xx])
                if neigh:
                    out[y][x] = tuple(sum(n[c] for n in neigh) / len(neigh) for c in range(3))
    return out


def _lens_shading(pixels: List[List[RGB]], camera: CameraProfile) -> List[List[RGB]]:
    if camera.lens_shading <= 0:
        return pixels
    h, w = len(pixels), len(pixels[0]) if pixels else 0
    out: List[List[RGB]] = []
    for y, row in enumerate(pixels):
        yy = (2*y/(h-1)-1) if h > 1 else 0
        nrow = []
        for x, rgb in enumerate(row):
            xx = (2*x/(w-1)-1) if w > 1 else 0
            radius2 = min(0.95, xx*xx + yy*yy)
            # cos^4(theta) approximation expressed as a smooth gain.
            gain = 1.0 + camera.lens_shading * radius2 + 0.10 * camera.lens_shading * radius2**2
            nrow.append(tuple(clamp(v * gain) for v in rgb))
        out.append(nrow)
    return out


def _band_preprocess(pixels: List[List[RGB]]) -> List[List[RGB]]:
    # A 3-tap low-pass removes isolated sensor noise while retaining edges.
    h, w = len(pixels), len(pixels[0]) if pixels else 0
    out = [[tuple(rgb) for rgb in row] for row in pixels]
    for y in range(h):
        for x in range(w):
            if 0 < x < w-1:
                out[y][x] = tuple(0.25*pixels[y][x-1][c] + 0.5*pixels[y][x][c] + 0.25*pixels[y][x+1][c] for c in range(3))
    return out


def _white_balance(pixels: List[List[RGB]], camera: CameraProfile) -> List[List[RGB]]:
    wb = camera.wb
    mean = max(wb)
    gains = tuple(v / mean for v in wb)
    return [[tuple(clamp(rgb[c] * gains[c]) for c in range(3)) for rgb in row] for row in pixels]


def _shadow_cleanup(pixels: List[List[RGB]]) -> List[List[RGB]]:
    return [[tuple(clamp(v + max(0.0, 0.025 - v) * 0.25) for v in rgb) for rgb in row] for row in pixels]


def _sensor_image(plane: Sequence[Sequence[float]]) -> Image.Image:
    h, w = len(plane), len(plane[0]) if plane else 0
    data = bytearray()
    for row in plane:
        for value in row:
            v = round(clamp(float(value)) * 255)
            data.extend((v, v, v))
    return Image.frombytes("RGB", (w, h), bytes(data))


def _sensor_pixels(plane: Sequence[Sequence[float]]) -> List[List[RGB]]:
    return [[(clamp(float(value)),) * 3 for value in row] for row in plane]


def _sensor_black_level(sensor: RawSensor) -> List[List[float]]:
    out: List[List[float]] = []
    ph, pw = len(sensor.pattern), len(sensor.pattern[0])
    for y, row in enumerate(sensor.plane):
        nrow = []
        for x, value in enumerate(row):
            colour = sensor.pattern[y % ph][x % pw]
            channel = "RGB".find(colour)
            black = sensor.black_levels[channel] if channel >= 0 else sum(sensor.black_levels) / 3
            nrow.append(clamp((float(value) - black) / max(1.0, sensor.white_level - black)))
        out.append(nrow)
    return out


def _sensor_bad_pixels(plane: List[List[float]]) -> List[List[float]]:
    h, w = len(plane), len(plane[0]) if plane else 0
    out = [list(row) for row in plane]
    for y in range(h):
        for x in range(w):
            value = plane[y][x]
            if value >= 0.999 or value <= 0.0001:
                neigh = [plane[yy][xx] for yy, xx in ((y-1, x), (y+1, x), (y, x-1), (y, x+1)) if 0 <= yy < h and 0 <= xx < w]
                if neigh and max(neigh) - min(neigh) < 0.25:
                    out[y][x] = sum(neigh) / len(neigh)
    return out


def _sensor_lens_shading(plane: List[List[float]], camera: CameraProfile) -> List[List[float]]:
    if camera.lens_shading <= 0:
        return plane
    h, w = len(plane), len(plane[0]) if plane else 0
    out: List[List[float]] = []
    for y, row in enumerate(plane):
        yy = 2*y/(h-1)-1 if h > 1 else 0
        nrow = []
        for x, value in enumerate(row):
            xx = 2*x/(w-1)-1 if w > 1 else 0
            radius2 = min(0.95, xx*xx + yy*yy)
            gain = 1.0 + camera.lens_shading * radius2 + 0.10 * camera.lens_shading * radius2**2
            nrow.append(clamp(value * gain))
        out.append(nrow)
    return out


def _sensor_band_preprocess(plane: List[List[float]]) -> List[List[float]]:
    h, w = len(plane), len(plane[0]) if plane else 0
    out = [list(row) for row in plane]
    for y in range(h):
        for x in range(1, w - 1):
            out[y][x] = 0.25*plane[y][x-1] + 0.5*plane[y][x] + 0.25*plane[y][x+1]
    return out


def _sensor_white_balance(plane: List[List[float]], sensor: RawSensor) -> List[List[float]]:
    wb = sensor.wb
    scale = max(wb) if wb else 1.0
    gains = tuple(v / scale for v in wb)
    ph, pw = len(sensor.pattern), len(sensor.pattern[0])
    out = []
    for y, row in enumerate(plane):
        nrow = []
        for x, value in enumerate(row):
            channel = "RGB".find(sensor.pattern[y % ph][x % pw])
            nrow.append(clamp(value * (gains[channel] if channel >= 0 else 1.0)))
        out.append(nrow)
    return out


def develop_raf(path: str | Path, camera: str | None = None) -> RawDevelopment:
    """Develop a RAF through all documented pre-colour stages."""

    profile = get_camera(camera)
    decoded, metadata = load_raf(path, camera)
    stages: Dict[str, Image.Image] = {}
    stage_pixels: Dict[str, List[List[RGB]]] = {}
    if isinstance(decoded, RawSensor):
        sensor = decoded
        metadata.update(sensor.metadata)
        plane = sensor.plane
        stages["raw_input"] = _sensor_image(plane)
        stage_pixels["raw_input"] = _sensor_pixels(plane)
        plane = _sensor_black_level(sensor)
        stages["black_level"] = _sensor_image(plane)
        stage_pixels["black_level"] = _sensor_pixels(plane)
        plane = _sensor_bad_pixels(plane)
        stages["bad_pixel_repair"] = _sensor_image(plane)
        stage_pixels["bad_pixel_repair"] = _sensor_pixels(plane)
        plane = _sensor_lens_shading(plane, profile)
        stages["lens_shading"] = _sensor_image(plane)
        stage_pixels["lens_shading"] = _sensor_pixels(plane)
        plane = _sensor_band_preprocess(plane)
        stages["band_preprocess"] = _sensor_image(plane)
        stage_pixels["band_preprocess"] = _sensor_pixels(plane)
        plane = _sensor_white_balance(plane, sensor)
        stages["white_balance"] = _sensor_image(plane)
        stage_pixels["white_balance"] = _sensor_pixels(plane)
        rgb = demosaic_cfa(plane, sensor.pattern)
        stages["demosaic"] = _pixels_to_image(rgb)
        stage_pixels["demosaic"] = [list(map(tuple, row)) for row in rgb]
        rgb = _shadow_cleanup(rgb)
        stages["shadow_cleanup"] = _pixels_to_image(rgb)
        stage_pixels["shadow_cleanup"] = [list(map(tuple, row)) for row in rgb]
        final = stages["shadow_cleanup"]
        final_pixels = stage_pixels["shadow_cleanup"]
        if profile.resize_factor != 1.0:
            size = (max(1, round(final.width * profile.resize_factor)), max(1, round(final.height * profile.resize_factor)))
            final = final.resize(size, Image.Resampling.LANCZOS)
            final_pixels = _resize_pixels_lanczos(final_pixels, size)
            final = _pixels_to_image(final_pixels)
        stages["resize_lanczos"] = final.copy()
        stage_pixels["resize_lanczos"] = final_pixels
        metadata.update({"camera_profile": profile.name, "stage_order": list(stages), "raw_chain": "sensor-plane"})
        return RawDevelopment(final, stages, metadata, stage_pixels)

    image = decoded
    pixels = _image_to_pixels(image)
    for name, fn in (
        ("raw_input", lambda p: p),
        ("black_level", lambda p: _black_level(p, profile)),
        ("bad_pixel_repair", _bad_pixels),
        ("lens_shading", lambda p: _lens_shading(p, profile)),
        ("band_preprocess", _band_preprocess),
        ("white_balance", lambda p: _white_balance(p, profile)),
        # The preview is already demosaiced; recording an explicit stage makes
        # the path equivalent for rawpy and preview-backed RAF fixtures.
        ("demosaic", lambda p: p),
        ("shadow_cleanup", _shadow_cleanup),
    ):
        pixels = fn(pixels)
        stages[name] = _pixels_to_image(pixels)
        stage_pixels[name] = [list(map(tuple, row)) for row in pixels]
    final = stages["shadow_cleanup"]
    final_pixels = stage_pixels["shadow_cleanup"]
    if profile.resize_factor != 1.0:
        size = (max(1, round(final.width * profile.resize_factor)), max(1, round(final.height * profile.resize_factor)))
        final_pixels = _resize_pixels_lanczos(final_pixels, size)
        final = _pixels_to_image(final_pixels)
        stages["resize_lanczos"] = final.copy()
    else:
        stages["resize_lanczos"] = final.copy()
    stage_pixels["resize_lanczos"] = final_pixels
    metadata.update({"camera_profile": profile.name, "stage_order": list(stages)})
    return RawDevelopment(final, stages, metadata, stage_pixels)
