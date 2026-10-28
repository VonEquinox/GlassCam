"""Explicit numerical correction to the pinned revision-8 preset reference.

The original delivery remains unmodified. Direct Phocus 4.2.2 arm64 calls and
AddPostViewerRGBFilters/CCalculatedCurves/CGradationFilter disassembly establish
that no-adjustment gradation still executes. Revision 8's activity shortcut is
therefore unsuitable as an oracle for this stage. All original tables, hue math
and remaining preset stages are reused in an isolated module instance.
"""
import numpy as np
from . import reference_runtime as r


presets = r.load_module(r.REFERENCE / "phocus_presets.py", "hncs_binary_presets")


def apply_post_curves(codes, value, *, apply_tone_curve=True):
    cfg = presets.settings(value)
    rel = presets.FACTORY_SETTING_FILES[cfg["name"]]
    catalog = presets.catalog()
    record = catalog["binary_evidence"]["post_curves"]["source_files"][rel]
    if record["xml_sha256"] != catalog["source_files"][rel]["sha256"]:
        raise ValueError("Preset XML and native curve tables disagree")
    mode = record["modes"]["tone" if apply_tone_curve else "no_tone"]
    tables = presets.post_curve_tables()
    source = np.asarray(codes, dtype=np.uint16)
    output = np.empty_like(source)
    luma = bool(apply_tone_curve and mode["native_settings"]["luma_point_count"] > 2)
    rows = 96 if source.ndim >= 3 else 8192
    for start in range(0, len(source), rows):
        band = source[start:start + rows]
        base = np.stack([tables[mode["tables"][name]][band[..., channel]]
                         for channel, name in enumerate(("red", "green", "blue"))], axis=-1)
        ratios = []
        for enabled, name in ((True, "contrast"), (luma, "luma")):
            if not enabled:
                ratios.append(np.ones_like(base, dtype=np.float32))
                continue
            mapped = tables[mode["tables"][name]][base].astype(np.float32)
            recovered = presets._recover_hue(base, mapped)
            ratios.append(np.divide(recovered, base, out=recovered.copy(), where=base != 0))
        adjusted = (base.astype(np.float32) * ratios[0]) * ratios[1]
        output[start:start + rows] = np.clip(adjusted, 0, 65535).astype(np.uint16)
    return output, {
        "tone_curve_requested": bool(apply_tone_curve),
        "contrast_hue_recovery": True,
        "luma_curve_applied": luma,
        "binary_gradation_correction": 1,
        "native_curve_asset_sha256": catalog["binary_evidence"]["post_curves"]["curves_sha256"],
    }


presets.apply_post_curves = apply_post_curves
