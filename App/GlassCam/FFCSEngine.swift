import Foundation

/// Ownership and layout bridge only. The portable C++ FFCS backend loads the
/// original bundled native-family LUTs and executes the supplied research pipeline.
enum FFCSEngine {
    struct Simulation: Identifiable, Sendable {
        let id: Int
        let name: String
    }

    static let simulations: [Simulation] = (0..<Int(ffcs_simulation_count())).map {
        Simulation(id: $0, name: simulationName(at: $0))
    }

    static func simulationName(at index: Int) -> String {
        guard index >= 0, index < Int(ffcs_simulation_count()),
              let name = ffcs_simulation_name(index) else { return "Unknown simulation" }
        return String(cString: name)
    }

    static func simulations(for family: FFCSCameraFamily) -> [Simulation] {
        simulations.filter { isSimulationAvailable($0.id, family: family) }
    }

    static func isSimulationAvailable(_ index: Int, family: FFCSCameraFamily) -> Bool {
        guard index >= 0, index < Int(ffcs_simulation_count()),
              let directory = try? resourceDirectory() else { return false }
        return directory.path.withCString { root in
            family.rawValue.withCString { ffcs_simulation_available(root, $0, index) == 1 }
        }
    }

    static func resolvedAssetFamily(_ index: Int, family: FFCSCameraFamily) -> String? {
        guard index >= 0, index < Int(ffcs_simulation_count()),
              let directory = try? resourceDirectory() else { return nil }
        return directory.path.withCString { root in
            family.rawValue.withCString { camera in
                guard let actual = ffcs_resolved_asset_family(root, camera, index) else { return nil }
                return String(cString: actual).uppercased()
            }
        }
    }

    private static func resourceDirectory() throws -> URL {
        guard let resources = Bundle.main.resourceURL else { throw Error.missingResources }
        let directory = resources.appendingPathComponent("FFCS", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw Error.missingResources }
        return directory
    }

    static func requiredHalo(simulationIndex: Int, effects: EffectToggles,
                             settings: FFCSSettings) throws -> Int {
        guard settings.isValid else { throw Error.invalidInput }
        let context = try contextCache.context(directory: resourceDirectory(), simulationIndex: simulationIndex,
                                               effects: effects, settings: settings)
        return Int(ffcs_required_halo(context.pointer))
    }

    enum Error: LocalizedError {
        case invalidInput, missingResources, backend(String)
        var errorDescription: String? {
            switch self {
            case .invalidInput: return "The FFCS image dimensions, settings, or RGB buffer are invalid."
            case .missingResources: return "The bundled FFCS native reference LUTs are missing."
            case .backend(let message): return "FFCS: \(message)"
            }
        }
    }

    /// One cached immutable context; in-flight renders retain their own owner.
    /// A look change replaces the cache entry instead of accumulating all LUTs.
    private final class ContextOwner: @unchecked Sendable {
        let pointer: OpaquePointer
        let directory: String
        let simulationIndex: Int
        let effects: EffectToggles
        let settings: FFCSSettings
        init(pointer: OpaquePointer, directory: String, simulationIndex: Int, effects: EffectToggles, settings: FFCSSettings) {
            self.pointer = pointer
            self.directory = directory
            self.simulationIndex = simulationIndex
            self.effects = effects
            self.settings = settings
        }
        deinit { ffcs_destroy(pointer) }
    }

    private final class ContextCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: ContextOwner?

        func context(directory: URL, simulationIndex: Int, effects: EffectToggles, settings: FFCSSettings) throws -> ContextOwner {
            lock.lock()
            defer { lock.unlock() }
            if let cached, cached.directory == directory.path,
               cached.simulationIndex == simulationIndex, cached.effects == effects, cached.settings == settings { return cached }
            var message = [CChar](repeating: 0, count: 1024)
            let pointer = directory.path.withCString { path in
                settings.cameraFamily.rawValue.withCString { family in
                    message.withUnsafeMutableBufferPointer { error in
                        ffcs_create_family_config(path, family, simulationIndex, effects.applyGrain ? 1 : 0,
                            effects.applySharpness ? 1 : 0, settings.applyReferenceAdjustments ? 1 : 0,
                            settings.sharpenRadius, error.baseAddress, error.count)
                    }
                }
            }
            guard let pointer else { throw Error.backend(String(cString: message)) }
            let owner = ContextOwner(pointer: pointer, directory: directory.path,
                                     simulationIndex: simulationIndex, effects: effects, settings: settings)
            cached = owner
            return owner
        }
    }
    private static let contextCache = ContextCache()

    // Keep the exact tiled low-scratch path, but use one worker until measured
    // on Apple hardware. The C ABI retains 1–4 worker support for device tuning.
    private static let workerCount: UInt32 = 1

    static func process(linearSRGB: [Float], width: Int, height: Int,
                        exposureEV: Double, simulationIndex: Int, seed: UInt32, effects: EffectToggles = .standard, settings: FFCSSettings = .standard) throws -> [UInt8] {
        try render(linearSRGB: linearSRGB, width: width, height: height,
                   exposureEV: exposureEV, simulationIndex: simulationIndex,
                   seed: seed, effects: effects, settings: settings, includePreview: true).preview
    }

    static func exportLinearRGBA(linearSRGB: [Float], width: Int, height: Int,
                                 exposureEV: Double, simulationIndex: Int, seed: UInt32, effects: EffectToggles = .standard, settings: FFCSSettings = .standard) throws -> [Float] {
        let result = try render(linearSRGB: linearSRGB, width: width, height: height,
                                exposureEV: exposureEV, simulationIndex: simulationIndex,
                                seed: seed, effects: effects, settings: settings, includePreview: false)
        // Expand the backend's packed Float32 RGB without an 8-bit intermediate.
        let count = width * height
        var rgba = [Float](repeating: 1, count: count * 4)
        for pixel in 0..<count {
            let src = pixel * 3, dst = pixel * 4
            rgba[dst] = result.linearRGB[src]
            rgba[dst + 1] = result.linearRGB[src + 1]
            rgba[dst + 2] = result.linearRGB[src + 2]
        }
        return rgba
    }

    /// Process only requested full-image rows, including the context-reported halo
    /// above/below except at image edges. Row order must match the full-image
    /// bitmap supplied to the ordinary renderer; no implicit orientation flip.
    static func exportLinearRGBStrip(linearSRGB: [Float], fullWidth: Int, fullHeight: Int,
                                      inputOriginY: Int, inputRows: Int,
                                      outputOriginY: Int, outputRows: Int,
                                      exposureEV: Double, simulationIndex: Int,
                                      seed: UInt32, effects: EffectToggles = .standard, settings: FFCSSettings = .standard) throws -> [Float] {
        guard fullWidth > 0, fullHeight > 0, fullWidth <= 100_000, fullHeight <= 100_000,
              fullWidth <= Int.max / fullHeight,
              inputOriginY >= 0, inputOriginY < fullHeight,
              outputOriginY >= 0, outputOriginY < fullHeight,
              inputRows > 0, inputRows <= fullHeight - inputOriginY,
              outputRows > 0, outputRows <= fullHeight - outputOriginY,
              exposureEV.isFinite, (-32...32).contains(exposureEV),
              simulationIndex >= 0, simulationIndex < Int(ffcs_simulation_count()) else {
            throw Error.invalidInput
        }
        let pixels = fullWidth * fullHeight
        guard pixels <= Int.max / MemoryLayout<Float>.stride / 3,
              linearSRGB.count == fullWidth * inputRows * 3, settings.isValid else {
            throw Error.invalidInput
        }
        let directory = try resourceDirectory()
        let context = try contextCache.context(directory: directory, simulationIndex: simulationIndex, effects: effects, settings: settings)
        let halo = Int(ffcs_required_halo(context.pointer))
        guard inputOriginY <= max(0, outputOriginY - halo),
              inputOriginY + inputRows >= min(fullHeight, outputOriginY + outputRows + halo) else {
            throw Error.invalidInput
        }
        var output = [Float](repeating: 0, count: fullWidth * outputRows * 3)
        var message = [CChar](repeating: 0, count: 1024)
        let status = withExtendedLifetime(context) {
            linearSRGB.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { linear in
                    message.withUnsafeMutableBufferPointer { error in
                        ffcs_process_linear_rgb_strip(context.pointer, input.baseAddress, input.count,
                            fullWidth, fullHeight, inputOriginY, inputRows, outputOriginY, outputRows,
                            Float(exposureEV), seed, linear.baseAddress, linear.count, workerCount,
                            error.baseAddress, error.count)
                    }
                }
            }
        }
        guard status == 1 else { throw Error.backend(String(cString: message)) }
        return output
    }

    private static func render(linearSRGB: [Float], width: Int, height: Int,
                               exposureEV: Double, simulationIndex: Int, seed: UInt32,
                               effects: EffectToggles, settings: FFCSSettings, includePreview: Bool) throws -> (linearRGB: [Float], preview: [UInt8]) {
        guard settings.isValid, width > 0, height > 0, width <= Int.max / height,
              exposureEV.isFinite, Float(exposureEV).isFinite,
              simulationIndex >= 0, simulationIndex < Int(ffcs_simulation_count()) else {
            throw Error.invalidInput
        }
        let count = width * height
        guard count <= Int.max / MemoryLayout<Float>.stride / 4,
              linearSRGB.count == count * 3 else { throw Error.invalidInput }
        let directory = try resourceDirectory()
        let context = try contextCache.context(directory: directory, simulationIndex: simulationIndex, effects: effects, settings: settings)
        var message = [CChar](repeating: 0, count: 1024)
        // Each call requests just one output. Preview never allocates an unused
        // full-image Float32 buffer; export never allocates a byte preview.
        var output = [Float](repeating: 0, count: includePreview ? 0 : count * 3)
        var preview = [UInt8](repeating: 0, count: includePreview ? count * 4 : 0)
        let status = withExtendedLifetime(context) {
            linearSRGB.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { linear in
                    preview.withUnsafeMutableBufferPointer { bytes in
                        message.withUnsafeMutableBufferPointer { error in
                            ffcs_process_linear_rgb_optimized(context.pointer, input.baseAddress, input.count,
                                width, height, Float(exposureEV), seed,
                                includePreview ? nil : linear.baseAddress, linear.count,
                                includePreview ? bytes.baseAddress : nil, bytes.count, workerCount,
                                error.baseAddress, error.count)
                        }
                    }
                }
            }
        }
        guard status == 1 else { throw Error.backend(String(cString: message)) }
        return (output, preview)
    }
}
