"""Compile and exercise the production F5 core on macOS without using a camera."""
from pathlib import Path
from native_build import build_command, binary_directory, swift_native_flags
import argparse
import json
import os
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "App/GlassCam"
F5_SWIFT = sorted((SOURCES / "F5").glob("*.swift"))
SWIFT_BASE = [*sorted((SOURCES / "ImagingCore").rglob("*.swift")),
              *sorted((SOURCES / "Capture").glob("*.swift"))]


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

    run("compile-core", build_command('GlassCamNative', sanitize=args.sanitize))
    directory = binary_directory(sanitize=args.sanitize)
    library = directory / 'libGlassCamNative.dylib'
    if args.suite in ("all", "core"):
        run("compile-core-tests", build_command('f5_core_tests', sanitize=args.sanitize))
        run("core-numerics", [directory / "f5_core_tests"],
            {"ASAN_OPTIONS": "detect_leaks=0", "UBSAN_OPTIONS": "halt_on_error=1"} if args.sanitize else None)
    base = ["xcrun", "swiftc", "-swift-version", "5", "-O", "-module-cache-path", work / "modules",
            *swift_native_flags(library)]
    if args.sanitize:
        base += ["-sanitize=address", "-g"]
    link = []
    if args.suite in ("all", "metal"):
        run("compile-metal-tests", [*base, ROOT / "App/GlassCam/F5/F5Errors.swift", ROOT / "App/GlassCam/F5/F5MetalRuntime.swift",
            ROOT / "tests/swift-legacy/apple_f5_metal.swift", *link, "-o", work / "metal-tests"])
        run("metal-numerics", [work / "metal-tests", ROOT / "App/GlassCam/F5/F5Kernels.metal"],
            {"MTL_DEBUG_LAYER": "1", "MTL_SHADER_VALIDATION": "1"})
    if args.suite in ("all", "contracts", "pipeline"):
        run("compile-contract-tests", [*base, *SWIFT_BASE, *F5_SWIFT,
            ROOT / "tests/swift-legacy/F5Fixtures.swift", ROOT / "tests/swift-legacy/apple_f5_contracts.swift", *link, "-o", work / "contract-tests"])
        run("contracts", [work / "contract-tests", work / "fixtures", ROOT / "App/GlassCam/F5/F5Kernels.metal", args.suite],
            {"MTL_DEBUG_LAYER": "1", "MTL_SHADER_VALIDATION": "1"})
    if args.build_offline:
        run("compile-offline", [*base, *SWIFT_BASE, *F5_SWIFT,
            ROOT / "tests/swift-legacy/F5Fixtures.swift", ROOT / "tools/F5OfflineMain.swift", *link, "-o", work / "f5-offline"])
    if args.build_desktop_quality:
        run("compile-desktop-quality", [*base, *SWIFT_BASE, *F5_SWIFT,
            ROOT / "tools/F5DesktopQualityMain.swift", *link, "-o", work / "f5-desktop-quality"])
    if args.build_local_denoise:
        run("compile-local-denoise", [*base, ROOT / "App/GlassCam/F5/F5Errors.swift", ROOT / "App/GlassCam/F5/F5MetalRuntime.swift",
            ROOT / "App/GlassCam/F5/F5LocalDenoise.swift", ROOT / "tools/F5LocalDenoiseMain.swift", *link, "-o", work / "f5-local-denoise"])
    if args.build_gaussian_audit:
        run("compile-gaussian-audit", [*base, ROOT / "App/GlassCam/F5/F5Errors.swift", ROOT / "App/GlassCam/F5/F5MetalRuntime.swift",
            ROOT / "tools/F5GaussianAuditMain.swift", "-o", work / "f5-gaussian-audit"])


if __name__ == "__main__":
    main()
