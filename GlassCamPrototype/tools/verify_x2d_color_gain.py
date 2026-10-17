"""Compare the processing-gain-aware core with original Phocus and real crops.

Expected values come from the original factory constructor and native function,
or saved intermediate captures of the original RAW pipeline. No expected array
is recomputed by the implementation under test.
"""
import argparse
import ctypes as c
import json
from pathlib import Path
import subprocess
import sys

import numpy as np
from audit_x2d_identity import sha


def bind(library, name, arguments, result=c.c_int):
    fn = getattr(library, name); fn.argtypes = arguments; fn.restype = result
    return fn


def stats(actual, expected):
    error = actual.astype(np.int32) - expected.astype(np.int32)
    return {"channels": int(error.size), "different_channels": int(np.count_nonzero(error)),
            "maximum_uint16_error": int(np.abs(error).max()), "mean_absolute_error": float(np.abs(error).mean())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--baseline-library", type=Path)
    parser.add_argument("--real-vector", type=Path)
    parser.add_argument("--real-contract", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output_dir.resolve(); out.mkdir(parents=True, exist_ok=True)
    ref = args.reference_root.resolve()
    sys.path[:0] = [str(ref), str(ref / "work/hncs-phocus-audit")]
    from native_chain_probe import Native
    from native_config_probe import FRAMEWORK_HASHES, verified_framework
    command = ["xcrun", "clang++", "-std=c++17", "-O3", "-fno-fast-math", "-ffp-contract=off",
               "-Wall", "-Wextra", "-Werror", "-dynamiclib", str(root / "core/hncs.cpp"), "-o", str(out / "core.dylib")]
    subprocess.run(command, check=True)
    lib = c.CDLL(str(out / "core.dylib"))
    create = bind(lib, "hncs_create_mode", [c.c_double, c.c_double, c.c_int, c.c_int], c.c_void_p)
    clone = bind(lib, "hncs_clone_with_native_gain", [c.c_void_p, c.c_double], c.c_void_p)
    destroy = bind(lib, "hncs_destroy", [c.c_void_p], None)
    render = bind(lib, "hncs_render_native", [c.c_void_p] * 3 + [c.c_size_t])
    n = Native()
    native_pixels = n.fn(n.raw, "_ZN14CVectorMethods24ColorNormalCorrectPixelsEP16CColorCorrectionPtS2_ib",
                         [c.c_void_p] * 4 + [c.c_int, c.c_bool])
    native_delete = n.fn(n.raw, "_ZN19CRawColorCorrectionD0Ev", [c.c_void_p])
    grid = np.stack(np.meshgrid(*([np.linspace(0, 65535, 17, dtype=np.uint16)] * 3), indexing="ij"), axis=-1).reshape(-1, 3)
    source = np.ascontiguousarray(np.concatenate([
        np.repeat(np.arange(65536, dtype=np.uint16)[:, None], 3, axis=1), grid,
        np.random.default_rng(20261018).integers(0, 65536, (8192, 3), dtype=np.uint16)]))
    inputs = source.astype(np.float64) / 65535.
    expected, actual = np.empty_like(source), np.empty_like(source)
    rows, goldens = [], {}
    if args.baseline_library:
        baseline = c.CDLL(str(args.baseline_library.resolve()))
        old_create = bind(baseline, "hncs_create_mode", [c.c_double, c.c_double, c.c_int, c.c_int], c.c_void_p)
        old_render = bind(baseline, "hncs_render_native", [c.c_void_p] * 3 + [c.c_size_t])
        old_destroy = bind(baseline, "hncs_destroy", [c.c_void_p], None)
    baseline_checks = []
    for space in [0, 1]:
      for model in [0, 1]:
       for cct in [2850., 5500., 7523.]:
        parent = create(0., cct, space, model)
        assert parent
        if args.baseline_library:
            old = old_create(0., cct, space, model)
            assert old and old_render(old, inputs.ctypes.data, expected.ctypes.data, len(source)) == 0
            assert render(parent, inputs.ctypes.data, actual.ctypes.data, len(source)) == 0
            row = {"space": space, "model": model, "cct": cct, **stats(actual, expected)}
            baseline_checks.append(row)
            old_destroy(old)
            assert row["maximum_uint16_error"] == 0, row
        for gain in [.25, 1., 1.0653693159208844, 4.643602306524954, 16.]:
            context = clone(parent, gain)
            assert context
            original = n.correction(cct, film=7 if model else 2, model=model, hdr=False, gain=gain, space=space)
            assert original
            inner = c.c_void_p.from_address(original + 0xb0).value
            native_pixels(None, inner, expected.ctypes.data, source.ctypes.data, len(source), bool(model))
            assert render(context, inputs.ctypes.data, actual.ctypes.data, len(source)) == 0
            row = {"space": space, "model": model, "cct": cct, "gain": gain,
                   "native_shadow": n.array(inner, 0x1b8, (4,)).tolist(), **stats(actual, expected)}
            rows.append(row)
            if space == 0 and model == 0 and cct == 7523.:
                key = "gain_" + str(len(goldens))
                chosen = np.r_[np.arange(0, 65536, 257), np.arange(len(source) - 128, len(source))]
                goldens[key + "_input"] = source[chosen]
                goldens[key + "_expected"] = expected[chosen].copy()
                row["golden_prefix"] = key
            destroy(context); native_delete(original)
        for invalid in [0., -1., float("nan"), float("inf"), -float("inf"), 1e-308, 1e308]:
            assert not clone(parent, invalid), invalid
        destroy(parent)
    assert not clone(None, 1.)
    real = None
    if args.real_vector and args.real_contract:
        vectors = np.load(args.real_vector)
        contract = json.loads(args.real_contract.read_text())["color_contract"]
        old = create(0., contract["cct"], 0, 0)
        context = clone(old, contract["outer_248"])
        assert context
        real_input = np.ascontiguousarray(vectors["source"].astype(np.float64) / 65535.)
        real_output = np.empty_like(vectors["expected"])
        assert render(context, real_input.ctypes.data, real_output.ctypes.data, real_output.size // 3) == 0
        real = {"before": stats(vectors["revision10"], vectors["expected"]),
                "after": stats(real_output, vectors["expected"]),
                "vector_sha256": sha(args.real_vector), "contract_sha256": sha(args.real_contract),
                "effective_gain": contract["outer_248"]}
        goldens["real_input"] = vectors["source"]
        goldens["real_expected"] = vectors["expected"]
        destroy(context); destroy(old)
    n.close()
    report = {"status": "passed" if all(row["maximum_uint16_error"] == 0 for row in rows) and
               (real is None or real["after"]["maximum_uint16_error"] == 0) else "difference-found",
              "cases": rows, "baseline_unit_gain": baseline_checks, "real_crop": real,
              "compile": command, "framework_sha256": {key: sha(verified_framework(key)) for key in FRAMEWORK_HASHES},
              "source_sha256": {str(p.relative_to(root)): sha(p) for p in [Path(__file__), root / "core/hncs.cpp", root / "core/hncs_c.h"]},
              "limits": ["Native color filter's ordinary work domain; no RAW decoder/HDR/ICC equivalence claim.",
                         "Real crop gain came from the original pipeline, not a fit to its output."]}
    np.savez_compressed(out / "native-gain-vectors.npz", **goldens)
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "cases": len(rows), "channels": sum(row["channels"] for row in rows),
        "maximum_error": max(row["maximum_uint16_error"] for row in rows), "baseline_cases": len(baseline_checks), "real": real}, indent=2))
    if report["status"] != "passed": raise SystemExit(1)


if __name__ == "__main__":
    main()
