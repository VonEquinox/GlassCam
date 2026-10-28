import Testing
import Foundation
import Metal
import simd
@testable import Peripheral

private struct GlassRenderer {
    let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState
    let input: MTLTexture, output: MTLTexture
    let width = 96, height = 192
    init(ramp: Bool = false) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw CocoaError(.featureUnsupported) }
        self.device = device; self.queue = queue
        let library = try device.makeLibrary(source: PeripheralGlassShader.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "glassVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "glassFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let source = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 32, height: 32, mipmapped: false)
        source.storageMode = .shared; source.usage = .shaderRead
        let destination = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        destination.storageMode = .shared; destination.usage = [.renderTarget, .shaderRead]
        guard let input = device.makeTexture(descriptor: source), let output = device.makeTexture(descriptor: destination) else { throw CocoaError(.coderInvalidValue) }
        self.input = input; self.output = output
        var pixels: [Float16] = (0..<32 * 32).flatMap { _ -> [Float16] in [0.25, 0.5, 2, 1] }
        if ramp {
            for y in 0..<32 { for x in 0..<32 {
                pixels[(y * 32 + x) * 4] = Float16(Float(x) / 32)
                pixels[(y * 32 + x) * 4 + 1] = Float16(Float(y) / 32)
                pixels[(y * 32 + x) * 4 + 2] = Float16(Float(x + 2 * y) / 96)
            } }
        }
        pixels.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 32 * 8) }
    }
    func uniforms(blackness: Float = 0) -> PeripheralGlassUniforms {
        .init(photo: SIMD4(0, Float(1.0 / 6), 1, Float(2.0 / 3)), viewport: SIMD2(Float(width), Float(height)),
            blackOpacity: blackness, photoToOuter: PeripheralAlignmentWorker.samplingTransform(homography: matrix_identity_float3x3,
                width: 192, height: 256, ratio: 2), gain: SIMD4(repeating: 1))
    }
    func render(_ value: PeripheralGlassUniforms) async throws -> [Float16] {
        var uniforms = value
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw CocoaError(.coderInvalidValue) }
        encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PeripheralGlassUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
        await withCheckedContinuation { continuation in command.addCompletedHandler { _ in continuation.resume() }; command.commit() }
        guard command.status == .completed else { throw command.error ?? CocoaError(.coderInvalidValue) }
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return pixels
    }
}

struct GlassShaderTests {
    @Test(arguments: [Float(0), 0.5, 1])
    func glassOpacity_neverWritesPhotograph(blackness: Float) async throws {
        let renderer = try GlassRenderer(), pixels = try await renderer.render(renderer.uniforms(blackness: blackness))
        let center = Array(pixels[(32 * renderer.width * 4)..<(160 * renderer.width * 4)])
        #expect(center == [Float16](repeating: 0, count: center.count))
    }
    @Test(arguments: [Float(0), 0.5, 1])
    func glassOpacity_scalesOnlyPerimeterTransmission(blackness: Float) async throws {
        let renderer = try GlassRenderer(), pixels = try await renderer.render(renderer.uniforms(blackness: blackness))
        let indices = (0..<renderer.width * renderer.height).filter { !(32..<160).contains($0 / renderer.width) }
        let alpha = indices.map { pixels[$0 * 4 + 3] }
        let errors = indices.flatMap { index in [Float(0.25), 0.5, 2].enumerated().map { abs(Float(pixels[index * 4 + $0.offset]) - $0.element * (1 - blackness)) } }
        #expect(Set(alpha) == [1])
        #expect(try #require(errors.max()) < 0.002) // Original half-float shader tolerance.
    }
    @Test func independentEdgeGains_applyVerifiedLinearPhotometry() async throws {
        let renderer = try GlassRenderer(); var uniforms = renderer.uniforms()
        uniforms.gainTop = SIMD4(0.5, 0.5, 0.5, 1); uniforms.gainBottom = SIMD4(1.5, 1.5, 1.5, 1)
        let pixels = try await renderer.render(uniforms)
        #expect(abs(Float(pixels[(10 * renderer.width + 48) * 4]) - 0.125) < 0.002)
        #expect(abs(Float(pixels[(180 * renderer.width + 48) * 4]) - 0.375) < 0.002)
    }
    @Test func affinePhotometry_appliesTransferFunctionOnce() async throws {
        let renderer = try GlassRenderer(); var uniforms = renderer.uniforms()
        uniforms.gainTop = SIMD4(0.7, 0.7, 0.7, 2); uniforms.gainBottom = uniforms.gainTop
        uniforms.biasTop = SIMD4(0.06, 0.06, 0.06, 0); uniforms.biasBottom = uniforms.biasTop
        let pixels = try await renderer.render(uniforms)
        #expect(abs(Float(pixels[(10 * renderer.width + 48) * 4]) - 0.1594601) < 0.002)
    }
    @Test func regionalOpacity_keepsIndependentPaneAndCenterUntouched() async throws {
        let renderer = try GlassRenderer(); var uniforms = renderer.uniforms()
        uniforms.gainTop = SIMD4(0.7, 0.7, 0.7, 2); uniforms.gainBottom = uniforms.gainTop
        uniforms.biasTop = SIMD4(0.06, 0.06, 0.06, 0); uniforms.biasBottom = uniforms.biasTop
        uniforms.edgeOpacity = SIMD4(1, 0, 1, 1)
        let pixels = try await renderer.render(uniforms)
        #expect(pixels[(10 * renderer.width + 48) * 4] == 0)
        #expect(Float(pixels[(180 * renderer.width + 48) * 4]) > 0.15)
        #expect(pixels[(80 * renderer.width + 48) * 4 + 3] == 0)
    }
    @Test(arguments: [3, 17, 174, 188], [5, 27, 61, 89])
    func asymmetricRamp_keepsSamplingAxes(y: Int, x: Int) async throws {
        let renderer = try GlassRenderer(ramp: true), pixels = try await renderer.render(renderer.uniforms())
        let sx = (Float(x) + 0.5) / Float(renderer.width), sy = (Float(y) + 0.5) / Float(renderer.height)
        let expectedX = 0.25 + 0.5 * sx - 0.5 / 32
        let expectedY = 0.25 + 0.5 * ((sy - 1.0 / 6) / (2.0 / 3)) - 0.5 / 32
        #expect(abs(Float(pixels[(y * renderer.width + x) * 4]) - expectedX) < 0.002)
        #expect(abs(Float(pixels[(y * renderer.width + x) * 4 + 1]) - expectedY) < 0.002)
    }
}
