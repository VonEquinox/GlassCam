"""Numerical model of the probed Phocus CPU sharpness path, without local layers.

The original CSharpnessFilter shifts work codes to 14 bits, computes integer
299/587/114 luma, performs horizontal then vertical integer convolution, applies
its original amount/noise tables, adds one common delta to RGB, clips and shifts
back. Tables are extracted from the original constructor, not fitted to pixels.
"""
import numpy as np


def sharpen(codes, weights, amount_table, noise_table):
    source = np.asarray(codes, dtype=np.uint16)
    work = (source.astype(np.int64) >> 2)
    luma = (work[..., 0]*299 + work[..., 1]*587 + work[..., 2]*114) // 1000
    weights = np.asarray(weights, dtype=np.int64)
    radius = len(weights) // 2
    total = int(weights.sum())
    h, w = luma.shape
    padded = np.pad(luma, ((0, 0), (radius, radius)), mode="edge")
    horizontal = sum(int(weight)*padded[:, i:i+w] for i, weight in enumerate(weights)) // total
    padded = np.pad(horizontal, ((radius, radius), (0, 0)), mode="edge")
    blurred = sum(int(weight)*padded[i:i+h] for i, weight in enumerate(weights)) // total
    difference = luma - blurred
    amplitude = np.asarray(amount_table, dtype=np.int32)[np.minimum(luma, 16383)]
    noise = np.asarray(noise_table, dtype=np.uint8)[np.minimum(abs(difference), 16383)]
    product = (difference*amplitude*noise).astype(np.int32).astype(np.int64)
    # ARM's signed /25500 truncates toward zero, including negative detail.
    correction = np.where(product >= 0, product // 25500, -((-product) // 25500))
    return (np.clip(work + correction[..., None], 0, 16383) << 2).astype(np.uint16)
