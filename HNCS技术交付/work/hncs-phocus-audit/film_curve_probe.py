"""Probe every eFilmCurveType through the Phocus 4.2.2 native constructor."""
from __future__ import annotations

import ctypes as c
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from native_chain_probe import Native


def digest(values: np.ndarray) -> str:
    return hashlib.sha256(np.asarray(values, dtype="<f4").tobytes()).hexdigest()


def main() -> None:
    native = Native()
    rows = []
    for working_space in (0, 1):
        for color_model in (0, 1):
            for film_curve in range(8):
                outer = native.correction(7523, film=film_curve, model=color_model,
                                          hdr=False, space=working_space)
                cc = c.c_void_p.from_address(outer + 0xb0).value
                curve = native.array(c.c_void_p.from_address(cc + 0x188).value,
                                     0, (65536,), "float32")
                rows.append({
                    "working_space": working_space,
                    "color_model": color_model,
                    "film_curve_type": film_curve,
                    "curve_sha256": digest(curve),
                    "samples": [int(curve[i]) for i in (0, 1000, 11796, 32768, 65535)],
                })
                native.fn(native.raw, "_ZN19CRawColorCorrectionD0Ev",
                          [c.c_void_p])(outer)
    native.close()
    result = {
        "phocus_version": "4.2.2",
        "source_binary_sha256": {
            name: hashlib.sha256(Path(path).read_bytes()).hexdigest()
            for name, path in {
                "HBUtil": "/Volumes/Phocus/Phocus.app/Contents/Frameworks/HBUtil.framework/Versions/A/HBUtil",
                "HBRawCorrections": "/Volumes/Phocus/Phocus.app/Contents/Frameworks/HBRawCorrections.framework/Versions/A/HBRawCorrections",
            }.items()
        },
        "rows": rows,
        "interpretation": {
            "type_0": "original film curve in gamma companding",
            "type_7": "pure gamma/L* OETF",
            "types_1_2_3_4_5_6": "V1 family in the non-HDR native gradation manager",
            "type_4": "UI automatic/as-shot sentinel when stored in CImageCorrection",
            "reproduction": "color_model 1 resolves to type 7 regardless of the requested type",
        },
    }
    out = ROOT / "work/hncs-pipeline/evidence/film_curve_probe.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
