"""Compare retained original CPU color crops with the shared production core.

The manifest lists native before/after directories. Optional TIFF comparisons
are reported independently: agreement between two vendor executions is not an
independent RAW decoder validation. Inputs, contracts and results are hashed.
"""
import argparse
import ctypes as c
import json
from pathlib import Path
import subprocess

import numpy as np
import tifffile

from audit_x2d_identity import sha
from verify_x2d_color_gain import bind, stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output_dir.resolve(); out.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(args.manifest.read_text())
    library = out / "color-core.dylib"
    command = ["xcrun", "clang++", "-std=c++17", "-O3", "-fno-fast-math", "-ffp-contract=off",
               "-Wall", "-Wextra", "-Werror", "-dynamiclib", str(root / "core/hncs.cpp"), "-o", str(library)]
    subprocess.run(command, check=True)
    lib = c.CDLL(str(library))
    create = bind(lib, "hncs_create_mode", [c.c_double, c.c_double, c.c_int, c.c_int], c.c_void_p)
    clone = bind(lib, "hncs_clone_with_native_gain", [c.c_void_p, c.c_double], c.c_void_p)
    destroy = bind(lib, "hncs_destroy", [c.c_void_p], None)
    render = bind(lib, "hncs_render_native", [c.c_void_p] * 3 + [c.c_size_t])
    rows, exports = [], []
    for case in manifest.get("color", []):
        before, after = (Path(case[key]) for key in ["before", "after"])
        inv_a, inv_b = (json.loads((folder / "invocation.json").read_text()) for folder in [before, after])
        for key in ["raw_sha256", "settings_sha256", "crop", "hdr", "exposure_ev", "temperature", "parameter_builder"]:
            if inv_a[key] != inv_b[key]:
                raise ValueError("Input contract mismatch: " + key)
        meta = json.loads((after / "native-input.json").read_text())
        params, contract = meta["parameters"], meta["color_contract"]
        if params["hdr"] or inv_a["requested_backend"] != "cpu" or inv_b["requested_backend"] != "cpu":
            raise ValueError("This comparison requires the ordinary CPU color domain")
        if contract["linearization_lengths"] != [0.] * 6:
            raise ValueError("Native linearization tables require a separate comparison")
        source, expected = (np.load(folder / "native-crop.npy") for folder in [before, after])
        assert source.dtype == np.uint16 and source.shape == expected.shape and source.shape[-1] == 3
        parent = create(0., contract["cct"], params["working_space"], params["color_model"])
        fixed = clone(parent, contract["outer_248"])
        if not parent or not fixed:
            raise RuntimeError("Unable to construct production color context")
        floating = np.ascontiguousarray(source.astype(np.float64) / 65535.)
        old, actual = np.empty_like(expected), np.empty_like(expected)
        try:
            for context, destination in [(parent, old), (fixed, actual)]:
                if render(context, floating.ctypes.data, destination.ctypes.data, source.size // 3):
                    raise RuntimeError("Production color processing failed")
        finally:
            destroy(fixed); destroy(parent)
        rows.append({"name": case["name"], "before": stats(old, expected), "after": stats(actual, expected),
                     "contract": contract, "invocation": inv_b,
                     "evidence_sha256": {str(p): sha(p) for folder in [before, after]
                                         for p in [folder / "native-crop.npy", folder / "native-input.json"]}})
    for case in manifest.get("exports", []):
        folder, path = Path(case["native"]), Path(case["tiff"])
        invocation = json.loads((folder / "invocation.json").read_text())
        left, top, width, height = invocation["crop"]
        reference = tifffile.memmap(path)
        expected = np.ascontiguousarray(reference[top:top + height, left:left + width])
        actual = np.load(folder / "native-crop.npy")
        if actual.shape != expected.shape: raise ValueError("TIFF crop geometry mismatch")
        exports.append({"name": case["name"], "native": str(folder), "tiff": str(path),
                        "invocation": invocation, **stats(actual, expected),
                        "crop_sha256": sha(folder / "native-crop.npy")})
    report = {"status": "passed-color" if all(r["after"]["maximum_uint16_error"] == 0 for r in rows) else "color-difference-found",
              "color": rows, "vendor_export_comparisons": exports, "compile": command,
              "source_sha256": {str(p.relative_to(root)): sha(p) for p in [Path(__file__), root / "core/hncs.cpp", root / "core/hncs_c.h"]},
              "manifest_sha256": sha(args.manifest),
              "limits": ["Color comparisons start with original prepared native pixels, not an independent RAW decoder.",
                         "TIFF comparison is vendor reexecution versus retained vendor export; nonzero differences are retained."]}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "color": [{"name": r["name"], "before": r["before"], "after": r["after"]} for r in rows],
                      "exports": [{k: r[k] for k in ["name", "maximum_uint16_error", "mean_absolute_error", "different_channels"]} for r in exports]}, indent=2))
    if report["status"] != "passed-color": raise SystemExit(1)


if __name__ == "__main__":
    main()
