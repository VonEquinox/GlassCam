"""Copy user-created state records from a paired iPhone, then verify/analyze on Mac.

Does not launch the app, start cameras, or delete phone records.
"""
from pathlib import Path
import argparse
import datetime
import json
import os
import subprocess
from analyze_peripheral_records import analyze


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Paired device UDID from devicectl list devices")
    parser.add_argument("--output", type=Path, default=Path.home() / "Library/Developer/GlassCamDiagnostics/manual-records")
    args = parser.parse_args()
    output = args.output.expanduser().resolve() / datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    output.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    copied = output / "GlassCamStateRecords"
    subprocess.run(["xcrun", "devicectl", "--json-output", str(output / "transfer.json"),
                    "device", "copy", "from", "--device", args.device,
                    "--domain-type", "appDataContainer", "--domain-identifier", "dev.glasscam.prototype",
                    "--source", "Documents/GlassCamStateRecords", "--destination", str(copied),
                    "--timeout", "120"], env=env, check=True)
    evidence = json.loads((output / "transfer.json").read_text())
    if evidence.get("info", {}).get("outcome") != "success":
        raise SystemExit("Device transfer was not confirmed successful")
    report = analyze(copied, output / "analysis")
    print(json.dumps({"output": str(output), "records": report["recordCount"],
                      "integrityFailures": report["integrityFailures"]}, ensure_ascii=False, indent=2))
    if not report["recordCount"] or report["integrityFailures"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
