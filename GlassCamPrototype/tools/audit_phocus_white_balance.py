"""Verify separable Nature WB and WB-driven kernel selection in Phocus 4.2.2.

Calls the hash-locked original arm64 libraries in this disposable process.
Reads original settings; never changes the application, RAW files or sidecars.
The xy samples model a virtual X2D response, not measured iPhone sensor gains.
"""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
import plistlib
import sys

import numpy as np


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--production-library", type=Path,
                        help="Also compare revised C++ contexts against the original selected color kernel")
    args = parser.parse_args()
    reference, out = args.reference_root.resolve(), args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sys.path[:0] = [str(reference), str(reference / "work/hncs-phocus-audit")]
    from native_chain_probe import Native, Vec3
    from native_config_probe import FRAMEWORK_HASHES, LUT, verified_framework
    from preset_curves_probe import NativeCurves

    production = None
    if args.production_library:
        production = c.CDLL(str(args.production_library.resolve()))
        production.hncs_create_preset_whitepoint_with_policy.argtypes = [c.c_double] * 4 + [c.c_int] * 4 + [c.c_char_p, c.c_int, c.c_int]
        production.hncs_create_preset_whitepoint_with_policy.restype = c.c_void_p
        production.hncs_render_native.argtypes = [c.c_void_p] * 3 + [c.c_size_t]
        production.hncs_destroy.argtypes = [c.c_void_p]

    n = Native()
    storage = c.CDLL(str(verified_framework("HBStorage")))
    factory = Path("/Volumes/Phocus/Phocus.app/Contents/Resources/Settings/Standard")
    catalog = json.loads((reference / "work/hncs-pipeline/phocus_presets.json").read_text())
    settings, input_hashes = {}, {}
    for name in ["Standard", "Nature"]:
        path = factory / (name + ".xml")
        assert sha(path) == catalog["source_files"][path.name]["sha256"]
        settings[name] = plistlib.loads(path.read_bytes())["ImageSetting"]["ImageCorrection"]
        input_hashes[str(path)] = sha(path)

    before = NativeCurves(n, storage, settings["Nature"])
    standard = NativeCurves(n, storage, settings["Standard"])
    calculated = c.create_string_buffer(0x1000)
    constructed = False
    try:
        old_bytes = bytes(before.correction)
        original_wb = {"temperature": c.c_int.from_buffer(before.correction, 0x27c).value,
                       "tint": c.c_double.from_buffer(before.correction, 0x280).value}
        tables = before.arrays()
        # DecodeToolFrom tool 7 -> DecodePartFrom part 9. Verified in r2/pdg.
        status = n.fn(storage, "_ZN16CImageCorrection14DecodeToolFromE15eCorrectionToolP9CKeyCoder",
                      [c.c_void_p, c.c_int, c.c_void_p], c.c_int)(before.correction, 7, standard.coder)
        assert status == 0
        changed = [i for i, (a, b) in enumerate(zip(old_bytes, bytes(before.correction))) if a != b]
        assert changed and set(changed) <= set(range(0x27c, 0x280)) | set(range(0x280, 0x288))
        as_shot_wb = {"temperature": c.c_int.from_buffer(before.correction, 0x27c).value,
                      "tint": c.c_double.from_buffer(before.correction, 0x280).value}
        assert original_wb == {"temperature": 5500, "tint": -0.003333333333333333}
        assert as_shot_wb == {"temperature": 0, "tint": 0.0}
        n.fn(n.image, "_ZN17CCalculatedCurvesC1ERK16CImageCorrection",
             [c.c_void_p, c.c_void_p])(calculated, before.correction)
        constructed = True
        curves = {}
        for index, (name, table) in enumerate(tables.items()):
            start = c.c_void_p.from_buffer(calculated, 24 * index).value
            end = c.c_void_p.from_buffer(calculated, 24 * index + 8).value
            assert start and (end - start) // 2 == 65536
            actual = np.ctypeslib.as_array((c.c_uint16 * 65536).from_address(start))
            assert np.array_equal(actual, table), name
            curves[name] = {"entries": len(table), "different_entries": 0,
                            "sha256": hashlib.sha256(table.astype("<u2").tobytes()).hexdigest()}
        separate = {"original": original_wb, "after_WB_tool_only": as_shot_wb,
                    "changed_byte_offsets": [hex(i) for i in changed],
                    "all_other_correction_bytes_unchanged": True, "native_curves": curves}
    finally:
        if constructed:
            delete = n.fn(c.CDLL("/usr/lib/libc++.1.dylib"), "_ZdlPv", [c.c_void_p])
            for index in range(5):
                delete(c.c_void_p.from_buffer(calculated, 24 * index).value)
        before.close()
        standard.close()

    to_gain = n.fn(n.image, "_ZN20CColorTempConversion17TempAndTintToGainE9eCCDTypes13eIRFilterTypeid",
                   [c.c_int, c.c_int, c.c_int, c.c_double], Vec3)
    gain = to_gain(22, 6, original_wb["temperature"], original_wb["tint"])
    nature_gain = np.array([gain.x, gain.y, gain.z])
    response = n.array(c.addressof(n.temp_object), 8, (3, 3))
    ctor = n.fn(n.image, "_ZN19CColorCorrectFilterC1E6CArrayIdLi3E23Matrix3x1InitializationE9eCCDTypes13eIRFilterType14eFilmCurveType11eColorModel13eWorkingSpacedbdbP14CCLCalibration",
                [c.c_void_p, Vec3] + [c.c_int] * 5 + [c.c_double, c.c_bool, c.c_double, c.c_bool, c.c_void_p])
    destructor = n.fn(n.image, "_ZN19CColorCorrectFilterD1Ev", [c.c_void_p])
    native_pixels = n.fn(n.raw, "_ZN14CVectorMethods24ColorNormalCorrectPixelsEP16CColorCorrectionPtS2_ib",
                         [c.c_void_p] * 4 + [c.c_int, c.c_bool])
    source = np.random.default_rng(181026).integers(0, 65536, (8192, 3), dtype=np.uint16)
    source[:256] = np.arange(256, dtype=np.uint16)[:, None] * 257
    source[256:260] = [[65535, 0, 0], [0, 65535, 0], [0, 0, 65535], [65535, 65535, 65535]]
    linear_source = source.astype(np.float64) / 65535.
    rows = []
    samples = [("main", .33209389448165894, .36442223191261292),
               ("tele", .33567193150520325, .37427031993865967),
               ("ultra", .33416590094566345, .3648126423358917),
               ("warm", .44757, .40745), ("D65", .3127, .3290),
               ("magenta_tint", .34, .32), ("green_tint", .34, .38)]
    try:
        for label, x, y in samples:
            neutral = np.linalg.solve(response, [x / y, 1, (1 - x - y) / y])
            capture = neutral[1] / neutral
            for policy, wb in [("photo", capture), ("original_preset", nature_gain)]:
                temperature, tint = n.wb_to_cct(wb)
                for space in [0, 1]:
                    obj = c.create_string_buffer(0x1000)
                    ctor(obj, Vec3(*wb), 22, 6, 2, 0, space, 1.0, False, 1.0, False, None)
                    reference_cc = n.correction(temperature, film=2, model=0, space=space)
                    try:
                        outer = c.c_void_p.from_buffer(obj, 0x48).value
                        assert outer and reference_cc
                        actual = c.c_void_p.from_address(outer + 0xb0).value
                        expected = c.c_void_p.from_address(reference_cc + 0xb0).value
                        errors = {}
                        for name, offset in [("matrix_in", 8), ("matrix_out", 0x50)]:
                            error = float(np.max(np.abs(n.array(actual, offset, (3, 3)) -
                                                       n.array(expected, offset, (3, 3)))))
                            errors[name] = error
                            assert error == 0
                        actual_lut, expected_lut = LUT.from_address(actual + 0x138), LUT.from_address(expected + 0x138)
                        shape = (actual_lut.height, actual_lut.width, 2)
                        assert shape == (expected_lut.height, expected_lut.width, 2)
                        error = float(np.max(np.abs(n.array(actual_lut.data, 0, shape) -
                                                   n.array(expected_lut.data, 0, shape))))
                        errors["lut"] = error
                        assert error == 0
                        if production:
                            context = production.hncs_create_preset_whitepoint_with_policy(0, x, y, 0, space, 0, 4, 2, b"nature", 1,
                                                                                         int(policy == "photo"))
                            assert context
                            try:
                                native_output, cpp_output = np.empty_like(source), np.empty_like(source)
                                native_pixels(None, actual, native_output.ctypes.data, source.ctypes.data, len(source), False)
                                assert production.hncs_render_native(context, linear_source.ctypes.data, cpp_output.ctypes.data, len(source)) == 0
                                error = int(np.max(np.abs(cpp_output.astype(np.int32) - native_output.astype(np.int32))))
                                assert error == 0, (label, policy, space, error)
                                errors["production_uint16_maximum"] = error
                                errors["production_channels"] = cpp_output.size
                            finally:
                                production.hncs_destroy(context)
                        rows.append({"sample": label, "xy": [x, y], "policy": policy,
                                     "working_space": space, "effective_native_gains": wb.tolist(),
                                     "native_gain_to_temperature": temperature, "native_tint": tint,
                                     "constructor_vs_selected_temperature": errors})
                    finally:
                        destructor(obj)
                        if reference_cc:
                            n.fn(n.raw, "_ZN19CRawColorCorrectionD0Ev", [c.c_void_p])(reference_cc)
    finally:
        n.close()
    sources = [Path(__file__), reference / "work/hncs-phocus-audit/native_chain_probe.py",
               reference / "work/hncs-phocus-audit/preset_curves_probe.py",
               reference / "work/hncs-phocus-correction/evidence/colormaps_plain/bohnjuhtuvuvtxyydb56.bin"]
    if args.production_library:
        sources += [args.production_library.resolve(), Path(__file__).resolve().parents[1] / "core/hncs.cpp",
                    Path(__file__).resolve().parents[1] / "core/hncs_c.h"]
    report = {"status": "passed", "phocus_version": "4.2.2", "architecture": "arm64",
              "framework_sha256": {name: sha(verified_framework(name)) for name in FRAMEWORK_HASHES},
              "source_sha256": {**input_hashes, **{str(p): sha(p) for p in sources}},
              "WB_tool_separation": separate, "native_nature_gains": nature_gain.tolist(),
              "kernel_selection": rows,
              "scope": "Native correction/WB tool, all five gradation tables, gain-to-CCT, and actual CColorCorrectFilter-selected matrices/LUT. No claim of native RAW decoding or measured iPhone-to-X2D calibration."}
    (out / "native-white-balance.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: WB-only edit left 327680 native curve entries and all other correction bytes unchanged; {len(rows)} WB-driven native kernel selections matched exactly.")


if __name__ == "__main__":
    main()
