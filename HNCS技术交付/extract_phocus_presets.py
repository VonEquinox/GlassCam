#!/usr/bin/env python3
"""Extract the bundled Phocus 4.2.2 factory settings into portable JSON.

The renderer does not load Phocus at runtime.  This script is run only while
the analysed Phocus image is mounted and records the exact plist values used
by the built-in factory settings and tool presets.
"""
from __future__ import annotations

import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PHOCUS = Path("/Volumes/Phocus/Phocus.app/Contents")
SETTINGS = PHOCUS / "Resources/Settings/Standard"
OUT = ROOT / "work/hncs-pipeline/phocus_presets.json"
WB_PROBE = ROOT / "work/hncs-pipeline/evidence/wb_preset_probe.json"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path: Path):
    return plistlib.loads(path.read_bytes())


def main() -> None:
    if not SETTINGS.is_dir():
        raise SystemExit(f"Phocus settings not found: {SETTINGS}")
    files = {}
    for path in sorted(SETTINGS.rglob("*.xml")):
        rel = path.relative_to(SETTINGS).as_posix()
        files[rel] = {"sha256": digest(path), "plist": load(path)}

    # These names are the actual FactorySettingName table from the binary's
    # English localization.  Keep the numeric order because it is part of the
    # UI contract; the XML files provide the parameter payloads.
    factory_names = [
        "Standard", "Product", "Portrait", "Nature", "Default", "Saturated",
        "Extra contrast", "Lighten", "High", "Medium", "Cloudy", "Daylight",
        "Flash", "Fluorescent", "Shade", "Tungsten", "Square Crop",
    ]
    curve_names = [
        "As Shot", "Standard", "Low Contrast", "High Contrast", "Old Standard", "Linear",
    ]
    result = {
        "schema": 1,
        "phocus_version": "4.2.2",
        "source_root": str(SETTINGS),
        "source_files": files,
        "factory_setting_names": factory_names,
        "film_curve_menu_names": curve_names,
        "binary_evidence": {
            "hbutil_sha256": digest(PHOCUS / "Frameworks/HBUtil.framework/Versions/A/HBUtil"),
            "hbrawcorrections_sha256": digest(PHOCUS / "Frameworks/HBRawCorrections.framework/Versions/A/HBRawCorrections"),
            "hbstorage_sha256": digest(PHOCUS / "Frameworks/HBStorage.framework/Versions/A/HBStorage"),
            "film_curve_selection": {
                "default_selection_value": 4,
                "default_selection_meaning": "auto/as-shot; resolve the RAW film curve",
                "observed_target_raw_film_curve": 2,
                "effective_reproduction_curve": 7,
                "return_gradation_curve": {
                    "type_0": "original film curve in gamma companding",
                    "type_7": "pure gamma/L* OETF",
                    "other_types": "V1 standard curve",
                },
            },
        },
    }
    if WB_PROBE.is_file():
        probe = json.loads(WB_PROBE.read_text(encoding="utf-8"))
        result["binary_evidence"]["white_balance_presets"] = {
            "source_binary_sha256": probe.get("source_binary_sha256"),
            "rows": probe.get("rows", {}),
        }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {OUT} ({len(files)} XML settings)")


if __name__ == "__main__":
    main()
