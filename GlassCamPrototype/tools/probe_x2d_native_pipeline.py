"""Obtain original Phocus X2D II intermediate crops with an explicit backend.

Native C++ ABI experiments execute in a child process; failures are recorded,
not presented as completed RAW parity. Original files are read-only.
"""
import argparse
import ctypes as c
import json
import math
from pathlib import Path
import plistlib
import subprocess
import sys
import time

import numpy as np
from audit_x2d_identity import RawProbe, sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--raw-source", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--preset", choices=["Standard", "Nature"], default="Standard")
    parser.add_argument("--crop", type=int, nargs=4, default=[2000, 2000, 64, 64])
    parser.add_argument("--stage", choices=["general", "specific"], default="general")
    parser.add_argument("--stop-filter", help="Capture this exact original filter ID")
    parser.add_argument("--before-filter", action="store_true")
    parser.add_argument("--backend", choices=["cpu", "auto"], default="cpu")
    parser.add_argument("--output-profile", type=Path, help="Original ICC output profile for AddOutputFiltersExport")
    parser.add_argument("--settings-file", type=Path, help="A retained original .phos sidecar or ImageCorrection plist")
    parser.add_argument("--parameter-builder", choices=["export", "viewer"], default="export")
    parser.add_argument("--description-source", choices=["cached", "constructed"], default="cached")
    parser.add_argument("--hdr", action="store_true")
    parser.add_argument("--exposure", type=float, default=0.)
    parser.add_argument("--temperature", type=int)
    parser.add_argument("--child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not math.isfinite(args.exposure) or not -20 <= args.exposure <= 20:
        parser.error("Exposure must be finite and within [-20, 20] EV")
    if any(v <= 0 or v > 4096 for v in args.crop[2:]):
        parser.error("Crop dimensions must be within [1, 4096]")
    out = args.output_dir.resolve(); out.mkdir(parents=True, exist_ok=True)
    bridge = out / "native-x2d-bridge.dylib"
    source = Path(__file__).with_name("native_x2d_pipeline_bridge.cpp")
    if not args.child:
        original_hash = sha(args.raw_source)
        command = ["xcrun", "clang++", "-std=c++17", "-O2", "-g", "-dynamiclib", str(source), "-o", str(bridge)]
        subprocess.run(command, check=True)
        started = time.perf_counter()
        child_command = [sys.executable, "-B", str(Path(__file__).resolve()), *sys.argv[1:], "--child"]
        try:
            result = subprocess.run(child_command, text=True, capture_output=True, timeout=240)
        except subprocess.TimeoutExpired as error:
            decode = lambda value: value.decode(errors="replace") if isinstance(value, bytes) else value or ""
            result = subprocess.CompletedProcess(child_command, 124, decode(error.stdout), decode(error.stderr))
        if sha(args.raw_source) != original_hash:
            raise RuntimeError("Source RAW changed during the original read-only pipeline call")
        (out / "native.stdout.txt").write_text(result.stdout)
        (out / "native.stderr.txt").write_text(result.stderr)
        report = {"status": "obtained-native-crop" if result.returncode == 0 else "native-crop-unavailable",
                  "returncode": result.returncode, "seconds": time.perf_counter() - started,
                  "compile": command, "probe_sha256": sha(Path(__file__)), "bridge_sha256": sha(source),
                  "raw": str(args.raw_source.resolve()), "raw_sha256": original_hash,
                  "preset": args.preset, "stage": args.stage, "crop": args.crop,
                  "stop_filter": args.stop_filter, "before_filter": args.before_filter,
                  "requested_backend": args.backend,
                  "parameter_builder": args.parameter_builder,
                  "description_source": args.description_source,
                  "output_profile": str(args.output_profile.resolve()) if args.output_profile else None,
                  "output_profile_sha256": sha(args.output_profile) if args.output_profile else None,
                  "settings_file": str(args.settings_file.resolve()) if args.settings_file else None,
                  "settings_sha256": sha(args.settings_file) if args.settings_file else None,
                  "hdr": args.hdr, "exposure_ev": args.exposure, "temperature": args.temperature,
                  "limits": ["This records an original intermediate, not GlassCam equivalence.",
                             "An unavailable stage remains an explicit gap."]}
        (out / "invocation.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2)); print(result.stdout[-2000:]); print(result.stderr[-4000:])
        raise SystemExit(0 if result.returncode == 0 else 1)
    probe = RawProbe(args.reference_root.resolve(), args.raw_source.resolve())
    adapter = c.CDLL(str(bridge))
    configure = adapter.configure_x2d_backend
    configure.argtypes = [c.c_void_p, c.c_void_p, c.c_bool]; configure.restype = c.c_int
    gpu_enabled = configure(probe.n.image._handle, probe.n.util._handle, args.backend == "cpu")
    if gpu_enabled < 0 or (args.backend == "cpu" and gpu_enabled != 0):
        raise RuntimeError("Unable to select/verify original CPU processing")
    # Original provider requires a live cache service; construction only stores
    # limits and empty containers. These are diagnostic process cache limits.
    probe.n.fn(probe.storage, "_ZN19CRawCacheController4InitEmmm", [c.c_ulong] * 3)(512 * 1024 * 1024, 64 * 1024 * 1024, 0)
    constructed_metadata = probe.metadata()
    constructed_description = probe.description
    if args.description_source == "cached":
        cached = adapter.cached_x2d_description
        cached.argtypes = [c.c_void_p, c.c_void_p]; cached.restype = c.c_void_p
        address = cached(probe.storage._handle, probe.raw)
        if not address: raise RuntimeError("Original cached RAW description is unavailable")
        probe.description = (c.c_char * 0x400).from_address(address)
    from preset_curves_probe import NativeCurves
    from native_config_probe import FRAMEWORK_HASHES, verified_framework
    factory = Path("/Volumes/Phocus/Phocus.app/Contents/Resources/Settings/Standard") / (args.preset + ".xml")
    payload = plistlib.loads(factory.read_bytes())["ImageSetting"]["ImageCorrection"]
    selected = {}
    if args.settings_file:
        saved = plistlib.loads(args.settings_file.read_bytes())
        if "ImageSettings" in saved:
            selected = saved["ImageSettings"][saved["CurrentIx"]]
            payload = selected["ImageCorrection"]
        elif "ImageSetting" in saved:
            payload = saved["ImageSetting"]["ImageCorrection"]
        else:
            payload = saved
    payload["EV"] = 2. ** args.exposure
    payload["HDR"] = args.hdr
    if args.temperature is not None:
        payload["ColorTemperature"] = args.temperature
    settings = NativeCurves(probe.n, probe.storage, payload)
    image_description = probe.decode_object("CImageDescription", selected.get("ImageDescription"))
    output_preset = probe.decode_object("COutputPreset", selected.get("OutputPreset"))
    params = c.create_string_buffer(0x1000)
    probe.n.fn(probe.n.util, "_ZN9CFileSpecC1Ev", [c.c_void_p])(params)
    fn = adapter.render_x2d_crop
    fn.argtypes = [c.c_void_p] * 10 + [c.c_int, c.c_bool, c.c_char_p, c.c_bool, c.c_char_p] + [c.c_int] * 6 + [c.c_void_p] * 3
    fn.restype = c.c_int
    left, top, width, height = args.crop
    metadata = (c.c_uint * 4)()
    color_contract = (c.c_double * 43)()
    values = probe.metadata()
    source_width = values["description"]["GetRawWidth"]
    source_height = values["description"]["GetRawHeight"]
    output = np.zeros(width * height * 4, dtype=np.uint16)
    result = fn(probe.n.image._handle, probe.n.util._handle, probe.storage._handle, probe.raw, probe.description,
                settings.correction, settings.curves, params, image_description, output_preset,
                int(args.stage == "specific"), args.parameter_builder == "export",
                args.stop_filter.encode() if args.stop_filter else None, args.before_filter,
                str(args.output_profile.resolve()).encode() if args.output_profile else None,
                left, top, width, height, source_width, source_height, output.ctypes.data, metadata, color_contract)
    if result:
        raise RuntimeError(f"Original pipeline returned {result}, image metadata {list(metadata)}")
    pixels = output[:width * height * metadata[2]].reshape(height, width, metadata[2])
    np.save(out / "native-crop.npy", pixels)
    scalars = {"wb": [c.c_double.from_buffer(params, offset).value for offset in [0x58, 0x60, 0x68]],
               "ev_multiplier": c.c_double.from_buffer(params, 0x70).value,
               "color_model": c.c_int.from_buffer(params, 0xb8).value,
               "film_curve": c.c_int.from_buffer(params, 0xbc).value,
               "working_space": c.c_int.from_buffer(params, 0xc0).value,
               "hdr": c.c_bool.from_buffer(params, 0x1b8).value}
    if scalars["hdr"] != args.hdr or scalars["ev_multiplier"] != 2. ** args.exposure:
        raise AssertionError("Native parameters did not select the requested exposure/HDR branch")
    (out / "native-settings.plist").write_bytes(plistlib.dumps(payload))
    (out / "native-input.json").write_text(json.dumps({"native": values, "parameters": scalars,
        "parameter_builder": args.parameter_builder,
        "description_source": args.description_source,
        "constructed_description_fields": constructed_metadata["description"],
        "description_fields_equal": constructed_metadata["description"] == values["description"],
        "scene_calibration_intensity": c.c_int.from_buffer(params, 0x148).value,
        "framework_sha256": {key: sha(verified_framework(key)) for key in FRAMEWORK_HASHES},
        "backend": {"requested": args.backend, "native_gpu_enabled": bool(gpu_enabled),
                    "control": "process-local original disableGPU debug key; no preferences saved"},
        "color_contract": {"cct": color_contract[0], "icm_method": color_contract[1],
            "filter_exposure": color_contract[2], "outer_1f8": color_contract[3], "outer_248": color_contract[4],
            "shadow": list(color_contract)[5:9], "incoming": list(color_contract)[9:18],
            "outgoing": list(color_contract)[18:27], "linearization_lengths": list(color_contract)[27:33]},
        "hdr_post_contract": {"highlight_parameters": list(color_contract)[33:35], "gamma_lstar": bool(color_contract[35])},
        "sharpness_contract": dict(zip(["effective_amount", "radius", "noise", "dark", "image_scale", "hdr_scale", "extra_lines"], list(color_contract)[36:43])),
        "buffer_metadata": list(metadata), "pixel_sha256": sha(out / "native-crop.npy"),
        "pixel_range": [int(pixels.min()), int(pixels.max())], "factory_xml_sha256": sha(factory)}, indent=2) + "\n")
    print(json.dumps({"metadata": list(metadata), "parameters": scalars, "range": [int(pixels.min()), int(pixels.max())]}))


if __name__ == "__main__":
    main()
