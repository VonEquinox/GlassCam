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
        try values.withUnsafeBytes { raw in
            if raw.count >= 16, let base = raw.baseAddress {
                return try uploadBytes(base, count: raw.count, label: label)
            }
            var padded = Data(raw)
            if padded.count < 16 { padded.count = 16 }
            return try padded.withUnsafeBytes { try uploadBytes($0.baseAddress!, count: $0.count, label: label) }
        }
    }
    func upload(_ data: Data, label: String) throws -> F5MetalBuffer {
        if data.count >= 16 {
            return try data.withUnsafeBytes { try uploadBytes($0.baseAddress!, count: $0.count, label: label) }
        }
        var bytes = data
        bytes.count = 16
        return try bytes.withUnsafeBytes { try uploadBytes($0.baseAddress!, count: $0.count, label: label) }
    }
    private func uploadBytes(_ baseAddress: UnsafeRawPointer, count: Int, label: String) throws -> F5MetalBuffer {
        guard count <= device.maxBufferLength, count <= maximumBytes - allocatedBytes else {
            throw F5Failure(.memoryPressure, "F5 upload exceeds its declared working-set budget: \(label).")
        }
        guard let buffer = device.makeBuffer(bytes: baseAddress, length: count, options: .storageModeShared) else {
            throw F5Failure(.memoryPressure, "Cannot upload F5 buffer: \(label).")
        }
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
}

struct F5GPUFrame {
    var shape, active, cfa: SIMD4<UInt32>
    var scale, kappa, readSigma, low, high, gain, blackResidual: SIMD4<Float>
    var censorLow, censorHigh, black, tables, extras, extra2: SIMD4<UInt32>
}
