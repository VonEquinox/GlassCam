# GlassCam native iOS effect prototype

Native SwiftUI interface, Core Image import adaptation, and independent C++17 HNCS and FFCS numerical backends via a thin Swift/C bridge. No package-manager dependency or generated-project tool is required.

## Build status

**Not compiled or run on an Apple platform in this environment.** The source and Xcode project are provided for local validation. The Linux cloud has no Xcode/iOS SDK; passing C++ numerical checks does not establish an iOS build or visual correctness.

## Open and run

1. On a Mac with Xcode 16 or later, open `GlassCam.xcodeproj`.
2. The first build phase verifies the bundled FFCS archive and extracts the 19 original assets offline. Keep `reference_ffcs/source.zip` and both resource-preparation files under `tools/` intact. Select the shared `GlassCam` scheme and an iOS 17+ simulator.
3. Run. Signing is not required for the simulator. For a real device, choose your development team and a unique bundle identifier under Signing & Capabilities.
4. With Xcode 26+ and iOS 26+, controls use SwiftUI `glassEffect`. Earlier supported SDKs/iOS versions use a translucent material fallback.

Simulator build from this folder:

```sh
xcodebuild -project GlassCam.xcodeproj -scheme GlassCam \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

C++ files are referenced from `../core`; keep the project in the supplied folder layout.

## Current flow

- PhotosPicker or Files import JPEG, PNG, HEIC and supported DNG.
- Rendered images use ImageIO transformed thumbnail decoding with a 2048px maximum, preserving the thumbnail CGImage color space for Core Image conversion to extended linear sRGB. DNG sets Apple `CIRAWFilter.scaleFactor` from `nativeSize` before requesting output and is experimental; support varies by Apple OS/camera decoder. DNG import is not a raw-camera-native calibration path.
- Opaque RGB floats cross the C ABI into the C++ numerical core. All HNCS transform math is in the C++ backend.
- Choose HNCS or FFCS; FFCS offers 19 source-backed XH2S looks and uses a cached immutable context. Its linear input route is independent of HNCS. See [FFCS](../docs/FFCS.md).
- Exposure spans −2 to +2 EV. Factory CCT spans 2000–10000 K. CCT controls profile interpolation, not an accurate estimate of scene white balance.
- Compare the processed left region with the original right region using the comparison slider.
- Preview stays 8-bit sRGB. The default fast path keeps the HNCS core exact but approximates final 8-bit sRGB encoding by at most one code level; the exactReference API remains available.
- Export is HEIF-only (`.heic`), using `CIContext.writeHEIF10Representation(of:to:colorSpace:options:)`. On explicit export, the numerical backend recomputes display-linear RGBA floats from the source/exposure/CCT snapshot associated with the displayed processed image. No UInt8 preview buffer, PNG, or JPEG enters this path. `CIImage` receives `.RGBAf` tagged `extendedLinearSRGB` (with values restricted to 0…1); the context works in float and encodes into standard SDR sRGB. No PQ/HLG, expanded HDR range, or gain map is requested. Encoder failure is shown as an error, with no fallback to 8-bit output.
- The native share sheet offers the original HEIC file/data through `NSItemProvider` and `UIActivityItemsConfiguration`. Save to Files and compatible receiving apps use this same HEIF representation; there is no standalone JPEG export or automatic sharing transcode. WeChat compatibility is unverified and may require a separately tested sharing-only fallback in future.
- The HNCS preview C++ backend uses up to four bounded workers; Swift reduces this for low-power or elevated thermal state. This policy is not yet device-benchmarked. The new float export kernel currently runs single-threaded; preview benchmark speedups are not HEIF export timings. FFCS uses the exact tiled route with one worker by default pending device profiling; its C API supports 1–4 workers.

## Intentional prototype limits

- Both preview and export are capped at 2048 pixels on the long edge to limit working-buffer size and latency. This is not full-resolution export. The full input file is still read, and the Apple decoder may allocate full-resolution RAW data before downscaling; the cap does not bound total peak import memory. RAW `nativeSize` and `scaleFactor` request reduced output before evaluating `outputImage`; rendered formats use 2048px ImageIO thumbnails. Internal RAW peak memory and large-input behavior still require device profiling.
- File reads and processing run off the UI thread. Settings lock as soon as photo transfer/file loading starts. Latest-request tokens prevent an older transfer/decode/render from replacing a newer selection; superseded photo tasks are cancelled. The complete decode/render stage is serialized so non-cancellable RAW decodes cannot overlap. Slider changes render after the drag ends.
- High-bit-depth export does not restore detail absent from an 8-bit source. ImageIO thumbnail precision for HEIC/16-bit imports also needs device inspection before claiming a universally high-bit-depth import-to-export pipeline.
- Source adaptation is experimental. No iPhone/device calibration and no claim of reproducing a particular camera exactly.
- Transparent source images flatten onto black. Export omits source metadata, including location metadata.
- Export recomputation and HEIF encoding run off the UI thread while the controls are busy/locked. The output belongs to the displayed processed snapshot even if unrendered slider positions differ. Only export allocates the additional float buffer; it is not retained during preview interaction.
- Export uses an app temporary file and the system share sheet. A shared owner retains the file for the sheet and its item-provider callbacks; the file is removed when those owners are released (a crash can leave OS-managed temporary data). No automatic upload, direct Photos-library write, camera capture, or background network work. Receiving apps may re-encode the file themselves; this prototype cannot guarantee their behavior.
- Device/SDK compilation, actual 10-bit HEVC/HEIF bitstream, SDR/sRGB metadata, share-sheet behavior, WeChat compatibility, DNG support, color-space orientation and real-device performance still need validation. An encoder API request is not a verified device result; no exported HEIF has been generated in this Linux environment.

## First Apple-platform validation checklist

1. Run the simulator build command above and resolve any SDK/compiler diagnostics.
2. Import a landscape JPEG, portrait JPEG with EXIF orientation, PNG and wide-gamut HEIC. Check orientation, aspect ratio and consistent comparison alignment.
3. Import supported landscape and portrait DNGs in Files, then an unsupported/corrupt file. The decoder orientation is explicitly set from ImageIO EXIF orientation metadata (when available). Confirm orientation, useful errors and no crashes on Apple hardware.
4. Drag comparison to both endpoints; left endpoint shows only original, right endpoint only processed.
5. Change exposure/CCT, release each slider, and verify output changes. Reset and verify repeatability.
6. Export via Files/AirDrop on a physical device; reopen the HEIC and check dimensions (long edge ≤2048), SDR sRGB tagging, orientation and approximate visual match to the preview (which has 8-bit quantization). Inspect the HEVC coded pixel depth and HEIF primary-image metadata with a HEIF-aware inspector: confirm 10-bit content, SDR transfer/color information, and no HDR gain map. A `.heic` suffix or a decoded 16-bit buffer alone is not proof of a 10-bit bitstream. Test a smooth gradient for retained precision beyond the 8-bit preview. Test encoder failure without silently producing another format.
7. In WeChat, test both ordinary image sharing and file/original modes using the exact app/iOS/device versions. Inspect the received file and compare its hash, dimensions, bit depth and color tags; document whether it was accepted or re-encoded. Do not claim compatibility before this test. Check Save to Files and AirDrop independently.
8. Try large inputs, iPad sheet presentation, dark mode, VoiceOver and cancellation. Simulate slow iCloud photo loading and rapid newer selections: only the newest result should commit, with settings locked throughout transfer. Dismiss/cancel sharing and verify the temporary file is removed after the sheet and provider release it; also test repeated shares and export after a failed render, which must export the still-displayed snapshot.
9. On iOS 26 built with Xcode 26, inspect native glass; on iOS 17/18 inspect fallback rendering.

## Apple API references

- [CIRAWFilter data initializer](https://developer.apple.com/documentation/coreimage/cirawfilter/init(imagedata:identifierhint:))
- [Core Image bitmap rendering](https://developer.apple.com/documentation/coreimage/cicontext/render(_:tobitmap:rowbytes:bounds:format:colorspace:))
- [RAW native size](https://developer.apple.com/documentation/coreimage/cirawfilter/nativesize)
- [RAW scale factor](https://developer.apple.com/documentation/coreimage/cirawfilter/scalefactor)
- [ImageIO thumbnail decoding](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:))
- [RAW orientation](https://developer.apple.com/documentation/coreimage/cirawfilter/orientation)
- [SwiftUI comparison masking](https://developer.apple.com/documentation/swiftui/view/mask(alignment:_:))
- [Applying Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)

- [Dedicated HEIF10 writer (iOS 15+; verified in Apple documentation)](https://developer.apple.com/documentation/coreimage/cicontext/writeheif10representation(of:to:colorspace:options:))
- [Core Image working format](https://developer.apple.com/documentation/coreimage/cicontextoption/workingformat)
- [NSItemProvider file representations](https://developer.apple.com/documentation/foundation/nsitemprovider/registerfilerepresentation(fortypeidentifier:fileoptions:visibility:loadhandler:))
- [Activity item-provider configuration](https://developer.apple.com/documentation/uikit/uiactivityitemsconfiguration/init(itemproviders:))
