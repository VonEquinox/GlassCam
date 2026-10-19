"""Run the opt-in Release benchmark on one explicitly selected physical iPhone.

Build GlassCam with SWIFT_ACTIVE_COMPILATION_CONDITIONS=GLASSCAM_PERFORMANCE.
An optional --app installs that build without uninstalling the existing app.
Runs are serialized. Input transfer, console transport, report transfer and
hash validation are outside the in-app latency measurements.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess


CONFIGURATIONS = ["hncs-standard", "hncs-nature", "ffcs-provia", "ffcs-acros"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--raw-source", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--run-id", default=datetime.now(timezone.utc).strftime("phone-%Y%m%d-%H%M%S"))
    parser.add_argument("--rounds", type=int, choices=range(0, 11), default=5)
    parser.add_argument("--configurations", nargs="+", choices=CONFIGURATIONS, default=CONFIGURATIONS)
    parser.add_argument("--sizes", nargs="+", type=int, choices=[24, 48], default=[48, 24])
    parser.add_argument("--no-controls", action="store_true")
    args = parser.parse_args()
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if (out / "run.json").exists():
        raise FileExistsError(f"Refusing to replace an existing run in {out}")
    environment = dict(os.environ)
    environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    base = ["xcrun", "devicectl", "device"]
    bundle = "dev.glasscam.prototype"
    commands = []

    def run(command, logname, stream=False):
        commands.append(command)
        (out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        with (out / logname).open("w") as log:
            if stream:
                process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT, text=True, bufsize=1)
                for line in process.stdout:
                    log.write(line)
                    log.flush()
                    if "GLASSCAM-DEVICE-PERF" in line or "ERROR" in line:
                        print(line.rstrip(), flush=True)
                result = process.wait()
            else:
                result = subprocess.run(command, env=environment, stdout=log,
                                        stderr=subprocess.STDOUT).returncode
        if result:
            raise RuntimeError(f"Command exited {result}; see {out / logname}")

    run(base + ["info", "details", "--device", args.device, "--json-output", str(out / "device.json")], "device.log")
    if args.app:
        run(base + ["install", "app", "--device", args.device, str(args.app.resolve())], "install.log")
    source = args.raw_source.resolve()
    run(base + ["copy", "to", "--device", args.device, "--source", str(source),
                "--destination", "Documents/PerformanceInput/source.dng", "--domain-type", "appDataContainer",
                "--domain-identifier", bundle], "input-transfer.log")
    source_hash = sha(source)
    (out / "run.json").write_text(json.dumps({
        "run_id": args.run_id, "rounds": args.rounds, "sizes": args.sizes,
        "configurations": args.configurations, "source_sha256": source_hash,
        "source_bytes": source.stat().st_size, "controls": not args.no_controls,
        "scope": "Physical-device production export/review; excludes camera and Photos."
    }, indent=2) + "\n")
    for configuration in args.configurations:
        local = out / configuration
        if local.exists():
            raise FileExistsError(f"Refusing to replace {local}")
        child = {"GLASSCAM_PERFORMANCE_RUN": args.run_id,
                 "GLASSCAM_PERFORMANCE_CONFIG": configuration,
                 "GLASSCAM_PERFORMANCE_ROUNDS": str(args.rounds),
                 "GLASSCAM_PERFORMANCE_SIZES": ",".join(map(str, args.sizes)),
                 "GLASSCAM_PERFORMANCE_CONTROLS": "0" if args.no_controls else "1",
                 "GLASSCAM_PERFORMANCE_SOURCE_SHA256": source_hash}
        print(f"Starting {configuration}", flush=True)
        try:
            run(base + ["process", "launch", "--device", args.device, "--terminate-existing", "--console",
                        "--environment-variables", json.dumps(child), bundle], f"{configuration}-console.log", stream=True)
        finally:
            run(base + ["copy", "from", "--device", args.device,
                        "--source", f"Documents/PerformanceResults/{args.run_id}/{configuration}",
                        "--destination", str(local), "--domain-type", "appDataContainer",
                        "--domain-identifier", bundle], f"{configuration}-transfer.log")
        report = json.loads((local / "report.json").read_text())
        assert report["status"] == "complete", report.get("error")
        assert report["source_sha256"] == source_hash
        render_calls = set()
        for row in report["samples"]:
            assert sha(local / row["file"]) == row["encoded_sha256"]
            assert row["output_depth"] == 10 and row["output_is_hdr"]
            if not row["timing_off_control"]:
                assert row["export_unattributed_seconds"] >= 0, "Overlapping timing spans"
                render_calls.add(row["stage_calls"]["raw_render"])
        assert len(render_calls) == 1 and min(render_calls) > 0, "Every size must process the same full source"
        print(f"Verified {configuration}: {len(report['samples'])} HDR outputs transferred", flush=True)


if __name__ == "__main__":
    main()
