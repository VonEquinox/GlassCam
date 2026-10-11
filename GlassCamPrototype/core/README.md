# Portable HNCS + FFCS backends

Standard C++17, C ABI, no runtime third-party dependencies. HNCS and FFCS are independent engines; neither is a substitute for measured iPhone source calibration. Swift only owns UI,
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
`lstar`, and `standard` or `reproduction`. The app intentionally selects legacy,
standard, V1 gamma. Reproduction selects its original pure curve.

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

`hncs_process_linear_rgba` emits packed Float32 display-linear sRGB RGBA (alpha 1) after the unchanged UInt16 HNCS core and display matrices, before either 8-bit OETF encoder. It guards RGBA float byte-size overflow and rejects nonfinite source data. This is the dedicated input to Apple's HEIF10 writer, not a conversion from the byte preview. `python tools/verify_linear_export.py` compares it against the original double-precision display reference. The portable backend does not itself encode HEIF or establish the emitted Apple bitstream's bit depth.


## FFCS exact stages and strip processing

`ffcs.cpp` / `ffcs_c.h` implement the 19 actual XH2S reference assets. The linear-sRGB input branch retains matrix, original 80³ LUT channel/axis conventions, Lab/OKLab, tone, coordinate-seeded grain and neighborhood sharpening. Missing or corrupt resources fail explicitly; REALA ACE is not invented. See [FFCS asset preparation and stage evidence](../docs/FFCS.md).

The reference full-frame route remains an oracle. The exact optimized route uses three RGB-double rows per worker, with 1–4 workers supported and one used by the app pending device profiling. The full-source strip API receives global dimensions/row coordinates and sharpening halo; it does not restart grain at each strip. The Apple caller uses 64 output rows at a time, writes a disk-backed Float raster, then downsizes in linear light only after exact source-resolution processing. Threading or bounded scratch does not itself establish an iPhone speedup or bounded total RSS.

[Stage evidence](../validation/ffcs_cpp_report.json) and [strip evidence](../validation/ffcs_strips.json) cover reference parity; [strip sanitizer results](../validation/ffcs_strip_sanitizer.txt) cover the tested C ABI calls. Apple compile/runtime, Core Image strip orientation, HEIF bitstream and real-device memory/thermal behavior remain untested.

## Delivery boundary

Portable kernels emit preview bytes or display-linear floats, never HEIF/JPEG files. Photos/Files save the Apple-encoded original HEIF. The separate share provider may lazily decode that finalized HEIF into a same-size compatibility JPEG; it does not call an approximate color kernel or rerender preview data. No JPEG export setting exists.
