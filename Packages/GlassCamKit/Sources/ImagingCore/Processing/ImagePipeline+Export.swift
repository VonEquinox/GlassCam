import Foundation
import CoreImage
import ImageIO

extension ImagePipeline {
    static func exportLinearSource(resources: ColorResources, _ decoded: CIImage, metadata: PhotoMetadata,
                                          recipe: ProcessingRecipe, to url: URL,
                                          settings: ExportSettings, rawDecode: RAWDecodeRecipe, isCancelled: @escaping @Sendable () -> Bool,
                                          progress: @escaping @Sendable (Double) -> Void,
                                          onSourceDimensions: ((Int, Int) -> Void)? = nil,
                                          releaseSourceCache: Bool = false,
                                          sourceIsRAW: Bool = false,
                                          useGPU: Bool = true) throws {
        try checkExportCancellation(isCancelled)
        // Protect all byte-count arithmetic before allocating or creating a file.
        guard decoded.extent.width < CGFloat(Int.max / 16),
              decoded.extent.height < CGFloat(Int.max / 16) else { throw PipelineError.invalidImage }
        let sourceWidth = Int(decoded.extent.width.rounded(.down))
        let sourceHeight = Int(decoded.extent.height.rounded(.down))
        guard recipe.isValid else { throw HNCSEngine.Error.invalidSettings }
        let crop = try recipe.crop.resolve(width: sourceWidth, height: sourceHeight)
        let width = crop.width, height = crop.height
        guard width > 0, height > 0, width <= Int.max / 16 / height else { throw PipelineError.invalidImage }
        let output = try settings.dimensions(sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: recipe.crop)
        onSourceDimensions?(sourceWidth, sourceHeight)
        let rasterBytes = width * height * 16
        let capacity = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        // Reserve RGBAf + encoded-output margin and the full work image/scratch.
        // Only legacy HNCS additionally stores a separate per-pixel gain plane.
        let extendedWork = recipe.usesExtendedHNCSWorkingDomain
        let needsSpatial = recipe.mode == .hncs && recipe.hncs.requiresSpatial(effects: recipe.effects)
        let needsWorkImage = needsSpatial || extendedWork
        let workBytesPerPixel = extendedWork ? (needsSpatial ? 32.0 : 12.0) : (needsSpatial ? 36.0 : 0.0)
        let spatialBytes = Double(width) * Double(height) * workBytesPerPixel
        if let available = capacity.volumeAvailableCapacityForImportantUsage,
           Double(available) < Double(rasterBytes) * 1.5 + spatialBytes + 64 * 1024 * 1024 {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ) else { throw PipelineError.rendering }
        let context = CIContext(options: [.workingColorSpace: linear,
                                          .workingFormat: CIFormat.RGBAf.rawValue,
                                          .cacheIntermediates: false])
        // CIContext colour-matches inputs before executing filters. Clamp only
        // in the destination primaries, so valid negative sRGB components can
        // first become in-gamut BT.2020 values.
        let encodingContext: CIContext
        if extendedWork {
            guard let targetLinear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else { throw PipelineError.rendering }
            encodingContext = CIContext(options: [.workingColorSpace: targetLinear,
                                                  .workingFormat: CIFormat.RGBAf.rawValue,
                                                  .cacheIntermediates: false])
        } else { encodingContext = context }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let croppedSource = decoded.cropped(to: crop.ciRect)
            .transformed(by: CGAffineTransform(translationX: -CGFloat(crop.x), y: -CGFloat(crop.ciY)))
        let source = croppedSource.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)))
            .cropped(to: bounds)
        if useGPU, let image = try MetalColorEngine.image(resources: resources, source: source, recipe: recipe) {
            try exportMetalImage(image, context: context, encodingContext: encodingContext, width: width, height: height,
                output: output, linear: linear, pq: pq, metadata: metadata, recipe: recipe, rawDecode: rawDecode,
                to: url, releaseSourceCache: releaseSourceCache, sourceIsRAW: sourceIsRAW, isCancelled: isCancelled, progress: progress)
            return
        }
        let raster = try ExportRasterFile()
        let highlightWork = needsSpatial && !extendedWork ? try ExportRasterFile() : nil
        let spatialWork = needsWorkImage ? try HNCSPresetWorkFile(width: width, height: height) : nil
        let stripRows = 64
        var outputHeadroom: Float = 1
        var maximumWorkValue: Float = 0
        let halo: Int
        if recipe.mode == .ffcs {
            halo = try FFCSEngine.requiredHalo(resources: resources, simulationIndex: recipe.simulationIndex,
                                               effects: recipe.effects, settings: recipe.ffcs)
        } else { halo = 0 }
        for start in stride(from: 0, to: height, by: stripRows) {
            try checkExportCancellation(isCancelled)
            try autoreleasepool {
                let rows = min(stripRows, height - start)
                let inputStart = max(0, start - halo)
                let inputEnd = min(height, start + rows + halo)
                let inputRows = inputEnd - inputStart
                var decodedRGBA = [Float](repeating: 0, count: width * inputRows * 4)
                decodedRGBA.withUnsafeMutableBytes { buffer in
                    // The strip and native backends count rows from the top.
                    // CI bounds count from the bottom, while render(toBitmap:)
                    // returns the selected rectangle in top-to-bottom order.
                    context.render(source, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                                   bounds: CGRect(x: 0, y: CGFloat(height - inputEnd), width: CGFloat(width), height: CGFloat(inputRows)),
                                   format: .RGBAf, colorSpace: linear)
                }
                var rgb = [Float](repeating: 0, count: width * inputRows * 3)
                for pixel in 0..<(width * inputRows) {
                    for channel in 0..<3 { rgb[pixel * 3 + channel] = decodedRGBA[pixel * 4 + channel] }
                }
                let inputGains: [Float]
                if extendedWork {
                    if recipe.appliesExposureBeforeHighlights { applyExposure(&rgb, exposureEV: recipe.exposureEV) }
                    inputGains = []
                } else {
                    inputGains = try normalizeHighlights(&rgb,
                        exposureEV: recipe.appliesExposureBeforeHighlights ? recipe.exposureEV : 0)
                }
                let firstPixel = (start - inputStart) * width
                let gains = extendedWork ? [] : Array(inputGains[firstPixel..<(firstPixel + width * rows)])
                if let spatialWork {
                    if let highlightWork { try highlightWork.append(gains) }
                    let work = try HNCSEngine.presetWork(linearSRGB: rgb, width: width, height: rows,
                        exposureEV: recipe.backendExposureEV, captureKelvin: recipe.illuminantKelvin, settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance)
                    if extendedWork { maximumWorkValue = max(maximumWorkValue, work.max() ?? 0) }
                    try spatialWork.writeTopDownRows(work, originY: start, rows: rows)
                    progress(0.1 + 0.35 * Double(start + rows) / Double(height))
                    return
                }
                var rgba: [Float]
                switch recipe.mode {
                case .hncs:
                    rgba = try HNCSEngine.exportLinearRGBA(linearSRGB: rgb, width: width, height: rows,
                                                           exposureEV: recipe.backendExposureEV,
                                                           illuminantKelvin: recipe.illuminantKelvin, settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance)
                case .ffcs:
                    let rendered = try FFCSEngine.exportLinearRGBStrip(resources: resources,
                        linearSRGB: rgb, fullWidth: width, fullHeight: height,
                        inputOriginY: inputStart, inputRows: inputRows,
                        outputOriginY: start, outputRows: rows,
                        exposureEV: recipe.backendExposureEV, simulationIndex: recipe.simulationIndex, seed: recipe.seed, effects: recipe.effects, settings: recipe.ffcs)
                    var expanded = [Float](repeating: 1, count: width * rows * 4)
                    for pixel in 0..<(width * rows) {
                        for channel in 0..<3 { expanded[pixel * 4 + channel] = rendered[pixel * 3 + channel] }
                    }
                    rgba = expanded
                case .lumix:
                    rgba = try LUMIXEngine.exportLinearRGBA(resources: resources, linearSRGB: rgb, width: width, height: rows,
                        exposureEV: recipe.backendExposureEV,
                        settings: recipe.lumix, illuminantKelvin: recipe.illuminantKelvin)
                }
                guard rgba.count == width * rows * 4,
                      rgba.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { throw PipelineError.rendering }
                outputHeadroom = max(outputHeadroom, restoreHighlights(&rgba, gains: gains))
                try raster.append(rgba)
                progress(0.1 + 0.75 * Double(start + rows) / Double(height))
            }
        }
        // Preserve the fixed RAW tiles until every source row/halo was read.
        // Release them before whole-image spatial work and HEIF encoding.
        if releaseSourceCache { context.clearCaches() }
        if let spatialWork {
            let gainData = try highlightWork?.mappedData(expectedBytes: width * height * 4)
            let workScale = extendedWork ? try HNCSEngine.workingScale(maximum: maximumWorkValue) : 1
            try checkExportCancellation(isCancelled)
            progress(0.45)
            // Grain normalization and USM see one complete cropped top-down
            // image, never independently seeded 64-row strips.
            try HNCSEngine.applySpatial(to: spatialWork, settings: recipe.hncs, effects: recipe.effects,
                baselineSharpness: rawDecode.baselineSharpness ?? 0, workScale: workScale, isCancelled: isCancelled)
            progress(0.65)
            for start in stride(from: 0, to: height, by: stripRows) {
                try checkExportCancellation(isCancelled)
                try autoreleasepool {
                    let rows = min(stripRows, height - start)
                    let work = try spatialWork.readTopDownRows(originY: start, rows: rows)
                    var rgba = try HNCSEngine.finishPresetWork(work, width: width, height: rows,
                        exposureEV: recipe.backendExposureEV, captureKelvin: recipe.illuminantKelvin, settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance, workScale: workScale)
                    guard rgba.count == width * rows * 4, rgba.allSatisfy({ $0.isFinite }) else { throw PipelineError.rendering }
                    if extendedWork {
                        // This is an upper bound in the source primaries. The
                        // destination-space clamp still owns the physical limit.
                        outputHeadroom = min(maximumHDRValue, max(outputHeadroom, rgba.max() ?? 1))
                    } else {
                        guard let gainData, rgba.allSatisfy({ $0 >= 0 && $0 <= 1 }) else { throw PipelineError.rendering }
                        let gains = gainData.withUnsafeBytes { bytes in
                            Array(bytes.bindMemory(to: Float.self)[(start * width)..<((start + rows) * width)])
                        }
                        outputHeadroom = max(outputHeadroom, restoreHighlights(&rgba, gains: gains))
                    }
                    try raster.append(rgba)
                    progress(0.65 + 0.2 * Double(start + rows) / Double(height))
                }
            }
        }
        try encodeHDR(raster: raster, rasterBytes: rasterBytes, width: width, height: height, output: output,
                      linear: linear, pq: pq, outputHeadroom: outputHeadroom, encodingContext: encodingContext,
                      metadata: metadata, recipe: recipe, to: url, isCancelled: isCancelled, progress: progress)
    }
}
