import Foundation

/// The selected original Photo Style is part of the durable photo recipe.
/// Missing fields in older HNCS/FFCS recipes adopt Standard without changing mode.
struct LUMIXSettings: Codable, Equatable, Sendable {
    static let currentRenderRevision = 4 // Bounded float iPhone adapter; no UInt16 wrap.
    var renderRevision = currentRenderRevision
    var photoStyle = "standard"
    var contrast = 0.0
    var saturation = 0.0
    /// Bound from this photo's EXIF once, then retained for retries/export.
    var sourceISO: Int? = nil
    static let standard = LUMIXSettings()
    var isValid: Bool {
        [1, 2, 3, Self.currentRenderRevision].contains(renderRevision) &&
        contrast.isFinite && (-5...5).contains(contrast) &&
        saturation.isFinite && (-5...5).contains(saturation) &&
        (sourceISO == nil || (1...1_000_000).contains(sourceISO!)) &&
        (renderRevision != 1 || (contrast == 0 && saturation == 0 && sourceISO == nil)) &&
        LUMIXEngine.looks.contains { $0.id == photoStyle }
    }
    var title: String { LUMIXEngine.looks.first { $0.id == photoStyle }?.name ?? "Unavailable Photo Style" }
    init(photoStyle: String = "standard", contrast: Double = 0, saturation: Double = 0) {
        self.photoStyle = photoStyle; self.contrast = contrast; self.saturation = saturation
    }
    private enum CodingKeys: String, CodingKey { case renderRevision, photoStyle, contrast, saturation, sourceISO }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        renderRevision = try values.decodeIfPresent(Int.self, forKey: .renderRevision) ?? 1
        photoStyle = try values.decodeIfPresent(String.self, forKey: .photoStyle) ?? "standard"
        contrast = try values.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try values.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        sourceISO = try values.decodeIfPresent(Int.self, forKey: .sourceISO)
    }
}

/// Portable original SDR VE execution; the ProRAW source adapter is documented
/// in docs/LUMIX_PRORAW_20261026.md. Full export uses the complete original cubes.
enum LUMIXEngine {
    struct Look: Identifiable, Sendable {
        let id: String
        let name: String
        let index: Int
    }
    static let looks: [Look] = (0..<Int(lumix_look_count())).compactMap { index in
        guard let key = lumix_look_key(index), let name = lumix_look_name(index) else { return nil }
        return Look(id: String(cString: key), name: String(cString: name), index: index)
    }
    enum Error: LocalizedError {
        case invalidInput, missingResources, backend(String)
        var errorDescription: String? {
            switch self {
            case .invalidInput: return "The LUMIX photo settings or RGB buffer are invalid."
            case .missingResources: return "The original LUMIX Photo Style resources are missing."
            case .backend(let message): return "LUMIX: \(message)"
            }
        }
    }
    private final class ContextOwner: @unchecked Sendable {
        let pointer: OpaquePointer
        let directory: URL
        let settings: LUMIXSettings
        let kelvin: Double
        init(pointer: OpaquePointer, directory: URL, settings: LUMIXSettings, kelvin: Double) {
            self.pointer = pointer; self.directory = directory; self.settings = settings
            self.kelvin = kelvin
        }
        deinit { lumix_destroy(pointer) }
    }
    private final class ContextCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: ContextOwner?
        func context(settings: LUMIXSettings, kelvin: Double) throws -> ContextOwner {
            guard settings.isValid, kelvin.isFinite, (2000...10000).contains(kelvin),
                  let look = looks.first(where: { $0.id == settings.photoStyle }) else {
                throw Error.invalidInput
            }
            guard let resources = Bundle.main.resourceURL else { throw Error.missingResources }
            let directory = resources.appendingPathComponent("LUMIX", isDirectory: true)
            lock.lock(); defer { lock.unlock() }
            if let cached, cached.directory == directory, cached.settings == settings, cached.kelvin == kelvin { return cached }
            var message = [CChar](repeating: 0, count: 1024)
            let pointer = directory.path.withCString { path in
                message.withUnsafeMutableBufferPointer { error in
                    if settings.renderRevision == 1 {
                        return lumix_create(path, look.index, error.baseAddress, error.count)
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

    static func exportLinearRGBA(linearSRGB: [Float], width: Int, height: Int,
                                 exposureEV: Double, settings: LUMIXSettings = .standard,
                                 illuminantKelvin: Double = 6500) throws -> [Float] {
        guard width > 0, height > 0, width <= Int.max / 16 / height,
              exposureEV.isFinite, (-2...2).contains(exposureEV) else { throw Error.invalidInput }
        let pixels = width * height
        guard linearSRGB.count == pixels * 3 else { throw Error.invalidInput }
        let owner = try cache.context(settings: settings, kelvin: illuminantKelvin)
        var rgba = [Float](repeating: 0, count: pixels * 4)
        var message = [CChar](repeating: 0, count: 1024)
        let status = withExtendedLifetime(owner) {
            linearSRGB.withUnsafeBufferPointer { input in
                rgba.withUnsafeMutableBufferPointer { output in
                    message.withUnsafeMutableBufferPointer { error in
                        if settings.renderRevision >= 4 {
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
