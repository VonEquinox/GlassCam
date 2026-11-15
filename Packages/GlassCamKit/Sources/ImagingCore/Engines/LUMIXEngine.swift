import CLUMIX
import CMetalImage
import CoreImage
import Foundation
import OSLog

/// Photo Style rendering with the preserved SDR integer path and the iPhone
/// floating-point adapter described in docs/color/lumix.md.
/// Full export uses the complete original cubes.
public enum LUMIXEngine {
    typealias Look = LUMIXPhotoStyleCatalog.Look
    public static let looks = LUMIXPhotoStyleCatalog.looks
    enum Error: LocalizedError {
        case invalidInput, missingResources, backend(String)
        var errorDescription: String? {
            switch self {
            case .invalidInput: return String(localized: "This photo cannot be processed.")
            case .missingResources: return String(localized: "This photo style is unavailable. Choose another style.")
            case .backend(let message):
                Logger(subsystem: "dev.glasscam", category: "LUMIX").error("Native render failed: \(message, privacy: .public)")
                return String(localized: "Photo processing failed. Please try again.")
            }
        }
    }
    private final class ContextOwner: @unchecked Sendable {
        let pointer: OpaquePointer
        let directory: URL
        let settings: LUMIXSettings
        let kelvin: Double
        private let metalLock = NSLock()
        private var cachedMetalResources: GCMetalColorResources?
        init(pointer: OpaquePointer, directory: URL, settings: LUMIXSettings, kelvin: Double) {
            self.pointer = pointer; self.directory = directory; self.settings = settings
            self.kelvin = kelvin
        }
        func metalResources(shaderPath: String) throws -> GCMetalColorResources {
            metalLock.lock()
            defer { metalLock.unlock() }
            if let cachedMetalResources { return cachedMetalResources }
            let created = try GCMetalColor.lumixResources(pointer, shaderPath: shaderPath)
            cachedMetalResources = created
            return created
        }
        deinit { lumix_destroy(pointer) }
    }
    private final class ContextCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: ContextOwner?
        func context(resources: ColorResources, settings: LUMIXSettings, kelvin: Double) throws -> ContextOwner {
            guard settings.isValid, kelvin.isFinite, (2000...10000).contains(kelvin),
                  let look = looks.first(where: { $0.id == settings.photoStyle }) else {
                throw Error.invalidInput
            }
            guard let directory = resources.lumixDirectory else { throw Error.missingResources }
            lock.lock(); defer { lock.unlock() }
            if let cached, cached.directory == directory, cached.settings == settings, cached.kelvin == kelvin { return cached }
            var message = [CChar](repeating: 0, count: 1024)
            let pointer = directory.path.withCString { path in
                message.withUnsafeMutableBufferPointer { error in
                    if settings.renderRevision == 1 {
                        return lumix_create(path, look.index, error.baseAddress, error.count)
                    }
                    if settings.renderRevision >= 5 {
                        return lumix_create_native_pipeline(path, look.index, kelvin,
                            Int32((settings.contrast + 5) * 2), Int32((settings.saturation + 5) * 2),
                            Int32(settings.sourceISO ?? 100), error.baseAddress, error.count)
                    }
                    return lumix_create_pipeline(path, look.index, kelvin,
                        Int32((settings.contrast + 5) * 2), Int32((settings.saturation + 5) * 2),
                        Int32(settings.sourceISO ?? 100), error.baseAddress, error.count)
                }
            }
            guard let pointer else { throw Error.backend(String(cString: message)) }
            let owner = ContextOwner(pointer: pointer, directory: directory, settings: settings, kelvin: kelvin)
            cached = owner
            return owner
        }
    }
    private static let cache = ContextCache()

    static func metalImage(resources: ColorResources, _ source: CIImage, recipe: ProcessingRecipe) throws -> CIImage {
        let owner = try cache.context(resources: resources, settings: recipe.lumix, kelvin: recipe.illuminantKelvin)
        return try withExtendedLifetime(owner) {
            let gpuResources = try owner.metalResources(shaderPath: MetalColorEngine.shaderPath)
            return try GCMetalColor.lumix(source, context: owner.pointer, resources: gpuResources,
                sourceExposure: Float(exp2(recipe.appliesExposureBeforeHighlights ? recipe.exposureEV : 0)),
                backendExposure: Float(exp2(recipe.backendExposureEV)), shaderPath: MetalColorEngine.shaderPath)
        }
    }

    static func exportLinearRGBA(resources: ColorResources, linearSRGB: [Float], width: Int, height: Int,
                                 exposureEV: Double, settings: LUMIXSettings = .standard,
                                 illuminantKelvin: Double = 6500) throws -> [Float] {
        guard width > 0, height > 0, width <= Int.max / 16 / height,
              exposureEV.isFinite, (-2...2).contains(exposureEV) else { throw Error.invalidInput }
        let pixels = width * height
        guard linearSRGB.count == pixels * 3 else { throw Error.invalidInput }
        let owner = try cache.context(resources: resources, settings: settings, kelvin: illuminantKelvin)
        var rgba = [Float](repeating: 0, count: pixels * 4)
        var message = [CChar](repeating: 0, count: 1024)
        let status = withExtendedLifetime(owner) {
            linearSRGB.withUnsafeBufferPointer { input in
                rgba.withUnsafeMutableBufferPointer { output in
                    message.withUnsafeMutableBufferPointer { error in
                        if settings.renderRevision >= 5 {
                            return lumix_process_native_rgba(owner.pointer, input.baseAddress, input.count, pixels,
                                exposureEV, output.baseAddress, output.count, error.baseAddress, error.count)
                        }
                        if settings.renderRevision == 4 {
                            return lumix_process_iphone_rgba(owner.pointer, input.baseAddress, input.count, pixels,
                                exposureEV, output.baseAddress, output.count, error.baseAddress, error.count)
                        }
                        return lumix_process_linear_rgba(owner.pointer, input.baseAddress, input.count, pixels,
                            exposureEV, output.baseAddress, output.count, error.baseAddress, error.count)
                    }
                }
            }
        }
        guard status == 1 else { throw Error.backend(String(cString: message)) }
        return rgba
    }
}
