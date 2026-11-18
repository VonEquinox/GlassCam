import Foundation
import Metal
import CMetalF5

/// Owns bounded guide rows. C++ prepares observations directly in the solver's
/// reusable Metal buffers; Swift only passes metadata and borrowed handles.
final class F5CurvatureBayerSource {
    let device: F5MetalDevice
    let width, height, frames: Int
    private let handle: OpaquePointer
    private let allocation: F5ExternalMetalAllocation
    private let inputs: [F5MetalBuffer]

    init(device: F5MetalDevice, width: Int, height: Int, frames: Int, tileSize: Int,
         cfa: [UInt32], alpha: [Float], beta: [Float],
         raw: F5MetalBuffer, flow: F5MetalBuffer, reliability: F5MetalBuffer) throws {
        guard width >= 4, height >= 4, width <= 16384, height <= 16384,
              (1...7).contains(frames), (2...256).contains(tileSize),
              cfa.count == 4, alpha.count == 4, beta.count == 4 else {
            throw F5Failure(.damagedBundle, "Invalid curvature Bayer source layout.")
        }
        if device.isCancelled() { throw CancellationError() }
        var config = gc_f5_curve_source_config(width: UInt32(width), height: UInt32(height), frames: UInt32(frames),
            tile_size: UInt32(tileSize), flow_width: UInt32((width + tileSize - 1) / tileSize),
            flow_height: UInt32((height + tileSize - 1) / tileSize), cfa: (cfa[0], cfa[1], cfa[2], cfa[3]),
            alpha: (alpha[0], alpha[1], alpha[2], alpha[3]), beta: (beta[0], beta[1], beta[2], beta[3]),
            maximum_bytes: UInt64(device.maximumBytes - device.allocatedBytes))
        var error = gc_f5_curve_error()
        guard let source = gc_f5_curve_source_create(&config,
            Unmanaged.passUnretained(device.device as AnyObject).toOpaque(),
            Unmanaged.passUnretained(device.library as AnyObject).toOpaque(),
            Unmanaged.passUnretained(raw.metal as AnyObject).toOpaque(),
            Unmanaged.passUnretained(flow.metal as AnyObject).toOpaque(),
            Unmanaged.passUnretained(reliability.metal as AnyObject).toOpaque(), &error) else {
            try F5CurvatureNative.check(error)
            throw F5Failure(.memoryPressure, "Cannot create curvature Bayer source.")
        }
        do { allocation = try device.retainExternalAllocation(Int(gc_f5_curve_source_allocated_bytes(source))) }
        catch { gc_f5_curve_source_destroy(source); throw error }
        self.device = device; self.width = width; self.height = height; self.frames = frames; handle = source
        inputs = [raw, flow, reliability]
    }

    deinit { gc_f5_curve_source_destroy(handle) }

    func prepare(origins: UnsafePointer<gc_f5_curve_origin>, count: Int, input: inout gc_f5_curve_input) throws {
        if device.isCancelled() { throw CancellationError() }
        var error = gc_f5_curve_error()
        _ = gc_f5_curve_source_prepare(handle, origins, UInt32(count), &input, &error)
        try F5CurvatureNative.check(error)
    }
}
