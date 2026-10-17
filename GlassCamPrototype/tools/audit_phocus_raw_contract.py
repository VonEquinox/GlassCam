"""Read existing RAW metadata through original Phocus and verify exposure units.

Opens files read-only and compares native getters with their original TIFF tags.
Does not render photographs, alter sidecars, fit a matrix, or apply these sensor
code-unit gains to already-normalized Apple RGB.
"""
import argparse
import ctypes as c
import json
import math
from pathlib import Path
import plistlib
import sys

import tifffile
from audit_phocus_input_spatial import sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--raw-source", type=Path, nargs="+", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    ref, out = args.reference_root.resolve(), args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sys.path[:0] = [str(ref), str(ref / "work/hncs-phocus-audit")]
    from native_chain_probe import Native
    from native_config_probe import FRAMEWORK_HASHES, verified_framework
    from preset_curves_probe import NativeCurves
    n = Native(); storage = c.CDLL(str(verified_framework("HBStorage")))
    stream = c.create_string_buffer(0x1000)
    n.fn(storage, "_ZN17CStreamFactoryMacC1Ev", [c.c_void_p])(stream)
    previous_stream = c.c_void_p.in_dll(n.util, "gStreamFactory").value
    c.c_void_p.in_dll(n.util, "gStreamFactory").value = c.addressof(stream)
    rows = []
    try:
      for path in args.raw_source:
        path = path.resolve(); initial = sha(path)
        with tifffile.TiffFile(path) as image:
            tags = image.pages[0].tags
            def number(tag, default=0.):
                entry = tags.get(tag)
                if entry is None: return default
                value = entry.value
                return value[0] / value[1] if isinstance(value, tuple) else float(value)
            baseline_exposure = number(0xc62a)
            exposure_offset = number(0xc7a5)
            baseline_sharpness = number(0xc62c)
            model = str(tags.get(272).value) if tags.get(272) else None
        spec, raw = c.create_string_buffer(0x40), c.create_string_buffer(0x4000)
        n.fn(n.util, "_ZN9CFileSpecC1EPKcbii", [c.c_void_p, c.c_char_p, c.c_bool, c.c_int, c.c_int])(spec, str(path).encode(), False, 0, 0)
        n.fn(n.image, "_ZN11CRaw3FRFileC1E9CFileSpec", [c.c_void_p, c.c_void_p])(raw, spec)
        try:
            values = {}
            for name, result in [("GetIsoGain", c.c_double), ("GetBlackLevel", c.c_int),
                                 ("GetBaselineSharpness", c.c_double), ("GetFilmCurveType", c.c_int)]:
                values[name] = n.fn(storage, f"_ZN13CRawImageFile{len(name)}{name}Ev", [c.c_void_p], result)(raw)
            white = n.fn(storage, "_ZNK13CRawImageFile16GetDNGWhiteLevelEv", [c.c_void_p], c.c_int)(raw)
            values["GetDNGWhiteLevel"] = white
            expected_gain = (65535. / (white - values["GetBlackLevel"])) * 2. ** (baseline_exposure + exposure_offset)
            assert math.isclose(expected_gain, values["GetIsoGain"], rel_tol=0, abs_tol=1e-12), (path, values, expected_gain)
            assert baseline_sharpness == values["GetBaselineSharpness"]
            effective = []
            factory = Path("/Volumes/Phocus/Phocus.app/Contents/Resources/Settings/Standard")
            for name in ["Standard", "Nature"]:
                payload = plistlib.loads((factory / (name + ".xml")).read_bytes())["ImageSetting"]["ImageCorrection"]
                settings = NativeCurves(n, storage, payload)
                try:
                    amount = n.fn(storage, "_ZNK16CImageCorrection24EffectiveSharpnessAmountEdi", [c.c_void_p, c.c_double, c.c_int], c.c_double)(settings.correction, values["GetBaselineSharpness"], 0)
                    effective.append({"preset": name, "nominal_amount": payload["USMAmount"],
                                      "native_effective_amount": amount, "kernel_integer_amount": int(amount),
                                      "extra_exposure_multiplier": c.c_double.from_buffer(settings.correction, 0x288).value})
                finally: settings.close()
            rows.append({"path": str(path), "sha256": initial, "model": model, "native": values,
                         "baseline_exposure": baseline_exposure, "exposure_offset": exposure_offset,
                         "tag_baseline_sharpness": baseline_sharpness, "computed_code_unit_gain": expected_gain,
                         "gain_absolute_error": abs(expected_gain - values["GetIsoGain"]), "presets": effective})
        finally:
            vtable = c.c_void_p.from_buffer(raw).value
            c.CFUNCTYPE(None, c.c_void_p)(c.c_void_p.from_address(vtable).value)(raw)
            n.fn(n.util, "_ZN9CFileSpecD1Ev", [c.c_void_p])(spec)
        assert sha(path) == initial
    finally:
        c.c_void_p.in_dll(n.util, "gStreamFactory").value = previous_stream
        n.fn(storage, "_ZN17CStreamFactoryMacD1Ev", [c.c_void_p])(stream)
        n.close()
    report = {"status": "passed", "files": rows, "source_sha256": {str(Path(__file__)): sha(Path(__file__))},
              "framework_sha256": {name: sha(verified_framework(name)) for name in FRAMEWORK_HASHES},
              "formula": "65535 / (white_level - black_level) * 2^(BaselineExposure + BaselineExposureOffset)",
              "formula_scope": "Verified only for the listed RAW files and their selected native branch. r2ghidra GetIsoGain also shows legacy-white-level, analog-gain, sensor-specific and debug-override branches; this is not a universal RAW formula.",
              "interpretation": "The native ISO getter includes source code-range normalization. Multiplying it again into Apple white-normalized RGB would duplicate normalization. BaselineSharpness is a separate per-file metadata input; preset EV=1 is a multiplier, meaning zero extra EV. These getters do not prove Apple/Phocus RAW-development or HDR equivalence."}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"files": len(rows), "maximum_gain_error": max(row["gain_absolute_error"] for row in rows),
                      "baseline_sharpness": [row["tag_baseline_sharpness"] for row in rows]}, indent=2))


if __name__ == "__main__":
    main()
