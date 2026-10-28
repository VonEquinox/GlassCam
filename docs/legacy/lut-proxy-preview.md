> FFCS部分为0.1历史数学/性能证据；0.2中性默认与Gaussian算法已变更，不能直接外推。当前实现及新证据见[FFCS](FFCS.md)。HNCS部分依其自身版本说明。

# Color-only GPU preview LUT investigation

This is an offline approximation study, **not a production enable**. This study does not change production kernels, full-photo processing, original resources or the high-precision display path. A separately implemented experimental app option is outside these offline results. The user has explicitly scoped live preview to color only: no grain, blur, halation, sharpening or other spatial effects.

## Reference and domain

- Input is finite Float32 **linear-sRGB in [0,1]³**, not camera-native RAW. A rendered camera-video image must first be color-managed into this declared domain. The same numerals in ProRAW scene-linear data or another transfer/primaries space are not interchangeable; this study does not establish camera matching.
- HNCS uses the actual production Float output with fixed EV=0, 5500 K, legacy/standard mode, including its experimental source bridge and original UInt16 core. FFCS uses actual PROVIA/ACROS assets and all pointwise matrix, LUT, Lab/UCS and tone operations, with EV=0.
- Only tool-private FFCS contexts have grain=0 and sharp=0. The extracted pointwise oracle matches the production serial Float API with those same zero coefficients bit-for-bit on 1,000 colors per look. This is not a 1×1 image workaround that accidentally retains grain. No production context is altered.
- Five transforms: HNCS, PROVIA, ACROS, HNCS→PROVIA and HNCS→ACROS. The chain is explicit and does not apply EV twice. These two combined transforms are research coverage only; they do not imply that the app combines its independently selected HNCS/FFCS modes.
- Oracle and stored nodes are display-linear sRGB Float32, clipped by their existing pointwise transforms. Half precision is independently evaluated by rounding nodes to binary16 and promoting to Float32 for CPU interpolation. This isolates node storage error; it does **not** reproduce Metal texture filtering precision.
- LUT sampling grids are either uniform in linear RGB, or uniform in the sRGB-OETF coordinates of that same linear input domain. The latter is a nonuniform linear-light sampling grid, not a change of input color space. The float sRGB transfer used for supplementary metrics introduces no 8-bit quantization.

## Reproduce / export

From the prototype directory:

```sh
OPENBLAS_NUM_THREADS=1 python tools/lut_proxy_study.py
python tools/lut_proxy_bake.py --look PROVIA --nodes 65 --shaper srgb --output build/lut-proxy-provia65.rgba32f
```

The study writes `validation/lut-proxy-study.json` with every metric, per-category extreme vectors, source/asset hashes, CPU timings and configuration. The export is tool-only; it does not install an asset or register an app path. It writes a Float32 RGBA binary plus JSON contract. The CLI deliberately only supports the tested fixed settings. It must be extended and revalidated before shipping other recipes/EV/WB.

## GPU/data contract

- Exported index is `((B*N + G)*N + R)*4`: **R fastest**, then G, then B; little-endian Float32 RGBA, alpha exactly 1. Internal diagnostic storage is R-major/B-fast and is explicitly transposed on export.
- Linear-grid cube coordinates are linear input RGB. Shaped-grid coordinates are `sRGB_OETF(linear_input_RGB)`, while output node RGB remains display-linear. A shaped cube cannot be fed unshaped linear coordinates in CIColorCube. Implement explicit transfer-coordinate mapping or custom Metal; also ensure color management does not interpret these coordinate values as a newly tagged sRGB image and decode them again.
- For a normalized Metal 3D texture with edge nodes, map shaped coordinate q to `(q*(N-1)+0.5)/N` to address texel centers; use clamp-to-edge and linear filtering. Verify each axis with asymmetric test colors. Hardware-filter precision and Apple execution remain untested.
- Values outside [0,1], negatives and NaN/Inf are outside the validated domain. The CPU lookup clamps as a defensive implementation detail, but this does not approve silently clamping extended scene highlights. A live path needs a documented admission/clamp policy and separate extended-range validation. HLG/PQ/HDR and ProRAW scene-linear extrapolation are not covered.
- Output is linear-sRGB RGB/alpha 1 for the existing high-precision SDR conversion/display, such as RGBA16Float. No RGBA8/UIImage boundary is required. Texture size does not constrain capture/export size.

## Cache and update contract

Key every cached cube by core/adapter version and source hashes, FFCS asset hash/index, HNCS mode flags, pipeline order, EV, WB/CCT (including truncation behavior), all pointwise recipe values, input primaries/transfer/domain policy, grid/shaper version, dimensions, interpolation and storage format. Omitted spatial settings must be fixed off, not copied from a full-photo recipe. Video auto-WB can already be baked into rendered frames; do not pretend a second HNCS CCT knob recovers sensor white balance.

Bake or retrieve off the capture/display queues, debounce rapid settings, retain immutable entries, cancel stale requests, atomically swap only a complete matching cube, and bound cache memory. Until the exact requested key is ready, show an explicitly unchanged/previous state rather than publishing a stale cube as the new look. Do not rebake per video frame. The full-photo kernel remains the exact path.

## Limits and next experiment

These are synthetic holdouts, not a global worst-case bound, photographic aesthetic evaluation, Apple GPU benchmark, energy/thermal test, or proof that rendered video matches a captured still. Ordinary randomized colors, gray ramps, dark values, saturated edges and cube boundary probes are all separately reported; a low mean alone is insufficient and adversarial maximum alone need not disqualify a preview proxy.

A hybrid shader that preserves analytic source/matrix/clamp/transfer stages and samples a smaller cube for the smooth remaining color transform may avoid baking sharp gamut boundaries into one interpolated cube. FFCS's existing LUT can also be sampled directly, with later pointwise math retained or separately approximated. These are plausible next architectures, not measured improvements here; first inspect the saved extreme vectors. HNCS core quantization/clip behavior can create discontinuities that no finite smooth cube exactly reproduces. Do not add color-card fitting to solve a purely numerical approximation problem.

## Measured results and recommendation

Run: 2026-10-11, Linux cloud CPU, fixed settings above. 168,193 samples: 100,000 independent random linear colors, 8,193 gray-ramp values, 20,000 dark log-distributed colors, 20,000 saturated edge values, 20,000 boundary probes. Seventy combinations cover five looks, two grid shapings, three sizes, two node precisions plus selected tetrahedral comparisons. Every interpolator reproduces all its stored nodes exactly; independent affine-identity and exported-axis tests also pass.

**Practical choice: evaluate a 65³ sRGB-shaped, trilinearly sampled, half-stored cube on device.** It is a good bounded first approximation candidate across these looks, not approved production behavior. A 33³ cube can be a lower-memory HNCS/ACROS tier after visual review; PROVIA has appreciably larger errors at 33³. Do not choose a plain linear-coordinate CI cube merely because its integration is simpler. Exact full-photo processing stays separate.

All channel metrics below are floating-point encoded-sRGB differences normalized to [0,1], never byte differences. ΔE76 is CIELAB D65 from the tagged display-linear sRGB outputs, **not ΔE2000**, and no universal perceptual visibility threshold is asserted. Per-pixel error is max absolute RGB channel; p95/p99 percentiles are over pixels.

| Look | Nodes | Channel max | p95 | p99 | RMSE | ΔE76 max | ΔE76 p99 |
|---|---:|---:|---:|---:|---:|---:|---:|
| HNCS | 17 | 0.12867 | 0.00632 | 0.01837 | 0.00318 | 2.972 | 1.118 |
| HNCS | 33 | 0.07699 | 0.00179 | 0.00476 | 0.00122 | 1.501 | 0.381 |
| HNCS | 65 | 0.03947 | 0.00054 | 0.00143 | 0.00043 | 0.795 | 0.137 |
| PROVIA | 17 | 0.06218 | 0.01869 | 0.02810 | 0.00555 | 12.408 | 3.570 |
| PROVIA | 33 | 0.03477 | 0.00809 | 0.01304 | 0.00232 | 6.310 | 1.588 |
| PROVIA | 65 | 0.01546 | 0.00311 | 0.00548 | 0.00087 | 2.475 | 0.612 |
| ACROS | 17 | 0.04414 | 0.00741 | 0.01602 | 0.00369 | 4.405 | 1.517 |
| ACROS | 33 | 0.02369 | 0.00243 | 0.00523 | 0.00121 | 2.359 | 0.491 |
| ACROS | 65 | 0.00970 | 0.00066 | 0.00167 | 0.00039 | 0.968 | 0.156 |
| HNCS_PROVIA | 17 | 0.13248 | 0.01435 | 0.03155 | 0.00479 | 12.135 | 3.103 |
| HNCS_PROVIA | 33 | 0.07454 | 0.00514 | 0.01181 | 0.00181 | 6.500 | 1.159 |
| HNCS_PROVIA | 65 | 0.03982 | 0.00162 | 0.00411 | 0.00062 | 3.510 | 0.405 |
| HNCS_ACROS | 17 | 0.05586 | 0.00575 | 0.01254 | 0.00309 | 5.558 | 1.158 |
| HNCS_ACROS | 33 | 0.02481 | 0.00162 | 0.00375 | 0.00096 | 2.494 | 0.353 |
| HNCS_ACROS | 65 | 0.00988 | 0.00048 | 0.00114 | 0.00030 | 0.987 | 0.108 |

### What the outliers mean

- HNCS65's largest encoded-channel deviation occurs at input [0, 0.6157176, 0.1707825]. Exact red is clipped to zero; proxy red is 0.0030549 linear. The sRGB toe magnifies this to 0.03947 encoded, while overall worst ΔE76 across the entire test is only 0.795. Thus the channel maximum alone overstates the practical perceptual concern. HNCS33 ΔE76 max is 1.50, p99 0.381: a plausible preview-quality tier, not numerically exact.
- PROVIA65's extreme is an ordinary interior input [0.2707940, 0.2680273, 0.4432997]; blue is 0.7253346 exact versus 0.6965106 proxy linear. Its errors cannot be dismissed as only adversarial gamut boundaries. All per-category maxima and exact vectors are in JSON.
- ACROS65's extreme is interior [0.2692335, 0.6485189, 0.6357316], approximately 0.215113 exact gray versus 0.224227 proxy.
- HNCS→PROVIA65 again has a clipped-red extreme. HNCS→ACROS65's extreme is interior. This is numerical interpolation error against the same color-only oracle; it does not quantify missing grain/sharpen from full-photo output, because those are intentionally outside live-preview scope.
- Small binary16 storage error is not the main limit: the maximum measured node rounding across all tables is 0.000244141 linear. Trilinear/tetrahedral convex interpolation cannot amplify node storage error beyond that bound in a single output channel with exact arithmetic; hardware arithmetic still needs measurement.

### Tetrahedral versus trilinear

At shaped65/half, tetrahedral changes PROVIA ΔE76 max/p99 from 2.475/0.612 to 2.019/0.548, ACROS from 0.968/0.156 to 0.727/0.136, and HNCS from 0.795/0.137 to 0.774/0.130. HNCS maximum individual encoded-channel error actually rises (0.03947→0.04702). This is a modest, non-uniform improvement, not a reason to require a custom tetrahedral shader before evaluating inexpensive hardware trilinear filtering. CPU reference lookup costs are not a Metal comparison.

### Memory and cold-bake cost

| Nodes | RGBA16F bytes | RGBA32F bytes | HNCS bake ms | PROVIA bake ms | ACROS bake ms |
|---|---:|---:|---:|---:|---:|
| 17 | 39,304 | 78,608 | 1.12 | 9.03 | 6.03 |
| 33 | 287,496 | 574,992 | 8.28 | 58.53 | 73.40 |
| 65 | 2,197,000 | 4,394,000 | 164.74 | 522.17 | 376.65 |

Bake values are medians of three calls on a variable shared cloud CPU, with contexts/assets already loaded; no device timing inference. They exclude grid creation, half conversion, cache management and GPU upload. A 65³ half RGBA cube is about 2.10 MiB; double-buffering is about 4.19 MiB plus any Float32 bake copy.

CPU-reference lookup of all 168,193 pixels (precomputed coordinates, not an image pipeline) takes median ranges across the five shaped half tables: 17³: 5.06–8.58 ms; 33³: 5.66–9.97 ms; 65³: 7.92–13.25 ms; these measurements are explicitly **not GPU timings, camera-frame cadence, or sustained phone performance**.

### Bounded next acceptance step

Use shaped65 trilinear for a debug-only device experiment with real center video, explicit input conversion and float output. Inspect ordinary photos plus the saved extreme vectors and ramps; verify the GPU against the CPU lookup, source-domain handling, stale-cache rejection, frame drops, memory and sustained thermal behavior. Adopt an application-specific visual/error budget after that review rather than inventing a universal approval threshold from these synthetic metrics. If PROVIA outliers remain visible, test the hybrid matrix/transfer-plus-native-LUT path before increasing to an unbounded large cube. No additional color-card calibration is needed for this numerical study.

## Evidence baseline and file scope

The measured core snapshot predates any separately added production color-only API. SHA-256: HNCS core `cd43b8ac69fd614cd1fa9f927a44e2cd87f8c264ca3fb16a2d777e8fffbd25b6`; FFCS core `ce38d7cdfcee449cd4b7b0c279d50ce944c997d1b83908ec35c7567ba0574d99`. Full tool and resource hashes are in the study JSON. Adding a new production API later does not retroactively make this its validation; compare the new API to this oracle and rerun as appropriate.

`tools/lut_proxy_verify.py` reproduces the export layout, float format/alpha/finite checks, six asymmetric/corner oracle vectors, 10,000 affine-identity samples for each interpolator, and Lab black/white sanity checks. Its result is `validation/lut-proxy-verification.json`. Generated `.so` and `.rgba32f` files stay under build and are not source deliverables.
