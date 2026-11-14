import Testing
import Foundation
import Metal
@testable import F5

@Suite(.serialized)
struct F5CurvatureTests {
    private let means = SIMD3<Float>(0.2, 0.3, 0.4)
    private func device(cancelled: @escaping () -> Bool = { false }) throws -> F5MetalDevice {
        try F5MetalDevice(maximumBytes: 32 * 1024 * 1024, shaderURL: F5TestContext.shader, isCancelled: cancelled)
    }
    private func patch(pattern: [UInt32], wave: Bool = false, origin: SIMD2<Int32> = .zero) -> F5CurvaturePatch {
        let displacements: [SIMD2<Float>] = [.zero, .init(0.5, 0), .init(0, 0.5), .init(0.5, 0.5)]
        let amplitude = SIMD3<Float>(0.03, 0.04, 0.02)
        var planes: [F5CurvaturePlane] = []
        for displacement in displacements {
            for phase in 0..<4 {
                let position = displacement + SIMD2(Float(phase % 2), Float(phase / 2))
                let channel = pattern[phase]
                let samples = (0..<256).map { i -> Float in
                    let x = Double(origin.x) + Double(i % 16 * 2) + Double(position.x) + 0.5
                    let y = Double(origin.y) + Double(i / 16 * 2) + Double(position.y) + 0.5
                    let detail = wave ? Double(amplitude[Int(channel)]) * cos(2 * .pi * (2 * x + 3 * y) / 32) : 0
                    return means[Int(channel)] + Float(detail)
                }
                planes.append(.init(samples: samples, position: position, channel: channel, variance: 1e-6, confidence: 1))
            }
        }
        return .init(planes: planes, mean: means, colorPrecision: [1e-4, 0, 0, 0, 1e-4, 0, 0, 0, 1e-4])
    }
    @Test(arguments: [[UInt32(0), 1, 1, 2], [UInt32(2), 1, 1, 0]], [1, 2])
    func constantBayer_preservesCameraColor(pattern: [UInt32], scale: Int) throws {
        let device = try device()
        let input = patch(pattern: pattern)

        let output = try F5CurvatureBatch(device: device).reconstruct([input], scale: scale)

        let side = 32 * scale, pixels = output.metal.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        var maximum = 0.0
        for y in 0..<side { for x in 0..<side {
            let wx = pow(sin(.pi * (Double(x) + 0.5) / Double(side)), 2)
            let wy = pow(sin(.pi * (Double(y) + 0.5) / Double(side)), 2)
            for c in 0..<3 { maximum = max(maximum, abs(Double(pixels[y * side + x][c]) - Double(means[c]) * wx * wy)) }
        }}
        // FFT, FP32 posterior solve and Fourier interpolation share this
        // absolute linear-light budget, below one normalized 14-bit RAW step.
        let linearTolerance = 2e-5
        #expect(maximum < linearTolerance)
    }
    @Test(arguments: [1, 2])
    func subpixelBayer_recoversBandlimitedDetail(scale: Int) throws {
        let device = try device()
        let input = patch(pattern: [0, 1, 1, 2], wave: true)

        let output = try F5CurvatureBatch(device: device).reconstruct([input], scale: scale)

        let side = 32 * scale, pixels = output.metal.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let amplitude = SIMD3<Double>(0.03, 0.04, 0.02)
        var maximum = 0.0
        for y in 0..<side { for x in 0..<side {
            let px = (Double(x) + 0.5) / Double(scale), py = (Double(y) + 0.5) / Double(scale)
            let window = pow(sin(.pi * (Double(x) + 0.5) / Double(side)), 2) * pow(sin(.pi * (Double(y) + 0.5) / Double(side)), 2)
            for c in 0..<3 {
                let expected = (Double(means[c]) + amplitude[c] * cos(2 * .pi * (2 * px + 3 * py) / 32)) * window
                maximum = max(maximum, abs(Double(pixels[y * side + x][c]) - expected))
            }
        }}
        let linearTolerance = 2e-5 // Same 14-bit linear-light budget as the constant-field case.
        #expect(maximum < linearTolerance)
    }
    @Test func invalidNoise_rejectsBatch() throws {
        let device = try device()
        let valid = patch(pattern: [0, 1, 1, 2]), plane = valid.planes[0]
        var planes = valid.planes
        planes[0] = .init(samples: plane.samples, position: plane.position, channel: plane.channel, variance: 0, confidence: 1)
        let input = F5CurvaturePatch(planes: planes, mean: valid.mean, colorPrecision: valid.colorPrecision)

        #expect(throws: F5Failure.self) { try F5CurvatureBatch(device: device).reconstruct([input]) }
    }
    @Test(arguments: [1, 2])
    func automaticPrior_preservesConstantCameraColor(scale: Int) throws {
        let device = try device()
        var input = patch(pattern: [0, 1, 1, 2])
        input.moments = .init(measuredVariance: .zero, guideNoise: .init(repeating: 1e-7))

        let raster = try F5CurvatureRaster(device: device).reconstruct(width: 10, height: 8, scale: scale, estimateColorPrior: true) { origins in
            origins.map { _ in input }
        }

        let data = try raster.file.mappedData(expectedBytes: raster.width * raster.height * 16)
        let maximum = data.withUnsafeBytes { raw in
            raw.bindMemory(to: SIMD4<Float>.self).reduce(Float(0)) { error, pixel in
                max(error, abs(pixel.x - means.x), abs(pixel.y - means.y), abs(pixel.z - means.z))
            }
        }
        let linearTolerance: Float = 3e-5 // The same normalized 14-bit half-step as provided priors.
        #expect(maximum < linearTolerance)
    }
    @Test(arguments: [1, 2])
    func automaticPrior_preservesMeasuredBandlimitedDetail(scale: Int) throws {
        let device = try device()
        var input = patch(pattern: [0, 1, 1, 2], wave: true)
        input.moments = .init(measuredVariance: .init(0.00045, 0.0008, 0.0002), guideNoise: .init(repeating: 1e-7))

        let output = try F5CurvatureBatch(device: device).reconstruct([input], scale: scale)

        let side = 32 * scale, pixels = output.metal.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let amplitude = SIMD3<Double>(0.03, 0.04, 0.02)
        var maximum = 0.0
        for y in 0..<side { for x in 0..<side { for c in 0..<3 {
            let px = (Double(x) + 0.5) / Double(scale), py = (Double(y) + 0.5) / Double(scale)
            let window = pow(sin(.pi * (Double(x) + 0.5) / Double(side)), 2) * pow(sin(.pi * (Double(y) + 0.5) / Double(side)), 2)
            let expected = (Double(means[c]) + amplitude[c] * cos(2 * .pi * (2 * px + 3 * py) / 32)) * window
            maximum = max(maximum, abs(Double(pixels[y * side + x][c]) - expected))
        }}}
        let linearTolerance = 1e-4 // Allows finite-noise MAP shrinkage of this unit-signal control.
        #expect(maximum < linearTolerance)
    }
    @Test(arguments: [Float.nan, Float.infinity, -Float.infinity])
    func nonfiniteObservation_isRejectedOnGPU(value: Float) throws {
        let device = try device(), valid = patch(pattern: [0, 1, 1, 2])
        let plane = valid.planes[0]
        var samples = plane.samples; samples[0] = value
        var planes = valid.planes
        planes[0] = .init(samples: samples, position: plane.position, channel: plane.channel, variance: plane.variance, confidence: plane.confidence)
        let input = F5CurvaturePatch(planes: planes, mean: valid.mean, colorPrecision: valid.colorPrecision)
        var code: F5Code?

        do { _ = try F5CurvatureBatch(device: device).reconstruct([input]) }
        catch let failure as F5Failure { code = failure.code }

        #expect(code == .damagedBundle)
        #expect(device.allocatedBytes == 0)
    }
    @Test func insufficientBudget_rejectsBeforePreparingPatches() throws {
        let device = try F5MetalDevice(maximumBytes: 512 * 1024, shaderURL: F5TestContext.shader, isCancelled: { false })
        var prepared = 0, code: F5Code?

        do {
            _ = try F5CurvatureRaster(device: device).reconstruct(width: 70, height: 78) { origins in
                prepared += origins.count
                return origins.map { patch(pattern: [0, 1, 1, 2], origin: $0) }
            }
        } catch let failure as F5Failure { code = failure.code }

        #expect(code == .memoryPressure)
        #expect(prepared == 0)
        #expect(device.allocatedBytes == 0)
    }
    @Test(arguments: [1, 2], [1, 3, F5CurvatureBatch.maximumPatches])
    func overlappingPatches_preserveDetailAcrossStripsAndEdges(scale: Int, batchSize: Int) throws {
        let device = try device(), width = 70, height = 78
        let amplitude = SIMD3<Double>(0.03, 0.04, 0.02)

        let raster = try F5CurvatureRaster(device: device).reconstruct(width: width, height: height, scale: scale, batchSize: batchSize) { origins in
            origins.map { patch(pattern: [0, 1, 1, 2], wave: true, origin: $0) }
        }

        let data = try raster.file.mappedData(expectedBytes: raster.width * raster.height * 16)
        let maximum = data.withUnsafeBytes { bytes -> Double in
            let pixels = bytes.bindMemory(to: SIMD4<Float>.self)
            var error = 0.0
            for y in 0..<raster.height { for x in 0..<raster.width { for c in 0..<3 {
                let px = (Double(x) + 0.5) / Double(scale), py = (Double(y) + 0.5) / Double(scale)
                let expected = Double(means[c]) + amplitude[c] * cos(2 * .pi * (2 * px + 3 * py) / 32)
                error = max(error, abs(Double(pixels[y * raster.width + x][c]) - expected))
            }}}
            return error
        }
        let linearTolerance = 3e-5 // A normalized 14-bit RAW half-step, including overlap normalization.
        #expect(maximum < linearTolerance)
    }
    @Test func cancellation_releasesBatchBuffers() throws {
        let device = try device(cancelled: { true })
        let input = patch(pattern: [0, 1, 1, 2])

        #expect(throws: CancellationError.self) { try F5CurvatureBatch(device: device).reconstruct([input]) }

        #expect(device.allocatedBytes == 0)
    }
    @Test func signedHDR_preservesLinearRange() throws {
        let device = try device(), field = SIMD3<Float>(-0.002, 0, 1.3)
        let model = patch(pattern: [0, 1, 1, 2])
        let input = F5CurvaturePatch(planes: model.planes.map { plane in
            .init(samples: Array(repeating: field[Int(plane.channel)], count: 256), position: plane.position,
                  channel: plane.channel, variance: plane.variance, confidence: plane.confidence)
        }, mean: field, colorPrecision: model.colorPrecision)

        let raster = try F5CurvatureRaster(device: device).reconstruct(width: 10, height: 8) { origins in
            origins.map { _ in input }
        }

        let data = try raster.file.mappedData(expectedBytes: raster.width * raster.height * 16)
        let maximum = data.withUnsafeBytes { raw in
            raw.bindMemory(to: SIMD4<Float>.self).reduce(Float(0)) { error, pixel in
                max(error, abs(pixel.x - field.x), abs(pixel.y - field.y), abs(pixel.z - field.z))
            }
        }
        let linearTolerance: Float = 3e-5 // Same normalized 14-bit half-step as overlap-add.
        #expect(maximum < linearTolerance)
    }
    @Test(arguments: [1, 4, 5])
    func coincidentFrames_preserveConstantColor(frameCount: Int) throws {
        let device = try device(), pattern: [UInt32] = [0, 1, 1, 2]
        let planes = (0..<(frameCount * 4)).map { i -> F5CurvaturePlane in
            let channel = pattern[i % 4]
            return .init(samples: Array(repeating: means[Int(channel)], count: 256),
                         position: .init(Float(i % 2), Float(i % 4 / 2)), channel: channel,
                         variance: i / 4 == 4 ? 1e-3 : 1e-5, confidence: 1)
        }
        // A finite colour covariance supplies the modes that coincident CFA
        // phases cannot distinguish; the fifth observation has short-frame noise.
        let precision: Float = 10_000
        let input = F5CurvaturePatch(planes: planes, mean: means,
            colorPrecision: [precision, 0, 0, 0, precision, 0, 0, 0, precision])

        let raster = try F5CurvatureRaster(device: device).reconstruct(width: 10, height: 8) { origins in
            origins.map { _ in input }
        }

        let data = try raster.file.mappedData(expectedBytes: raster.width * raster.height * 16)
        let maximum = data.withUnsafeBytes { raw in
            raw.bindMemory(to: SIMD4<Float>.self).reduce(Float(0)) { error, pixel in
                max(error, abs(pixel.x - means.x), abs(pixel.y - means.y), abs(pixel.z - means.z))
            }
        }
        let linearTolerance: Float = 3e-5 // Same 14-bit half-step as the other raster controls.
        #expect(maximum < linearTolerance)
    }
    @Test func cancelledRaster_releasesRollingAndBatchBuffers() throws {
        var cancelled = false
        let device = try device(cancelled: { cancelled })

        #expect(throws: CancellationError.self) {
            try F5CurvatureRaster(device: device).reconstruct(width: 70, height: 78, progress: { completed in
                if completed > 0 { cancelled = true }
            }) { origins in origins.map { patch(pattern: [0, 1, 1, 2], origin: $0) } }
        }

        #expect(device.allocatedBytes == 0)
    }
    @Test(arguments: [SIMD2<Int>(16, 0), SIMD2<Int>(0, 16), SIMD2<Int>(16, 3), SIMD2<Int>(16, 16)], [1, 2])
    func subpixelBayer_recoversNyquistBoundaryDetail(frequency: SIMD2<Int>, scale: Int) throws {
        let device = try device()
        let pattern: [UInt32] = [0, 1, 1, 2]
        let displacements: [SIMD2<Float>] = [.zero, .init(0.37, 0.11), .init(-0.19, 0.43), .init(0.47, -0.31)]
        let amplitude = SIMD3<Double>(0.03, 0.04, 0.02)
        func nyquistSignal(_ channel: Int, _ tx: Double, _ ty: Double) -> Double {
            let nx = cos(.pi * Double(frequency.x) * tx / 16)
            let ny = cos(.pi * Double(frequency.y) * ty / 16)
            return amplitude[channel] * nx * ny
        }
        var planes: [F5CurvaturePlane] = []
        for displacement in displacements {
            for phase in 0..<4 {
                let position = displacement + SIMD2(Float(phase % 2), Float(phase / 2))
                let channel = pattern[phase]
                let samples = (0..<256).map { i -> Float in
                    let tx = Double(i % 16 * 2) + Double(position.x)
                    let ty = Double(i / 16 * 2) + Double(position.y)
                    let wx = pow(sin(.pi * (tx + 0.5) / 32), 2), wy = pow(sin(.pi * (ty + 0.5) / 32), 2)
                    let window = max(wx * wy, 1e-12)
                    return means[Int(channel)] + Float(nyquistSignal(Int(channel), tx, ty) / window)
                }
                planes.append(.init(samples: samples, position: position, channel: channel, variance: 1e-7, confidence: 1))
            }
        }
        let input = F5CurvaturePatch(planes: planes, mean: means, colorPrecision: [1e-6, 0, 0, 0, 1e-6, 0, 0, 0, 1e-6])

        let output = try F5CurvatureBatch(device: device).reconstruct([input], scale: scale)

        let side = 32 * scale, pixels = output.metal.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        var maximum = 0.0
        for y in 0..<side { for x in 0..<side {
            let tx = (Double(x) + 0.5) / Double(scale) - 0.5
            let ty = (Double(y) + 0.5) / Double(scale) - 0.5
            let window = pow(sin(.pi * (Double(x) + 0.5) / Double(side)), 2) * pow(sin(.pi * (Double(y) + 0.5) / Double(side)), 2)
            for c in 0..<3 {
                let expected = Double(means[c]) * window + nyquistSignal(c, tx, ty)
                maximum = max(maximum, abs(Double(pixels[y * side + x][c]) - expected))
            }
        }}
        let linearTolerance = 3e-5 // Normalized 14-bit half-step for cosine-split Nyquist synthesis.
        #expect(maximum < linearTolerance)
    }
}
