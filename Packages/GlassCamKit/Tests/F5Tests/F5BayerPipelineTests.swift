import Testing
import Foundation
import ImageIO
import GlassCamTestSupport
@testable import F5
@testable import Capture
@testable import ImagingCore

@Suite(.serialized)
struct F5BayerPipelineTests {
    private func render(_ quality: CaptureQuality, _ mode: ColorMode) throws -> CaptureRenderResult {
        let work = try TestDirectory()
        let fixture = try F5Fixtures.make(directory: work.url, width: 32, height: 24,
            additionalDNGTags: [F5Fixtures.rationals(50729,[0.44757,0.40745]),
                F5Fixtures.rationals(50730,[1],signed: true), F5Fixtures.rationals(50732,[1.5])], quality: quality)
        let recipe = ProcessingRecipe(mode: mode, exposureEV: 0.7, illuminantKelvin: 6500,
            simulationIndex: 0, seed: 0, hncs: .standard, effects: .init(applyGrain: false,applySharpness: false))
        let snapshot = CaptureSnapshot(recipe: recipe, output: .camera(48), quality: quality)
        return try F5ImagePipeline.render(resources: TestResources.colors, fixture.source, snapshot: snapshot,
            progress: { _ in }, isCancelled: { false }, shaderURL: F5TestContext.shader)
    }

    @Test(arguments: [CaptureQuality.speed,.balanced], ColorMode.allCases)
    func bayerModes_exportEveryColorEngineWithSourceMetadata(quality: CaptureQuality, mode: ColorMode) throws {
        let result = try render(quality,mode)

        let white = try #require(result.snapshot.recipe.photoWhiteBalance)
        #expect(result.snapshot.quality == quality)
        #expect(abs(white.x - 0.44757) < 1e-6)
        #expect(abs(white.y - 0.40745) < 1e-6)
        #expect(result.snapshot.recipe.exposureEV == 0.7)
        if mode == .lumix { #expect(result.snapshot.recipe.lumix.sourceISO == 100) }
    }

    @Test(arguments: [CaptureQuality.speed,.balanced], ColorMode.allCases)
    func bayerHEIF_keepsTenBitAndActualExposureISO(quality: CaptureQuality, mode: ColorMode) throws {
        let result = try render(quality,mode)

        let container = try #require(CGImageSourceCreateWithURL(result.file.url as CFURL,nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(container,0,nil) as? [String:Any])
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String:Any])
        #expect((properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10)
        #expect((exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue == 0.008)
        #expect((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue == 100)
    }

    @Test(arguments: [CaptureQuality.speed,.balanced])
    func baselineExposure_scalesLinearOutputExactlyOnce(quality: CaptureQuality) throws {
        let plain = try TestDirectory(), exposed = try TestDirectory()
        let a = try F5Fixtures.make(directory: plain.url, width: 32, height: 24, quality: quality)
        let b = try F5Fixtures.make(directory: exposed.url, width: 32, height: 24,
            additionalDNGTags: [F5Fixtures.rationals(50730,[1],signed: true)], quality: quality)

        let first = try F5Reconstructor.reconstruct(a.source, shaderURL: F5TestContext.shader)
        let second = try F5Reconstructor.reconstruct(b.source, shaderURL: F5TestContext.shader)

        let data = try first.raster.mappedData(expectedBytes: first.width * first.height * 16)
        let scaled = try second.raster.mappedData(expectedBytes: second.width * second.height * 16)
        let maximum = data.withUnsafeBytes { a in scaled.withUnsafeBytes { b in
            let lhs = a.bindMemory(to: SIMD4<Float>.self), rhs = b.bindMemory(to: SIMD4<Float>.self)
            return lhs.indices.reduce(Float(0)) { value, i in
                max(value,abs(rhs[i].x - 2 * lhs[i].x),abs(rhs[i].y - 2 * lhs[i].y),abs(rhs[i].z - 2 * lhs[i].z))
            }
        } }
        // One matrix multiply in FP32, with no sensor-WB or exposure re-decode.
        #expect(maximum < 2e-6)
        #expect(first.width == (quality == .speed ? 32 : 64))
        #expect(second.quality.actualFrameCount == quality.bayerFrameCount)
    }

    @Test func warmNeutral_cameraMatrixBalancesWhiteWithoutSecondSensorWB() throws {
        let context = try F5TestContext()
        let data = try F5Fixtures.makeDNG(width: 10,height: 8,active: .init(top: 1,left: 1,bottom: 7,right: 9),
            pixels: [UInt16](repeating: 10000,count: 80),exposure: 0.008,
            overrides: [F5Fixtures.rationals(50729,[0.44757,0.40745])])
        let metadata = try F5DNGMetadata.read(data)

        let color = try F5ColorBridge.rendering(metadata: metadata,profile: context.fixture.profile)

        let xyz = try F5ColorBridge.xyz([0.44757,0.40745])
        let neutral = xyz.map { $0 / xyz.max()! * 0.18 }
        let balanced = color.cameraToLinearSRGB.apply(neutral)
        #expect((balanced.max()! - balanced.min()!) < 2e-5)
        #expect(color.whiteBalanceOwner == "matrix")
    }
}
