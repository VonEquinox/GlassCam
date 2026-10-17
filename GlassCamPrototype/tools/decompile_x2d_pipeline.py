"""Hash-locked, readable r2ghidra analysis of the missing X2D RAW/HDR stages.

Only reads vendor libraries. Addresses identify Phocus 4.2.2 arm64, not an
independently compiled imitation. Inferred C++ types and all warnings are kept;
decompilation alone is not a numerical equivalence test.
"""
import argparse
import json
from pathlib import Path
import subprocess

from decompile_phocus import run_r2, sha

HASHES = {
    "HBUtil": "0786d740ad4d6455ee5c5a0d53339f960deabc32b931ecff3186719d627dcf1c",
    "HBRawCorrections": "887d4c3823362c5e89ae3fb14939b85eb5fe85db60913c9d99836ad007c636f0",
    "HBStorage": "c311cedfe841f757a3154713f24e08de1601f0ad6a57d601c25e21cd1ce87826",
    "HBImageProcessing": "125dd5b0bf0cc1ad00d1cf959eeeea82aa24acee117c2b2bcb55fa44f430d010",
}
TARGETS = {
    "HBUtil": [
        ("GetGradationCurveHDR", 0x25184),
        ("GradationApplyGain", 0x24bd8),
        ("GradationApplyHighlight", 0x24edc),
        ("SetDebugKey", 0x14a54),
    ],
    "HBRawCorrections": [
        ("RawColorCorrectPixels", 0x1694c),
        ("ApplyLinearization", 0x16774),
        ("NewRawColorCorrection", 0x16b48),
        ("RawColorConstructor", 0x147f4),
        ("PrepareLinearizations", 0x306c4),
        ("CalculateLinearization", 0x30aa0),
        ("HDRGradation", 0x14620),
        ("CalculateDesatValues", 0x15304),
        ("ProfileLookup", 0x2ecc4),
        ("XMLLutConstructor", 0xf38),
        ("XMLLutFilename", 0x154c),
    ],
    "HBStorage": [
        ("RawDescription", 0xf2b94),
        ("RawCCDType", 0x4c978),
        ("RawBackModel", 0x435dc),
        ("RawNeutralGain", 0x44c04),
        ("RawNeutralCalibration", 0x44c14),
        ("RawBlackLevel", 0x44ce4),
        ("RawWhiteLevel", 0x41bd4),
        ("RawData", 0x42468),
        ("RawCacheInit", 0x1349a8),
        ("RawCacheConstructor", 0x134818),
        ("ImageCacheConstructor", 0x134ad8),
        ("ProfileFromFile", 0x83008),
        ("ProfileFromEnum", 0x82d7c),
        ("SetColorManager", 0x8271c),
    ],
    "HBImageProcessing": [
        ("AddBaseFilters", 0xefff0),
        ("AddSingleshotRawFilters", 0xf5e98),
        ("AddRGBFilters", 0xf7dc4),
        ("UpdateProcessParams", 0xfd704),
        ("AddOutputFiltersExport", 0xfaf30),
        ("ProcessCropSetup", 0xfd0d4),
        ("ProcessCropGeneral", 0xfc6c8),
        ("ProcessCropSpecific", 0xfcd10),
        ("AddShowCaseHDRFilters", 0xf2d58),
        ("ColorCorrectFilterResult", 0x23da8),
        ("ProcessorOutputImage", 0x778a4),
        ("ColorFilterConstructor", 0x23934),
        ("ProcessorConstructor", 0x77330),
        ("ProcessorAddFilter", 0x77360),
        ("FilterContextConstructor", 0x2c14c),
        ("RawProviderConstructor", 0xed7e8),
        ("ProcessorDestructor", 0x77fc0),
        ("FromCorrection", 0x8e91c),
        ("GenerateImage", 0x8f6c0),
        ("IsGpuEnabled", 0xe1d88),
        ("FilterOutputImage", 0x4ba28),
        ("ProfileFromIccData", 0x7bc70),
        ("ColorSyncConstructor", 0x7b6dc),
        ("GainReduction", 0xff43c),
        ("HighlightStrengthConstructor", 0x1a804),
        ("HighlightStrengthPixel", 0x1af5c),
        ("GammaConstructor", 0x44c4c),
    ],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frameworks", type=Path,
                        default=Path("/Volumes/Phocus/Phocus.app/Contents/Frameworks"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--only", nargs="+", help="Selected labels, otherwise all targets")
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"status": "decompiled-for-review", "vendor_version": "Phocus 4.2.2",
              "architecture": "arm64", "r2_version": subprocess.check_output(["r2", "-v"], text=True).strip(),
              "tool": "r2ghidra pdg", "source_sha256": sha(Path(__file__)),
              "binaries": [], "functions": [],
              "scope": "Inferred C++/ABI types and warnings are retained. Numerical probes are required separately."}
    available = {label for values in TARGETS.values() for label, _ in values}
    if args.only and set(args.only) - available:
        parser.error("Unknown function labels: " + ", ".join(sorted(set(args.only) - available)))
    for name, targets in TARGETS.items():
        selected = [(label, address) for label, address in targets if not args.only or label in args.only]
        if not selected:
            continue
        source = args.frameworks / (name + ".framework") / "Versions/A" / name
        if sha(source) != HASHES[name]:
            raise ValueError("Unrecognized vendor binary: " + str(source))
        thin = output / (name + ".arm64")
        subprocess.run(["xcrun", "lipo", str(source), "-thin", "arm64", "-output", str(thin)], check=True)
        symbols, _ = run_r2(thin, "isj; q")
        (output / (name + ".symbols.json")).write_text(symbols.stdout)
        report["binaries"].append({"name": name, "source": str(source),
                                   "sha256": sha(source), "arm64_sha256": sha(thin)})
        for label, address in selected:
            result, command = run_r2(thin, f"af @ {address}; s {address}; pdg; q")
            if "{" not in result.stdout:
                raise RuntimeError("r2ghidra failed to decode " + label + ": " + result.stderr)
            file = output / (label + ".c")
            file.write_text(result.stdout)
            (output / (label + ".stderr.txt")).write_text(result.stderr)
            report["functions"].append({"library": name, "name": label, "address": hex(address),
                                        "file": file.name, "sha256": sha(file), "command": command,
                                        "warnings": result.stdout.count("WARNING:")})
            (output / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
            print(f"{label}: {len(result.stdout.splitlines())} C lines, {result.stdout.count('WARNING:')} warnings", flush=True)


if __name__ == "__main__":
    main()
