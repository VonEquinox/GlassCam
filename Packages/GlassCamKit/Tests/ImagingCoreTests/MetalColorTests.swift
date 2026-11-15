import Testing
@testable import ImagingCore
import GlassCamTestSupport
import NativeTestSupport
import CHNCS
import CMetalImage
import CoreImage
import Foundation

/// Approved final-photo budget, measured in BT.2124 Delta E ITP after the
/// same Core Image conversion to BT.2020/PQ. CPU goldens remain unchanged.
private enum HDRColorBudget {
    static let mean = 0.1, p95 = 0.25, p99 = 0.5, maximum = 1.0, peakRelative = 0.001
}

@Suite(.serialized) struct MetalColorTests {
    static let linear = ImagePipelineTests.linear
    static let context = ImagePipelineTests.context

    static func rgba(width: Int, height: Int) -> [Float] {
        var result = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let p = (y * width + x) * 4
            let gain: Float = y % 7 == 0 ? 8 : y % 3 == 0 ? 2 : 1
            result[p] = gain * Float((x * 17 + y * 31) % 257) / 256
            result[p + 1] = gain * Float((x * 43 + y * 7) % 257) / 256
            result[p + 2] = gain * Float((x * 11 + y * 47) % 257) / 256
        } }
        return result
    }
    static func image(_ rgba: [Float], width: Int, height: Int) -> CIImage {
        rgba.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linear) }
    }
    static func pq(_ rgba: [Float], width: Int, height: Int) -> [Float] {
        let source = image(rgba, width: width, height: height)
        var result = rgba
        result.withUnsafeMutableBytes {
            context.render(source, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: source.extent,
                           format: .RGBAf, colorSpace: ImagePipelineTests.pq)
        }
        return result
    }
    static func metrics(_ reference: [Float], _ actual: [Float], width: Int, height: Int) throws -> [Double] {
        let first = pq(reference, width: width, height: height), second = pq(actual, width: width, height: height)
        let state = try #require(hdr_metric_create())
        defer { hdr_metric_destroy(state) }
        let status = first.withUnsafeBufferPointer { a in second.withUnsafeBufferPointer { b in
            hdr_metric_add(state, a.baseAddress, b.baseAddress, width * height)
        } }
        try #require(status == 0)
        var result = [Double](repeating: 0, count: 12)
        try #require(hdr_metric_finish(state, &result, result.count) == 0)
        return result
    }
    static func checkBudget(_ values: [Double]) {
        #expect(values[2] <= HDRColorBudget.mean)
        #expect(values[3] <= HDRColorBudget.p95)
        #expect(values[4] <= HDRColorBudget.p99)
        #expect(values[5] < HDRColorBudget.maximum)
        #expect(abs(values[6] - values[7]) / max(values[6], 1) <= HDRColorBudget.peakRelative)
        checkClipping(values)
    }
    static func checkClipping(_ values: [Double]) {
        #expect(values[8] == 0)
        #expect(values[9] == 0)
    }
    static var recipes: [ProcessingRecipe] {
        let effects = EffectToggles(applyGrain: false, applySharpness: false)
        let hncs = HNCSEngine.cameraPresets.flatMap { preset in HNCSWorkingSpace.allCases.map { space in
            var settings = HNCSSettings.standard; settings.presetKey = preset.id; settings.workingSpace = space
            return ProcessingRecipe(mode: .hncs, exposureEV: 0.5, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 19, hncs: settings, effects: effects)
        }
        }
        let ffcs = FFCSEngine.simulations(resources: TestResources.colors, for: .xh2s).map { look in
            ProcessingRecipe(mode: .ffcs, exposureEV: -0.5, illuminantKelvin: 6500,
                simulationIndex: look.id, seed: 19, hncs: .standard, effects: effects)
        }
        let lumix = LUMIXEngine.looks.map { look in
            ProcessingRecipe(mode: .lumix, exposureEV: 0.5, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 19, hncs: .standard, effects: effects, lumix: .init(photoStyle: look.id))
        }
        return hncs + ffcs + lumix
    }

    static func finishedWork(_ work: [Float], width: Int, height: Int, recipe: ProcessingRecipe) throws -> [Float] {
        let scale = try HNCSEngine.workingScale(maximum: work.max() ?? 0)
        var normalized = work
        let status = recipe.hncs.presetKey.withCString { key in
            normalized.withUnsafeMutableBufferPointer {
                hncs_prepare_apple_hdr_spatial($0.baseAddress, width, height, key,
                    recipe.effects.applyGrain ? 1 : 0, recipe.effects.applySharpness ? 1 : 0, 0, scale)
            }
        }
        try #require(status == 0)
        return try HNCSEngine.finishPresetWork(normalized, width: width, height: height,
            exposureEV: recipe.backendExposureEV, captureKelvin: recipe.illuminantKelvin,
            settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance, workScale: scale)
    }

    @Test(arguments: recipes)
    static func pointwiseColor_staysWithinHDRBudget(recipe: ProcessingRecipe) throws {
        try checkColor(recipe)
    }

    static var lumixBoundaryRecipes: [ProcessingRecipe] {
        // CCT endpoints, the first selector quantization boundary, interior
        // node mixtures, all extreme formula combinations and source ISO.
        let controls: [(Double, Double, Double, Int, Double)] = [
            (3000, 0, 0, 50, -2), (4000, 0, 0, 64, 0.5), (5000, 0, 0, 80, 2),
            (4000, -5, -5, 100, 0.5), (4000, -5, 5, 50, 0.5),
            (4000, 5, -5, 64, 0.5), (4000, 5, 5, 80, 0.5),
            (3007.8124, 0.5, -0.5, 100, 0), (3007.8125, 0.5, -0.5, 100, 0),
            (4999.999, 1.5, -2, 100, 0)
        ]
        return LUMIXEngine.looks.flatMap { look in
            controls.map { kelvin, contrast, saturation, iso, exposure in
                var settings = LUMIXSettings(photoStyle: look.id, contrast: contrast, saturation: saturation)
                settings.sourceISO = iso
                return ProcessingRecipe(mode: .lumix, exposureEV: exposure, illuminantKelvin: kelvin,
                    simulationIndex: 0, seed: 19, hncs: .standard, lumix: settings)
            }
        }
    }

    @Test(arguments: lumixBoundaryRecipes)
    static func lumixTableAndControlBoundaries_stayWithinHDRBudget(recipe: ProcessingRecipe) throws {
        try checkColor(recipe)
    }

    @Test(arguments: LUMIXEngine.looks.map(\.id))
    static func lumixSignedGamutBoundaries_stayWithinHDRBudget(style: String) throws {
        let width = 131, height = 129
        var input = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let ramp = Float(x) / Float(width - 1)
            let gain: Float = [1, 2, 8][(y / 8) % 3]
            let values: [Float]
            switch y % 8 {
            case 0: values = [ramp, ramp, ramp]
            case 1: values = [ramp, 0, 0]
            case 2: values = [0, ramp, 0]
            case 3: values = [0, 0, ramp]
            case 4: values = [-0.25, ramp, 1]
            case 5: values = [1, -0.25, ramp]
            case 6: values = [ramp, 1, -0.25]
            default: values = [ramp, 0.95 * ramp, -0.0]
            }
            for channel in 0..<3 { input[(y * width + x) * 4 + channel] = values[channel] * gain }
        } }
        let settings = LUMIXSettings(photoStyle: style, contrast: 5, saturation: 5)
        let recipe = ProcessingRecipe(mode: .lumix, exposureEV: 0, illuminantKelvin: 4000,
            simulationIndex: 0, seed: 19, hncs: .standard, lumix: settings)

        try checkColor(recipe, width: width, height: height, input: input)
    }

    @Test static func concurrentLookChanges_preserveInFlightParameters() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for recipe in recipes {
                group.addTask { try checkColor(recipe) }
            }
            try await group.waitForAll()
        }
    }

    static func checkColor(_ recipe: ProcessingRecipe, width: Int = 127, height: Int = 131,
                           input suppliedInput: [Float]? = nil) throws {
        let pair = try colorPair(recipe, width: width, height: height, input: suppliedInput)
        checkBudget(try metrics(pair.reference, pair.actual, width: width, height: height))
    }

    static func colorPair(_ recipe: ProcessingRecipe, width: Int, height: Int,
                          input suppliedInput: [Float]?) throws -> (reference: [Float], actual: [Float]) {
        let input = suppliedInput ?? rgba(width: width, height: height)
        let source = image(input, width: width, height: height)
        let rendered = try #require(try MetalColorEngine.image(resources: TestResources.colors, source: source, recipe: recipe))
        // Match the CPU bitmap's top-down row order, independent of CIImage's
        // Cartesian coordinates and the initializer's storage convention.
        let sourcePixels = ImagePipelineTests.pixels(source)
        var rgb = (0..<(width * height)).flatMap { Array(sourcePixels[($0 * 4)..<($0 * 4 + 3)]) }
        let output = ImagePipelineTests.pixels(rendered)
        let expected: [Float], actual: [Float]
        if recipe.mode == .hncs {
            try ImagePipeline.applyExposure(&rgb, exposureEV: recipe.exposureEV)
            let work = try HNCSEngine.presetWork(linearSRGB: rgb, width: width, height: height,
                exposureEV: recipe.backendExposureEV, captureKelvin: recipe.illuminantKelvin,
                settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance)
            expected = try finishedWork(work, width: width, height: height, recipe: recipe)
            let file = try HNCSPresetWorkFile(width: width, height: height)
            _ = try HNCSEngine.renderWorkFile(rendered, context: context, to: file, recipe: recipe,
                                             isCancelled: { false }, progress: { _ in })
            actual = try finishedWork(file.readTopDownRows(originY: 0, rows: height), width: width, height: height, recipe: recipe)
        } else {
            let gains = try ImagePipeline.normalizeHighlights(&rgb, exposureEV: recipe.exposureEV)
            var reference: [Float]
            if recipe.mode == .ffcs {
                reference = try FFCSEngine.exportLinearRGBA(resources: TestResources.colors, linearSRGB: rgb,
                    width: width, height: height, exposureEV: recipe.backendExposureEV, simulationIndex: recipe.simulationIndex,
                    seed: recipe.seed, effects: recipe.effects, settings: recipe.ffcs)
            } else {
                reference = try LUMIXEngine.exportLinearRGBA(resources: TestResources.colors, linearSRGB: rgb,
                    width: width, height: height, exposureEV: recipe.backendExposureEV, settings: recipe.lumix,
                    illuminantKelvin: recipe.illuminantKelvin)
            }
            try ImagePipeline.restoreHighlights(&reference, gains: gains)
            expected = reference; actual = output
        }

        return (expected, actual)
    }

    @Test(arguments: recipes.filter { $0.mode != .hncs })
    static func grayRamp_doesNotAddReversals(recipe: ProcessingRecipe) throws {
        let width = 2049, height = 3
        let gains: [Float] = [1, 2, 8]
        let input: [Float] = (0..<(width * height)).flatMap { pixel in
            let value = Float(pixel % width) / Float(width - 1) * gains[pixel / width]
            return [value, value, value, 1]
        }
        let pair = try colorPair(recipe, width: width, height: height, input: input)
        func luminance(_ values: [Float], _ pixel: Int) -> Float {
            let p = pixel * 4
            return (values[p] * 0.2126 + values[p + 1] * 0.7152) + values[p + 2] * 0.0722
        }
        var addedReversals = 0
        for row in 0..<height { for column in 1..<width {
            let pixel = row * width + column
            let before = luminance(pair.actual, pixel - 1), after = luminance(pair.actual, pixel)
            // Bound only Float32 conversion and the three-term luma sum.
            let rounding = 8 * Float.ulpOfOne * max(1, max(abs(before), abs(after)))
            if luminance(pair.reference, pixel) >= luminance(pair.reference, pixel - 1),
               after < before - rounding {
                addedReversals += 1
            }
        } }

        #expect(addedReversals == 0)
    }

    @Test(arguments: ["standard", "nature", "portrait"], [1.0, 5.8829245141, 7.25])
    static func spatialGPU_matchesCPUIncludingTileBoundaries(preset: String, scale: Double) throws {
        let width = 161, height = 2081
        let input = (0..<(width * height)).flatMap { pixel -> [Float] in
            // Exercise half-way Float32 quantization and both adjacent values,
            // with all 16-bit code intervals represented across the image.
            let code = UInt32(truncatingIfNeeded: pixel) &* 1664525 &+ 1013904223
            let middle = (Float(code % 65535) + 0.5) / 65535
            let values = [middle.nextDown, middle, middle.nextUp]
            return scale == 1 ? values : values.map { $0 * Float(scale) * 0.9 }
        }
        var expected = input
        let status = preset.withCString { key in expected.withUnsafeMutableBufferPointer {
            hncs_prepare_apple_hdr_spatial($0.baseAddress, width, height, key, 0, 1, 0.75, scale)
        } }
        try #require(status == 0)
        let file = try HNCSPresetWorkFile(width: width, height: height)
        try file.writeTopDownRows(input, originY: 0, rows: height)
        try file.prepareForSpatialPass()
        let gpu = try #require(MetalSpatialEngine.shared.context, "\(MetalSpatialEngine.shared.initializationError)")

        let result = file.url.path.withCString { path in preset.withCString { key in
            gc_metal_spatial_prepare_file(gpu, path, width, height, key, 0, 1, 0.75, scale, nil, nil, nil)
        } }

        #expect(result == 0)
        let actual = try Data(contentsOf: file.url)
        #expect(actual == expected.withUnsafeBytes { Data($0) })
    }

    @Test static func nativeRenderer_preservesTopDownRowsAndTail() throws {
        let width = 521, height = 4111
        let source = image(rgba(width: width, height: height), width: width, height: height)
        let expected = ImagePipelineTests.pixels(source)
        let file = try ExportRasterFile()

        let maximum = try MetalColorEngine.render(source, context: context, to: file.url.path, components: 4,
                                                 isCancelled: { false }, progress: { _ in })

        #expect(try Data(contentsOf: file.url) == expected.withUnsafeBytes { Data($0) })
        #expect(maximum == expected.max())
    }

    @Test static func nativeFinishFile_matchesReferenceAcrossChunks() throws {
        let width = 257, height = 1027
        let source = rgba(width: width, height: height)
        let input = (0..<(width * height)).flatMap { pixel in (0..<3).map { source[pixel * 4 + $0] / 8 } }
        let recipe = ImagePipelineTests.recipe("nature")
        let scale = 5.8829245141
        let expected = try HNCSEngine.finishPresetWork(input, width: width, height: height,
            exposureEV: 0, captureKelvin: 6500, settings: recipe.hncs, effects: recipe.effects,
            whiteBalance: nil, workScale: scale)
        let work = try HNCSPresetWorkFile(width: width, height: height)
        try work.writeTopDownRows(input, originY: 0, rows: height)
        let output = try ExportRasterFile()

        let peak = try HNCSEngine.finishPresetWorkFile(work, to: output, recipe: recipe, workScale: scale,
            isCancelled: { false }, progress: { _ in })

        #expect(try Data(contentsOf: output.url) == expected.withUnsafeBytes { Data($0) })
        #expect(peak == expected.max())
    }

    @Test(arguments: [0, 1, 8], [0.1, 1.0, 5.0])
    static func ffcsNeighborhood_keepsImageCoordinatesAndCropHalo(look: Int, radius: Double) throws {
        let width = 83, height = 79
        let recipe = ProcessingRecipe(mode: .ffcs, exposureEV: -0.5, illuminantKelvin: 6500,
            simulationIndex: look, seed: 0xffffffff, hncs: .standard,
            ffcs: .init(applyReferenceAdjustments: true, sharpenRadius: radius))
        let source = image(rgba(width: width, height: height), width: width, height: height)
        let input = ImagePipelineTests.pixels(source)
        var rgb = (0..<(width * height)).flatMap { Array(input[($0 * 4)..<($0 * 4 + 3)]) }
        let gains = try ImagePipeline.normalizeHighlights(&rgb, exposureEV: recipe.exposureEV)
        var wholeReference = try FFCSEngine.exportLinearRGBA(resources: TestResources.colors, linearSRGB: rgb,
            width: width, height: height, exposureEV: 0, simulationIndex: look, seed: recipe.seed,
            effects: recipe.effects, settings: recipe.ffcs)
        try ImagePipeline.restoreHighlights(&wholeReference, gains: gains)
        let crop = CGRect(x: 7, y: 11, width: 61, height: 53)
        let firstRow = height - Int(crop.maxY), firstColumn = Int(crop.minX)
        let expected = (0..<Int(crop.height)).flatMap { row in
            let first = ((firstRow + row) * width + firstColumn) * 4
            return Array(wholeReference[first..<(first + Int(crop.width) * 4)])
        }

        let gpuImage = try #require(try MetalColorEngine.image(resources: TestResources.colors, source: source, recipe: recipe))
        let actual = ImagePipelineTests.pixels(gpuImage.cropped(to: crop))

        checkBudget(try metrics(expected, actual, width: Int(crop.width), height: Int(crop.height)))
    }

    @Test static func cancelledNativeRenderer_leavesEmptyDestination() throws {
        let source = image(rgba(width: 31, height: 37), width: 31, height: 37)
        let file = try ExportRasterFile()

        #expect(throws: CancellationError.self) {
            _ = try MetalColorEngine.render(source, context: context, to: file.url.path, components: 4,
                                           isCancelled: { true }, progress: { _ in })
        }
        #expect(try Data(contentsOf: file.url).isEmpty)
    }

    @Test(arguments: [ColorMode.ffcs, .lumix])
    static func nonfiniteSource_rejectsOutputBeforeLUTAccess(mode: ColorMode) throws {
        let source = image([.nan, 0.5, 0.25, 1], width: 1, height: 1)
        let recipe = ProcessingRecipe(mode: mode, exposureEV: 0, illuminantKelvin: 6500,
            simulationIndex: 0, seed: 0, hncs: .standard)
        let rendered = try #require(try MetalColorEngine.image(resources: TestResources.colors, source: source, recipe: recipe))
        let file = try ExportRasterFile()

        #expect(throws: (any Error).self) {
            _ = try MetalColorEngine.render(rendered, context: context, to: file.url.path, components: 4,
                                           isCancelled: { false }, progress: { _ in })
        }
        #expect(try Data(contentsOf: file.url).isEmpty)
    }
}
