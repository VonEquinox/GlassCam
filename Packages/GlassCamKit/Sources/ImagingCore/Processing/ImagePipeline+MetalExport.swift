import CoreImage
import Foundation

extension ImagePipeline {
    static func exportMetalImage(_ image: CIImage, context: CIContext, encodingContext: CIContext,
                                width: Int, height: Int, output: (width: Int, height: Int),
                                linear: CGColorSpace, pq: CGColorSpace, metadata: PhotoMetadata,
                                recipe: ProcessingRecipe, rawDecode: RAWDecodeRecipe, to url: URL,
                                releaseSourceCache: Bool, sourceIsRAW: Bool, isCancelled: @escaping @Sendable () -> Bool,
                                progress: @escaping @Sendable (Double) -> Void) throws {
        let raster = try ExportRasterFile()
        var headroom: Float = 1
        if recipe.usesExtendedHNCSWorkingDomain {
            let work = try HNCSPresetWorkFile(width: width, height: height)
            let maximum = try HNCSEngine.renderWorkFile(image, context: context, to: work,
                recipe: recipe, isCancelled: isCancelled, progress: { progress(0.1 + 0.35 * $0) })
            if releaseSourceCache { context.clearCaches() }
            let scale = try HNCSEngine.workingScale(maximum: maximum)
            try HNCSEngine.applySpatial(to: work, settings: recipe.hncs, effects: recipe.effects,
                baselineSharpness: rawDecode.baselineSharpness ?? 0, workScale: scale, isCancelled: isCancelled)
            progress(0.65)
            headroom = min(maximumHDRValue, try HNCSEngine.finishPresetWorkFile(work, to: raster,
                recipe: recipe, workScale: scale, isCancelled: isCancelled, progress: { progress(0.65 + 0.2 * $0) }))
        } else {
            headroom = max(1, try MetalColorEngine.render(image, context: context, to: raster.url.path, components: 4, maximumRows: sourceIsRAW ? 64 : 0,
                isCancelled: isCancelled, progress: { progress(0.1 + 0.75 * $0) }))
            if releaseSourceCache { context.clearCaches() }
        }
        try encodeHDR(raster: raster, rasterBytes: width * height * 16, width: width, height: height,
            output: output, linear: linear, pq: pq, outputHeadroom: headroom, encodingContext: encodingContext,
            metadata: metadata, recipe: recipe, to: url, isCancelled: isCancelled, progress: progress)
    }
}
