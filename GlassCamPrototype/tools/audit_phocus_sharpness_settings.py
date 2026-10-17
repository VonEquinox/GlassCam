"""Check sharpness defaults and every factory preset with original Phocus getters."""
import argparse
import ctypes as c
import json
from pathlib import Path
import plistlib
import sys

from audit_phocus_input_spatial import sha
from phocus_sharpness_settings import preset_sharpness, sharpness_settings


def native_settings(native, storage, correction):
    getters = {
        "amount": "_ZNK16CImageCorrection16GetUnsharpAmountEv",
        "radius": "_ZNK16CImageCorrection16GetUnsharpRadiusEv",
        "noise_limit": "_ZNK16CImageCorrection20GetUnsharpNoiseLimitEv",
        "dark_limit": "_ZNK16CImageCorrection19GetUnsharpDarkLimitEv",
    }
    values = {key: native.fn(storage, symbol, [c.c_void_p], c.c_int)(correction)
              for key, symbol in getters.items()}
    # Hash-locked DecodePartFrom stores ApplyUSM here (0x35fd8).
    values["enabled"] = bool(c.c_ubyte.from_buffer(correction, 0x9e).value)
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    ref, out = args.reference_root.resolve(), args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sys.path[:0] = [str(ref), str(ref / "work/hncs-phocus-audit")]
    from native_chain_probe import Native
    from native_config_probe import FRAMEWORK_HASHES, verified_framework
    from preset_curves_probe import NativeCurves, correction_payload
    import phocus_presets as presets

    native = Native()
    storage = c.CDLL(str(verified_framework("HBStorage")))
    factory = Path("/Volumes/Phocus/Phocus.app/Contents/Resources/Settings/Standard")
    standard = plistlib.loads((factory / "Standard.xml").read_bytes())["ImageSetting"]["ImageCorrection"]
    sources = [Path(__file__), Path(__file__).with_name("phocus_sharpness_settings.py")]
    source_hashes = {str(p): sha(p) for p in sources}
    cases = []
    for label, payload in [
        ("empty-decoded-dictionary", {}), ("standard", standard),
        ("missing-radius", {k: v for k, v in standard.items() if k != "USMRadius"}),
        ("explicit-zero-radius", dict(standard, USMRadius=0)),
        ("zero-amount", dict(standard, USMAmount=0)),
        ("disabled", dict(standard, ApplyUSM=False)),
        ("missing-apply-flag", {k: v for k, v in standard.items() if k != "ApplyUSM"}),
        ("missing-all-usm", {k: v for k, v in standard.items() if not k.startswith("USM")}),
    ]:
        obj = NativeCurves(native, storage, payload)
        try:
            actual = native_settings(native, storage, obj.correction)
            assert actual == sharpness_settings(payload), (label, actual)
            cases.append({"case": label, "native": actual, "resolved": sharpness_settings(payload)})
        finally:
            obj.close()

    obj = NativeCurves(native, storage, standard)
    try:
        native.fn(storage, "_ZN16CImageCorrection19SetDefaultSharpnessEv", [c.c_void_p])(obj.correction)
        defaults = native_settings(native, storage, obj.correction)
        assert defaults == {"amount": 0, "radius": 10, "noise_limit": 0, "dark_limit": 10, "enabled": True}
    finally:
        obj.close()

    records = []
    for key in sorted(set(presets.preset_key(k) for k in presets.PRESET_CHOICES)):
        filename = presets.FACTORY_SETTING_FILES[presets.settings(key)["name"]]
        path = factory / filename
        assert sha(path) == presets.catalog()["source_files"][filename]["sha256"]
        original = plistlib.loads(path.read_bytes())
        # Independent original XML + preexisting native gradation overlay policy;
        # do not use the production sharpness resolver to make the oracle payload.
        payload = correction_payload({"plist": original}, standard)
        obj = NativeCurves(native, storage, payload)
        try:
            actual = native_settings(native, storage, obj.correction)
            resolved = preset_sharpness(presets, key)
            assert actual == resolved, (key, actual, resolved)
            records.append({"preset": key, "xml": filename, "xml_sha256": sha(path),
                            "tool_over_standard": "ImageSetting" not in original,
                            "native": actual, "resolved": resolved})
        finally:
            obj.close()
    native.close()
    assert source_hashes == {str(p): sha(p) for p in sources}
    report = {"status": "passed", "framework_sha256": {k: sha(verified_framework(k)) for k in FRAMEWORK_HASHES},
              "source_sha256": source_hashes, "decode_cases": cases, "SetDefaultSharpness": defaults,
              "presets": records, "summary": {"decode_cases": len(cases), "preset_cases": len(records),
              "parameter_mismatches": 0},
              "policy": "Tool-only XML is applied over factory Standard, matching GlassCam's existing stateless gradation contract. Full settings decode independently. Missing numeric keys in a full decoded payload are zero, not constructor defaults."}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))


if __name__ == "__main__":
    main()
