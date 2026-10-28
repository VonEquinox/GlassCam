"""Build the ordinary iPhone Release; install only with --install-device.

Uses the project's existing development team. --refresh-signing asks Xcode to
renew provisioning; it does not enroll an account or purchase a membership.
"""
from pathlib import Path
import argparse
import datetime
import json
import os
import plistlib
import subprocess
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path.home() / "Library/Developer/GlassCamRelease")
    parser.add_argument("--unsigned", action="store_true", help="Compile without signing; cannot install")
    parser.add_argument("--refresh-signing", action="store_true", help="Allow Xcode to update existing provisioning")
    parser.add_argument("--install-device", help="Explicit CoreDevice ID of the already paired iPhone to install and launch")
    args = parser.parse_args()
    if args.unsigned and (args.install_device or args.refresh_signing):
        parser.error("--unsigned cannot be combined with installation or provisioning updates")
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    build_env = os.environ.copy()
    build_env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    command = ["xcodebuild", "-project", str(ROOT / "App/GlassCam.xcodeproj"),
               "-scheme", "GlassCam", "-configuration", "Release", "-destination", "generic/platform=iOS",
               "-derivedDataPath", str(output)]
    if args.unsigned:
        command.append("CODE_SIGNING_ALLOWED=NO")
    if args.refresh_signing:
        command.append("-allowProvisioningUpdates")
    command.append("build")
    log = output / "release-build.log"
    print(f"Building ordinary Release; log: {log}", flush=True)
    with log.open("w") as stream:
        result = subprocess.run(command, env=build_env, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-60:]))
        raise SystemExit(result.returncode)
    app = output / "Build/Products/Release-iphoneos/GlassCam.app"
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    report = {"app": str(app), "bundle_identifier": info["CFBundleIdentifier"], "signed": not args.unsigned,
              "installed": False, "launched": False}
    if not args.unsigned:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        profile = app / "embedded.mobileprovision"
        decoded = subprocess.check_output(["security", "cms", "-D", "-i", str(profile)], stderr=subprocess.DEVNULL)
        expiry = plistlib.loads(decoded)["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
        report["expires_at"] = expiry.astimezone(ZoneInfo("Asia/Shanghai")).isoformat()
    if args.install_device:
        for name, action in [
            ("install", ["device", "install", "app", "--device", args.install_device, str(app)]),
            ("launch", ["device", "process", "launch", "--device", args.install_device,
                        "--terminate-existing", info["CFBundleIdentifier"]]),
        ]:
            evidence = output / f"{name}.json"
            subprocess.run(["xcrun", "devicectl", "--json-output", str(evidence), *action], env=build_env, check=True)
            result = json.loads(evidence.read_text())
            if result.get("info", {}).get("outcome") != "success":
                raise SystemExit(f"Device {name} was not confirmed successful; inspect {evidence}")
            report["installed" if name == "install" else "launched"] = True
    (output / "release.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
