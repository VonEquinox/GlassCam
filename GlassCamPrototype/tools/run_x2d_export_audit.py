"""Collect original X2D export crops across scenes, presets and working domains.

Read-only vendor calls run in isolated children. Chart coordinates come from
the retained reference geometry; no calibration matrix or color fit is used.
The output manifest is consumed by compare_x2d_crops.py.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
from pathlib import Path
import subprocess
import sys

import numpy as np

from audit_x2d_identity import sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--reference-scenes", type=Path, required=True)
    parser.add_argument("--output-profile", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=2, choices=[1, 2, 3, 4])
    parser.add_argument("--modes", nargs="+", choices=["color", "final", "variants", "hdr"],
                        default=["color", "final", "variants", "hdr"])
    args = parser.parse_args()
    reference, scenes, out = args.reference_root.resolve(), args.reference_scenes.resolve(), args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(reference))
    import hncs_pipeline as h
    chart = json.loads((reference / "work/hncs-pipeline/a7rv_to_x2dii.json").read_text())
    region = chart["chart_config"]["hasselblad"]
    polygons = (h.patch_polygons(region["corners"], region["roi_fraction"]) *
                np.array(chart["target"]["visible_shape"][::-1]) - [128, 96])
    regions = {}
    for index, label in [(0, "dark-skin-print"), (1, "light-skin-print"), (12, "blue"),
                         (14, "red"), (18, "white"), (23, "black")]:
        center = np.rint(polygons[index].mean(axis=0)).astype(int)
        regions[label] = [int(center[0] - 32), int(center[1] - 32), 64, 64]
    analysis = json.loads((scenes / "analysis.json").read_text())
    probe = Path(__file__).with_name("probe_x2d_native_pipeline.py")
    commands = []
    manifest = {"color": [], "exports": [], "hdr": [], "regions": regions,
                "source_sha256": sha(Path(__file__)), "probe_sha256": sha(probe),
                "scope": "Printed target regions, not real-skin or calibrated target truth. Native RAW stages are not independently ported."}

    def collect(name, raw, settings, preset, crop, backend="cpu", stop=None, before=False, hdr=False, ev=0., cct=None, profile=False):
        directory = out / name
        command = [sys.executable, "-B", str(probe), "--reference-root", str(reference), "--raw-source", str(raw),
                   "--output-dir", str(directory), "--preset", preset.title(), "--crop", *map(str, crop),
                   "--stage", "specific", "--backend", backend, "--exposure", str(ev)]
        if settings: command += ["--settings-file", str(settings)]
        if stop: command += ["--stop-filter", stop]
        if before: command += ["--before-filter"]
        if hdr: command += ["--hdr"]
        if cct is not None: command += ["--temperature", str(cct)]
        if profile: command += ["--output-profile", str(args.output_profile.resolve())]
        commands.append((name, directory, command))
        return str(directory)

    raw_paths = {"daylight": scenes / "working/x2dii-daylight_0001.3fr", "lowlight": scenes / "working/x2dii-lowlight_0002.3fr"}
    for row in analysis["exports"]:
        scene, preset = row["scene"], row["preset"]
        raw, settings = raw_paths[scene], scenes / "evidence" / row["settings_file"]
        for label, crop in regions.items():
            base = f"{scene}-{preset}-{label}"
            if "color" in args.modes:
                before = collect(base + "-before", raw, settings, preset, crop, stop="colorCorrect", before=True)
                after = collect(base + "-after", raw, settings, preset, crop, stop="colorCorrect")
                manifest["color"].append({"name": base, "before": before, "after": after})
            if "final" in args.modes:
                for backend in ["cpu", "auto"]:
                    directory = collect(base + "-final-" + backend, raw, settings, preset, crop, backend=backend, profile=True)
                    manifest["exports"].append({"name": base + "-" + backend, "native": directory,
                                                "tiff": row["source_export"], "tiff_sha256": row["sha256"]})
    if "variants" in args.modes:
        iso200 = reference / "work/hncs-finalization/raw/f3da42aac2944357bd87685f9ae2ec1e.3fr"
        for preset in ["standard", "nature"]:
            for label, raw, ev, cct in [("daylight-minus2-warm", raw_paths["daylight"], -2., 2850),
                                         ("daylight-plus2-cool", raw_paths["daylight"], 2., 10000),
                                         ("iso200", iso200, 0., None)]:
                settings = scenes / "evidence" / ("daylight-" + preset + ".phos") if label != "iso200" else None
                base = label + "-" + preset
                before = collect(base + "-before", raw, settings, preset, regions["light-skin-print"],
                                 stop="colorCorrect", before=True, ev=ev, cct=cct)
                after = collect(base + "-after", raw, settings, preset, regions["light-skin-print"],
                                stop="colorCorrect", ev=ev, cct=cct)
                manifest["color"].append({"name": base, "before": before, "after": after})
    if "hdr" in args.modes:
        for scene, preset, region_name, ev in [("daylight", "standard", "white", 2.),
                                               ("daylight", "nature", "red", 0.),
                                               ("lowlight", "standard", "black", 0.)]:
            name = f"hdr-{scene}-{preset}-{region_name}"
            case = {"name": name, "stages": {}}
            settings = scenes / "evidence" / f"{scene}-{preset}.phos"
            for label, stop, before in [("input", "colorCorrect", True), ("color", "colorCorrect", False),
                                        ("highlight", "HighlightStrength", False), ("gamma", "gamma", False),
                                        ("gradation", "gradation", False), ("sharpness", "sharpness", False)]:
                case["stages"][label] = collect(name + "-" + label, raw_paths[scene], settings, preset,
                                                regions[region_name], stop=stop, before=before, hdr=True, ev=ev)
            manifest["hdr"].append(case)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    results = []

    def run(task):
        name, directory, command = task
        if directory.exists(): raise FileExistsError("Refusing to replace existing evidence: " + str(directory))
        result = subprocess.run(command, text=True, capture_output=True, timeout=280)
        directory.mkdir(exist_ok=True)
        (directory / "driver.stdout.txt").write_text(result.stdout)
        (directory / "driver.stderr.txt").write_text(result.stderr)
        return {"name": name, "returncode": result.returncode, "command": command}

    # Validate the shared ABI/environment before scheduling the full matrix.
    if commands:
        first = run(commands[0]); results.append(first)
        (out / "runs.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"1/{len(commands)} {first['name']}: {first['returncode']}", flush=True)
        if first["returncode"] != 0: raise SystemExit(1)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run, task) for task in commands[1:]]
        for future in as_completed(futures):
            try: result = future.result()
            except Exception as error: result = {"error": str(error), "returncode": -1}
            results.append(result)
            (out / "runs.json").write_text(json.dumps(results, indent=2) + "\n")
            print(f"{len(results)}/{len(commands)} {result.get('name', result.get('error'))}: {result['returncode']}", flush=True)
    if any(r["returncode"] != 0 for r in results): raise SystemExit(1)


if __name__ == "__main__":
    main()
