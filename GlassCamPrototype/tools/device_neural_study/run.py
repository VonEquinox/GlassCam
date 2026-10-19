"""Run one isolated neural study phase on an explicitly selected iPhone."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--device", required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--run-id", required=True)
    p.add_argument("--phase", choices=["probe", "full", "trace-ane", "trace-tensor"], required=True)
    p.add_argument("--backend", default="cpu")
    p.add_argument("--preset", default="standard", choices=["standard", "nature"])
    p.add_argument("--rounds", type=int, default=3)
    p.add_argument("--app", type=Path)
    p.add_argument("--payload", type=Path)
    args = p.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
    prefix = ["xcrun", "devicectl", "device"]
    commands = []

    def run(command, name, stream=False):
        commands.append(command)
        (out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        with (out / name).open("w") as log:
            if stream:
                process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT, text=True, bufsize=1)
                activated = False
                for line in process.stdout:
                    log.write(line); log.flush()
                    if not activated and "Waiting for the application" in line:
                        # CoreDevice can create the process before activating
                        # its scene after installation. Activate the same
                        # process during the app's initial cooldown/window.
                        activation = prefix + ["process", "launch", "--device", args.device, "dev.glasscam.prototype"]
                        commands.append(activation)
                        (out / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
                        subprocess.run(activation, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
                        activated = True
                    if "NEURAL-STUDY" in line or "ERROR" in line:
                        print(line.rstrip(), flush=True)
                code = process.wait()
            else:
                code = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT).returncode
        if code: raise RuntimeError(f"Exit {code}: {out / name}")

    if args.app:
        run(prefix + ["install", "app", "--device", args.device, str(args.app.resolve())], "install.log")
    if args.payload:
        run(prefix + ["copy", "to", "--device", args.device, "--source", str(args.payload.resolve()),
                      "--destination", "Documents/NeuralStudyInput", "--domain-type", "appDataContainer",
                      "--domain-identifier", "dev.glasscam.prototype"], "input-copy.log")
    child = {"NEURAL_PHASE": args.phase, "NEURAL_RUN_ID": args.run_id,
             "NEURAL_BACKEND": args.backend, "NEURAL_PRESET": args.preset, "NEURAL_ROUNDS": str(args.rounds)}
    error = None
    try:
        run(prefix + ["process", "launch", "--device", args.device, "--terminate-existing", "--console",
                      "--environment-variables", json.dumps(child), "dev.glasscam.prototype"], "console.log", stream=True)
    except RuntimeError as exception:
        error = str(exception)
    try:
        run(prefix + ["copy", "from", "--device", args.device, "--source", f"Documents/NeuralStudyResults/{args.run_id}",
                      "--destination", str(out / "results"), "--domain-type", "appDataContainer",
                      "--domain-identifier", "dev.glasscam.prototype"], "output-copy.log")
    except RuntimeError:
        if error: print(error, flush=True)
        raise
    if error: raise RuntimeError(error)
    result = json.loads((out / "results/report.json").read_text())
    print("Collected", result["status"], len(result["rows"]), "rows", flush=True)
    if result["status"] != "complete": raise RuntimeError(result.get("error", "Incomplete report"))


if __name__ == "__main__":
    main()
