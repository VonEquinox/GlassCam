import Foundation
import CoreImage
import ImageIO
import CMetalImage

extension ImagePipeline {
    static func applyExposure(_ rgb: inout [Float], exposureEV: Double) throws {
        guard exposureEV != 0 else { return }
        let scale = Float(exp2(exposureEV))
        let success = rgb.withUnsafeMutableBufferPointer { gc_float_scale($0.baseAddress, $0.count, scale) }
        guard success == 1 else { throw PipelineError.rendering }
    }

    public static func process(resources: ColorResources, _ input: ImportedImage, recipe: ProcessingRecipe) throws -> ProcessedImage {
        guard recipe.isValid else { throw HNCSEngine.Error.invalidSettings }
        var input = input
        let sourcePolicy = recipe.sourceDecodeRecipe(input.baseRAWDecode)
        let frozenWhite = recipe.photoWhiteBalance?.origin == .appleRAW ? recipe.photoWhiteBalance : nil
        if ["dng", "raw"].contains(input.sourceFile.fileExtension?.lowercased() ?? ""),
           sourcePolicy != input.rawDecode || (frozenWhite != nil && frozenWhite != input.whiteBalance) {
            // Re-decode for the selected engine's pinned RAW input policy and
            // retain that policy in ProcessedImage.source. Automatic capture
            // binds the same policy before any pixel decode.
            let previous = input
            input = try decodeQueue.sync {
                try autoreleasepool {
                    try decode(data: Data(contentsOf: previous.sourceFile.url), fileExtension: previous.sourceFile.fileExtension,
                        sourceFile: previous.sourceFile, maximumEdge: CGFloat(previous.previewMaximumEdge),
                        exportSettings: previous.exportSettings, rawDecode: sourcePolicy, baseRAWDecode: previous.baseRAWDecode,
                        frozenWhiteBalance: frozenWhite)
                }
            }
        }
        let recipe = recipe.resolvingWhiteBalance(input.whiteBalance).resolvingLUMIXSourceISO(input.sourceISO)
        guard recipe.isValid else { throw HNCSEngine.Error.invalidSettings }
        let crop = try recipe.crop.resolve(width: input.width, height: input.height)
        let comparisonSource = try input.original.cropped(to: crop)
        let rgb: [Float]
        if crop.width == input.width && crop.height == input.height {
            rgb = input.linearRGB
        } else {
            var pixels = [Float]()
            pixels.reserveCapacity(crop.width * crop.height * 3)
            // Decoded bitmaps use top-to-bottom rows; ciY is only for CI rectangles.
            for row in crop.top..<(crop.top + crop.height) {
                let start = (row * input.width + crop.x) * 3
                pixels.append(contentsOf: input.linearRGB[start..<(start + crop.width * 3)])
            }
            rgb = pixels
        }
        // Crop before pointwise/spatial processing, just as the source reference.
        // Exact engines return display-linear Float32; no byte encoder runs.
        var effectInput = rgb
        let gains: [Float]?
        if recipe.usesExtendedHNCSWorkingDomain {
            if recipe.appliesExposureBeforeHighlights { try applyExposure(&effectInput, exposureEV: recipe.exposureEV) }
            gains = nil
        }
        else {
            gains = try normalizeHighlights(&effectInput,
                exposureEV: recipe.appliesExposureBeforeHighlights ? recipe.exposureEV : 0)
        }
        var rgba: [Float]
        switch recipe.mode {
        case .hncs:
            rgba = try HNCSEngine.exportLinearRGBA(linearSRGB: effectInput, width: crop.width,
                                                   height: crop.height, exposureEV: recipe.backendExposureEV,
                                                   illuminantKelvin: recipe.illuminantKelvin, settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance,
                                                   baselineSharpness: input.rawDecode.baselineSharpness ?? 0)
        case .ffcs:
            rgba = try FFCSEngine.exportLinearRGBA(resources: resources, linearSRGB: effectInput, width: crop.width,
                                                   height: crop.height, exposureEV: recipe.backendExposureEV,
                                                   simulationIndex: recipe.simulationIndex, seed: recipe.seed, effects: recipe.effects, settings: recipe.ffcs)
        case .lumix:
            rgba = try LUMIXEngine.exportLinearRGBA(resources: resources, linearSRGB: effectInput, width: crop.width,
                                                    height: crop.height,
                                                    exposureEV: recipe.backendExposureEV,
                                                    settings: recipe.lumix, illuminantKelvin: recipe.illuminantKelvin)
        }
        if let gains { try restoreHighlights(&rgba, gains: gains) }
        let image = try PreviewRaster(linearRGBA: rgba, width: crop.width, height: crop.height)
        return ProcessedImage(image: image, comparisonSource: comparisonSource, source: input, recipe: recipe)
    }
}
