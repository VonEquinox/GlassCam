import Testing
import CF5
import Foundation
import CoreImage
import ImageIO
import Metal
@testable import F5
@testable import ImagingCore
@testable import Capture
import GlassCamTestSupport

@Suite(.serialized)
struct F5OpcodeTests {
    static func result(_ name: String) throws -> ([Float], Bool, UInt32) {
        let dng = try #require(F5Fixtures.postOpcodeFixtures().first { $0.0 == name }).1
        let device = try F5MetalDevice(maximumBytes: 64 * 1024 * 1024, shaderURL: F5TestContext.shader, isCancelled: { false })
            let metadata=try F5DNGMetadata.read(dng),width=metadata.activeArea.width,height=metadata.activeArea.height
            let correction=try F5RAWCorrections(metadata:metadata)
            let post=try F5PostOperations.records(metadata)
            let controls=(0..<3).flatMap{Array(repeating:Float(0.02)*Float($0+1),count:width*height)}
            let input=try device.upload(controls,label:"Constant scene-linear RGB"),quality=try device.upload([UInt32](repeating:1,count:((width+31)/32)*((height+31)/32)),label:"Native output support")
            let operations=try device.upload(post.data,label:"Ordered opcode fixture")
            let output=try device.allocate(width*height*16,label:"Opcode result"),failure=try device.allocate(4,label:"Opcode failure")
            let grid=F5GPUGrid(shape:SIMD4(UInt32(width),UInt32(height),1,0),core:.zero,field:.zero,counts:.zero,bin:.zero,
                objective:.zero,regularizer:.zero,step:.zero,options:.zero)
            let options=F5GPUOutput(shape:SIMD4(UInt32(width),UInt32(height),0,UInt32(height)),
                crop:SIMD4(0,0,Float(width),Float(height)),options:SIMD4(UInt32(post.ids.count),1,0,0))
            try device.run { command in
                try device.clear(failure.metal,command:command)
                try device.encode("f5_output_strip",count:width*height,buffers:[input.metal,input.metal,quality.metal,operations.metal,output.metal,failure.metal],command:command) {
                    F5MetalDevice.value(grid,at:6,encoder:$0);F5MetalDevice.value(options,at:7,encoder:$0)
                }
            }
            let actual=Array(UnsafeBufferPointer(start:output.metal.contents().assumingMemoryBound(to:Float.self),count:width*height*4))
            return (actual, correction.gains.isEmpty, failure.metal.contents().load(as: UInt32.self))
    }
    @Test(arguments: ["gain_rgb", "gain_before_warp", "gain_after_warp", "gain_warp_gain", "partial_planes_broadcast", "hdr_extension"])
    func stage3Operations_doNotAlsoEnterRAWPrediction(name: String) throws {
        let (_, rawGainsEmpty, failure) = try Self.result(name)
        #expect(rawGainsEmpty)
        #expect(failure == 0)
    }
    @Test func sceneHDR_extensionKeepsRecoveredHighlights() throws {
        let (actual, _, _) = try Self.result("hdr_extension")
        // Original scene-HDR extension tolerance.
        #expect(abs(actual[0] - 2) < 1e-6)
        #expect(abs(actual[1] - 4) < 1e-6)
        #expect(abs(actual[2] - 6) < 1e-6)
    }
    @Test func gainAndGeometry_preserveOpcodeOrder() throws {
        let (before, _, _) = try Self.result("gain_before_warp")
        let (after, _, _) = try Self.result("gain_after_warp")
        let difference = try #require(zip(before, after).map { abs($0 - $1) }.max())
        #expect(difference > 0.01)
    }
}
