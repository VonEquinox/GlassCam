"""Run the production image pipeline against Core Image, Metal and HEIF on macOS.

No Python packages are needed. Native products use the SwiftPM build cache;
Swift runners, LUTs and fixtures are removed with their temporary directory.
"""
from pathlib import Path
from native_build import build_product, swift_native_flags
import argparse
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw-source', type=Path, help='Also export a local full-resolution DNG fixture')
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("Requires macOS with Apple developer tools and Metal.")
    with tempfile.TemporaryDirectory(prefix="glasscam-apple-images-") as directory:
        work = Path(directory)
        library = build_product()
        with (work / "resources.log").open("w") as log:
            subprocess.run(["bash", str(ROOT / "scripts/prepare_ffcs_resources.sh"),
                            str(ROOT / "vendor/ffcs/source.zip"), str(work / "FFCS")],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        run("python3", ROOT / "scripts/prepare_lumix_resources.py", "--output", work / "LUMIX")
        swift = ["xcrun", "swiftc", "-swift-version", "5", "-O",
                 "-module-cache-path", work / "modules"]
        run(*swift, ROOT / "tests/swift-legacy/apple_ci_strip_roundtrip.swift", "-o", work / "strips")
        run(work / "strips")
        sources = ROOT / "App/GlassCam"
        run(*swift, *swift_native_flags(library),
            *(sources / name for name in ["ExportSettings.swift", "SourceImageStore.swift",
                                          "PhotoWhiteBalance.swift", "HNCSEngine.swift", "FFCSEngine.swift", "LUMIXEngine.swift",
                                          "ImagePipeline.swift", "PreviewRaster.swift", "ShareDelivery.swift",
                                          "CameraSettingsStore.swift", "CaptureGeometry.swift", "CaptureJournal.swift", "CaptureWorkflow.swift"]), *sorted(sources.glob("F5*.swift")),
            ROOT / "tests/swift-legacy/apple_image_pipeline.swift", ROOT / "tests/swift-legacy/apple_capture_workflow.swift",
            ROOT / "tests/swift-legacy/apple_capture_recovery.swift", "-o", work / "images")
        fixtures = work / "fixtures"
        fixtures.mkdir()
        run(work / "images", fixtures, *([args.raw_source.resolve()] if args.raw_source else []))


if __name__ == "__main__":
    main()
