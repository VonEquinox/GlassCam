"""Rebuild the lossless LUMIX resource archive using the supplied native oracle.

Requires macOS/Rosetta only for this extraction, never for an ordinary app build.
The app runs the portable C++ implementation and bundles no SILKYPIX executable.
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

ROOT = Path(__file__).resolve().parents[1]
PINNED = "63738fb40fc09a340bceaae351fc41a699601c50d22a9b4a990bd34ed22b826b"
# Native s_PanaPhotoStyleEnumTable and CAMERA_ID 106 (DC-S1M2).
STYLES = [1, 2, 3, 4, 5, 6, 8, 11, 13, 14, 16, 17, 18, 19, 20, 21]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--analysis-root", type=Path, default=ROOT.parent.parent / "LumixAnalyze")
    args = parser.parse_args()
    framework = args.analysis_root / "work/pkg/Installer.pkg/Payload/SILKYPIX Developer Studio 8 SE.app/Contents/Frameworks/SILKYPIX8.framework/Versions/A/SILKYPIX8"
    if sha(framework.read_bytes()) != PINNED:
        raise SystemExit("The native oracle does not match the audited SILKYPIX framework.")
    reference = ROOT / "reference_lumix"
    reference.mkdir(exist_ok=True)
    validation = ROOT / "validation/lumix-integration-20261026"
    evidence = validation / "evidence"
    evidence.mkdir(parents=True, exist_ok=True)
    vectors = validation / "native-vectors"
    vectors.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    manifest = {"schemaVersion": 1, "sourceSHA256": PINNED, "camera": "DC-S1M2",
                "cameraID": 106, "scope": "Original SDR Photo Style LUT branch; iPhone source adapter, not RW2 equivalence",
                "gridOrder": "RGB uint16 little-endian; R fastest, G next, B slowest",
                "grid": 129, "increment": 32, "white": 4095, "looks": [], "files": {}}
    with tempfile.TemporaryDirectory(prefix="glasscam-lumix-extract-") as temporary:
        work = Path(temporary)
        executable = work / "extract"
        subprocess.run(["xcrun", "clang++", "-arch", "x86_64", "-std=c++17", "-O2",
                        str(ROOT / "tools/extract_lumix_reference.cpp"), "-o", str(executable)], env=env, check=True)
        def oracle(*args):
            return subprocess.check_output([str(executable), str(framework), *map(str, args)], text=True)
        enum = oracle("enum")
        (evidence / "photo-style-enum.tsv").write_text(enum)
        names = {int(line.split("\t")[0]): line.split("\t")[1] for line in enum.splitlines()}
        mapping = oracle("map")
        (validation / "camera-style-map.tsv").write_text(mapping)
        rows = {int(p[1]): p for line in mapping.splitlines() if (p := line.split("\t"))[0] == "106"}
        with zipfile.ZipFile(reference / "source.zip", "w", compression=zipfile.ZIP_STORED) as archive:
            for style in STYLES:
                asset = Path(rows[style][5]).stem
                if not asset: raise RuntimeError(f"Unmapped style {style}")
                source = framework.parent / ("Resources/ColorModeDataBin/" + asset + ".s3d")
                raw = work / (asset + ".rgb16")
                golden = vectors / (asset + ".rgb12")
                metadata = json.loads(oracle("decode", source, raw, golden))
                if metadata != {"grid": 129, "gain": 1, "white": 256, "matrix": [1,0,0,0,1,0,0,0,1]}:
                    raise RuntimeError(f"Unexpected mapping header for {asset}: {metadata}")
                payload = raw.read_bytes()
                if len(payload) != 129**3 * 6: raise RuntimeError("Decoded table length mismatch")
                header = struct.pack("<8s6I", b"GLUMIX1\0", 129, 32, 4095, len(payload), zlib.crc32(payload), 1)
                packed = header + zlib.compress(payload, 6)
                filename = asset + ".lmx"
                archive.writestr(filename, packed)
                manifest["files"][filename] = sha(packed)
                manifest["looks"].append({"photoStyle": style, "enum": names[style], "asset": filename,
                    "sourceFile": source.name, "sourceSHA256": sha(source.read_bytes()),
                    "decodedSHA256": sha(payload), "goldenSHA256": sha(golden.read_bytes()),
                    "nativeVectorCount": len(golden.read_bytes()) // 12})
                print(f"{names[style]}: {asset}, {len(packed):,} bytes, {129}³ original grid", flush=True)
            archive.writestr("manifest.json", json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    data = (reference / "source.zip").read_bytes()
    (reference / "SHA256SUMS").write_text(sha(data) + "  source.zip\n")
    (validation / "extraction.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"Saved {len(manifest['looks'])} original looks; archive {len(data):,} bytes.")


if __name__ == "__main__":
    main()
