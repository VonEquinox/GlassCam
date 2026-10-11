# Color-only GPU live preview design

Research design recorded on 2026-10-11. The subsequent opt-in implementation is described in [LIVE_COLOR_PROXY.md](LIVE_COLOR_PROXY.md); this document records the design and validation rationale. Targets the project's iOS 17 minimum. Apple-device build, camera capture, color validation, and timing remain required.

## Recommendation

Start with `AVCaptureVideoDataOutput` → retained `CVPixelBuffer` → `CIImage(cvPixelBuffer:)` → persistent Metal-backed `CIContext` → `CIColorCube` → `MTKView` with `.rgba16Float`. Keep camera-input color management enabled. This avoids CPU RGB readback and hand-written YCbCr decoding. It does not promise that Core Image has no internal intermediate surfaces or that it is one GPU pass.

The GPU path is an approximate color-only viewfinder, not the exact photo pipeline. Exclude grain, blur, sharpening, halation, local/neighbor operations, resampling-dependent effects, and image-wide adaptation. A 3D cube can represent only a fixed pointwise RGB mapping. The retained ProRAW, `ImagePipeline.process`, full-source export, HNCS/FFCS precise engines and ten-bit SDR HEIF remain unchanged.

Direct Metal is a second implementation only if measured device performance or an exact shaper contract warrants it. It provides explicit fused YCbCr conversion + LUT + display rendering, but substantially expands correctness obligations. A useful intermediate choice is Core Image input/color management plus one compiled CI color kernel for a shaper, then CIColorCube. Do not use a private ISP API or assume arbitrary filters can be attached to `AVCaptureVideoPreviewLayer`.

## Numerical gate: do not enable a generic cube by default

The companion CPU evaluation reports these **maximum encoded-channel** errors at fixed EV=0 (legacy HNCS WB=5500 K): uniform-linear 65³ gives HNCS/PROVIA/ACROS approximately 0.090/0.088/0.029; sRGB-shaped 65³ gives 0.0395/0.0155/0.0097. Shaped 33³ gives approximately 0.077/0.035/0.024. Shaped 65³ p95 is 0.000539/0.00311/0.000661. Low p95 does not erase the visible worst-case risk. These are CPU oracle results relayed by the evaluation worker, not Apple GPU validation. This blocks treating plain CIColorCube33, or even shaped65, as fidelity-approved. Keep the candidate behind a development flag until worst cases, acceptable error thresholds, parameter sweep and real-device output are reviewed.

For the evaluated shaped cube, lookup coordinates are **sRGB-encoded linear-sRGB input**, while stored outputs remain **display-linear RGB**. For x in [0,1], q=12.92*x when x≤0.0031308, otherwise q=1.055*x^(1/2.4)−0.055. At node q=i/(N−1), generate the cube from the inverse sRGB curve, then evaluate the full pointwise oracle. This numerical coordinate transform must not be mistaken for changing the CI working/output color space.

The built-in `CILinearToSRGBToneCurve` is a candidate pre-cube shaper: `let coordinates = image.applyingFilter("CILinearToSRGBToneCurve")`, then set that as CIColorCube input, retaining linear working space and linear output. Apple documents this filter's [linear-to-sRGB conversion](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/lineartosrgbtonecurve()). Validate its exact device output against the CPU piecewise formula; a compiled CIColorKernel is the explicit alternative. Do **not** add the inverse curve after the cube: its RGB output is already display-linear. Do not substitute `CIColorCubeWithColorSpace` with an encoded-sRGB space while keeping these linear output values; that changes the interpretation.

Only finite [0,1] inputs at the tested parameter values are currently evaluated. No negative/extended input guarantee, EV/WB sweep guarantee, GPU interpolation parity or performance conclusion follows. Reuse the source/render architecture independently of whichever cube or analytic pointwise implementation eventually passes the fidelity gate.

## Current integration seams

- `CameraController.swift`: already owns one native-YCbCr `AVCaptureVideoDataOutput` per physical lens. It explicitly prefers **8-bit** 420f, then 420v. Preserve independent source raster caps and full-resolution photo checks.
- `CameraFrameDelivery.swift`: currently validates dimensions/format/generation, bounds queued main closures, then enqueues into `AVSampleBufferDisplayLayer`. Replace the displayed layer dependency with a thread-safe latest-frame source. Existing gate drops new frames while an older closure is pending; use replacement semantics for lowest latency.
- `CameraView.swift`: substitute a Metal-backed view in the existing center/peripheral rectangles; keep `CameraFraming` geometry, orientation, physical-camera selection, black ultra-wide periphery and masks unchanged. Two views may share immutable LUT data and a Metal device/context, but each lens needs its own frame slot, source metadata, orientation generation and availability. Never stretch the center feed to manufacture a peripheral image.
- `PrecisionPreview.swift`: reuse its display contract: linear-sRGB interpretation, half-float drawable, explicit SDR clamp, EDR disabled. Do not reuse its CPU `PreviewRaster` construction for live camera frames.

## Bounded frame and GPU ownership

Keep `alwaysDiscardsLateVideoFrames = true` and a serial capture delegate queue. In the delegate, validate and replace one locked `latestFrame` slot, retaining the pixel buffer plus timestamp, source encoding and generation. Return immediately: no CPU processing, waiting for GPU, or per-frame ObservableObject publishes. The prior slot is released immediately when replaced.

On display tick, if a renderer's in-flight slot is available, atomically take the newest frame. Start with one GPU frame in flight per lens plus one replaceable pending frame. Do not acquire a drawable if no new frame exists, unless geometry/look needs redraw. No frame means retain the displayed drawable or intentional black/status, rather than submitting duplicate work continuously.

Commit asynchronously. A completion handler retains the frame owner, cube owner, and, for direct Metal, **both CVMetalTexture wrapper objects** through completion; release the in-flight slot even on GPU error. Holding only `MTLTexture` is insufficient for the Core Video mapping contract. Invalidating a lens increments generation and clears its pending frame; existing GPU work can finish but must not revive the old view or readiness state. LUT generation also uses a revision token to prevent obsolete slider results from replacing newer settings.

Apple recommends brief capture callbacks, describes the one-frame late-drop queue, and documents drop reasons in [TN2445](https://developer.apple.com/library/archive/technotes/tn2445/_index.html).

## First implementation API sketch

All APIs below are available by the project's iOS 17 baseline; no new OS minimum is intended. String-based CIColorCube itself dates to iOS 6. Avoid newly introduced HDR options in this implementation. Compile against the actual Apple SDK before treating snippets as validated source.

```swift
let device = MTLCreateSystemDefaultDevice()!
let commandQueue = device.makeCommandQueue()!
let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let context = CIContext(mtlDevice: device, options: [
    .workingColorSpace: linear,
    .workingFormat: CIFormat.RGBAf.rawValue,
    .cacheIntermediates: false
])
view.colorPixelFormat = .rgba16Float
view.framebufferOnly = false
view.sampleCount = 1
if let layer = view.layer as? CAMetalLayer {
    layer.colorspace = linear
    layer.wantsExtendedDynamicRangeContent = false
}
// Inside serialized rendering; not on the capture queue:
let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
let cube = CIFilter(name: "CIColorCube")!
cube.setValue(image, forKey: kCIInputImageKey)
cube.setValue(lut.dimension, forKey: "inputCubeDimension")
cube.setValue(lut.rgbaFloat32Data, forKey: "inputCubeData")
// Apply validated pre-cube domain mapping before setting inputImage above.
// Apply explicit [0,1] SDR output clamp, alpha=1, geometry and black background.
let output: CIImage = /* complete graph */ image
context.render(output, to: drawable.texture, commandBuffer: commandBuffer,
               bounds: drawableBounds, colorSpace: linear)
commandBuffer.addCompletedHandler { _ in
    withExtendedLifetime(frame) {}
    withExtendedLifetime(lut) {}
    // release in-flight token, report errors, request latest pending frame
}
commandBuffer.present(drawable)
commandBuffer.commit()
```

Reuse context/queue. A mutable filter is renderer-serial or per-frame; never concurrently mutate one shared CIFilter. Do not manufacture a UIImage/CGImage or call `render(toBitmap:)` per frame. Do not label camera YCbCr as linear-sRGB with a CIImage option: working space and source interpretation are different things. The CI image receives the original tagged buffer; context converts it into the cube's working space.

Apple documents [CVPixelBuffer CIImage initializers](https://developer.apple.com/documentation/coreimage/ciimage) and [CIColorCube's working-space semantics](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html#//apple_ref/doc/filter/ci/CIColorCube).

## Color and source contract

Inspect each new encoding/generation's fourcc, dimensions, plane count, clean aperture/pixel aspect, color primaries, transfer, YCbCr matrix and chroma location. Use `CVBufferCopyAttachment` for `kCVImageBufferColorPrimariesKey`, `kCVImageBufferTransferFunctionKey`, `kCVImageBufferYCbCrMatrixKey`, and chroma-location keys; format-description extensions can supplement missing buffer metadata. Cache only by the actual metadata tuple, not resolution. Unknown/conflicting encodings must produce explicit unsupported state rather than assume Rec.709.

Use tagged SDR sRGB/P3 capture as delivered and let CI convert to the common working space. Do not force global sRGB or disable automatic wide color casually: those settings are device/session-wide and can change still-capture behavior. Verify `activeColorSpace`, `isVideoHDREnabled`, and delivered transfer metadata. If unexpected HLG/PQ/log arrives, do not relabel it SDR or merely clamp it before the LUT. Prefer reject/pause that preview with a visible explanation while retaining precise photo configuration. An optional explicitly designed HDR-to-SDR transform is a separate validated source adapter.

If an intentional SDR capture configuration is adopted, set it under `lockForConfiguration()` before starting, with session configuration brackets; manual activeColorSpace requires disabling `automaticallyConfiguresCaptureDeviceForWideColor`. Recheck ProRAW support, still dimensions and exact graph afterward. In HLG, disabling `isVideoHDREnabled` alone does not turn HDR off. [Apple activeColorSpace](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activecolorspace), [wide-color automation](https://developer.apple.com/documentation/avfoundation/avcapturesession/automaticallyconfigurescapturedeviceforwidecolor), [video HDR](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isvideohdrenabled).

## Direct Metal alternative

Request Metal-compatible native buffer storage when supported. Create one cache with `CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)`. Map 8-bit bi-planar luma and CbCr using:

```swift
CVMetalTextureCacheCreateTextureFromImage(
    kCFAllocatorDefault, cache, pixelBuffer, nil, .r8Unorm,
    CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
    CVPixelBufferGetHeightOfPlane(pixelBuffer, 0), 0, &yWrapper)
CVMetalTextureCacheCreateTextureFromImage(
    kCFAllocatorDefault, cache, pixelBuffer, nil, .rg8Unorm,
    CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
    CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1, &uvWrapper)
let yTexture = CVMetalTextureGetTexture(yWrapper!)!
let uvTexture = CVMetalTextureGetTexture(uvWrapper!)!
```

Check every CVReturn and optional. No base-address lock/copy is needed for successful GPU mappings. This mapping does not itself perform YCbCr → RGB or transfer conversion. [Apple texture mapping and lifetime contract](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)).

For normalized 8-bit samples, video range is Y=(255*y−16)/219 and C=(255*c−128)/224; full range is Y=y and C=c−128/255. Apply the attached matrix to obtain nonlinear R'G'B', then decode the actual attached transfer, then convert linear primaries to working linear-sRGB. Do not use one hardcoded BT.709 matrix for every feed or confuse BT.709 and sRGB transfer curves. Chroma reconstruction must honor attached chroma location and correct luma/chroma pixel centers. Handle out-of-range YCbCr values deliberately; premature clamping changes edge/highlight colors. Ten-bit planes have different normalization/storage and must get a separate tested implementation, not reuse these constants.

For cube sampling, upload `MTLTextureDescriptor` with `textureType = .type3D`, dimensions N×N×N, `.rgba16Float` (or verified float32 format/filter support), one mip level, `.shaderRead`. Data is red-fastest. Use linear filtering, normalized coordinates and clamp-to-edge in all dimensions. For normalized LUT-domain coordinate q, sample coordinate is `(q*(N-1)+0.5)/N`; simply sampling q misses exact texel centers/endpoints. Hardware trilinear sampling is not tetrahedral interpolation. Match the CPU oracle to the actual interpolation and precision. A shader `float3` can keep math Float32 while texture values are half; separately test half-LUT quantization.

## LUT contract and caching

- Store immutable Float32 premultiplied RGBA cube data, alpha exactly 1; sample nodes at index/(N−1). The CIColorCube layout has R varying fastest, then G, then B. [Apple cubeData contract](https://developer.apple.com/documentation/coreimage/cicolorcube/cubedata).
- The base renderer's domain is the oracle's declared input linear-sRGB domain, not encoded camera R'G'B'. Do not apply a gamma-encoded photographic LUT to linear values.
- Bake EV and WB only where their position matches the exact color-only oracle. If analytically applied outside the cube, preserve ordering and avoid applying them twice. Camera auto-WB is already in rendered video; a photo RAW WB control may need a calibrated preview approximation and cannot recover RAW camera-space values.
- Out-of-domain policy must be explicit. Baked positive EV can process >1 internally even with [0,1] cube input. But extended-sRGB source values, negative wide-gamut components, or pre-cube EV/WB can still lie outside the cube. Either validate a deliberate clamp for the approximate preview or use an explicit shaper with the identical inverse when generating nodes. Do not claim that a hard clamp preserves highlight rolloff.
- A possible nonnegative highlight shaper is q=log2(1+a*x)/log2(1+a*M), inverse x=(2^(q*log2(1+a*M))−1)/a, for declared a>0,M>0. This alone does not support negative channels; require a signed/domain-offset variant or documented lower clamp. The shaper is a coordinate transform, not an extra aesthetic tone curve. Its parameters/version belong to the cube key. CI requires an actual pre-cube kernel implementing it; plain CIColorCube does not automatically apply it.
- Key: engine/model revision, look/simulation ID, exact EV/WB values or explicit quantization policy, pointwise/spatial-exclusion policy, source-adapter revision, working/output space, domain/shaper version/parameters, N, cube precision/interpolation. Seed belongs only if it affects allowed pointwise output; omitted spatial grain is not seeded into the cube.
- Generate on a utility queue, cancel/supersede old requests, publish immutable newest cube atomically. Slider changes must not launch unlimited cube builds. Use bounded LRU cache. Source matrix/transfer metadata belongs to conversion state; do not rebake identical working-space LUT just because a camera's YUV matrix changes.

## Precision, verification and acceptance

A half-float drawable is a high-precision app rendering surface. It does not establish ten-bit capture, ten-bit physical panel precision, or ten-bit end-to-end compositor behavior. Current capture is eight-bit. Label these separately. Explicit clamp to [0,1] plus `wantsExtendedDynamicRangeContent = false` maintains the intended SDR presentation; [Apple's EDR switch](https://developer.apple.com/documentation/quartzcore/cametallayer/wantsextendeddynamicrangecontent) does not turn a source into SDR.

Before deployment, compile on Apple SDK and test real single/multi-camera devices. Compare identity path against correctly color-managed source for full/video range, matrices, SDR transfers, P3, rotation, aperture and mirroring. Run grayscale near-black/white ramps and saturated colors; test cube corners, nodes and random points against CPU color-only oracle at 17/33/65 sizes, with EV/WB extremes and half-LUT storage separately. Do not approve from mean error alone: record percentiles, max and worst-color examples. Test camera switching/orientation/look churn, pause/resume, disappearing views, unavailable drawable, GPU failures, memory pressure and sustained capture while a precise photo exports.

Measure delivered and rendered FPS, dropped-frame reasons, end-to-end timestamp age, CPU encoding time, GPU duration, peak retained camera buffers, memory and thermal behavior. No timing, FPS or battery promise is justified by LUT size alone. Compare CI versus direct Metal only on matching input/output contracts and the same target devices.
