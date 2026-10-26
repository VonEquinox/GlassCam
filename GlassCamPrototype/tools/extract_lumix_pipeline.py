"""Extract the native SDR VE branch's alternate cubes and register tables.

The pinned source framework is an offline oracle only. iOS uses portable code.
The revision-1 archive is preserved so saved photos retain their old rendering.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import struct
import subprocess
import tempfile
import zipfile
import zlib

from extract_lumix_assets import PINNED, STYLES, ROOT, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--analysis-root", type=Path, default=ROOT.parent.parent / "LumixAnalyze")
    parser.add_argument("--output", type=Path, default=Path.home() / "Library/Developer/GlassCamDiagnostics/lumix-full-proraw-20261026")
    args = parser.parse_args()
    framework = args.analysis_root / "work/pkg/Installer.pkg/Payload/SILKYPIX Developer Studio 8 SE.app/Contents/Frameworks/SILKYPIX8.framework/Versions/A/SILKYPIX8"
    if sha(framework.read_bytes()) != PINNED:
        raise RuntimeError("Unrecognized native oracle")
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    args.output.mkdir(parents=True, exist_ok=True)
    work = args.output.resolve()
    evidence = ROOT / "validation/lumix-full-proraw-20261026/evidence"
    evidence.mkdir(parents=True, exist_ok=True)
    for source, name in [("extract_lumix_reference.cpp", "extract"), ("probe_lumix_pipeline.cpp", "probe")]:
        subprocess.run(["xcrun", "clang++", "-arch", "x86_64", "-std=c++17", "-O2", ROOT / "tools" / source, "-o", work / name], env=env, check=True)
    def oracle(program, *params):
        return subprocess.check_output([str(work / program), str(framework), *map(str, params)], text=True)
    constants = oracle("probe", "constants", evidence)
    (evidence / "constants.json").write_text(constants)
    payload = b"".join((evidence / name).read_bytes() for name in
                       ["contrast.bin", "saturation.bin", "monochrome.bin", "low-iso.bin", "temperature.bin"])
    registers = struct.pack("<8s4I", b"GLUMIX2\0", 2, len(payload), zlib.crc32(payload), 106) + payload
    manifest = dict(schemaVersion=2, sourceSHA256=PINNED, cameraID=106, files={}, looks=[])
    rows = {int(p[1]): p for line in oracle("extract", "map").splitlines() if (p := line.split("\t"))[0] == "106"}
    archive = ROOT / "reference_lumix/pipeline.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as bundle:
        bundle.writestr("pipeline.lmp", registers)
        manifest["files"]["pipeline.lmp"] = sha(registers)
        for style in STYLES:
            first, second = (Path(rows[style][i]).stem for i in (5, 6))
            source = framework.parent / "Resources/ColorModeDataBin" / (second + ".s3d")
            raw = work / (second + ".rgb16")
            metadata = json.loads(oracle("extract", "decode", source, raw))
            if metadata != dict(grid=129, gain=1, white=256, matrix=[1,0,0,0,1,0,0,0,1]):
                raise RuntimeError("Unexpected alternate LUT format")
            data = raw.read_bytes()
            packed = struct.pack("<8s6I", b"GLUMIX1\0", 129, 32, 4095, len(data), zlib.crc32(data), 1) + zlib.compress(data, 6)
            name = second + ".lmx"
            bundle.writestr(name, packed)
            manifest["files"][name] = sha(packed)
            manifest["looks"].append(dict(photoStyle=style, first=first, second=second,
                sourceSHA256=sha(source.read_bytes()), decodedSHA256=sha(data)))
            print(f"{style}: {first}/{second}, original alternate cube", flush=True)
        bundle.writestr("manifest.json", json.dumps(manifest, indent=2) + "\n")
    sums = ROOT / "reference_lumix/SHA256SUMS"
    lines = [line for line in sums.read_text().splitlines() if not line.endswith("  pipeline.zip")]
    lines.append(sha(archive.read_bytes()) + "  pipeline.zip")
    sums.write_text("\n".join(lines) + "\n")
    (evidence.parent / "extraction.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
