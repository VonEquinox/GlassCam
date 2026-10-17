"""Verify X2D II identity and input metadata using the original Phocus library.

Each invocation owns a diagnostic process. Raw files are opened read-only. The
original constructor builds sRawDescription; no camera identity or calibration
values are injected into it. Opaque native storage is retained until exit.
"""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
import plistlib
import sys

import numpy as np
import tifffile

X2D_MODELS = frozenset(["X2D II 100C", "Hasselblad X2D II 100C"])


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class RawProbe:
    """Lifetime is one independent probe process; never used by the iOS app."""
    def __init__(self, reference, path):
        with tifffile.TiffFile(path) as image:
            model = image.pages[0].tags.get(272)
            if model is None or model.value not in X2D_MODELS:
                raise ValueError("Original X2D II 100C model tag is required")
        sys.path[:0] = [str(reference), str(reference / "work/hncs-phocus-audit")]
        from native_chain_probe import Native
        from native_config_probe import verified_framework
        # Reuse only the ABI helpers. Load factory resources through the
        # original library's own constructor/lazy cache, without registering
        # the external decoded plist used by the earlier color-core audit.
        self.n = Native.__new__(Native)
        self.n.util = c.CDLL(str(verified_framework("HBUtil")))
        self.n.raw = c.CDLL(str(verified_framework("HBRawCorrections")))
        self.n.image = c.CDLL(str(verified_framework("HBImageProcessing")))
        self.n.cf = c.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.storage = c.CDLL(str(verified_framework("HBStorage")))
        self.stream = c.create_string_buffer(0x1000)
        self.n.fn(self.storage, "_ZN17CStreamFactoryMacC1Ev", [c.c_void_p])(self.stream)
        c.c_void_p.in_dll(self.n.util, "gStreamFactory").value = c.addressof(self.stream)
        self.spec, self.raw, self.description = (c.create_string_buffer(size) for size in [0x40, 0x4000, 0x1000])
        self.n.fn(self.n.util, "_ZN9CFileSpecC1EPKcbii",
                  [c.c_void_p, c.c_char_p, c.c_bool, c.c_int, c.c_int])(
                      self.spec, str(path).encode(), False, 0, 0)
        self.n.fn(self.n.image, "_ZN11CRaw3FRFileC1E9CFileSpec", [c.c_void_p, c.c_void_p])(self.raw, self.spec)
        self.n.fn(self.storage, "_ZN15sRawDescriptionC1EP13CRawImageFileP15CRawCaptureInfo",
                  [c.c_void_p] * 3)(self.description, self.raw, None)
        self.n.config = c.create_string_buffer(0x330)
        self.n.fn(self.n.raw, "_ZN7CXMLLutC1E13uColorProfilei",
                  [c.c_void_p, c.c_uint32, c.c_int])(self.n.config, 0x616, 0)
        self.n.temp_object = c.create_string_buffer(0x98)
        self.n.fn(self.n.image, "_ZN20CColorTempConversionC1E9eCCDTypes13eIRFilterType",
                  [c.c_void_p, c.c_int, c.c_int])(self.n.temp_object, 22, 6)
        table = self.n.fn(self.n.image, "_ZN20CColorTempConversion9TempTableEv", [], c.c_void_p)
        self.n.image_base = c.cast(table, c.c_void_p).value - 0xd3738

    def decode_object(self, class_name, payload=None):
        """Construct/decode an original streamable object, retained until exit."""
        if class_name not in ["CImageDescription", "COutputPreset"]:
            raise ValueError("Unsupported original streamable type")
        obj = c.create_string_buffer(0x1000)
        prefix = f"_ZN{len(class_name)}{class_name}"
        self.n.fn(self.storage, prefix + "C1Ev", [c.c_void_p])(obj)
        if payload is not None:
            blob = plistlib.dumps(payload, fmt=plistlib.FMT_XML)
            data = self.n.fn(self.n.cf, "CFDataCreate", [c.c_void_p, c.c_void_p, c.c_long], c.c_void_p)(None, blob, len(blob))
            dictionary = self.n.fn(self.n.cf, "CFPropertyListCreateWithData",
                [c.c_void_p, c.c_void_p, c.c_ulong, c.c_void_p, c.c_void_p], c.c_void_p)(None, data, 0, None, None)
            if not dictionary:
                raise ValueError("Original property list could not be decoded")
            coder = c.create_string_buffer(0x20)
            self.n.fn(self.n.util, "_ZN12CKeyCoderMacC1EP14__CFDictionaryb", [c.c_void_p, c.c_void_p, c.c_bool])(coder, dictionary, False)
            self.n.fn(self.storage, prefix + "10DecodeFromEP9CKeyCoder", [c.c_void_p] * 2)(obj, coder)
            self.n.fn(self.n.util, "_ZN12CKeyCoderMacD1Ev", [c.c_void_p])(coder)
            for handle in [dictionary, data]: self.n.fn(self.n.cf, "CFRelease", [c.c_void_p])(handle)
        return obj

    def scalar(self, offset, kind=c.c_int):
        return kind.from_buffer(self.description, offset).value

    def metadata(self):
        values = {}
        for name, result in [("CCDType", c.c_int), ("GetBackModel", c.c_int),
                             ("GetModel", c.c_int), ("GetIsoGain", c.c_double),
                             ("GetSensitivityGain", c.c_double), ("GetAnalogGain", c.c_double),
                             ("GetBlackLevel", c.c_int), ("GetFilmCurveType", c.c_int),
                             ("GetBaselineSharpness", c.c_double)]:
            values[name] = self.n.fn(self.storage, f"_ZN13CRawImageFile{len(name)}{name}Ev",
                                     [c.c_void_p], result)(self.raw)
        values["GetDNGWhiteLevel"] = self.n.fn(self.storage, "_ZNK13CRawImageFile16GetDNGWhiteLevelEv",
                                               [c.c_void_p], c.c_int)(self.raw)
        neutral = (c.c_double * 3)()
        values["neutral_success"] = self.n.fn(self.storage, "_ZN13CRawImageFile14GetNeutralGainEPd",
                                               [c.c_void_p, c.c_void_p], c.c_bool)(self.raw, neutral)
        values["neutral_gain"] = list(neutral)
        packed = self.n.fn(self.storage, "_ZN13CRawImageFile21GetNeutralCalibrationEv",
                           [c.c_void_p], c.c_uint64)(self.raw)
        values["neutral_calibration_u14"] = [(packed >> (16 * k)) & 0xffff for k in range(3)]
        values["description"] = {label: self.scalar(offset, kind) for label, offset, kind in [
            ("sensitivity_gain", 0x18, c.c_double), ("iso_gain", 0x40, c.c_double),
            ("analog_gain", 0x50, c.c_double), ("film_curve", 0xb0, c.c_int),
            ("shots", 0xe0, c.c_int), ("components", 0xe4, c.c_int),
            ("black_level", 0x130, c.c_int), ("correction_bits", 0x138, c.c_uint32),
            ("back_model", 0x25c, c.c_int), ("ccd", 0x344, c.c_int), ("ir_filter", 0x348, c.c_int),
            ("working_max", 0x398, c.c_int), ("preprocessed", 0x3a0, c.c_bool)]}
        for name in ["GetRawWidth", "GetRawHeight"]:
            values["description"][name] = self.n.fn(self.storage, f"_ZNK15sRawDescription{len(name)}{name}Ev",
                                                     [c.c_void_p], c.c_int)(self.description)
        if values["CCDType"] != 22 or values["GetBackModel"] != 71 or values["description"]["ir_filter"] != 6:
            raise ValueError("Original RAW selected a different camera/CCD/IR branch")
        return values


def tag_numbers(value):
    if isinstance(value, tuple) and len(value) % 2 == 0:
        return [value[i] / value[i + 1] for i in range(0, len(value), 2)]
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--raw-source", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    reference, path, out = args.reference_root.resolve(), args.raw_source.resolve(), args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    original_hash = sha(path)
    with tifffile.TiffFile(path) as image:
        tags = image.pages[0].tags
        tag_values = {str(key): {"name": tags[key].name, "value": tag_numbers(tags[key].value)}
                      for key in [271, 272, 50728, 50730, 50732, 51109] if key in tags}
    if tag_values.get("272", {}).get("value") not in X2D_MODELS:
        raise ValueError("This audit requires an identified X2D II 100C RAW")
    probe = RawProbe(reference, path)
    values = probe.metadata()
    neutral_tag = np.asarray(tag_values["50728"]["value"], dtype=np.float64)
    expected_neutral = neutral_tag.max() / neutral_tag
    neutral_error = float(np.max(np.abs(expected_neutral - values["neutral_gain"])))
    if not values["neutral_success"] or neutral_error != 0:
        raise AssertionError("Native neutral getter and AsShotNeutral disagree")
    if values["CCDType"] != 22 or values["description"]["ccd"] != 22 or values["description"]["ir_filter"] != 6:
        raise AssertionError("RAW selected a different color configuration than the existing 0x616 factory profile")
    config = reference / "work/hncs-phocus-correction/evidence/colormaps_plain/bohnjuhtuvuvtxyydb56.bin"
    from native_config_probe import FRAMEWORK_HASHES, verified_framework
    report = {"status": "passed", "source": str(path), "source_sha256": original_hash,
              "tags": tag_values, "native": values, "neutral_gain_max_error": neutral_error,
              "factory_profile": {"path": str(config), "sha256": sha(config), "native_cache_key": "0x616",
                                  "plist_keys": sorted(plistlib.loads(config.read_bytes())),
                                  "loader": "Original CXMLLut(profile, 0) and native lazy cache; no external plist registered",
                                  "encoded_resource": "/Volumes/Phocus/Phocus.app/Contents/Frameworks/HBRawCorrections.framework/Versions/A/Resources/Colormaps/bohnjuhtuvuvtxyydb56.dat",
                                  "encoded_sha256": sha(Path("/Volumes/Phocus/Phocus.app/Contents/Frameworks/HBRawCorrections.framework/Versions/A/Resources/Colormaps/bohnjuhtuvuvtxyydb56.dat"))},
              "framework_sha256": {key: sha(verified_framework(key)) for key in FRAMEWORK_HASHES},
              "probe_sha256": sha(Path(__file__)),
              "limits": ["Metadata and original selected description only; RAW pixels and HDR remain separate checks.",
                         "No vendor identity was inferred from the filename; model tag and native getters are recorded."]}
    if sha(path) != original_hash:
        raise AssertionError("RAW changed during read-only probe")
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "native": values, "neutral_error": neutral_error}, indent=2))


if __name__ == "__main__":
    main()
