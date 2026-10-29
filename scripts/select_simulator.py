"""Select an existing, available iPhone simulator without changing simulator state."""

import argparse
import json
import subprocess
import sys


def version_key(version):
    return tuple(int(part) for part in (version.split(".") + ["0", "0", "0"])[:3])


def select(devices, runtimes, requested=None):
    available_runtimes = {
        runtime["identifier"]: version_key(runtime["version"])
        for runtime in runtimes
        if runtime.get("isAvailable")
        and runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
        and int(runtime["version"].split(".")[0]) >= 27
    }
    candidates = [
        (device, available_runtimes[runtime])
        for runtime, group in devices.items()
        if runtime in available_runtimes
        for device in group
        if device.get("isAvailable")
        and device.get("deviceTypeIdentifier", "").startswith("com.apple.CoreSimulator.SimDeviceType.iPhone-")
    ]
    if requested:
        candidates = [item for item in candidates if item[0]["udid"].lower() == requested.lower()]
    if not candidates:
        detail = f"SIMULATOR_ID={requested} is not an available iPhone simulator running iOS 27 or later." if requested else (
            "No available iPhone simulator running iOS 27 or later was found."
        )
        raise ValueError(detail + " Select an existing simulator with SIMULATOR_ID; no runtime or simulator was created.")
    # Prefer a running simulator, then the newest runtime, then a stable device type/UUID order.
    candidates.sort(key=lambda item: (
        item[0]["state"] != "Booted", tuple(-part for part in item[1]),
        item[0]["deviceTypeIdentifier"], item[0]["udid"],
    ))
    return candidates[0][0]["udid"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--id", help="Require this existing simulator UUID")
    args = parser.parse_args()
    try:
        inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "--json"], text=True))
        print(select(inventory["devices"], inventory["runtimes"], args.id))
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Simulator selection failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
