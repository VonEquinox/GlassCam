"""Independently test V2 matrix isolation before the original mapping reader."""
import argparse
import json
from pathlib import Path
import subprocess

import numpy as np

from audit_x2d_identity import sha
from decompile_ffcs_stages import LIBRARY_SHA256


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audit-dir", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    assert sha(args.library) == LIBRARY_SHA256
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if (out / "report.json").exists():
        raise FileExistsError("Preserve the existing matrix comparison")
    audit = json.loads((args.audit_dir / "report.json").read_text())
    inputs = args.audit_dir / "input-bgr16.bin"
    assert sha(inputs) == audit["input_sha256"]
    source = Path(__file__).with_name("native_ffcs_audit.cpp")
    command = ["xcrun", "clang++", "-std=c++17", "-O2", "-arch", "x86_64", str(source), "-o", str(out / "probe")]
    subprocess.run(command, check=True)
    report = {"library_sha256": LIBRARY_SHA256, "source_sha256": sha(source),
              "tool_sha256": sha(Path(__file__)), "audit_sha256": sha(args.audit_dir / "report.json"),
              "input_sha256": sha(inputs), "command": command, "tables": [], "skipped_v1": []}
    for row in audit["tables"]:
        resource = Path(row["native_file"])
        assert sha(resource) == row["native_sha256"]
        if not resource.read_bytes().startswith(b"ISL_3DMAP_V2"):
            report["skipped_v1"].append(row["asset"])
            continue
        directory = out / row["asset"]
        directory.mkdir(parents=True)
        prefix = directory / "native"
        old = Path(row["command"][-1])
        invocation = [str(out / "probe"), str(args.library), str(resource), str(inputs), str(prefix), "--identity-header"]
        result = subprocess.run(invocation, text=True, capture_output=True, timeout=120)
        (directory / "stdout.txt").write_text(result.stdout)
        (directory / "stderr.txt").write_text(result.stderr)
        result.check_returncode()
        assert sha(resource) == row["native_sha256"]
        native = json.loads(result.stdout)
        identity = np.fromfile(str(prefix) + ".matrix", "<f8").reshape(3, 3)
        assert np.array_equal(identity, np.eye(3))
        checks = {suffix: sha(Path(str(prefix) + suffix)) == sha(Path(str(old) + suffix))
                  for suffix in [".lut", ".gamma-in", ".gamma-out", ".trilinear", ".dispatch"]}
        report["tables"].append({"asset": row["asset"], "resource_sha256": sha(resource),
                                 "samples": native["samples"], "read_matrix_is_identity": True,
                                 "identical_to_original_header": checks, "command": invocation})
        assert all(checks.values())
    assert report["tables"]
    report["status"] = "passed-v2-header-matrix-isolation"
    report["scope"] = "Only a process-local V2 byte copy changes: nine int32 matrix entries at offset 28. Original resource hashes remain unchanged."
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"tables": len(report["tables"]), "skipped_v1": len(report["skipped_v1"]),
                      "samples": sum(row["samples"] for row in report["tables"]), "status": report["status"]}))


if __name__ == "__main__":
    main()
