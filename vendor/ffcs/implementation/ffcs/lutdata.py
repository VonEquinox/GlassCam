"""Packed reference LUT loading.

The XH2S tables shipped with the supplied SilkyPix reference installer are
stored in a compact FFCS container generated from the vendor's 80³ ISLRGB
tables.  Keeping them packed avoids expanding a 512k-node table into millions
of Python objects; interpolation reads only the eight neighbouring nodes.
"""

from __future__ import annotations

import struct
import zlib
import math
import json
import hashlib
from array import array
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence, Tuple


_CACHE: dict[str, tuple[PackedLUT, Tuple[float, ...]]] = {}

@dataclass
class PackedLUT:
    size: int
    scale: float
    values: array
    channel_order: str = "BGR"
    axis_order: str = "BGR"

    def __getitem__(self, index: int) -> Tuple[float, float, float]:
        i = int(index) * 3
        return (self.values[i] / self.scale, self.values[i + 1] / self.scale, self.values[i + 2] / self.scale)


def _data_root() -> Path:
    return Path(__file__).with_name("data")


def _profile_key(name: str) -> str:
    key = "".join(ch for ch in name.upper() if ch.isalnum())
    return {
        "CLASSICCHROME": "classic_chrome", "CLASSICNEG": "classic_neg",
        "NOSTALGICNEG": "nostalgic_neg", "ETERNA": "eterna",
        "ETERNABLEACHBYPASS": "bleach_bypass", "PRONEGHI": "pro_neg_hi",
        "PRONEGSTD": "pro_neg_std", "MONOCHROME": "bw", "MONO": "bw",
        "REALAACE": "reala_ace",
    }.get(key, key.lower())


def _filter_key(name: str) -> str:
    key = "".join(ch for ch in name.upper() if ch.isalnum())
    if key in {"ACROSG", "ACROSGREEN"}: return "acros_g_filter"
    if key in {"ACROSR", "ACROSRED"}: return "acros_r_filter"
    if key in {"ACROSYE", "ACROSYELLOW"}: return "acros_ye_filter"
    if key in {"MONOCHROMEG", "MONOG", "MONOGREEN"}: return "mono_g_filter"
    if key in {"MONOCHROMER", "MONOR", "MONORED"}: return "mono_r_filter"
    if key in {"MONOCHROMEye".upper(), "MONOYE", "MONOYELLOW"}: return "mono_ye_filter"
    return _profile_key(name)


def load_packed_lut(path: str | Path) -> tuple[PackedLUT, Tuple[float, ...]]:
    data = Path(path).read_bytes()
    if data[:8] not in {b"FFCSLUT1", b"FFCSLUT2"}:
        raise ValueError(f"Unsupported FFCS LUT container: {path}")
    start = 60 if data[:8]==b"FFCSLUT2" else 56
    if len(data)<start: raise ValueError(f"Truncated FFCS LUT header: {path}")
    size, channels, scale = struct.unpack_from("<HHf", data, 8)
    if channels != 3 or size < 2 or not math.isfinite(scale) or scale <= 0:
        raise ValueError(f"Invalid FFCS LUT header: {path}")
    matrix = struct.unpack_from("<9f", data, 16)
    flags = data[52] if data[:8] == b"FFCSLUT2" else 0
    if flags&~1 or not all(map(math.isfinite,matrix)):
        raise ValueError(f"Invalid FFCS LUT flags or matrix: {path}")
    payload_len = struct.unpack_from("<I", data, 56 if data[:8] == b"FFCSLUT2" else 52)[0]
    start = 60 if data[:8] == b"FFCSLUT2" else 56
    if len(data)!=start+payload_len:
        raise ValueError(f"FFCS LUT compressed length mismatch: {path}")
    expected = size * size * size * 3 * 2
    decoder = zlib.decompressobj()
    try: payload = decoder.decompress(data[start:],expected+1)
    except zlib.error as exc: raise ValueError(f"Invalid compressed LUT: {path}") from exc
    if not decoder.eof or decoder.unused_data:
        raise ValueError(f"Truncated or trailing compressed LUT data: {path}")
    if len(payload) != expected:
        raise ValueError(f"Invalid FFCS LUT payload length {len(payload)} != {expected}")
    values = array("H")
    values.frombytes(payload)
    if values.itemsize != 2:
        raise RuntimeError("Unsupported native uint16 representation")
    if __import__("sys").byteorder != "little":
        values.byteswap()
    channel_order = "RGB" if flags & 1 else "BGR"
    return PackedLUT(size, float(scale), values, channel_order=channel_order, axis_order="BGR"), matrix


def load_reference_lut(camera: str, simulation: str) -> tuple[PackedLUT, Tuple[float, ...], Path] | None:
    cam = "".join(ch for ch in str(camera).upper() if ch.isalnum())
    # Dedicated tables take priority; common GFX100 fallbacks are explicitly
    # recorded as unverified camera substitutions in pipeline metadata.
    families = {"XH2S": ("xh2s",), "XA3": ("xa3",), "GFX100": ("gfx100",),
                "GFX100S": ("gfx100s","gfx100"), "GFX100II": ("gfx100ii","gfx100")}.get(cam)
    if families is None:
        return None
    path = next((p for family in families if (p:=_data_root()/family/f"{_filter_key(simulation)}.lutz").is_file()),None)
    if path is None: return None
    key = str(path)
    if key not in _CACHE:
        _CACHE[key] = load_packed_lut(path)
    lut, matrix = _CACHE[key]
    return lut, matrix, path


def reference_validation(path: str | Path) -> dict:
    """Attach measurements only when the sampled asset hash still matches."""
    report_path = _data_root()/"reference_validation.json"
    path = Path(path)
    if report_path.is_file():
        data = json.loads(report_path.read_text())
        key = str(path.relative_to(_data_root()))
        item = data.get("tables",{}).get(key)
        if item and item["packed_sha256"]==hashlib.sha256(path.read_bytes()).hexdigest():
            return {**item,"status":"measured","scope":data["scope"],
                    "method":data["method"],"metric_domain":data["metric_domain"]}
    return {"status":"unquantified","scope":"packed LUT only","source":str(path)}
