"""Film simulation and camera profile data used by the FFCS pipeline.

The profiles are deliberately data driven.  Fujifilm does not publish the
camera JPEG lookup tables, so the built in profiles are deterministic,
documented rendering profiles that can be replaced with measured LUTs through
the public :class:`FilmSimulation` API.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Iterable, Mapping, Tuple


RGBMatrix = Tuple[Tuple[float, float, float], Tuple[float, float, float], Tuple[float, float, float]]


def _matrix(rows: Iterable[Iterable[float]]) -> RGBMatrix:
    return tuple(tuple(float(v) for v in row) for row in rows)  # type: ignore[return-value]


@dataclass(frozen=True)
class FilmSimulation:
    """Parameters for a rendering look.

    ``lut_size`` and ``lut`` are optional.  If ``lut`` is not supplied, the
    pipeline constructs a smooth analytic identity LUT and applies the look's
    gamut and hue controls.  A measured LUT can be supplied as a nested
    ``lut[z][y][x]`` sequence in normalised RGB coordinates.
    """

    name: str
    aliases: Tuple[str, ...] = ()
    contrast: float = 1.0
    saturation: float = 1.0
    hue_shift: float = 0.0
    highlight_rolloff: float = 0.0
    shadow_lift: float = 0.0
    grain_strength: float = 0.0
    grain_size: float = 1.0
    grain_chroma: float = 0.12
    sharpness: float = 0.0
    sigma: float = 1.0
    matrix: RGBMatrix = field(default_factory=lambda: _matrix(((1, 0, 0), (0, 1, 0), (0, 0, 1))))
    lut: object | None = None
    lut_size: int = 17
    acros: bool = False
    sepia: bool = False
    # ``linear`` is the analytic/cube default.  Reference ISLRGB tables are
    # sampled in the display-coded working domain and set this to ``encoded``.
    lut_domain: str = "linear"
    lut_scale: float = 1.0
    lut_source: str | None = None


@dataclass(frozen=True)
class CameraProfile:
    """Camera dependent RAW preprocessing parameters."""

    name: str
    black_level: float = 0.0
    white_level: float = 16383.0
    wb: Tuple[float, float, float] = (1.0, 1.0, 1.0)
    lens_shading: float = 0.0
    cfa: str = "RGGB"
    cfa_period: Tuple[int, int] = (2, 2)
    matrix: RGBMatrix = field(default_factory=lambda: _matrix(((1, 0, 0), (0, 1, 0), (0, 0, 1))))
    resize_factor: float = 1.0


# Camera matrices are colour-preserving starting points.  They are kept in
# this module so users can register measured matrices without changing code.
CAMERA_PROFILES: Dict[str, CameraProfile] = {
    "XH2S": CameraProfile(
        "XH2S", black_level=256, white_level=16383, wb=(2.04, 1.0, 1.49),
        lens_shading=0.16, cfa="XTRANS", cfa_period=(6, 6),
        matrix=_matrix(((1.22, -0.15, -0.07), (-0.06, 1.13, -0.07), (-0.04, -0.14, 1.18))),
    ),
    "X-T5": CameraProfile(
        "X-T5", black_level=256, white_level=16383, wb=(2.0, 1.0, 1.48),
        lens_shading=0.14, cfa="XTRANS", cfa_period=(6, 6),
        matrix=_matrix(((1.20, -0.14, -0.06), (-0.05, 1.12, -0.07), (-0.04, -0.13, 1.17))),
    ),
    "X100V": CameraProfile(
        "X100V", black_level=256, white_level=16383, wb=(1.95, 1.0, 1.52),
        lens_shading=0.12, cfa="XTRANS", cfa_period=(6, 6),
        matrix=_matrix(((1.18, -0.13, -0.05), (-0.05, 1.11, -0.06), (-0.03, -0.12, 1.16))),
    ),
    "GFX100S": CameraProfile(
        "GFX100S", black_level=512, white_level=65535, wb=(1.9, 1.0, 1.45),
        lens_shading=0.10, cfa="RGGB", cfa_period=(2, 2),
        matrix=_matrix(((1.16, -0.11, -0.05), (-0.04, 1.09, -0.05), (-0.03, -0.10, 1.13))),
    ),
    "GFX100": CameraProfile(
        "GFX100", black_level=512, white_level=65535, wb=(1.9, 1.0, 1.45),
        lens_shading=0.10, cfa="RGGB", cfa_period=(2, 2),
        matrix=_matrix(((1.16, -0.11, -0.05), (-0.04, 1.09, -0.05), (-0.03, -0.10, 1.13))),
    ),
    "XA3": CameraProfile(
        "XA3", black_level=256, white_level=16383, wb=(1.96, 1.0, 1.50),
        lens_shading=0.13, cfa="RGGB", cfa_period=(2, 2),
        matrix=_matrix(((1.18, -0.13, -0.05), (-0.05, 1.11, -0.06), (-0.03, -0.12, 1.16))),
    ),
    "GENERIC": CameraProfile("GENERIC"),
}


def _specs() -> Tuple[FilmSimulation, ...]:
    # Controls are intentionally expressed in a compact, testable form.  The
    # resulting profiles retain the relative character of each named look and
    # are suitable defaults when no measured camera LUT is available.
    return (
        FilmSimulation("PROVIA", ("PROVIA/STANDARD", "STANDARD"), 1.03, 1.02, 0.0, 0.10, 0.0, 0.015, 1.0, 0.10, 0.22, 1.0),
        FilmSimulation("VELVIA", ("VELVIA/VIVID", "VIVID"), 1.14, 1.34, 0.012, 0.18, -0.01, 0.025, 0.9, 0.13, 0.12, 1.0),
        FilmSimulation("ASTIA", ("SOFT",), 1.00, 1.08, -0.008, 0.08, 0.005, 0.015, 1.0, 0.09, 0.18, 1.0),
        FilmSimulation("CLASSIC CHROME", ("CLASSIC_CHROME", "CLASSICCHROME", "CC"), 1.10, 0.88, -0.012, 0.24, 0.01, 0.012, 1.1, 0.08, 0.20, 1.0),
        FilmSimulation("CLASSIC NEG.", ("CLASSIC_NEG", "CLASSIC NEG", "CLASSICNEG", "NC"), 1.06, 1.05, 0.018, 0.20, 0.015, 0.020, 1.2, 0.11, 0.16, 1.0),
        FilmSimulation("NOSTALGIC NEG.", ("NOSTALGIC_NEG", "NOSTALGIC NEG", "NOSTALGICNEG"), 1.04, 0.96, 0.025, 0.14, 0.025, 0.022, 1.25, 0.10, 0.15, 1.0),
        FilmSimulation("ETERNA", ("ETERNA/CINEMA",), 0.86, 0.81, -0.008, 0.30, 0.02, 0.018, 1.0, 0.10, 0.10, 1.0),
        FilmSimulation("ETERNA BLEACH BYPASS", ("ETERNA_BLEACH_BYPASS", "BLEACH BYPASS", "BLEACH_BYPASS"), 1.23, 0.43, -0.01, 0.34, 0.01, 0.024, 0.85, 0.12, 0.08, 1.0),
        FilmSimulation("ACROS", ("ACROS+", "ACROS_STD"), 1.15, 0.0, 0.0, 0.28, 0.02, 0.035, 1.15, 0.12, 0.25, 1.0, acros=True),
        FilmSimulation("MONOCHROME", ("MONO",), 1.08, 0.0, 0.0, 0.18, 0.01, 0.022, 1.1, 0.10, 0.20, 1.0),
        FilmSimulation("PRO NEG. HI", ("PRO_NEG_HI", "PRONEGHI"), 1.10, 0.93, -0.008, 0.12, 0.005, 0.012, 1.0, 0.08, 0.18, 1.0),
        FilmSimulation("PRO NEG. STD", ("PRO_NEG_STD", "PRONEGSTD"), 0.96, 0.92, 0.0, 0.06, 0.008, 0.012, 1.0, 0.08, 0.18, 1.0),
        FilmSimulation("REALA ACE", ("REALA_ACE", "REALA"), 1.02, 1.07, -0.005, 0.10, 0.004, 0.015, 1.0, 0.09, 0.18, 1.0),
        FilmSimulation("SEPIA", ("SEPIA_TONE",), 1.00, 0.38, 0.0, 0.16, 0.025, 0.018, 1.1, 0.10, 0.14, 1.0, sepia=True),
    )


SIMULATIONS: Dict[str, FilmSimulation] = {}
for _spec in _specs():
    for _key in (_spec.name, *_spec.aliases):
        SIMULATIONS["".join(ch for ch in _key.upper() if ch.isalnum())] = _spec


def normalize_simulation_name(name: str) -> str:
    """Return the canonical simulation name or raise ``ValueError``."""

    key = "".join(ch for ch in str(name).upper() if ch.isalnum())
    if key not in SIMULATIONS:
        available = ", ".join(sorted({s.name for s in SIMULATIONS.values()}))
        raise ValueError(f"Unknown film simulation {name!r}. Available: {available}")
    return SIMULATIONS[key].name


def get_simulation(name: str, filter_colour: str | None = None) -> FilmSimulation:
    """Resolve a simulation, including ACROS/MONOCHROME colour-filter variants."""

    key = "".join(ch for ch in str(name).upper() if ch.isalnum())
    if filter_colour is None:
        for prefix in ("ACROS", "MONOCHROME", "MONO"):
            if key.startswith(prefix) and key[len(prefix):] in {"G", "R", "YE", "GREEN", "RED", "YELLOW"}:
                filter_colour = key[len(prefix):]
                key = prefix
                break
    base = SIMULATIONS.get(key)
    if base is None:
        raise ValueError(f"Unknown film simulation: {name}")
    f = (filter_colour or "").strip().upper()
    if f in {"G", "GREEN", "R", "RED", "YE", "YELLOW"} and base.name in {"ACROS", "MONOCHROME"}:
        # Colour filters alter the luminance weights.  Keep all other profile
        # controls identical and expose the variant in the canonical name.
        hue = {"G": -0.025, "GREEN": -0.025, "R": 0.032, "RED": 0.032, "YE": 0.052, "YELLOW": 0.052}[f]
        return FilmSimulation(**{**base.__dict__, "name": f"{base.name}+{('G' if f in {'G','GREEN'} else 'R' if f in {'R','RED'} else 'Ye')}", "hue_shift": hue})
    return base


def get_camera(camera: str | CameraProfile | None) -> CameraProfile:
    if isinstance(camera, CameraProfile):
        return camera
    if not camera:
        return CAMERA_PROFILES["GENERIC"]
    key = "".join(ch for ch in str(camera).upper() if ch.isalnum())
    for name, profile in CAMERA_PROFILES.items():
        if "".join(ch for ch in name.upper() if ch.isalnum()) == key:
            return profile
    # Unknown bodies are accepted so the CLI remains useful with custom files.
    return CameraProfile(name=str(camera).upper())


def list_simulations() -> Tuple[str, ...]:
    return tuple(s.name for s in _specs())


def list_cameras() -> Tuple[str, ...]:
    return tuple(CAMERA_PROFILES)
