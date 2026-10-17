"""Create readable, hash-locked Phocus C decompilations with r2 + r2ghidra.

Never modifies the original frameworks. Correct ABI signatures are supplied
for the small, independently probed functions. Complex C++ functions retain
the decompiler's inferred signature and warnings; output is analysis, not code
to compile or a replacement for original-function numerical tests.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

HASHES = {
    "HBStorage": "c311cedfe841f757a3154713f24e08de1601f0ad6a57d601c25e21cd1ce87826",
    "HBImageProcessing": "125dd5b0bf0cc1ad00d1cf959eeeea82aa24acee117c2b2bcb55fa44f430d010",
}
TARGETS = {
    "HBStorage": [
        ("SetDefaultSharpness", 0x32a90, "void reset_sharpness(void *correction)"),
        ("DecodePartFrom", 0x34ac8, None),
        ("EffectiveSharpnessAmount", 0x32228, "double effective_sharpness(void *correction, double baseline, int compensation)"),
        ("GetBaselineSharpness", 0x43c28, "double baseline_sharpness(void *raw_file)"),
        ("GetIsoGain", 0x41770, "double iso_code_gain(void *raw_file)"),
    ],
    "HBImageProcessing": [
        ("AddPostViewerRGBFilters", 0xfa0dc, None),
        ("SharpnessConstructor", 0xd7028, "void construct_sharpness(void *filter, int amount, double radius, int noise, int dark, int width, double image_scale, double hdr_scale)"),
        ("SharpnessResult", 0xd7158, None),
        ("SharpnessContext", 0x95d20, "void construct_context(void *context, unsigned int width, int amount, double radius, int noise, int dark, double unused, double image_scale, double hdr_scale)"),
        ("RadiusScaleCorrection", 0x95c00, "double corrected_radius(double radius, double image_scale)"),
        ("AmountTable", 0x95eac, "void make_amount_table(void *context)"),
        ("NoiseTable", 0x9605c, "void make_noise_table(void *context)"),
        ("KernelWeights", 0x960e8, "void make_kernel_weights(void *context)"),
        ("RepeatMargin", 0x142ec8, None),
        ("Grayscale", 0x11d238, None),
        ("Saturation", 0xb5d1c, None),
        ("RGBToHSL", 0xf568, "void rgb_to_hsl(float red, float green, float blue, float *hue, float *saturation, float *lightness)"),
        ("HSLToRGB", 0xf6b0, "void hsl_to_rgb(float hue, float saturation, float lightness, float *red, float *green, float *blue)"),
    ],
}
CONSTANTS = {
    "HBStorage": {"baseline_factor": 0x14dfd8, "amount_anchor": 0x14cb40},
    "HBImageProcessing": {"log_two": 0x1833d0, "large_radius_offset": 0x1840e8,
        "large_radius_scale": 0x181df8, "small_radius_offset": 0x1890d8,
        "small_radius_scale": 0x1890e0, "large_radius_far_offset": 0x1890e8,
        "large_radius_far_scale": 0x1890f0, "small_radius_far_offset": 0x1890f8,
        "small_radius_far_scale": 0x189100, "hdr_work_scale": 0x184d70},
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_r2(path, commands):
    command = ["r2", "-q", "-e", "scr.color=false", "-e", "bin.relocs.apply=true", "-c", commands, str(path)]
    result = subprocess.run(command, text=True, capture_output=True, timeout=45, check=True)
    return result, command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frameworks", type=Path, default=Path("/Volumes/Phocus/Phocus.app/Contents/Frameworks"))
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    out = args.output_dir.resolve(); out.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output(["r2", "-v"], text=True).strip()
    binaries, functions, constants = [], [], {}
    for name, targets in TARGETS.items():
        source = args.frameworks / (name + ".framework") / "Versions/A" / name
        assert sha(source) == HASHES[name], "Unrecognized Phocus framework: " + str(source)
        thin = out / (name + ".arm64")
        subprocess.run(["xcrun", "lipo", str(source), "-thin", "arm64", "-output", str(thin)], check=True)
        binaries.append({"name": name, "source": str(source), "source_sha256": sha(source), "thin_sha256": sha(thin)})
        constants[name] = {}
        for label, address in CONSTANTS[name].items():
            result, _ = run_r2(thin, f"pxj 8 @ {address}; q")
            raw = bytes(json.loads(result.stdout.strip()))
            constants[name][label] = {"address": hex(address), "double": struct.unpack("<d", raw)[0], "bytes": raw.hex()}
        for label, address, signature in targets:
            commands = f"af @ {address}; s {address}; "
            if signature:
                function_name = signature.split("(")[0].split()[-1]
                commands += f"afn {function_name}; afs {signature}; "
            result, command = run_r2(thin, commands + "pdg; q")
            assert "{" in result.stdout and len(result.stdout) > 60, "r2ghidra pdg unavailable or function not decoded"
            file = out / (label + ".c")
            file.write_text(result.stdout)
            (out / (label + ".stderr.txt")).write_text(result.stderr)
            functions.append({"binary": name, "name": label, "address": hex(address), "signature": signature,
                              "file": file.name, "sha256": sha(file), "warnings": result.stdout.count("WARNING:"),
                              "command": command})
            print("Decompiled", label, hex(address), flush=True)
    report = {"status": "decompiled-for-review", "r2_version": version, "tool": "r2ghidra pdg",
              "script_sha256": sha(Path(__file__)), "binaries": binaries, "functions": functions, "constants": constants,
              "note": "Signatures are supplied from verified ABI calls. Complex C++ types and indirect calls can remain ambiguous; warnings are preserved. Constants are read through r2 from the same hash-locked arm64 slice."}
    (out / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Saved", len(functions), "readable C files and exact constant values.")


if __name__ == "__main__":
    main()
