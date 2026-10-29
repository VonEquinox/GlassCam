import Testing
import Foundation
import CoreImage
import ImageIO
@testable import ImagingCore
import GlassCamTestSupport

struct ColorChainFixture {
    let work: TestDirectory
    let width = 33, height = 131
    let retained: SourceImageFile
    let decoded: [Float]
    init() throws {
        let work = try TestDirectory()
        let context = ImagePipelineTests.context, linear = ImagePipelineTests.linear, pixels = ImagePipelineTests.pixels
        let width = 33, height = 131
        let colors: [[Float]] = [[0,0,0], [0.001,0.002,0.003], [0.18,0.18,0.18], [1,1,1], [2,2,2],
            [4,1,0.2], [0.1,3,0.2], [0.2,0.1,2], [1,0.2,0.01], [0.02,0.3,1], [8,4,2]]
        let data: [Float] = (0..<(width*height)).flatMap { colors[$0 % colors.count]+[Float(1)] }
        let sourceURL = work.url.appendingPathComponent("exposure.tiff")
        let raster = try PreviewRaster(linearRGBA: data, width: width, height: height)
        try context.writeTIFFRepresentation(of: raster.image, to: sourceURL, format: .RGBAf, colorSpace: linear, options: [:])
        let retained = try SourceImageFile(data: Data(contentsOf: sourceURL), fileExtension: "tiff")
        // Use full-source decoded floats, independent of ImageIO thumbnails.
        let decoded = pixels(CIImage(contentsOf: sourceURL, options: [.expandToHDR: true])!)

        self.work = work; self.retained = retained; self.decoded = decoded
    }
        func input(_ values: [Float]) throws -> ImportedImage {
            ImportedImage(sourceFile: retained, exportSettings: .native,
                linearRGB: (0..<(width*height)).flatMap { Array(values[($0*4)..<($0*4+3)]) },
                width: width, height: height,
                original: try PreviewRaster(linearRGBA: values, width: width, height: height), sourceDescription: "Audit")
        }

    func source() throws -> ImportedImage { try input(decoded) }
}

@Suite(.serialized) struct ColorChainTests {
    static let resources = TestResources.colors
    static let pixels = ImagePipelineTests.pixels
    // Pre-migration Float32 color-chain and HEIF codec tolerances.
    static let floatTolerance: Float = 0.00001
    static func recipe(_ mode: ColorMode, _ ev: Double, revision: Int = ProcessingRecipe.currentPipelineRevision,
                       spatial: Bool = false, white: PhotoWhiteBalance? = nil) -> ProcessingRecipe {
        ProcessingRecipe(mode: mode, exposureEV: ev, illuminantKelvin: white?.modelKelvin ?? 6500,
            simulationIndex: 0, seed: 0, hncs: .standard,
            effects: EffectToggles(applyGrain: spatial, applySharpness: spatial),
            ffcs: FFCSSettings(applyReferenceAdjustments: spatial), photoWhiteBalance: white, pipelineRevision: revision)
    }
    @Test(arguments: ColorMode.allCases, [-2.0, -1.0, -0.3, 0, 0.7, 1, 2])
    static func exposure_matchesScalingSceneLinearSource(mode: ColorMode, ev: Double) throws {
        let fixture = try ColorChainFixture()
        let result = try ImagePipeline.process(resources: resources, fixture.source(), recipe: recipe(mode, ev))
        var scaled = fixture.decoded
        for pixel in 0..<(fixture.width * fixture.height) { for channel in 0..<3 { scaled[pixel * 4 + channel] *= Float(exp2(ev)) } }
        let expected = try ImagePipeline.process(resources: resources, fixture.input(scaled), recipe: recipe(mode, 0))
        let maximumError = try ImagePipelineTests.error(pixels(result.image.image), pixels(expected.image.image))
        #expect(maximumError <= floatTolerance)
    }
    private struct Golden: Decodable {
        struct Row: Decodable { let mode: ColorMode; let exposureEV: Double; let gray2: [Float]; let saturated: [Float] }
        let cases: [Row]
    }
    @Test(arguments: ColorMode.allCases, [-2.0, -1.0, 0, 1, 2])
    static func unversionedRecipe_replaysFrozenExposureGolden(mode: ColorMode, ev: Double) throws {
        let fixture = try ColorChainFixture()
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: TestResources.fixtures.appendingPathComponent("color-pipeline/color-pipeline-v1-exposure.json")))
        let row = try #require(golden.cases.first { $0.mode == mode && $0.exposureEV == ev })
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe(mode, ev))) as? [String: Any])
        object.removeValue(forKey: "pipelineRevision")
        let legacy = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONSerialization.data(withJSONObject: object))
        let output = try ImagePipeline.process(resources: resources, fixture.source(), recipe: legacy)
        let values = pixels(output.image.image)
        #expect(output.recipe.pipelineRevision == 1)
        #expect(try ImagePipelineTests.error(Array(values[16..<19]), row.gray2) < floatTolerance)
        #expect(try ImagePipelineTests.error(Array(values[20..<23]), row.saturated) < floatTolerance)
    }
    @Test(arguments: ColorMode.allCases.flatMap { mode in [false, true].flatMap { spatial in [-1.0, 1.0].map { (mode, spatial, $0) } } })
    static func spatialStripExport_matchesWholeImageAndDirectBytes(scenario: (ColorMode, Bool, Double)) throws {
        let (mode, spatial, ev) = scenario
        let fixture = try ColorChainFixture()
        let width = fixture.width, height = fixture.height, decoded = fixture.decoded, retained = fixture.retained, directory = fixture.work.url
                    let target = recipe(mode, ev, spatial: spatial)
                    let processed = try ImagePipeline.process(resources: resources, fixture.source(), recipe: target)
                    var scaled = decoded
                    for p in 0..<(width*height) { for c in 0..<3 { scaled[p*4+c] *= Float(exp2(ev)) } }
                    let oracle = try ImagePipeline.process(resources: resources, fixture.input(scaled), recipe: recipe(mode, 0, spatial: spatial))
                    #expect(try ImagePipelineTests.error(pixels(processed.image.image), pixels(oracle.image.image)) < floatTolerance, "\(mode) spatial exposure differs from scaling the source")
                    let stem = "\(mode.rawValue)-\(spatial)-\(ev)"
                    let output = directory.appendingPathComponent(stem+".heic")
                    let direct = directory.appendingPathComponent(stem+"-direct.heic")
                    try ImagePipeline.writeHEIF(resources: resources, processed, to: output)
                    let bound = try ImagePipeline.writeHEIF(resources: resources, sourceFile: retained, recipe: target, to: direct, settings: .native)
                    let outputData = try Data(contentsOf: output), directData = try Data(contentsOf: direct)
                    #expect(outputData == directData, "\(stem) direct and previewed full-source exports differ")
                    #expect(bound == processed.recipe, "\(stem) direct and previewed full-source exports differ")
                    let fullReference = directory.appendingPathComponent(stem+"-whole.heic")
                    let targetContext = target.usesExtendedHNCSWorkingDomain
                        ? ImagePipelineTests.targetContext : ImagePipelineTests.context
                    var expected = oracle.image.image.applyingFilter("CIColorClamp", parameters: [
                        "inputMinComponents": CIVector(x: 0,y: 0,z: 0,w: 1),
                        "inputMaxComponents": CIVector(x: CGFloat(ImagePipeline.maximumHDRValue), y: CGFloat(ImagePipeline.maximumHDRValue),
                                                        z: CGFloat(ImagePipeline.maximumHDRValue), w: 1)]).cropped(to: oracle.image.image.extent)
                    if #available(macOS 26, *) { expected = expected.settingContentHeadroom(oracle.image.headroom) }
                    try targetContext.writeHEIF10Representation(of: expected, to: fullReference,
                        colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!,
                        options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0])
                    let stripError = try HDRColorMetric.maximum(reference: CIImage(contentsOf: fullReference, options: [.expandToHDR: true])!,
                        actual: CIImage(contentsOf: output, options: [.expandToHDR: true])!)
                    #expect(stripError < HDRColorMetric.encodedMaximum)
    }
}
