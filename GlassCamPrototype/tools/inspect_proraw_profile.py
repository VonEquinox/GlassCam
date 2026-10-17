"""Extract a DNG's embedded color profile without decoding or changing pixels.

Uses TIFF/IFD metadata and DNG 1.7.1 ProfileGainTableMap layout (pp. 71–73).
Photo-derived curves and maps are written only to the explicit output directory.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics
import struct


TAGS = {256: "ImageWidth", 257: "ImageLength", 262: "PhotometricInterpretation",
        271: "Make", 272: "Model", 274: "Orientation", 305: "Software",
        33434: "ExposureTime", 33437: "FNumber", 34855: "ISO", 42036: "LensModel",
        50706: "DNGVersion", 50707: "DNGBackwardVersion", 50708: "UniqueCameraModel",
        50714: "BlackLevel", 50717: "WhiteLevel", 50721: "ColorMatrix1", 50722: "ColorMatrix2",
        50723: "CameraCalibration1", 50724: "CameraCalibration2", 50727: "AnalogBalance",
        50728: "AsShotNeutral", 50729: "AsShotWhiteXY", 50730: "BaselineExposure",
        50778: "CalibrationIlluminant1", 50779: "CalibrationIlluminant2",
        50936: "ProfileName", 50940: "ProfileToneCurve", 50964: "ForwardMatrix1",
        50965: "ForwardMatrix2", 52525: "ProfileGainTableMap", 52544: "ProfileGainTableMap2"}
SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4}


def entries(path):
    size = path.stat().st_size
    with path.open("rb") as stream:
        def read(offset, length):
            if offset < 0 or length < 0 or offset + length > size:
                raise ValueError("TIFF data outside file")
            stream.seek(offset)
            data = stream.read(length)
            if len(data) != length: raise ValueError("Truncated TIFF")
            return data
        header = read(0, 8)
        if header[:2] not in (b"II", b"MM"): raise ValueError("Not TIFF")
        endian = "<" if header[:2] == b"II" else ">"
        if struct.unpack(endian + "H", header[2:4])[0] != 42:
            raise ValueError("This diagnostic supports classic TIFF/DNG, not BigTIFF")
        queue = [("IFD0", struct.unpack(endian + "I", header[4:])[0])]
        visited = set()
        while queue:
            label, offset = queue.pop(0)
            if not offset or offset in visited: continue
            visited.add(offset)
            if len(visited) > 128: raise ValueError("Excessive IFD count")
            count = struct.unpack(endian + "H", read(offset, 2))[0]
            table = read(offset + 2, count * 12 + 4)
            queue.append((label + ".next", struct.unpack(endian + "I", table[-4:])[0]))
            for index in range(count):
                row = table[index * 12:index * 12 + 12]
                tag, kind, length = struct.unpack(endian + "HHI", row[:8])
                if kind not in SIZES or (tag not in TAGS and tag not in (330, 34665, 50933)): continue
                byte_count = SIZES[kind] * length
                raw = row[8:8 + byte_count] if byte_count <= 4 else read(struct.unpack(endian + "I", row[8:])[0], byte_count)
                fractions = None
                if kind == 2: value = raw.rstrip(b"\0").decode("utf-8", errors="replace")
                elif kind == 7: value = raw
                elif kind in (5, 10):
                    code = "II" if kind == 5 else "ii"
                    fractions = [struct.unpack_from(endian + code, raw, i * 8) for i in range(length)]
                    value = [a / b if b else None for a, b in fractions]
                else:
                    code = {1: "B", 3: "H", 4: "I", 6: "b", 8: "h", 9: "i", 11: "f", 12: "d", 13: "I"}[kind]
                    value = list(struct.unpack(endian + str(length) + code, raw))
                if tag in (330, 34665, 50933):
                    queue.extend((label + f".{tag}.{i}", v) for i, v in enumerate(value))
                else:
                    yield label, TAGS[tag], kind, value, raw, fractions


def gain_table(raw, directory, stem):
    candidates = []
    for endian in ("<", ">"):
        if len(raw) < 64: raise ValueError("Truncated ProfileGainTableMap")
        vertical, horizontal = struct.unpack_from(endian + "II", raw)
        points = struct.unpack_from(endian + "I", raw, 40)[0]
        if min(vertical, horizontal, points) > 0 and len(raw) == 64 + 4 * vertical * horizontal * points:
            candidates.append((endian, vertical, horizontal, points))
    if len(candidates) != 1: raise ValueError("Unrecognized or ambiguous gain-table layout")
    endian, vertical, horizontal, points = candidates[0]
    spacing_v, spacing_h, origin_v, origin_h = struct.unpack_from(endian + "dddd", raw, 8)
    weights = list(struct.unpack_from(endian + "fffff", raw, 44))
    gains = struct.unpack_from(endian + str(vertical * horizontal * points) + "f", raw, 64)
    if not all(math.isfinite(x) and x >= 0 for x in gains): raise ValueError("Invalid profile gains")
    (directory / (stem + ".f32")).write_bytes(struct.pack("<" + str(len(gains)) + "f", *gains))
    samples = []
    for value in (0, .01, .05, .18, .5, 1):
        # DNG 1.7.1 p.73 specifies input * MapPointsN, followed by edge replication.
        position = min(points - 1, value * points)
        lo, hi = int(position), min(points - 1, int(position) + 1)
        fraction = position - lo
        table = [(1 - fraction) * gains[i * points + lo] + fraction * gains[i * points + hi]
                 for i in range(vertical * horizontal)]
        samples.append({"table_input": value, "minimum": min(table), "maximum": max(table),
                        "mean": statistics.mean(table)})
    return {"byte_order": "little" if endian == "<" else "big", "shape_v_h_n": [vertical, horizontal, points],
            "spacing_v_h": [spacing_v, spacing_h], "origin_v_h": [origin_v, origin_h], "input_weights": weights,
            "minimum": min(gains), "maximum": max(gains), "mean": statistics.mean(gains),
            "spatial_gain_samples": samples, "float32_little_endian_file": stem + ".f32",
            "domain": "DNG RIMM RGB after BaselineExposure and image warps; not a LUT for decoded sRGB",
            "reference": "Adobe DNG 1.7.1, ProfileGainTableMap, pp.71–73"}


def inspect(source, directory):
    directory.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as stream: digest = hashlib.file_digest(stream, "sha256").hexdigest()
    report = {"source_sha256": digest,
              "source_bytes": source.stat().st_size, "tags": {}, "matrices": {}, "tone_curves": {}, "gain_tables": {}}
    for ifd, name, kind, value, raw, fractions in entries(source):
        key = ifd + "." + name
        if name == "ProfileGainTableMap":
            stem = key.replace(".", "-")
            report["gain_tables"][key] = gain_table(raw, directory, stem)
            report["tags"][key] = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
            (directory / (stem + ".bin")).write_bytes(raw)
        elif name == "ProfileToneCurve":
            if len(value) < 4 or len(value) % 2 or not all(math.isfinite(x) for x in value):
                raise ValueError("Invalid profile tone curve")
            pairs = [value[i:i + 2] for i in range(0, len(value), 2)]
            if any(b[0] <= a[0] for a, b in zip(pairs, pairs[1:])): raise ValueError("Tone input is not strictly increasing")
            report["tone_curves"][key] = {"points": pairs, "sha256": hashlib.sha256(raw).hexdigest(),
                "output_monotonic": all(b[1] >= a[1] for a, b in zip(pairs, pairs[1:]))}
            report["tags"][key] = {"points": len(pairs)}
        elif isinstance(value, bytes):
            report["tags"][key] = {"bytes": len(value), "sha256": hashlib.sha256(value).hexdigest()}
        else:
            report["tags"][key] = value
            if "Matrix" in name or "CameraCalibration" in name:
                report["matrices"][key] = {"values": value, "exact_rationals": fractions}
    report["scope"] = "Embedded metadata from one computational ProRAW. Not an independent colorimetric measurement or an iPhone-to-Hasselblad mapping."
    (directory / "embedded-profile.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    report = inspect(args.source.resolve(strict=True), args.output_dir.resolve())
    print(json.dumps({"matrices": list(report["matrices"]), "tone_curves": list(report["tone_curves"]),
                      "gain_tables": report["gain_tables"]}, indent=2))


if __name__ == "__main__": main()
