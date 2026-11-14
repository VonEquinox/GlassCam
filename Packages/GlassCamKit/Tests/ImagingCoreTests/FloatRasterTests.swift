import Testing
@testable import ImagingCore

struct FloatRasterTests {
    @Test func packing_preservesSignedHDRBitsAndSuppliesOpaqueAlpha() throws {
        let source: [Float] = [-0.0, -.leastNonzeroMagnitude, 8, 0.5, 1, -0.25]

        let rgba = try FloatRasterOperations.rgba(fromRGB: source)
        let restored = try FloatRasterOperations.rgb(fromRGBA: rgba)

        #expect(restored.map(\.bitPattern) == source.map(\.bitPattern))
        #expect([rgba[3], rgba[7]] == [1, 1])
    }

    @Test func normalization_appliesExposureOnceAndRetainsSignedChannels() throws {
        var pixels: [Float] = [-0.25, 2, 4, 0, 3, 1]

        let gains = try ImagePipeline.normalizeHighlights(&pixels, exposureEV: 1)

        #expect(gains == [8, 6])
        #expect(pixels == [-0.0625, 0.5, 1, 0, 1, 1 / 3])
    }

    @Test func restoration_clampsRGBAndPreservesAlpha() throws {
        var pixels: [Float] = [-0.25, 0.5, 1, 0.75]

        let peak = try ImagePipeline.restoreHighlights(&pixels, gains: [4])

        #expect(pixels == [0, 2, 4, 0.75])
        #expect(peak == 4)
    }

    @Test(arguments: [Float.nan, Float.infinity, -Float.infinity])
    func nonfiniteExposureInput_isRejected(value: Float) {
        var pixels: [Float] = [value, 0, 0]

        #expect(throws: PipelineError.self) {
            try ImagePipeline.applyExposure(&pixels, exposureEV: 1)
        }
    }

    @Test func mismatchedHighlightPlane_isRejected() {
        var pixels: [Float] = [1, 1, 1, 1]

        #expect(throws: PipelineError.self) {
            try ImagePipeline.restoreHighlights(&pixels, gains: [])
        }
    }

    @Test func restoration_preservesNegativeZeroAtTheFloatBoundary() throws {
        var pixels: [Float] = [-0.0, 0, 0, 1]

        try ImagePipeline.restoreHighlights(&pixels, gains: [2])

        #expect(pixels[0].bitPattern == Float(-0.0).bitPattern)
    }
}
