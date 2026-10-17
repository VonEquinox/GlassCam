"""Validate and collect the local revision-10 evidence without rerunning tests."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-root", type=Path, required=True)
    args = parser.parse_args()
    evidence = args.evidence_root.resolve()
    validation = ROOT / "validation"
    paths = {
        "settings": "settings/report.json", "color_a": "color-audit-a/report.json", "color_b": "color-audit-b/report.json",
        "sharpness_o3": "sharpness-o3/report.json", "sharpness_o0": "sharpness-o0/report.json",
        "post_stages": "post-stages/report.json", "chain": "chain/report.json",
        "spatial": "integration-final/report.json", "raw_contract": "raw-contract/report.json",
        "exposure": "exposure/report.json", "readable_c": "readable-c/manifest.json",
        "mac_standard": "mac-standard/revision10/report.json", "mac_nature": "mac-nature/revision10/report.json",
    }
    records, reports = {}, {}
    for key, relative in paths.items():
        source = evidence / relative
        data = json.loads(source.read_text())
        source_hashes = data.get("source_sha256", {})
        if isinstance(source_hashes, dict):
            for path, expected in source_hashes.items():
                assert sha(Path(path)) == expected, (key, "stale source", path)
        if key not in ["exposure", "readable_c"]:
            assert data["status"] in ["passed", "complete"], (key, data.get("status"))
        destination = validation / ("phocus-r10-" + key.replace("_", "-") + ".json")
        shutil.copy2(source, destination)
        reports[key] = data
        records[key] = {"path": str(destination.relative_to(ROOT)), "sha256": sha(destination), "original": str(source)}
    for key in ["color_a", "color_b"]:
        assert reports[key]["summary"]["maximum_uint16_error"] == 0
    for key in ["sharpness_o3", "sharpness_o0", "post_stages", "chain", "spatial"]:
        assert reports[key]["summary"]["maximum_uint16_error"] == 0
    assert reports["settings"]["summary"]["parameter_mismatches"] == 0
    assert reports["color_a"]["vectors"]["seed"] != reports["color_b"]["vectors"]["seed"]
    assert reports["sharpness_o3"]["seed"] != reports["sharpness_o0"]["seed"]
    assert reports["sharpness_o3"]["optimization"] == "O3" and reports["sharpness_o0"]["optimization"] == "O0"
    for row in reports["exposure"]["color_filter_exposure"]:
        assert row["comparisons_to_same_native_core"]["unchanged_input"]["maximum_uint16_error"] == 0
    for row in reports["readable_c"]["functions"]:
        assert sha(evidence / "readable-c" / row["file"]) == row["sha256"]
    assert sha(ROOT / "tools/decompile_phocus.py") == reports["readable_c"]["script_sha256"]
    mac = {}
    for key in ["mac_standard", "mac_nature"]:
        report = reports[key]
        manifest = json.loads((evidence / key.replace("_", "-") / "source-sha256.json").read_text())
        for relative, expected in manifest.items():
            assert sha(ROOT / relative) == expected, (key, relative)
        assert len(report["captures"]) == 4 and len(report["path_comparison"]) == 2
        assert all(row["all_encoded_files_identical"] and row["first_pair_decoded_rgba_identical"] for row in report["path_comparison"])
        assert len(report["live_capture_verification"]) == 2
        assert all(row["matches_pipeline_export"] and row["retry_reused_same_file"] for row in report["live_capture_verification"])
        mac[key] = {"preset": report["preset"], "comparison": report["path_comparison"],
                    "service": report["live_capture_verification"], "source_sha256": report["source_sha256"],
                    "rounds_per_output": 1, "working_space": report["working_space"], "exposure_ev": report["exposure_ev"]}
    assert mac["mac_standard"]["source_sha256"] == mac["mac_nature"]["source_sha256"]
    logs = {}
    for key, name in {"portable": "portable-suite.log", "apple": "apple-raw-runtime.log", "sanitizer": "native-sanitizer.log"}.items():
        source = evidence / name
        destination = validation / ("phocus-revision10-" + key + "-20261018.txt")
        shutil.copy2(source, destination)
        logs[key] = {"path": str(destination.relative_to(ROOT)), "sha256": sha(destination)}
    portable = (evidence / "portable-suite.log").read_text()
    assert portable.rstrip().endswith("OK")
    test_count = int(re.search(r"Ran (\d+) tests", portable)[1])
    assert test_count == 198
    apple = (evidence / "apple-raw-runtime.log").read_text()
    assert "PASS: per-RAW BaselineSharpness 1.5, decoder sharpness disabled, policy/retry stable" in apple
    assert "PASS: real RAW 6048×8064 → 10-bit PQ HEIF" in apple
    assert "PASS: 96 native stage/spatial comparisons" in (evidence / "native-sanitizer.log").read_text()
    build_log = evidence / "ios-build.log"
    assert "** BUILD SUCCEEDED **" in build_log.read_text()
    executable = evidence / "ios-build/Build/Products/Release-iphoneos/GlassCam.app/GlassCam"
    assert executable.is_file()
    assert (evidence / "regenerated-spatial.inc").read_bytes() == (ROOT / "core/hncs_spatial_assets.inc").read_bytes()
    code = [p for p in (ROOT / "core").glob("*") if p.suffix in [".cpp", ".h", ".hpp", ".inc"]]
    code += list((ROOT / "ios/GlassCam").glob("*.swift"))
    code += [ROOT / "ios/GlassCam/GlassCam-Bridging-Header.h", ROOT / "ios/GlassCam.xcodeproj/project.pbxproj"]
    report = {
        "schema": 1, "status": "revision10_local_validation_passed", "render_revision": 10,
        "created_at_utc": datetime.now(timezone.utc).isoformat(), "user_local_date": "2026-10-18",
        "branch": subprocess.check_output(["git", "branch", "--show-current"], cwd=ROOT, text=True).strip(),
        "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "method": "analyze-it: radare2/r2ghidra readable C plus original Phocus 4.2.2 native calls, distinct random seeds, O0/O3, frozen original vectors, production Swift/macOS execution",
        "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in sorted(code)},
        "summary": {
            "color_core_and_gradation_channels": sum(reports[k]["summary"]["total_compared_channels"] for k in ["color_a", "color_b"]),
            "color_core_and_gradation_maximum_uint16_error": 0,
            "white_balance_maximum_gain_error": max(reports[k]["summary"]["maximum_WB_gain_error"] for k in ["color_a", "color_b"]),
            "post_color_channels": reports["post_stages"]["summary"]["channels"],
            "sharpness_parameter_cases": sum(reports[k]["summary"]["cases"] for k in ["sharpness_o0", "sharpness_o3"]),
            "sharpness_pattern_cases": sum(reports[k]["summary"]["pattern_cases"] for k in ["sharpness_o0", "sharpness_o3"]),
            "chain_cases": reports["chain"]["summary"]["cases"], "chain_channels": reports["chain"]["summary"]["channels"],
            "portable_tests": test_count, "sanitizer_comparisons": 96, "readable_c_functions": len(reports["readable_c"]["functions"]),
        },
        "evidence": records, "logs": logs, "mac_full_source": mac,
        "apple_checks": [line[6:] for line in apple.splitlines() if line.startswith("PASS: ")],
        "ios_build": {"configuration": "Release", "destination": "generic iOS", "succeeded": True,
                      "code_signing_allowed": False, "executable": str(executable), "executable_sha256": sha(executable),
                      "log": str(build_log), "log_sha256": sha(build_log)},
        "phone": {"tested": False, "installed": False, "reason": "This task's acceptance is limited to non-device work."},
        "limits": ["UInt16 equivalence covers tested native work-code inputs and factory parameters, not every RGB16 triple.",
                   "No physical iPhone/X2D color calibration or full-scene color-error guarantee.",
                   "Native spatial equivalence is full-resolution, non-HDR work scale, without local layers or lens compensation.",
                   "Grain remains the separately validated portable model; source adaptation and HDR restoration are application contracts.",
                   "Reduced RAW diagnostic preview has a different sampling grid; final capture review comes from the actual HEIF.",
                   "Mac RAW checks use one retained source and one round per output; they are not iPhone performance results.",
                   "ASan/UBSan passed; LeakSanitizer was not enabled."]
    }
    target = validation / "phocus-revision10-20261018.json"
    target.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))
    print("Verified source/evidence hashes and wrote", target)


if __name__ == "__main__":
    main()
