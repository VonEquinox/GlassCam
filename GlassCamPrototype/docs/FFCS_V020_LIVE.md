# FFCS 0.2 experimental live-color remeasurement

Measured 2026-10-13 against the newly pinned `c4b3383` reference. This is a diagnostic study, not a production-path modification, camera-JPEG equivalence certificate, or Apple-device test. Old private-context FFCS LUT studies do not establish the new default's accuracy.

## Exact scope

- Public oracle: `ffcs_process_linear_rgb_color_only` using `ffcs_create_family_config`.
- Family XH2S; PROVIA index 0 or ACROS index 8; native table, `applyReferenceAdjustments=false`, sharpening radius 1.0, exposure 0 EV.
- Grain and sharpness gates may each be on or off. All four combinations were checked on 3,977 independent reference probes; with native neutral defaults they have no coefficient to apply. No analytic overlay, other camera family, other simulation, other radius, nonzero exposure, HNCS chain, or spatial effect is covered.
- Input is finite linear-sRGB RGB in [0,1]. Source clipping happens before shaping; this study does not validate wide-gamut/HDR preservation or camera buffer conversion.
- 65³ nodes. Node input = sRGB EOTF(index/64), evaluated in double and cast to Float32, matching the Swift baker. Lookup coordinate = sRGB OETF(linear input) in Float32.
- Node storage is RGBA Float32, R fastest, G next, B slowest: float offset `((B*65+G)*65+R)*4`. Alpha is exactly one. Output is display-linear sRGB, with no post-lookup inverse shaper. Each cube is 4,394,000 bytes.
- Explicit CPU Float32 trilinear lookup; final Float16 rounding models RGBA16Float drawable storage. Cube nodes themselves are not rounded to half.

## Results

452,780 held-out colors per look: 200,000 uniform linear, 100,000 uniform encoded-domain colors decoded to linear, 40,000 boundary, 40,000 saturated, 40,000 logarithmic dark, 8,193 gray, 24,579 channel-axis, and eight corners. Seed 20261013. Cube nodes are separate from the random holdouts; deterministic corners and axes deliberately include node locations to test boundaries.

Final RGBA16Float output compared with direct native Float32 oracle:

| Look | Encoded max | Encoded channel RMSE | Lab ΔE76 p99 | Lab ΔE76 max |
|---|---:|---:|---:|---:|
| PROVIA | 0.01815040 | 0.000852833 | 0.611160 | 2.532723 |
| ACROS | 0.01576168 | 0.000495999 | 0.189495 | 1.101971 |

Float32 output before drawable rounding:

| Look | Encoded max | Encoded channel RMSE | Lab ΔE76 p99 | Lab ΔE76 max |
|---|---:|---:|---:|---:|
| PROVIA | 0.01806026 | 0.000851195 | 0.610142 | 2.531571 |
| ACROS | 0.01575995 | 0.000492761 | 0.189514 | 1.101850 |

Encoded errors use normalized floating sRGB values without integer quantization. ΔE76 uses linear sRGB to XYZ D65 and Lab D65; it is not CIEDE2000 or a universal visibility threshold. These observed maxima are not mathematical uniform bounds. In particular, isolated PROVIA differences can exceed ΔE76 2.5, so the cube must remain explicitly approximate.

## Cross-checks

- Independent new public Python `FFCS(PipelineConfig(camera='XH2S', simulation=..., input_is_linear=True)).apply(...)` compared against native direct oracle on 3,977 random/boundary/dark/saturated/axis/corner colors per look. No copied private transform or old LUT oracle was used.
- Full native public `ffcs_process_linear_rgb` and color-only output were bit-identical on the same subset, as expected for neutral spatial coefficients.
- All 274,625 nodes per look reproduced their stored RGBA values exactly. Identity-cube channel-axis/layout tests passed. Alpha stayed one.
- NaN, positive/negative infinity, negative input, and input above one were rejected before output changed.
- Source, asset, and cube hashes and all per-category metrics are recorded in `validation/ffcs-v020-live-study.json`.

## Admission and limits

The evidence supports considering only the exact narrow recipe identity above for the existing opt-in approximate live path. It does not establish broader support, imperceptibility, camera visual matching, or frame rate. Admission is a product gate maintained separately from this diagnostic script. Keep other FFCS recipes on the system preview fallback until measured.

Apple SDK compilation, Core Image's actual shaper/interpolation/color-management arithmetic, GPU channel layout and rounding, camera video inputs, orientation/cropping, photographs, thermal behavior, latency, FPS, and energy use remain untested here. HNCS was neither modified nor remeasured.

Reproduce from repository root after installing the pinned reference's Python dependencies:

```sh
python tools/ffcs_v020_live_study.py
```

The script compiles `build/ffcs_v020_live.so` from the current public native core, writes only its diagnostic JSON under `validation`, and prints the two aggregate metric rows. It does not publish, register cubes, or edit app admission.
