"""Deterministic numeric images for native sharpness and composed-chain checks."""
import numpy as np


def corpus(seed):
    h, w = 37, 53
    rng = np.random.default_rng(seed)
    result = {f"flat-{level}": np.full((h, w, 3), level, np.uint16)
              for level in [0, 1, 2, 3, 4, 63, 64, 1023, 32767, 65532, 65535]}
    result["full-gray-ramp"] = np.repeat(np.arange(65536, dtype=np.uint16)[None, :, None], 3, axis=2)
    edge = np.full((h, w, 3), [12000, 22000, 32000], np.uint16)
    edge[:, w // 2:] = [48000, 18000, 8000]
    result["color-edge"] = edge
    checker = np.indices((h, w)).sum(axis=0) % 2
    result["saturated-checker"] = np.where(checker[..., None], [65535, 0, 32768], [0, 65535, 3]).astype(np.uint16)
    impulse = np.full((h, w, 3), 16000, np.uint16)
    for y, x in [(0, 0), (0, w - 1), (h - 1, 0), (h - 1, w - 1), (h // 2, w // 2)]:
        impulse[y, x] = [60000, 40000, 20000]
    result["corners-and-center"] = impulse
    result["dark-noise"] = rng.integers(0, 257, (h, w, 3), dtype=np.uint16)
    result["highlight-noise"] = rng.integers(65279, 65536, (h, w, 3), dtype=np.uint16)
    result["random"] = rng.integers(0, 65536, (h, w, 3), dtype=np.uint16)
    for h, w in [(1, 1), (1, 17), (19, 1), (131, 7), (5, 8203)]:
        image = rng.integers(0, 65536, (h, w, 3), dtype=np.uint16)
        image[0, 0] = [0, 1, 65535]
        image[-1, -1] = [65532, 4, 3]
        result[f"boundary-{w}x{h}"] = image
    return result
