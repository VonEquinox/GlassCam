"""Input invariants shared by rendering, IO and comparison."""
from __future__ import annotations

import math


def pixel_shape(pixels, *, name="pixels") -> tuple[int, int]:
    h = len(pixels)
    w = len(pixels[0]) if h else 0
    if not h or not w:
        raise ValueError(f"{name} must be a non-empty rectangular RGB image")
    for row in pixels:
        if len(row) != w:
            raise ValueError(f"{name} has rows of different widths")
        for rgb in row:
            if len(rgb) != 3 or not all(math.isfinite(float(v)) for v in rgb):
                raise ValueError(f"{name} must contain finite RGB triples")
    return h, w


def matching_shapes(a, b):
    sa, sb = pixel_shape(a, name="reference"), pixel_shape(b, name="candidate")
    if sa != sb:
        raise ValueError(f"Image shapes differ: {sa} != {sb}")
    return sa


def canonical_space(space: str) -> str:
    key = "".join(c for c in str(space).lower() if c.isalnum())
    if key == "srgb":
        return "sRGB"
    if key in {"adobergb", "adobergb1998"}:
        return "AdobeRGB"
    raise ValueError(f"Unsupported output colour space: {space}")


def json_safe(value):
    """Keep JSON strict while retaining a perfect-match PSNR explicitly."""
    if isinstance(value, float) and not math.isfinite(value):
        return "Infinity" if value == float("inf") else "-Infinity" if value == -float("inf") else None
    if isinstance(value, dict):
        return {k: json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(v) for v in value]
    return value
