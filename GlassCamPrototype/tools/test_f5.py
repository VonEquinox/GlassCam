"""Compile and exercise the production F5 core on macOS without using a camera."""
from pathlib import Path
import argparse
import json
import os
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
F5_SWIFT = sorted((ROOT / "ios/GlassCam").glob("F5*.swift"))
SWIFT_BASE = ["ExportSettings.swift", "SourceImageStore.swift", "PhotoWhiteBalance.swift",
              "HNCSEngine.swift", "FFCSEngine.swift", "LUMIXEngine.swift", "ImagePipeline.swift",
              "PreviewRaster.swift", "ShareDelivery.swift", "CameraSettingsStore.swift",
              "CaptureGeometry.swift", "CaptureJournal.swift", "CaptureWorkflow.swift"]
CPP = ["hncs.cpp", "hncs_spatial.cpp", "hncs_numpy_rng.cpp", "ffcs.cpp", "lumix.cpp",
       "f5_math.cpp", "f5_registration.cpp", "f5_quality.cpp", "f5_c.cpp"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path("/tmp/GlassCam-F5-Tests"))
    parser.add_argument("--suite", choices=["all", "core", "contracts", "metal", "pipeline"], default="all")
    parser.add_argument("--sanitize", action="store_true")
    parser.add_argument("--build-offline", action="store_true", help="Also compile the synthetic production renderer")
    parser.add_argument("--build-desktop-quality", action="store_true", help="Compile the desktop-only unqualified real-ROI experiment")
    parser.add_argument("--build-local-denoise", action="store_true", help="Compile bounded local-transform diagnostic renderer")
    parser.add_argument("--build-gaussian-audit", action="store_true", help="Compile fixed Gaussian data/prior operator diagnostics")
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    results = []

    def run(name, command, extra_env=None):
        started = time.monotonic()
        with (work / f"{name}.log").open("w") as log:
            result = subprocess.run([str(x) for x in command], stdout=log, stderr=subprocess.STDOUT,
                                    env=env | (extra_env or {}))
        results.append(dict(name=name, exit_code=result.returncode, seconds=time.monotonic()-started))
        real_samples=bool(os.environ.get("F5_REAL_BURST"))
        (work / "results.json").write_text(json.dumps(dict(synthetic=not real_samples, camera_used=False,
            real_device_samples_audited=real_samples, results=results), indent=2))
        if result.returncode:
            print((work / f"{name}.log").read_text()[-18000:], flush=True)
            raise SystemExit(result.returncode)
        print(name, "PASS", round(results[-1]["seconds"], 2), "s", flush=True)

    core = ROOT / "core"
    sanitizers = ["-fsanitize=address"] if args.sanitize else []
    run("compile-core", ["xcrun", "clang++", "-std=c++17", "-O2", "-fno-fast-math", "-ffp-contract=off", *sanitizers,
        "-dynamiclib", *(core / name for name in CPP), "-lz", "-pthread", "-o", work / "libglasscam.dylib"])
    if args.suite in ("all", "core"):
        run("compile-core-tests", ["xcrun", "clang++", "-std=c++17", "-O2", *sanitizers, "-I", core,
            ROOT / "tests/f5_core_tests.cpp", "-L", work, "-lglasscam", "-Wl,-rpath,"+str(work), "-o", work / "core-tests"])
        run("core-numerics", [work / "core-tests"])
    base = ["xcrun", "swiftc", "-swift-version", "5", "-O", "-module-cache-path", work / "modules",
            "-I", core, "-import-objc-header", ROOT / "ios/GlassCam/GlassCam-Bridging-Header.h"]
    if args.sanitize:
        base += ["-sanitize=address", "-g"]
    link = ["-L", work, "-lglasscam", "-Xlinker", "-rpath", "-Xlinker", work]
    if args.suite in ("all", "metal"):
        run("compile-metal-tests", [*base, ROOT / "ios/GlassCam/F5Errors.swift", ROOT / "ios/GlassCam/F5MetalRuntime.swift",
            ROOT / "tests/apple_f5_metal.swift", *link, "-o", work / "metal-tests"])
        run("metal-numerics", [work / "metal-tests", ROOT / "ios/GlassCam/F5Kernels.metal"],
            {"MTL_DEBUG_LAYER": "1", "MTL_SHADER_VALIDATION": "1"})
    if args.suite in ("all", "contracts", "pipeline"):
        run("compile-contract-tests", [*base, *(ROOT / "ios/GlassCam" / name for name in SWIFT_BASE), *F5_SWIFT,
            ROOT / "tests/F5Fixtures.swift", ROOT / "tests/apple_f5_contracts.swift", *link, "-o", work / "contract-tests"])
        run("contracts", [work / "contract-tests", work / "fixtures", ROOT / "ios/GlassCam/F5Kernels.metal", args.suite],
            {"MTL_DEBUG_LAYER": "1", "MTL_SHADER_VALIDATION": "1"})
    if args.build_offline:
        run("compile-offline", [*base, *(ROOT / "ios/GlassCam" / name for name in SWIFT_BASE), *F5_SWIFT,
            ROOT / "tests/F5Fixtures.swift", ROOT / "tools/F5OfflineMain.swift", *link, "-o", work / "f5-offline"])
    if args.build_desktop_quality:
        run("compile-desktop-quality", [*base, *(ROOT / "ios/GlassCam" / name for name in SWIFT_BASE), *F5_SWIFT,
            ROOT / "tools/F5DesktopQualityMain.swift", *link, "-o", work / "f5-desktop-quality"])
    if args.build_local_denoise:
        run("compile-local-denoise", [*base, ROOT / "ios/GlassCam/F5Errors.swift", ROOT / "ios/GlassCam/F5MetalRuntime.swift",
            ROOT / "ios/GlassCam/F5LocalDenoise.swift", ROOT / "tools/F5LocalDenoiseMain.swift", *link, "-o", work / "f5-local-denoise"])
    if args.build_gaussian_audit:
        run("compile-gaussian-audit", [*base, ROOT / "ios/GlassCam/F5Errors.swift", ROOT / "ios/GlassCam/F5MetalRuntime.swift",
            ROOT / "tools/F5GaussianAuditMain.swift", "-o", work / "f5-gaussian-audit"])


if __name__ == "__main__":
    main()
