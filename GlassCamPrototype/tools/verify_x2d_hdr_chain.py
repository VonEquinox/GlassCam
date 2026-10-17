"""Replay captured original X2D HDR color -> gamma -> gradation -> USM stages.

RAW preparation is supplied by the original. For the USM comparison discard a
four-pixel crop boundary: its original outside-ROI neighborhood is not stored.
Full-frame replicated-edge behavior is checked separately with native vectors.
"""
import argparse
import ctypes as c
import json
from pathlib import Path
import subprocess

import numpy as np

from audit_x2d_identity import sha
from verify_x2d_color_gain import bind, stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--crop-manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if (out / "report.json").exists():
        raise FileExistsError("Preserve the existing chain comparison")
    sources = [root / "core" / name for name in ["hncs.cpp", "hncs_spatial.cpp", "hncs_numpy_rng.cpp"]]
    command = ["xcrun", "clang++", "-std=c++17", "-O3", "-fno-fast-math", "-ffp-contract=off",
               "-Wall", "-Wextra", "-Werror", "-dynamiclib", *map(str, sources), "-o", str(out / "core.dylib")]
    subprocess.run(command, check=True)
    lib = c.CDLL(str(out / "core.dylib"))
    create = bind(lib, "hncs_create_mode", [c.c_double, c.c_double, c.c_int, c.c_int], c.c_void_p)
    destroy = bind(lib, "hncs_destroy", [c.c_void_p], None)
    color = bind(lib, "hncs_render_x2d_hdr_color", [c.c_void_p, c.c_double, c.c_void_p, c.c_void_p, c.c_size_t])
    post = bind(lib, "hncs_render_x2d_hdr_post", [c.c_void_p, c.c_void_p, c.c_size_t, c.c_double, c.c_double, c.c_int])
    gradation = bind(lib, "hncs_apply_x2d_hdr_gradation", [c.c_char_p, c.c_void_p, c.c_void_p, c.c_size_t])
    sharpness = bind(lib, "hncs_render_x2d_hdr_sharpness", [c.c_void_p, c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_double])
    manifest = json.loads(args.crop_manifest.read_text())
    rows = []
    for case in manifest["hdr"]:
        paths = {stage: Path(directory) for stage, directory in case["stages"].items()}
        values = {stage: np.ascontiguousarray(np.load(path / "native-crop.npy")) for stage, path in paths.items()}
        metadata = json.loads((paths["color"] / "native-input.json").read_text())
        invocation = json.loads((paths["color"] / "invocation.json").read_text())
        preset = invocation["preset"].lower().encode()
        params, contract = metadata["parameters"], metadata["color_contract"]
        assert params["hdr"] and metadata["backend"]["requested"] == "cpu"
        h, w = values["input"].shape[:2]
        source = values["input"].astype(np.float64) / 65535.
        actual, temp = np.empty_like(values["color"]), np.empty_like(values["color"])
        context = create(0., contract["cct"], params["working_space"], params["color_model"])
        assert context
        stages = []

        def record(label, actual, expected, crop=0):
            a = actual[crop:-crop, crop:-crop] if crop else actual
            b = expected[crop:-crop, crop:-crop] if crop else expected
            stages.append({"stage": label, "excluded_crop_border": crop, **stats(a, b)})

        try:
            assert color(context, contract["outer_248"], source.ctypes.data, actual.ctypes.data, h * w) == 0
            record("color", actual, values["color"])
        finally:
            destroy(context)
        assert post(actual.ctypes.data, temp.ctypes.data, h * w, 50., 50., params["working_space"]) == 0
        actual, temp = temp, actual
        record("highlight-and-gamma", actual, values["gamma"])
        assert gradation(preset, actual.ctypes.data, temp.ctypes.data, h * w) == 0
        actual, temp = temp, actual
        record("gradation", actual, values["gradation"])
        baseline = metadata["native"]["GetBaselineSharpness"]
        assert sharpness(actual.ctypes.data, temp.ctypes.data, w, h, preset, baseline) == 0
        record("chain-through-sharpness", temp, values["sharpness"], 4)
        isolated = np.empty_like(actual)
        assert sharpness(values["gradation"].ctypes.data, isolated.ctypes.data, w, h, preset, baseline) == 0
        record("isolated-sharpness", isolated, values["sharpness"], 4)
        row = {"name": case["name"], "preset": preset.decode(), "baseline_sharpness": baseline,
               "stages": stages, "source_sha256": {stage: sha(path / "native-crop.npy") for stage, path in paths.items()}}
        rows.append(row)
        print(json.dumps(row), flush=True)
    passed = all(stage["maximum_uint16_error"] == 0 for row in rows for stage in row["stages"])
    report = {"status": "passed" if passed else "difference-found", "cases": rows,
              "compile": command, "manifest_sha256": sha(args.crop_manifest),
              "source_sha256": {str(p.relative_to(root)): sha(p) for p in [Path(__file__), *sources,
                 root / "core/hncs_x2d_hdr_gradation.inc", *sorted((root / "core").glob("hncs_phocus*.hpp"))]},
              "scope": "Prepared original RAW input through HDR color, default 50/50 highlight, gamma, factory gradation and HDR USM; no independent RAW decoder or final ICC."}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
