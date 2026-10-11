#!/usr/bin/env python3
"""Extract portable data for hncs_pipeline.py from the locally analysed Phocus."""
import hashlib
import importlib.util
import json
import plistlib
import struct
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / "work/hncs-pipeline/assets"
FRAMEWORKS = Path("/Volumes/Phocus/Phocus.app/Contents/Frameworks")


def arm64_data(binary, address, count):
    """Map a VM address to its file offset in the arm64 Mach-O slice."""
    if binary[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("Expected the verified universal Mach-O")
    nfat = struct.unpack_from(">I", binary, 4)[0]
    slices = [struct.unpack_from(">5I", binary, 8+20*i) for i in range(nfat)]
    base = next(offset for cpu, _, offset, _, _ in slices if cpu == 0x0100000c)
    ncmds = struct.unpack_from("<I", binary, base+16)[0]
    cursor = base+32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", binary, cursor)
        if cmd == 0x19:
            vmaddr, _, fileoff, filesize = struct.unpack_from("<4Q", binary, cursor+24)
            if vmaddr <= address and address+count <= vmaddr+filesize:
                offset = base+fileoff+address-vmaddr
                return binary[offset:offset+count]
        cursor += size
    raise ValueError(f"Address is not file-backed: {address:#x}")


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)
    raw_path = FRAMEWORKS / "HBRawCorrections.framework/Versions/A/HBRawCorrections"
    util_path = FRAMEWORKS / "HBUtil.framework/Versions/A/HBUtil"
    image_path = FRAMEWORKS / "HBImageProcessing.framework/Versions/A/HBImageProcessing"
    raw = raw_path.read_bytes()
    # Offsets are specific to the verified 4.2.2 universal binaries.
    expected = {raw_path: "887d4c3823362c5e89ae3fb14939b85eb5fe85db60913c9d99836ad007c636f0",
                util_path: "0786d740ad4d6455ee5c5a0d53339f960deabc32b931ecff3186719d627dcf1c",
                image_path: "125dd5b0bf0cc1ad00d1cf959eeeea82aa24acee117c2b2bcb55fa44f430d010"}
    for path, digest in expected.items():
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError(f"Unrecognised Phocus binary: {path}")
    # CColorTempConversion::GainToTempAndTint uses this native Robertson table.
    image_binary = image_path.read_bytes()
    robertson = np.frombuffer(arm64_data(image_binary, 0x189e10, 31*4*8), dtype="<f8").reshape(31,4).copy()
    if robertson[0,0] != 0 or robertson[-1,0] != 600 or robertson[0,1] != .18006:
        raise ValueError("Unrecognised colour temperature table")
    def matrix(address):
        return np.array(struct.unpack_from("<9d", raw, 688128 + address)).reshape(3, 3)
    colormap = ROOT / "work/hncs-phocus-correction/evidence/colormaps_plain/bohnjuhtuvuvtxyydb56.bin"
    data = plistlib.loads(colormap.read_bytes())
    spec = importlib.util.spec_from_file_location("v1curve", ROOT / "work/hncs-phocus-correction/evidence/v1curve.py")
    curves = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(curves)
    profile_path = FRAMEWORKS / "HBImageProcessing.framework/Versions/A/Resources/Profiles/HasselbladLStarRGB.icc"
    (ASSETS / "HasselbladLStarRGB.icc").write_bytes(profile_path.read_bytes())
    (ASSETS / "HasselbladRGB.icc").write_bytes(profile_path.with_name("Hasselblad RGB.icc").read_bytes())
    # CalculateLUT v3 interpolates TS/Flash/HT in CCT, clamped to 2000..10000 K.
    arrays = {
        "matrix_temperatures": np.array([data[k] for k in ("tlt", "tt", "tf", "th")]),
        "camera_to_xyz": np.array([data[k] for k in ("mlt", "mt", "mf", "mh")]).reshape(4, 3, 3) * .5 + 1,
        "wb_temperatures": np.array([data[k] for k in ("tt", "tf", "th")]),
        "factory_wb": np.array([data[k] for k in ("vt", "vf", "vh")]) * .5 + 1,
        "grid": np.array([data[k] for k in ("CbS", "CbE", "CrS", "CrE", "DivFactor")]),
        "working_rgb_to_xyz": matrix(0x3fc30),
        "xyz_to_legacy_rgb": matrix(0x3fd50),
        # This is also kMHasselbladRGB, initialised at runtime at 0x69520.
        "legacy_rgb_to_xyz": matrix(0x5fe70),
        "rgb_to_ycbcr": matrix(0x3dbe0),
        # InitCRawColorCorrection clears these thresholds for IRFilterType >= 6.
        "gray_thresholds": np.array([0., 0.]),
        "lut_expansion": np.array([5, 7, 55, 12]),
        "shadow_desaturation": np.array([15500., -.123]),
        "robertson": robertson,
        "v1_lstar": np.asarray(curves.gradation_table(True, True), dtype=np.uint16),
        "pure_lstar": np.asarray(curves.gradation_table(False, True), dtype=np.uint16),
        "v1_gamma": np.asarray(curves.gradation_table(True, False), dtype=np.uint16),
        "pure_gamma": np.asarray(curves.gradation_table(False, False), dtype=np.uint16),
        "legacy_icc_gamma": np.array([563/256]),
    }
    height, width = data["CrE"] - data["CrS"] + 1, data["CbE"] - data["CbS"] + 1
    for intent in ("Std", "Repro"):
        arrays["lut_" + intent.lower()] = np.array([data["LUTTable" + light + intent]
                for light in ("TS", "Flash", "HT")]).reshape(3, height, width, 2)
    np.savez_compressed(ASSETS / "x2dii_phocus_422.npz", **arrays)
    metadata = {
        "schema": 2, "colour_path_revision": 2, "phocus_version": "4.2.2", "sensor_key": "0x616",
        "colormap": colormap.name, "colormap_sha256": hashlib.sha256(colormap.read_bytes()).hexdigest(),
        "colormap_timestamp": data["TimeStamp"],
        "binary_sha256": {p.name: digest for p, digest in expected.items()},
        "matrix_convention": "row-major; column vectors; NumPy row samples multiply M.T",
        "lut_semantics": "absolute mapped chroma: input*DivFactor-start, interpolate, output/DivFactor",
        "pixel_kernel": "CVectorMethods::ColorNormalCorrectPixels @0x32a5c",
        "kernel_options": "X2D II gray thresholds 0/0; Standard shadow desaturation enabled; Reproduction bypasses it with non-HDR 1.7 gain; legacy workspace 0 uses unexpanded LUT/gamma, LStar workspace 1 uses expanded LUT (5,7)/(55,12)/LStar",
        "cct_method": "Native CColorTempConversion: flash camera->XYZ times factory WB, then Robertson table; no UI quantisation",
        "runtime_matrix": "kMHasselbladRGB @0x69520 equals static @0x5fe70, verified by native load",
        "scope": "Normal non-HDR factory Standard (filmCurve 2/4/6) and Reproduction (effective filmCurve 7), colorModel 0/1, unit effective gain; legacy/LStar spaces 0/1. FilmCurve type 0 original gamma and type 7 pure OETF are resolved in phocus_presets.py; extracted factory setting payloads are in phocus_presets.json. Optional closed-loop colour configuration and Phocus RAW/spatial processing are not implemented.",
    }
    metadata["files"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in ASSETS.iterdir()
                          if p.suffix in (".npz", ".icc")}
    (ASSETS / "provenance.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
