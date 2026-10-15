# Native camera capture contract

Release builds have passed with Xcode 27.0. On 2026-10-15, preview negotiation and visible main-camera preview were checked on an iPhone 18 Pro Max running iOS 27.0.1. The production controller also completed the main-camera handoff with an 8064×6048 Apple ProRAW buffer and nonempty DNG file representation. A subsequent user shutter in the full app delivered the same dimensions, retained the source and returned to the editor. Saved/exported file validation, optical alignment, other lens combinations and preview performance still require the device validation below. Source-contract tests do not establish those results.

## Physical cameras and fail-closed behavior

- Ultra wide: one physical ultra-wide camera, no wider camera exists in this design; peripheral area stays black.
- Main: physical wide center plus physical ultra-wide live peripheral preview, in one `AVCaptureMultiCamSession`.
- Telephoto: physical telephoto center plus physical wide live peripheral preview, in one `AVCaptureMultiCamSession`.
- A missing physical lens, unsupported simultaneous device set/format, excessive hardware/pressure cost, or unavailable Apple ProRAW output is an explicit error. It does not synthesize a wider image, crop another camera to fake telephoto, switch to Bayer RAW/HEIF, or silently reduce photo resolution.
- Main/tele MultiCam is now a video-only preview graph. The user approved an explicit frozen-preview handoff to a separate ordinary `.photo` session for the same physical lens. ProRAW capability and highest still dimensions are checked in that single-camera graph, not inferred from MultiCam support. See [handoff contract](CAPTURE_SESSION_HANDOFF.md).

## Framing and preview

Each scaled video-data output has an explicit connection to its own physical video input. Its delegate delivers frames to its own sample-buffer display layer. The MultiCam preview has no PhotoOutput. During capture, a separate ordinary session connects PhotoOutput only to the selected center lens. There is no peripheral photo output and no peripheral data enters the saved photograph. Each output discards late frames. The app retains at most one pending sample/main-queue delivery per physical lens; it does not accumulate a frame history. Display-immediately sample attachments avoid playback-timebase delays, and renderer backpressure discards frames rather than building a backlog.

Pixel-format negotiation runs after the graph connections are committed. The system preview accepts supported 8-bit or 10-bit bi-planar YCbCr420 buffers, with an exact format/dimension check on delivered frames. The tested main-camera graph requires `x420` for its center output and uses `420f` for its wider output. The experimental color overlay still requires its separately validated 8-bit NV12 source and falls back to system preview for 10-bit input.

Quit Device Hub screen interaction before testing the physical camera. Apple documents that physical-device interaction prevents camera/microphone access and can produce empty video even in the system Camera app. See [Device Hub camera access conflicts](https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-device-hub). During this test, quitting Device Hub restored visible preview on the phone, as confirmed by the user.

Digital zoom and connection crop are 1; video stabilization and optional content-aware still distortion correction are disabled. The selected center format must have the same aspect ratio as its maximum supported still dimensions. Center layout uses aspect fit and receives the actual oriented photo aspect ratio. Interface orientation updates apply on the camera serial queue. During a capture transaction the shutter orientation is fixed; a newer orientation is deferred until preview restoration. DNG orientation is subsequently interpreted by the existing `ImagePipeline` RAW decoder.

These are necessary framing controls, **not proof of pixel-exact preview-to-ProRAW alignment**. Apple computational RAW processing and optical correction must be checked on device against edge targets in every orientation/lens. The two physical viewpoints have parallax and may differ in exposure, distortion and timing. Wider peripheral imagery is a separately identified live view, not a calibrated seamless continuation. `videoFieldOfView` is reported in the sensor coordinate system, not as calibrated extrinsics.

The default preview is system video; the optional experimental GPU color-only overlay is described below and is hidden during the frozen capture handoff. HNCS/FFCS processes the captured DNG through the existing image pipeline after capture. The editor preview stays bounded independently of source capture. Processed output targets are separate per-lens choices; the export pipeline must re-read retained original DNG data and render to the snapshotted target, never upscale its editor preview.

## Quality policy

The controller publishes actual configured source dimensions, physical camera unique ID, actual center/peripheral preview rasters, and supported processed-output options. Output 12/24/48 MP means a **downsample target**, not a native RAW request. A 48 MP source can offer 12/24/48 processed outputs; a 12 MP source offers only 12. The same nominal source tier preserves native dimensions (for example 4032×3024 is nominal 12 MP); smaller tiers round down to integer aspect-ratio units within their pixel budget. No crop or interpolation is used to reach a larger output tier.

Center and peripheral preview long-edge limits remain independent (UI defaults1920/960). They select video buffers, never the captured RAW resolution. Single-camera `.photo` probing determines the highest supported ProRAW source and the processed-output menu before the preview graph is built. A stored per-lens target must match an available option exactly; a missing48MP choice cannot silently become12MP.

For main/tele, shutter freezes the last displayed real video layers, stops and tears down MultiCam, builds the ordinary `.photo` capture graph, and revalidates lens identity, framing and ProRAW settings. There is no concurrent camera ownership. Ultra-wide already uses a single-camera `.photo` graph and does not need this transition. A higher-resolution setting is only a request: actual returned Apple RAW type and dimensions must match or the photo is rejected. Native24MP processed fusion is not treated as a24MP ProRAW source.

On the tested iOS 27.0.1 device, `captureReadiness == .ready` immediately after building the photo graph still allowed a 48MP request to resolve to 12MP. The photo graph therefore receives a minimum two-second settling period within the existing eight-second preparation deadline. Request cancellation and graph disposal revoke that wait, and actual RAW dimensions remain mandatory. The deprecated still-stabilization setter is omitted because setting it to false changes quality prioritization to speed; captures retain `.quality`.

The capture result and restored preview are independent outcomes. A completed, validated DNG remains deliverable even if preview restoration fails. Request/session identities exclude stale callbacks before any restoration work. Stop/background/interruption cancels unfinished work and prevents an old transaction rebuilding over a newer session. Reconfiguration, capture and restoration are serialized; repeated shutters and configuration changes are blocked. A frozen indicator remains visible while the original video layers are retained, with no opaque error card covering them.

The editor presents the camera using one identifiable session item. The presentation closure takes its immutable admission ticket from that item, so the first opening cannot capture an older ticket from separate Boolean/UUID state. Late callbacks only dismiss a matching presentation. A rejected shutter reservation displays an error instead of silently returning.

Source/preview orientation and framing are checked again during the transition. These checks do not establish optical alignment; true video-to-ProRAW crop, correction and edge correspondence require device tests. See [detailed handoff requirements and limits](CAPTURE_SESSION_HANDOFF.md).

## Device release checklist

1. Build Debug and Release using Xcode with iOS 17+ SDK, enable Camera privacy string, and verify permission denied/revoked/allowed states. Simulator is not camera validation.
2. Test supported and unsupported physical lens sets on multiple iPhone Pro generations. Record exact hardware, iOS, active format, `supportedMaxPhotoDimensions`, final ProRAW support, hardware cost and pressure cost.
3. Record freeze, stop, single-session start, capture and preview-restore timing; force restoration failure and verify the successful DNG is retained. In every supported mode, cover each lens separately and verify center/peripheral feed provenance. Cover wider lens while capturing and confirm saved DNG is unaffected.
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
- [Photo quality prioritization](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxphotoqualityprioritization): still-session quality resources are configured explicitly.
- [RAW pixel buffer](https://developer.apple.com/documentation/avfoundation/avcapturephoto/pixelbuffer) and [resolved settings](https://developer.apple.com/documentation/avfoundation/avcaptureresolvedphotosettings): verify delivered photo data.

- [Implement high resolution photo capture (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/304/): photo preset, supported dimensions, and requested-versus-actual resolution.

- [Video-data output settings](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/videosettings): iOS16+ explicit pixel-buffer dimensions, exact aspect/orientation rules and size limits.
- [Automatic output buffer sizing](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/automaticallyconfiguresoutputbufferdimensions): disable automatic sizing before manual preview configuration.
- [Sample display attachments](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/enqueue%28_%3A%29): DisplayImmediately must be a sample attachment.
- [AVSampleBufferVideoRenderer](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer): iOS17 renderer, readiness and flush behavior.

## Peripheral geometry implementation

The wider source is now positioned using a first-order pinhole FOV ratio, tan(widerFOV/2)/tan(centerFOV/2), keeping its real oriented aspect. It is not stretched to fill the screen. Main/tele shutter remains disabled if that real extent cannot cover the requested window; only ultra-wide accepts black margins. This is approximate center-aligned geometry, not extrinsic calibration, depth-aware stitching or removal of parallax. Native glass stays outside the photo rectangle. Actual photo/preview edge correspondence is still a device release gate.

## 实时视频像素格式

在提交连接后查询每路实际可用格式，依次选择8位NV12（420f/420v）或10位双平面YCbCr（xf20/x420）；每路首帧验证CVPixelBuffer实际OSType和尺寸。2026-10-15真机主摄使用x420、外围使用420f，本机取景已确认。该协商仅覆盖系统预览；实验实时色彩仍只准入8位NV12，10位输入回退到系统预览。预览位深不代表最终效果或导出精度已经过真机验收。


## Experimental center color preview

A default-off switch adds a color-only GPU proxy over the unchanged system center layer. The wider peripheral layer stays unprocessed. Only measured EV0 recipes are admitted (HNCS5500/6500K, FFCS PROVIA/ACROS); unsupported settings retain system preview with a reason. One GPU job plus one replaceable latest source frame bounds retention. Session/recipe changes, stale input, off-window state and GPU failure hide the overlay. This does not alter capture configuration or final-photo processing. See [implementation and untested device gates](LIVE_COLOR_PROXY.md).

## Plan A native-clear composition

The selected photo rectangle is now the maximal aspect-fit rectangle in the full window; control bands no longer reduce it. Glass.clear panes are clipped to the natural window-minus-photo regions. Real photo-only controls follow the reference composition; insufficient margins use a separate plain control panel without changing photo geometry. Grid/thumbnail/settings are functional, flash-off is status only, and diagnostic text lives in details. No edge-copy, custom seam shader, extra blur or image elongation is part of A. See [scope and visual acceptance](CLEAR_GLASS_UI.md).

## revision8方形预设与捕获配方

Square Crop把最终中央边界改为最大等比方形，底层完整sensor sourcePhoto仍保持同一像素比例，外围FOV按未裁切sensor尺寸映射；没有拉伸或玻璃覆盖成片。实际ProRAW仍保留完整捕获源，后处理按参考中心裁切；HEIF的方形实际像素数低于完整4:3档位。快门冻结完整处理配方，迟到成功照片与新任务隔离，详见[捕获交付](CAPTURE_SESSION_HANDOFF.md)。
