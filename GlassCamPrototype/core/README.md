# Portable HNCS backend

Standard C++17, C ABI, no runtime third-party dependencies. Swift only owns UI,
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
