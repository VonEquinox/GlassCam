import Foundation
import Metal
import CMetalF5

private final class F5RegistrationCallbacks {
    let cancelled: () -> Bool, progress: (Double) -> Void
    init(cancelled: @escaping () -> Bool, progress: @escaping (Double) -> Void) { self.cancelled = cancelled; self.progress = progress }
}

/// The C++ context owns Fourier grayscale, pyramids, GPU local registration and
/// reliability. Completed registration retains only motion, masks and summaries.
final class F5CurvatureRegistration {
    let device: F5MetalDevice
    let width, height, frames: Int
    private let handle: OpaquePointer
    private let allocation: F5ExternalMetalAllocation

    init(device: F5MetalDevice, width: Int, height: Int, frames: Int, cfa: [UInt32], alpha: [Float], beta: [Float],
         raw: F5MetalBuffer, kinds: F5MetalBuffer, progress: @escaping (Double) -> Void = { _ in }) throws {
        defer { withExtendedLifetime(raw) {}; withExtendedLifetime(kinds) {} }
        guard width >= 4, height >= 4, width <= 16384, height <= 16384, (1...5).contains(frames),
              cfa.count == 4, alpha.count == 4, beta.count == 4 else { throw F5Failure(.damagedBundle, "Invalid Bayer registration layout.") }
        if device.isCancelled() { throw CancellationError() }
        var configuration = gc_f5_curve_registration_config(width: UInt32(width), height: UInt32(height), frames: UInt32(frames),
            cfa: (cfa[0],cfa[1],cfa[2],cfa[3]), alpha: (alpha[0],alpha[1],alpha[2],alpha[3]), beta: (beta[0],beta[1],beta[2],beta[3]),
            maximum_bytes: UInt64(device.maximumBytes - device.allocatedBytes))
        var error = gc_f5_curve_error()
        guard let context = gc_f5_curve_registration_create(&configuration,
            Unmanaged.passUnretained(device.device as AnyObject).toOpaque(), Unmanaged.passUnretained(device.library as AnyObject).toOpaque(),
            Unmanaged.passUnretained(raw.metal as AnyObject).toOpaque(), Unmanaged.passUnretained(kinds.metal as AnyObject).toOpaque(), &error) else {
            try F5CurvatureNative.check(error)
            throw F5Failure(.memoryPressure, "Cannot create Bayer GPU registration.")
        }
        let retained: F5ExternalMetalAllocation
        var temporary: F5ExternalMetalAllocation?
        let provider = F5RegistrationCallbacks(cancelled: device.isCancelled, progress: progress)
        do {
            temporary = try device.retainExternalAllocation(Int(gc_f5_curve_registration_allocated_bytes(context)))
            var callbacks = gc_f5_curve_callbacks(context: Unmanaged.passUnretained(provider).toOpaque(), prepare: nil, cancelled: { pointer in
                guard let pointer else { return 1 }
                return Unmanaged<F5RegistrationCallbacks>.fromOpaque(pointer).takeUnretainedValue().cancelled() ? 1 : 0
            }, progress: { pointer, completed in
                guard let pointer else { return }
                Unmanaged<F5RegistrationCallbacks>.fromOpaque(pointer).takeUnretainedValue().progress(completed)
            })
            _ = gc_f5_curve_registration_run(context, &callbacks, &error)
            withExtendedLifetime(provider) {}
            try F5CurvatureNative.check(error)
            withExtendedLifetime(temporary) {}
            temporary = nil
            retained = try device.retainExternalAllocation(Int(gc_f5_curve_registration_allocated_bytes(context)))
        } catch { gc_f5_curve_registration_destroy(context); throw error }
        handle = context; allocation = retained; self.device = device; self.width = width; self.height = height; self.frames = frames
    }
    deinit { gc_f5_curve_registration_destroy(handle) }
    var flow: F5MetalBuffer { borrowed(gc_f5_curve_registration_flow(handle)) }
    var reliability: F5MetalBuffer { borrowed(gc_f5_curve_registration_reliability(handle)) }
    var summary: F5MetalBuffer { borrowed(gc_f5_curve_registration_summary(handle)) }
    private func borrowed(_ pointer: UnsafeMutableRawPointer?) -> F5MetalBuffer {
        let buffer = Unmanaged<AnyObject>.fromOpaque(pointer!).takeUnretainedValue() as! MTLBuffer
        return F5MetalBuffer(buffer, owner: device, accountedBytes: 0, retaining: self)
    }
}
