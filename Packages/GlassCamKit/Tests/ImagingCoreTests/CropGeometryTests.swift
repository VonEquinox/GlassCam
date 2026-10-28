import Testing
import CoreGraphics
@testable import ImagingCore
import GlassCamTestSupport

struct CropGeometryTests {
    @Test(arguments: [(7,10,[0,1,7,2]),(10,7,[1,0,7,0]),(8,11,[0,1,8,2]),(1,1,[0,0,1,0]),(1,4,[0,1,1,2])])
    func oddAndEvenSquareCrop_keepsTopLeftPixelConvention(example: (Int,Int,[Int])) throws {
        let crop = try ImageCrop.centeredSquare.resolve(width: example.0,height: example.1)
        #expect([crop.x,crop.top,crop.width,crop.ciY] == example.2)
        #expect(crop.height == crop.width)
    }
    @Test(arguments: 1...16,1...16)
    func squareCrop_isContainedAndCenteredWithRemainderAtFarEdge(width: Int,height: Int) throws {
        let crop = try ImageCrop.centeredSquare.resolve(width: width,height: height)
        let right = width-crop.x-crop.width, bottom = height-crop.top-crop.height
        #expect(CGRect(x:0,y:0,width:width,height:height).contains(crop.ciRect))
        #expect((0...1).contains(right-crop.x))
        #expect((0...1).contains(bottom-crop.top))
    }
    @Test func explicitOutput_rotatesToSourceBeforeSquareCrop() throws {
        let selected = ExportSettings(targetWidth: 6,targetHeight: 4)
        let output = try selected.dimensions(sourceWidth: 8,sourceHeight: 12,crop: .centeredSquare)
        #expect(output.width == 4)
        #expect(output.height == 4)
    }
    @Test(arguments: [ExportSettings(targetWidth: 24,targetHeight: 16),ExportSettings(targetWidth: 8,targetHeight: 8),ExportSettings(targetWidth: 6,targetHeight: nil)])
    func squareCrop_cannotHideInvalidExplicitOutput(settings: ExportSettings) {
        #expect(throws: PipelineError.unsupportedOutput) {
            try settings.dimensions(sourceWidth: 12,sourceHeight: 8,crop: .centeredSquare)
        }
    }
    @Test(arguments: [(7,10),(10,7),(1,1)])
    func nativeSquareOutput_preservesTrueShortEdgeWithoutUpsampling(size: (Int,Int)) throws {
        let output = try ExportSettings.native.dimensions(sourceWidth: size.0,sourceHeight: size.1,crop: .centeredSquare)
        #expect(output.width == min(size.0,size.1))
        #expect(output.height == output.width)
    }
    @Test func disablingHistoricalCrop_restoresFullComparisonPixels() throws {
        let work = try TestDirectory()
        let input = try ImagePipelineTests.fixture(work.url,width: 7,height: 10)
        var settings = HNCSSettings.standard; settings.presetKey = "square-crop"
        let recipe = ProcessingRecipe(mode: .hncs,exposureEV: 0,illuminantKelvin: 6500,simulationIndex: 0,seed: 0,
                                      hncs: settings,effects: .init(applyGrain: false,applySharpness: false,applyExtraCrop: false))
        let output = try ImagePipeline.process(resources: TestResources.colors,input,recipe: recipe)
        let expected: [Float] = stride(from:0,to:input.linearRGB.count,by:3).flatMap { offset in
            Array(input.linearRGB[offset..<(offset+3)]) + [Float(1)]
        }
        // Existing Float32 bitmap roundtrip tolerance; no codec is involved.
        let floatRoundtripTolerance: Float = 1e-6
        #expect(output.comparisonSource.width == input.width)
        #expect(output.comparisonSource.height == input.height)
        #expect(try ImagePipelineTests.error(ImagePipelineTests.pixels(output.comparisonSource.image),expected) < floatRoundtripTolerance)
    }
    @Test func enablingAbsentGrain_preservesStandardPixelsAndPreset() throws {
        let settings = HNCSSettings.standard
        let input: [Float] = (0..<7*9*3).map { Float($0%37)/40 }
        let disabled = try HNCSEngine.exportLinearRGBA(linearSRGB:input,width:7,height:9,exposureEV:0,illuminantKelvin:6500,
            settings:settings,effects:.init(applyGrain:false,applySharpness:false))
        let enabled = try HNCSEngine.exportLinearRGBA(linearSRGB:input,width:7,height:9,exposureEV:0,illuminantKelvin:6500,
            settings:settings,effects:.init(applyGrain:true,applySharpness:false))
        #expect(enabled == disabled)
        #expect(settings == .standard)
    }
}
