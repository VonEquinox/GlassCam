"""Inspect downloaded samples without applying camera color transforms."""

import io
import hashlib
import json
import sys
from pathlib import Path

import rawpy
import tifffile
from PIL import ExifTags, Image


BASE = Path(__file__).resolve().parent
SAMPLES = BASE / "samples"


def plain(value):
    if isinstance(value, bytes):
        return {"bytes": len(value), "sha256": hashlib.sha256(value).hexdigest()}
    if isinstance(value, dict):
        return {str(k): plain(v) for k, v in value.items()}
    if isinstance(value, (tuple, list)):
        return [plain(v) for v in value]
    if hasattr(value, "tolist"):
        return plain(value.tolist())
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def save_preview(im, name):
    im = im.convert("RGB")
    im.thumbnail((1400, 1100))
    im.save(BASE / name)


def file_sha256(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


results = {"rawpy": rawpy.__version__, "libraw": rawpy.libraw_version, "files": {}}
paths = sorted(SAMPLES.iterdir()) + [Path(arg).resolve() for arg in sys.argv[1:]]
for path in paths:
    if path.suffix.lower() not in (".arw", ".3fr"):
        continue
    name = path.name
    with tifffile.TiffFile(path) as tif:
        tags = tif.pages[0].tags
        metadata = {
            tag.name: plain(tag.value)
            for tag in tags.values()
            if tag.name in ("Make", "Model", "Software", "DateTime", "ExifTag", "AsShotNeutral")
        }
    with rawpy.imread(str(path)) as raw:
        visible = raw.raw_image_visible
        record = {
            "bytes": path.stat().st_size,
            "path": str(path.resolve()),
            "sha256": file_sha256(path),
            "metadata": metadata,
            "raw_size": [raw.sizes.raw_width, raw.sizes.raw_height],
            "visible_size": [raw.sizes.width, raw.sizes.height],
            "color_desc": raw.color_desc.decode("ascii"),
            "raw_pattern": plain(raw.raw_pattern),
            "black_level_per_channel": plain(raw.black_level_per_channel),
            "white_level": raw.white_level,
            "camera_white_level_per_channel": plain(raw.camera_white_level_per_channel),
            "camera_whitebalance": plain(raw.camera_whitebalance),
            "rgb_xyz_matrix": plain(raw.rgb_xyz_matrix),
            "visible_raw_range": [int(visible.min()), int(visible.max())],
            "fraction_at_white_level_full_frame": float((visible >= raw.white_level).mean()),
        }
        thumb = raw.extract_thumb()
        if thumb.format == rawpy.ThumbFormat.JPEG:
            with Image.open(io.BytesIO(thumb.data)) as im:
                save_preview(im, name + ".preview.jpg")
        elif thumb.format == rawpy.ThumbFormat.BITMAP:
            save_preview(Image.fromarray(thumb.data), name + ".preview.jpg")
    results["files"][name] = record

path = SAMPLES / "B_31325.JPG"
with Image.open(path) as im:
    exif = im.getexif()
    metadata = {ExifTags.TAGS.get(k, str(k)): plain(v) for k, v in exif.items()}
    if 34665 in exif:
        metadata["ExifIFD"] = {
            ExifTags.TAGS.get(k, str(k)): plain(v)
            for k, v in exif.get_ifd(34665).items()
        }
    results["files"][path.name] = {
        "bytes": path.stat().st_size,
        "size": im.size,
        "metadata": metadata,
        "icc_profile_bytes": len(im.info.get("icc_profile", b"")),
    }
    save_preview(im, "B_31325.JPG.preview.jpg")

out = json.dumps(plain(results), indent=2, ensure_ascii=True)
(BASE / "sample-inspection.json").write_text(out + "\n", encoding="utf-8")
print(out)
