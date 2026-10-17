"""Read original SILKYPIX 8.1.20 mapping code with radare2/r2ghidra.

This binary ships in RAW FILE CONVERTER EX 3.0, not Fujifilm camera firmware.
The FFCS Python reference and GlassCam are separate implementations. Original
inferred types and warnings are retained for review alongside native probes.
"""
import argparse
import json
from pathlib import Path
import subprocess

from decompile_phocus import run_r2, sha

LIBRARY_SHA256 = "a0bdc416748549eada3086c4fa92015912ca6acc4b07b721f38bd2aa95af61b9"
TARGETS = {
    "MappingConstructor": 0x77ef66,
    "InitGammaTable": 0x77f400,
    "ReadMappingData": 0x787ffc,
    "TransformDispatch": 0x782bec,
    "TransformTrilinear": 0x784968,
    "TransformNormalFixed": 0x782fe2,
    "TransformNormal": 0x784cda,
    "SetStandardDeviation": 0x786556,
    "XYZToLab": 0x755cec,
    "LabToXYZ": 0x755e5e,
    "EncodeSRGB": 0x757252,
    "DecodeSRGB": 0x7573bc,
    "ReadMappingHeaderV2": 0x788086,
    "ReadMappingHeaderV1": 0x78835c,
    "FilteringLine3DCM": 0x92af56,
    "Search3DMapping": 0x79ac1e,
    "Set3DMapping": 0x92bdfc,
    "MakeUpIntegerMatrix": 0x92a290,
    "Filter3DCMConstructor": 0x92a5f8,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--only", nargs="+", choices=sorted(TARGETS))
    args = parser.parse_args()
    library = args.library.resolve()
    if sha(library) != LIBRARY_SHA256:
        raise ValueError("Unrecognized original SILKYPIX library")
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = {"status": "decompiled-for-review", "product": "RAW FILE CONVERTER EX 3.0 powered by SILKYPIX",
              "version": "8.1.20.0", "architecture": "x86_64", "library": str(library),
              "library_sha256": LIBRARY_SHA256, "source_sha256": sha(Path(__file__)),
              "r2_version": subprocess.check_output(["r2", "-v"], text=True).strip(),
              "tool": "r2ghidra pdg", "functions": [],
              "scope": "Original desktop engine entry points; not camera JPEG or full GUI equivalence."}
    for label, address in TARGETS.items():
        if args.only and label not in args.only:
            continue
        result, command = run_r2(library, f"af @ {address}; s {address}; pdg; q")
        if "{" not in result.stdout:
            raise RuntimeError("r2ghidra could not decode " + label + ": " + result.stderr)
        file = out / (label + ".c")
        file.write_text(result.stdout)
        (out / (label + ".stderr.txt")).write_text(result.stderr)
        report["functions"].append({"name": label, "address": hex(address), "file": file.name,
                                    "sha256": sha(file), "warnings": result.stdout.count("WARNING:"),
                                    "command": command})
        (out / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"{label}: {len(result.stdout.splitlines())} C lines", flush=True)


if __name__ == "__main__":
    main()
