import Foundation
import ImagingCore
import CMetalF5

private final class F5CurvatureProvider {
    typealias Prepare = (UnsafePointer<gc_f5_curve_origin>, Int, inout gc_f5_curve_input) throws -> Void
    let prepare: Prepare
    let progress: (Double) -> Void
    let cancelled: () -> Bool
    var error: Error?
    init(prepare: @escaping Prepare, progress: @escaping (Double) -> Void, cancelled: @escaping () -> Bool) {
        self.prepare = prepare; self.progress = progress; self.cancelled = cancelled
    }
}

/// C++ owns the patch loop, reusable GPU workspaces, overlap rows and strip I/O.
final class F5CurvatureRaster {
    struct Result { let file: ExportRasterFile; let width, height: Int }
    typealias PatchProvider = (_ origins: [SIMD2<Int32>]) throws -> [F5CurvaturePatch]
    let device: F5MetalDevice
    init(device: F5MetalDevice) { self.device = device }

    func reconstruct(width: Int, height: Int, scale: Int = 2,
                     batchSize: Int = F5CurvatureBatch.maximumPatches,
                     estimateColorPrior: Bool = false,
                     progress: @escaping (Double) -> Void = { _ in },
                     patches: @escaping PatchProvider) throws -> Result {
        try reconstruct(width: width, height: height, scale: scale, batchSize: batchSize,
                        estimateColorPrior: estimateColorPrior, progress: progress) { origins, count, input in
            let positions = UnsafeBufferPointer(start: origins, count: count).map { SIMD2($0.x, $0.y) }
            let prepared = try patches(positions)
            guard prepared.count == count else { throw F5Failure(.damagedBundle, "Curvature provider omitted a patch.") }
            try F5CurvatureBatch.fill(prepared, into: &input)
        }
    }

    func reconstruct(source: F5CurvatureBayerSource, scale: Int = 2,
                     batchSize: Int = F5CurvatureBatch.maximumPatches,
                     progress: @escaping (Double) -> Void = { _ in }) throws -> Result {
        guard source.device === device else { throw F5Failure(.damagedBundle, "Curvature source belongs to a different device.") }
        return try reconstruct(width: source.width, height: source.height, scale: scale, batchSize: batchSize,
                               planes: source.frames * 4, estimateColorPrior: true, progress: progress) { origins, count, input in
            try source.prepare(origins: origins, count: count, input: &input)
        }
    }

    private func reconstruct(width: Int, height: Int, scale: Int, batchSize: Int, planes: Int = 20,
                             estimateColorPrior: Bool, progress: @escaping (Double) -> Void,
                             prepare: @escaping F5CurvatureProvider.Prepare) throws -> Result {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              [1, 2].contains(scale), (1...F5CurvatureBatch.maximumPatches).contains(batchSize) else {
            throw F5Failure(.damagedBundle, "Invalid curvature raster dimensions.")
        }
        let capacity = min(batchSize, width / 16 + 1)
        let native = try F5CurvatureNative(device: device, width: width, height: height, scale: scale, capacity: capacity,
                                           planes: planes, estimateColorPrior: estimateColorPrior)
        let file = try ExportRasterFile()
        let provider = F5CurvatureProvider(prepare: prepare, progress: progress, cancelled: device.isCancelled)
        var callbacks = gc_f5_curve_callbacks(context: Unmanaged.passUnretained(provider).toOpaque(), prepare: { context, origins, count, input in
            guard let context, let origins, let input else { return 1 }
            let provider = Unmanaged<F5CurvatureProvider>.fromOpaque(context).takeUnretainedValue()
            do {
                try provider.prepare(origins, Int(count), &input.pointee)
                return 0
            } catch { provider.error = error; return error is CancellationError ? 4 : 1 }
        }, cancelled: { context in
            guard let context else { return 1 }
            return Unmanaged<F5CurvatureProvider>.fromOpaque(context).takeUnretainedValue().cancelled() ? 1 : 0
        }, progress: { context, completed in
            guard let context else { return }
            Unmanaged<F5CurvatureProvider>.fromOpaque(context).takeUnretainedValue().progress(completed)
        })
        var error = gc_f5_curve_error()
        _ = gc_f5_curvature_raster(native.handle, file.handle.fileDescriptor, &callbacks, &error)
        if let original = provider.error { throw original }
        try F5CurvatureNative.check(error)
        try file.handle.synchronize()
        return .init(file: file, width: width * scale, height: height * scale)
    }
}
