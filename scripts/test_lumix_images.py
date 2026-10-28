"""Run the production LUMIX Swift/Core Image/HDR pipeline on Mac fixtures."""
from pathlib import Path
import argparse
from contextlib import nullcontext
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Keep diagnostic binaries and fixture images in this directory")
    parser.add_argument("--proraw", type=Path, action="append",
                        help="Existing ProRAW capture (repeat for the color-chain audit)")
    parser.add_argument("--test-source", type=Path, default=ROOT / "tests/swift-legacy/apple_lumix_pipeline.swift",
                        help="Swift entrypoint for production color-pipeline checks")
    parser.add_argument("--swift-source-root", type=Path, default=ROOT / "App/GlassCam",
                        help="Optional isolated Swift source snapshot for audit replay")
    args = parser.parse_args()
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    def run(*args):
        subprocess.run(list(map(str, args)), env=env, check=True)
    with (nullcontext(str(args.output.resolve())) if args.output else tempfile.TemporaryDirectory(prefix="glasscam-lumix-images-")) as temporary:
        work = Path(temporary)
        work.mkdir(parents=True, exist_ok=True)
        core = ROOT / "core"
        run("xcrun", "clang++", "-std=c++17", "-O2", "-fno-fast-math", "-ffp-contract=off", "-dynamiclib",
            *(core / name for name in ["hncs.cpp", "hncs_spatial.cpp", "hncs_numpy_rng.cpp", "ffcs.cpp", "lumix.cpp", "f5_math.cpp", "f5_registration.cpp", "f5_quality.cpp", "f5_c.cpp"]),
            "-lz", "-pthread", "-o", work / "libglasscam.dylib")
        run(sys.executable, ROOT / "scripts/prepare_lumix_resources.py", "--output", work / "LUMIX")
        run("bash", ROOT / "scripts/prepare_ffcs_resources.sh", ROOT / "vendor/ffcs/source.zip", work / "FFCS")
        sources = args.swift_source_root.resolve()
        run("xcrun", "swiftc", "-swift-version", "5", "-O", "-module-cache-path", work / "modules",
            "-I", core, "-import-objc-header", sources / "GlassCam-Bridging-Header.h",
            *(sources / name for name in ["ExportSettings.swift", "SourceImageStore.swift", "PhotoWhiteBalance.swift",
                "HNCSEngine.swift", "FFCSEngine.swift", "LUMIXEngine.swift", "ImagePipeline.swift", "PreviewRaster.swift",
                "ShareDelivery.swift", "CameraSettingsStore.swift", "CaptureGeometry.swift", "CaptureJournal.swift", "CaptureWorkflow.swift"]), *sorted(sources.glob("F5*.swift")),
            args.test_source.resolve(), "-L", work, "-lglasscam",
            "-Xlinker", "-rpath", "-Xlinker", work, "-o", work / "images")
        run(work / "images", work / "fixtures", *([p.resolve() for p in args.proraw] if args.proraw else []))


if __name__ == "__main__":
    main()
