"""Audit retained native Bayer buffers against an independent DNG SDK decoder.

Reads one immutable probe bundle. The report contains measurements and hashes,
never photo pixels, and does not create or qualify a device noise profile.
"""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import struct
import subprocess
import tempfile
import numpy as np


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def verified_blob(root, record):
    path = (root / record["path"]).resolve()
    if not path.is_relative_to(root) or not path.is_file():
        raise ValueError("Blob escapes its bundle or is not a file")
    if path.stat().st_size != record["bytes"] or sha(path) != record["sha256"]:
        raise ValueError("Original blob length or SHA256 changed")
    return path


def gain_maps(metadata):
    result = []
    for op in metadata["opcodes"]:
        item = dict(list=op["list"], id=op["id"], version=op["version"], flags=op["flags"])
        if op["id"] == 9:
            data = base64.b64decode(op["parameters"], validate=True)
            area = struct.unpack_from(">10I", data)
            geometry = struct.unpack_from(">4dI", data, 40)
            rows, columns, planes = area[8], area[9], geometry[4]
            if len(data) != 76 + rows * columns * planes * 4:
                raise ValueError("Malformed DNG GainMap")
            values = np.frombuffer(data, dtype=">f4", offset=76).reshape(rows, columns, planes)
            item.update(area=list(area[:4]), first_plane=area[4], affected_planes=area[5],
                        pitch=list(area[6:8]), grid=[rows, columns, planes],
                        spacing=list(geometry[:2]), origin=list(geometry[2:4]),
                        gain_minimum=float(values.min()), gain_maximum=float(values.max()),
                        planes_identical=bool(np.all(values == values[:, :, :1])))
        result.append(item)
    return result


def audit(bundle, oracle):
    root = bundle.resolve()
    manifest_path = root / "burst.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("synthetic") or len(manifest["frames"]) != 5:
        raise ValueError("Expected one five-frame real-device probe")
    frames = sorted(manifest["frames"], key=lambda f: f["burstIndex"])
    if [f["burstIndex"] for f in frames] != list(range(5)):
        raise ValueError("Duplicate or missing burst index")
    candidates = {1, 2, 4, 8, 16, 32, 64, 128, 256}
    measurements = []
    with tempfile.TemporaryDirectory(prefix="f5-stage1-audit-") as work:
        for frame in frames:
            raw_path = verified_blob(root, frame["mosaic"])
            dng_path = verified_blob(root, frame["dng"])
            raster = frame["raster"]
            height, width, stride = raster["height"], raster["width"], raster["rowBytes"] // 2
            dtype = "<u2" if raster["byteOrder"] == "little" else ">u2"
            native = np.fromfile(raw_path, dtype=dtype).reshape(height, stride)[:, :width]
            decoded_path = Path(work) / "stage1.raw"
            decoded = subprocess.run([str(oracle.resolve()), "--raw-uint16", str(dng_path), str(decoded_path)],
                                     check=True, capture_output=True, text=True)
            descriptor = json.loads(decoded.stdout)
            if descriptor["width"] != width or descriptor["height"] != height:
                raise ValueError("DNG and retained native buffer have different rasters")
            dng = np.fromfile(decoded_path, dtype="=u2").reshape(height, width)
            area = raster["activeArea"]
            top, left, bottom, right = (area[k] for k in ("top", "left", "bottom", "right"))
            if not (0 <= top < bottom <= height and 0 <= left < right <= width):
                raise ValueError("Invalid ActiveArea")
            a, b = native[top:bottom, left:right], dng[top:bottom, left:right]
            matches = {divisor for divisor in candidates if np.array_equal(a // divisor, b)}
            candidates &= matches
            item = dict(index=frame["burstIndex"], role=frame["role"],
                        dng_sha256=frame["dng"]["sha256"], native_sha256=frame["mosaic"]["sha256"],
                        pixels_compared=int(a.size), exact_divisors=sorted(matches),
                        native_minimum=int(a.min()), native_maximum=int(a.max()),
                        native_percentiles=np.percentile(a, [1, 50, 99]).tolist(),
                        dng_minimum=int(b.min()), dng_maximum=int(b.max()),
                        dng_black=frame["metadata"]["blackLevel"], dng_white=frame["metadata"]["whiteLevel"],
                        noise_profile=frame["metadata"]["noiseProfile"],
                        requested_exposure=frame["requestedExposure"], actual_exposure=frame["actualExposure"],
                        requested_iso=frame.get("requestedISO"), actual_iso=frame["actualISO"],
                        opcodes=gain_maps(frame["metadata"]))
            if len(candidates) == 1:
                divisor = next(iter(candidates))
                residual = a.astype(np.int32) - divisor * b.astype(np.int32)
                item["native_low_bit_residual_histogram"] = np.bincount(residual.ravel(), minlength=divisor).tolist()
            padding = np.concatenate([native[:top].ravel(), native[bottom:].ravel(),
                                      native[top:bottom, :left].ravel(), native[top:bottom, right:].ravel()])
            item["outside_active_pixels"] = int(padding.size)
            item["outside_active_all_zero"] = bool(padding.size and np.all(padding == 0))
            measurements.append(item)
            print(f"frame {frame['burstIndex']}: {a.size} active pixels, exact divisors {sorted(matches)}", flush=True)
    if len(candidates) != 1:
        raise ValueError(f"Native-to-DNG mapping is ambiguous: {sorted(candidates)}")
    iso_values = [f["actualISO"] for f in frames]
    mains = [f["actualExposure"] for f in frames if f["role"] == "L"]
    short = next(f["actualExposure"] for f in frames if f["role"] == "S")
    flags = set(manifest["flags"])
    if any(abs(iso / iso_values[0] - 1) > .001 for iso in iso_values):
        flags.update(["ISO_CHANGED", "NONUNIFORM_MAINS"])
    if any(abs(f["actualExposure"] / f["requestedExposure"] - 1) > .01 for f in frames):
        flags.add("EXPOSURE_ADJUSTED")
    if short > np.median(mains) / 8 * 1.01:
        flags.update(["SHORT_EXPOSURE_LIMITED", "HIGHLIGHT_NOT_GUARANTEED"])
    return dict(revision="f5-device-input-audit-v1", qualification="UNQUALIFIED", synthetic=False,
                hardware_model=manifest["hardwareModel"], os_build=manifest["osBuild"],
                manifest_sha256=sha(manifest_path), oracle="Adobe DNG SDK 1.7.1 Stage1, original integers",
                oracle_binary_sha256=sha(oracle), frame_count=len(frames), all_blob_hashes_verified=True,
                raw_fourcc=f"0x{frames[0]['rawFourCC']:08x}", raster=frames[0]["raster"],
                native_to_dng_divisor=next(iter(candidates)), dng_stage1_rounding="floor",
                active_pixels_compared=sum(f["pixels_compared"] for f in measurements),
                capture_span_ms=1000 * (max(f["timestamp"] for f in frames) - min(f["timestamp"] for f in frames)),
                main_to_short_ratio=float(np.median(mains) / short), persisted_flags=manifest["flags"],
                recomputed_flags=sorted(flags), frames=measurements,
                constraints=["No noise/optical calibration or product qualification is inferred from this scene.",
                             "Zero padding outside ActiveArea is not dark calibration data.",
                             "Use fractional code conversion; retain native low bits and quantization intervals."])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--sdk-oracle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = audit(args.bundle, args.sdk_oracle)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(args.output)


if __name__ == "__main__":
    main()
