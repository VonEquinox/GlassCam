"""Spatial effects: film grain, chroma grain, and unsharp masking."""

from __future__ import annotations

import math
import random
from typing import List, Sequence, Tuple

from PIL import Image, ImageFilter

from .color import clamp, grayscale, luminance
from .models import FilmSimulation

RGB = Tuple[float, float, float]


def _hash_noise(x: int, y: int, seed: int) -> float:
    # Integer hash gives repeatable output across Python versions/platforms.
    n = (x * 374761393 + y * 668265263 + seed * 69069) & 0xFFFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0xFFFFFFFF
    n ^= n >> 16
    return (n / 4294967295.0) * 2.0 - 1.0


def _smooth_noise(x: int, y: int, width: int, height: int, seed: int) -> float:
    # Bilinear value noise.  Sampling at a reduced grid controls grain size.
    scale = max(1.0, width * 0.008)
    gx, gy = int(x / scale), int(y / scale)
    fx, fy = (x / scale - gx), (y / scale - gy)
    def n(ix: int, iy: int) -> float:
        return _hash_noise(ix, iy, seed)
    a = n(gx, gy) * (1-fx) + n(gx+1, gy) * fx
    b = n(gx, gy+1) * (1-fx) + n(gx+1, gy+1) * fx
    return a * (1-fy) + b * fy


def apply_grain(pixels: List[List[RGB]], spec: FilmSimulation, seed: int = 0) -> List[List[RGB]]:
    if spec.grain_strength <= 0:
        return pixels
    height = len(pixels)
    width = len(pixels[0]) if height else 0
    out: List[List[RGB]] = []
    strength = float(spec.grain_strength) * 0.035
    size = max(0.25, float(spec.grain_size))
    chroma = clamp(float(spec.grain_chroma), 0.0, 1.0)
    for y, row in enumerate(pixels):
        newrow: List[RGB] = []
        for x, rgb in enumerate(row):
            # Fine and coarse components reproduce the broad spectrum of film
            # grain while remaining deterministic and streamable.
            fine = _hash_noise(x, y, seed)
            coarse = _smooth_noise(int(x / size), int(y / size), max(1, int(width / size)), max(1, int(height / size)), seed + 17)
            n = 0.72 * fine + 0.28 * coarse
            lum = luminance(rgb)
            # Grain is proportional to exposure and naturally fades in deep
            # shadows/highlights where the emulsion has less variance.
            exposure = 0.35 + 0.9 * math.sqrt(max(0.0, lum * (1.0 - 0.45 * lum)))
            delta = n * strength * exposure
            if spec.acros or spec.saturation == 0:
                g = clamp(grayscale(rgb) + delta)
                newrow.append((g, g, g))
            else:
                c = n * strength * chroma * 0.45
                newrow.append((clamp(rgb[0] + delta + c), clamp(rgb[1] + delta), clamp(rgb[2] + delta - c)))
        out.append(newrow)
    return out


def apply_sharpen(image: Image.Image, amount: float, radius: float = 1.0) -> Image.Image:
    """Unsharp mask with a stable radius/percent mapping."""

    if amount <= 0:
        return image
    percent = int(max(1, min(500, amount * 100)))
    return image.filter(ImageFilter.UnsharpMask(radius=max(0.1, radius), percent=percent, threshold=1))


def apply_sharpen_pixels(pixels: Sequence[Sequence[RGB]], amount: float, radius: float = 1.0) -> List[List[RGB]]:
    """Float-preserving unsharp mask for the final 16-bit path."""

    if amount <= 0:
        return [list(map(tuple, row)) for row in pixels]
    h, w = len(pixels), len(pixels[0]) if pixels else 0
    strength = max(0.0, min(3.0, amount)) * 0.35
    out: List[List[RGB]] = []
    for y in range(h):
        row: List[RGB] = []
        for x in range(w):
            neigh = []
            for yy in range(max(0, y-1), min(h, y+2)):
                for xx in range(max(0, x-1), min(w, x+2)):
                    neigh.append(pixels[yy][xx])
            blur = tuple(sum(v[c] for v in neigh) / len(neigh) for c in range(3))
            row.append(tuple(clamp(pixels[y][x][c] + strength * (pixels[y][x][c] - blur[c])) for c in range(3)))
        out.append(row)
    return out
