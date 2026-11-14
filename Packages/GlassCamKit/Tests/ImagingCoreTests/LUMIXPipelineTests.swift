import Testing
import Foundation
import CoreImage
import ImageIO
@testable import ImagingCore
@testable import Capture
import GlassCamTestSupport

private struct LUMIXFixture {
    static let width = 33, height = 131
    let work: TestDirectory
    let retained: SourceImageFile
    let input: ImportedImage
    let full: ImportedImage
    let fullRGBA: [Float]
    init() throws {
        let work = try TestDirectory()
        let linear = ImagePipelineTests.linear, context = ImagePipelineTests.context
        let pixels = ImagePipelineTests.pixels
        // An image taller than two export strips, with saturated colors and >1 headroom.
        let width = Self.width, height = Self.height
        var rgba = [Float](repeating: 1, count: width*height*4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y*width+x)*4
            rgba[offset] = 0.08 + Float(x)/Float(width-1)*2.4
            rgba[offset+1] = 0.08 + Float(y)/Float(height-1)*2.4
            rgba[offset+2] = 0.12 + Float((x+y)%11)/10*2
        } }
        let sourceRaster = try PreviewRaster(linearRGBA: rgba, width: width, height: height)
        let sourceURL = work.url.appendingPathComponent("source.tiff")
        try context.writeTIFFRepresentation(of: sourceRaster.image, to: sourceURL, format: .RGBAf,
                                            colorSpace: linear, options: [:])
        let retained = try SourceImageFile(data: Data(contentsOf: sourceURL), fileExtension: "tiff")
        let input = ImportedImage(sourceFile: retained, exportSettings: .native,
            linearRGB: (0..<(width*height)).flatMap { Array(rgba[($0*4)..<($0*4+3)]) },
            width: width, height: height, original: sourceRaster, sourceDescription: "Float32 HDR fixture")
        // Full-source export must be compared against full-source decoded pixels.
        // The preview's ImageIO thumbnail decoder can produce different HDR chroma.
        let decoded = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true, .expandToHDR: true])!
        let fullRGBA = pixels(decoded)
        let full = ImportedImage(sourceFile: input.sourceFile, exportSettings: .native,
            linearRGB: (0..<(width*height)).flatMap { Array(fullRGBA[($0*4)..<($0*4+3)]) },
            width: width, height: height, original: try PreviewRaster(linearRGBA: fullRGBA, width: width, height: height),
            sourceDescription: "Full-source HDR oracle")

        self.work = work; self.retained = retained; self.input = input; self.full = full; self.fullRGBA = fullRGBA
    }
    func floatInput(_ values: [Float], width: Int, height: Int) throws -> ImportedImage {
        ImportedImage(sourceFile: retained, exportSettings: .native,
            linearRGB: (0..<(width*height)).flatMap { Array(values[($0*4)..<($0*4+3)]) },
            width: width, height: height, original: try PreviewRaster(linearRGBA: values, width: width, height: height),
            sourceDescription: "Exposure fixture")
    }
}

@Suite(.serialized) struct LUMIXPipelineTests {
    static let resources = TestResources.colors
    static let pixels = ImagePipelineTests.pixels
    static let context = ImagePipelineTests.context
    static let pq = ImagePipelineTests.pq
    static func lumixRecipe(_ settings: LUMIXSettings = .standard, ev: Double = 0,
                            pipelineRevision: Int = ProcessingRecipe.currentPipelineRevision) -> ProcessingRecipe {
        ProcessingRecipe(mode: .lumix, exposureEV: ev, illuminantKelvin: 6500, simulationIndex: 0,
            seed: 0, hncs: .standard, lumix: settings, pipelineRevision: pipelineRevision)
    }
    @Test(arguments: LUMIXEngine.looks.map(\.id))
    static func selectedPhotoStyle_preservesRecipeWhitePointAndHDR(style: String) throws {
        let fixture = try LUMIXFixture(), input = fixture.input
            let recipe = ProcessingRecipe(mode: .lumix, exposureEV: 0, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 0, hncs: .standard, lumix: LUMIXSettings(photoStyle: style))
            #expect(recipe.isValid, "Invalid listed LUMIX recipe")
            let processed = try ImagePipeline.process(resources: resources, input, recipe: recipe)
            #expect(processed.recipe.mode == .lumix, "The rendered recipe lost the selected Photo Style")
            #expect(processed.recipe.lumix.photoStyle == style, "The rendered recipe lost the selected Photo Style")
            #expect(processed.recipe.photoWhiteBalance == input.whiteBalance, "LUMIX changed the photo white point or framing")
            #expect(processed.recipe.crop == .none, "LUMIX changed the photo white point or framing")
            let values = pixels(processed.image.image)
            #expect(values.allSatisfy { $0.isFinite }, "LUMIX preview is invalid or clipped HDR headroom")
            #expect((values.max() ?? 0) > 1, "LUMIX preview is invalid or clipped HDR headroom")
    }
    @Test(arguments: ["standard", "l-monochrome"])
    static func stripHEIF_matchesFullFrameAndDirectExport(style: String) throws {
        let fixture = try LUMIXFixture(), input = fixture.input, full = fixture.full, directory = fixture.work.url
        let width = LUMIXFixture.width, height = LUMIXFixture.height
        let recipe = lumixRecipe(LUMIXSettings(photoStyle: style))
        let processed = try ImagePipeline.process(resources: resources, input, recipe: recipe)
                let output = directory.appendingPathComponent(style+".heic")
                try ImagePipeline.writeHEIF(resources: resources, processed, to: output)
                guard let image = CIImage(contentsOf: output, options: [.expandToHDR: true]),
                      let container = CGImageSourceCreateWithURL(output as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any] else {
                    throw PipelineError.encoding
                }
                #expect(Int(image.extent.width) == width, "LUMIX full-source export changed dimensions")
                #expect(Int(image.extent.height) == height, "LUMIX full-source export changed dimensions")
                #expect((properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10, "LUMIX export lost 10-bit encoding")
                let actual = pixels(image)
                #expect((actual.max() ?? 0) > 1, "Export lost HDR pixels")
                #expect(actual.allSatisfy { $0.isFinite }, "Export lost HDR pixels")
                let oracle = try ImagePipeline.process(resources: resources, full, recipe: recipe)
                var expected = oracle.image.image
                if #available(macOS 26, *) { expected = expected.settingContentHeadroom(max(1, pixels(expected).max() ?? 1)) }
                let expectedURL = directory.appendingPathComponent(style+"-expected.heic")
                try context.writeHEIF10Representation(of: expected, to: expectedURL, colorSpace: pq,
                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0])
                let maximumError = try HDRColorMetric.maximum(reference: CIImage(contentsOf: expectedURL, options: [.expandToHDR: true])!, actual: image)
                #expect(maximumError < HDRColorMetric.encodedMaximum)
                let directURL = directory.appendingPathComponent(style+"-direct.heic")
                let directRecipe = try ImagePipeline.writeHEIF(resources: resources, sourceFile: input.sourceFile, recipe: recipe,
                    to: directURL, settings: .native)
                #expect(directRecipe == processed.recipe, "Skipping the preview changed the frozen LUMIX recipe: \(directRecipe) versus \(processed.recipe)")
                #expect(try Data(contentsOf: directURL) == Data(contentsOf: output))
    }
    @Test(arguments: ["standard", "l-monochrome"], [-2.0, -1.0, 1.0, 2.0])
    static func exposure_scalesSceneLinearHighlightsBeforeStripExport(style: String, ev: Double) throws {
        let fixture = try LUMIXFixture(), full = fixture.full, retained = fixture.retained, fullRGBA = fixture.fullRGBA
        let width = LUMIXFixture.width, height = LUMIXFixture.height, directory = fixture.work.url
                let recipe = lumixRecipe(LUMIXSettings(photoStyle: style), ev: ev)
                let actual = try ImagePipeline.process(resources: resources, full, recipe: recipe)
                var scaled = fullRGBA
                let scale = Float(exp2(ev))
                for pixel in 0..<(width*height) { for channel in 0..<3 { scaled[pixel*4+channel] *= scale } }
                let expected = try ImagePipeline.process(resources: resources, fixture.floatInput(scaled, width: width, height: height),
                    recipe: lumixRecipe(LUMIXSettings(photoStyle: style)))
                #expect(try ImagePipelineTests.error(pixels(actual.image.image), pixels(expected.image.image)) == 0, "LUMIX exposure clipped HDR magnitude or changed highlight color")
                let label = "\(style)-ev\(ev)"
                let output = directory.appendingPathComponent(label+".heic")
                let direct = directory.appendingPathComponent(label+"-direct.heic")
                let oracle = directory.appendingPathComponent(label+"-expected.heic")
                try ImagePipeline.writeHEIF(resources: resources, actual, to: output)
                _ = try ImagePipeline.writeHEIF(resources: resources, sourceFile: retained, recipe: recipe, to: direct, settings: .native)
                try context.writeHEIF10Representation(of: expected.image.image, to: oracle, colorSpace: pq,
                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0])
                #expect(try Data(contentsOf: output) == Data(contentsOf: direct))
                #expect(try HDRColorMetric.maximum(reference: CIImage(contentsOf: oracle, options: [.expandToHDR: true])!,
                    actual: CIImage(contentsOf: output, options: [.expandToHDR: true])!) < HDRColorMetric.encodedMaximum)
    }
    @Test static func standardAndVivid_produceDistinctPixels() throws {
        let fixture = try LUMIXFixture()
        let standard = try ImagePipeline.process(resources: resources, fixture.input, recipe: lumixRecipe())
        let vivid = try ImagePipeline.process(resources: resources, fixture.input, recipe: lumixRecipe(.init(photoStyle: "vivid")))
        #expect(try ImagePipelineTests.error(pixels(standard.image.image), pixels(vivid.image.image)) > 0.01)
    }
    @Test(arguments: [0.0, 1.0, 2.0])
    static func currentExposure_increasesSuperwhiteMagnitude(ev: Double) throws {
        let fixture = try LUMIXFixture()
        let bright = try fixture.floatInput([2, 2, 2, 1], width: 1, height: 1)
        let result = try ImagePipeline.process(resources: resources, bright, recipe: lumixRecipe(ev: ev))
        let expected = Float(2 * exp2(ev))
        let maximumError = pixels(result.image.image).prefix(3).map { abs($0 - expected) }.max() ?? .infinity
        // Original Float32 highlight tolerance.
        let tolerance: Float = 0.0001
        #expect(maximumError < tolerance)
    }
    @Test(arguments: [0.0, 1.0, 2.0])
    static func savedV2Exposure_replaysOriginalSuperwhiteMagnitude(ev: Double) throws {
        let fixture = try LUMIXFixture()
        let bright = try fixture.floatInput([2, 2, 2, 1], width: 1, height: 1)
        let v2 = try JSONDecoder().decode(LUMIXSettings.self, from: Data(#"{"photoStyle":"standard","renderRevision":2}"#.utf8))
        let result = try ImagePipeline.process(resources: resources, bright, recipe: lumixRecipe(v2, ev: ev, pipelineRevision: 1))
        #expect(v2.isValid)
        #expect(Array(pixels(result.image.image).prefix(3)) == [2, 2, 2])
    }
    @Test static func adjustedRecipe_roundtripKeepsCCTISOAndLookControls() throws {
        var adjusted = LUMIXSettings(photoStyle: "standard", contrast: 1.5, saturation: -2)
        adjusted.sourceISO = 64
        let recipe = ProcessingRecipe(mode: .lumix, exposureEV: 0, illuminantKelvin: 4000, simulationIndex: 0, seed: 0, hncs: .standard, lumix: adjusted)
        #expect(try JSONDecoder().decode(ProcessingRecipe.self, from: JSONEncoder().encode(recipe)) == recipe)
        #expect(recipe.resolvingLUMIXSourceISO(80).lumix.sourceISO == 64)
    }
    @Test static func captureISO_bindsWithoutInheritingHNCSDecoderOverride() {
        let recipe = lumixRecipe().resolvingLUMIXSourceISO(80)
        let resolved = recipe.sourceDecodeRecipe(RAWDecodeRecipe.current.withoutDecoderSharpness)
        #expect(recipe.lumix.sourceISO == 80)
        #expect(resolved.rendering == .cameraNeutral)
        #expect(resolved.sharpnessAmount == nil)
    }
    @Test(arguments: ["photoStyle", "contrast", "sourceISO"])
    static func invalidLookSettings_areRejected(field: String) {
        var settings = LUMIXSettings.standard
        switch field {
        case "photoStyle": settings.photoStyle = "not-a-real-look"
        case "contrast": settings.contrast = .nan
        default: settings.sourceISO = 0
        }
        #expect(!settings.isValid)
    }
    @Test static func savedV1Photo_doesNotAdoptISOCorrection() throws {
        let fixture = try LUMIXFixture()
        let v1 = try JSONDecoder().decode(LUMIXSettings.self, from: Data(#"{"photoStyle":"standard","renderRevision":1}"#.utf8))
        let recipe = lumixRecipe(v1)
        let result = try ImagePipeline.process(resources: resources, fixture.input, recipe: recipe)
        #expect(v1.isValid)
        #expect(v1.renderRevision == 1)
        #expect(recipe.resolvingLUMIXSourceISO(50).lumix == v1)
        #expect(result.recipe.lumix == v1)
    }
    @Test(arguments: [ColorMode.hncs, .ffcs])
    static func recipeWithoutLUMIX_preservesExistingEngine(mode: ColorMode) throws {
        let fixture = try LUMIXFixture()
        let old = ProcessingRecipe(mode: mode, exposureEV: 0, illuminantKelvin: 6500, simulationIndex: 0, seed: 0, hncs: .standard)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "lumix")
        let restored = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored == old)
        #expect(try ImagePipeline.process(resources: resources, fixture.input, recipe: restored).recipe.mode == mode)
    }
    @Test(arguments: ColorMode.allCases)
    static func absentInputPolicy_keepsLegacyPhotoSemanticsDuringMetadataBinding(mode: ColorMode) throws {
        let neutral = ProcessingRecipe(mode: mode, exposureEV: 0, illuminantKelvin: 6500, simulationIndex: 0, seed: 0, hncs: .standard)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(neutral)) as? [String: Any])
        object.removeValue(forKey: "rawInputPolicy")
        let old = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.rawInputPolicy == .legacy)
        #expect(neutral.rawInputPolicy == .cameraNeutral)
        #expect(old.resolvingWhiteBalance(.renderedD65).resolvingLUMIXSourceISO(80).rawInputPolicy == .legacy)
        #expect(neutral.sourceDecodeRecipe(.current).rendering == .cameraNeutral)
    }
}
