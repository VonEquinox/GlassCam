"""Validate transferred device samples and summarize measured wall-clock spans."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess


CONFIGURATIONS = ["hncs-standard", "hncs-nature", "ffcs-provia", "ffcs-acros"]
STAGE_GROUPS = {
    "retain_raw": ["retain_raw"],
    "initialization": ["metadata_bind", "source_graph_setup", "context_scratch_setup"],
    "raw_render": ["raw_render"],
    "rgb_pack_hdr_split": ["strip_buffer_allocation", "rgb_pack_hdr_split"],
    "color_engine": ["color_engine"],
    "spatial_sharpness": ["spatial_sharpness"],
    "post_color_hdr_restore": ["post_color", "rgba_pack", "hdr_restore_validate"],
    "intermediate_and_rgba_io": ["intermediate_io", "rgba_write"],
    "output_graph": ["output_graph"],
    "heif_ci_and_validation": ["heif_encode_ci", "output_validate"],
    "export_unattributed": ["export_unattributed_seconds"],
    "review_decode": ["review_decode"],
}


def statistics_for(values):
    return {"median": statistics.median(values), "minimum": min(values),
            "maximum": max(values), "samples": values}


def grouped(row):
    values = {**row["stages_seconds"], **row["seconds"],
              "export_unattributed_seconds": row["export_unattributed_seconds"]}
    return {group: sum(values.get(key, 0) for key in keys) for group, keys in STAGE_GROUPS.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.input_dir.resolve()
    reports = {name: json.loads((root / name / "report.json").read_text()) for name in CONFIGURATIONS}
    first = reports[CONFIGURATIONS[0]]
    rows = []
    probes = []
    all_samples = []
    for name, report in reports.items():
        assert report["status"] == "complete", name
        assert report["source_sha256"] == first["source_sha256"]
        assert report["machine"] == first["machine"]
        for row in report["samples"]:
            path = root / name / row["file"]
            assert hashlib.sha256(path.read_bytes()).hexdigest() == row["encoded_sha256"], str(path)
            expected_dimensions = [4242, 5656] if row["megapixels"] == 24 else [6048, 8064]
            assert row["output_dimensions"] == expected_dimensions
            assert row["output_depth"] == 10 and row["output_is_hdr"]
            assert row["review_dimensions"] == [1536, 2048]
            if not row["timing_off_control"]:
                assert row["stage_calls"]["raw_render"] == 126
                assert row["stage_calls"]["color_engine"] == 126
                assert row["export_unattributed_seconds"] >= 0
                # Tiny gaps outside the three top-level spans remain in total.
                assert 0 <= row["total_seconds"] - sum(grouped(row).values()) < 0.01
            all_samples.append(row)
        for size in [24, 48]:
            all_size = [r for r in report["samples"] if r["megapixels"] == size]
            warm = [r for r in all_size if not r["warmup"] and not r["timing_off_control"]]
            controls = [r for r in all_size if r["timing_off_control"]]
            assert len(warm) == report["warm_rounds_requested"] == 5
            assert len(controls) == 1
            assert len({r["encoded_sha256"] for r in all_size}) == 1, (name, size, "Output changed")
            stages = {group: statistics_for([grouped(r)[group] for r in warm]) for group in STAGE_GROUPS}
            rows.append({"configuration": name, "megapixels": size, "count": len(warm),
                         "total_seconds": statistics_for([r["total_seconds"] for r in warm]),
                         "grouped_stages_seconds": stages,
                         "raw_stages_seconds": {key: statistics_for([r["stages_seconds"].get(key, 0) for r in warm])
                                                for key in sorted(warm[0]["stages_seconds"])},
                         "first_for_size_seconds": all_size[0]["total_seconds"],
                         "first_for_size_is_first_in_process": all_size[0]["first_export_in_process"],
                         "timing_off_control_seconds": controls[0]["total_seconds"],
                         "all_outputs_including_control_byte_identical": True,
                         "encoded_sha256": warm[0]["encoded_sha256"]})
            path = root / name / warm[0]["file"]
            command = ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                       "stream=codec_name,width,height,pix_fmt,color_space,color_transfer,color_primaries", "-of", "json", str(path)]
            probe = json.loads(subprocess.check_output(command, text=True))
            stream = probe["streams"][0]
            assert stream["codec_name"] == "hevc" and stream["pix_fmt"] == "yuv420p10le"
            assert stream["color_transfer"] == "smpte2084" and stream["color_primaries"] == "bt2020"
            probes.append({"configuration": name, "megapixels": size, "stream": stream,
                           "dimension_note": "ffprobe reports HEIF tile dimensions; full composed dimensions validated by ImageIO.",
                           "command": command})
    states = [s[key] for s in all_samples for key in ["state_before", "state_after"]]
    measured = [s for s in all_samples if not s["warmup"] and not s["timing_off_control"]]
    measured_states = [s[key] for s in measured for key in ["state_before", "state_after"]]
    report = {
        "status": "passed-physical-device-measurement", "date": "2026-10-18",
        "hardware": {key: first[key] for key in ["machine", "os", "gpu", "logical_cpus", "physical_memory_bytes"]},
        "source": {"sha256": first["source_sha256"], "bytes": first["source_bytes"], "dimensions": [6048, 8064]},
        "scope": first["scope"], "stage_scope": first["stage_scope"],
        "sample_count": len(all_samples),
        "measured_samples": sum(not s["warmup"] and not s["timing_off_control"] for s in all_samples),
        "warmup_samples": sum(s["warmup"] for s in all_samples),
        "timing_off_controls": sum(s["timing_off_control"] for s in all_samples),
        "conditions": {"all_before_after_foreground": all(s["application_state"] == 0 for s in states),
                       "all_before_after_thermal_nominal": all(s["thermal"] == 0 for s in states),
                       "measured_before_after_thermal_nominal": all(s["thermal"] == 0 for s in measured_states),
                       "measured_render_thermal_samples_nominal": all(s["thermal_states_during_render"] == [0] for s in measured),
                       "all_render_thermal_samples_nominal": all(s["thermal_states_during_render"] == [0]
                                                                    for s in all_samples if not s["timing_off_control"]),
                       "all_low_power_off": all(not s["low_power"] for s in states),
                       "battery_state_values": sorted({s["battery_state"] for s in states}),
                       "battery_level_minimum": min(s["battery_level"] for s in states),
                       "battery_level_maximum": max(s["battery_level"] for s in states),
                       "minimum_between_samples_seconds": 5},
        "non_nominal_samples": [
            {"configuration": name, "megapixels": s["megapixels"], "round": s["round"],
             "timing_off_control": s["timing_off_control"], "warmup": s["warmup"],
             "before": s["state_before"]["thermal"], "after": s["state_after"]["thermal"],
             "render_states": s["thermal_states_during_render"], "wait_seconds": s["thermal_wait_seconds"]}
            for name, r in reports.items() for s in r["samples"]
            if s["state_before"]["thermal"] != 0 or s["state_after"]["thermal"] != 0
            or any(state != 0 for state in s["thermal_states_during_render"])
        ],
        "maximum_process_lifetime_peak_rss_bytes": max(s["process_lifetime_peak_rss_bytes"] for s in all_samples),
        "memory_scope": first["memory_scope"],
        "rows": rows, "independent_hevc_probes": probes,
        "evidence_root": str(root), "raw_reports": reports,
        "limits": ["Five repetitions of one fixed RAW, no p95 or population guarantee.",
                   "First export in each process is not a cold phone or a cold filesystem cache.",
                   "No simultaneous camera preview, camera acquisition, Photos transaction, sustained shooting or energy measurement.",
                   "File I/O spans are API wall times; buffered writes and later page faults may be charged to other spans.",
                   "Timing-off controls verify output equivalence; one per size does not precisely estimate profiling overhead."]
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    for row in rows:
        timing = row["total_seconds"]
        print(f"{row['configuration']} {row['megapixels']}MP: {timing['median']:.6f} s "
              f"[{timing['minimum']:.6f}, {timing['maximum']:.6f}]")
    print(json.dumps(report["conditions"], indent=2))


if __name__ == "__main__":
    main()
