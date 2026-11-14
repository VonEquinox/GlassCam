import Testing
import Foundation
import Metal
@testable import F5

@Suite(.serialized)
struct F5CurvatureRegistrationTests {
    private func device() throws -> F5MetalDevice {
        try F5MetalDevice(maximumBytes: 64 * 1024 * 1024, shaderURL: F5TestContext.shader, isCancelled: { false })
    }

    @Test func mixedRadixFFT_matchesAnalyticImpulseSpectrum() throws {
        let device = try device(), width = 18, height = 14, count = width * height
        let location = SIMD2<Int>(5,3)
        var impulse = [SIMD2<Float>](repeating: .zero, count: count)
        impulse[location.y * width + location.x] = .init(1,0)
        var input = try device.upload(impulse, label: "Known spatial impulse")
        var output = try device.allocate(count * 8, label: "FFT ping pong")

        let command = try #require(device.queue.makeCommandBuffer())
        let function = try #require(device.library.makeFunction(name: "f5_reg_fft_stage"))
        let pipeline = try device.device.makeComputePipelineState(function: function)
        for axis in 0..<2 {
            let length = axis == 0 ? width : height
            var remaining = length, product = 1
            for radix in [2,3,5,7] {
                while remaining % radix == 0 {
                    var parameters = SIMD8<UInt32>(UInt32(width),UInt32(height),UInt32(axis),0,
                        UInt32(length),UInt32(radix),UInt32(product),0)
                    let encoder = try #require(command.makeComputeCommandEncoder())
                    encoder.setComputePipelineState(pipeline)
                    encoder.setBuffer(input.metal, offset: 0, index: 0)
                    encoder.setBuffer(output.metal, offset: 0, index: 1)
                    encoder.setBytes(&parameters, length: MemoryLayout<SIMD8<UInt32>>.stride, index: 2)
                    encoder.dispatchThreadgroups(MTLSize(width: (count + 255) / 256, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                    encoder.endEncoding()
                    swap(&input,&output); product *= radix; remaining /= radix
                }
            }
        }
        command.commit(); command.waitUntilCompleted()
        try #require(command.status == .completed)

        let spectrum = input.metal.contents().assumingMemoryBound(to: SIMD2<Float>.self)
        let maximum = (0..<count).reduce(Float(0)) { error, i in
            let phase = -2 * Double.pi * (Double((i % width) * location.x) / Double(width) + Double((i / width) * location.y) / Double(height))
            return max(error,abs(spectrum[i].x - Float(cos(phase))),abs(spectrum[i].y - Float(sin(phase))))
        }
        // FFT phase recurrence accumulates FP32 rounding across mixed radices.
        #expect(maximum < 2e-5)
    }

    private func register(shifts: [SIMD2<Float>], movingObject: Bool = false) throws -> F5CurvatureRegistration {
        let device = try device(), width = 256, height = 256, pattern = [0,1,1,2]
        var values = [Float](repeating: 0, count: shifts.count * width * height)
        for f in shifts.indices {
            for y in 0..<height { for x in 0..<width {
                let px = Float(x) - shifts[f].x, py = Float(y) - shifts[f].y
                let texture = 0.35 + 0.06 * sin(0.17 * px + 0.11 * py) + 0.07 * cos(0.073 * px - 0.241 * py)
                    + 0.03 * sin(0.31 * px + 0.29 * py)
                let channel = pattern[(y & 1) * 2 + (x & 1)]
                values[(f * height + y) * width + x] = movingObject && f > 0 && (96..<160).contains(x) && (96..<160).contains(y)
                    ? 0.8 : texture * [Float(0.8),1,0.7][channel]
            } }
        }
        return try F5CurvatureRegistration(device: device, width: width, height: height, frames: shifts.count,
            cfa: pattern.map(UInt32.init), alpha: [Float](repeating: 1e-4, count: 4), beta: [Float](repeating: 3e-7, count: 4),
            raw: device.upload(values, label: "Analytic translated Bayer texture"),
            kinds: device.upload([UInt8](repeating: 0, count: values.count), label: "Normal RAW sample kinds"))
    }

    @Test(arguments: [SIMD2<Float>(2,-1),SIMD2<Float>(-0.6,0.4)])
    func localRegistration_recoversKnownSubpixelTranslation(shift: SIMD2<Float>) throws {
        let result = try register(shifts: [.zero,shift])
        let buffer = result.flow
        defer { withExtendedLifetime(buffer) {} }
        let flow = buffer.metal.contents().assumingMemoryBound(to: SIMD2<Float>.self)
        let errors = (4..<12).flatMap { y in (4..<12).map { x in
            let delta = flow[256 + y * 16 + x] - shift
            return sqrt(delta.x * delta.x + delta.y * delta.y)
        } }.sorted()
        // The tolerance is below one quarter of a native sensor pixel.
        #expect(errors[errors.count / 2] < 0.2)
    }

    @Test func movingObject_rejectsInconsistentCompanionSamples() throws {
        let result = try register(shifts: [.zero,.zero], movingObject: true)
        let buffer = result.reliability
        defer { withExtendedLifetime(buffer) {} }
        let values = buffer.metal.contents().assumingMemoryBound(to: Float.self)
        let object = (56..<72).flatMap { y in (56..<72).map { x in values[16384 + y * 128 + x] } }
        let staticRegion = (16..<32).flatMap { y in (16..<32).map { x in values[16384 + y * 128 + x] } }

        #expect(object.reduce(0,+) / Float(object.count) < 0.05)
        #expect(staticRegion.reduce(0,+) / Float(staticRegion.count) > 0.8)
    }

    @Test func singleFrame_registrationIsIdentityAndReleasesWorkspace() throws {
        var registration: F5CurvatureRegistration? = try register(shifts: [.zero])
        let device = try #require(registration).device
        var flow: F5MetalBuffer? = try #require(registration).flow
        let values = try #require(flow).metal.contents().assumingMemoryBound(to: SIMD2<Float>.self)
        #expect((0..<256).allSatisfy { values[$0] == .zero })
        registration = nil
        // The borrowed buffer intentionally retains the completed context.
        #expect(withExtendedLifetime(flow) { device.allocatedBytes } > 0)
        flow = nil
        #expect(device.allocatedBytes == 0)
        withExtendedLifetime(registration) {}
        withExtendedLifetime(flow) {}
    }
}
