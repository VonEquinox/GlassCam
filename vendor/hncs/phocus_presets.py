"""Portable Phocus curve and factory-setting semantics.

The names and plist payloads are extracted from Phocus 4.2.2.  The native
colour core has only three distinct non-HDR gradation families: the original
gamma film curve (type 0), the V1 curve (types other than 0/7), and the pure
gamma/L* OETF (type 7).  The UI exposes six names because ``As Shot`` is a
selection sentinel and several named choices share the V1 family.
"""
from __future__ import annotations

import hashlib
import json
from functools import lru_cache
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
PRESETS_PATH = ROOT / "work/hncs-pipeline/phocus_presets.json"
POST_CURVES_PATH = ROOT / "work/hncs-pipeline/phocus_post_curves.npz"

# eFilmCurveType values observed in the native constructor and EffectiveFilmCurve.
# 4 is the UI's automatic/as-shot sentinel; the actual RAW value is resolved
# before CGradationManager selects a table.  The low/high entries are kept as
# explicit native values even though the non-HDR core maps them to the V1 family.
FILM_CURVE_TYPES = {
    "as-shot": 4,
    "standard": 2,
    "low-contrast": 6,
    "high-contrast": 1,
    "old-standard": 0,
    "linear": 7,
}
FILM_CURVE_ALIASES = {
    "as_shot": "as-shot",
    "as shot": "as-shot",
    "low_contrast": "low-contrast",
    "low contrast": "low-contrast",
    "high_contrast": "high-contrast",
    "high contrast": "high-contrast",
    "old_standard": "old-standard",
    "old standard": "old-standard",
}

FACTORY_SETTING_FILES = {
    "standard": "Standard.xml",
    "nature": "Nature.xml",
    "portrait": "Portrait.xml",
    "product": "Product.xml",
    "square-crop": "Square Crop.xml",
    "square_crop": "Square Crop.xml",
    "saturated": "Color Corrections/Saturated.xml",
    "extra-contrast": "Exposure/Extra contrast.xml",
    "extra_contrast": "Exposure/Extra contrast.xml",
    "lighten": "Gradation Curves/Lighten.xml",
    "high": "Sharpness/High.xml",
    "medium": "Sharpness/Medium.xml",
    "cloudy": "White Balance/Cloudy.xml",
    "daylight": "White Balance/Daylight.xml",
    "flash": "White Balance/Flash.xml",
    "fluorescent": "White Balance/Fluorescent.xml",
    "shade": "White Balance/Shade.xml",
    "tungsten": "White Balance/Tungsten.xml",
    # Tool-level one-click settings shipped beside the factory image presets.
    "adjustment-layers-default": "Adjustment Layers/Default.xml",
    "color-corrections-default": "Color Corrections/Default.xml",
    "color-corrections-saturated": "Color Corrections/Saturated.xml",
    "color-management-default": "Color Management/Default.xml",
    "defringe-default": "Defringe/Default.xml",
    "dust-default": "Dust/Default.xml",
    "exposure-default": "Exposure/Default.xml",
    "exposure-extra-contrast": "Exposure/Extra contrast.xml",
    "film-grain-artistic": "Film Grain/Artistic.xml",
    "film-grain-default": "Film Grain/Default.xml",
    "film-grain-fine-texture": "Film Grain/Fine Texture.xml",
    "film-grain-high-iso": "Film Grain/High ISO.xml",
    "film-grain-medium-iso": "Film Grain/Medium ISO.xml",
    "film-grain-rough-color": "Film Grain/Rough Color.xml",
    "film-grain-slide-high-iso": "Film Grain/Slide High ISO.xml",
    "film-grain-slide-medium-iso": "Film Grain/Slide Medium ISO.xml",
    "film-grain-tabular-grain": "Film Grain/Tabular Grain.xml",
    "gradation-curves-default": "Gradation Curves/Default.xml",
    "gradation-curves-lighten": "Gradation Curves/Lighten.xml",
    "grayscale-blue-filter": "Grayscale/Blue filter.xml",
    "grayscale-default": "Grayscale/Default.xml",
    "grayscale-green-filter": "Grayscale/Green filter.xml",
    "grayscale-red-filter": "Grayscale/Red filter.xml",
    "histogram-default": "Histogram/Default.xml",
    "keystone-correction-default": "Keystone Correction/Default.xml",
    "lens-corrections-default": "Lens Corrections/Default.xml",
    "noise-filter-default": "Noise Filter/Default.xml",
    "scene-calibration-default": "Scene Calibration/Default.xml",
    "sharpness-default": "Sharpness/Default.xml",
    "sharpness-high": "Sharpness/High.xml",
    "sharpness-medium": "Sharpness/Medium.xml",
    "sharpness-portrait": "Sharpness/Portrait.xml",
    "white-balance-cloudy": "White Balance/Cloudy.xml",
    "white-balance-daylight": "White Balance/Daylight.xml",
    "white-balance-flash": "White Balance/Flash.xml",
    "white-balance-fluorescent": "White Balance/Fluorescent.xml",
    "white-balance-shade": "White Balance/Shade.xml",
    "white-balance-tungsten": "White Balance/Tungsten.xml",
}
FACTORY_SETTING_ALIASES = {
    "default": "standard",
    "extra contrast": "extra-contrast",
    "square crop": "square-crop",
}
# Keep the user-facing ``Default`` factory name available in the CLI while
# resolving it to the canonical Standard XML payload.  The underscore forms
# remain accepted for shell-friendly compatibility with earlier revisions.
PRESET_CHOICES = tuple(sorted(set(FACTORY_SETTING_FILES) | {"default"}))


def _norm_name(value: str) -> str:
    value = str(value).strip().lower().replace("–", "-").replace("—", "-")
    return FILM_CURVE_ALIASES.get(value, FACTORY_SETTING_ALIASES.get(value, value))


@lru_cache(maxsize=1)
def catalog() -> dict:
    if not PRESETS_PATH.is_file():
        return {"source_files": {}, "factory_setting_names": [], "film_curve_menu_names": []}
    return json.loads(PRESETS_PATH.read_text(encoding="utf-8"))


def preset_key(value: str | None) -> str:
    if value is None:
        return "standard"
    key = _norm_name(value)
    if key not in FACTORY_SETTING_FILES and key != "standard":
        raise ValueError(f"Unknown Phocus factory setting: {value!r}")
    return key


def preset_payload(value: str | None) -> dict:
    """Return the exact extracted plist payload for a factory setting."""
    key = preset_key(value)
    rel = FACTORY_SETTING_FILES.get(key, "Standard.xml")
    entry = catalog().get("source_files", {}).get(rel)
    if not entry:
        return {}
    return entry["plist"]


def _image_correction(payload: dict) -> dict:
    if "ImageSetting" in payload:
        return payload.get("ImageSetting", {}).get("ImageCorrection", {})
    return payload


def _first_image_description(payload: dict) -> dict:
    return payload.get("ImageSetting", {}).get("ImageDescription", {}) if isinstance(payload, dict) else {}


def _native_wb_row(color_temperature, tint) -> dict | None:
    """Look up native TempAndTintToGain data for a preset."""
    if color_temperature in (None, 0) or tint is None:
        return None
    evidence = catalog().get("binary_evidence", {}).get("white_balance_presets", {})
    if not evidence.get("factory_configuration_loaded"):
        raise ValueError("Preset white-balance data require the loaded X2D II factory configuration")
    rows = evidence.get("rows", {})
    for row in rows.values():
        if int(row.get("cct", -1)) == int(color_temperature) and abs(float(row.get("tint", 99.)) - float(tint)) < 1e-9:
            return row
    return None


def settings(value: str | None) -> dict:
    key = preset_key(value)
    payload = preset_payload(key)
    correction = _image_correction(payload)
    description = _first_image_description(payload)
    # Tool presets have their fields at the plist root; factory settings put
    # them under ImageSetting.ImageCorrection.
    if "ImageSetting" not in payload:
        correction = payload
    result = {
        "name": key,
        "source_payload": payload,
        "color_temperature": correction.get("ColorTemperature"),
        "tint": correction.get("Tint"),
        "saturation": correction.get("Saturation", 0),
        "contrast": correction.get("Contrast", 0),
        "brightness": correction.get("Brightness", 0),
        "ev": correction.get("EV"),
        "gamma": correction.get("Gamma", 2.),
        "film_curve_selection": correction.get("FilmCurve", 4),
        "gradations": correction.get("Gradations"),
        "sharpness": {
            "amount": correction.get("USMAmount"),
            "radius": correction.get("USMRadius"),
            "noise_limit": correction.get("USMNoiseLimit"),
            "dark_limit": correction.get("USMDarkLimit"),
        },
        "grayscale": correction.get("GrayScale"),
        "apply_grayscale": correction.get("ApplyGrayScale", False),
        "film_grain": {k: correction.get(k) for k in (
            "ApplyFilmGrain", "FilmGrainAmount", "FilmGrainColor",
            "FilmGrainRoughness", "FilmGrainSize", "FilmGrainType")},
        "crop": description.get("RelativeCrop"),
        "image_description": description,
    }
    wb_row = _native_wb_row(result["color_temperature"], result["tint"])
    result["native_wb_gains"] = ([float(x) for x in wb_row.get("normalized_gains", ())]
                                  if wb_row else None)
    result["native_tint_multiplier"] = ([float(x) for x in wb_row.get("tint_multiplier", ())]
                                         if wb_row else None)
    result["crop_aspect_ratio"] = 1. if FACTORY_SETTING_FILES.get(key) == "Square Crop.xml" else None
    if result["color_temperature"] not in (None, 0) and result["native_wb_gains"] is None:
        raise ValueError(f"Missing configured white-balance gains for preset {key}")
    return result


def resolve_crop(shape, config: dict) -> dict | None:
    """Resolve a factory crop against this image's pixel dimensions."""
    relative = config.get("crop")
    if not relative and config.get("crop_aspect_ratio") is None:
        return None
    height, width = shape[:2]
    if config.get("crop_aspect_ratio") == 1.:
        size = min(height, width)
        left, top = (width-size)//2, (height-size)//2
        right, bottom = left+size, top+size
    else:
        left = int(round(float(relative.get("Left", 0.)) * width))
        right = int(round(float(relative.get("Right", 1.)) * width))
        top = int(round(float(relative.get("Top", 0.)) * height))
        bottom = int(round(float(relative.get("Bottom", 1.)) * height))
    if not (0 <= left < right <= width and 0 <= top < bottom <= height):
        raise ValueError(f"Invalid Phocus crop: {relative!r}")
    return {"pixel_bounds": [left, top, right, bottom],
            "relative_crop": {"Left": left/width, "Right": right/width,
                              "Top": top/height, "Bottom": bottom/height},
            "aspect_ratio": (right-left)/(bottom-top),
            "source_relative_crop": relative}


@lru_cache(maxsize=1)
def post_curve_tables() -> dict:
    evidence = catalog().get("binary_evidence", {}).get("post_curves", {})
    if evidence.get("schema") != 1:
        raise ValueError("Missing native preset curves; run preset_curves_probe.py")
    if not POST_CURVES_PATH.is_file():
        raise ValueError("Missing phocus_post_curves.npz")
    with POST_CURVES_PATH.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != evidence["curves_sha256"]:
        raise ValueError("Phocus preset curve hash mismatch")
    if evidence["baseline_xml_sha256"] != catalog()["source_files"]["Standard.xml"]["sha256"]:
        raise ValueError("Preset curves use a different Standard baseline")
    with np.load(POST_CURVES_PATH, allow_pickle=False) as data:
        tables = {key: data[key] for key in data.files}
    for table in tables.values():
        if table.shape != (65536,) or table.dtype != np.uint16:
            raise ValueError("Invalid native preset curve array")
        table.flags.writeable = False
    return tables


def _recover_hue(original: np.ndarray, adjusted: np.ndarray) -> np.ndarray:
    """Recover input hue with the adjusted HSL lightness and saturation.

    Mirrors CGradationFilter::RecoverHue float32 boundaries and its native
    double constants. The caller retains the native ratio/multiply boundary.
    """
    rgb = original.astype(np.float32) / np.float32(65535.)
    lo, hi = rgb.min(axis=-1), rgb.max(axis=-1)
    span = hi - lo
    r, g, b = np.moveaxis(rgb, -1, 0)
    divisor = np.where(span != 0, span, np.float32(1.))
    hue = np.where(hi == r, ((g-b)*np.float32(60.))/divisor,
                   np.where(hi == g, ((b-r)*np.float32(60.))/divisor+np.float32(120.),
                            ((r-g)*np.float32(60.))/divisor+np.float32(240.)))
    hue = np.where((hi == r) & (g < b), hue+np.float32(360.), hue)
    hue = np.where(span != 0, hue, np.float32(0.))
    mapped = adjusted.astype(np.float32) / np.float32(65535.)
    bottom, top = mapped.min(axis=-1), mapped.max(axis=-1)
    light = (bottom+top)*np.float32(.5)
    delta = top-bottom
    low_s = np.divide(delta*np.float32(.5), light, out=np.zeros_like(light), where=light > 1/65535.)
    low_p = light*(np.float32(1.)+low_s)
    denominator = (2.-2.*light.astype(np.float64)).astype(np.float32)
    high_s = np.divide(delta, denominator, out=np.zeros_like(delta), where=light.astype(np.float64) < 1.-1/65535.)
    high_p = ((light+high_s).astype(np.float64)-light.astype(np.float64)*high_s.astype(np.float64)).astype(np.float32)
    p = np.where(light < np.float32(.5), low_p, high_p).astype(np.float64)
    q = (light+light).astype(np.float64)-p
    normalized_hue = (hue/np.float32(360.)).astype(np.float64)
    offsets = np.array([.3333333432674408, 0., -.3333333432674408])
    t = normalized_hue[..., None]+offsets
    t = np.where(t < 0, t+1., np.where(t > 1., t-1., t))
    amplitude = (p-q)*6.
    color = np.where(t < .1666666716337204, amplitude[..., None]*t+q[..., None],
                     np.where(t < .5, p[..., None],
                              np.where(t < .6666666865348816,
                                       amplitude[..., None]*(.6666666865348816-t)+q[..., None], q[..., None])))
    return color.astype(np.float32)*np.float32(65535.)


def apply_post_curves(codes, value: str | None, *, apply_tone_curve=True) -> tuple[np.ndarray, dict]:
    """Apply factory channel/Gamma tables, contrast and optional luma curve."""
    cfg = settings(value)
    rel = FACTORY_SETTING_FILES[cfg["name"]]
    record = catalog()["binary_evidence"]["post_curves"]["source_files"][rel]
    if record["xml_sha256"] != catalog()["source_files"][rel]["sha256"]:
        raise ValueError("Preset XML and native curve tables disagree")
    mode = record["modes"]["tone" if apply_tone_curve else "no_tone"]
    tables = post_curve_tables()
    source = np.asarray(codes, dtype=np.uint16)
    curve_points = cfg.get("gradations") or []
    point_active = bool(apply_tone_curve and any(len(g.get("Points", [])) > 2 for g in curve_points))
    gamma_active = abs(float(mode["native_settings"]["effective_gamma"])-1.) > 1e-7
    contrast_active = bool(cfg.get("contrast") or cfg.get("brightness"))
    luma_active = bool(apply_tone_curve and mode["native_settings"]["luma_point_count"] > 2)
    gradation_active = point_active or gamma_active or contrast_active or luma_active
    output = np.empty_like(source) if gradation_active else source
    # Pointwise gradation needs no neighbourhood; bound temporary HSL arrays.
    rows = 96 if source.ndim >= 3 else 8192
    if gradation_active:
        for start in range(0, len(source), rows):
            band = source[start:start+rows]
            base = np.stack([tables[mode["tables"][name]][band[..., ch]]
                             for ch, name in enumerate(("red", "green", "blue"))], axis=-1)
            ratios = []
            for active, name in ((True, "contrast"), (luma_active, "luma")):
                if not active:
                    ratios.append(np.ones_like(base, dtype=np.float32))
                    continue
                mapped = tables[mode["tables"][name]][base].astype(np.float32)
                recovered = _recover_hue(base, mapped)
                ratios.append(np.divide(recovered, base, out=recovered.copy(), where=base != 0))
            adjusted = base.astype(np.float32)*ratios[0]*ratios[1]
            output[start:start+rows] = np.clip(adjusted, 0, 65535).astype(np.uint16)
    return output, {"tone_curve_applied": point_active, "tone_curve_requested": bool(apply_tone_curve),
                    "gamma_applied": gamma_active, "effective_gamma": mode["native_settings"]["effective_gamma"],
                    "contrast_applied": float(cfg.get("contrast") or 0), "brightness_applied": float(cfg.get("brightness") or 0),
                    "contrast_hue_recovery": gradation_active, "luma_curve_applied": luma_active,
                    "native_curve_asset_sha256": catalog()["binary_evidence"]["post_curves"]["curves_sha256"]}


def _apply_film_grain(work: np.ndarray, grain: dict, key: str) -> tuple[np.ndarray, bool]:
    """Apply XML grain controls with a deterministic portable noise model."""
    if not grain.get("ApplyFilmGrain") or not grain.get("FilmGrainAmount"):
        return work, False
    amount = float(grain.get("FilmGrainAmount", 0.)) / 100.
    color = float(grain.get("FilmGrainColor", 0.) or 0.) / 100.
    roughness = float(grain.get("FilmGrainRoughness", 0.) or 0.) / 100.
    size = float(grain.get("FilmGrainSize", 0.) or 0.) / 100.
    grain_type = int(grain.get("FilmGrainType", 0) or 0)
    seed = int.from_bytes(hashlib.sha256(f"{key}:{work.shape}".encode()).digest()[:8], "little")
    rng = np.random.default_rng(seed)
    from scipy.ndimage import gaussian_filter
    base = rng.standard_normal(work.shape[:2]).astype(np.float32)
    fine_sigma = max(.15, .35 + .8 * size + .15 * grain_type)
    coarse_sigma = max(.5, 1.3 + 3.0 * size + .35 * grain_type)
    fine = gaussian_filter(base, sigma=fine_sigma, mode="wrap")
    coarse = gaussian_filter(base, sigma=coarse_sigma, mode="wrap")
    grain_plane = (1. - roughness) * fine + roughness * coarse
    grain_plane /= max(float(grain_plane.std()), 1e-6)
    if color:
        channels = np.stack([
            grain_plane,
            gaussian_filter(rng.standard_normal(work.shape[:2]).astype(np.float32), sigma=fine_sigma, mode="wrap"),
            gaussian_filter(rng.standard_normal(work.shape[:2]).astype(np.float32), sigma=fine_sigma, mode="wrap"),
        ], axis=-1)
        channels /= np.maximum(channels.std(axis=(0, 1), keepdims=True), 1e-6)
        channels = channels * color + grain_plane[..., None] * (1. - color)
    else:
        channels = np.repeat(grain_plane[..., None], 3, axis=-1)
    strength = .012 * amount * (0.55 + .45 * np.sqrt(np.clip(work, 0., 1.)))
    return np.clip(work + channels * strength, 0., 1.), True


def apply_preset(codes, value: str | None, *, apply_sharpness: bool = False,
                 apply_grain: bool = True, apply_tone_curve: bool = True) -> tuple[np.ndarray, dict]:
    """Apply the color/tone part of a factory setting to HNCS uint16 codes.

    The factory settings' proprietary spatial kernels remain outside the
    recovered HNCS color core. Their exact extracted values remain in the
    returned provenance. Tone, saturation, grayscale, and crop metadata are
    applied here; Film Grain uses a deterministic portable model driven by all
    five XML grain controls. White-balance CCT/Tint gains are handled by
    ``render`` using the native probe values.
    """
    key = preset_key(value)
    cfg = settings(key)
    out = np.asarray(codes, dtype=np.uint16)
    work = out.astype(np.float32) / 65535.
    saturation = float(cfg.get("saturation") or 0.)
    if saturation:
        mean = work.mean(axis=-1, keepdims=True)
        work = mean + (work - mean) * (1. + saturation / 100.)
    tone_input = np.rint(np.clip(work, 0., 1.)*65535.).astype(np.uint16) if saturation else out
    tone, tone_provenance = apply_post_curves(tone_input, key, apply_tone_curve=apply_tone_curve)
    work = tone.astype(np.float32)/65535.
    if cfg.get("apply_grayscale") and cfg.get("grayscale"):
        weights = np.asarray(cfg["grayscale"][1:4], dtype=np.float32) / 100.
        gray = np.sum(work * weights.reshape(1, 1, 3), axis=-1, keepdims=True)
        work = np.repeat(gray, 3, axis=-1)
    grain = cfg.get("film_grain", {})
    work, grain_applied = _apply_film_grain(work, grain, key) if apply_grain else (work, False)
    sharpness = cfg.get("sharpness", {})
    sharpness_applied = False
    if apply_sharpness and sharpness.get("amount"):
        # CSharpnessFilter is a proprietary multi-pass kernel.  Keep the
        # preset's exact amount/radius/threshold values, and provide a stable
        # portable unsharp approximation for callers that explicitly request
        # spatial preset effects.
        from scipy.ndimage import gaussian_filter
        amount = float(sharpness.get("amount", 0.)) / 100.
        radius = max(float(sharpness.get("radius", 10.)) / 10., .1)
        blurred = gaussian_filter(work, sigma=(radius, radius, 0.), mode="nearest")
        detail = work - blurred
        threshold = float(sharpness.get("noise_limit", 0.) or 0.) / 65535.
        if threshold:
            detail = np.where(np.abs(detail) >= threshold, detail, 0.)
        work = np.clip(work + amount * detail, 0., 1.)
        sharpness_applied = True
    work = np.clip(work, 0., 1.)
    provenance = {
        "preset": key,
        "preset_settings": cfg,
        **tone_provenance,
        "saturation_applied": saturation,
        "grayscale_applied": bool(cfg.get("apply_grayscale")),
        "sharpness_requested": bool(sharpness.get("amount") and apply_sharpness),
        "sharpness_applied": sharpness_applied,
        "film_grain_requested": bool(grain.get("ApplyFilmGrain") and grain.get("FilmGrainAmount")),
        "film_grain_applied": grain_applied,
        "spatial_filters": "portable deterministic film grain and optional Gaussian unsharp; native Phocus spatial kernels remain proprietary",
    }
    return np.rint(work * 65535.).astype(np.uint16), provenance


@lru_cache(maxsize=1)
def original_gamma_curve() -> np.ndarray:
    """Generate HBUtil SetFilmCurveOriginal's 65536-entry gamma table."""
    i = np.arange(65536, dtype=np.float64)
    t = i / 65536.
    v = 65536. * np.power(t, 1. / 4.1)
    strength = 48. / 50.
    toe = strength * (v * v / 32768. - v)
    u = 65536. - v
    shoulder = strength * u * (1. - u / 32768.)
    d = np.where(v < 32768., toe, shoulder)
    out = 65536. * np.power(np.clip((v + d) / 65536., 0., 1.), 1. / .76)
    return np.clip(out, 0, 65535).astype(np.uint16)


def resolve_film_curve(value: str | None, assets: dict, *, intent: str = "standard",
                       working_space: str = "lstar", raw_film_curve: int = 2) -> tuple[np.ndarray, dict]:
    key = _norm_name(value or "as-shot")
    if key not in FILM_CURVE_TYPES:
        raise ValueError(f"Unknown film curve: {value!r}")
    requested_type = int(FILM_CURVE_TYPES[key])
    resolved_type = 7 if intent == "reproduction" else (int(raw_film_curve) if requested_type == 4 else requested_type)
    if resolved_type == 7:
        asset_key = "pure_lstar" if working_space == "lstar" else "pure_gamma"
    elif resolved_type == 0 and working_space == "legacy":
        asset_key = "original_gamma"
    else:
        asset_key = "v1_lstar" if working_space == "lstar" else "v1_gamma"
    curve = original_gamma_curve() if asset_key == "original_gamma" else assets[asset_key]
    return curve, {
        "film_curve": key,
        "requested_film_curve_type": requested_type,
        "resolved_film_curve_type": resolved_type,
        "raw_film_curve_type": int(raw_film_curve),
        "curve_asset": asset_key,
        "native_semantics": "type0 original gamma; type7 pure OETF; other types V1; type4 auto/as-shot sentinel",
    }
