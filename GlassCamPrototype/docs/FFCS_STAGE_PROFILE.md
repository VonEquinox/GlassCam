# FFCS CPU stage attribution and neutral-UCS experiment

## Result

The dominant cost in this portable CPU implementation is repeated double-precision Lab/UCS conversion, not the original 3D LUT lookup or film grain. Original-loop 720p profiles spend a median 66.4% (PROVIA) / 69.4% (ACROS) in Lab+UCS. LUT preparation plus trilinear sampling is about 10%; grain about 3%; sharpening including allocation about 4.6–4.7%. A separate split-pass profile attributes only 4.5–6.8% to LUT sampling itself and 1.3–1.4% to sharpening arithmetic. These are medians of within-run shares, not ratios of independently computed medians.

Therefore reducing LUT dimension alone or deleting grain/sharpening cannot remove the main cost. Baking the static pointwise color mapping can remove the expensive conversions; this is an approximate preview candidate, not a strict-equivalent replacement. Keep the exact path for final processing until an explicitly relaxed contract is chosen.

## Environment and scope

- CPU: Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz
- Platform: Linux-6.18.44-x86_64-with-glibc2.41
- Compiler: g++ (Debian 14.2.0-19) 14.2.0
- Flags: -std=c++17 -O3 -fno-fast-math -ffp-contract=off -pthread
- Production `core/ffcs.cpp` SHA-256: `ce38d7cdfcee449cd4b7b0c279d50ce944c997d1b83908ec35c7567ba0574d99`
- One warmup, three measured samples per mode; process CPU and steady-clock wall recorded in raw JSON.
- Real C++, original XH2S assets. Synthetic gradient/noise linear RGB, EV 0, seed 37. No RAW decode, camera capture, LUT loading/decompression, display, Metal/GPU, or file I/O in timings. No iPhone extrapolation.
- Main final run did not overlap the other assigned LUT benchmark. Cloud variability remains substantial: timing mode order is sequential, CPU scheduling/frequency/quota are not controlled, and sample count is small. An overlapping preflight was excluded from published results.

## API wall p50 (milliseconds)

| Look | Resolution | Full production | Exact row-stream 1 worker | Exact row-stream 4 workers | Exact RGBA-only 4 workers |
|---|---:|---:|---:|---:|---:|
| PROVIA | 256×144 | 87.8 | 65.5 | 50.6 | 41.6 |
| PROVIA | 512×288 | 271.6 | 365.7 | 115.5 | 129.2 |
| PROVIA | 1280×720 | 1888.1 | 2018.1 | 1131.3 | 582.7 |
| ACROS | 256×144 | 76.0 | 77.5 | 27.2 | 25.4 |
| ACROS | 512×288 | 310.5 | 265.0 | 103.7 | 92.9 |
| ACROS | 1280×720 | 2063.6 | 2161.0 | 1359.0 | 567.1 |

At 720p, full production PROVIA raw wall samples were 1576.1/1889.1/1888.1 ms; ACROS 2063.6/2024.9/3239.9 ms. Four-worker full-output samples were PROVIA 1131.3/619.0/1250.8 ms and ACROS 1549.6/1201.3/1359.0 ms. Thus a previously observed “~1 second at 720p” is plausible for this CPU/parallel implementation, but not a stable specification. The arithmetic explanation is robust; fixed throughput is not. RGBA-only eliminates optional output decoding and float stores, but its apparent speedup exceeds the isolated decode share due to uncontrolled cloud variation; do not attribute the whole speedup to that omission.

## Original-loop stage wall p50 at 720p (milliseconds)

| Stage | PROVIA | ACROS |
|---|---:|---:|
| input_allocation | 24.2 | 21.8 |
| input_validation_gain | 15.4 | 7.5 |
| matrix_3x3 | 13.6 | 10.1 |
| lut_3d | 258.2 | 239.0 |
| lab_ucs | 1479.5 | 1684.2 |
| tone_curve | 13.9 | 23.6 |
| film_grain | 77.7 | 87.9 |
| sharpen | 105.8 | 80.1 |
| output_decode_float | 170.9 | 134.8 |
| output_rgba_quantize | 84.0 | 49.0 |

Stage medians do not sum to the total median. `gamma_pre` is a no-op for this linear-input route; `output_icc` is a no-op marker for sRGB. Actual transfer-function work is inside LUT preparation, Lab/UCS, and float output decoding. The original-loop sharpen interval includes its double output allocation.

## Split attribution at 720p (milliseconds)

| Substage | PROVIA | ACROS |
|---|---:|---:|
| lut_input_encode | 94.9 | 117.7 |
| lut_sample | 104.8 | 144.3 |
| lab | 773.2 | 650.8 |
| ucs | 692.0 | 563.8 |
| tone_curve | 16.5 | 36.8 |
| film_grain | 63.5 | 57.7 |
| sharpen_allocation | 32.4 | 33.1 |
| sharpen | 27.1 | 22.5 |

Splitting adds passes and changes compiler/cache behavior, so use these values for attribution, not to predict a production speedup by subtraction. Full-frame input/sharpen allocations occupy about 44.2 MB of double RGB at 720p (22.1 MB each); exact row streaming reduces post-grain working storage to ~90 KiB per worker. It does not remove color conversion arithmetic.

## Neutral UCS omission: approximate, measured

The current UCS adjustment leaves L/chroma/hue mathematically unchanged, but matrix constants, finite arithmetic, transfer functions and clipping make its round-trip numerically non-identity. A diagnostic removes only this round-trip, retaining matrix, original LUT, Lab, tone, exact grain, and exact sharpening. The 512×288 render-only timings exclude API allocation and final output conversion.

| Look | Full p50 ms | Omit UCS p50 ms | Encoded max abs | Encoded RMSE | Linear max abs | Changed RGB8 channels | Max code delta |
|---|---:|---:|---:|---:|---:|---:|---:|
| PROVIA | 244.0 | 139.1 | 2.68e-07 | 5.99e-08 | 2.57e-07 | 6 / 442368 | 1 |
| ACROS | 239.5 | 149.6 | 8.52e-09 | 6.14e-09 | 1.94e-08 | 0 / 442368 | 0 |

This fixture suggests a promising low-error preview simplification. It does not establish a universal worst-case bound, all-look equivalence, natural-photo quality, or permission to change the strict reference implementation. Even PROVIA already changes six output channel bytes.

## What may and may not be baked/omitted

- A per-look LUT can approximate the fixed input matrix → original packed LUT → Lab → UCS → tone mapping. EV can remain a gain/clip before the baked mapping when the same input domain is used. Re-bake when baked parameters change.
- Preserve domain transitions and clipping; the packed asset is not the complete FFCS effect. Original LUT BGR axes and channel flag, matrix and interpolation contract still matter.
- Grain cannot be encoded by an RGB-only LUT: it depends on XY, image width, grain size, seed, and luminance. The ACROS/zero-saturation grain branch also performs grayscale collapse. Removing that entire branch can remove more than texture.
- Sharpening depends on the 3×3 neighborhood and image boundaries; it cannot be encoded by an RGB-only LUT. Grain must precede sharpening to preserve the effect.
- Omitting Lab is not analogous to neutral UCS: Lab uses look saturation/hue parameters and materially defines color.
- Optional linear-float output decode can be skipped for a purely encoded-RGBA consumer; this is already supported by the exact optimized API and preserves the requested RGBA bytes.
- Exact row streaming/multithreading preserves production results and cuts memory, but scalar transcendental work remains. GPU/SIMD implementation and any approximation must be measured independently on target devices.

## Validation and reproducibility

All six image/look configurations passed double-byte comparison at every common original stage between the extracted split render and untouched production render. All timed original, split, full and optimized modes matched original final float outputs exactly; all RGBA outputs matched byte-for-byte (including the rgba-only mode). The deliberate UCS-omission experiment reports errors separately and is never asserted equivalent.

Run `python3 tools/ffcs_stage_profile/run.py`, then `python3 tools/ffcs_stage_profile/run_omit_ucs.py`. Do not run CPU benchmarks concurrently. See the harness README for timing boundaries. Raw evidence: `validation/ffcs_stage_profile/raw.jsonl`, `summary.json`, `omit_ucs.jsonl`.

Reference semantics checked against `reference_ffcs/docs/02_颜色变换数学与数值约定.md`, `05_颗粒锐化与图像IO.md`, and `implementation/ffcs/pipeline.py` from the supplied FFCS delivery. No production source or live app behavior was changed.
