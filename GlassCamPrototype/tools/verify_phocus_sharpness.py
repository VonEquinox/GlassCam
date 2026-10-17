"""Compare reconstructed C++ sharpness tables and pixels to original Phocus.

The original CImageCorrection resolves BaselineSharpness before constructing
CSharpnessFilter. Every expected output is computed by the original library.
No approximate tolerance is used for either tables or UInt16 pixels.
"""
import argparse
import ctypes as c
import hashlib
import itertools
import json
from pathlib import Path
import plistlib
import subprocess
import sys

import numpy as np

from audit_phocus_input_spatial import Filters, delta, sha
from phocus_sharpness_vectors import corpus


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=181019)
    parser.add_argument("--optimization", choices=["O0", "O3"], default="O3")
    parser.add_argument("--hdr-scale", type=float, choices=[1., 5.8829245141], default=1.)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    ref, out = args.reference_root.resolve(), args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sys.path[:0] = [str(ref), str(ref / "work/hncs-phocus-audit")]
    from native_chain_probe import Native
    from native_config_probe import FRAMEWORK_HASHES, verified_framework
    from preset_curves_probe import NativeCurves

    sources = [root / "core/hncs_phocus_sharpness.hpp", root / "tools/phocus_sharpness_model_bridge.cpp",
               root / "tools/native_phocus_filters_bridge.cpp", root / "tools/audit_phocus_input_spatial.py",
               root / "tools/phocus_sharpness_vectors.py", Path(__file__)]
    source_hashes = {str(p): sha(p) for p in sources}
    for name, source in [("model", "phocus_sharpness_model_bridge.cpp"), ("native", "native_phocus_filters_bridge.cpp")]:
        subprocess.run(["xcrun", "clang++", "-std=c++17", "-" + args.optimization, "-fno-fast-math", "-ffp-contract=off",
                        "-Wall", "-Wextra", "-Werror", "-dynamiclib", str(root / "tools" / source),
                        "-o", str(out / (name + ".dylib"))], check=True)
    n = Native()
    native_filters = Filters(n, out / "native.dylib")
    storage = c.CDLL(str(verified_framework("HBStorage")))
    model = c.CDLL(str(out / "model.dylib"))
    model.sharpness_model_create_scaled.argtypes = [c.c_int, c.c_double, c.c_int, c.c_int, c.c_double, c.c_double]
    model.sharpness_model_create_scaled.restype = c.c_void_p
    model.sharpness_model_destroy.argtypes = [c.c_void_p]
    model.sharpness_model_tables.argtypes = [c.c_void_p] * 4
    model.sharpness_model_render.argtypes = [c.c_void_p] * 3 + [c.c_size_t, c.c_size_t]
    model.sharpness_model_amount.argtypes = [c.c_int, c.c_double]
    model.sharpness_model_amount.restype = c.c_double
    factory = Path("/Volumes/Phocus/Phocus.app/Contents/Resources/Settings/Standard/Standard.xml")
    payload = plistlib.loads(factory.read_bytes())["ImageSetting"]["ImageCorrection"]
    settings = NativeCurves(n, storage, payload)
    resolve = n.fn(storage, "_ZNK16CImageCorrection24EffectiveSharpnessAmountEdi",
                    [c.c_void_p, c.c_double, c.c_int], c.c_double)
    inner_ctor = n.fn(n.image, "_ZN15CSharpenAndBlurC1Ejidiiddd",
        [c.c_void_p, c.c_uint, c.c_int, c.c_double, c.c_int, c.c_int, c.c_double, c.c_double, c.c_double])
    filter_ctor = n.fn(n.image, "_ZN16CSharpnessFilterC1Eidiiidd",
        [c.c_void_p, c.c_int, c.c_double, c.c_int, c.c_int, c.c_int, c.c_double, c.c_double])
    inner_delete = n.fn(n.image, "_ZN15CSharpenAndBlurD1Ev", [c.c_void_p])
    cases = list(itertools.product([1, 100, 180, 350], [0., 1., 1.5, 2.], [.8, 1., 4.], [0, 8], [0, 10, 100]))
    cases += [(amount, baseline, radius, noise, dark) for amount, baseline, radius, noise, dark in
              [(0, 1.5, 0., 0, 10), (-100, 1., 1., 0, 10), (1000, 1.5, .2, 255, 1023),
               (100, 1.5, 8., 255, 255), (100, 1.5, -1., 0, 0)]]
    records, failures = [], []
    rng = np.random.default_rng(args.seed)
    patterns = corpus(args.seed)
    pattern_records = []
    vectors = {}
    shapes = [(1, 1), (1, 17), (19, 1), (7, 11), (33, 37), (65, 67)]
    print("Comparing native effective amounts, full tables and image vectors", flush=True)
    for index, (nominal, baseline, radius, noise, dark) in enumerate(cases):
        c.c_int16.from_buffer(settings.correction, 0x262).value = nominal
        native_amount = resolve(settings.correction, baseline, 0)
        cpp_amount = model.sharpness_model_amount(nominal, baseline)
        context = model.sharpness_model_create_scaled(nominal, radius, noise, dark, baseline, args.hdr_scale)
        assert context
        inner, native_filter = c.create_string_buffer(0x1000), c.create_string_buffer(0x1000)
        h, w = shapes[index % len(shapes)]
        inner_ctor(inner, w, int(native_amount), radius, noise, dark, 1., 1., args.hdr_scale)
        filter_ctor(native_filter, int(native_amount), radius, noise, dark, w, 1., args.hdr_scale)
        try:
            def table(offset, dtype, count):
                address = c.c_void_p.from_buffer(inner, offset).value
                return np.ctypeslib.as_array((dtype*count).from_address(address)).copy()
            count = c.c_ubyte.from_buffer(inner, 0x170).value
            original_amount = table(0x10, c.c_int32, 16384)
            original_noise = table(0x168, c.c_uint8, 16384)
            original_weights = table(0xb0, c.c_uint32, count)
            actual_amount = np.empty(16384, np.int32)
            actual_noise = np.empty(16384, np.uint8)
            actual_weights = np.empty(9, np.uint32)
            cpp_count = model.sharpness_model_tables(context, actual_amount.ctypes.data, actual_noise.ctypes.data, actual_weights.ctypes.data)
            table_errors = {"amount": int(np.count_nonzero(original_amount != actual_amount)),
                            "noise": int(np.count_nonzero(original_noise != actual_noise)),
                            "weights": int(np.count_nonzero(original_weights != actual_weights[:count])) if cpp_count == count else -1}
            source = rng.integers(0, 65536, (h, w, 3), dtype=np.uint16)
            source[0, 0] = [0, 1, 65535]
            halo = max(4, c.c_int.from_buffer(native_filter, 0x70).value)
            padded = native_filters.pad(source, halo)
            np.testing.assert_array_equal(padded, np.pad(source, ((halo, halo), (halo, halo), (0, 0)), mode="edge"))
            expected = native_filters.run(native_filter, "_ZNK16CSharpnessFilter12FilterResultE6CXRectS0_NSt3__110unique_ptrI14CBufferedImageNS1_14default_deleteIS3_EEEES6_", padded, (halo, halo, w, h))
            actual = np.empty_like(source)
            assert model.sharpness_model_render(context, source.ctypes.data, actual.ctypes.data, w, h) == 0
            row = {"nominal_amount": nominal, "baseline_sharpness": baseline, "radius": radius,
                   "noise_limit": noise, "dark_limit": dark, "native_effective_amount": native_amount,
                   "cpp_effective_amount": cpp_amount, "effective_amount_error": abs(native_amount-cpp_amount),
                   "table_mismatches": table_errors, "shape": [h, w, 3], "pixels": delta(actual, expected)}
            records.append(row)
            if any(table_errors.values()) or native_amount != cpp_amount or row["pixels"]["maximum_uint16_error"]:
                sample = np.flatnonzero(original_amount != actual_amount)[:6]
                row["amount_examples"] = [{"index": int(i), "native": int(original_amount[i]), "cpp": int(actual_amount[i])} for i in sample]
                failures.append(row)
                if len(failures) <= 4: print(json.dumps(row), flush=True)
            if baseline == 1.5 and nominal in [100, 180] and radius in [.8, 1.] and noise == 0 and dark == 10:
                label = f"a{nominal}_r{radius}"
                vectors[label+"_source"] = source
                vectors[label+"_native"] = expected
                vectors[label+"_amount_table"] = original_amount
                vectors[label+"_noise_table"] = original_noise
                vectors[label+"_weights"] = original_weights
            if (nominal, baseline, radius, noise, dark) in [(100, 1.5, 1., 0, 10), (180, 1.5, .8, 0, 10)]:
                for name, pixels in patterns.items():
                    ph, pw = pixels.shape[:2]
                    padded = native_filters.pad(pixels, halo)
                    original = native_filters.run(native_filter, "_ZNK16CSharpnessFilter12FilterResultE6CXRectS0_NSt3__110unique_ptrI14CBufferedImageNS1_14default_deleteIS3_EEEES6_", padded, (halo, halo, pw, ph))
                    actual_pattern = np.empty_like(pixels)
                    assert model.sharpness_model_render(context, pixels.ctypes.data, actual_pattern.ctypes.data, pw, ph) == 0
                    error = delta(actual_pattern, original)
                    pattern_records.append({"nominal_amount": nominal, "baseline_sharpness": baseline,
                                            "pattern": name, "shape": list(pixels.shape), **error})
                    if error["maximum_uint16_error"]: failures.append(pattern_records[-1])
        finally:
            model.sharpness_model_destroy(context)
            inner_delete(inner)
            native_filters.destroy(native_filter)
    settings.close()
    n.close()
    assert source_hashes == {str(p): sha(p) for p in sources}
    np.savez_compressed(out / "native-vectors.npz", **vectors)
    report = {"status": "passed" if not failures else "mismatch", "cases": records,
              "seed": args.seed, "optimization": args.optimization, "hdr_scale": args.hdr_scale, "patterns": pattern_records,
              "framework_sha256": {name: sha(verified_framework(name)) for name in FRAMEWORK_HASHES},
              "source_sha256": source_hashes, "vectors_sha256": sha(out / "native-vectors.npz"),
              "summary": {"cases": len(records), "failures": len(failures), "pixel_channels": sum(row["pixels"]["channels"] for row in records),
                          "table_entries": len(records)*32768, "pattern_cases": len(pattern_records),
                          "pattern_channels": sum(row["channels"] for row in pattern_records),
                          "maximum_uint16_error": max([row["pixels"]["maximum_uint16_error"] for row in records] + [row["maximum_uint16_error"] for row in pattern_records]),
                          "maximum_effective_amount_error": max(row["effective_amount_error"] for row in records)},
              "scope": "Original CPU CSharpnessFilter at full-resolution image scale 1, explicitly recorded HDR domain factor, original CRepeatMarginFilter RGB boundary, no local layers or lens sharpness compensation. Separate integration checks exercise the production API."}
    (out / "report.json").write_text(json.dumps(report, indent=2)+"\n")
    print(json.dumps(report["summary"], indent=2), flush=True)
    if failures: raise SystemExit("Original native sharpness mismatch; inspect report.json")


if __name__ == "__main__":
    main()
