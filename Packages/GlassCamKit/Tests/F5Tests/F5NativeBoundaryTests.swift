import Testing
import Foundation
import CMetalF5
import ImagingCore
@testable import F5

@Suite(.serialized)
struct F5NativeBoundaryTests {
    @Test func archiveAliasedDescriptors_preserveSource() throws {
        let source = try ExportRasterFile()
        try source.append(Array(repeating: [Float](arrayLiteral: 0.25,0.5,1.2,1), count: 8 * 6).flatMap { $0 })
        try source.handle.synchronize()
        let before = try Data(contentsOf: source.url)
        let reader = try FileHandle(forReadingFrom: source.url)
        let alias = try FileHandle(forUpdating: source.url)
        defer { try? reader.close(); try? alias.close() }
        var error = gc_f5_curve_error()

        let status = gc_f5_curve_write_rgb(reader.fileDescriptor, alias.fileDescriptor,
                                            8, 6, 0, nil, &error)

        #expect(status == 1)
        #expect(try Data(contentsOf: source.url) == before)
    }

    @Test func colorOutputAliasedDescriptors_preserveSource() throws {
        let device = try F5MetalDevice(maximumBytes: 64 * 1024 * 1024, shaderURL: F5TestContext.shader, isCancelled: { false })
        let operations = try device.upload([SIMD4<Float>.zero], label: "No lens operations")
        var configuration = gc_f5_curve_output_config(width: 8, height: 6, scale: 1,
            output_width: 8, output_height: 6, operations: 0, crop_x: 0, crop_y: 0,
            camera_to_linear: (2,0,0,0,2,0,0,0,2), maximum_bytes: UInt64(device.maximumBytes))
        var error = gc_f5_curve_error()
        let context = try #require(gc_f5_curve_output_create(&configuration,
            Unmanaged.passUnretained(device.device as AnyObject).toOpaque(),
            Unmanaged.passUnretained(device.library as AnyObject).toOpaque(),
            Unmanaged.passUnretained(operations.metal as AnyObject).toOpaque(), &error))
        defer { gc_f5_curve_output_destroy(context); withExtendedLifetime(operations) {} }
        let source = try ExportRasterFile()
        try source.append([Float](repeating: 0.5, count: 8 * 6 * 4))
        try source.handle.synchronize()
        let before = try Data(contentsOf: source.url)
        let reader = try FileHandle(forReadingFrom: source.url)
        let alias = try FileHandle(forUpdating: source.url)
        defer { try? reader.close(); try? alias.close() }

        let status = gc_f5_curve_output_write(context, reader.fileDescriptor,
                                              -1, alias.fileDescriptor, nil, &error)

        #expect(status == 1)
        #expect(try Data(contentsOf: source.url) == before)
    }

    @Test func cancelledRegistration_consumesSingleUseContext() throws {
        let device = try F5MetalDevice(maximumBytes: 64 * 1024 * 1024, shaderURL: F5TestContext.shader, isCancelled: { false })
        let raw = try device.upload([Float](repeating: 0.25, count: 8 * 6), label: "Constant Bayer signal")
        let kinds = try device.upload([UInt8](repeating: 0, count: 8 * 6), label: "Normal samples")
        var configuration = gc_f5_curve_registration_config(width: 8, height: 6, frames: 1, cfa: (0,1,1,2),
            alpha: (0,0,0,0), beta: (1e-6,1e-6,1e-6,1e-6), maximum_bytes: UInt64(device.maximumBytes))
        var error = gc_f5_curve_error()
        let context = try #require(gc_f5_curve_registration_create(&configuration,
            Unmanaged.passUnretained(device.device as AnyObject).toOpaque(),
            Unmanaged.passUnretained(device.library as AnyObject).toOpaque(),
            Unmanaged.passUnretained(raw.metal as AnyObject).toOpaque(),
            Unmanaged.passUnretained(kinds.metal as AnyObject).toOpaque(), &error))
        defer { gc_f5_curve_registration_destroy(context); withExtendedLifetime((raw,kinds)) {} }
        var cancelled = gc_f5_curve_callbacks(context: nil, prepare: nil, cancelled: { _ in 1 }, progress: nil)
        let first = gc_f5_curve_registration_run(context, &cancelled, &error)

        let retry = gc_f5_curve_registration_run(context, nil, &error)

        #expect(first == 4)
        #expect(retry == 1)
    }
}
