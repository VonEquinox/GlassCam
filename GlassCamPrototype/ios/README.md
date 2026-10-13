# GlassCam native iOS prototype

SwiftUI UI, Apple decoding/capture/encoding, and independent standard C++17 HNCS / FFCS engines. No package-manager or project-generator dependency.

## Build status and setup

**Not compiled or run with Apple SDKs in this cloud environment.** Portable numerical and source-contract tests do not establish a working iOS build, camera configuration or HEIF file.

1. Open `GlassCam.xcodeproj` in Xcode 16 or later. Keep `../core`, `../reference_ffcs/source.zip` and `../tools` in the supplied layout.
2. The first build phase verifies the bundled archive and extracts 19 original FFCS assets offline. Missing/corrupt assets fail the build; there is no approximate substitute.
3. Select shared scheme `GlassCam`, iOS 17+ simulator. For hardware, set your development team and a unique bundle identifier.
4. Native SwiftUI `glassEffect` requires Xcode 26+ and iOS 26+. The Plan A camera scene uses Glass.clear on iOS26; older camera configurations use a plain transparent perimeter, not imitation frosted glass. Existing editor compatibility styling is separate.

```sh
xcodebuild -project GlassCam.xcodeproj -scheme GlassCam \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## Import, effects and full-source output

PhotosPicker / Files accepts JPEG, PNG, HEIC and supported DNG. The complete input is retained in an owned, protected temporary file for this editing session. Default import preview is capped at a 2048px long edge: ImageIO thumbnails for rendered inputs, requested RAW scale for DNG. Embedded profiles and orientation feed Apple conversion to extended linear sRGB. DNG support and all Apple color/orientation behavior need device validation. ProRAW is not unprocessed CFA, and the HNCS virtual-native source bridge is not iPhone calibration.

Select HNCS or one of 19 actual FFCS XH2S looks; the engines are not chained. Exposure is −2…+2 EV. HNCS factory CCT 2000…10000K selects profile interpolation, not measured scene white balance. FFCS does not use this CCT. Comparison shows processed left and original right. Effect comparison now uses exact Float32 outputs and a single Metal RGBA16Float SDR drawable, without UIImage/UInt8 intermediates. The legacy8-bit fast API remains available for diagnostics, not the current editor preview. See [high-precision preview](../docs/HIGH_PRECISION_PREVIEW.md).

Export reopens the full source, processes exact color/spatial stages before downsizing, and uses 64-row output strips with FFCS halo/global grain coordinates. A disk-backed RGBAf raster feeds linear-light Lanczos when a smaller output is requested. Dedicated `writeHEIF10Representation` requests 10-bit SDR sRGB: no UInt8 preview input, HDR/gain map, or 8-bit fallback. Dimension/component-depth metadata checks are implemented, but actual HEVC coded depth still needs independent inspection. Source metadata including location is omitted; transparency flattens onto black.

Only application-owned processing scratch is bounded. Full-source file size, Apple decoder/encoder surfaces, mmap resident pages and disk intermediate storage remain significant; a 48.8MP Float RGBA raster is about 781MB. The preview cap does not bound total RAW decode memory. See [full-source design](../docs/FULL_RESOLUTION_EXPORT.md).

## Save original HEIF and share compatibly

- Save HEIF to Photos requests add-only permission and creates a photo resource directly from the original HEIF. No compatibility conversion participates.
- Save HEIF to Files uses an exporting document picker to copy that same original file.
- Share uses one NSItemProvider with HEIC file/data representations registered before JPEG. The JPEG is generated only on request, from the finalized HEIF, retaining dimensions and normalizing orientation into conventional 8-bit SDR sRGB. It never uses the preview or rerenders an effect. Successful conversion is cached for subsequent loads.
- There is no JPEG or PNG export option. Standard Save to Camera Roll is excluded from the share sheet; use the explicit HEIF save control.
- Receiving extensions choose the representation they request. Registration priority does not prove they select HEIC or that WeChat accepts either route. Some recipients may re-encode independently.
- Shared ownership keeps originals/compatibility files alive through picker/provider callbacks. Sheet dismissal alone does not delete a file still in use. Partial or failed compatibility output is not published; temporary owners clean up on release. A crash can leave OS-managed temporary data.

No automatic upload or background network work is implemented. Photos authorization and the receiving app's behavior remain platform-dependent and unverified here.

## Task state, errors and cancellation

Import transfer/decode/effect/export run away from the UI thread. Settings lock during operations; latest-operation tokens reject stale results. Effect failure retains the decoded source for Retry. A changed or failed, unrendered recipe disables Save/share until its preview succeeds, so an old result cannot be delivered as the pending settings.

The actual worker and an explicit locked cancellation token carry cancellation across the serial decode queue. Cancellation is checked between strips and before/after codecs. Synchronous Apple calls cannot be interrupted mid-call; busy stays set until they return, and canceled work must not publish an image or start saving. Photos writes cannot be canceled after their transaction is submitted. Files picker cancellation and share-provider Progress cancellation are separate delivery boundaries.

HNCS preview supports up to four bounded workers, reduced under low-power/thermal policy. HNCS Float export now uses the same bounded worker policy with bit-exact per-pixel math and a serial oracle; FFCS app processing currently uses one worker. These are implementation choices, not measured iPhone energy/performance guarantees.

## Native camera and per-lens settings

The separately opened camera screen requests camera access on use. Physical center and wider peripheral video feeds extend across the window; the center photo rectangle is free of glass. The perimeter never enters PhotoOutput. Main/tele require an actual supported wider simultaneous source; ultra-wide permits black perimeter. Near/far objects, parallax, distortion and timing mean the FOV mapping is approximate, not a calibrated seamless continuation. Coverage is gated; optical edge alignment still needs physical targets.

Center/peripheral preview limits are independent (defaults 1920/960). Scaled video outputs do not force full-resolution preview buffers or silently lower the selected native still source. Per-physical-camera settings persist only supported 12/24/48MP processed output targets; a smaller target is produced after full-source effects, never by upscaling a smaller source.

Main/tele MultiCam is video-only. At shutter, the UI labels and retains frozen preview, stops the MultiCam graph, then rebuilds an ordinary single-camera `.photo` graph for the same physical lens and highest supported ProRAW source. Actual returned RAW dimensions/type are validated; no silent12MP fallback. Preview is restored afterward, but restoration failure never discards an already successful photo. Single ultra-wide `.photo` remains direct. Per-lens output settings are preserved with exact supported-tier selection. Missing capabilities fail explicitly. See [handoff contract](../docs/CAPTURE_SESSION_HANDOFF.md).

Live video is the system preview, not live HNCS/FFCS; captured ProRAW runs through the effects pipeline afterward.

## First Apple-platform acceptance checklist

1. Build Debug and Release; test iOS 26 native glass and older material fallback. Check iPad, VoiceOver, dark mode and permission-denied paths.
2. Import oriented landscape/portrait JPEG, wide-gamut HEIC, PNG and supported/corrupt DNG. Verify profile conversion, EXIF/RAW/bitmap row orientation and exact before/after alignment. Run `tests/apple_ci_strip_roundtrip.swift` on Apple to check strip row order.
3. Compare both endpoints, adjust/retry/reset effects, trigger render failure and cancel just before completion. Pending settings must block Save/share; decoded source remains retryable. Rapid transfers must not commit stale images.
4. Export full source and smaller per-lens targets with both engines. Check dimensions, aspect/no upscale, no stripe seams, deterministic grain/sharpen and preview-to-final appearance; allow expected scale/byte-quantization differences.
5. Inspect HEVC coded depth and HEIF primary-image SDR/sRGB metadata with a HEIF-aware inspector. A `.heic` name or decoded 16-bit buffer is not proof. Verify no HDR gain map, smooth-gradient precision and explicit encoder failures.
6. Save separately to Photos and Files; retrieve originals and verify format, dimensions, metadata and unchanged file bytes where the API exposes originals. Test denied add-only access and picker cancellation. Verify JPEG never enters these dedicated saves.
7. Test AirDrop and exact WeChat/iOS/device versions with ordinary image and file/original flows. Record which provider type is requested, whether original HEIC or compatibility JPEG is sent, received dimensions/depth/tags and ability to view. Test receivers that reject HEIC, repeated file/data callbacks, provider cancellation and dismissal while codec work is in flight. No compatibility claim before this test.
8. Cancel import/effect/export during slow RAW decode, each processing boundary and encoding. Busy must persist until noncancelable work finishes; no overlapping export or canceled delivery. Photos transaction submission is the point beyond which cancellation cannot undo a save. Check temporary-file lifetime/cleanup and disk-full failure.
9. On each lens/preview/output combination, record actual formats, ProRAW support and native/output sizes; test wider-feed coverage, startup readiness, rapid changes, rotation, interruptions, pressure and Retry. Compare preview edge targets to saved DNG framing and verify perimeter exclusion. Do not accept a 48MP marketing specification as successful capture evidence.
10. Profile decode, core, resize, encode and delivery separately: large-image peak RSS/disk, thermal steady state, p50/p95 latency and energy. Cloud C++ preview timings are not phone/export results.

## Apple API references

- [CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter)
- [Dedicated HEIF10 writer](https://developer.apple.com/documentation/coreimage/cicontext/writeheif10representation(of:to:colorspace:options:))
- [Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Item-provider file representations](https://developer.apple.com/documentation/foundation/nsitemprovider/registerfilerepresentation(fortypeidentifier:fileoptions:visibility:loadhandler:))
- [Activity item-provider configuration](https://developer.apple.com/documentation/uikit/uiactivityitemsconfiguration/init(itemproviders:))

## Experimental color-only live preview

Default off. Center-only 65³ shaped GPU cube; full-photo C++ processing and 10-bit HEIF remain independent. Currently admitted: EV 0, HNCS 5500/6500 K or FFCS PROVIA/ACROS. Other recipes use the unchanged system layer with an explicit status; peripheral video remains system color. Source is still 8-bit NV12, processing/display is Float/RGBA16Float SDR. See [scope and measured approximation](../docs/LIVE_COLOR_PROXY.md). Device acceptance must cover source-age timeout, unavailable drawable, off-window/background, orientation, rapid look/lens changes, cancellation and GPU failure. No device FPS/energy result has been measured.

## Plan A reference camera UI

Native clear glass is confined to the natural area outside the maximal full-window photo rectangle. No control-band reservation, center crop/warp or app-added blur/seam effect. Settings retain lens output, HNCS/FFCS, EV/Factory CCT, preview limits and diagnostics; the real Float thumbnail returns to the editor/import flow. Compact windows use a separate plain control panel. This is source implementation only, not a verified visual replica; see [Plan A](../docs/CLEAR_GLASS_UI.md).

## HNCS revision8设备验收增项

- 检查真实preset/film/space/intent与tone/portable grain/USM控件、重启配方持久化和跨相机/编辑器同步。Standard按上游CLI绕过空间预设；其他预设默认sharpness开与CLI一致。
- 虚拟capture CCT与工厂CCT、完整目标WB明确区分，不标称测量的相机白平衡。
- Square Crop竖横屏、奇数源尺寸、中央边界、比较两侧、真实HEIF像素尺寸必须一致；玻璃仅在最终照片外。
- HNCS工作RGB磁盘top-left行序、全图grain/USM和RGBAf还原必须用真实Apple CI诊断；空间导出取消、磁盘不足和后台时的FileProtection行为均待实测。
- 核验快门配方快照、关闭后晚到照片与新导入/新相机/导出并发，成功DNG不得配错方或抢占新任务。
- 新预设没有实时cube误差批准，必须系统取景回退；Standard5500/6500原旧配方单独保留。

C++/Python黄金及源码模型测试通过不意味着以上Apple SDK/设备项目已执行。

## 三个独立开关验收

编辑器和相机共用颗粒、锐化、预设额外裁切三个设置；默认true，切换preset/引擎与Reset均保留用户值。确认旧HNCS显式false与旧FFCS默认全开的迁移；关闭Square Crop后中心边界、比较与HEIF恢复源比例。无对应效果时开关可设置未来偏好，但不添加新处理。切换期间拍摄/关闭/晚到成功必须保留快门三项值。App recipe JSON已包含三项；未新增HEIF内嵌Exif配方。Apple编译与实际操作仍未执行。
