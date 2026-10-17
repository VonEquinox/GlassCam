"""Compare GlassCam C++ directly with hash-locked Phocus 4.2.2 arm64 binaries.

Uses synthetic numeric vectors, original factory resources and existing native
ABI probes. No photograph is rendered and no image appearance is scored.
Run in a separate process: native objects and cached configuration are private
to this diagnostic process, never attached to the running Phocus application.
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
from datetime import datetime, timezone

import numpy as np


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def bind(lib, name, args, result=c.c_int):
    function = getattr(lib, name)
    function.argtypes, function.restype = args, result
    return function


def difference(actual, expected, source=None):
    signed = actual.astype(np.int32) - expected.astype(np.int32)
    delta = np.abs(signed)
    values, counts = np.unique(signed, return_counts=True)
    result = {"pixels": int(len(actual)), "channels": int(actual.size),
              "different_channels": int(np.count_nonzero(delta)), "maximum_uint16_error": int(delta.max()),
              "signed_error_range": [int(values[0]), int(values[-1])]}
    if len(values) <= 17:
        result["signed_error_histogram"] = {str(v): int(n) for v, n in zip(values, counts)}
    if source is not None:
        indices = np.flatnonzero(np.any(delta != 0, axis=1))[:8]
        result["difference_examples"] = [{"index": int(i), "input": source[i].tolist(),
                                          "native": expected[i].tolist(), "cpp": actual[i].tolist()}
                                         for i in indices]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--core-source", type=Path, help="Optional standalone candidate hncs.cpp; includes still come from this repository's core directory")
    parser.add_argument("--random-pixels", type=int, default=32768)
    parser.add_argument("--seed", type=int, default=20261017)
    parser.add_argument("--all-presets", action="store_true", help="Compare original gradation filters for every distinct factory XML payload")
    args = parser.parse_args()
    reference, out = args.reference_root.resolve(), args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[1]
    core_source = args.core_source.resolve() if args.core_source else repo / "core/hncs.cpp"
    if not 1 <= args.random_pixels <= 10_000_000:
        parser.error("--random-pixels must be between 1 and 10000000")
    probes = reference / "work/hncs-phocus-audit"
    sys.path[:0] = [str(reference), str(probes)]
    from native_config_probe import FRAMEWORK_HASHES, verified_framework
    from native_chain_probe import Native, Vec3
    from preset_curves_probe import NativeCurves, bridge, correction_payload
    from phocus_presets import FACTORY_SETTING_FILES

    app = Path("/Volumes/Phocus/Phocus.app")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != "4.2.2":
        raise ValueError("This native ABI probe is restricted to Phocus 4.2.2")
    binaries = {name: verified_framework(name) for name in FRAMEWORK_HASHES}
    binaries["Phocus"] = app / "Contents/MacOS/Phocus"
    report = {"schema": 2, "created_at": datetime.now(timezone.utc).isoformat(),
              "phocus_version": "4.2.2", "architecture": "arm64",
              "binaries": {name: {"path": str(path), "sha256": digest(path)} for name, path in binaries.items()}}
    source_files = [core_source, repo / "core/hncs_c.h", repo / "core/hncs_phocus_post.hpp", *sorted((repo / "core").glob("hncs*assets.inc")),
                    Path(__file__), probes / "native_chain_probe.py", probes / "native_config_probe.py",
                    probes / "preset_curves_probe.py", probes / "preset_filter_bridge.cpp", reference / "phocus_presets.py"]
    report["source_sha256"] = {str(path): digest(path) for path in source_files}
    factory = app / "Contents/Resources/Settings/Standard"
    catalog = json.loads((reference / "work/hncs-pipeline/phocus_presets.json").read_text())
    presets, resource_hashes = {}, {}
    preset_files = {key: FACTORY_SETTING_FILES[key] for key in ["standard", "nature"]}
    if args.all_presets:
        for key, name in FACTORY_SETTING_FILES.items():
            if name not in preset_files.values():
                preset_files[key] = name
    for key, name in preset_files.items():
        path = factory / name
        if digest(path) != catalog["source_files"][name]["sha256"]:
            raise ValueError("Factory resource changed")
        presets[key] = plistlib.loads(path.read_bytes())
        resource_hashes[key] = {"path": str(path), "sha256": digest(path)}
    report["factory_resources"] = resource_hashes
    config = reference / "work/hncs-phocus-correction/evidence/colormaps_plain/bohnjuhtuvuvtxyydb56.bin"
    expected_config = json.loads((reference / "work/hncs-pipeline/assets/provenance.json").read_text())["colormap_sha256"]
    if digest(config) != expected_config:
        raise ValueError("Recovered original factory configuration changed")
    report["native_configuration"] = {"path": str(config), "sha256": expected_config,
        "note": "Previously recovered original X2D II factory plist, parsed by native CXMLLut; no generated matrices or LUTs are injected into correction objects."}

    cpp_path, bridge_path = out / "glasscam-core.dylib", out / "native-gradation-bridge.dylib"
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-O3", "-fno-fast-math", "-ffp-contract=off",
                    "-dynamiclib", "-I", str(repo / "core"), str(core_source), "-lz", "-pthread", "-o", str(cpp_path)], check=True)
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-O2", "-dynamiclib",
                    str(probes / "preset_filter_bridge.cpp"), "-o", str(bridge_path)], check=True)
    cpp = c.CDLL(str(cpp_path))
    create = bind(cpp, "hncs_create_preset", [c.c_double] * 3 + [c.c_int] * 4 + [c.c_char_p, c.c_int, c.c_void_p, c.c_void_p], c.c_void_p)
    destroy = bind(cpp, "hncs_destroy", [c.c_void_p], None)
    render = bind(cpp, "hncs_render_native", [c.c_void_p] * 3 + [c.c_size_t])
    render_preset = bind(cpp, "hncs_render_native_preset", [c.c_void_p] * 3 + [c.c_size_t])
    post = bind(cpp, "hncs_apply_post_curves", [c.c_char_p, c.c_int, c.c_void_p, c.c_void_p, c.c_size_t])
    whitepoint = bind(cpp, "hncs_whitepoint_parameters", [c.c_double, c.c_double, c.c_void_p, c.c_void_p])
    create_white = bind(cpp, "hncs_create_preset_whitepoint", [c.c_double] * 4 + [c.c_int] * 4 + [c.c_char_p, c.c_int], c.c_void_p)
    get_wb = bind(cpp, "hncs_preset_white_balance", [c.c_void_p] * 4)
    get_matrix = bind(cpp, "hncs_source_to_native_matrix", [c.c_void_p, c.c_void_p])

    n = Native()
    storage = c.CDLL(str(binaries["HBStorage"]))
    native_filter = bridge(n, bridge_path)
    native_pixels = n.fn(n.raw, "_ZN14CVectorMethods24ColorNormalCorrectPixelsEP16CColorCorrectionPtS2_ib",
                         [c.c_void_p] * 4 + [c.c_int, c.c_bool])
    delete_correction = n.fn(n.raw, "_ZN19CRawColorCorrectionD0Ev", [c.c_void_p])
    wb_function = n.fn(n.image, "_ZN20CColorTempConversion17TempAndTintToGainE9eCCDTypes13eIRFilterTypeid",
                       [c.c_int, c.c_int, c.c_int, c.c_double], Vec3)
    response = n.array(c.addressof(n.temp_object), 8, (3, 3))

    levels = np.rint(np.linspace(0, 65535, 33)).astype(np.uint16)
    cube = np.array(list(itertools.product(levels, repeat=3)), dtype=np.uint16)
    ramp = np.repeat(np.arange(65536, dtype=np.uint16)[:, None], 3, axis=1)
    random = np.random.default_rng(args.seed).integers(0, 65536, (args.random_pixels, 3), dtype=np.uint16)
    source = np.ascontiguousarray(np.concatenate([ramp, cube, random]))
    normalized = np.ascontiguousarray(source.astype(np.float64) / 65535.)
    report["vectors"] = {"seed": args.seed, "gray_levels": 65536, "rgb_cube_grid": 33, "rgb_cube_pixels": len(cube),
                         "random_pixels": len(random), "pixels_per_case": len(source), "sha256": hashlib.sha256(source.tobytes()).hexdigest()}
    print("Original-binary/C++ core comparisons", flush=True)
    core_records = []
    cases = [(space, model, temp, 7 if model else 2) for space, model, temp in
             itertools.product([0, 1], [0, 1], [1000, 2000, 2993, 5119, 5500, 7523, 10000, 11000])]
    cases += [(space, 0, 5500, film) for space, film in itertools.product([0, 1], [0, 7])]
    for space, model, temp, film in cases:
        outer = n.correction(temp, film=film, model=model, hdr=False, space=space)
        if not outer:
            raise ValueError("Native color correction could not be constructed")
        cc = c.c_void_p.from_address(outer + 0xb0).value
        expected = np.empty_like(source)
        native_pixels(None, cc, expected.ctypes.data, source.ctypes.data, len(source), bool(model))
        context = create(0, temp, temp, space, model, film, 2, b"standard", 1, None, None)
        if not context:
            raise ValueError("GlassCam context could not be constructed")
        actual = np.empty_like(source)
        assert render(context, normalized.ctypes.data, actual.ctypes.data, len(source)) == 0
        row = {"working_space": "lstar" if space else "legacy", "color_model": model, "cct": temp,
               "film_curve": film, **difference(actual, expected, source),
               "native_gray_thresholds": n.array(cc, 0xe0, (2,)).tolist(),
               "native_shadow_parameters": n.array(cc, 0x1b8, (4,)).tolist()}
        core_records.append(row)
        destroy(context)
        delete_correction(outer)
    report["core_comparisons"] = core_records

    print("Original native gradation filter/C++ preset comparisons", flush=True)
    post_records, full_records = [], []
    baseline = presets["standard"]["ImageSetting"]["ImageCorrection"]
    for key in presets:
        for tone in [True, False]:
            payload = correction_payload({"plist": presets[key]}, baseline, tone)
            curves = NativeCurves(n, storage, payload)
            # The native constructor only disables the filter for a null
            # CCalculatedCurves pointer, not for an identity user curve.
            # AddPostViewerRGBFilters passes ExposureToolVersion > 2 as the
            # RecoverHue switch; both original resources use version 4.
            filter_object = c.create_string_buffer(0x1000)
            shared_curve = (c.c_void_p * 2)(c.addressof(curves.curves), None)
            version = c.c_int.from_buffer(curves.correction, 0x408).value
            n.fn(n.image, "_ZN16CGradationFilterC1ENSt3__110shared_ptrIK17CCalculatedCurvesEEb",
                 [c.c_void_p, c.c_void_p, c.c_bool])(filter_object, shared_curve, version > 2)
            construction = {"exposure_tool_version": version,
                            "filter_enabled": bool(c.c_ubyte.from_buffer(filter_object, 0x38).value),
                            "recover_hue": bool(c.c_ubyte.from_buffer(filter_object, 0xec).value)}
            c.CFUNCTYPE(None, c.c_void_p)(n.image_base + 0x47d84)(filter_object)
            assert construction["filter_enabled"] and construction["recover_hue"]
            identity = np.arange(65536, dtype=np.uint16)
            tables = curves.arrays()
            expected = native_filter(curves, source)
            actual = np.empty_like(source)
            assert post(key.encode(), int(tone), source.ctypes.data, actual.ctypes.data, len(source)) == 0
            post_records.append({"preset": key, "apply_tone_curve": tone, **difference(actual, expected, source),
                                 "native_filter_construction": construction,
                                 "table_difference_from_identity": {name: difference(table[:, None], identity[:, None])
                                                                    for name, table in tables.items()},
                                 "native_settings": curves.settings(),
                                 "gray_ramp_samples": [{"input": i, "output": expected[i].tolist()} for i in [0, 16384, 32768, 49152, 65535]]})
            full_cases = itertools.product([0, 1], [2993, 5119, 7523]) if key in ["standard", "nature"] else []
            for space, temp in full_cases:
                factory_temp = payload.get("ColorTemperature") or temp
                outer = n.correction(factory_temp, film=2, model=0, hdr=False, space=space)
                cc = c.c_void_p.from_address(outer + 0xb0).value
                core = np.empty_like(source)
                native_pixels(None, cc, core.ctypes.data, source.ctypes.data, len(source), False)
                expected = native_filter(curves, core)
                context = create(0, temp, factory_temp, space, 0, 4, 2, key.encode(), int(tone), None, None)
                assert context and render_preset(context, normalized.ctypes.data, actual.ctypes.data, len(source)) == 0
                full_records.append({"preset": key, "apply_tone_curve": tone, "capture_cct_label": temp,
                    "factory_cct": factory_temp, "working_space": "lstar" if space else "legacy", **difference(actual, expected, source)})
                destroy(context)
                delete_correction(outer)
            curves.close()
    report["post_curve_comparisons"], report["core_plus_preset_comparisons"] = post_records, full_records

    print("White-point and original preset WB semantics", flush=True)
    wb_records = []
    for capture_cct, tint in [(2993, .004333333333333333), (5500, 0.), (7523, -.003), (2850, 0.), (6500, -.003333333333333333)]:
        value = wb_function(22, 6, capture_cct, tint)
        native_wb = np.array([value.x, value.y, value.z]); native_wb /= native_wb[1]
        tristimulus = response @ (1 / native_wb)
        xy = tristimulus[:2] / tristimulus.sum()
        expected_cct = min(10000, max(2000, n.wb_to_cct(native_wb)[0]))
        baseline_wb = np.empty(3); actual_cct = c.c_double()
        assert whitepoint(*xy, baseline_wb.ctypes.data, c.byref(actual_cct)) == 0
        for key in ["standard", "nature"]:
            context = create_white(0, *xy, 0, 1, 0, 4, 2, key.encode(), 1)
            capture_wb, target_wb, matrix = np.empty(3), np.empty(3), np.empty((3, 3))
            factory_cct = c.c_double()
            assert context and get_wb(context, capture_wb.ctypes.data, target_wb.ctypes.data, c.byref(factory_cct)) == 0
            assert get_matrix(context, matrix.ctypes.data) == 0
            preset = presets[key]["ImageSetting"]["ImageCorrection"]
            desired = native_wb
            if preset["ColorTemperature"]:
                value = wb_function(22, 6, preset["ColorTemperature"], preset["Tint"])
                desired = np.array([value.x, value.y, value.z]); desired /= desired[1]
            wb_records.append({"preset": key, "capture_temperature": capture_cct, "capture_tint": tint,
                "derived_xy": xy.tolist(), "native_cct": expected_cct, "cpp_capture_cct": actual_cct.value,
                "cpp_factory_cct": factory_cct.value, "native_capture_gains": native_wb.tolist(), "cpp_capture_gains": capture_wb.tolist(),
                "native_target_gains": desired.tolist(), "cpp_target_gains": target_wb.tolist(),
                "capture_gain_max_error": float(np.max(abs(capture_wb - native_wb))),
                "target_gain_max_error": float(np.max(abs(target_wb - desired))),
                "neutral_axis_max_error": float(np.max(abs(matrix @ np.ones(3) - target_wb / capture_wb)))})
            destroy(context)
    report["white_balance_comparisons"] = wb_records

    print("Native shadow weight and automatic film selection", flush=True)
    gray_weight = n.fn(n.raw, "_ZNK16CColorCorrection19CalculateGrayWeightEddb",
                       [c.c_void_p, c.c_double, c.c_double, c.c_bool], c.c_double)
    shadow_records = []
    for model in [0, 1]:
        outer = n.correction(5500, film=7 if model else 2, model=model, hdr=False, space=0)
        cc = c.c_void_p.from_address(outer + 0xb0).value
        threshold, a, b, d = n.array(cc, 0x1b8, (4,))
        assert n.array(cc, 0xe0, (2,)).tolist() == [0., 0.]
        for y, saturation in itertools.product([0, 1, 3875, 7750, 11625, 15499, 15500, 15501, 32768, 65535],
                                               [0., .02, .5, 2.]):
            actual = gray_weight(cc, y, saturation, bool(model))
            expected = 1. if model or y > threshold else max(0., min(1., (a*y)*y + b*y + d))
            shadow_records.append({"color_model": model, "Y_code": y, "input_saturation": saturation,
                                   "native_chroma_weight": actual, "polynomial_error": abs(actual-expected)})
        delete_correction(outer)
    report["shadow_weight_probe"] = {"cases": shadow_records,
        "operation": "ColorNormalCorrectPixels applies CalculateGrayWeight to the mapped chroma terms; Y is retained as the reconstruction baseline before the film curve.",
        "assembly_locations": {"CalculateGrayWeight": "HBRawCorrections arm64 0x30e58",
                               "chroma_multiply": "HBRawCorrections arm64 0x32ba8",
                               "Y_reconstruction": "HBRawCorrections arm64 0x32bc4"}}

    film_records = []
    effective_film = n.fn(storage, "_ZNK16CImageCorrection18EffectiveFilmCurveE14eFilmCurveType",
                          [c.c_void_p, c.c_int], c.c_int)
    curves = NativeCurves(n, storage, baseline)
    for model, requested, raw in itertools.product([0, 1], [0, 1, 2, 4, 6, 7], [0, 2, 4, 7, 99]):
        c.c_int.from_buffer(curves.correction, 0x2a8).value = model
        c.c_int.from_buffer(curves.correction, 0x2ac).value = requested
        native = effective_film(curves.correction, raw)
        cpp_selection = 7 if model else raw if requested == 4 else requested
        film_records.append({"color_model": model, "requested": requested, "raw_film_type": raw,
                             "native_effective_film": native, "cpp_selection": cpp_selection})
    curves.close()
    report["film_selection_probe"] = film_records

    payload = presets["nature"]["ImageSetting"]["ImageCorrection"]
    report["nature_parameters_from_original_resource"] = {key: payload[key] for key in
        ["ColorTemperature", "Tint", "EV", "FilmCurve", "USMAmount", "USMRadius", "VignetteAmount", "LensCorrection", "Gradations"]}
    report["scope"] = {"compared": "Original non-HDR X2D II native color core, original CGradationFilter, and virtual-whitepoint/preset gain semantics versus the recorded C++ source.",
        "not_covered": ["Full native RAW demosaic, lens, spatial sharpening, or HDR chain equivalence.",
                        "Physical iPhone-to-Hasselblad sensor calibration or all-scene color accuracy.",
                        "The native-input APIs tested here take already normalized and white-balanced native RGB; no Apple RAW pixels are used."]}
    all_numeric = core_records + post_records + full_records
    report["summary"] = {"core_cases": len(core_records), "post_curve_cases": len(post_records),
        "core_plus_preset_cases": len(full_records), "total_compared_channels": sum(row["channels"] for row in all_numeric),
        "different_channels": sum(row["different_channels"] for row in all_numeric),
        "maximum_uint16_error": max(row["maximum_uint16_error"] for row in all_numeric),
        "maximum_WB_gain_error": max(max(row["capture_gain_max_error"], row["target_gain_max_error"]) for row in wb_records),
        "CCT_all_equal": all(row["native_cct"] == row["cpp_capture_cct"] for row in wb_records),
        "shadow_weight_cases": len(shadow_records),
        "shadow_weight_max_error": max(row["polynomial_error"] for row in shadow_records),
        "film_selection_cases": len(film_records),
        "film_selection_all_equal": all(row["native_effective_film"] == row["cpp_selection"] for row in film_records)}
    passed = (report["summary"]["maximum_uint16_error"] == 0 and report["summary"]["CCT_all_equal"] and
              report["summary"]["maximum_WB_gain_error"] <= 1e-12 and
              report["summary"]["shadow_weight_max_error"] <= 1e-12 and report["summary"]["film_selection_all_equal"])
    report["status"] = "passed" if passed else "mismatch"
    n.close()
    (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2), flush=True)
    if not passed:
        raise SystemExit("Native/C++ mismatch; inspect report.json before drawing conclusions")


if __name__ == "__main__":
    main()
