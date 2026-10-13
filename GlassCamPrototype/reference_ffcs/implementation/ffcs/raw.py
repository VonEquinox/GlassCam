"""RAF input handling and camera dependent preprocessing.

Fuji RAF files contain a proprietary sensor block plus one or more JPEG
previews.  A full proprietary decoder is outside the scope of a small
portable package, but FFCS handles real RAF files when ``rawpy`` is installed
and preserves an embedded JPEG preview otherwise.  Preview stage placeholders
are explicitly marked not applicable to sensor processing.
"""

from __future__ import annotations

import io
import math
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

from PIL import Image, ImageOps

from .color import clamp
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
    black_pattern: Tuple[Tuple[float, ...], ...] | None = None
    wb_pattern: Tuple[Tuple[float, ...], ...] | None = None


def _mean(values: Sequence[float], default: float = 0.0) -> float:
    return sum(values) / len(values) if values else default


def demosaic_bayer(raw: Sequence[Sequence[float]], pattern: str = "RGGB") -> List[List[RGB]]:
    """Same-colour inverse-distance interpolation for a Bayer mosaic.

    ``raw`` values are normalised sensor samples.  The implementation is kept
    public so a caller with a decoded RAF plane can run the exact same stage
    independently from the preview-backed developer.
    """

    p = pattern.upper()
    if len(p) != 4 or any(c not in "RGB" for c in p):
        raise ValueError("Bayer pattern must be four characters such as RGGB")
    return demosaic_cfa(raw,((p[0],p[1]),(p[2],p[3])))


def demosaic_xtrans(raw: Sequence[Sequence[float]], pattern=None) -> List[List[RGB]]:
    """Interpolate a 6×6 CFA; pass the actual decoder phase for sensor files."""

    # Balanced example phase: 20 green, 8 red and 8 blue sites. Real sensor
    # files use the decoder's visible CFA phase.
    full = (
        ("G", "R", "G", "G", "B", "G"), ("B", "G", "B", "R", "G", "R"),
        ("G", "R", "G", "G", "B", "G"), ("G", "B", "G", "G", "R", "G"),
        ("R", "G", "R", "B", "G", "B"), ("G", "B", "G", "G", "R", "G"),
    )
    return demosaic_cfa(raw,pattern or full)


def demosaic_cfa(raw: Sequence[Sequence[float]], pattern: Sequence[Sequence[str]]) -> List[List[RGB]]:
    """Preserve measured sites and interpolate missing colours by distance."""

    h, w = len(raw), len(raw[0]) if raw else 0
    ph, pw = len(pattern), len(pattern[0]) if pattern else 0
    if not ph or not pw or any(len(row)!=pw for row in pattern) or any(c not in {"R","G","B"} for row in pattern for c in row):
        raise ValueError("CFA pattern must be a rectangular RGB mosaic")
    if not set("RGB") <= {c for row in pattern for c in row}:
        raise ValueError("CFA pattern must contain R, G and B sites")
    out: List[List[RGB]] = []
    for y in range(h):
        row: List[RGB] = []
        for x in range(w):
            center = pattern[y%ph][x%pw]
            channels = []
            for colour in "RGB":
                if colour==center:
                    channels.append(clamp(float(raw[y][x]))); continue
                neighbours = []
                for radius in range(1,max(ph,pw)+1):
                    neighbours = [(float(raw[yy][xx]),1/((yy-y)**2+(xx-x)**2))
                                  for yy in range(max(0,y-radius),min(h,y+radius+1))
                                  for xx in range(max(0,x-radius),min(w,x+radius+1))
                                  if (yy,xx)!=(y,x) and pattern[yy%ph][xx%pw]==colour]
                    if neighbours: break
                channels.append(clamp(sum(v*weight for v,weight in neighbours)/sum(weight for _,weight in neighbours)) if neighbours else 0.0)
            row.append(tuple(channels))
        out.append(row)
    return out


@dataclass
class RawDevelopment:
    image: Image.Image
    stages: Dict[str, Image.Image] = field(default_factory=dict)
    metadata: Dict[str, object] = field(default_factory=dict)
    # Images are previews. Float maps preserve original raw codes or the
    # declared normalized stage domain without preview quantization.
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
        # Leave the stream boundary to the JPEG decoder.
        eoi = data.find(b"\xff\xd9", soi + 3)
        if eoi >= 0:
            # Pillow walks JPEG segments, including embedded EXIF thumbnails.
            out.append((soi, len(data)-soi))
        start = soi + 3
    return out


def extract_raf_preview(path: str | Path) -> Image.Image:
    data = Path(path).read_bytes()
    candidates = _jpeg_candidates(data)
    # Prefer the largest image; RAF stores a thumbnail and a full-size preview.
    best = None
    for offset, length in candidates:
        try:
            with Image.open(io.BytesIO(data[offset:offset + length])) as im:
                preview = ImageOps.exif_transpose(im).convert("RGB")
                if best is None or preview.width*preview.height>best.width*best.height:
                    best = preview
        except Exception:
            continue
    if best is not None: return best
    raise ValueError(f"No decodable JPEG preview found in RAF file: {path}")


def _rawpy_decode(path: str | Path, camera: CameraProfile, errors=None) -> RawSensor | None:
    try:
        import rawpy  # type: ignore
    except ImportError as exc:
        if errors is not None: errors.append(str(exc))
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
            if raw_pattern is None: raise ValueError("Decoder did not provide a CFA pattern")
            ph,pw = raw_pattern.shape
            visible = getattr(raw,"raw_colors_visible",None)
            cfa = visible[:ph,:pw].tolist() if visible is not None else raw_pattern.tolist()
            pattern = tuple(tuple(desc[int(index)] if int(index) < len(desc) else "G" for index in row) for row in cfa)
            black_values = list(raw.black_level_per_channel)
            black = tuple(_mean([float(black_values[i]) for i,c in enumerate(desc) if c==colour and i<len(black_values)]) for colour in "RGB")
            white = float(raw.white_level or camera.white_level)
            wb_values = list(raw.camera_whitebalance)
            required = {i for row in cfa for i in row}
            wb_source = "camera"
            if any(i>=len(wb_values) or not math.isfinite(wb_values[i]) or wb_values[i]<=0 for i in required):
                wb_values = list(raw.daylight_whitebalance); wb_source = "daylight-fallback"
            if any(i>=len(wb_values) or not math.isfinite(wb_values[i]) or wb_values[i]<=0 for i in required):
                raise ValueError("No valid sensor white balance")
            wb = tuple(_mean([float(wb_values[i]) for i,c in enumerate(desc) if c==colour and i<len(wb_values)],1.0) for colour in "RGB")
            # The sensor plane remains linear; black level, shading, WB, and
            # demosaic are performed by FFCS so each stage is observable.
            return RawSensor(plane, pattern, black, white, wb, {
                "source": "rawpy.raw_image_visible", "pattern": pattern,
                "raw_size": (len(plane[0]) if plane else 0, len(plane)),
                "white_level":white,"cfa_indices":cfa,"wb_source":wb_source,
            },tuple(tuple(float(black_values[i]) for i in row) for row in cfa),
              tuple(tuple(float(wb_values[i]) for i in row) for row in cfa))
    except Exception as exc:
        if errors is not None: errors.append(f"{type(exc).__name__}: {exc}")
        return None


def load_raf(path: str | Path, camera: str | None = None) -> Tuple[Image.Image | RawSensor, Dict[str, object]]:
    profile = get_camera(camera)
    errors = []
    image = _rawpy_decode(path, profile, errors)
    decoder = "rawpy-sensor" if image is not None else "embedded-jpeg-preview"
    if image is None:
        image = extract_raf_preview(path)
    return image, {
        "decoder": decoder, "camera": profile.name, "cfa": profile.cfa,
        "demosaic_algorithm": "same-colour-inverse-distance" if decoder == "rawpy-sensor" else "embedded-preview-preserved",
        "decoder_fallback_reason":errors,
    }




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
    return [[(float(value),) * 3 for value in row] for row in plane]


def _sensor_black_level(sensor: RawSensor) -> List[List[float]]:
    out: List[List[float]] = []
    ph, pw = len(sensor.pattern), len(sensor.pattern[0])
    for y, row in enumerate(sensor.plane):
        nrow = []
        for x, value in enumerate(row):
            colour = sensor.pattern[y % ph][x % pw]
            channel = "RGB".find(colour)
            black = sensor.black_pattern[y%ph][x%pw] if sensor.black_pattern else sensor.black_levels[channel]
            nrow.append(clamp((float(value) - black) / max(1.0, sensor.white_level - black)))
        out.append(nrow)
    return out


def _sensor_bad_pixels(plane: List[List[float]], pattern=(("R","G"),("G","B"))) -> List[List[float]]:
    h, w = len(plane), len(plane[0]) if plane else 0
    out = [list(row) for row in plane]
    ph,pw = len(pattern),len(pattern[0]); radius = max(ph,pw)
    for y in range(h):
        for x in range(w):
            value = plane[y][x]
            if value >= 0.999 or value <= 0.0001:
                neigh = [plane[yy][xx] for yy in range(max(0,y-radius),min(h,y+radius+1))
                         for xx in range(max(0,x-radius),min(w,x+radius+1))
                         if (yy,xx)!=(y,x) and pattern[yy%ph][xx%pw]==pattern[y%ph][x%pw]]
                if len(neigh)>=2 and max(neigh)-min(neigh)<0.25 and abs(value-_mean(neigh))>0.25:
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


def _sensor_band_preprocess(plane: List[List[float]], pattern=(("R","G"),("G","B"))) -> List[List[float]]:
    h, w = len(plane), len(plane[0]) if plane else 0
    out = [list(row) for row in plane]
    for y in range(h):
        for x in range(w):
            ph,pw = len(pattern),len(pattern[0]); colour = pattern[y%ph][x%pw]
            left = next((xx for xx in range(x-1,max(-1,x-pw-1),-1) if pattern[y%ph][xx%pw]==colour),None)
            right = next((xx for xx in range(x+1,min(w,x+pw+1)) if pattern[y%ph][xx%pw]==colour),None)
            if left is not None and right is not None:
                out[y][x] = 0.25*plane[y][left]+0.5*plane[y][x]+0.25*plane[y][right]
    return out


def _sensor_white_balance(plane: List[List[float]], sensor: RawSensor) -> List[List[float]]:
    wb = sensor.wb
    if len(wb)!=3 or any(not math.isfinite(v) or v<=0 for v in wb):
        raise ValueError("Sensor white balance must contain three finite positive gains")
    scale = wb[1]
    gains = tuple(v / scale for v in wb)
    ph, pw = len(sensor.pattern), len(sensor.pattern[0])
    out = []
    for y, row in enumerate(plane):
        nrow = []
        for x, value in enumerate(row):
            channel = "RGB".find(sensor.pattern[y % ph][x % pw])
            gain = sensor.wb_pattern[y%ph][x%pw]/scale if sensor.wb_pattern else gains[channel]
            nrow.append(clamp(value*gain))
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
        if not math.isfinite(sensor.white_level) or sensor.white_level<=0:
            raise ValueError("Sensor white level must be finite and positive")
        metadata.update(sensor.metadata)
        plane = sensor.plane
        stages["raw_input"] = _sensor_image([[v/sensor.white_level for v in row] for row in plane])
        stage_pixels["raw_input"] = _sensor_pixels(plane)
        plane = _sensor_black_level(sensor)
        stages["black_level"] = _sensor_image(plane)
        stage_pixels["black_level"] = _sensor_pixels(plane)
        site_pattern = sensor.metadata.get("cfa_indices",sensor.pattern)
        plane = _sensor_bad_pixels(plane,site_pattern)
        stages["bad_pixel_repair"] = _sensor_image(plane)
        stage_pixels["bad_pixel_repair"] = _sensor_pixels(plane)
        plane = _sensor_lens_shading(plane, profile)
        stages["lens_shading"] = _sensor_image(plane)
        stage_pixels["lens_shading"] = _sensor_pixels(plane)
        plane = _sensor_band_preprocess(plane,site_pattern)
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
        metadata.update({"camera_profile": profile.name, "stage_order": list(stages), "raw_chain": "sensor-plane", "white_level":sensor.white_level,"input_domain":"linear"})
        return RawDevelopment(final, stages, metadata, stage_pixels)

    image = decoded
    # The embedded JPEG has already been black-corrected, balanced and rendered.
    # Preserve its pixels; stage names alone must not imply sensor processing.
    from .io import _manage_pixels, pixels_from_image
    final_pixels = _manage_pixels(pixels_from_image(image),image.info.get("icc_profile"),True)
    names = ("raw_input","black_level","bad_pixel_repair","lens_shading","band_preprocess","white_balance","demosaic","shadow_cleanup","resize_lanczos")
    if profile.resize_factor!=1:
        size = (max(1,round(image.width*profile.resize_factor)),max(1,round(image.height*profile.resize_factor)))
        resized = _resize_pixels_lanczos(final_pixels,size)
    else: resized = final_pixels
    for name in names:
        pixels = resized if name=="resize_lanczos" else final_pixels
        stages[name] = _pixels_to_image(pixels)
        stage_pixels[name] = [list(map(tuple,row)) for row in pixels]
    metadata.update({"camera_profile":profile.name,"stage_order":list(stages),"raw_chain":"embedded-preview-preserved","input_domain":"encoded",
                     "stage_status":{name:"not_applicable" for name in names if name not in {"raw_input","resize_lanczos"}}})
    return RawDevelopment(stages["resize_lanczos"],stages,metadata,stage_pixels)
