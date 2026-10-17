"""Original saturation/grayscale calls versus revision-10 post-spatial C++.

The native call graph places these stages after gradation, USM and grain.
Full factory settings and tool overlays come from original Phocus resources.
"""
import argparse
import ctypes as c
import itertools
import json
from pathlib import Path
import plistlib
import subprocess
import sys

import numpy as np
from audit_phocus_input_spatial import Filters, delta, sha


class NativePostStages:
    def __init__(self, native, storage, filters, correction):
        self.filters = filters
        self.stages = []
        self.saturation = native.fn(storage, "_ZNK16CImageCorrection13GetSaturationEv", [c.c_void_p], c.c_int)(correction)
        self.gray = bool(c.c_ubyte.from_buffer(correction, 0x96).value)
        # The catalog under test has no selective points or vibrance. Reject
        # either instead of silently treating a more complex look as global sat.
        assert c.c_void_p.from_buffer(correction, 0x2e8).value == c.c_void_p.from_buffer(correction, 0x2f0).value
        assert c.c_int.from_buffer(correction, 0x300).value == 0
        if self.saturation and c.c_ubyte.from_buffer(correction, 0x90).value:
            obj = c.create_string_buffer(0x1000)
            ctor = filters.bridge.construct_phocus_saturation
            ctor.argtypes = [c.c_void_p, c.c_int, c.c_void_p]
            address = c.cast(getattr(native.image, "_ZN21CSelectiveColorFilterC1ENSt3__16vectorI22CSelectiveControlPointNS0_9allocatorIS2_EEEEii"), c.c_void_p).value
            assert ctor(obj, self.saturation, address) == 0
            self.stages.append((obj, "_ZNK21CSelectiveColorFilter12FilterResultE6CXRectS0_NSt3__110unique_ptrI14CBufferedImageNS1_14default_deleteIS3_EEEES6_"))
        self.gray_weights = []
        if self.gray:
            getter = native.fn(storage, "_ZNK16CImageCorrection12GetGrayScaleEh", [c.c_void_p, c.c_uint8], c.c_double)
            self.gray_weights = [getter(correction, ch) / 100. for ch in [1, 2, 3]]
            obj = c.create_string_buffer(0x1000)
            ctor = native.fn(native.image, "_ZN16CGrayscaleFilterC1Edddb", [c.c_void_p, c.c_double, c.c_double, c.c_double, c.c_bool])
            ctor(obj, *self.gray_weights, True)
            self.stages.append((obj, "_ZNK16CGrayscaleFilter12FilterResultE6CXRectS0_NSt3__110unique_ptrI14CBufferedImageNS1_14default_deleteIS3_EEEES6_"))

    def run(self, source):
        result = source.copy()
        for obj, symbol in self.stages:
            result = self.filters.run(obj, symbol, result)
        return result

    def close(self):
        for obj, _ in self.stages:
            self.filters.destroy(obj)


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
    from preset_curves_probe import NativeCurves, correction_payload
    import phocus_presets as presets
    sources = [root / p for p in ["core/hncs.cpp", "core/hncs_c.h", "core/hncs_phocus_post.hpp",
               "core/hncs_preset_assets.inc", "tools/native_phocus_filters_bridge.cpp", "tools/audit_phocus_input_spatial.py",
               "tools/audit_phocus_post_stages.py"]]
    hashes = {str(p): sha(p) for p in sources}
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-O3", "-fno-fast-math", "-ffp-contract=off",
                    "-Wall", "-Wextra", "-Werror", "-dynamiclib", str(root / "core/hncs.cpp"), "-o", str(out / "core.dylib")], check=True)
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-O2", "-dynamiclib",
                    str(root / "tools/native_phocus_filters_bridge.cpp"), "-o", str(out / "native.dylib")], check=True)
    cpp = c.CDLL(str(out / "core.dylib"))
    post = cpp.hncs_apply_phocus_post_spatial
    post.argtypes = [c.c_char_p, c.c_void_p, c.c_void_p, c.c_size_t]
    n = Native()
    storage = c.CDLL(str(verified_framework("HBStorage")))
    filters = Filters(n, out / "native.dylib")
    factory = Path("/Volumes/Phocus/Phocus.app/Contents/Resources/Settings/Standard")
    baseline = plistlib.loads((factory / "Standard.xml").read_bytes())["ImageSetting"]["ImageCorrection"]
    ramp = np.repeat(np.arange(65536, dtype=np.uint16)[:, None], 3, axis=1)
    cube = np.array(list(itertools.product(np.rint(np.linspace(0, 65535, 17)).astype(np.uint16), repeat=3)))
    random = np.random.default_rng(args.seed).integers(0, 65536, (131072, 3), dtype=np.uint16)
    source = np.ascontiguousarray(np.concatenate([ramp, cube, random]))[None, ...]
    rows = []
    for key in sorted(set(presets.preset_key(k) for k in presets.PRESET_CHOICES)):
        filename = presets.FACTORY_SETTING_FILES[presets.settings(key)["name"]]
        path = factory / filename
        assert sha(path) == presets.catalog()["source_files"][filename]["sha256"]
        payload = correction_payload({"plist": plistlib.loads(path.read_bytes())}, baseline)
        settings = NativeCurves(n, storage, payload)
        stages = NativePostStages(n, storage, filters, settings.correction)
        try:
            expected = stages.run(source)
            actual = np.empty_like(source)
            assert post(key.encode(), source.ctypes.data, actual.ctypes.data, source.size // 3) == 0
            error = delta(actual, expected)
            rows.append({"preset": key, "saturation": stages.saturation, "gray_weights": stages.gray_weights, **error})
        finally:
            stages.close(); settings.close()
    n.close()
    assert hashes == {str(p): sha(p) for p in sources}
    failures = [row for row in rows if row["maximum_uint16_error"]]
    report = {"status": "mismatch" if failures else "passed", "source_sha256": hashes,
              "framework_sha256": {name: sha(verified_framework(name)) for name in FRAMEWORK_HASHES},
              "seed": args.seed, "input_sha256": __import__("hashlib").sha256(source.tobytes()).hexdigest(), "cases": rows,
              "summary": {"cases": len(rows), "channels": sum(r["channels"] for r in rows),
                          "maximum_uint16_error": max(r["maximum_uint16_error"] for r in rows), "failed_cases": len(failures)}}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))
    if failures:
        print(json.dumps(failures, indent=2)); raise SystemExit(1)


if __name__ == "__main__":
    main()
