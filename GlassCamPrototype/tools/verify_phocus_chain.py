"""Verify the production color -> gradation -> sharpness -> final-color chain.

Original Phocus computes every expected work code, including its margin filter.
The declared virtual source matrix is an input adapter, not sensor calibration.
Display conversion is checked separately against the existing exact C++ output
transform; this does not claim Phocus's ICC export or HDR engine is reproduced.
"""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

import numpy as np
from audit_phocus_input_spatial import Filters, delta, sha
from audit_phocus_post_stages import NativePostStages
from audit_phocus_sharpness_settings import native_settings
from phocus_sharpness_vectors import corpus


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20261018)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    ref, out = args.reference_root.resolve(), args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sys.path[:0] = [str(ref), str(ref / "work/hncs-phocus-audit")]
    from native_chain_probe import Native
    from native_config_probe import FRAMEWORK_HASHES, verified_framework
    from preset_curves_probe import NativeCurves, correction_payload, bridge
    import phocus_presets as presets
    paths = sorted(set([*root.joinpath("core").glob("hncs*"),
        *[root / "tools" / name for name in ["native_phocus_filters_bridge.cpp", "audit_phocus_input_spatial.py",
           "audit_phocus_post_stages.py", "audit_phocus_sharpness_settings.py", "phocus_sharpness_vectors.py", "verify_phocus_chain.py"]]]))
    hashes = {str(p): sha(p) for p in paths if p.is_file()}
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-O3", "-fno-fast-math", "-ffp-contract=off",
        "-Wall", "-Wextra", "-Werror", "-dynamiclib", *[str(root / "core" / p) for p in
        ["hncs.cpp", "hncs_spatial.cpp", "hncs_numpy_rng.cpp"]], "-o", str(out / "core.dylib")], check=True)
    for source, destination in [(root / "tools/native_phocus_filters_bridge.cpp", "native.dylib"),
                                (ref / "work/hncs-phocus-audit/preset_filter_bridge.cpp", "gradation.dylib")]:
        subprocess.run(["xcrun", "clang++", "-std=c++17", "-O2", "-dynamiclib", str(source), "-o", str(out / destination)], check=True)
    lib = c.CDLL(str(out / "core.dylib"))
    def bind(name, params, result=c.c_int):
        fn = getattr(lib, name); fn.argtypes = params; fn.restype = result; return fn
    create = bind("hncs_create_preset", [c.c_double] * 3 + [c.c_int] * 4 + [c.c_char_p, c.c_int, c.c_void_p, c.c_void_p], c.c_void_p)
    destroy = bind("hncs_destroy", [c.c_void_p], None)
    matrix = bind("hncs_source_to_native_matrix", [c.c_void_p] * 2)
    wb = bind("hncs_preset_white_balance", [c.c_void_p] * 4)
    prepare = bind("hncs_process_phocus_work_float", [c.c_void_p] * 3 + [c.c_size_t])
    finish = bind("hncs_finish_phocus_work_linear", [c.c_void_p] * 3 + [c.c_size_t])
    display = bind("hncs_finish_preset_work_linear", [c.c_void_p] * 3 + [c.c_size_t])
    combined = bind("hncs_process_phocus_linear_rgba", [c.c_void_p] * 3 + [c.c_size_t])
    post = bind("hncs_apply_phocus_post_spatial", [c.c_char_p, c.c_void_p, c.c_void_p, c.c_size_t])
    mem = bind("hncs_apply_spatial_native_sharpness", [c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_int, c.c_int, c.c_double])
    callback = c.CFUNCTYPE(c.c_int, c.c_void_p)
    file = bind("hncs_apply_spatial_native_sharpness_file", [c.c_char_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_int, c.c_int, c.c_double, c.c_char_p, callback, c.c_void_p])
    n = Native(); storage = c.CDLL(str(verified_framework("HBStorage")))
    filters = Filters(n, out / "native.dylib")
    gradation = bridge(n, out / "gradation.dylib")
    pixels = n.fn(n.raw, "_ZN14CVectorMethods24ColorNormalCorrectPixelsEP16CColorCorrectionPtS2_ib", [c.c_void_p] * 4 + [c.c_int, c.c_bool])
    delete = n.fn(n.raw, "_ZN19CRawColorCorrectionD0Ev", [c.c_void_p])
    amount = n.fn(storage, "_ZNK16CImageCorrection24EffectiveSharpnessAmountEdi", [c.c_void_p, c.c_double, c.c_int], c.c_double)
    ctor = n.fn(n.image, "_ZN16CSharpnessFilterC1Eidiiidd", [c.c_void_p, c.c_int, c.c_double, c.c_int, c.c_int, c.c_int, c.c_double, c.c_double])
    factory = Path("/Volumes/Phocus/Phocus.app/Contents/Resources/Settings/Standard")
    baseline = plistlib.loads((factory / "Standard.xml").read_bytes())["ImageSetting"]["ImageCorrection"]
    patterns = corpus(args.seed)
    presets_to_check = ["standard", "nature", "saturated", "grayscale-red-filter", "grayscale-green-filter",
                        "grayscale-blue-filter", "high", "film-grain-artistic"]
    rows, vectors, vector_cases = [], {}, []
    with tempfile.TemporaryDirectory(prefix="phocus-chain-") as temporary:
      work_path = Path(temporary) / "work.rgbf"
      for preset_index, key in enumerate(presets_to_check):
        filename = presets.FACTORY_SETTING_FILES[presets.settings(key)["name"]]
        original = plistlib.loads((factory / filename).read_bytes())
        assert sha(factory / filename) == presets.catalog()["source_files"][filename]["sha256"]
        for space in [0, 1]:
          for tone in [False, True]:
            ev = -.7 if (preset_index + space + tone) % 2 else 0.
            capture_cct = [2850., 5119., 7523.][(preset_index + space) % 3]
            context = create(ev, capture_cct, 0., space, 0, 4, 2, key.encode(), int(tone), None, None)
            assert context
            transform = np.empty((3, 3), np.float64); assert matrix(context, transform.ctypes.data) == 0
            baseline_wb, target_wb = (c.c_double * 3)(), (c.c_double * 3)(); factory_cct = c.c_double()
            assert wb(context, baseline_wb, target_wb, c.byref(factory_cct)) == 0
            outer = n.correction(factory_cct.value, film=2, model=0, hdr=False, space=space)
            assert outer
            cc = c.c_void_p.from_address(outer + 0xb0).value
            settings = NativeCurves(n, storage, correction_payload({"plist": original}, baseline, tone))
            sharp = native_settings(n, storage, settings.correction)
            final_stages = NativePostStages(n, storage, filters, settings.correction)
            try:
              for raw_baseline in [0., 1.5]:
                effective = amount(settings.correction, raw_baseline, 0)
                selected = patterns if key in ["standard", "nature"] and tone and space == 1 and raw_baseline == 1.5 else {
                    name: patterns[name] for name in ["color-edge", "dark-noise", "corners-and-center", "boundary-7x131", "random"]}
                for pattern, codes in selected.items():
                  h, w = codes.shape[:2]; count = h * w
                  source = codes.astype(np.float32) / np.float32(65535.)
                  scaled = source.astype(np.float64) * (2. ** ev)
                  native_input = np.empty_like(scaled)
                  for ch in range(3):
                    native_input[..., ch] = (scaled[..., 0] * transform[ch, 0] + scaled[..., 1] * transform[ch, 1]) + scaled[..., 2] * transform[ch, 2]
                  native_input = np.rint(np.clip(native_input, 0, 1) * 65535.).astype(np.uint16)
                  native_color = np.empty_like(codes)
                  pixels(None, cc, native_color.ctypes.data, native_input.ctypes.data, count, False)
                  native_curve = gradation(settings, native_color)
                  actual_work = np.empty_like(source)
                  assert prepare(context, source.ctypes.data, actual_work.ctypes.data, count) == 0
                  expected_work = native_curve.astype(np.float32) / np.float32(65535.)
                  np.testing.assert_array_equal(actual_work.view(np.uint32), expected_work.view(np.uint32))
                  for enabled in [False, True]:
                    expected_sharp = native_curve.copy()
                    if enabled and sharp["enabled"] and effective > 0:
                        obj = c.create_string_buffer(0x1000)
                        ctor(obj, int(effective), sharp["radius"] / 10., sharp["noise_limit"], sharp["dark_limit"], w, 1., 1.)
                        try:
                            halo = max(4, c.c_int.from_buffer(obj, 0x70).value)
                            expected_sharp = filters.run(obj, "_ZNK16CSharpnessFilter12FilterResultE6CXRectS0_NSt3__110unique_ptrI14CBufferedImageNS1_14default_deleteIS3_EEEES6_", filters.pad(native_curve, halo), (halo, halo, w, h))
                        finally: filters.destroy(obj)
                    native_final = final_stages.run(expected_sharp)
                    memory = actual_work.copy()
                    assert mem(memory.ctypes.data, w, h, key.encode(), 0, int(enabled), raw_baseline) == 0
                    actual_work.tofile(work_path)
                    assert file(str(work_path).encode(), w, h, key.encode(), 0, int(enabled), raw_baseline, temporary.encode(), callback(), None) == 0
                    disk = np.fromfile(work_path, dtype=np.float32).reshape(source.shape)
                    np.testing.assert_array_equal(memory.view(np.uint32), disk.view(np.uint32))
                    np.testing.assert_array_equal(memory.view(np.uint32), (expected_sharp.astype(np.float32) / np.float32(65535.)).view(np.uint32))
                    memory_codes = np.rint(np.clip(memory, 0, 1) * np.float32(65535.)).astype(np.uint16)
                    actual_final = np.empty_like(codes)
                    assert post(key.encode(), memory_codes.ctypes.data, actual_final.ctypes.data, count) == 0
                    error = delta(actual_final, native_final)
                    assert error["maximum_uint16_error"] == 0, (key, pattern, raw_baseline, error)
                    rgba = np.empty((h, w, 4), np.float32)
                    expected_rgba = np.empty_like(rgba)
                    final_work = native_final.astype(np.float32) / np.float32(65535.)
                    assert finish(context, memory.ctypes.data, rgba.ctypes.data, count) == 0
                    assert display(context, final_work.ctypes.data, expected_rgba.ctypes.data, count) == 0
                    np.testing.assert_array_equal(rgba.view(np.uint32), expected_rgba.view(np.uint32))
                    if not enabled:
                        direct = np.empty_like(rgba)
                        assert combined(context, source.ctypes.data, direct.ctypes.data, count) == 0
                        np.testing.assert_array_equal(direct.view(np.uint32), rgba.view(np.uint32))
                    row = {"preset": key, "space": space, "tone": tone, "exposure_ev": ev,
                           "capture_cct": capture_cct, "factory_cct": factory_cct.value,
                           "baseline_sharpness": raw_baseline, "sharpness": enabled, "pattern": pattern,
                           "shape": [h, w, 3], **error}
                    rows.append(row)
                    if tone and space == 1 and raw_baseline == 1.5 and enabled and pattern == "color-edge":
                        name = "case" + str(len(vector_cases))
                        vectors[name + "_source"] = source
                        vectors[name + "_work"] = expected_work
                        vectors[name + "_sharpness"] = expected_sharp
                        vectors[name + "_final_codes"] = native_final
                        vector_cases.append(dict(row, vector_key=name))
            finally:
                final_stages.close(); settings.close(); delete(outer); destroy(context)
        print("Verified composed", key, flush=True)
    n.close()
    assert hashes == {str(p): sha(p) for p in paths if p.is_file()}
    np.savez_compressed(out / "native-vectors.npz", **vectors)
    report = {"status": "passed", "seed": args.seed, "source_sha256": hashes,
              "framework_sha256": {name: sha(verified_framework(name)) for name in FRAMEWORK_HASHES},
              "cases": rows, "native_vector_cases": vector_cases, "vectors_sha256": sha(out / "native-vectors.npz"),
              "summary": {"cases": len(rows), "channels": sum(r["channels"] for r in rows), "maximum_uint16_error": 0,
                          "work_float_bit_mismatches": 0, "memory_file_bit_mismatches": 0, "final_display_route_bit_mismatches": 0},
              "scope": "Original non-HDR color core, gradation, RGB margins, USM, global saturation and grayscale; full-resolution scale and no local layers, selective points, vibrance or lens compensation. Grain disabled here; its portable implementation has separate parity tests. The virtual source adapter and existing C++ display conversion are explicit boundary contracts, not cross-camera or native ICC/HDR equivalence."}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))


if __name__ == "__main__":
    main()
