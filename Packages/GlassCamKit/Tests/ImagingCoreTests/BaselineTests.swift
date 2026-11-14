import Testing
import Foundation
import CoreImage
import ImageIO
import CryptoKit
@testable import ImagingCore
import GlassCamTestSupport

private enum BaselineInputs {
    static var enabled: Bool { ProcessInfo.processInfo.environment["GLASSCAM_DNG_DIR"] != nil }
    static func source(_ index: Int) throws -> URL {
        let root = try #require(TestResources.environmentURL("GLASSCAM_DNG_DIR"))
        let sources = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "dng" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(sources.count >= 3, "GLASSCAM_DNG_DIR must contain main, ultra-wide and telephoto ProRAW fixtures")
        return sources[index]
    }
    static func output(_ name: String) throws -> URL {
        let root = TestResources.environmentURL("GLASSCAM_BASELINE_OUTPUT") ?? FileManager.default.temporaryDirectory.appendingPathComponent("GlassCam-color-baseline")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(name)
    }
    static func reportHash(_ url: URL) throws {
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        print("HEIF SHA256 \(digest)  \(url.lastPathComponent)")
    }
}

@Suite(.enabled(if: BaselineInputs.enabled, "Set GLASSCAM_DNG_DIR to run the three local ProRAW baselines"), .serialized)
struct BaselineTests {
    @Test(arguments: 0..<3)
    func rawWhiteBalance_isFrozenFromActualDecoder(index: Int) throws {
        let source = try BaselineInputs.source(index)
        let input = try ImagePipeline.load(data: Data(contentsOf: source), fileExtension: "dng")
        let processed = try ImagePipeline.process(resources: TestResources.colors, input, recipe: .standard)
        let filter = try #require(CIRAWFilter(imageURL: source))
        let asShot = PhotoWhiteBalance.asShot(filter)
        #expect(asShot.origin == .appleRAW)
        #expect(input.whiteBalance == asShot)
        #expect(processed.recipe.photoWhiteBalance == asShot)
    }
    @Test(arguments: 0..<3)
    func rawSharpness_isAppliedOnceWithFrozenBaseline(index: Int) throws {
        let source = try BaselineInputs.source(index)
        let input = try ImagePipeline.load(data: Data(contentsOf: source), fileExtension: "dng")
        let processed = try ImagePipeline.process(resources: TestResources.colors, input, recipe: .standard)
        let filter = try #require(CIRAWFilter(imageURL: source))
        let baseline = try ImagePipeline.baselineSharpness(in: filter.properties)
        let rawRecipe = processed.source.rawDecode
        let inspection = try ImagePipeline.inspectRAW(sourceFile: input.sourceFile, recipe: rawRecipe)
        let configured = try #require(inspection["configured"] as? [String: Any])
        #expect(rawRecipe.sharpnessAmount == 0)
        #expect(rawRecipe.baselineSharpness == baseline)
        if configured["sharpness_supported"] as? Bool == true {
            #expect((configured["sharpness_amount"] as? NSNumber)?.floatValue == 0)
        }
        #expect(try JSONDecoder().decode(RAWDecodeRecipe.self, from: JSONEncoder().encode(rawRecipe)) == rawRecipe)
    }
    @Test(arguments: 0..<3)
    func rawRetry_preservesDecodedPixelsAndPolicy(index: Int) throws {
        let source = try BaselineInputs.source(index)
        let input = try ImagePipeline.load(data: Data(contentsOf: source), fileExtension: "dng")
        let first = try ImagePipeline.process(resources: TestResources.colors, input, recipe: .standard)
        let retried = try ImagePipeline.process(resources: TestResources.colors, first.source, recipe: .standard)
        #expect(retried.source.rawDecode == first.source.rawDecode)
        #expect(retried.source.linearRGB == first.source.linearRGB)
    }
    @Test(arguments: 0..<3)
    func cameraOutput_usesFullDecodedSourceAndDeclaredPolicy(index: Int) throws {
        let source = try BaselineInputs.source(index)
        let input = try ImagePipeline.load(data: Data(contentsOf: source), fileExtension: "dng")
        let processed = try ImagePipeline.process(resources: TestResources.colors, input, recipe: .standard)
        let nativeURL = try BaselineInputs.output("raw-\(index)-native.heic")
        try ImagePipeline.writeHEIF(resources: TestResources.colors, processed, to: nativeURL)
        let nativeSource = try #require(CGImageSourceCreateWithURL(nativeURL as CFURL, nil))
        let nativeProperties = try #require(CGImageSourceCopyPropertiesAtIndex(nativeSource, 0, nil) as? [String: Any])
        let width = try #require(nativeProperties[kCGImagePropertyPixelWidth as String] as? NSNumber).intValue
        let height = try #require(nativeProperties[kCGImagePropertyPixelHeight as String] as? NSNumber).intValue
        let settings = ExportSettings.camera24(framing: CaptureFraming(cameraID: "offline-RAW-fixture", nativePixelCount: width * height, deliveredWidth: width, deliveredHeight: height))
        let url = try BaselineInputs.output("raw-\(index)-camera-24.heic")
        var reported: [Int]?
        try ImagePipeline.writeHEIF(resources: TestResources.colors, sourceFile: processed.source.sourceFile, recipe: processed.recipe, to: url,
            settings: settings, rawDecode: processed.source.rawDecode, onSourceDimensions: { reported = [$0, $1] })
        let encoded = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [String: Any])
        let expected = try settings.dimensions(sourceWidth: width, sourceHeight: height, crop: processed.recipe.crop)
        #expect(reported == [width, height])
        #expect((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == expected.width)
        #expect((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == expected.height)
        #expect((properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10)
        if expected.width == width && expected.height == height { #expect(try Data(contentsOf: url) == Data(contentsOf: nativeURL)) }
        try BaselineInputs.reportHash(url)
    }
    @Test(arguments: 0..<3)
    func rawNativeExport_preservesSensorExtentAndTenBitHDR(index: Int) throws {
        let source = try BaselineInputs.source(index)
        let input = try ImagePipeline.load(data: Data(contentsOf: source), fileExtension: "dng")
        let processed = try ImagePipeline.process(resources: TestResources.colors, input, recipe: .standard)
        let url = try BaselineInputs.output("raw-\(index)-hdr.heic")
        try ImagePipeline.writeHEIF(resources: TestResources.colors, processed, to: url)
        let filter = try #require(CIRAWFilter(imageURL: source))
        let encoded = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [String: Any])
        let image = try #require(CIImage(contentsOf: url, options: [.expandToHDR: true]))
        let actualSize = [Int(image.extent.width), Int(image.extent.height)].sorted()
        #expect(actualSize == [Int(filter.nativeSize.width), Int(filter.nativeSize.height)].sorted())
        #expect((properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10)
        #expect(image.colorSpace?.isHDR() == true)
        let maximum = ImagePipelineTests.pixels(image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)]))
        #expect(maximum.allSatisfy { $0.isFinite })
        #expect(try #require(maximum.max()) > 1)
        try BaselineInputs.reportHash(url)
    }
}
