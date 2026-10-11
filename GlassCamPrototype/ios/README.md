# GlassCam native iOS effect prototype

Native SwiftUI interface, Core Image import adaptation, and a C++17 HNCS numerical backend via a thin Swift/C bridge. No package-manager dependency or generated-project tool is required.

## Build status

**Not compiled or run on an Apple platform in this environment.** The source and Xcode project are provided for local validation. The Linux cloud has no Xcode/iOS SDK; passing C++ numerical checks does not establish an iOS build or visual correctness.

## Open and run

1. On a Mac with Xcode 16 or later, open `GlassCam.xcodeproj`.
2. Select the shared `GlassCam` scheme and an iOS 17+ simulator.
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
- Exposure spans −2 to +2 EV. Factory CCT spans 2000–10000 K. CCT controls profile interpolation, not an accurate estimate of scene white balance.
- Compare the processed left region with the original right region using the comparison slider.
- Export the current processed image as sRGB PNG through the native share sheet. The default fast path keeps the HNCS core exact but approximates final 8-bit sRGB encoding by at most one code level; the exactReference API remains available.
- The C++ backend uses up to four bounded workers; Swift reduces this for low-power or elevated thermal state. This policy is not yet device-benchmarked.

## Intentional prototype limits

- Both preview and export are capped at 2048 pixels on the long edge to limit working-buffer size and latency. This is not full-resolution export. The full input file is still read, and the Apple decoder may allocate full-resolution RAW data before downscaling; the cap does not bound total peak import memory. Decoder-native downsampling and large-input memory validation remain work to do.
- File reads and processing run off the UI thread. Settings lock as soon as photo transfer/file loading starts. Latest-request tokens prevent an older transfer/decode/render from replacing a newer selection; superseded photo tasks are cancelled. The complete decode/render stage is serialized so non-cancellable RAW decodes cannot overlap. Slider changes render after the drag ends.
- Source adaptation is experimental. No iPhone/device calibration and no claim of reproducing a particular camera exactly.
- Transparent source images flatten onto black. Export omits source metadata, including location metadata.
- Export uses an app temporary file and the system share sheet; the temporary file is removed after sheet dismissal. No automatic upload, Photos-library write, camera capture, or background network work.
- Device/SDK compilation, share-sheet behavior, DNG support, color-space orientation and real-device performance still need validation.

## First Apple-platform validation checklist

1. Run the simulator build command above and resolve any SDK/compiler diagnostics.
2. Import a landscape JPEG, portrait JPEG with EXIF orientation, PNG and wide-gamut HEIC. Check orientation, aspect ratio and consistent comparison alignment.
3. Import supported landscape and portrait DNGs in Files, then an unsupported/corrupt file. The decoder orientation is explicitly set from ImageIO EXIF orientation metadata (when available). Confirm orientation, useful errors and no crashes on Apple hardware.
4. Drag comparison to both endpoints; left endpoint shows only original, right endpoint only processed.
5. Change exposure/CCT, release each slider, and verify output changes. Reset and verify repeatability.
6. Export via Files/AirDrop; reopen the PNG and check dimensions (long edge ≤2048), sRGB tagging, orientation and match to the processed preview.
7. Try large inputs, iPad sheet presentation, dark mode, VoiceOver and cancellation. Simulate slow iCloud photo loading and rapid newer selections: only the newest result should commit, with settings locked throughout transfer. Dismiss sharing and verify the app temporary file is removed.
8. On iOS 26 built with Xcode 26, inspect native glass; on iOS 17/18 inspect fallback rendering.

## Apple API references

- [CIRAWFilter data initializer](https://developer.apple.com/documentation/coreimage/cirawfilter/init(imagedata:identifierhint:))
- [Core Image bitmap rendering](https://developer.apple.com/documentation/coreimage/cicontext/render(_:tobitmap:rowbytes:bounds:format:colorspace:))
- [RAW native size](https://developer.apple.com/documentation/coreimage/cirawfilter/nativesize)
- [RAW scale factor](https://developer.apple.com/documentation/coreimage/cirawfilter/scalefactor)
- [ImageIO thumbnail decoding](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:))
- [RAW orientation](https://developer.apple.com/documentation/coreimage/cirawfilter/orientation)
- [SwiftUI comparison masking](https://developer.apple.com/documentation/swiftui/view/mask(alignment:_:))
- [Applying Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
