# Full-source SDR HEIF10 pipeline

## Implemented separation

`ImagePipeline.load(data:fileExtension:previewMaximumEdge:)` saves an immutable,
file-protected copy of the original import/capture bytes. `ImportedImage` owns
that file through a shared reference. The selected preview long edge (default
2048, allowed 256–4096) affects only preview decoding and editing. Export does
not read the reduced preview RGB or the display UIImage.

`writeHEIF(_:to:settings:)` reopens the saved original and sets RAW scaleFactor
to 1. Rendered-image input uses its embedded profile and EXIF orientation. RAW
orientation is assigned to CIRAWFilter once. Both routes are flattened onto
black and adapted through extended linear sRGB, as before. This is still an
experimental source adapter, not a calibrated iPhone native-camera profile.

The immutable processed recipe selects the exact existing HNCS float route or
the FFCS exact strip route. Color processing runs at the full decoded source
size before any requested reduction. FFCS strips include the one-row sharpening
halo and supply original full dimensions and global row indices for grain;
there is no grain restart at stripe boundaries. RGB and RGBA scratch arrays
contain at most 66 source-width rows (64 output plus two halos).

The processed RGBAf pixels are written sequentially to a protected temporary
file, then mapped read-only without a Swift full-image copy. Mapping ownership
is captured by the Data deallocator. File and mapping remain alive throughout
the synchronous encoder. Source and raster files are removed when their owners
are released; encoded output is removed if encoding/validation fails.

Requested dimensions are supplied from the camera's per-physical-lens choices.
The backend swaps width/height to match source orientation if necessary, checks
aspect ratio and rejects any upsampling. Imported files may request native
size. Camera integration passes its explicit captured output choice into load; the
ImportedImage stores that immutable export-settings snapshot alongside the
source file. writeHEIF defaults to that snapshot, not live camera controls. A target exceeding the actual
RAW decoder output fails rather than synthesizing detail.

When reducing, CILanczosScaleTransform executes after color processing in
linear light. A final clamp removes possible negative/over-range ringing.
Only `writeHEIF10Representation` is used, tagged ordinary SDR sRGB. A fresh
bitmap does not carry source HDR/gain-map properties. No JPEG, 8-bit fallback,
PQ/HLG, HDR expansion or gain-map output is requested. The written dimensions
and ImageIO component-depth metadata must match the requested dimensions and
10 bits, otherwise the output is discarded.

## Memory and storage limits

This is **bounded application-owned processing scratch**, not a bounded total
resident-memory claim. At 8064 pixels wide, main scratch arrays are roughly
10–35 MB depending on buffer lifetimes and backend temporaries; context/LUTs,
source decoder, Core Image, page cache and HEIF encoder are additional.
A 48.8 MP RGBAf intermediate needs approximately 781 MB of disk space. The
implementation checks available important-usage capacity for the raster,
an encoded-output margin, and 64 MiB spare before starting. A disk-full error
can still happen later and is propagated. Source copy space is additional.

The mmap reserves a full-image address range, and touched file-backed pages
can become resident. Apple may internally allocate full-size decode, filtering
and encode surfaces. Repeated stripe rendering may also cause decoder work to
repeat. The full-stage serial queue prevents concurrent exports/import decodes
from multiplying those application-owned surfaces; a canceled task can finish
an in-progress Apple call before the next strip cancellation check.

## Verification boundary and required device checks

Portable C++ strip-oracle tests verify FFCS exact row results against the
full-frame backend, including global grain and boundaries. Python source
contract tests verify architectural separation, ordering and format calls;
they do not compile Swift or prove any encoded result.

This environment has no Apple SDK. Before distribution, build on the target
Xcode/iOS SDK and run device tests that:

1. Compare concatenated Core Image rendered stripe bytes against a single
   full-frame render for asymmetric images and all EXIF orientations. Row
   indices intentionally use the existing CI bitmap's row convention.
2. Compare full-source color output to a full-frame reference before reduction;
   compare reduction and actual HEIF bit depth, transfer characteristics,
   dimensions, visible orientation and absence of gain-map/HDR metadata.
3. Capture all advertised 12/24/48 MP choices on each physical lens, including
   a device with no ProRAW support. Ensure actual capture dimensions suffice;
   do not infer support from the app's marketing resolution labels.
4. Profile peak RSS, thermal behavior, latency, cancellation, file cleanup,
   background/lock behavior and low-disk failures on the oldest supported phone.

## Official API references

- [CIRAWFilter nativeSize](https://developer.apple.com/documentation/coreimage/cirawfilter/nativesize)
- [Core Image context and image representation APIs](https://developer.apple.com/documentation/coreimage/cicontext)
- [Capture and process ProRAW images](https://developer.apple.com/videos/play/wwdc2021/10160/)

These APIs support full-native RAW and dedicated HEIF10 encoding; they do not
promise bounded internal decoder/encoder allocation.

## Precision and display checks

Output dimensions must have the exact source aspect ratio (tolerance only for floating arithmetic); Lanczos aspectRatio stays1, so the exporter does not stretch to fit. Full-source FFCS grain/sharpen followed by reduction can differ visibly from a low-resolution effect preview, even with the same recipe. That preview is approximate. Run `swift tests/apple_ci_strip_roundtrip.swift` on macOS with Apple frameworks before accepting stripe orientation: this asymmetric diagnostic compares64/64/3 row segments and bitmap roundtrip. It has not run in the Linux workspace.

HNCS now also keeps a one-entry immutable recipe context cache, avoiding LUT/matrix preparation for every64-row strip. On the cloud CPU,96 repeated native context constructions alone cost median0.538s across5 samples (`validation/hncs_context_cache.json`); the cache removes repeated setup, but this is not an Apple end-to-end export benchmark. In-flight calls retain ownership while a new recipe replaces the cached entry.
