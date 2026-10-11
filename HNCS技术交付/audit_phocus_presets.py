"""Audit every extracted Phocus Settings/Standard payload against the renderer."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from phocus_presets import FACTORY_SETTING_FILES, apply_preset, catalog, preset_key, settings

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "work/hncs-pipeline/evidence/preset_effect_audit.json"


def main() -> None:
    source_to_key = {}
    for key, source in FACTORY_SETTING_FILES.items():
        source_to_key.setdefault(source, key)
    source = np.zeros((32, 32, 3), dtype=np.uint16)
    source[8:24, 8:24] = np.array([12000, 30000, 52000], dtype=np.uint16)
    rows = []
    for rel in sorted(catalog().get("source_files", {})):
        key = source_to_key[rel]
        cfg = settings(key)
        output, provenance = apply_preset(source, key, apply_sharpness=(key != "standard"))
        correction = cfg["source_payload"].get("ImageSetting", {}).get("ImageCorrection", {})
        rows.append({
            "source_file": rel,
            "key": key,
            "pipeline_applies_preset_stage": key != "standard",
            "output_changed_on_probe": bool(np.any(output != source)),
            "color_temperature": cfg["color_temperature"],
            "tint": cfg["tint"],
            "native_tint_multiplier": cfg["native_tint_multiplier"],
            "relative_crop": cfg["crop"],
            "tone_curve_applied": provenance["tone_curve_applied"],
            "saturation_applied": provenance["saturation_applied"],
            "contrast_applied": provenance["contrast_applied"],
            "grayscale_applied": provenance["grayscale_applied"],
            "film_grain_requested": provenance["film_grain_requested"],
            "film_grain_applied": provenance["film_grain_applied"],
            "sharpness_requested": provenance["sharpness_requested"],
            "sharpness_applied": provenance["sharpness_applied"],
            "native_apply_flags": {k: correction.get(k) for k in (
                "ApplyLensCorrection", "ApplyDust", "ApplyNoiseFilterBias",
                "ApplySceneCalibration", "ApplyDefringe", "ApplyAdjustmentLayers",
            ) if k in correction},
            "spatial_note": provenance["spatial_filters"],
        })
    assert len(rows) == len(catalog()["source_files"]) == 43
    result = {
        "schema": 1,
        "phocus_version": catalog().get("phocus_version"),
        "source_files": len(rows),
        "all_source_files_mapped": True,
        "rows": rows,
        "renderer_entrypoint": "phocus_presets.apply_preset + hncs_pipeline.render",
        "portable_boundary": "Film Grain and CSharpnessFilter use deterministic portable approximations; lens, dust, keystone, scene calibration and other proprietary spatial kernels remain in provenance unless their XML defaults are no-op.",
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"source_files": len(rows), "all_source_files_mapped": True}, ensure_ascii=False))


if __name__ == "__main__":
    main()
