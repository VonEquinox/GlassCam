"""Probe Phocus's native CCT/Tint -> camera gain conversion for factory WB values."""
from __future__ import annotations

import ctypes as c
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from native_config_probe import verified_framework


class Vec3(c.Structure):
    _fields_ = [("x", c.c_double), ("y", c.c_double), ("z", c.c_double)]


def main() -> None:
    path = Path(verified_framework("HBImageProcessing"))
    lib = c.CDLL(str(path))
    fn = getattr(lib, "_ZN20CColorTempConversion17TempAndTintToGainE9eCCDTypes13eIRFilterTypeid")
    fn.argtypes = [c.c_int, c.c_int, c.c_int, c.c_double]
    fn.restype = Vec3
    # eCCDTypes=22 (X2D II), eIRFilterType=6 (X2D II normal IR filter).
    values = {
        "cloudy": (6500, -0.003333333333333333),
        "daylight": (5500, -0.003333333333333333),
        "flash": (5500, 0.0),
        "fluorescent": (3800, -0.007),
        "shade": (7500, -0.003333333333333333),
        "tungsten": (2850, 0.0),
    }
    rows = {}
    for name, (cct, tint) in values.items():
        value = fn(22, 6, cct, tint)
        raw = [value.x, value.y, value.z]
        neutral_value = fn(22, 6, cct, 0.0)
        neutral = [neutral_value.x, neutral_value.y, neutral_value.z]
        rows[name] = {
            "cct": cct,
            "tint": tint,
            "native_gains": raw,
            "normalized_gains": [item / raw[1] for item in raw],
            "zero_tint_gains": neutral,
            "tint_multiplier": [item / base for item, base in zip(raw, neutral)],
        }
    result = {
        "schema": 1,
        "phocus_version": "4.2.2",
        "source_binary": str(path),
        "source_binary_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "sensor": {"ccd_type": 22, "ir_filter_type": 6},
        "rows": rows,
        "meaning": "The normalized gains are the native target-camera white-balance gains for the XML CCT/Tint values.",
    }
    out = ROOT / "work/hncs-pipeline/evidence/wb_preset_probe.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
