"""Explicit opt-in macOS checks for the production peripheral glass components.

Compiles and runs the actual Swift policy, Vision registration, independent seam
measurement and Metal shader. Does not access a camera or Photos. Run after test authorization.
"""
from pathlib import Path
import platform
import argparse
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitize", action="store_true", help="Enable AddressSanitizer for the actual production Swift components")
    parser.add_argument("--benchmark", action="store_true", help="Only run the Mac matching microbenchmark; no phone performance claims")
    parser.add_argument("--dense-gold", action="store_true", help="Run the actual bidirectional Vision model against an independent known displacement/exposure fixture")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise SystemExit("Requires macOS, Xcode and Metal")
    with tempfile.TemporaryDirectory(prefix="glasscam-peripheral-") as directory:
        work = Path(directory)
        env = os.environ.copy()
        env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
        sources = ROOT / "App/GlassCam"
        command = ["xcrun", "swiftc", "-swift-version", "5", "-O", "-module-cache-path", str(work / "modules")]
        if args.sanitize:
            command += ["-sanitize=address"]
        command += [str(sources / name) for name in ["CameraSessionRecovery.swift", "PeripheralGlassPolicy.swift", "PeripheralGlassShader.swift", "PeripheralAlignment.swift", "PeripheralStateRecording.swift", "PeripheralVisibleSeam.swift", "PeripheralDenseRefinement.swift", "PeripheralLiveDisplay.swift"]]
        command += [str(ROOT / "tests/swift-legacy/apple_peripheral_glass.swift"), "-o", str(work / "peripheral")]
        subprocess.run(command, check=True, env=env)
        if args.sanitize:
            env.setdefault("ASAN_OPTIONS", "detect_leaks=0")
        subprocess.run([str(work / "peripheral")] + (["--benchmark"] if args.benchmark else ["--dense-gold"] if args.dense_gold else []), check=True, env=env)
        if not args.benchmark and not args.dense_gold:
            timing_command = ["xcrun", "swiftc", "-swift-version", "5", "-O", "-module-cache-path", str(work / "modules")]
            if args.sanitize:
                timing_command += ["-sanitize=address"]
            subprocess.run([*timing_command, str(sources / "PeripheralGlassPolicy.swift"),
                            str(ROOT / "tests/swift-legacy/apple_peripheral_timing.swift"), "-o", str(work / "timing")], check=True, env=env)
            subprocess.run([str(work / "timing"), str(ROOT / "tests/fixtures/peripheral/phone-glass-timing-20261023.json"),
                            str(work / "timing-result.json")], check=True, env=env)


if __name__ == "__main__":
    main()
