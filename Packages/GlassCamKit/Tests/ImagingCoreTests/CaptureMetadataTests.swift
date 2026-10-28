import Testing
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import ImagingCore
import GlassCamTestSupport

private struct CaptureMetadataFixture {
    let output: TemporaryHEIFFile
    let metadata: PhotoMetadata
    let expectedDate: Date
    let bareProperties: [String: Any]
    let before: [Float]
    let after: [Float]
    init() throws {
        let width = 32, height = 24
        var rgba = [Float](repeating: 2, count: width * height * 4)
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 1 }
        let raster = try PreviewRaster(linearRGBA: rgba, width: width, height: height)
        let file = TemporaryHEIFFile()
        try ImagePipelineTests.targetContext.writeHEIF10Representation(of: raster.image, to: file.url, colorSpace: ImagePipelineTests.pq, options: [:])
        let before = ImagePipelineTests.pixels(CIImage(contentsOf: file.url, options: [.expandToHDR: true])!)
        let original: [String: Any] = [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Fixture Camera",
                kCGImagePropertyTIFFModel as String: "Three-lens fixture",
                kCGImagePropertyTIFFDateTime as String: "2026:10:19 11:22:33",
                kCGImagePropertyTIFFOrientation as String: 6
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:10:19 11:22:33",
                kCGImagePropertyExifDateTimeDigitized as String: "2026:10:19 11:22:33",
                kCGImagePropertyExifOffsetTime as String: "+08:00",
                kCGImagePropertyExifOffsetTimeOriginal as String: "+08:00",
                kCGImagePropertyExifOffsetTimeDigitized as String: "+08:00",
                kCGImagePropertyExifSubsecTimeOriginal as String: "125",
                kCGImagePropertyExifSubsecTimeDigitized as String: "125",
                kCGImagePropertyExifExposureTime as String: 1.0 / 125,
                kCGImagePropertyExifFNumber as String: 2.8,
                kCGImagePropertyExifISOSpeedRatings as String: [200],
                kCGImagePropertyExifFocalLength as String: 5.7,
                kCGImagePropertyExifFocalLenIn35mmFilm as String: 26,
                kCGImagePropertyExifLensModel as String: "Fixture Lens",
                kCGImagePropertyExifLensMake as String: "Fixture Camera",
                kCGImagePropertyExifLensSpecification as String: [5.7, 5.7, 2.8, 2.8],
                kCGImagePropertyExifMakerNote as String: Data([1, 2, 3, 4]),
                kCGImagePropertyExifPixelXDimension as String: 9000,
                kCGImagePropertyExifPixelYDimension as String: 6000
            ]
        ]
        let metadata = PhotoMetadata(properties: original)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 3, minute: 22, second: 33))!.addingTimeInterval(0.125)
        let bareSource = CGImageSourceCreateWithURL(file.url as CFURL, nil)!
        let bareProperties = CGImageSourceCopyPropertiesAtIndex(bareSource, 0, nil) as! [String: Any]
        try ImagePipelineTests.targetContext.writeHEIF10Representation(
            of: raster.image.settingProperties(metadata.encodingProperties(width: width, height: height)),
            to: file.url, colorSpace: ImagePipelineTests.pq, options: [:])
        let after = ImagePipelineTests.pixels(CIImage(contentsOf: file.url, options: [.expandToHDR: true])!)

        let retained = try SourceImageFile(data: Data(contentsOf: file.url), fileExtension: "heic")
        let output = TemporaryHEIFFile(captureDate: retained.metadata.captureDate)
        try ImagePipeline.writeHEIF(resources: TestResources.colors, sourceFile: retained, recipe: .standard, to: output.url, settings: .native)
        self.output = output; self.metadata = metadata; expectedDate = date
        self.bareProperties = bareProperties; self.before = before; self.after = after
    }
    func properties(jpeg: Bool) async throws -> [String: Any] {
        let bytes: Data
        if jpeg { bytes = try await shareData(ShareDelivery.makeProvider(for: output), type: .jpeg) }
        else { bytes = try Data(contentsOf: output.url) }
        guard let container = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any] else {
            throw PipelineError.encoding
        }
        return properties
    }
}

func shareData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
            if let error { continuation.resume(throwing: error) }
            else if let data { continuation.resume(returning: data) }
            else { continuation.resume(throwing: PipelineError.encoding) }
        }
    }
}

struct CaptureMetadataTests {
    @Test func captureDate_preservesTimezoneAndSubseconds() throws {
        let fixture = try CaptureMetadataFixture()
        // EXIF decimal subseconds are accepted within one millisecond.
        let timestampTolerance = 0.001
        #expect(abs(try #require(fixture.metadata.captureDate).timeIntervalSince(fixture.expectedDate)) < timestampTolerance)
    }
    @Test func metadataValidation_rejectsSuccessfulEncodeWithoutCaptureFields() throws {
        let fixture = try CaptureMetadataFixture()
        #expect(throws: PipelineError.metadata) { try fixture.metadata.validate(in: fixture.bareProperties) }
    }
    @Test func encodingCaptureMetadata_keepsImagePixels() throws {
        let fixture = try CaptureMetadataFixture()
        #expect(fixture.after == fixture.before)
    }
    @Test(arguments: [false, true])
    func export_preservesCameraAndLensIdentity(jpeg: Bool) async throws {
        let properties = try await CaptureMetadataFixture().properties(jpeg: jpeg)
        let tiff = try #require(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == "Fixture Camera")
        #expect(tiff[kCGImagePropertyTIFFModel as String] as? String == "Three-lens fixture")
        #expect(exif[kCGImagePropertyExifLensModel as String] as? String == "Fixture Lens")
    }
    @Test(arguments: [false, true])
    func export_preservesMeasuredExposure(jpeg: Bool) async throws {
        let properties = try await CaptureMetadataFixture().properties(jpeg: jpeg)
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        let exposure = try #require(exif[kCGImagePropertyExifExposureTime as String] as? NSNumber).doubleValue
        // Original rational EXIF exposure round-trip tolerance.
        let exposureTolerance = 1e-7
        #expect(exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int] == [200])
        #expect(abs(exposure - 1.0 / 125) < exposureTolerance)
    }
    @Test(arguments: [false, true])
    func export_normalizesGeometryAndDropsStaleMakerNote(jpeg: Bool) async throws {
        let properties = try await CaptureMetadataFixture().properties(jpeg: jpeg)
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(exif[kCGImagePropertyExifMakerNote as String] == nil)
        #expect((exif[kCGImagePropertyExifPixelXDimension as String] as? NSNumber)?.intValue == 32)
        #expect((exif[kCGImagePropertyExifPixelYDimension as String] as? NSNumber)?.intValue == 24)
        #expect((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1 == 1)
    }
    @Test(arguments: [false, true])
    func export_preservesCaptureDateFields(jpeg: Bool) async throws {
        let fixture = try CaptureMetadataFixture()
        let properties = try await fixture.properties(jpeg: jpeg)
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        let date = try #require(PhotoMetadata(properties: properties).captureDate)
        let timestampTolerance = 0.001
        #expect(abs(date.timeIntervalSince(fixture.expectedDate)) < timestampTolerance)
        #expect(exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String == "+08:00")
        #expect(exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String == "125")
        #expect(exif[kCGImagePropertyExifSubsecTimeDigitized as String] as? String == "125")
    }
    @Test func captureMetadata_keepsTenBitHDRExport() async throws {
        let fixture = try CaptureMetadataFixture()
        let properties = try await fixture.properties(jpeg: false)
        try fixture.metadata.validate(in: properties)
        #expect((properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10)
        #expect(CIImage(contentsOf: fixture.output.url)?.colorSpace?.isHDR() == true)
    }
}
