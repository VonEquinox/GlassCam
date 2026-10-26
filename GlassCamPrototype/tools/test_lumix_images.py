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
    parser.add_argument("--proraw", type=Path, help="Validate an existing ProRAW capture through full-source export")
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
            *(core / name for name in ["hncs.cpp", "hncs_spatial.cpp", "hncs_numpy_rng.cpp", "ffcs.cpp", "lumix.cpp"]),
            "-lz", "-pthread", "-o", work / "libglasscam.dylib")
        run(sys.executable, ROOT / "tools/prepare_lumix_resources.py", "--output", work / "LUMIX")
        run("bash", ROOT / "tools/prepare_ffcs_resources.sh", ROOT / "reference_ffcs/source.zip", work / "FFCS")
        sources = ROOT / "ios/GlassCam"
        run("xcrun", "swiftc", "-swift-version", "5", "-O", "-module-cache-path", work / "modules",
            "-I", core, "-import-objc-header", sources / "GlassCam-Bridging-Header.h",
            *(sources / name for name in ["ExportSettings.swift", "SourceImageStore.swift", "PhotoWhiteBalance.swift",
                "HNCSEngine.swift", "FFCSEngine.swift", "LUMIXEngine.swift", "ImagePipeline.swift", "PreviewRaster.swift",
                "ShareDelivery.swift", "CameraSettingsStore.swift", "CaptureGeometry.swift", "CaptureJournal.swift", "CaptureWorkflow.swift"]),
            ROOT / "tests/apple_lumix_pipeline.swift", "-L", work, "-lglasscam",
            "-Xlinker", "-rpath", "-Xlinker", work, "-o", work / "images")
        run(work / "images", work / "fixtures", *([args.proraw.resolve()] if args.proraw else []))


if __name__ == "__main__":
    main()
