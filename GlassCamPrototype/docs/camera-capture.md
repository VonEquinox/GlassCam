# Native camera capture contract

This source implementation has **not been compiled with the Apple SDK or run on an iPhone**. Linux source-contract tests cannot establish capture availability, DNG validity, field-of-view alignment, or preview performance. Treat device validation below as a release gate.

## Physical cameras and fail-closed behavior

- Ultra wide: one physical ultra-wide camera, no wider camera exists in this design; peripheral area stays black.
- Main: physical wide center plus physical ultra-wide live peripheral preview, in one `AVCaptureMultiCamSession`.
- Telephoto: physical telephoto center plus physical wide live peripheral preview, in one `AVCaptureMultiCamSession`.
- A missing physical lens, unsupported simultaneous device set/format, excessive hardware/pressure cost, or unavailable Apple ProRAW output is an explicit error. It does not synthesize a wider image, crop another camera to fake telephoto, switch to Bayer RAW/HEIF, or silently reduce photo resolution.
- Device-level MultiCam support does **not** establish that Apple ProRAW works in that final graph. The output is checked after manual connections and again before capture. It is possible that no main/telephoto simultaneous configuration works on a particular device. This implementation does not switch to a single camera behind the user's back.

## Framing and preview

Each scaled video-data output has an explicit connection to its own physical video input. Its delegate delivers frames to its own sample-buffer display layer. Photo output connects only to the center input. There is no peripheral photo output and no peripheral data enters the saved photograph. Each output discards late frames. The app retains at most one pending sample/main-queue delivery per physical lens; it does not accumulate a frame history. Display-immediately sample attachments avoid playback-timebase delays, and renderer backpressure discards frames rather than building a backlog.

Digital zoom and connection crop are 1; video stabilization and optional content-aware still distortion correction are disabled. The selected center format must have the same aspect ratio as its maximum supported still dimensions. Center layout uses aspect fit and receives the actual oriented photo aspect ratio. Interface orientation updates apply to both preview connections and the photo connection on the camera serial queue. DNG orientation is subsequently interpreted by the existing `ImagePipeline` RAW decoder.

These are necessary framing controls, **not proof of pixel-exact preview-to-ProRAW alignment**. Apple computational RAW processing and optical correction must be checked on device against edge targets in every orientation/lens. The two physical viewpoints have parallax and may differ in exposure, distortion and timing. Wider peripheral imagery is a separately identified live view, not a calibrated seamless continuation. `videoFieldOfView` is reported in the sensor coordinate system, not as calibrated extrinsics.

The preview is the system camera preview, not a live HNCS/FFCS render. HNCS/FFCS processes the captured DNG through the existing image pipeline after capture. The editor preview stays bounded independently of source capture. Processed output targets are separate per-lens choices; the export pipeline must re-read retained original DNG data and render to the snapshotted target, never upscale its editor preview.

## Quality policy

The controller publishes actual configured source dimensions, physical camera unique ID, actual center/peripheral preview rasters, and supported processed-output options. Output 12/24/48 MP means a **downsample target**, not a native RAW request. A 48 MP source can offer 12/24/48 processed outputs; a 12 MP source offers only 12. The same nominal source tier preserves native dimensions (for example 4032×3024 is nominal 12 MP); smaller tiers round down to integer aspect-ratio units within their pixel budget. No crop or interpolation is used to reach a larger output tier.

Center and peripheral preview long-edge limits are independent (UI defaults 1920 and 960, accepted range 640–4096). The greatest native source allowed by the combination is prioritized first; among equivalent native-source candidates, the smallest sensor video raster is selected to conserve bandwidth. Independent `AVCaptureVideoDataOutput.videoSettings` width/height requests downscale center and peripheral buffers without lowering that native still source. Automatic output sizing and preview-sized automatic buffers are disabled before setting exact dimensions. The output sizes are even integer multiples of the source aspect ratio and never exceed source video dimensions. Published preview sizes are sensor-oriented scaled buffers; portrait connections swap width/height. Rotation clears old dimension keys, changes connection orientation, and installs the new matching dimensions in one serial configuration transaction. Old delegates are drained during rotation, queued frames are generation/dimension rejected, and display layers flush on format/orientation changes and renderer failure. Startup and each rotation require a correctly sized first frame from every physical feed before enabling the shutter; a five-second readiness timeout stops capture with an explicit error instead of leaving a black preview marked ready.

Single ultra-wide capture uses `.photo`, as Apple documents this preset for 24/48 MP high-resolution delivery. MultiCam remains its required `.inputPriority`; this implementation conservatively limits native MultiCam requests to nominal 12 MP. Native 24 MP deferred processed delivery is not treated as a ProRAW source. The single-camera photo preset may override active format: source format, full-photo aspect and native dimensions are inspected again. A subsequent source-format change rejects setup. A large source raster no longer requires a large preview raster: video-data output scales the delivered buffers separately. High-resolution simultaneous capture and exact device compatibility remain unverified; no 48 MP capability is promised merely because a sensor has 48 million pixels.

Source dimensions come from the final active format, then final PhotoOutput ProRAW support and available Apple RAW pixel formats are gated. The supported output menu is published only after that graph starts. `maxPhotoDimensions` is still a request, not proof of delivered resolution; every capture must pass the actual-dimension check. This is conservative deterministic selection, not exhaustive negotiation of every format pair.
Photo output and each capture request use `.quality` prioritization and the selected `maxPhotoDimensions`. Captured RAW dimensions must equal requested dimensions (allowing orientation). A non-ProRAW pixel buffer, absent DNG, or changed dimensions rejects the capture. ProRAW is selected only using `AVCapturePhotoOutput.isAppleProRAWPixelFormat` over `availableRawPhotoPixelFormatTypes`.

Only one photo request is retained at a time. The completion waits for `didFinishCaptureFor`, not merely photo processing, so later capture errors cannot be lost. Stop cancels the app request. A failed/interrupted session disables shutter; the user taps Retry camera or selects a different lens to rebuild and validate. Serious/critical/shutdown system pressure stops capture instead of degrading quality.

## Device release checklist

1. Build Debug and Release using Xcode with iOS 17+ SDK, enable Camera privacy string, and verify permission denied/revoked/allowed states. Simulator is not camera validation.
2. Test supported and unsupported physical lens sets on multiple iPhone Pro generations. Record exact hardware, iOS, active format, `supportedMaxPhotoDimensions`, final ProRAW support, hardware cost and pressure cost.
3. In every supported mode, cover each lens separately and verify center/peripheral feed provenance. Cover wider lens while capturing and confirm saved DNG is unaffected.
4. Place targets at the center preview's four edges and corners. Capture in portrait, upside-down where enabled, and both landscapes. Decode the DNG and verify full framing, orientation, no mirroring, no unintended crop. Test rotation immediately before and during shutter; any mismatch blocks release.
5. Inspect DNG properties and underlying RAW type; verify actual dimensions and Apple ProRAW metadata. No Bayer/HEIF-only delivery may be counted as success.
6. Request repeated shutters, mode changes, permission transitions, background/foreground, capture interruption, media-services reset, and rotation while configuring. Verify no stale capture, duplicate callback, stuck shutter or unbounded queue growth.
7. Profile preview latency, memory, energy and long-running thermal pressure. Induce serious pressure/interruption: shutter must disable and show an explicit reason. Verify Retry camera on the same lens and explicit lens changes recover.
8. Run captured images through both effect backends and independently encoded 10-bit SDR HEIF; verify photo orientation and no peripheral pixels. Verify each configured processed target, preserved aspect and no upscaling; test saved settings per physical lens and combination. Confirm smaller HEIF targets do not lower native capture dimensions.

## Apple references consulted

- [AVCaptureMultiCamSession](https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession): input-priority graph and capture budgets.
- [supportedMultiCamDeviceSets](https://developer.apple.com/documentation/avfoundation/avcapturedevice/discoverysession/supportedmulticamdevicesets): simultaneous device-set gate.
- [Manual preview connection](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/init%28inputport%3Avideopreviewlayer%3A%29): input-port-specific layer connection.
- [Apple ProRAW capture](https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats) and [AVCapturePhotoOutput](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput): final configuration gate and RAW format selection.
- [Photo quality prioritization](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxphotoqualityprioritization): MultiCam defaults to speed, so quality is set explicitly.
- [RAW pixel buffer](https://developer.apple.com/documentation/avfoundation/avcapturephoto/pixelbuffer) and [resolved settings](https://developer.apple.com/documentation/avfoundation/avcaptureresolvedphotosettings): verify delivered photo data.

- [Implement high resolution photo capture (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/304/): photo preset, supported dimensions, and requested-versus-actual resolution.

- [Video-data output settings](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/videosettings): iOS16+ explicit pixel-buffer dimensions, exact aspect/orientation rules and size limits.
- [Automatic output buffer sizing](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/automaticallyconfiguresoutputbufferdimensions): disable automatic sizing before manual preview configuration.
- [Sample display attachments](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/enqueue%28_%3A%29): DisplayImmediately must be a sample attachment.
- [AVSampleBufferVideoRenderer](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer): iOS17 renderer, readiness and flush behavior.

## Peripheral geometry implementation

The wider source is now positioned using a first-order pinhole FOV ratio, tan(widerFOV/2)/tan(centerFOV/2), keeping its real oriented aspect. It is not stretched to fill the screen. Main/tele shutter remains disabled if that real extent cannot cover the requested window; only ultra-wide accepts black margins. This is approximate center-aligned geometry, not extrinsic calibration, depth-aware stitching or removal of parallax. Native glass stays outside the photo rectangle. Actual photo/preview edge correspondence is still a device release gate.

## 实时视频像素格式

当前选择8bit NV12（420f/420v），每路首帧除尺寸还验证CVPixelBuffer实际OSType，界面显示该格式。独立高精度Float效果预览不能反推实时视频也有10bit源精度。后续10bit视频选择须同时验证activeFormat、输出类型、SDR颜色空间和显示链。
