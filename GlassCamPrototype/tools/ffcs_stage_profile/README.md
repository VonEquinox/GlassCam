# FFCS diagnostic stage profiler

Run from the project root:

    python3 tools/ffcs_stage_profile/run.py

This compiles an independent diagnostic executable including `core/ffcs.cpp` in its own translation unit. It never edits, replaces, or links a changed production library. `run.py` extracts the production `render` function and makes only three attribution changes in a generated local include: split input encoding from 3D LUT sampling, split Lab from UCS, and mark sharpening allocation separately. The production and instrumented versions use identical source math. Extra passes in split attribution can change cache/compiler behavior, so `profile_original` is provided as a cross-check. Every common stage is compared byte-for-byte as double RGB outside the timed region; all final float RGB and RGBA bytes are compared with the unmodified production API.

Inputs: deterministic synthetic linear RGB gradient mixed with deterministic noise, plus exact 0/1 values; EV 0; seed 37; original PROVIA and ACROS XH2S assets. Dimensions: 256×144, 512×288, 1280×720. This is a CPU microbenchmark, not a natural-photo quality dataset, RAW decode, camera pipeline, GPU, thermal, or iPhone test.

One warmup and three timed runs per mode. Wall time uses `steady_clock`; process CPU time uses `std::clock` (all threads). API input/output buffers and LUT context are preallocated outside timings; internal frame/row allocations remain inside. Context loading/decompression, input generation and parity verification are excluded. The baseline is float-linear RGB plus RGBA output, matching the public API. The rgba-only optimized mode intentionally omits the optional float decode/output. Modes are sequential, not randomized; cloud load/frequency can vary. Three runs establish a local p50, not a statistically robust device benchmark. Report raw ranges alongside conclusions.

Outputs are `validation/ffcs_stage_profile/raw.jsonl`, `summary.json`, and the diagnostic generated include/executable. Only the source harness, README, JSON evidence, and analysis document need publication; generated executable/include/console need not be committed. The summary pins the tested production SHA-256 and compiler flags. Standard parity assertions abort on any mismatch.

Production invariants: original BGR LUT axes/channel flag, header matrix, clip positions, look parameters, original stage order, grain XY/width/seed and 3×3 edge-truncated sharpening are retained. Gamma-pre and output-ICC are markers/no-ops on this tested linear-input sRGB path. Their costs should not be counted as absent color work: the actual sRGB encodes/decodes happen inside LUT preparation, Lab, UCS, and output conversion.

## Neutral UCS omission experiment

    python3 tools/ffcs_stage_profile/run_omit_ucs.py

Run separately from the main benchmark. This deliberately changes only `ucs(lab(v,...))` into `lab(v,...)` in a generated diagnostic copy of render. The unmodified full render is retained as the comparison. Measures 512×288 PROVIA/ACROS, one warmup/three samples, same spatial grain/sharpening. Outputs `omit_ucs.jsonl` with encoded/linear errors and changed RGB8 channels. This is approximate even if byte differences are rare; it is not eligible for the strict production path merely because its UCS parameters are mathematically neutral. Its timings exclude API input allocation/output float/RGBA conversion and must not be compared directly with end-to-end API timings.
