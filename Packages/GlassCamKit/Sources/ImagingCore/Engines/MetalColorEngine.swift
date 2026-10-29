import CMetalImage
import CoreImage
import Foundation

enum MetalColorEngine {
    static var shaderPath: String {
        Bundle.module.url(forResource: "ColorKernels", withExtension: "metal", subdirectory: "Metal")?.path ?? ""
    }
    static func image(resources: ColorResources, source: CIImage, recipe: ProcessingRecipe) throws -> CIImage? {
        guard MetalSpatialEngine.shared.context != nil else { return nil }
        switch recipe.mode {
        case .hncs:
            guard recipe.usesExtendedHNCSWorkingDomain else { return nil }
            // The quantized HNCS color stages stay on the exact native path;
            // their completed work image goes through Metal integer sharpness.
            return source
        case .ffcs:
            return try FFCSEngine.metalImage(resources: resources, source, recipe: recipe)
        case .lumix:
            guard recipe.lumix.renderRevision >= 4 else { return nil }
            return try LUMIXEngine.metalImage(resources: resources, source, recipe: recipe)
        }
    }
    static func render(_ image: CIImage, context: CIContext, to path: String, components: Int, maximumRows: Int = 0,
                       isCancelled: @escaping @Sendable () -> Bool,
                       progress: @escaping @Sendable (Double) -> Void) throws -> Float {
        var maximum: Float = 0
        do {
            try GCMetalColor.render(image, context: context, toPath: path, components: UInt(components),
                                    maximumRows: UInt(maximumRows), maximum: &maximum, cancelled: isCancelled, progress: progress)
        } catch {
            if isCancelled() { throw CancellationError() }
            throw error
        }
        return maximum
    }
}
