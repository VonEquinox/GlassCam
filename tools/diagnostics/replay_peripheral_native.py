"""Verify a manual-record ZIP and replay native camera inputs with production Swift on Mac.

No phone access. Cold acquisition and recorded-candidate acquisition are separate
reports. Repeated static-input liveness uses virtual time and is not a video test.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
import zipfile
from analyze_peripheral_records import analyze

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--render", action="store_true", help="Save static offscreen production-Metal previews; not phone screenshots")
    parser.add_argument("--real-clock", action="store_true", help="Also test actual-clock native worker/GPU recovery on static scenes 1, 3, 7")
    parser.add_argument("--tolerance", type=float, default=1.0, help="Replay the actual matching tolerance multiplier")
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    integrity = analyze(args.archive.resolve(), output / "input-audit")
    if not integrity["recordCount"] or integrity["integrityFailures"]:
        raise SystemExit("Original input integrity failed")
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    with tempfile.TemporaryDirectory(prefix="glasscam-native-field-replay-") as temp:
        work = Path(temp)
        sources = ROOT / "App/GlassCam"
        names = ("Peripheral/PeripheralGlassPolicy.swift", "Peripheral/PeripheralVisibleSeam.swift", "Peripheral/PeripheralDenseRefinement.swift", "Peripheral/PeripheralLiveDisplay.swift", "Peripheral/PeripheralAlignment.swift", "Peripheral/PeripheralStateRecording.swift", "Peripheral/PeripheralGlassShader.swift")
        executable = work / "replay"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-module-cache-path", str(work / "modules"),
                        *[str(sources / name) for name in names], str(ROOT / "tools/diagnostics/replay_peripheral_native.swift"),
                        "-o", str(executable)], env=env, check=True)
        inputs = work / "inputs"
        inputs.mkdir()
        with zipfile.ZipFile(args.archive) as archive:
            for entry in archive.infolist():
                path = Path(entry.filename)
                if path.is_absolute() or ".." in path.parts:
                    raise SystemExit("Invalid archive path")
            archive.extractall(inputs)
        reports = {}
        for name, flags in [("cold-acquisition", []), ("recorded-candidate", ["--recorded-candidate"])]:
            target = output / (name + ".json")
            subprocess.run([str(executable), str(inputs), str(target), "--wait-dense", "--tolerance", str(args.tolerance), *flags,
                            *(["--render"] if args.render and name == "cold-acquisition" else []),
                            *(["--real-clock"] if args.real_clock and name == "cold-acquisition" else [])], env=env, check=True)
            report = json.loads(target.read_text())
            reports[name] = {"recordCount": len(report["records"]),
                             "liveAllPanesFullyClear": [row["scene"] for row in report["records"] if row.get("livePreview", {}).get("maximumOpacity", 1)<.001],
                             "liveAllPanesVisible": [row["scene"] for row in report["records"] if row.get("livePreview", {}).get("maximumOpacity", 1)<.999],
                             "permitsDisplay": [row["scene"] for row in report["records"] if row.get("permitsDisplay")],
                             "somePeripheralPaneVisible": [row["scene"] for row in report["records"]
                                                           if row.get("staticRepeatedInputMinimumOpacity", 1) < .999],
                             "somePeripheralPaneFullyClear": [row["scene"] for row in report["records"]
                                                              if row.get("staticRepeatedInputMinimumOpacity") == 0],
                             "staticRepeatedInputFullyClear": [row["scene"] for row in report["records"]
                                                               if row.get("staticRepeatedInputEffectiveOpacity") == 0]}
        with args.archive.open("rb") as stream:
            fingerprint = hashlib.file_digest(stream, "sha256").hexdigest()
        summary = {"archiveSHA256": fingerprint, "tolerance": args.tolerance, "reports": reports,
                   "limits": "Static snapshots have no transparency ground truth; virtual-time repetition is not recorded camera motion or final Glass compositing."}
        (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
