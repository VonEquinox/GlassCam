import Foundation
import Metal
import CMetalF5

struct F5CurvaturePlane {
    let samples: [Float]
    let position: SIMD2<Float>
    let channel: UInt32
    let variance: Float
    let confidence: Float
}

struct F5CurvatureMoments {
    let measuredVariance: SIMD3<Float>
    let guideNoise: SIMD3<Float>
}

struct F5CurvaturePatch {
    let planes: [F5CurvaturePlane]
    let mean: SIMD3<Float>
    /// Row-major positive-definite precision of camera RGB.
    let colorPrecision: [Float]
    var moments: F5CurvatureMoments? = nil
}

/// Swift only bridges prepared observations. C++ owns validation, GPU buffers,
/// FFT/solve/synthesis dispatch and the lifetime of the returned windowed blocks.
final class F5CurvatureBatch {
    static let patchSize = 32
    static let maximumPatches = 128
    let device: F5MetalDevice
    init(device: F5MetalDevice) { self.device = device }

    func reconstruct(_ patches: [F5CurvaturePatch], scale: Int = 2) throws -> F5MetalBuffer {
        guard !patches.isEmpty, patches.count <= Self.maximumPatches, [1, 2].contains(scale),
              let planes = patches.first?.planes.count, (4...20).contains(planes), planes % 4 == 0 else {
            throw F5Failure(.damagedBundle, "Invalid curvature batch dimensions.")
        }
        let native = try F5CurvatureNative(device: device, width: 0, height: 0, scale: scale,
                                           capacity: patches.count, planes: planes, slots: 1,
                                           estimateColorPrior: patches[0].moments != nil)
        var view = gc_f5_curvature_input(native.handle, 0)
        try Self.fill(patches, into: &view)
        var error = gc_f5_curve_error()
        _ = gc_f5_curvature_solve(native.handle, UInt32(patches.count), view.plane_count, &error)
        try F5CurvatureNative.check(error)
        if device.isCancelled() { throw CancellationError() }
        guard let pointer = gc_f5_curvature_output(native.handle),
              let output = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? MTLBuffer else {
            throw F5Failure(.memoryPressure, "Native curvature output is unavailable.")
        }
        return F5MetalBuffer(output, owner: device, accountedBytes: 0, retaining: native)
    }

    static func fill(_ patches: [F5CurvaturePatch], into view: inout gc_f5_curve_input) throws {
        guard !patches.isEmpty, patches.count <= Int(view.patch_capacity),
              let planeCount = patches.first?.planes.count, (4...Int(view.plane_capacity)).contains(planeCount), planeCount % 4 == 0,
              let samples = view.samples, let models = view.models, let channels = view.channels,
              let means = view.means, let precision = view.precision else {
            throw F5Failure(.damagedBundle, "Invalid native curvature input capacity.")
        }
        for (b, patch) in patches.enumerated() {
            guard patch.planes.count == planeCount,
                  (view.statistics == nil ? patch.moments == nil && patch.colorPrecision.count == 9 : patch.moments != nil),
                  patch.colorPrecision.count == 9 || patch.colorPrecision.isEmpty else {
                throw F5Failure(.damagedBundle, "Invalid native curvature patch layout.")
            }
            means[b * 4] = patch.mean.x; means[b * 4 + 1] = patch.mean.y
            means[b * 4 + 2] = patch.mean.z; means[b * 4 + 3] = 0
            if !patch.colorPrecision.isEmpty {
                patch.colorPrecision.withUnsafeBufferPointer { precision.advanced(by: b * 9).update(from: $0.baseAddress!, count: 9) }
            }
            if let statistics = view.statistics, let moments = patch.moments {
                for c in 0..<3 { statistics[b * 8 + c] = moments.measuredVariance[c]; statistics[b * 8 + 4 + c] = moments.guideNoise[c] }
                statistics[b * 8 + 3] = 0; statistics[b * 8 + 7] = 0
            }
            for (r, plane) in patch.planes.enumerated() {
                guard plane.samples.count == 256 else { throw F5Failure(.damagedBundle, "Invalid curvature CFA plane size.") }
                let row = b * planeCount + r
                models[row * 4] = plane.position.x; models[row * 4 + 1] = plane.position.y
                models[row * 4 + 2] = plane.variance; models[row * 4 + 3] = plane.confidence
                channels[row] = plane.channel
                plane.samples.withUnsafeBufferPointer { samples.advanced(by: row * 256).update(from: $0.baseAddress!, count: 256) }
            }
        }
        view.plane_count = UInt32(planeCount)
    }
}
