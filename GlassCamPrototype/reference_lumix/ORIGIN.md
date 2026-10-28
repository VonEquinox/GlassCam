# LUMIX Photo Style reference

Source: the user-supplied `LumixAnalyze` directory, SILKYPIX Developer Studio 8 SE **8.0.31.1**.

Pinned framework: `SILKYPIX8`, 32,343,344 bytes,
SHA-256 `63738fb40fc09a340bceaae351fc41a699601c50d22a9b4a990bd34ed22b826b`.
原始报告和复核保存在本地 `GlassCam-research` 仓库的提交 `799f5a6a560a7be4c3a520b0f5359a9e1758a53b`，路径为 `docs/reports/lumix/ANALYSIS.md` 和 `docs/reports/lumix/ANALYSIS_REVIEW.md`。提取脚本位于同一提交的 `tools/reverse-engineering/`，原始调查证据位于 `evidence/`。

`source.zip` and `pipeline.zip` are self-contained runtime data archives. Their hashes are in `SHA256SUMS`;
its manifest records every original `.s3d` hash, decoded-grid hash and independent native-vector hash.
No source executable, framework or Rosetta dependency is shipped in GlassCam.

The portable runtime contains the **DC-S1M2 SDR Photo Style 3D-LUT VE branch**, adapted to iPhone linear-sRGB input. It is not a complete SILKYPIX/RW2 implementation or a Panasonic sensor profile. `source.zip` preserves the 16 revision-1 cubes; `pipeline.zip` adds all 16 paired cubes and the original contrast, saturation, monochrome, low-ISO and temperature registers.

## Additional binary evidence

- `IslZTiffExifPanasonic::GetCameraID` at `0x9d0638` identifies `DC-S1M2` as **106**.
- Calling `Get3DLUTFileName` at `0x5b48c0` for camera 106 selects the **L008** group. The report's group-to-camera mapping was previously unresolved.
- The initialized `s_PanaPhotoStyleEnumTable` at `0x154a220` contains **25 positive style IDs**, not only the 19 identified in the report. Availability still depends on camera ID. The supported SDR subset is recorded in the archive manifest.
- Original `IslZColor3DLut::ReadMappingHeaderV2` / `ReadMappingData` decode the Huffman resources at extraction time. No grid reduction or fitting is applied.
- `IslZColor3DLut::GetpLutPt(r,g,b)` is B-fast with BGR samples. Extraction transposes this losslessly into **R-fast RGB**. The independent native oracle reconstructs the separate `Pana_LUT` layout and calls the original `GetValue` at `0x82bfb8` with BGR input/output.
- SDR `Set3DLUT` uses a **129-node grid, increment 32, white 4095**. The last node is a guard node; coordinates are divided by 32 rather than stretched over 128/4095.
- Native interpolation uses eight corners and `floor(value + 0.5)`, then unsigned-16 clipping. These operations are preserved by the portable core.
- Original `Set3DLUT` at `0x5babf8` independently confirms both table endpoints and integer node mixing. `MakeUpVEParam` supplies a four-point temperature selector; 256 selects the second mapped file, 512 selects the first.
- Original `IslVEISFilter3DLUT::FilteringLine` at `0x82d74e` is the independent complete RGB48 oracle. The port includes low-ISO luminance curves, source-white normalization, the native alternate input transform, Y/C saturation and signed monochrome chroma, contrast curves, truncation and writeback. Native and portable outputs match exactly for 5,506,816 RGB48 pixels.

## Reproduction

Ordinary builds only need the archive:

```sh
python3 GlassCamPrototype/tools/prepare_lumix_resources.py
python3 GlassCamPrototype/tools/verify_lumix.py
python3 GlassCamPrototype/tools/test_lumix_images.py
```

Re-extracting requires the supplied source folder and macOS with Rosetta:

```sh
python3 GlassCamPrototype/tools/extract_lumix_assets.py --analysis-root /path/to/LumixAnalyze
python3 GlassCamPrototype/tools/extract_lumix_pipeline.py --analysis-root /path/to/LumixAnalyze
uv run --python 3.12 --with numpy python GlassCamPrototype/tools/verify_lumix_pipeline.py
```

## Adapter boundary

Current camera captures use revision 4's separate bounded float adapter and a
camera-neutral RAW input policy. The original UInt16 oracle is preserved for
native verification and legacy recipes. The iPhone adapter keeps the original
cubes and style registers but omits Panasonic sensor-specific low-ISO
compensation and replaces wraparound with continuous gamut compression.
See [the 2026-10-28 repair](../docs/COLOR_INPUT_REPAIR_20261028.md).

Revision 2 uses Apple scene-linear ProRAW input and retains the source white point. Source ISO and CCT are bound into the durable photo recipe. The full original SDR VE branch runs with a scalar RGB48 white of 65535, using both complete cubes and native registers. Input/output HDR splitting/restoration and final HEIF encoding remain GlassCam policies. The SDR output is decoded with the standard sRGB EOTF into Float32.

Saved revision-1 recipes keep their first native LUT and prior Apple-rendered input. Camera preferences migrate future captures to revision 2.

The source adapter does not recover Panasonic sensor RGB, MakerNotes, CF2/Bayer development, arbitrary legacy VE matrix/axis branches, Panasonic spatial denoise/sharpening, or an arbitrary original CMS/ICC transform. V-Log and HLG-specific tables are excluded because their input/output contract differs. Apple supplies ProRAW decode and detail processing. Numerical VE agreement is not evidence of cross-camera photographic equivalence. See [implementation and validation](../docs/LUMIX_PRORAW_20261026.md).

All data retains its original ownership. This file records provenance and grants no additional rights to the source assets.
