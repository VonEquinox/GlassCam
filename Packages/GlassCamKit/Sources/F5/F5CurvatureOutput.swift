import Foundation
import Metal
import ImagingCore
import CMetalF5

private final class F5CurvatureOutputCallbacks {
    let cancelled: () -> Bool, progress: (Double) -> Void
    init(cancelled: @escaping () -> Bool, progress: @escaping (Double) -> Void) { self.cancelled = cancelled; self.progress = progress }
}

enum F5CurvatureOutput {
    struct Result {
        let camera, linear: ExportRasterFile
        let width, height: Int
    }
    static func write(_ input: F5CurvatureRaster.Result, nativeWidth: Int, nativeHeight: Int,
                      metadata: F5DNGMetadata, matrix: [Double], device: F5MetalDevice,
                      progress: @escaping (Double) -> Void = { _ in }) throws -> Result {
        if device.isCancelled() { throw CancellationError() }
        guard nativeWidth > 0, nativeHeight > 0, input.width % nativeWidth == 0,
              input.height % nativeHeight == 0, input.width / nativeWidth == input.height / nativeHeight,
              matrix.count == 9, matrix.allSatisfy(\.isFinite) else {
            throw F5Failure(.colorTransformInvalid, "Invalid curvature output color or dimensions.")
        }
        let scale = input.width / nativeWidth, width = Int(floor(metadata.cropSize[0] * Double(scale))), height = Int(floor(metadata.cropSize[1] * Double(scale)))
        guard [1,2].contains(scale), width > 0, height > 0, width <= 32768, height <= 32768 else {
            throw F5Failure(.colorTransformInvalid, "Invalid curvature output crop.")
        }
        let post = try F5PostOperations.records(metadata)
        let operations = try device.upload(post.data.isEmpty ? [.zero] : post.data, label: "F5 ordered curvature output operations")
        defer { withExtendedLifetime(operations) {} }
        let m = matrix.map(Float.init)
        var configuration = gc_f5_curve_output_config(width: UInt32(nativeWidth), height: UInt32(nativeHeight), scale: UInt32(scale),
            output_width: UInt32(width), output_height: UInt32(height), operations: UInt32(post.ids.count),
            crop_x: Float(metadata.cropOrigin[0]), crop_y: Float(metadata.cropOrigin[1]),
            camera_to_linear: (m[0],m[1],m[2],m[3],m[4],m[5],m[6],m[7],m[8]), maximum_bytes: UInt64(device.maximumBytes - device.allocatedBytes))
        var error = gc_f5_curve_error()
        guard let context = gc_f5_curve_output_create(&configuration,
            Unmanaged.passUnretained(device.device as AnyObject).toOpaque(),
            Unmanaged.passUnretained(device.library as AnyObject).toOpaque(),
            Unmanaged.passUnretained(operations.metal as AnyObject).toOpaque(), &error) else {
            try F5CurvatureNative.check(error)
            throw F5Failure(.memoryPressure, "Cannot create curvature output context.")
        }
        defer { gc_f5_curve_output_destroy(context) }
        let allocation = try device.retainExternalAllocation(Int(gc_f5_curve_output_allocated_bytes(context)))
        defer { withExtendedLifetime(allocation) {} }
        let source = try FileHandle(forReadingFrom: input.file.url)
        defer { try? source.close() }
        let camera = try ExportRasterFile(), linear = try ExportRasterFile()
        let provider = F5CurvatureOutputCallbacks(cancelled: device.isCancelled, progress: progress)
        var callbacks = gc_f5_curve_callbacks(context: Unmanaged.passUnretained(provider).toOpaque(), prepare: nil, cancelled: { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<F5CurvatureOutputCallbacks>.fromOpaque(pointer).takeUnretainedValue().cancelled() ? 1 : 0
        }, progress: { pointer, completed in
            guard let pointer else { return }
            Unmanaged<F5CurvatureOutputCallbacks>.fromOpaque(pointer).takeUnretainedValue().progress(completed)
        })
        try input.file.handle.synchronize()
        _ = gc_f5_curve_output_write(context, source.fileDescriptor, camera.handle.fileDescriptor, linear.handle.fileDescriptor, &callbacks, &error)
        withExtendedLifetime(provider) {}
        try F5CurvatureNative.check(error)
        try camera.handle.synchronize(); try linear.handle.synchronize()
        return .init(camera: camera, linear: linear, width: width, height: height)
    }
}
