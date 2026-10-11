"""Colour science primitives used by the FFCS renderer.

All functions operate on Python sequences so FFCS works in a minimal Python
installation.  If a caller has NumPy it can still use the same API by
converting arrays to nested sequences at the pipeline boundary.
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple

from .models import FilmSimulation, RGBMatrix

RGB = Tuple[float, float, float]


def clamp(x: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return lo if x < lo else hi if x > hi else x


def clamp_rgb(rgb: Sequence[float]) -> RGB:
    return (clamp(float(rgb[0])), clamp(float(rgb[1])), clamp(float(rgb[2])))


def load_cube_lut(path: str | Path) -> Tuple[int, list[tuple[float, float, float]]]:
    """Read a standard ``.cube`` 3D LUT.

    The returned flat list is ordered ``z, y, x`` (blue, green, red), matching
    :func:`_trilinear`.  Values are clamped to the display domain and comments
    or one-dimensional shaper records are ignored.
    """

    size = None
    rows: list[tuple[float, float, float]] = []
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        key = fields[0].upper()
        if key == "LUT_3D_SIZE" and len(fields) >= 2:
            size = int(fields[1])
            continue
        if key in {"TITLE", "DOMAIN_MIN", "DOMAIN_MAX", "LUT_1D_SIZE"}:
            continue
        if len(fields) >= 3:
            try:
                rows.append((clamp(float(fields[0])), clamp(float(fields[1])), clamp(float(fields[2]))))
            except ValueError:
                continue
    if size is None or size < 2:
        raise ValueError(f"{path}: missing valid LUT_3D_SIZE")
    expected = size ** 3
    if len(rows) != expected:
        raise ValueError(f"{path}: expected {expected} RGB entries, found {len(rows)}")
    return size, rows


def srgb_decode(x: float) -> float:
    x = clamp(x)
    return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4


def srgb_encode(x: float) -> float:
    x = clamp(x)
    return 12.92 * x if x <= 0.0031308 else 1.055 * (x ** (1.0 / 2.4)) - 0.055


_M_XYZ_ADOBE = ((2.0413690, -0.5649464, -0.3446944), (-0.9692660, 1.8760108, 0.0415560), (0.0134474, -0.1183897, 1.0154096))
_M_RGB_XYZ_ADOBE = ((0.5766690, 0.1855580, 0.1882290), (0.2973450, 0.6273640, 0.0752910), (0.0270310, 0.0706890, 0.9913380))


def srgb_to_adobe_rgb(rgb: Sequence[float]) -> RGB:
    """Convert display-coded sRGB values to Adobe RGB (1998) encoding."""

    linear_srgb = tuple(srgb_decode(clamp(v)) for v in rgb)
    xyz = _mul3(linear_srgb, _M_RGB_XYZ)
    adobe_linear = _mul3(xyz, _M_XYZ_ADOBE)
    return clamp_rgb(tuple(max(0.0, v) ** (1.0 / 2.19921875) for v in adobe_linear))


def adobe_rgb_to_srgb(rgb: Sequence[float]) -> RGB:
    """Convert Adobe RGB (1998) encoding to display-coded sRGB values."""

    adobe_linear = tuple(clamp(v) ** 2.19921875 for v in rgb)
    xyz = _mul3(adobe_linear, _M_RGB_XYZ_ADOBE)
    return clamp_rgb(tuple(srgb_encode(v) for v in _mul3(xyz, _M_XYZ_RGB)))


def apply_matrix(rgb: Sequence[float], matrix: RGBMatrix) -> RGB:
    return clamp_rgb((
        matrix[0][0] * rgb[0] + matrix[0][1] * rgb[1] + matrix[0][2] * rgb[2],
        matrix[1][0] * rgb[0] + matrix[1][1] * rgb[1] + matrix[1][2] * rgb[2],
        matrix[2][0] * rgb[0] + matrix[2][1] * rgb[1] + matrix[2][2] * rgb[2],
    ))


def _trilinear(lut: object, size: int, rgb: Sequence[float]) -> RGB:
    """Trilinear interpolation for ``lut[z][y][x]`` data."""

    x, y, z = (clamp(float(v)) * (size - 1) for v in rgb)
    x0, y0, z0 = int(math.floor(x)), int(math.floor(y)), int(math.floor(z))
    x1, y1, z1 = min(x0 + 1, size - 1), min(y0 + 1, size - 1), min(z0 + 1, size - 1)
    fx, fy, fz = x - x0, y - y0, z - z0
    # Accept either list-like LUTs or flat size^3 arrays.
    def at(ix: int, iy: int, iz: int) -> Sequence[float]:
        try:
            return lut[iz][iy][ix]  # type: ignore[index]
        except (TypeError, IndexError):
            return lut[(iz * size * size) + (iy * size) + ix]  # type: ignore[index]
    out = []
    for c in range(3):
        c000 = float(at(x0, y0, z0)[c]); c100 = float(at(x1, y0, z0)[c])
        c010 = float(at(x0, y1, z0)[c]); c110 = float(at(x1, y1, z0)[c])
        c001 = float(at(x0, y0, z1)[c]); c101 = float(at(x1, y0, z1)[c])
        c011 = float(at(x0, y1, z1)[c]); c111 = float(at(x1, y1, z1)[c])
        a = c000 * (1-fx) + c100 * fx
        b = c010 * (1-fx) + c110 * fx
        c0 = a * (1-fy) + b * fy
        a = c001 * (1-fx) + c101 * fx
        b = c011 * (1-fx) + c111 * fx
        c1 = a * (1-fy) + b * fy
        out.append(clamp(c0 * (1-fz) + c1 * fz))
    return tuple(out)  # type: ignore[return-value]


def _rgb_to_hsv(rgb: Sequence[float]) -> Tuple[float, float, float]:
    r, g, b = rgb
    hi, lo = max(rgb), min(rgb)
    d = hi - lo
    if d == 0:
        h = 0.0
    elif hi == r:
        h = ((g - b) / d) % 6.0
    elif hi == g:
        h = (b - r) / d + 2.0
    else:
        h = (r - g) / d + 4.0
    return h / 6.0, 0.0 if hi == 0 else d / hi, hi


def _hsv_to_rgb(h: float, s: float, v: float) -> RGB:
    h = (h % 1.0) * 6.0
    i, f = int(h), h - int(h)
    p, q, t = v * (1-s), v * (1-s*f), v * (1-s*(1-f))
    return ((v, t, p), (q, v, p), (p, v, t), (p, q, v), (p, p, v), (v, p, q))[i % 6]


def _analytic_lut(rgb: Sequence[float], spec: FilmSimulation) -> RGB:
    """Deterministic analytic fallback for a missing measured camera LUT."""

    r, g, b = clamp_rgb(rgb)
    # Contrast pivot in linear working space.  A small toe lift preserves
    # texture in shadows while the shoulder limits highlight clipping.
    pivot = 0.5
    c = ((r - pivot) * spec.contrast + pivot, (g - pivot) * spec.contrast + pivot, (b - pivot) * spec.contrast + pivot)
    c = tuple(clamp(v + spec.shadow_lift * (1.0 - v) - spec.highlight_rolloff * max(0.0, v - 0.72) ** 2) for v in c)
    h, s, v = _rgb_to_hsv(c)
    c = _hsv_to_rgb(h + spec.hue_shift, clamp(s * spec.saturation), v)
    return clamp_rgb(c)


def apply_3d_lut(rgb: Sequence[float], spec: FilmSimulation) -> RGB:
    lut_input = rgb
    if spec.lut is not None and getattr(spec.lut, "axis_order", "RGB") == "BGR":
        lut_input = (rgb[2], rgb[1], rgb[0])
    if spec.lut is not None:
        mapped = _trilinear(spec.lut, spec.lut_size, lut_input)
        if getattr(spec.lut, "channel_order", "RGB") == "BGR":
            mapped = (mapped[2], mapped[1], mapped[0])
    else:
        mapped = _analytic_lut(rgb, spec)
    # Sigma controls the smoothness of the LUT's transition around the neutral
    # axis.  sigma=1 is identity; values are bounded to avoid unstable gains.
    sigma = max(0.05, min(8.0, float(spec.sigma)))
    if abs(sigma - 1.0) > 1e-7:
        mapped = tuple(clamp(0.5 + math.tanh((v - 0.5) * sigma) / (2.0 * math.tanh(0.5 * sigma))) for v in mapped)
    return clamp_rgb(mapped)


# D65 matrices and reference white, IEC 61966-2-1 / CIE 15 conventions.
_M_RGB_XYZ = ((0.4124564, 0.3575761, 0.1804375), (0.2126729, 0.7151522, 0.0721750), (0.0193339, 0.1191920, 0.9503041))
_M_XYZ_RGB = ((3.2404542, -1.5371385, -0.4985314), (-0.9692660, 1.8760108, 0.0415560), (0.0556434, -0.2040259, 1.0572252))
_WHITE = (0.95047, 1.0, 1.08883)


def _mul3(v: Sequence[float], m: Sequence[Sequence[float]]) -> RGB:
    return tuple(sum(m[i][j] * v[j] for j in range(3)) for i in range(3))  # type: ignore[return-value]


def _f_lab(t: float) -> float:
    d = 6.0 / 29.0
    return t ** (1/3) if t > d ** 3 else t / (3*d*d) + 4/29


def _finv_lab(t: float) -> float:
    d = 6.0 / 29.0
    return t ** 3 if t > d else 3*d*d*(t - 4/29)


def rgb_to_lab(rgb: Sequence[float]) -> Tuple[float, float, float]:
    xyz = _mul3(tuple(srgb_decode(clamp(v)) for v in rgb), _M_RGB_XYZ)
    x, y, z = (_f_lab(xyz[i] / _WHITE[i]) for i in range(3))
    return (116*y - 16, 500*(x-y), 200*(y-z))


def lab_to_rgb(lab: Sequence[float]) -> RGB:
    l, a, b = lab
    fy, fx, fz = (l + 16) / 116, (l + 16) / 116 + a / 500, (l + 16) / 116 - b / 200
    xyz = (_finv_lab(fx) * _WHITE[0], _finv_lab(fy) * _WHITE[1], _finv_lab(fz) * _WHITE[2])
    linear = _mul3(xyz, _M_XYZ_RGB)
    return clamp_rgb(tuple(srgb_encode(v) for v in linear))


def adjust_lab(rgb: Sequence[float], contrast: float = 1.0, saturation: float = 1.0, hue_shift: float = 0.0, lightness: float = 0.0) -> RGB:
    """Apply a perceptual adjustment in CIELAB/UCS-like coordinates."""

    l, a, b = rgb_to_lab(rgb)
    c = math.hypot(a, b) * saturation
    h = math.atan2(b, a) + hue_shift * 2 * math.pi
    l = 50.0 + (l - 50.0) * contrast + lightness
    return lab_to_rgb((clamp(l, 0.0, 100.0), c * math.cos(h), c * math.sin(h)))


def rgb_to_ucs(rgb: Sequence[float]) -> Tuple[float, float, float]:
    """Convert sRGB to the compact OKLab uniform colour space.

    OKLab is a practical UCS for a dependency-free renderer: its LMS cube-root
    construction is smooth, invertible, and behaves well around neutrals.
    """

    r, g, b = (srgb_decode(clamp(v)) for v in rgb)
    l = 0.4122214708*r + 0.5363325363*g + 0.0514459929*b
    m = 0.2119034982*r + 0.6806995451*g + 0.1073969566*b
    s = 0.0883024619*r + 0.2817188376*g + 0.6299787005*b
    l, m, s = math.copysign(abs(l) ** (1/3), l), math.copysign(abs(m) ** (1/3), m), math.copysign(abs(s) ** (1/3), s)
    return (0.2104542553*l + 0.7936177850*m - 0.0040720468*s,
            1.9779984951*l - 2.4285922050*m + 0.4505937099*s,
            0.0259040371*l + 0.7827717662*m - 0.8086757660*s)


def ucs_to_rgb(ucs: Sequence[float]) -> RGB:
    l0 = ucs[0] + 0.3963377774*ucs[1] + 0.2158037573*ucs[2]
    m0 = ucs[0] - 0.1055613458*ucs[1] - 0.0638541728*ucs[2]
    s0 = ucs[0] - 0.0894841775*ucs[1] - 1.2914855480*ucs[2]
    l, m, s = l0**3, m0**3, s0**3
    linear = (4.0767416621*l - 3.3077115913*m + 0.2309699292*s,
              -1.2684380046*l + 2.6097574011*m - 0.3413193965*s,
              -0.0041960863*l - 0.7034186147*m + 1.7076147010*s)
    return clamp_rgb(tuple(srgb_encode(v) for v in linear))


def adjust_ucs(rgb: Sequence[float], contrast: float = 1.0, saturation: float = 1.0, hue_shift: float = 0.0) -> RGB:
    l, a, b = rgb_to_ucs(rgb)
    c = math.hypot(a, b) * saturation
    h = math.atan2(b, a) + hue_shift * 2 * math.pi
    return ucs_to_rgb((0.5 + (l - 0.5) * contrast, c * math.cos(h), c * math.sin(h)))


def tone_curve(rgb: Sequence[float], contrast: float = 1.0, shoulder: float = 0.0, toe: float = 0.0) -> RGB:
    """Apply a smooth toe/shoulder curve with continuous first derivative."""

    def one(x: float) -> float:
        x = clamp(x)
        # Contrast is anchored at one: a neutral curve is exactly identity.
        # This avoids introducing an unmeasured S-curve when a reference LUT
        # already contains its tone response.
        y = 0.5 + (x - 0.5) * max(0.05, contrast)
        if toe:
            y = y + toe * (1.0 - y) * (0.18 - 0.18 * y)
        if shoulder:
            y = y - shoulder * y * y * 0.22
        return clamp(y)
    return tuple(one(v) for v in rgb)  # type: ignore[return-value]


def luminance(rgb: Sequence[float]) -> float:
    return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]


def grayscale(rgb: Sequence[float], weights: Sequence[float] = (0.2126, 0.7152, 0.0722)) -> float:
    return clamp(sum(float(a) * float(b) for a, b in zip(rgb, weights)))
