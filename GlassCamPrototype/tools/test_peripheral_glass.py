"""Explicit opt-in macOS checks for the production peripheral glass components.

Compiles and runs the actual Swift policy, Vision registration, independent seam
measurement and Metal shader. Does not access a camera or Photos. Run after test authorization.
"""
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Requires macOS, Xcode and Metal")
    with tempfile.TemporaryDirectory(prefix="glasscam-peripheral-") as directory:
        work = Path(directory)
        sources = ROOT / "ios/GlassCam"
        command = ["xcrun", "swiftc", "-swift-version", "5", "-O", "-module-cache-path", str(work / "modules")]
        command += [str(sources / name) for name in ["PeripheralGlassPolicy.swift", "PeripheralGlassShader.swift", "PeripheralAlignment.swift"]]
        command += [str(ROOT / "tests/apple_peripheral_glass.swift"), "-o", str(work / "peripheral")]
        subprocess.run(command, check=True)
        subprocess.run([str(work / "peripheral")], check=True)


if __name__ == "__main__":
    main()
