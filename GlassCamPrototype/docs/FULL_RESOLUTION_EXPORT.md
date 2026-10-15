# Full-source HDR HEIF10 pipeline

## Implemented separation

`ImagePipeline.load(data:fileExtension:previewMaximumEdge:)` saves an immutable,
file-protected copy of the original import/capture bytes. `ImportedImage` owns
that file through a shared reference. The selected preview long edge (default
2048, allowed 256–4096) affects only preview decoding and editing. Export does
not read the reduced preview RGB or the display UIImage.

`writeHEIF(_:to:settings:)` reopens the saved original and sets RAW scaleFactor
to 1 and extendedDynamicRangeAmount to 1. Rendered-image input expands HDR/gain-map content and uses its embedded profile and EXIF orientation. RAW
orientation is assigned to CIRAWFilter once. Both routes are flattened onto
black and adapted through extended linear sRGB, as before. This is still an
experimental source adapter, not a calibrated iPhone native-camera profile.

The immutable processed recipe selects the exact existing HNCS float route or
the FFCS exact strip route. Color processing runs at the full decoded source
size before any requested reduction. FFCS strips include the backend-reported Gaussian sharpening
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
linear light. A final clamp removes negative ringing while retaining super-white values up to the PQ ceiling (10,000 nits / 203-nit reference white).
Only `writeHEIF10Representation` is used, with BT.2020/PQ HDR color space. Written dimensions, 10-bit component depth, and an HDR color space must validate, otherwise the output is discarded.

The existing reference color cores remain SDR. The outer adapter separates each source pixel’s gain `max(1, R, G, B)`, applies the selected effect to RGB divided by that gain, then restores the gain after color and spatial processing. This preserves source highlights without inventing brighter pixels for SDR inputs. The HDR extension is not a calibrated camera profile or a claim of native HDR reference parity. Spatial HNCS presets retain gain values in a separate protected Float32 file until the global spatial pass finishes. HDR RGBAf pixels are materialized before Lanczos so scaling cannot change the order of gain restoration.

Save to Photos/Files and the primary share representation preserve this HDR HEIF. JPEG-only share recipients receive a tone-mapped SDR compatibility derivative. See [HDR behavior](HDR_EXPORT.md).

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

The 2026-10-13 macOS run of `python3 -B tools/test_apple_images.py` passes real
Core Image, Foundation, Metal and HEIF checks; Xcode 27 simulator Debug/Release
builds also pass. Bitmap and native-backend rows now count from the top, with
explicit conversion to the lower-left CI rectangle. Alpha clamps are cropped
back to finite bounds before encoding. Before distribution, run device tests that:

1. Compare concatenated Core Image rendered stripe bytes against a single
   full-frame render for asymmetric images and all EXIF orientations. Row
   indices intentionally use the existing CI bitmap's row convention.
2. Compare full-source color output to a full-frame reference before reduction;
   compare reduction and actual HEIF bit depth, transfer characteristics,
   dimensions, visible orientation, PQ profile, and decoded highlight values above 1.
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

Output dimensions must have the exact source aspect ratio (tolerance only for floating arithmetic); Lanczos aspectRatio stays1, so the exporter does not stretch to fit. Full-source FFCS grain/sharpen followed by reduction can differ visibly from a low-resolution effect preview, even with the same recipe. That preview is approximate. `swift tests/apple_ci_strip_roundtrip.swift` now passes on macOS: asymmetric64/64/3 row segments and bitmap roundtrip have maximum error0. The production-pipeline regression also compares real full-source and reduced HEIF exports with whole-frame processing through the same codec.

HNCS now also keeps a one-entry immutable recipe context cache, avoiding LUT/matrix preparation for every64-row strip. On the cloud CPU,96 repeated native context constructions alone cost median0.538s across5 samples (`validation/hncs_context_cache.json`); the cache removes repeated setup, but this is not an Apple end-to-end export benchmark. In-flight calls retain ownership while a new recipe replaces the cached entry.

## HNCS revision8空间预设

Square Crop先按实际源像素居中裁切；输出保持原输出档位的缩小比例，方图实际MP更少。需要grain/USM的HNCS配方先流写12B/像素top-left工作RGB，运行全图统计与滤波（最大16B/像素scratch），再64行finish至RGBAf；不逐条带重设随机种子或方差。Swift额外磁盘预算按36B/像素保守预留（含4B/像素HDR高光增益），之外仍有RGBAf和编码余量。内核固定RAM小于4MiB不含Apple处理/文件缓存；48MP总磁盘需要数GB，实际设备峰值尚未测量。详见[参考合同](HNCS_REVISION8.md)。
