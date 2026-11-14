import Testing
import CoreImage
import Metal
import QuartzCore
@testable import ImagingCore

struct PreviewDisplayTests {
    func raster(_ value: Float, width: Int = 8) throws -> PreviewRaster {
        var rgba = [Float](repeating: value, count: width * 8 * 4)
        for alpha in stride(from: 3, to: rgba.count, by: 4) { rgba[alpha] = 1 }
        return try PreviewRaster(linearRGBA: rgba, width: width, height: 8)
    }
    @Test(arguments: [(Float(8), Float(8)), (2, 2), (0.5, 1)])
    func displayedPhoto_headroomMatchesActualPixels(value: (Float, Float)) throws {
        let image = try raster(value.0)
        #expect(PreviewDisplay.headroom(source: image, processed: nil, comparisonFraction: nil) == value.1)
    }
    @Test(arguments: [Float(8), 2, 1])
    func replacingHDRPhoto_updatesLayerRangeAndToneMapping(headroom: Float) throws {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.drawableSize = CGSize(width: 8, height: 8)
        PreviewDisplay.configure(layer, headroom: 8)

        PreviewDisplay.configure(layer, headroom: headroom)

        #expect(layer.wantsExtendedDynamicRangeContent == (headroom > 1))
        #expect(layer.contentsHeadroom == CGFloat(headroom))
        #expect(layer.preferredDynamicRange == .high)
        #expect(layer.toneMapMode == .ifSupported)
        #expect(layer.nextDrawable()?.texture.pixelFormat == .rgba16Float)
    }
    @Test(arguments: [(Optional<CGFloat>.none, Float(2)), (0, 8), (1, 2), (0.5, 8)])
    func comparisonHeadroom_usesOnlyVisibleInputs(input: (CGFloat?, Float)) throws {
        let original = try raster(8), result = try raster(2)
        #expect(PreviewDisplay.headroom(source: original, processed: result, comparisonFraction: input.0) == input.1)
    }
    @Test func mismatchedComparison_cannotRaiseSourceHeadroom() throws {
        #expect(PreviewDisplay.headroom(source: try raster(0.5), processed: try raster(8, width: 4), comparisonFraction: nil) == 1)
    }
    @Test func configuringDisplay_doesNotChangeOwnedFloatPixels() throws {
        let image = try raster(8)
        let before = ImagePipelineTests.pixels(image.image)
        PreviewDisplay.configure(CAMetalLayer(), headroom: PreviewDisplay.headroom(source: image, processed: nil, comparisonFraction: nil))
        #expect(ImagePipelineTests.pixels(image.image) == before)
    }

    @Test func dataBackedPreview_ownsItsPixelsAndExcludesAlphaFromHeadroom() throws {
        let pixels: [Float] = [-0.25, 2, 4, 8]
        var data = pixels.withUnsafeBytes { Data($0) }
        let image = try PreviewRaster(linearRGBAData: data, width: 1, height: 1)
        let before = ImagePipelineTests.pixels(image.image)

        data.resetBytes(in: 0..<data.count)

        #expect(image.headroom == 4)
        #expect(ImagePipelineTests.pixels(image.image) == before)
    }

    @Test(arguments: [0, 1, 2, 3])
    func nonfiniteComponent_rejectsDataBackedPreview(channel: Int) {
        var pixels: [Float] = [1, 2, 4, 1]
        pixels[channel] = .nan
        let data = pixels.withUnsafeBytes { Data($0) }

        #expect(throws: PipelineError.self) { try PreviewRaster(linearRGBAData: data, width: 1, height: 1) }
    }
}
