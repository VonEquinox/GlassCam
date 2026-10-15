"""Run the production image pipeline against Core Image, Metal and HEIF on macOS.

No Python packages are needed. Build products, LUTs and fixtures live in one
temporary directory and are removed on exit; the source checkout is unchanged.
"""
from pathlib import Path
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
        core = ROOT / "core"
        run("xcrun", "clang++", "-std=c++17", "-O2", "-fno-fast-math",
            "-ffp-contract=off", "-dynamiclib", core / "hncs.cpp",
            core / "hncs_spatial.cpp", core / "hncs_numpy_rng.cpp",
            core / "ffcs.cpp", "-lz", "-pthread", "-o", work / "libglasscam.dylib")
        with (work / "resources.log").open("w") as log:
            subprocess.run(["bash", str(ROOT / "tools/prepare_ffcs_resources.sh"),
                            str(ROOT / "reference_ffcs/source.zip"), str(work / "FFCS")],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        swift = ["xcrun", "swiftc", "-swift-version", "5", "-O",
                 "-module-cache-path", work / "modules"]
        run(*swift, ROOT / "tests/apple_ci_strip_roundtrip.swift", "-o", work / "strips")
        run(work / "strips")
        sources = ROOT / "ios/GlassCam"
        run(*swift, "-I", core, "-import-objc-header", sources / "GlassCam-Bridging-Header.h",
            *(sources / name for name in ["ExportSettings.swift", "SourceImageStore.swift",
                                          "HNCSEngine.swift", "FFCSEngine.swift",
                                          "ImagePipeline.swift", "PreviewRaster.swift", "ShareDelivery.swift",
                                          "CameraSettingsStore.swift", "CaptureWorkflow.swift"]),
            ROOT / "tests/apple_image_pipeline.swift", ROOT / "tests/apple_capture_workflow.swift", "-L", work, "-lglasscam",
            "-Xlinker", "-rpath", "-Xlinker", work, "-o", work / "images")
        fixtures = work / "fixtures"
        fixtures.mkdir()
        run(work / "images", fixtures, *([args.raw_source.resolve()] if args.raw_source else []))


if __name__ == "__main__":
    main()
