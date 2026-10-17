"""Probe original Phocus exposure and spatial stages with synthetic numbers.

Requires the hash-locked 4.2.2 arm64 frameworks and existing native factory
configuration loader. No photographs, GUI interaction, or new sensor fit.
This diagnostic reports disagreements with the current portable spatial model;
it does not silently redefine those disagreements as native parity.
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
from phocus_sharpness_reference import sharpen


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def delta(actual, expected):
    d = actual.astype(np.int32) - expected.astype(np.int32)
    return {"channels": int(d.size), "different_channels": int(np.count_nonzero(d)),
            "maximum_uint16_error": int(np.abs(d).max()),
            "signed_range": [int(d.min()), int(d.max())]}


class Filters:
    def __init__(self, native, bridge_path):
        self.n = native
        self.bridge = c.CDLL(str(bridge_path))
        self.apply = self.bridge.apply_phocus_filter
        self.apply.argtypes = [c.c_void_p, c.c_void_p, c.c_uint, c.c_uint, c.c_int, c.c_int,
                               c.c_uint, c.c_uint, c.c_void_p] + [c.c_void_p] * 5
        self.apply.restype = c.c_int
        self.base_addresses = [c.cast(getattr(native.util, symbol), c.c_void_p).value for symbol in
            ["_ZN14CBufferedImageC1EjjjjPtbj", "_ZN14CBufferedImageD0Ev",
             "_ZN14CBufferedImage11GetPixelPtrEjj", "_ZN6CXRectC1Eiiii"]]

    def run(self, obj, symbol, source, crop=None):
        # Original filters may consume/modify their input buffer.
        source = np.ascontiguousarray(source, dtype=np.uint16).copy()
        height, width, channels = source.shape
        assert channels == 3
        left, top, w, h = crop or (0, 0, width, height)
        out = np.empty((h, w, 3), np.uint16)
        address = c.cast(getattr(self.n.image, symbol), c.c_void_p).value
        result = self.apply(obj, source.ctypes.data, width, height, left, top, w, h,
                            out.ctypes.data, *self.base_addresses, address)
        if result:
            raise ValueError(f"Native filter returned {result}: {symbol}")
        return out

    def destroy(self, obj):
        # Complete destructor, not deleting destructor: object storage is Python-owned.
        vtable = c.c_void_p.from_buffer(obj).value
        address = c.c_void_p.from_address(vtable).value
        c.CFUNCTYPE(None, c.c_void_p)(address)(obj)

    def pad(self, source, halo):
        """Ask original CRepeatMarginFilter to supply the RGB neighborhood."""
        source = np.ascontiguousarray(source, dtype=np.uint16)
        height, width, _ = source.shape
        constructor = self.bridge.construct_phocus_margin
        constructor.argtypes = [c.c_void_p, c.c_int, c.c_int, c.c_int, c.c_void_p, c.c_void_p]
        obj = c.create_string_buffer(0x1000)
        rect = c.cast(getattr(self.n.util, "_ZN6CXRectC1Eiiii"), c.c_void_p).value
        margin = c.cast(getattr(self.n.image, "_ZN19CRepeatMarginFilterC1E6CXRecti"), c.c_void_p).value
        assert constructor(obj, width, height, 1, rect, margin) == 0
        try:
            return self.run(obj, "_ZNK19CRepeatMarginFilter12FilterResultE6CXRectS0_NSt3__110unique_ptrI14CBufferedImageNS1_14default_deleteIS3_EEEES6_",
                            source, (-halo, -halo, width + 2 * halo, height + 2 * halo))
        finally:
            self.destroy(obj)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--stage", choices=["exposure", "sharpness", "all"], default="all")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    reference, out = args.reference_root.resolve(), args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sys.path[:0] = [str(reference), str(reference / "work/hncs-phocus-audit")]
    from native_chain_probe import Native, Vec3
    from native_config_probe import FRAMEWORK_HASHES, verified_framework
    from preset_curves_probe import NativeCurves

    bridge_path = out / "native-filters-bridge.dylib"
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-O2", "-dynamiclib",
                    str(root / "tools/native_phocus_filters_bridge.cpp"), "-o", str(bridge_path)], check=True)
    native = Native()
    filters = Filters(native, bridge_path)
    storage = c.CDLL(str(verified_framework("HBStorage")))
    report = {"phocus_version": "4.2.2", "architecture": "arm64",
              "framework_sha256": {name: sha(verified_framework(name)) for name in FRAMEWORK_HASHES},
              "source_sha256": {str(p): sha(p) for p in [Path(__file__), root / "tools/native_phocus_filters_bridge.cpp",
                  root / "core/hncs_spatial.cpp", root / "core/hncs_spatial_assets.inc", root / "core/hncs_numpy_rng.cpp",
                  root / "tools/phocus_sharpness_reference.py"]}}
    vectors = {}

    if args.stage in ["exposure", "all"]:
        print("Original CColorCorrectFilter exposure/ISO parameters", flush=True)
        ctor = native.fn(native.image, "_ZN19CColorCorrectFilterC1E6CArrayIdLi3E23Matrix3x1InitializationE9eCCDTypes13eIRFilterType14eFilmCurveType11eColorModel13eWorkingSpacedbdbP14CCLCalibration",
                         [c.c_void_p, Vec3] + [c.c_int] * 5 + [c.c_double, c.c_bool, c.c_double, c.c_bool, c.c_void_p])
        wb = native.fn(native.image, "_ZN20CColorTempConversion17TempAndTintToGainE9eCCDTypes13eIRFilterTypeid",
                       [c.c_int, c.c_int, c.c_int, c.c_double], Vec3)(22, 6, 5500, 0.)
        pixels = native.fn(native.raw, "_ZN14CVectorMethods24ColorNormalCorrectPixelsEP16CColorCorrectionPtS2_ib",
                           [c.c_void_p] * 4 + [c.c_int, c.c_bool])
        rng = np.random.default_rng(181017)
        source = rng.integers(0, 65536, (1, 65536, 3), dtype=np.uint16)
        source[0, :6553] = np.arange(6553, dtype=np.uint16)[:, None] * 10
        records = []
        for exposure in [.25, .5, 1., 2., 4.]:
            for iso in [.5, 1., 2.]:
                obj = c.create_string_buffer(0x1000)
                ctor(obj, wb, 22, 6, 2, 0, 0, exposure, False, iso, False, None)
                try:
                    assert c.c_ubyte.from_buffer(obj, 0x38).value == 1
                    outer = c.c_void_p.from_buffer(obj, 0x48).value
                    cc = c.c_void_p.from_address(outer + 0xb0).value
                    actual = filters.run(obj, "_ZNK19CColorCorrectFilter12FilterResultE6CXRectS0_NSt3__110unique_ptrI14CBufferedImageNS1_14default_deleteIS3_EEEES6_", source)
                    candidate_errors = {}
                    for label, gain in [("unchanged_input", 1.), ("exposure_before_kernel", exposure),
                                        ("iso_before_kernel", iso), ("exposure_times_iso_before_kernel", exposure*iso)]:
                        codes = np.ascontiguousarray(np.clip(source.astype(np.float64)*gain, 0, 65535).astype(np.uint16))
                        expected = np.empty_like(codes)
                        pixels(None, cc, expected.ctypes.data, codes.ctypes.data, codes.size // 3, False)
                        candidate_errors[label] = delta(actual, expected)
                    table_lengths = []
                    for offset in [0x1e0, 0x1f8, 0x210, 0x240, 0x258, 0x270]:
                        start = c.c_void_p.from_address(cc + offset).value or 0
                        end = c.c_void_p.from_address(cc + offset + 8).value or 0
                        table_lengths.append((end-start)//2)
                    records.append({"exposure_argument": exposure, "iso_argument": iso,
                        "linearization_table_lengths": table_lengths,
                        "shadow_parameters": native.array(cc, 0x1b8, (4,)).tolist(),
                        "comparisons_to_same_native_core": candidate_errors,
                        "output_sha256": hashlib.sha256(actual.tobytes()).hexdigest()})
                    vectors[f"exposure_{exposure}_iso_{iso}"] = actual
                    print(exposure, iso, {key: value["maximum_uint16_error"] for key, value in candidate_errors.items()}, flush=True)
                finally:
                    filters.destroy(obj)
        report["color_filter_exposure"] = records
        vectors["exposure_source"] = source

    if args.stage in ["sharpness", "all"]:
        print("Original CSharpnessFilter versus portable Gaussian USM", flush=True)
        cpp_path = out / "portable-spatial.dylib"
        subprocess.run(["xcrun", "clang++", "-std=c++17", "-O3", "-fno-fast-math", "-ffp-contract=off", "-dynamiclib",
                        str(root / "core/hncs_spatial.cpp"), str(root / "core/hncs_numpy_rng.cpp"), "-o", str(cpp_path)], check=True)
        cpp = c.CDLL(str(cpp_path))
        cpp.hncs_apply_spatial_preset.argtypes = [c.c_void_p, c.c_size_t, c.c_size_t, c.c_char_p, c.c_int, c.c_int]
        ctor = native.fn(native.image, "_ZN16CSharpnessFilterC1Eidiiidd",
                         [c.c_void_p, c.c_int, c.c_double, c.c_int, c.c_int, c.c_int, c.c_double, c.c_double])
        inner_ctor = native.fn(native.image, "_ZN15CSharpenAndBlurC1Ejidiiddd",
            [c.c_void_p, c.c_uint, c.c_int, c.c_double, c.c_int, c.c_int, c.c_double, c.c_double, c.c_double])
        corpus = {}
        h, w = 37, 53
        for level in [0, 1, 2, 3, 4, 5, 1000, 16000, 32767, 65535]:
            corpus[f"flat_{level}"] = np.full((h, w, 3), level, np.uint16)
        corpus["ramp"] = np.broadcast_to(np.rint(np.linspace(0, 65535, w))[None, :, None], (h, w, 3)).astype(np.uint16).copy()
        edge = np.full((h, w, 3), [12000, 22000, 32000], np.uint16)
        edge[:, w//2:] = [48000, 18000, 8000]
        corpus["color_edge"] = edge
        impulse = np.full((h, w, 3), 16000, np.uint16)
        impulse[h//2, w//2] = [60000, 40000, 20000]
        corpus["color_impulse"] = impulse
        corpus["random"] = np.random.default_rng(181018).integers(0, 65536, (h, w, 3), dtype=np.uint16)
        records = []
        tables = {}
        factory = Path("/Volumes/Phocus/Phocus.app/Contents/Resources/Settings/Standard")
        for key in ["standard", "nature"]:
            path = factory / (key.title()+".xml")
            payload = plistlib.loads(path.read_bytes())["ImageSetting"]["ImageCorrection"]
            curves = NativeCurves(native, storage, payload)
            getters = {}
            for label, symbol in [("radius", "_ZNK16CImageCorrection16GetUnsharpRadiusEv"),
                                  ("noise_limit", "_ZNK16CImageCorrection20GetUnsharpNoiseLimitEv"),
                                  ("dark_limit", "_ZNK16CImageCorrection19GetUnsharpDarkLimitEv")]:
                getters[label] = native.fn(storage, symbol, [c.c_void_p], c.c_int)(curves.correction)
            curves.close()
            inner = c.create_string_buffer(0x1000)
            inner_ctor(inner, w, payload["USMAmount"], getters["radius"] / 10., getters["noise_limit"],
                       getters["dark_limit"], 1., 1., 1.)
            try:
                count = c.c_ubyte.from_buffer(inner, 0x170).value
                def native_array(offset, dtype, count):
                    address = c.c_void_p.from_buffer(inner, offset).value
                    return np.ctypeslib.as_array((dtype*count).from_address(address)).copy()
                weights = native_array(0xb0, c.c_uint32, count)
                amount_table = native_array(0x10, c.c_int32, 16384)
                noise_table = native_array(0x168, c.c_uint8, 16384)
                assert sum(weights) == c.c_uint32.from_buffer(inner, 0x1d0).value
                tables[key] = {"weights": weights.tolist(), "sum": int(weights.sum()),
                    "amount_table_sha256": hashlib.sha256(amount_table.tobytes()).hexdigest(),
                    "noise_table_sha256": hashlib.sha256(noise_table.tobytes()).hexdigest()}
                vectors[f"{key}_weights"] = weights
                vectors[f"{key}_amount_table"] = amount_table
                vectors[f"{key}_noise_table"] = noise_table
            finally:
                native.fn(native.image, "_ZN15CSharpenAndBlurD1Ev", [c.c_void_p])(inner)
            for label, source in corpus.items():
                obj = c.create_string_buffer(0x1000)
                ctor(obj, payload["USMAmount"], getters["radius"] / 10., getters["noise_limit"],
                     getters["dark_limit"], w, 1., 1.)
                try:
                    extra = c.c_int.from_buffer(obj, 0x70).value
                    halo = max(4, extra)
                    assert 0 <= extra <= 1024
                    padded = np.ascontiguousarray(np.pad(source, ((halo, halo), (halo, halo), (0, 0)), mode="edge"))
                    actual = filters.run(obj, "_ZNK16CSharpnessFilter12FilterResultE6CXRectS0_NSt3__110unique_ptrI14CBufferedImageNS1_14default_deleteIS3_EEEES6_", padded, (halo, halo, w, h))
                    work = source.astype(np.float32) / np.float32(65535.)
                    assert cpp.hncs_apply_spatial_preset(work.ctypes.data, w, h, key.encode(), 0, 1) == 0
                    portable = np.rint(np.clip(work, 0, 1)*np.float32(65535.)).astype(np.uint16)
                    expected = sharpen(source, weights, amount_table, noise_table)
                    records.append({"preset": key, "pattern": label, "shape": list(source.shape),
                        "xml_sha256": sha(path), "amount": payload["USMAmount"], **getters,
                        "image_scale": 1., "HDR_scale": 1., "extra_lines": extra, "supplied_halo": halo,
                        "native_vs_source": delta(actual, source), "portable_vs_native": delta(portable, actual),
                        "reconstructed_vs_native": delta(expected, actual),
                        "native_output_mod4_histogram": np.bincount((actual % 4).reshape(-1), minlength=4).tolist(),
                        "native_center": actual[h//2, w//2].tolist(),
                        "source_center": source[h//2, w//2].tolist()})
                    vectors[f"sharpness_{key}_{label}_native"] = actual
                    vectors[f"sharpness_{key}_{label}_portable"] = portable
                    vectors[f"sharpness_{label}_source"] = source
                    print(key, label, "portable max delta", records[-1]["portable_vs_native"]["maximum_uint16_error"],
                          "reconstruction max delta", records[-1]["reconstructed_vs_native"]["maximum_uint16_error"], flush=True)
                finally:
                    filters.destroy(obj)
        report["sharpness"] = records
        report["native_sharpness_tables"] = tables
        report["spatial_scope"] = "CPU CSharpnessFilter with explicit 16-bit work input, factory amount/radius/noise/dark controls, full-resolution scale 1, non-HDR. Numerically edge-replicated input halo supplied; original full-RAW image-edge construction and local adjustment layers are not established."
    native.close()
    np.savez_compressed(out / "vectors.npz", **vectors)
    report["vectors_sha256"] = sha(out / "vectors.npz")
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Saved", out / "report.json", flush=True)
    if any(row["reconstructed_vs_native"]["maximum_uint16_error"] != 0 for row in report.get("sharpness", [])):
        raise SystemExit("Reconstructed sharpness does not yet match the original binary")


if __name__ == "__main__":
    main()
