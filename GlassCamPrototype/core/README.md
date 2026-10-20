# Portable HNCS + FFCS backends

C++17, C ABI; FFCS links the platform zlib decoder. HNCS and FFCS are independent engines; neither is a substitute for measured iPhone source calibration. Swift only owns UI,
image decoding via Apple frameworks, buffers, and export. `HNCSEngine.swift` is a
thin bridge. The immutable context is thread-safe for nonoverlapping output
buffers, so a caller may split rows or tiles across workers.

## Build and golden harness

```
g++ -std=c++17 -pthread -O3 -fno-fast-math -ffp-contract=off \
  core/hncs.cpp core/hncs_cli.cpp -o hncs_cli
./hncs_cli 5550 legacy standard < native-f64.rgb > output-u16.rgb
```

CMake is also supported (`cmake -S core -B build && cmake --build build`). The
binary harness uses host-endian packed RGB triplets. It supports `legacy` or
`lstar`, and `standard` or `reproduction`. The simplest `hncs_create` constructor
selects legacy/standard/V1; preset contexts honor their explicit settings.
Reproduction selects its original pure curve.

`generate_assets.py` reproducibly emits `hncs_assets.inc` from the original NPZ
using round-trip-safe double literals and exact uint16 curve entries. NumPy is
needed only to regenerate data, not to build or run C++. The include retains the
original matrices, temperature tables, two-dimensional chroma LUTs, thresholds,
and curves; it is not a replacement fitted RGB/3-D LUT.

## Preserved boundaries

- Original integer CCT truncation and [2000,10000] clamping; matrix and chroma
  tables interpolate or extrapolate on their original intervals.
- Double arithmetic, input clip and ties-to-even quantization to 16 bits.
- YCbCr ratio lookup with original bilinear 2-D chroma mapping, saturation
  weights, native standard shadow desaturation, and neutral Y baseline.
- Working-space clipping and truncation before the exact uint16 film curve.
- Original ICC gamma/L* decoding, Bradford to D65, standard sRGB encoding.
- No fast-math or FMA contraction. Turning either on can break integer golden
  parity. Compiler/platform changes still require running golden tests.

The source adapter is experimental and separate: linear sRGB D65 is converted
to XYZ, Bradford-adapted to the row-sum white of the interpolated camera matrix,
and transformed through its inverse to virtual native RGB. Exposure precedes
this adapter. This is an appearance-processing prototype, not a measured
sensor profile or a complete Phocus/RAW rendering pipeline.

## Performance

Settings matrices and chroma LUT interpolation are computed once per context.
ICC decode values are precomputed exactly for all 65536 possible uint16 codes.
The production loop fuses adapter, core, display transform and RGBA quantization
with constant per-pixel scratch, avoiding full-frame double intermediates.
The exact `hncs_process_srgb` oracle retains the original double `pow` transfer
function. The explicitly named `hncs_process_srgb_fast` replaces only the final
sRGB OETF with a nearest-sample 65536-entry linear-light-to-byte table. Maximum
continuous code perturbation is at most 0.026 on the 0–255 scale; final RGB
bytes may differ from the exact oracle by at most one. The original HNCS core
and native uint16 codes are unchanged. The parallel variant accepts an explicit
1–4 workers, splits contiguous ranges, uses no full-frame temporary buffers,
and falls back safely if a worker cannot be launched. Inputs below 65536 pixels
run sequentially. No Metal/GPU approximation is used. Benchmark results must be
reported with their actual machine, compiler, dimensions and worker count;
desktop measurements are not iPhone frame-rate claims.

Current separated core timing is recorded in [COLOR_PERFORMANCE](../docs/COLOR_PERFORMANCE.md); it excludes Apple decoding/encoding and does not establish end-to-end export latency.

## High-bit-depth export boundary

`hncs_process_linear_rgba` emits packed Float32 display-linear sRGB RGBA (alpha 1) after the unchanged UInt16 HNCS core and display matrices, before either 8-bit OETF encoder. It guards RGBA float byte-size overflow and rejects nonfinite source data. The new `hncs_process_linear_rgba_parallel` retains this serial API as oracle and distributes identical per-pixel work across1–4 workers. It is used by the Swift Float export bridge; small buffers remain serial. This is the dedicated input to Apple's HEIF10 writer, not a conversion from the byte preview. `python tools/verify_linear_export.py` compares it against the original double-precision display reference. The portable backend does not itself encode HEIF or establish the emitted Apple bitstream's bit depth.


## FFCS exact stages and strip processing

`ffcs.cpp` / `ffcs_c.h` implement FFCS 0.2 native tables across five supplied families (50 assets, 20 named looks, family-specific availability). Neutral default postprocessing bypasses Lab/UCS exactly. Explicit analytic overlay retains source coefficients and Gaussian radius; spatial gates never activate a zero coefficient. Dedicated family tables and declared GFX100 fallback match the reference resolver; absent native tables fail closed. See [source and validation](../docs/FFCS.md).

Full/reference, optimized and strip APIs share the same math, global grain coordinates and Gaussian summation order. `ffcs_required_halo` determines strip input and row-ring extent; native defaults have no spatial halo. The app uses 64 output rows and one worker; C ABI permits 1–4 workers. Full-source effects precede linear-light downsizing. Strict flags, bounded inflate and complete zlib-stream checks reject corrupt assets. These bounds do not establish total Apple RSS or device speed.

The 2026-10-18 strict optimization caches exact Double normalization of every
UInt16 code (512 KiB/context) and uses synchronous GCD for Apple calls with more
than one worker. Swift still selects one FFCS worker. Same-input full HEIF
measurements and rejected GPU/Core ML candidates are documented in the
[current performance report](../docs/COLOR_PERFORMANCE_20261018.md).

## Prepared X2D II HDR stages

The Apple app's revision-12 working-domain bridge is separate from the prepared
X2D APIs below. `hncs_process_apple_hdr_work_float` restores source magnitude into
encoded working RGB before a frame-wide packing/spatial pass;
`hncs_finish_apple_hdr_work_linear` returns signed extended-linear-sRGB without
SDR gamut clipping. Old APIs retain their existing contracts. These new paths
and tests have been written but not built or executed. See the
[revision-12 contract](../docs/HNCS_REVISION12_20261019.md).

`hncs_clone_with_native_gain` configures the ordinary color kernel's native
processing scale without multiplying input pixels again. HDR uses a separate
sequence: `hncs_render_x2d_hdr_color`, `hncs_render_x2d_hdr_post`,
`hncs_apply_x2d_hdr_gradation`, then `hncs_render_x2d_hdr_sharpness`.
The last two support Standard/Nature factory settings and full-resolution
pixels. Their RGB16 values are native HDR working codes, not display-linear
sRGB. The caller still needs the appropriate HDR output ICC transform.

The HDR film/highlight/gamma/sharpness equations and original finite gradation
tables have same-input native comparisons. RAW preparation remains separate;
these APIs do not add a proprietary RAW decoder to the Apple app. Exact scope,
buffer contracts, reproducible probes and native goldens are in
[the X2D report](../docs/X2D_COLOR_PIPELINE_20261018.md).

## Delivery boundary

Portable kernels emit preview bytes or display-linear floats, never HEIF/JPEG files. Photos/Files save the Apple-encoded original HEIF. The separate share provider may lazily decode that finalized HEIF into a same-size compatibility JPEG; it does not call an approximate color kernel or rerender preview data. No JPEG export setting exists.

Exact Float parallel benchmark, regression and failure contracts: [EXACT_FLOAT_PARALLEL](../docs/EXACT_FLOAT_PARALLEL.md). Apple acceleration constraints: [precision research](../docs/apple_precision_acceleration.md).

## HNCS render revision8

`hncs_create_preset` is additive: old constructors retain their exact original output. It selects real generated post-curves/film families, complete configured target-WB ratios through a declared synthetic source bridge, and exposes Float32 work/finish hooks. Frame-aware `hncs_apply_spatial_preset_file` implements the supplied portable grain/USM model with global statistics and canonical top-left row order. This is not proprietary Phocus spatial equivalence.

Build all three HNCS translation units: `hncs.cpp`, `hncs_spatial.cpp`, `hncs_numpy_rng.cpp`. Numerical code uses C++17 with strict FP; the current file backend additionally requires POSIX and the RNG uses Clang/GCC 128-bit integers. Apple/Linux are intended targets; native MSVC support is not established. Both spatial APIs use temporary-file scratch, even when caller input is an in-memory buffer. Scratch ≤16B/pixel, explicit extra processing RAM <4MiB, excluding caller/source/output buffers and OS cache. Preserve the embedded NumPy/SciPy/PCG license notices.

Reproduction: `python core/generate_preset_assets.py`; `python tools/generate_hncs_spatial_assets.py --help`; `python tools/verify_hncs_revision8.py`; `python tools/test_hncs_spatial.py --reference reference --large`; `python tools/test_hncs_numpy_rng.py`. Details and actual versioned evidence: [revision8](../docs/HNCS_REVISION8.md).

## Independent effect switches

FFCS `ffcs_create_options` adds immutable grain/sharpen booleans (strict0/1). Old construction keeps both gates on but now uses the corrected 0.2 neutral default; source-revision changes intentionally alter prior rendered pixels. Full/reference/optimized/strip routes gate only existing stages; color-only ignores both. There is no FFCS crop stage. HNCS uses its existing frame-aware grain/USM flags; extra crop is resolved in the source-image recipe before processing. The earlier FFCS switch audit is historical 0.1 evidence; current 0.2 audits are listed in TEST_STATUS. HNCS switch evidence remains applicable. See [switch contract](../docs/EFFECT_TOGGLES.md).
