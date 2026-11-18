import Foundation
import Metal
import CMetalF5

/// GPU normalization of original integer Bayer codes with the shared event
/// decoder. Event kinds are retained alongside the delivered sample centers.
final class F5CurvatureRAW {
    let width, height, frames: Int
    let device: F5MetalDevice
    private let handle: OpaquePointer
    private let allocation: F5ExternalMetalAllocation

    convenience init(frames: [F5MetalFrame], device: F5MetalDevice) throws {
        guard let first = frames.first,
              frames.allSatisfy({ $0.uniforms.active.z == first.uniforms.active.z && $0.uniforms.active.w == first.uniforms.active.w }) else {
            throw F5Failure(.damagedBundle, "Curvature RAW frame dimensions disagree.")
        }
        try self.init(count: frames.count, width: Int(first.uniforms.active.z), height: Int(first.uniforms.active.w),
                      device: device) { frames[$0] }
    }

    init(count: Int, width: Int, height: Int, device: F5MetalDevice,
         frameProvider: (Int) throws -> F5MetalFrame) throws {
        if device.isCancelled() { throw CancellationError() }
        guard (1...7).contains(count), width >= 4, height >= 4 else {
            throw F5Failure(.damagedBundle, "Curvature RAW frame dimensions disagree.")
        }
        self.width = width; self.height = height; self.frames = count; self.device = device
        var configuration = gc_f5_curve_raw_config(width: UInt32(width), height: UInt32(height), frames: UInt32(count),
            maximum_bytes: UInt64(device.maximumBytes - device.allocatedBytes))
        var error = gc_f5_curve_error()
        guard let raw = gc_f5_curve_raw_create(&configuration,
            Unmanaged.passUnretained(device.device as AnyObject).toOpaque(),
            Unmanaged.passUnretained(device.library as AnyObject).toOpaque(), &error) else {
            try F5CurvatureNative.check(error)
            throw F5Failure(.memoryPressure, "Cannot create curvature integer RAW decoder.")
        }
        let retained: F5ExternalMetalAllocation
        var temporary: F5ExternalMetalAllocation?
        do {
            temporary = try device.retainExternalAllocation(Int(gc_f5_curve_raw_allocated_bytes(raw)))
            for index in 0..<count {
                try autoreleasepool {
                    if device.isCancelled() { throw CancellationError() }
                    let frame = try frameProvider(index)
                    guard Int(frame.uniforms.active.z) == width, Int(frame.uniforms.active.w) == height else {
                        throw F5Failure(.damagedBundle, "Curvature RAW frame dimensions disagree.")
                    }
                    var uniforms = frame.uniforms
                    withUnsafeBytes(of: &uniforms) { bytes in
                        _ = gc_f5_curve_raw_decode(raw, UInt32(index),
                            Unmanaged.passUnretained(frame.raw.metal as AnyObject).toOpaque(),
                            Unmanaged.passUnretained(frame.table.metal as AnyObject).toOpaque(),
                            bytes.baseAddress, UInt32(bytes.count), &error)
                    }
                    try F5CurvatureNative.check(error)
                }
            }
            _ = gc_f5_curve_raw_repair(raw, &error)
            try F5CurvatureNative.check(error)
            withExtendedLifetime(temporary) {}
            temporary = nil
            retained = try device.retainExternalAllocation(Int(gc_f5_curve_raw_allocated_bytes(raw)))
        } catch { gc_f5_curve_raw_destroy(raw); throw error }
        handle = raw; allocation = retained
    }

    deinit { gc_f5_curve_raw_destroy(handle) }

    var values: F5MetalBuffer { borrowed(gc_f5_curve_raw_values(handle)) }
    var kinds: F5MetalBuffer { borrowed(gc_f5_curve_raw_kinds(handle)) }
    private func borrowed(_ pointer: UnsafeMutableRawPointer?) -> F5MetalBuffer {
        let buffer = Unmanaged<AnyObject>.fromOpaque(pointer!).takeUnretainedValue() as! MTLBuffer
        return F5MetalBuffer(buffer, owner: device, accountedBytes: 0, retaining: self)
    }
}
