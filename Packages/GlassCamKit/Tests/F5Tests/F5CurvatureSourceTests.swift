import Testing
import Foundation
import CMetalF5
@testable import F5

@Suite(.serialized)
struct F5CurvatureSourceTests {
    @Test func singleFrame_curvatureReducesNoiseAndPreservesLowFrequencyTexture() throws {
        let device = try device(), width = 80, height = 80
        let pattern: [UInt32] = [0,1,1,2]
        var state: UInt64 = 0x69736f
        var samples: [Float] = [], signal: [SIMD3<Float>] = []
        for y in 0..<height { for x in 0..<width {
            let light = Float(0.04 * sin(Double(x) * 0.09 + Double(y) * 0.05))
            let target = SIMD3<Float>(0.2,0.3,0.4) + SIMD3<Float>(repeating: light)
            signal.append(target)
            state = state &* 6364136223846793005 &+ 1
            let noise = (Float(state >> 40) / Float(1 << 24) - 0.5) * 0.04
            samples.append(target[Int(pattern[(y & 1) * 2 + (x & 1)])] + noise)
        } }
        let tiles = ((width + 15) / 16) * ((height + 15) / 16)
        let prepared = try F5CurvatureBayerSource(device: device,width: width,height: height,frames: 1,tileSize: 16,
            cfa: pattern,alpha: [Float](repeating: 0,count: 4),beta: [Float](repeating: 0.04 * 0.04 / 12,count: 4),
            raw: device.upload(samples,label: "Noisy known Bayer signal"),
            flow: device.upload([SIMD2<Float>](repeating: .zero,count: tiles),label: "Single-frame identity"),
            reliability: device.upload([Float](repeating: 1,count: width * height / 4),label: "Single-frame confidence"))

        let result = try F5CurvatureRaster(device: device).reconstruct(source: prepared,scale: 1)

        let output = try result.file.mappedData(expectedBytes: width * height * 16)
        let rms = output.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to: SIMD4<Float>.self)
            var squared: Double = 0
            for i in signal.indices {
                let error = SIMD3(values[i].x,values[i].y,values[i].z) - signal[i]
                squared += Double(error.x * error.x + error.y * error.y + error.z * error.z)
            }
            return sqrt(squared / Double(width * height * 3))
        }
        let inputNoiseRMS = 0.04 / sqrt(12.0)
        #expect(rms < inputNoiseRMS * 0.7)
    }
    private let patterns: [[UInt32]] = [[0,1,1,2], [2,1,1,0], [1,0,2,1], [1,2,0,1]]
    private func device() throws -> F5MetalDevice {
        try F5MetalDevice(maximumBytes: 32 * 1024 * 1024, shaderURL: F5TestContext.shader, isCancelled: { false })
    }
    private func source(device: F5MetalDevice, pattern: [UInt32], wave: Bool,
                        invalidReliability: Float? = nil, cameraConstant: Bool = false,
                        width: Int = 80, height: Int = 80) throws -> F5CurvatureBayerSource {
        let frames = 4, tiles = ((width + 15) / 16) * ((height + 15) / 16)
        let shifts: [SIMD2<Float>] = [.zero, .init(0.25,0.5), .init(-0.5,0.25), .init(0.75,-0.5)]
        let base = SIMD3<Float>(0.2,0.3,0.4), slope = SIMD2<Float>(0.0002,0.0003)
        let raw = (0..<frames * width * height).map { i -> Float in
            let f = i / (width * height), x = i % width, y = i / width % height
            if cameraConstant { return base[Int(pattern[(y & 1) * 2 + (x & 1)])] }
            if !wave { return 1.2 }
            return base[Int(pattern[(y & 1) * 2 + (x & 1)])] + slope.x * (Float(x) - shifts[f].x) + slope.y * (Float(y) - shifts[f].y)
        }
        let flow = (0..<frames * tiles).map { shifts[$0 / tiles] }
        var reliability = [Float](repeating: 1, count: frames * width * height / 4)
        if let invalidReliability { reliability[0] = invalidReliability }
        return try .init(device: device, width: width, height: height, frames: frames, tileSize: 16,
                         cfa: pattern, alpha: [Float](repeating: 0, count: 4), beta: [Float](repeating: 1e-6, count: 4),
                         raw: device.upload(raw, label: "Analytic Bayer ramp"), flow: device.upload(flow, label: "Known subpixel motion"),
                         reliability: device.upload(reliability, label: "Known reliability"))
    }

    @Test(arguments: [[UInt32(0),1,1,2], [UInt32(2),1,1,0], [UInt32(1),0,2,1], [UInt32(1),2,0,1]])
    func translatedBayerRamp_preparesCameraStatisticsAndUnwindowedSamples(pattern: [UInt32]) throws {
        let device = try device(), source = try source(device: device, pattern: pattern, wave: true)
        let native = try F5CurvatureNative(device: device, width: 0, height: 0, scale: 1, capacity: 1, planes: 16, slots: 1, estimateColorPrior: true)
        defer { withExtendedLifetime(native) {} }
        var input = gc_f5_curvature_input(native.handle, 0), origin = gc_f5_curve_origin(x: 16, y: 16)

        try source.prepare(origins: &origin, count: 1, input: &input)

        let expectedMean = SIMD3<Float>(0.2,0.3,0.4) + SIMD3<Float>(repeating: (0.0002 + 0.0003) * 31.5)
        var meanError: Float = 0, varianceError: Float = 0, observationError: Float = 0
        for c in 0..<3 {
            meanError = max(meanError, abs(input.means[c] - expectedMean[c]))
            // Variance of a uniformly sampled 32-pixel linear ramp: (32²−1)/12.
            let expectedVariance: Float = (0.0002 * 0.0002 + 0.0003 * 0.0003) * 85.25
            varianceError = max(varianceError, abs(input.statistics[c] - expectedVariance))
        }
        let shifts: [SIMD2<Float>] = [.zero, .init(0.25,0.5), .init(-0.5,0.25), .init(0.75,-0.5)]
        for row in 0..<16 {
            let phase = row % 4, shift = shifts[row / 4], channel = Int(pattern[phase])
            let base = SIMD3<Float>(0.2,0.3,0.4)[channel]
            let position = SIMD2(input.models[row * 4], input.models[row * 4 + 1])
            for i in 0..<256 {
                let x = Float(16 + i % 16 * 2) + position.x, y = Float(16 + i / 16 * 2) + position.y
                observationError = max(observationError, abs(input.samples[row * 256 + i] - (base + 0.0002 * x + 0.0003 * y)))
            }
            let expectedX = floor(shift.x / 2) * 2 - shift.x + Float(phase % 2)
            observationError = max(observationError, abs(position.x - expectedX), abs(input.models[row * 4 + 3] - 1))
        }
        // Absolute FP32 reduction/interpolation budgets are below a normalized
        // 14-bit code step; variance uses its squared-light scale.
        #expect(meanError < 2e-6)
        #expect(varianceError < 1e-9)
        #expect(observationError < 2e-6)
    }

    @Test(arguments: [1, 2])
    func normalizedBayerToRaster_preservesHDRThroughGuideAndCurvature(scale: Int) throws {
        let device = try device(), source = try source(device: device, pattern: patterns[0], wave: false, width: 70, height: 78)

        let result = try F5CurvatureRaster(device: device).reconstruct(source: source, scale: scale, batchSize: 3)

        let data = try result.file.mappedData(expectedBytes: result.width * result.height * 16)
        let maximum = data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: SIMD4<Float>.self).reduce(Float(0)) { maximum, pixel in
                max(maximum, abs(pixel.x - 1.2), abs(pixel.y - 1.2), abs(pixel.z - 1.2), abs(pixel.w - 1))
            }
        }
        let linearTolerance: Float = 3e-5 // Shared full-raster linear-light budget.
        #expect(maximum < linearTolerance)
    }

    @Test(arguments: [[UInt32(0),1,1,2], [UInt32(2),1,1,0]])
    func reflectedSourceBoundary_preservesCFAPlaneColors(pattern: [UInt32]) throws {
        let device = try device(), source = try source(device: device, pattern: pattern, wave: false, cameraConstant: true)
        let native = try F5CurvatureNative(device: device, width: 0, height: 0, scale: 1, capacity: 1, planes: 16, slots: 1, estimateColorPrior: true)
        defer { withExtendedLifetime(native) {} }
        var input = gc_f5_curvature_input(native.handle, 0), origin = gc_f5_curve_origin(x: -16, y: -16)

        try source.prepare(origins: &origin, count: 1, input: &input)

        let base = SIMD3<Float>(0.2,0.3,0.4)
        let samples = UnsafeBufferPointer(start: input.samples, count: 16 * 256)
        let maximum = samples.enumerated().reduce(Float(0)) { maximum, entry in
            max(maximum, abs(entry.element - base[Int(pattern[entry.offset / 256 % 4])]))
        }
        #expect(maximum == 0)
    }

    @Test(arguments: [[UInt32(0),1,1,2], [UInt32(2),1,1,0], [UInt32(1),0,2,1], [UInt32(1),2,0,1]],
          [SIMD2<Int32>(-16,-16), .init(64,-16), .init(-16,64), .init(64,64), .init(16,16)])
    func sensorEdgeGuide_preservesConstantCameraColour(pattern: [UInt32], position: SIMD2<Int32>) throws {
        let device = try device()
        let source = try source(device: device, pattern: pattern, wave: false, cameraConstant: true)
        let native = try F5CurvatureNative(device: device, width: 0, height: 0, scale: 1, capacity: 1, planes: 16, slots: 1, estimateColorPrior: true)
        defer { withExtendedLifetime(native) {} }
        var input = gc_f5_curvature_input(native.handle, 0)
        var origin = gc_f5_curve_origin(x: position.x, y: position.y)

        try source.prepare(origins: &origin, count: 1, input: &input)

        let mean = SIMD3(input.means[0], input.means[1], input.means[2])
        let difference = mean - SIMD3<Float>(0.2, 0.3, 0.4)
        // The same FP32 reduction budget as an interior 32×32 guide patch.
        #expect(max(abs(difference.x), abs(difference.y), abs(difference.z)) < 2e-6)
        #expect(max(input.statistics[0], input.statistics[1], input.statistics[2]) < 1e-9)
    }

    @Test(arguments: [Float.nan, Float(-0.1), Float(1.1)])
    func invalidReliability_rejectsGPUPreparation(value: Float) throws {
        let device = try device(), source = try source(device: device, pattern: patterns[0], wave: false, invalidReliability: value)

        #expect(throws: F5Failure.self) { try F5CurvatureRaster(device: device).reconstruct(source: source) }
    }

    @Test func sourceLifetime_keepsBorrowedGPUInputsAccounted() throws {
        let device = try device()
        var retained: F5CurvatureBayerSource? = try source(device: device, pattern: patterns[0], wave: false)
        let activeBytes = withExtendedLifetime(retained) { device.allocatedBytes }

        retained = nil

        #expect(activeBytes >= 4 * 80 * 80 * 4)
        #expect(device.allocatedBytes == 0)
        withExtendedLifetime(retained) {}
    }
}
