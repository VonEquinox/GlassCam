"""Validate complete phone exports, summarize latency, and retain trace boundaries."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import xml.etree.ElementTree as ET


def stats(values):
    return {"median": statistics.median(values), "minimum": min(values), "maximum": max(values), "samples": values}


def trace_labels(path, column):
    root = ET.parse(path).getroot()
    identifiers = {e.get("id"): e for e in root.iter() if e.get("id")}
    result = []
    for row in root.iter("row"):
        cells = [identifiers.get(e.get("ref"), e) for e in row]
        result.append({"label": cells[column].get("fmt", ""),
                       "start_ns": int(cells[0].text or 0), "duration_ns": int(cells[1].text or 0)})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    project = Path(__file__).resolve().parents[2]
    previous = json.loads((project / "validation/iphone-performance-20261018.json").read_text())
    probe = json.loads((root / "probe-analysis.json").read_text())
    variants = ["cpu", "ml-fp32-ne", "ml-padded16-cpu", "ml-padded16-ne", "tensor8-fp32", "tensor8-fp16"]
    reports, rows, codec_probes = {}, [], []
    for variant in variants:
        folder = root / ("full-" + variant) / "results"
        report = json.loads((folder / "report.json").read_text())
        assert report["status"] == "complete" and report["backend"] == variant
        assert report["source_sha256"] == previous["source"]["sha256"]
        assert len(report["rows"]) == 8
        reports[variant] = report
        for value in report["rows"]:
            assert hashlib.sha256((folder / value["file"]).read_bytes()).hexdigest() == value["sha256"]
            assert value["depth"] == 10
            assert [value["width"], value["height"]] == ([4242, 5656] if value["megapixels"] == 24 else [6048, 8064])
            assert value["metrics"]["context_delta_max"] <= 1e-12
            assert value["metrics"]["calls"] == (0 if variant == "cpu" else 126)
        for size in [24, 48]:
            group = [v for v in report["rows"] if v["megapixels"] == size]
            warm = [v for v in group if not v["warmup"]]
            assert len(warm) == 3 and len({v["sha256"] for v in group}) == 1
            if variant == "cpu":
                original = next(v for v in previous["rows"] if v["configuration"] == "hncs-standard" and v["megapixels"] == size)
                assert warm[0]["sha256"] == original["encoded_sha256"]
                quality = {"reference": True, "passed_hdr_budget": True}
            else:
                quality = json.loads((root / "full-quality" / f"{variant}-{size}.json").read_text())
                mapping = {"mean": "mean_deltaEITP", "p95": "p95_deltaEITP", "p99": "p99_deltaEITP", "maximum": "maximum_deltaEITP"}
                quality["passed_hdr_budget"] = (all(quality[mapping[key]] <= bound for key, bound in probe["budget"]["candidate_HDR_deltaEITP"].items())
                    and quality["additional_black_channels"] == quality["additional_white_channels"] == 0
                    and abs(quality["actual_peak_rgb_nits"] / quality["reference_peak_rgb_nits"] - 1) <= probe["budget"]["hdr_peak_relative_error_max"])
            reference = reports["cpu"]["rows"]
            base = statistics.median(v["total_seconds"] for v in reference if not v["warmup"] and v["megapixels"] == size)
            total = stats([v["total_seconds"] for v in warm])
            rows.append({"variant": variant, "megapixels": size, "seconds": total,
                         "duration_change_percent": 100 * (total["median"] / base - 1),
                         "color_stage_seconds": stats([v["stages_seconds"]["color_engine"] for v in warm]),
                         "backend_components": {key: stats([v["metrics"][key] for v in warm]) for key in warm[0]["metrics"] if key != "context_delta_max"},
                         "all_repeated_files_identical": True, "output_sha256": warm[0]["sha256"], "quality": quality})
            file = folder / warm[0]["file"]
            command = ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                       "stream=codec_name,pix_fmt,color_transfer,color_primaries", "-of", "json", str(file)]
            result = json.loads(subprocess.check_output(command, text=True))["streams"][0]
            assert result["pix_fmt"] == "yuv420p10le" and result["color_transfer"] == "smpte2084" and result["color_primaries"] == "bt2020"
            codec_probes.append({"variant": variant, "megapixels": size, "result": result, "command": command})
    ane = trace_labels(root / "core-ai-ane.xml", 4)
    ane_predictions = [r for r in ane if "standard-small-padded16_" in r["label"] and r["label"].endswith(" Prediction")]
    assert len(ane_predictions) == 46
    gpu = trace_labels(root / "gpu-execution.xml", 6)
    gpu_study = [r for r in gpu if "standard-small-" in r["label"] and "GlassCam (5719)" in r["label"]]
    assert any("tensor8-fp16" in r["label"] for r in gpu_study)
    samples = [s for r in reports.values() for s in r["rows"] if not s["warmup"]]
    nominal = all(s["before"]["thermal"] == s["after"]["thermal"] == 0 and s["render_thermal_states"] == [0] for s in samples)
    summary = {"status": "completed-candidates-not-adopted", "date": "2026-10-18", "device": "iPhone 18 Pro Max / A20 Pro / iOS 27.0.1 (24A446)",
               "scope": "HNCS Standard source-matrix/exposure candidates. Full RAW retain/export/review measured; camera capture, Photos saving and concurrent viewfinder excluded. FFCS was not ported to these backends.",
               "full_export_count": 48, "warmup_count": 12, "measured_count": 36, "repeats_per_condition": 3,
               "all_measured_thermal_nominal": nominal,
               "all_measured_foreground": all(s["before"]["foreground"] and s["after"]["foreground"] for s in samples),
               "all_measured_low_power_off": all(not s["before"]["low_power"] and not s["after"]["low_power"] for s in samples),
               "production_baseline_byte_identical": True, "rows": rows, "codec_probes": codec_probes,
               "execution_evidence": {"ane_small_model_hardware_predictions": ane_predictions,
                   "ane_event_label_counts": dict(Counter(r["label"] for r in ane)),
                   "gpu_study_execution_intervals": gpu_study,
                   "gpu_shader_evidence": json.loads((root / "gpu-shader-evidence.json").read_text()),
                   "gpu_dedicated_neural_counter_obtained": False,
                   "limitations": ["The matched small padded16 source model has 46 named ANE hardware prediction events.",
                       "Full-image variants have compute plans and complete timing; attempts to attach an additional full-image trace failed with process-discovery/device-boot errors.",
                       "TensorOps kernels executed on A20 Pro GPU. Public counter sets exposed GPUTimestamp only; Metal trace gpu-counter-info had zero rows. No dedicated GPU Neural Accelerator occupancy claim."]},
               "probe": probe, "full_raw_reports": reports, "evidence_root": str(root),
               "build_manifest": json.loads((root / "build-manifest.json").read_text()),
               "limits": ["One retained RAW and three warm repetitions, not a general latency or p95 guarantee.",
                          "Profiler runs and diagnostic retries are excluded from latency statistics.",
                          "Prediction/submit time includes framework work and synchronization, not exclusive accelerator execution time.",
                          "Synthetic color tests do not substitute for final HEIF accuracy.",
                          "No power/energy measurement or sustained camera workload test."]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    for row in rows:
        print(row["variant"], row["megapixels"], round(row["seconds"]["median"], 6),
              round(row["duration_change_percent"], 2), row["quality"]["passed_hdr_budget"])
    print("All measured samples nominal:", nominal)


if __name__ == "__main__":
    main()
