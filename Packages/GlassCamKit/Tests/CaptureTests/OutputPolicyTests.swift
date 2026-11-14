import Testing
import Foundation
@testable import Capture
@testable import ImagingCore

struct OutputPolicyTests {
    @Test(arguments: [12_000_000, 24_000_000, 48_000_000])
    func sourcePixelCount_doesNotChange24MPOutput(count: Int) throws {
        let framing = CaptureFraming(nativePixelCount: count)

        let selected = try ExportSettings.camera24(framing: framing).selectedOutputMegapixels(sourceWidth: 8000, sourceHeight: 6000)

        #expect(selected == 24)
    }
    @Test(arguments: [(8000, 6000), (6000, 8000), (257, 389), (389, 257), (1000, 1000)])
    func adaptiveOutput_preservesCompositionAt24MP(size: (Int, Int)) throws {
        let dimensions = try ExportSettings.camera24().dimensions(sourceWidth: size.0, sourceHeight: size.1)
        // Integer rounding of the original adaptive-output fixture permits 0.2% pixel and 0.1% aspect error.
        let pixelTolerance = 0.002, aspectTolerance = 0.001
        #expect(abs(Double(dimensions.width * dimensions.height) / 24_000_000 - 1) < pixelTolerance)
        #expect(abs((Double(dimensions.width) / Double(dimensions.height)) / (Double(size.0) / Double(size.1)) - 1) < aspectTolerance)
    }
    @Test func squareCrop_keeps24MPOutput() throws {
        #expect(try ExportSettings.camera24().selectedOutputMegapixels(sourceWidth: 6000, sourceHeight: 4000, crop: .centeredSquare) == 24)
    }
    @Test func digitalZoom_keeps24MPOutput() throws {
        let framing = CaptureFraming(displayZoom: 2, deviceZoom: 4, nativeDeviceZoom: 2, nativePixelCount: 48_000_000)
        #expect(try ExportSettings.camera24(framing: framing).selectedOutputMegapixels(sourceWidth: 8000, sourceHeight: 6000) == 24)
    }
    @Test func nativeOutput_preservesSourceDimensions() throws {
        let size = try ExportSettings.native.dimensions(sourceWidth: 257, sourceHeight: 389)
        #expect(size.width == 257)
        #expect(size.height == 389)
    }
    @Test(arguments: [ExportSettings(targetWidth: 514, targetHeight: 778), ExportSettings(targetWidth: nil, targetHeight: nil, cameraMegapixels: 0), .camera24(framing: CaptureFraming(deviceZoom: .nan))])
    func invalidOrExplicitUpscaledOutput_isRejected(settings: ExportSettings) {
        #expect(throws: PipelineError.self) { try settings.dimensions(sourceWidth: 257, sourceHeight: 389) }
    }
    @Test(arguments: [(0.1, 0.5), (20.0, 10.0), (Double.nan, 0.5)])
    func zoomRange_clampsInvalidOrOutsideValue(input: (Double, Double)) {
        #expect(CameraZoomRange(lowerBound: 0.5, upperBound: 10, stops: []).clamped(input.0) == input.1)
    }
    @Test func uncroppedNativeRAW_rejectsSilentResolutionLoss() {
        let framing = CaptureFraming(cameraID: "main", nativePixelCount: 8064 * 6048)
        #expect(!framing.acceptsRAWDimensions(requestedWidth: 8064, requestedHeight: 6048,
            deliveredWidth: 4032, deliveredHeight: 3024, bufferWidth: 4032, bufferHeight: 3024))
        #expect(framing.acceptsRAWDimensions(requestedWidth: 8064, requestedHeight: 6048,
            deliveredWidth: 6048, deliveredHeight: 8064, bufferWidth: 8064, bufferHeight: 6048))
    }
    @Test func explicitlyZoomedRAW_acceptsSmallerMatchingAspectOnly() {
        let framing = CaptureFraming(deviceZoom: 2, cameraID: "main", nativePixelCount: 8064 * 6048)
        #expect(framing.acceptsRAWDimensions(requestedWidth: 8064, requestedHeight: 6048,
            deliveredWidth: 4032, deliveredHeight: 3024, bufferWidth: 4032, bufferHeight: 3024))
        #expect(!framing.acceptsRAWDimensions(requestedWidth: 8064, requestedHeight: 6048,
            deliveredWidth: 4032, deliveredHeight: 3000, bufferWidth: 4032, bufferHeight: 3000))
    }
    @Test func exifDigitalCrop_constrainsEffectivePixelsAndAllowsSmallerRAW() throws {
        let framing = CaptureFraming(cameraID: "main", nativePixelCount: 48_000_000, exifDigitalZoom: 2)
        #expect(framing.acceptsRAWDimensions(requestedWidth: 8000, requestedHeight: 6000,
            deliveredWidth: 4000, deliveredHeight: 3000, bufferWidth: 4000, bufferHeight: 3000))
        #expect(try ExportSettings.camera24(framing: framing).selectedOutputMegapixels(sourceWidth: 8000, sourceHeight: 6000) == 24)
    }
    @Test(arguments: [Double.nan, .infinity, -1, 0, 1, 1.5])
    func exifCannotEraseKnownDigitalZoom(exif: Double) {
        #expect(CaptureFraming(deviceZoom: 2, exifDigitalZoom: exif).relativeDigitalZoom == 2)
    }
    @Test func recoveredReview_usesDecodedExtentAndLabelsInterpolation() throws {
        let framing = CaptureFraming(nativePixelCount: 48_000_000, deliveredWidth: 8000, deliveredHeight: 6000, decodedWidth: 4000, decodedHeight: 3000)
        let replay = try JSONDecoder().decode(CaptureFraming.self, from: JSONEncoder().encode(framing))
        let saved = SavedCapture(file: TemporaryHEIFFile(), preview: try PreviewRaster(linearRGBA: [Float](repeating: 1, count: 4 * 4 * 4), width: 4, height: 4),
                                width: 5656, height: 4242, snapshot: CaptureSnapshot(recipe: .standard, output: .camera24(framing: replay)))
        #expect(saved.resolutionDescription == "Estimated source 12.0 MP · Output 24.0 MP · Interpolated")
    }
    @Test func snapshotRoundtrip_preservesCaptureGeometry() throws {
        let frozen = CaptureSnapshot(recipe: .standard, output: .camera24(framing: .init(displayZoom: 2, deviceZoom: 4, nativeDeviceZoom: 2, nativePixelCount: 48_000_000)))
        let replay = try JSONDecoder().decode(CaptureSnapshot.self, from: JSONEncoder().encode(frozen))
        #expect(replay.recipe == frozen.recipe)
        #expect(replay.output == frozen.output)
    }
    @Test(arguments: CaptureQuality.allCases)
    func sourceQuality_selectsHighestAllowedNativeSize(quality: CaptureQuality) {
        let high = CGSize(width: 8064, height: 6048), low = CGSize(width: 4032, height: 3024)
        #expect(quality.sourceDimensions(available: [high, low]) == (quality.usesBayer ? low : high))
    }
    @Test func speedSource_rejectsUnsupportedOrInvalidDimensions() {
        #expect(CaptureQuality.speed.sourceDimensions(available: [.init(width: 8064, height: 6048)]) == nil)
        #expect(CaptureQuality.speed.sourceDimensions(available: [.zero, .init(width: CGFloat.nan, height: 4)]) == nil)
    }
    @Test(arguments: [CaptureQuality.speed, .balanced])
    func cameraModes_share24MPDimensions(quality: CaptureQuality) throws {
        let snapshot = CaptureSnapshot(recipe: .standard, output: .native, quality: quality)

        let size = try snapshot.output.dimensions(sourceWidth: 4032, sourceHeight: 3024)

        #expect(size.width == 5656)
        #expect(size.height == 4242)
    }
    @Test(arguments: [12, 48])
    func restoredSnapshot_normalizesOtherResolutionTo24MP(megapixels: Int) throws {
        let snapshot = CaptureSnapshot(recipe: .standard, output: .native, quality: .speed)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object["output"] = ["cameraMegapixels": megapixels]

        let restored = try JSONDecoder().decode(CaptureSnapshot.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(restored.output.cameraMegapixels == 24)
    }

    @Test func snapshotWithoutMode_defaultsToBalanced() throws {
        let snapshot = CaptureSnapshot(recipe: .standard, output: .camera24(), quality: .speed)
        let bytes = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: "quality")
        let decoded = try JSONDecoder().decode(CaptureSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.quality == .balanced)
    }
    @Test(arguments: ["quality", "turbo"])
    func unavailableQuality_isRejected(value: String) throws {
        let snapshot = CaptureSnapshot(recipe: .standard, output: .camera24(), quality: .speed)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object["quality"] = value
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CaptureSnapshot.self, from: JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func speedSnapshot_roundtripPreservesQualityAnd24MPOutput() throws {
        let snapshot = CaptureSnapshot(recipe: .standard, output: .camera24(), quality: .speed)
        let decoded = try JSONDecoder().decode(CaptureSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.quality == .speed)
        #expect(decoded.output.cameraMegapixels == 24)
    }
}
