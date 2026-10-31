import ImagingCore
import Capture
import Foundation
import Metal
import simd

final class F5MetalBuffer {
    let metal: MTLBuffer
    private let owner: F5MetalDevice
    private let accountedBytes: Int
    private let retainedOwner: AnyObject?
    init(_ metal: MTLBuffer, owner: F5MetalDevice, accountedBytes: Int? = nil, retaining: AnyObject? = nil) {
        self.metal = metal; self.owner = owner
        self.accountedBytes = accountedBytes ?? metal.length; retainedOwner = retaining
    }
    deinit { owner.release(accountedBytes) }
}

final class F5ExternalMetalAllocation {
    private let release: () -> Void
    init(release: @escaping () -> Void) { self.release = release }
    deinit { release() }
}

final class F5MetalDevice {
    let device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary
    let maximumBytes: Int
    let isCancelled: () -> Bool
    private(set) var allocatedBytes = 0, peakBytes = 0
    private var pipelines: [String: MTLComputePipelineState] = [:]
    init(maximumBytes: Int, shaderURL: URL? = nil, isCancelled: @escaping () -> Bool) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw F5Failure(.memoryPressure, "Metal is unavailable for F5 reconstruction.")
        }
        self.device = device; self.queue = queue; self.maximumBytes = maximumBytes; self.isCancelled = isCancelled
        if let shaderURL {
            let options = MTLCompileOptions(); options.mathMode = .safe; options.mathFloatingPointFunctions = .precise; options.languageVersion = .version3_1
            library = try device.makeLibrary(source: String(contentsOf: shaderURL, encoding: .utf8), options: options)
        } else if let compiled = device.makeDefaultLibrary() { library = compiled }
        else { throw F5Failure(.unsupportedRAW, "F5's Metal library is missing from the application.") }
    }
    func allocate(_ bytes: Int, label: String) throws -> F5MetalBuffer {
        guard bytes > 0, bytes <= device.maxBufferLength, bytes <= maximumBytes - allocatedBytes,
              let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw F5Failure(.memoryPressure, "F5 allocation exceeds its declared working-set budget: \(label).")
        }
        buffer.label = label; allocatedBytes += bytes; peakBytes = max(peakBytes, allocatedBytes)
        return F5MetalBuffer(buffer, owner: self)
    }
    func upload<T>(_ values: [T], label: String) throws -> F5MetalBuffer {
        try values.withUnsafeBufferPointer { try upload(Data(buffer: $0), label: label) }
    }
    func upload(_ data: Data, label: String) throws -> F5MetalBuffer {
        var bytes = data
        if bytes.count < 16 { bytes.count = 16 }
        guard bytes.count <= device.maxBufferLength, bytes.count <= maximumBytes - allocatedBytes else {
            throw F5Failure(.memoryPressure, "F5 upload exceeds its declared working-set budget: \(label).")
        }
        // Metal copies synchronously while the source owner is alive. Avoid
        // escaping a generic Array's temporary pointer through the buffer owner.
        let copied = bytes.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        guard let buffer = copied else { throw F5Failure(.memoryPressure, "Cannot upload F5 buffer: \(label).") }
        buffer.label = label; allocatedBytes += buffer.length; peakBytes = max(peakBytes, allocatedBytes)
        return F5MetalBuffer(buffer, owner: self)
    }
    fileprivate func release(_ count: Int) { allocatedBytes -= count }
    func retainExternalAllocation(_ bytes: Int) throws -> F5ExternalMetalAllocation {
        guard bytes >= 0, bytes <= maximumBytes - allocatedBytes else {
            throw F5Failure(.memoryPressure, "Native F5 buffers exceed the declared working-set budget.")
        }
        allocatedBytes += bytes; peakBytes = max(peakBytes, allocatedBytes)
        return F5ExternalMetalAllocation { self.release(bytes) }
    }
    func run(_ operation: (MTLCommandBuffer) throws -> Void) throws {
        if isCancelled() { throw CancellationError() }
        guard let command = queue.makeCommandBuffer() else { throw F5Failure(.memoryPressure, "Cannot allocate a Metal command buffer.") }
        try operation(command)
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw F5Failure(.numericalStall, command.error?.localizedDescription ?? "Metal command failed.") }
        if isCancelled() { throw CancellationError() }
    }
    func encode(_ name: String, count: Int, buffers: [MTLBuffer?], command: MTLCommandBuffer,
                constants: (MTLComputeCommandEncoder) -> Void = { _ in }) throws {
        if count == 0 { return }
        let pipeline: MTLComputePipelineState
        if let value = pipelines[name] { pipeline = value }
        else {
            guard let function = library.makeFunction(name: name) else { throw F5Failure(.unsupportedRAW, "Missing Metal kernel \(name).") }
            pipeline = try device.makeComputePipelineState(function: function); pipelines[name] = pipeline
        }
        guard let encoder = command.makeComputeCommandEncoder() else { throw F5Failure(.memoryPressure, "Cannot create an F5 compute encoder.") }
        encoder.label = name; encoder.setComputePipelineState(pipeline)
        for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
        constants(encoder)
        encoder.dispatchThreadgroups(MTLSize(width: (count + 255) / 256, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.endEncoding()
    }
    static func value<T>(_ value: T, at index: Int, encoder: MTLComputeCommandEncoder) {
        var value = value
        withUnsafeBytes(of: &value) { encoder.setBytes($0.baseAddress!, length: $0.count, index: index) }
    }
    func clear(_ buffer: MTLBuffer, command: MTLCommandBuffer, bytes: Int? = nil) throws {
        guard let blit = command.makeBlitCommandEncoder() else { throw F5Failure(.memoryPressure, "Cannot clear F5 scratch.") }
        blit.fill(buffer: buffer, range: 0..<(bytes ?? buffer.length), value: 0); blit.endEncoding()
    }
    func copy(_ from: MTLBuffer, to: MTLBuffer, bytes: Int, command: MTLCommandBuffer) throws {
        guard let blit = command.makeBlitCommandEncoder() else { throw F5Failure(.memoryPressure, "Cannot copy F5 scratch.") }
        blit.copy(from: from, sourceOffset: 0, to: to, destinationOffset: 0, size: bytes); blit.endEncoding()
    }
}

struct F5GPUFrame {
    var shape, active, cfa: SIMD4<UInt32>
    var scale, kappa, readSigma, low, high, gain, blackResidual: SIMD4<Float>
    var censorLow, censorHigh, black, tables, extras, extra2: SIMD4<UInt32>
}
struct F5GPUGrid {
    var shape, core: SIMD4<UInt32>
    var field: SIMD4<Int32>
    var counts: SIMD4<UInt32>
    var bin: SIMD4<Int32>
    var objective, regularizer, step: SIMD4<Float>
    var options: SIMD4<UInt32>
}
struct F5GPULUT {
    var layout: SIMD4<UInt32>
    var domain, width, limits: SIMD4<Float>
}
struct F5GPUEvent {
    var at, interval, score: SIMD4<Float>
    var info: SIMD4<UInt32>
    var source: SIMD4<Float>
    var frozenScore: SIMD4<Float> = .zero
}

