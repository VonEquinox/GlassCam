"""Apply the pre-existing color budget to phone-produced Float32 outputs."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import statistics
import numpy as np


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--results", type=Path, required=True)
    p.add_argument("--payload", type=Path, required=True)
    p.add_argument("--budget", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    root = Path(__file__).resolve().parents[2]
    namespace = {"np": np}
    # Reuse the existing, previously validated pure numerical functions while
    # avoiding unrelated RAW-decoder imports in this small analysis runtime.
    sources = [(root / "reference/hncs_pipeline.py", ["delta_e_2000"]),
               (root / "tools/audit_ffcs_original.py", ["srgb_lab", "summary"]),
               (root / "tools/measure_source_acceleration.py", ["itp", "encoded_srgb"])]
    for path, names in sources:
        nodes = [node for node in ast.parse(path.read_text()).body if isinstance(node, ast.FunctionDef) and node.name in names]
        assert len(nodes) == len(names)
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), namespace)
    budget = json.loads(args.budget.read_text())
    report = json.loads((args.results / "report.json").read_text())
    gains = np.fromfile(args.payload / "synthetic-gains.f32", np.float32).reshape(256, 512)
    rows = []
    for row in report["rows"]:
        if row.get("kind") == "dense-control" or row["status"] != "complete": continue
        data = (args.results / row["output"]).read_bytes()
        assert hashlib.sha256(data).hexdigest() == row["sha256"]
        image = np.frombuffer(data, np.float32).reshape(256, 512, 4)[..., :3].copy()
        reference = np.fromfile(args.results / f"{row['preset']}-cpu.rgba32f", np.float32).reshape(256, 512, 4)[..., :3].copy()
        lab = namespace["srgb_lab"](namespace["encoded_srgb"](image.reshape(-1, 3).astype(np.float64)))
        base_lab = namespace["srgb_lab"](namespace["encoded_srgb"](reference.reshape(-1, 3).astype(np.float64)))
        delta = namespace["delta_e_2000"](base_lab, lab)
        hdr_image = (image * gains[..., None]).astype(np.float32)
        hdr_base = (reference * gains[..., None]).astype(np.float32)
        hdr_delta = 720 * np.linalg.norm(namespace["itp"](hdr_image.reshape(-1, 3)) - namespace["itp"](hdr_base.reshape(-1, 3)), axis=1)
        sdr, hdr = namespace["summary"](delta), namespace["summary"](hdr_delta)
        black = int(np.count_nonzero((image <= 0) & (reference > 0)))
        white = int(np.count_nonzero((image >= 1) & (reference < 1)))
        reversals = int(np.count_nonzero((np.diff(image[4, :, 1]) < 0) & (np.diff(reference[4, :, 1]) >= 0)))
        peak = abs(float(hdr_image.max()) - float(hdr_base.max())) / float(hdr_base.max())
        passed = (all(sdr[k] <= v for k, v in budget["candidate_SDR_deltaE00"].items())
                  and all(hdr[k] <= v for k, v in budget["candidate_HDR_deltaEITP"].items())
                  and black == white == reversals == 0 and peak <= budget["hdr_peak_relative_error_max"])
        result = {"preset": row["preset"], "backend": row["backend"], "point_median_seconds": statistics.median(row["point_seconds"]),
                  "sdr_deltaE00": sdr, "hdr_deltaEITP": hdr, "additional_black": black, "additional_white": white,
                  "gradient_reversals": reversals, "peak_relative_error": peak, "passed_budget": bool(passed),
                  "different_float_channels": int(np.count_nonzero(image.view(np.uint32) != reference.view(np.uint32))),
                  "setup": row["setup"], "metrics": row["metrics"], "before": row["before"], "after": row["after"]}
        rows.append(result)
        print(row["preset"], row["backend"], f"{result['point_median_seconds']*1000:.3f} ms", "HDR max", round(hdr["maximum"], 5), "pass", passed)
    output = {"scope": "Phone synthetic point-stage timing plus full native color/gradation/sharpness/finish error propagation; not full RAW/HEIF timing.",
              "budget": budget, "budget_sha256": hashlib.sha256(args.budget.read_bytes()).hexdigest(),
              "metric_source_hashes": {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path, _ in sources},
              "rows": rows, "raw_report": report}
    args.output.write_text(json.dumps(output, indent=2) + "\n")


if __name__ == "__main__":
    main()
