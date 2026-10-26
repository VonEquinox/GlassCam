"""Replay small common motions on verified original camera records, without a phone.

Supply one or more exported record ZIPs. This is a controlled image perturbation,
not a real camera-motion benchmark or an optical calibration.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

from analyze_peripheral_records import analyze

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archives", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tolerance", type=float, default=1)
    parser.add_argument("--sources", type=Path, default=ROOT / "ios/GlassCam",
                        help="Optional preserved source snapshot for a before/after comparison")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    with tempfile.TemporaryDirectory(prefix="glasscam-seam-stability-") as temporary:
        work = Path(temporary)
        inputs = work / "inputs"
        inputs.mkdir()
        fingerprints = {}
        for index, path in enumerate(args.archives):
            archive = path.resolve()
            audit = analyze(archive, output / f"input-audit-{index + 1}")
            if not audit["recordCount"] or audit["integrityFailures"]:
                raise SystemExit("Input integrity failed")
            with archive.open("rb") as stream:
                fingerprints[str(archive)] = hashlib.file_digest(stream, "sha256").hexdigest()
            with zipfile.ZipFile(archive) as container:
                for entry in container.infolist():
                    path = Path(entry.filename)
                    if path.is_absolute() or ".." in path.parts:
                        raise SystemExit("Invalid input path")
                container.extractall(inputs / str(index))
        library = work / "ReplayLibrary.swift"
        library.write_text((ROOT / "tools/replay_peripheral_native.swift").read_text().replace(
            "@main\nstruct NativeFieldReplay", "struct NativeFieldReplay"))
        names = ("PeripheralGlassPolicy.swift", "PeripheralVisibleSeam.swift", "PeripheralDenseRefinement.swift",
                 "PeripheralLiveDisplay.swift", "PeripheralAlignment.swift", "PeripheralStateRecording.swift",
                 "PeripheralGlassShader.swift")
        executable = work / "stability"
        with (output / "compile.log").open("w") as log:
            subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O",
                            "-module-cache-path", str(work / "modules"),
                            *[str(args.sources / name) for name in names], str(library),
                            str(ROOT / "tools/replay_peripheral_stability.swift"), "-o", str(executable)],
                           check=True, env=env, stdout=log, stderr=subprocess.STDOUT)
        subprocess.run([str(executable), str(inputs), str(output / "motion.json"), str(args.tolerance)],
                       check=True, env=env)
        (output / "inputs.json").write_text(json.dumps(fingerprints, indent=2) + "\n")


if __name__ == "__main__":
    main()
