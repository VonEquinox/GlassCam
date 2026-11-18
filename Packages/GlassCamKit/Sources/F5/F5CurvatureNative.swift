import Foundation
import Metal
import CMetalF5

final class F5CurvatureNative {
    let handle: OpaquePointer
    private let allocation: F5ExternalMetalAllocation

    init(device: F5MetalDevice, width: Int, height: Int, scale: Int, capacity: Int, planes: Int = 28, slots: Int = 2,
         estimateColorPrior: Bool = false) throws {
        if device.isCancelled() { throw CancellationError() }
        var configuration = gc_f5_curve_config(width: UInt32(width), height: UInt32(height), scale: UInt32(scale),
            batch_capacity: UInt32(capacity), plane_capacity: UInt32(planes), slots: UInt32(slots),
            maximum_bytes: UInt64(device.maximumBytes - device.allocatedBytes), automatic_color_prior: estimateColorPrior ? 1 : 0)
        var error = gc_f5_curve_error()
        guard let context = gc_f5_curvature_create(&configuration,
            Unmanaged.passUnretained(device.device as AnyObject).toOpaque(),
            Unmanaged.passUnretained(device.library as AnyObject).toOpaque(), &error) else {
            try Self.check(error)
            throw F5Failure(.memoryPressure, "Cannot create native curvature context.")
        }
        let retained: F5ExternalMetalAllocation
        do { retained = try device.retainExternalAllocation(Int(gc_f5_curvature_allocated_bytes(context))) }
        catch { gc_f5_curvature_destroy(context); throw error }
        handle = context; allocation = retained
    }

    deinit { gc_f5_curvature_destroy(handle) }

    static func check(_ error: gc_f5_curve_error) throws {
        guard error.status != 0 else { return }
        if error.status == 4 { throw CancellationError() }
        var bytes = error.message
        let message = withUnsafePointer(to: &bytes) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        if error.status == 5 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error.system_error), userInfo: [NSLocalizedDescriptionKey: message]) }
        let code: F5Code = error.status == 1 ? .damagedBundle : error.status == 2 ? .memoryPressure : .numericalStall
        throw F5Failure(code, message)
    }
}
