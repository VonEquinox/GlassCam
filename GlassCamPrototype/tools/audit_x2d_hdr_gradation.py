"""Capture exact HDR factory gradation tables and probe original filter modes.

CalculateCurve(CCurve*, bool) uses the native 5.8829245141 domain scale when
HDR and ExpToolVersion >= 4. SDR tables cannot be reused for that input domain.
This generator copies exact finite UInt16 tables; it performs no color fitting.
"""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

import numpy as np

from audit_phocus_input_spatial import Filters
from audit_x2d_identity import sha
from verify_x2d_color_gain import bind, stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--crop-manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if (out / "report.json").exists():
        raise FileExistsError("Preserve original gradation evidence")
    sys.path[:0] = [str(args.reference_root), str(args.reference_root / "work/hncs-phocus-audit")]
    from native_chain_probe import Native
    from native_config_probe import FRAMEWORK_HASHES, verified_framework
    from preset_curves_probe import NativeCurves
    command = ["xcrun", "clang++", "-std=c++17", "-O2", "-dynamiclib",
               str(root / "tools/native_phocus_filters_bridge.cpp"), "-o", str(out / "filters.dylib")]
    subprocess.run(command, check=True)
    n = Native()
    storage = c.CDLL(str(verified_framework("HBStorage")))
    filters = Filters(n, out / "filters.dylib")
    construct = bind(filters.bridge, "construct_phocus_gradation", [c.c_void_p, c.c_void_p, c.c_bool, c.c_void_p])
    constructor = c.cast(getattr(n.image, "_ZN16CGradationFilterC1ENSt3__110shared_ptrIK17CCalculatedCurvesEEb"), c.c_void_p).value
    symbol = "_ZNK16CGradationFilter12FilterResultE6CXRectS0_NSt3__110unique_ptrI14CBufferedImageNS1_14default_deleteIS3_EEEES6_"
    factory = Path("/Volumes/Phocus/Phocus.app/Contents/Resources/Settings/Standard")
    tables, presets, table_records = [], [], []
    corpus = np.concatenate([np.repeat(np.arange(65536, dtype=np.uint16)[:, None], 3, axis=1),
              np.stack(np.meshgrid(*([np.linspace(0, 65535, 17, dtype=np.uint16)] * 3), indexing="ij"), axis=-1).reshape(-1, 3),
              np.random.default_rng(20261018).integers(0, 65536, (8192, 3), dtype=np.uint16)])[None]
    goldens, golden_cases, crop_rows = {}, [], []

    def apply(curves, pixels, recover):
        obj = c.create_string_buffer(0x1000)
        assert construct(obj, curves.curves, recover, constructor) == 0
        try:
            return filters.run(obj, symbol, pixels)
        finally:
            filters.destroy(obj)

    for key in ["standard", "nature"]:
        path = factory / (key.title() + ".xml")
        payload = plistlib.loads(path.read_bytes())["ImageSetting"]["ImageCorrection"]
        payload.update({"HDR": True, "ExpToolVersion": 4})
        curves = NativeCurves(n, storage, payload)
        try:
            arrays = curves.arrays()
            np.savez_compressed(out / (key + "-tables.npz"), **arrays)
            indices = []
            for name in ["red", "green", "blue", "contrast", "luma"]:
                a = arrays[name]
                for index, existing in enumerate(tables):
                    if np.array_equal(a, existing):
                        break
                else:
                    index = len(tables)
                    tables.append(a)
                indices.append(index)
            presets.append({"key": key, "indices": indices, "luma": curves.settings()["luma_point_count"] > 2})
            table_records.append({"preset": key, "factory_sha256": sha(path), "settings": curves.settings(),
                "table_sha256": {name: hashlib.sha256(a.tobytes()).hexdigest() for name, a in arrays.items()}})
            for recover in [False, True]:
                expected = apply(curves, corpus, recover)
                prefix = f"case_{len(golden_cases)}"
                goldens[prefix + "_input"] = corpus
                goldens[prefix + "_expected"] = expected
                golden_cases.append({"prefix": prefix, "preset": key, "recover_hue": recover})
        finally:
            curves.close()
    manifest = json.loads(args.crop_manifest.read_text())
    for case in manifest["hdr"]:
        before, after = Path(case["stages"]["gamma"]), Path(case["stages"]["gradation"])
        payload = plistlib.loads((after / "native-settings.plist").read_bytes())
        curves = NativeCurves(n, storage, payload)
        try:
            source, expected = np.load(before / "native-crop.npy"), np.load(after / "native-crop.npy")
            key = json.loads((after / "invocation.json").read_text())["preset"].lower()
            generated = np.load(out / (key + "-tables.npz"))
            arrays = curves.arrays()
            checks = {name: int(np.count_nonzero(a != generated[name])) for name, a in arrays.items()}
            row = {"name": case["name"], "factory_hdr_table_differences": checks, "filter_modes": []}
            for recover in [False, True]:
                row["filter_modes"].append({"recover_hue": recover, **stats(apply(curves, source, recover), expected)})
            crop_rows.append(row)
            print(json.dumps(row), flush=True)
        finally:
            curves.close()
    lines = ["// Generated by tools/audit_x2d_hdr_gradation.py from hash-locked Phocus 4.2.2.",
             "// Exact HDR UInt16 tables: Standard/Nature, ExpToolVersion 4, default controls.",
             "#pragma once", "#include <cstdint>", "namespace x2d_hdr_gradation_assets {"]
    for index, table in enumerate(tables):
        lines.append(f"inline constexpr uint16_t table_{index}[65536] = {{")
        for start in range(0, 65536, 32):
            lines.append(",".join(map(str, table[start:start + 32])) + ",")
        lines.append("};")
    lines.append("inline constexpr const uint16_t* tables[] = {" + ",".join(f"table_{i}" for i in range(len(tables))) + "};")
    lines.append("struct Preset { const char* key; unsigned table[5]; bool luma; };")
    lines.append("inline constexpr Preset presets[] = {")
    for preset in presets:
        lines.append('{"' + preset["key"] + '",{' + ",".join(map(str, preset["indices"])) + '},' + str(preset["luma"]).lower() + '},')
    lines.extend(["};", "} // namespace x2d_hdr_gradation_assets", ""])
    (out / "hncs_x2d_hdr_gradation.inc").write_text("\n".join(lines))
    np.savez_compressed(out / "goldens.npz", **goldens)
    (out / "goldens.json").write_text(json.dumps({"cases": golden_cases, "vectors_sha256": sha(out / "goldens.npz")}, indent=2) + "\n")
    report = {"tables": table_records, "crops": crop_rows, "unique_tables": len(tables),
              "generated_sha256": sha(out / "hncs_x2d_hdr_gradation.inc"), "command": command,
              "framework_sha256": {name: sha(verified_framework(name)) for name in FRAMEWORK_HASHES},
              "source_sha256": {str(p.relative_to(root)): sha(p) for p in [Path(__file__), root / "tools/native_phocus_filters_bridge.cpp"]},
              "scope": "Original table generation and original filter mode comparison; no independent port validation yet."}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"unique_tables": len(tables), "header_bytes": (out / "hncs_x2d_hdr_gradation.inc").stat().st_size}))


if __name__ == "__main__":
    main()
