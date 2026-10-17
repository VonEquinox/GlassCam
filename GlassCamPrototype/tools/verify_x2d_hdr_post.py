"""Compare original Phocus HDR highlight/gamma filters with the independent port."""
import argparse
import ctypes as c
import json
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np

from audit_phocus_input_spatial import Filters
from audit_x2d_identity import sha
from verify_x2d_color_gain import bind, stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--crop-manifest", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if (out / "report.json").exists():
        raise FileExistsError("Preserve previous original comparisons")
    sys.path[:0] = [str(args.reference_root), str(args.reference_root / "work/hncs-phocus-audit")]
    from native_chain_probe import Native
    from native_config_probe import FRAMEWORK_HASHES, verified_framework
    commands = []
    sources = [root / "tools/native_phocus_filters_bridge.cpp", root / "tools/x2d_hdr_post_model_bridge.cpp"]
    for source, name in zip(sources, ["filters", "candidate"]):
        command = ["xcrun", "clang++", "-std=c++17", "-O3", "-fno-fast-math", "-ffp-contract=off",
                   "-Wall", "-Wextra", "-Werror", "-dynamiclib", str(source),
                   *([str(root / "core/hncs.cpp")] if name == "candidate" else []),
                   "-o", str(out / (name + ".dylib"))]
        subprocess.run(command, check=True)
        commands.append(command)
    for source in [*sources, root / "core/hncs_phocus_hdr_post.hpp"]:
        shutil.copyfile(source, out / source.name)
    native = Native()
    filters = Filters(native, out / "filters.dylib")
    candidate = c.CDLL(str(out / "candidate.dylib"))
    render = bind(candidate, "hdr_post_model", [c.c_void_p, c.c_void_p, c.c_size_t, c.c_int,
                   c.c_double, c.c_double, c.c_int])
    constructors = [native.fn(native.image, "_ZN24CHighlightStrengthFilterC1Edd", [c.c_void_p, c.c_double, c.c_double]),
                    native.fn(native.image, "_ZN12CGammaFilterC1Eb", [c.c_void_p, c.c_bool])]
    suffix = "12FilterResultE6CXRectS0_NSt3__110unique_ptrI14CBufferedImageNS1_14default_deleteIS3_EEEES6_"
    symbols = ["_ZNK24CHighlightStrengthFilter" + suffix, "_ZNK12CGammaFilter" + suffix]
    gray = np.repeat(np.arange(65536, dtype=np.uint16)[:, None], 3, axis=1)
    grid = np.stack(np.meshgrid(*([np.linspace(0, 65535, 17, dtype=np.uint16)] * 3), indexing="ij"), axis=-1).reshape(-1, 3)
    random = np.random.default_rng(20261018).integers(0, 65536, (16384, 3), dtype=np.uint16)
    source = np.ascontiguousarray(np.concatenate([gray, grid, random])[None])
    chosen = np.r_[[1, 2, 7531, 7539], np.arange(0, 65536, 257), np.arange(source.shape[1] - 128, source.shape[1])]
    rows, goldens, cases = [], {}, []

    def check(pixels, expected, stage, amount, saturation, lstar, name):
        actual = np.empty_like(expected)
        assert render(pixels.ctypes.data, actual.ctypes.data, pixels.size // 3, stage,
                      amount, saturation, int(lstar)) == 0
        difference = np.abs(actual.astype(np.int32) - expected.astype(np.int32))
        worst = int(np.argmax(difference)) // 3
        row = {"name": name, "stage": stage, "amount": amount, "saturation": saturation,
               "lstar": lstar, **stats(actual, expected),
               "worst": {"input": pixels.reshape(-1, 3)[worst].tolist(),
                         "expected": expected.reshape(-1, 3)[worst].tolist(),
                         "actual": actual.reshape(-1, 3)[worst].tolist()}}
        rows.append(row)
        print(json.dumps(row), flush=True)
        return actual

    random_settings = [(float(a), float(s), False) for a, s in np.random.default_rng(314159).uniform(0, 100, (16, 2))]
    for stage, settings in [(0, [(a, s, False) for a in [0., 50., 100.] for s in [0., 50., 100.]] + random_settings),
                            (1, [(0., 0., lstar) for lstar in [False, True]]),
                            (2, [(a, s, lstar) for a, s in [(0., 0.), (50., 50.), (100., 100.)] for lstar in [False, True]])]:
        for amount, saturation, lstar in settings:
            obj = c.create_string_buffer(0x1000)
            if stage in [0, 2]:
                constructors[0](obj, amount, saturation)
            else:
                constructors[1](obj, lstar)
            try:
                expected = filters.run(obj, symbols[0 if stage == 2 else stage], source)
            finally:
                filters.destroy(obj)
            if stage == 2:
                obj = c.create_string_buffer(0x1000)
                constructors[1](obj, lstar)
                try:
                    expected = filters.run(obj, symbols[1], expected)
                finally:
                    filters.destroy(obj)
            name = f"stage-{stage}-amount-{amount}-sat-{saturation}-lstar-{int(lstar)}"
            check(source, expected, stage, amount, saturation, lstar, name)
            prefix = f"case_{len(cases)}"
            goldens[prefix + "_input"] = source.reshape(-1, 3)[chosen]
            goldens[prefix + "_expected"] = expected.reshape(-1, 3)[chosen]
            cases.append({"prefix": prefix, "stage": stage, "amount": amount, "saturation": saturation, "lstar": lstar})
    if args.crop_manifest:
        manifest = json.loads(args.crop_manifest.read_text())
        for case in manifest["hdr"]:
            for before, after, stage in [("color", "highlight", 0), ("highlight", "gamma", 1), ("color", "gamma", 2)]:
                source_path, expected_path = Path(case["stages"][before]), Path(case["stages"][after])
                pixels = np.ascontiguousarray(np.load(source_path / "native-crop.npy"))
                expected = np.ascontiguousarray(np.load(expected_path / "native-crop.npy"))
                metadata = json.loads((expected_path / "native-input.json").read_text())
                # Earlier manifests use gamma_inverse for the same 0x48 flag;
                # it selects L* vs legacy gamma and is not an inverse operation.
                contract = metadata.get("hdr_post_contract", {})
                amount, saturation = contract.get("highlight_parameters", [50., 50.])
                lstar = contract.get("gamma_lstar", contract.get("gamma_inverse", bool(metadata["parameters"]["working_space"])))
                check(pixels, expected, stage, amount, saturation, lstar, case["name"] + "-" + after)
                rows[-1].update({"input_sha256": sha(source_path / "native-crop.npy"),
                                 "expected_sha256": sha(expected_path / "native-crop.npy")})
    passed = all(row["maximum_uint16_error"] == 0 for row in rows)
    report = {"status": "passed" if passed else "difference-found", "cases": rows, "compile": commands,
              "framework_sha256": {name: sha(verified_framework(name)) for name in FRAMEWORK_HASHES},
              "source_sha256": {str(p.relative_to(root)): sha(p) for p in [Path(__file__), *sources, root / "core/hncs_phocus_hdr_post.hpp", root / "core/hncs.cpp", root / "core/hncs_c.h"]},
              "scope": "Original CPU HDR HighlightStrength and gamma filters. All 65536 neutrals, 17-cube, 16384 random RGB; optional real HDR crops."}
    np.savez_compressed(out / "goldens.npz", **goldens)
    (out / "goldens.json").write_text(json.dumps({"cases": cases, "vectors_sha256": sha(out / "goldens.npz")}, indent=2) + "\n")
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
