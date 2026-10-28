"""Exercise real native buffer persistence, ZIP export and desktop verification, without a camera."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import zipfile
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools/diagnostics"))
from analyze_peripheral_records import analyze


def main():
    with tempfile.TemporaryDirectory(prefix="glasscam-recording-tests-") as temp:
        work = Path(temp)
        env = os.environ.copy()
        env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
        sources = ROOT / "App/GlassCam"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-module-cache-path", str(work / "modules"),
                        *[str(sources / name) for name in ("Peripheral/PeripheralGlassPolicy.swift", "Peripheral/PeripheralAlignment.swift", "Peripheral/PeripheralFrameInput.swift", "Peripheral/LiveCameraFrame.swift", "Peripheral/PeripheralStateRecording.swift", "Peripheral/PeripheralVisibleSeam.swift", "Peripheral/PeripheralDenseRefinement.swift", "Peripheral/PeripheralLiveDisplay.swift")],
                        str(ROOT / "tests/swift-legacy/apple_peripheral_recording.swift"), "-o", str(work / "tests")], env=env, check=True)
        subprocess.run([str(work / "tests"), str(work / "fixtures")], env=env, check=True)
        fixture = work / "fixtures"
        with zipfile.ZipFile(fixture / "export.zip") as archive:
            assert archive.testzip() is None
            assert len([n for n in archive.namelist() if n.endswith("manifest.json")]) == 2
        directory = analyze(fixture / "records", work / "directory-analysis")
        exported = analyze(fixture / "export.zip", work / "zip-analysis")
        assert directory["recordCount"] == exported["recordCount"] == 2
        assert directory["integrityFailures"] == exported["integrityFailures"] == 0
        assert directory["records"] == exported["records"]
        recorded = next(row for row in directory["records"] if row["pairCount"] == 2)
        assert recorded["submittedGlassState"] == "black"
        assert recorded["analysisReason"] == "expired-before-publication"
        assert recorded["selectedTolerance"] == 2.15
        assert len(list((work / "directory-analysis").rglob("*.png"))) == 1
        # Corruption must be detected instead of reporting an unexplained camera issue.
        native = next((fixture / "records").rglob("*-plane0.bin"))
        native.write_bytes(b"corrupted")
        corrupt = analyze(fixture / "records", work / "corrupt-analysis")
        assert corrupt["integrityFailures"] == 1
        print("PASS desktop: ZIP CRC, all SHA256, identical directory/ZIP analysis, preview, corruption detection")


if __name__ == "__main__":
    main()
