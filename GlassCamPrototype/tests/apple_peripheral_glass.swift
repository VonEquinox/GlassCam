import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import simd

/// Execute only after test authorization. No camera, Photos or UI automation.
@main
struct PeripheralGlassChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.00001) -> Bool { abs(a-b) < tolerance }

    static func main() throws {
        policyChecks()
        projectionChecks()
        seamChecks()
        try mailboxChecks()
        visionChecks()
        try shaderChecks()
        print("PASS: peripheral policy, projection, residual, mailbox, Vision registration and Metal center exclusion")
    }

    static func policyChecks() {
        var gate = PeripheralGlassPolicy()
        require(gate.opacity(at: 0) == 1, "Startup must not display unverified peripheral pixels")
        gate.update(error: 0.01, available: true, at: 0)
        gate.update(error: 0.01, available: true, at: 0.39)
        require(gate.opacity(at: 0.39) == 1, "One good frame cannot immediately expose glass")
        gate.update(error: 0.01, available: true, at: 0.4)
        require(close(gate.opacity(at: 0.6),0.5), "Recovery must take 0.4 seconds")
        require(close(gate.opacity(at: 0.8),0), "Stable glass did not recover")
        gate.update(error: 0.10, available: true, at: 1)
        require(close(gate.opacity(at: 1.1),0), "The agreed trigger is above, not equal to, 10%")
        gate.update(error: 0.101, available: true, at: 1.2)
        require(close(gate.opacity(at: 1.35),0.5), "Darkening must take 0.3 seconds")
        require(close(gate.opacity(at: 1.5),1), "Over-threshold perimeter must become fully black")
        gate.update(error: 0.079, available: true, at: 2)
        gate.update(error: 0.081, available: true, at: 2.3)
        gate.update(error: 0.079, available: true, at: 2.4)
        gate.update(error: 0.079, available: true, at: 2.7)
        require(gate.targetOpacity == 1, "An unstable recovery window must reset")
        gate.update(error: 0.079, available: true, at: 2.81)
        let before = gate.opacity(at: 3.0)
        gate.update(error: nil, available: true, at: 3.0)
        require(close(gate.opacity(at: 3.0),before), "An interrupted animation must start from its current opacity")
        require(close(gate.opacity(at: 3.3),1), "Unknown error must darken")
        for error in [Double.nan, .infinity, -1] {
            gate.update(error: error, available: true, at: 4)
            require(gate.targetOpacity == 1, "Non-finite/invalid quality must not count as aligned")
        }
        gate.update(error: 0, available: false, at: 5)
        require(gate.targetOpacity == 1, "Missing/widest peripheral source must remain black")
        gate.update(error: 0.08, available: true, at: 6)
        gate.update(error: 0.08, available: true, at: 7)
        require(gate.targetOpacity == 1, "Recovery requires strictly below 8%")
        var repeated = PeripheralGlassPolicy()
        repeated.update(error: 0, available: true, at: 0, measuredAt: 0)
        repeated.update(error: 0, available: true, at: 0.5, measuredAt: 0)
        require(repeated.targetOpacity == 1, "Repainting one old result falsely counted as stable recovery")
        repeated.update(error: 0, available: true, at: 0.55, measuredAt: 0.41)
        require(repeated.targetOpacity == 0 && repeated.opacity(at: 0.55) == 1,
                "New stable measurements must start recovery at the current animation time")
        print("PASS: exact threshold boundaries, stability, interrupted fades and unknown quality")
    }

    static func projectionChecks() {
        let identity = PeripheralAlignmentWorker.samplingTransform(homography: matrix_identity_float3x3,
            width: 192, height: 256, ratio: 2)
        let center = PeripheralAlignmentWorker.project(SIMD2(0.5,0.5), using: identity)!
        let corner = PeripheralAlignmentWorker.project(SIMD2(0,0), using: identity)!
        require(simd_length(center-SIMD2(0.5,0.5)) < 0.00001, "Center UV moved")
        require(simd_length(corner-SIMD2(0.25,0.25)) < 0.00001, "Top-left crop mapping flipped")
        var h = matrix_identity_float3x3
        h.columns.2 = SIMD3(12,16,1)
        let matrix = PeripheralAlignmentWorker.samplingTransform(homography: h, width: 192, height: 256, ratio: 2)
        let moved = PeripheralAlignmentWorker.project(SIMD2(0.5,0.5), using: matrix)!
        require(close(Double(moved.x),0.5-12.0/384.0), "Floating-to-reference transform was not inverted")
        require(close(Double(moved.y),0.5+16.0/512.0), "CI bottom-left to texture top-left conversion failed")
        require(PeripheralAlignmentWorker.project(.zero, using: simd_float3x3()) == nil, "Degenerate projection was admitted")
        print("PASS: independent pixel-space translation, inverse and y-axis golden vectors")
    }

    static func texture(width: Int, height: Int, seed: UInt64) -> [UInt8] {
        var state = seed
        var image = [UInt8](repeating: 255, count: width*height*4)
        for i in stride(from: 0, to: image.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let value = UInt8(32 + ((state >> 32) % 192))
            image[i] = value; image[i+1] = value; image[i+2] = value
        }
        return image
    }
    static func seamChecks() {
        let w = 192, h = 256
        let original = texture(width: w, height: h, seed: 17)
        let same = PeripheralAlignmentWorker.measureSeams(reference: original, warped: original, width: w, height: h)
        require(same != nil && close(same!.residual,0), "Aligned textured seams were rejected")
        var shifted = [UInt8](repeating: 0, count: original.count)
        let dx = 5, dy = -3
        for y in 0..<h { for x in 0..<w {
            let sx = x-dx, sy = y-dy
            if (0..<w).contains(sx), (0..<h).contains(sy) {
                for c in 0..<4 { shifted[(y*w+x)*4+c] = original[(sy*w+sx)*4+c] }
            }
        } }
        let measured = PeripheralAlignmentWorker.measureSeams(reference: original, warped: shifted, width: w, height: h)
        require(measured != nil && close(measured!.residual,hypot(5,3)/192,0.001),
                "Residual must be measured after warp, independently of homography magnitude")
        let landscape = texture(width: 192, height: 144, seed: 23)
        let landscapeMatch = PeripheralAlignmentWorker.measureSeams(reference: landscape, warped: landscape, width: 192, height: 144)
        require(landscapeMatch != nil && close(landscapeMatch!.residual,0),
                "Landscape analysis omitted a zero-displacement candidate")
        let flat = [UInt8](repeating: 128, count: original.count)
        require(PeripheralAlignmentWorker.measureSeams(reference: flat, warped: flat, width: w, height: h) == nil,
                "Textureless scene incorrectly reported zero error")
        let unrelated = texture(width: w,height: h,seed: 71)
        require(PeripheralAlignmentWorker.measureSeams(reference: original, warped: unrelated, width: w,height: h) == nil,
                "Unrelated images incorrectly passed alignment")
        var occluded = original
        for y in 0..<h { for x in (w*4/5)..<w { for c in 0..<3 { occluded[(y*w+x)*4+c] = 0 } } }
        require(PeripheralAlignmentWorker.measureSeams(reference: original, warped: occluded, width: w,height: h) == nil,
                "A failed textured seam was discarded instead of making quality unknown")
        print("PASS: zero/known-shift residual, textureless/uncorrelated/occluded rejection")
    }

    static func sample(time: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        require(CVPixelBufferCreate(nil,32,32,kCVPixelFormatType_32BGRA,nil,&pixel) == kCVReturnSuccess, "CVPixelBuffer allocation")
        var format: CMVideoFormatDescription?
        require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel!, formatDescriptionOut: &format) == noErr,
                "Video format")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1,timescale: 30),
            presentationTimeStamp: CMTime(seconds: time,preferredTimescale: 60000), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        require(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel!,formatDescription: format!,
            sampleTiming: &timing,sampleBufferOut: &buffer) == noErr, "Sample buffer")
        return buffer!
    }
    static func mailboxChecks() throws {
        let source = PeripheralFrameSource()
        source.configure(outputIndex: 1, ratio: 2)
        let selection = source.selection()
        let a = try sample(time: 1), b = try sample(time: 1.005)
        source.offer(center: a, outer: b, selection: selection)
        require(source.latest() != nil, "Synchronized frame pair missing")
        source.offer(center: a, outer: try sample(time: 1.1), selection: selection)
        require(source.latest() == nil, "Unsynchronized frames must not be blended")
        source.reset()
        source.offer(center: a, outer: b, selection: selection)
        require(source.latest() == nil, "Stale geometry generation was reused")
        source.configure(outputIndex: nil, ratio: 1)
        source.offer(center: a,outer: b,selection: source.selection())
        require(source.latest() == nil, "Native widest angle acquired a fake perimeter")
        let independent = PeripheralFrameSource()
        independent.configure(outputIndex: 1, ratio: 2)
        let independentSelection = independent.selection()
        independent.offer(center: nil, outer: b, selection: independentSelection)
        require(independent.latest() == nil, "An outer frame alone cannot form a pair")
        independent.offer(center: a, outer: nil, selection: independentSelection)
        require(independent.latest()?.serial == 1, "Separate independent-camera callbacks failed to pair")
        require(independent.selection() == independentSelection, "An absent callback output changed geometry")
        independent.offer(center: a, outer: nil, selection: independentSelection)
        require(independent.latest()?.serial == 1, "A consumed outer sample was reused")
        independent.offer(center: nil, outer: try sample(time: 1.1), selection: independentSelection)
        require(independent.latest() == nil, "Separate callbacks bypassed the synchronization limit")
        independent.offer(center: try sample(time: 1.105), outer: nil, selection: independentSelection)
        require(independent.latest()?.serial == 2, "A newer unmatched sample was lost")
        independent.offer(center: a, outer: nil, selection: independentSelection)
        independent.configure(outputIndex: 1, ratio: 3)
        independent.offer(center: nil, outer: b, selection: independent.selection())
        require(independent.latest() == nil, "Unmatched frames crossed a zoom/geometry change")
        independent.reset()
        independent.offer(center: a, outer: nil, selection: independent.selection())
        require(independent.latest() == nil, "Unmatched frames crossed an orientation reset")
        independent.invalidate()
        independent.offer(center: a, outer: b, selection: independent.selection())
        require(independent.latest() == nil, "A disposed source accepted frames")
        print("PASS: paired/separate callbacks, bounded PTS, consumed samples and geometry invalidation")
    }

    static func pixelBuffer(rgba: [UInt8], width: Int, height: Int) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        require(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &result) == kCVReturnSuccess,
            "Registration fixture pixel buffer allocation")
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width {
            let source = (y*width+x)*4, destination = y*row+x*4
            pointer[destination] = rgba[source+2]; pointer[destination+1] = rgba[source+1]
            pointer[destination+2] = rgba[source]; pointer[destination+3] = rgba[source+3]
        } }
        return buffer
    }

    static func visionChecks() {
        let width = 384, height = 512, cropX = 100, cropY = 126
        let outer = texture(width: width, height: height, seed: 2619)
        var center = [UInt8](repeating: 0, count: 192*256*4)
        for y in 0..<256 { for x in 0..<192 { for c in 0..<4 {
            center[(y*192+x)*4+c] = outer[((y+cropY)*width+x+cropX)*4+c]
        } } }
        let pair = PeripheralFrameSource.Pair(center: pixelBuffer(rgba: center, width: 192, height: 256),
            outer: pixelBuffer(rgba: outer, width: width, height: height), receipt: 100,
            configuration: .init(outputIndex: 1, fieldOfViewRatio: 2, epoch: 7), serial: 1)
        let worker = PeripheralAlignmentWorker()
        // Freeze freshness only for this algorithm fixture. Vision/CI really run;
        // their first-use compilation time is not an optical-quality assertion.
        guard let aligned = worker.analyze(pair, now: { 100 }) else {
            fatalError("Vision could not register a known overlapping textured scene")
        }
        require(aligned.epoch == 7 && aligned.residual < 0.02, "Post-registration seam residual is not near zero")
        let mapped = PeripheralAlignmentWorker.project(SIMD2(0.5,0.5), using: aligned.photoToOuter)!
        let expected = SIMD2(Float(cropX+96)/Float(width), Float(cropY+128)/Float(height))
        require(simd_length(mapped-expected) < 0.015, "Vision-to-Metal mapping disagrees with the known top-left crop")
        require(worker.analyze(pair, now: { 101 }) == nil, "An expired registration frame was reused")
        func darkened(_ pixels: [UInt8]) -> [UInt8] {
            pixels.enumerated().map { index, value in index % 4 == 3 ? value : UInt8((Float(value) * 0.1).rounded()) }
        }
        let dark = CIImage(cvPixelBuffer: pixelBuffer(rgba: darkened(center), width: 192, height: 256))
        let darkBytes = worker.bitmap(dark, bounds: CGRect(x: 0, y: 0, width: 192, height: 256), width: 192, height: 256)
        let darkMatch = PeripheralAlignmentWorker.measureSeams(reference: darkBytes, warped: darkBytes, width: 192, height: 256)
        require(darkMatch != nil && darkMatch!.residual == 0,
                "Dark but aligned texture was erased by the registration bitmap's transfer curve")
        print("PASS: full Vision/CI registration against an independent overlapping-scene fixture")
    }

    static func shaderChecks() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A real Metal device is required")
        }
        let library = try device.makeLibrary(source: PeripheralGlassShader.source, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "glassVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "glassFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,width: 32,height: 32,mipmapped: false)
        inputDescriptor.storageMode = .shared; inputDescriptor.usage = .shaderRead
        let input = device.makeTexture(descriptor: inputDescriptor)!
        let color: [Float16] = [0.25,0.5,2,1]
        let pixels = (0..<(32*32)).flatMap { _ in color }
        pixels.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0,0,32,32),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 32*8) }
        let w = 96,h = 192
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,width: w,height: h,mipmapped: false)
        outputDescriptor.storageMode = .shared; outputDescriptor.usage = [.renderTarget,.shaderRead]
        let output = device.makeTexture(descriptor: outputDescriptor)!
        let transform = PeripheralAlignmentWorker.samplingTransform(homography: matrix_identity_float3x3,width: 192,height: 256,ratio: 2)
        for blackness: Float in [0,0.5,1] {
            var uniforms = PeripheralGlassUniforms(photo: SIMD4(0,Float(1.0/6.0),1,Float(2.0/3.0)),
                viewport: SIMD2(Float(w),Float(h)),blackOpacity: blackness,photoToOuter: transform,gain: SIMD4(repeating: 1))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
            let command = queue.makeCommandBuffer()!, encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(input,index: 0)
            encoder.setFragmentBytes(&uniforms,length: MemoryLayout<PeripheralGlassUniforms>.stride,index: 0)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3); encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            require(command.status == .completed, "Metal glass rendering failed")
            var bytes = [Float16](repeating: 0,count: w*h*4)
            bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow: w*8,from: MTLRegionMake2D(0,0,w,h),mipmapLevel: 0) }
            for y in 0..<h { for x in 0..<w {
                let i = (y*w+x)*4
                if (32..<160).contains(y) {
                    require(bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 0,
                            "Glass modified a central photo pixel")
                } else {
                    require(bytes[i+3] == 1,"Perimeter was not fully owned by glass")
                    if blackness == 1 { require(bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0,"Blackening left transmitted light") }
                    else {
                        require(bytes[i+2] > bytes[i+1] && bytes[i+1] > bytes[i],
                                "Visible glass lost the transmitted camera colors")
                    }
                }
            } }
        }
        print("PASS: actual Metal shader compilation and central RGBA exclusion at all glass states")
    }
}
