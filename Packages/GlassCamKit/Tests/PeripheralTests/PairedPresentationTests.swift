import Testing
import Foundation
import CoreImage
import Metal
import simd
@testable import Peripheral

private struct PairedObservation {
    let previousSerial: UInt64?, serial: UInt64, status: MTLCommandBufferStatus
    let centerError: Float, horizontalDifference: Float, verticalDifference: Float
    let outer: [Float], expectedOuter: [Float], completed: Bool
    static func render(_ i: Int) async throws -> Self {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw CocoaError(.featureUnsupported) }
        let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let context=CIContext(mtlCommandQueue:queue,options:[.cacheIntermediates:false,.workingColorSpace:space])
        let library=try await device.makeLibrary(source:PeripheralGlassShader.source,options:nil)
        let d=MTLRenderPipelineDescriptor();d.vertexFunction=library.makeFunction(name:"glassVertex")
        d.fragmentFunction=library.makeFunction(name:"pairedPreviewFragment");d.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline=try await device.makeRenderPipelineState(descriptor:d)
        let outputDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:48,height:96,mipmapped:false)
        outputDescriptor.storageMode = .shared;outputDescriptor.usage=[.renderTarget,.shaderRead]
        let output=device.makeTexture(descriptor:outputDescriptor)!,store=PeripheralLiveTextureStore()
        func sample(_ t:MTLTexture,_ x:Int,_ y:Int)->[Float] {
            var result=[Float16](repeating:0,count:4)
            result.withUnsafeMutableBytes {t.getBytes($0.baseAddress!,bytesPerRow:8,from:MTLRegionMake2D(x,y,1,1),mipmapLevel:0)}
            return result.map {Float($0)}
        }
            let v=UInt8(30+i*25)
            let centralPixels:[UInt8]=(0..<(48*64)).flatMap {p -> [UInt8] in
                let green=UInt8(10+2*(p%48)),blue=UInt8(20+3*(p/48))
                return [v,green,blue,255]
            }
            let c=try PeripheralFixtures.pixelBuffer(rgba:centralPixels,width:48,height:64)
            let o=try PeripheralFixtures.pixelBuffer(rgba:(0..<48*64).flatMap {_ in [20,v,30,255]},width:48,height:64)
            let pair=PeripheralFrameSource.Pair(center:c,outer:o,receipt:Double(i),configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:UInt64(i+1))
            let frame=PeripheralLiveFrame(pair:pair,matrix:simd_float3x3(SIMD3(0.5,0,0),SIMD3(0,0.5,0),SIMD3(0.25,0.25,1)),
                gains:.init(),refinement:nil,refinementStrength:0,analysisPairID:0,analysisObservedAt:nil,modelPair:nil,
                mappingBasis:"test-fixed-FOV",seams:.horizontal,tolerance:1,margin:8)
            let command=queue.makeCommandBuffer()!
            let upload=try store.prepare(frame,revision:1,at:Double(i),device:device,context:context,command:command,
                colorSpace:space,includeCenter:true)!
            let previousSerial = store.completed?.frame.pair.serial
            let bundle=upload.0
            var u=PeripheralGlassUniforms(photo:SIMD4(0,Float(1.0/6),1,Float(2.0/3)),viewport:SIMD2(48,96),
                blackOpacity: i%2==0 ? 0:1,photoToOuter:frame.matrix,gain:SIMD4(repeating:1))
            u.centerEnabled=1
            let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output
            pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
            let encoder=command.makeRenderCommandEncoder(descriptor:pass)!
            encoder.setRenderPipelineState(pipeline);encoder.setFragmentTexture(bundle.texture,index:0)
            encoder.setFragmentTexture(bundle.centerTexture!,index:1)
            encoder.setFragmentBytes(&u,length:MemoryLayout<PeripheralGlassUniforms>.stride,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);encoder.endEncoding()
            await withCheckedContinuation { continuation in command.addCompletedHandler { _ in continuation.resume() }; command.commit() };withExtendedLifetime(upload.1) {}

            let center=sample(output,24,48),expectedCenter=sample(bundle.centerTexture!,24,32)
            let centerError = zip(center, expectedCenter).map { abs($0 - $1) }.max()!
            let horizontalDifference = sample(output,42,48)[1] - sample(output,4,48)[1]
            let verticalDifference = sample(output,24,74)[2] - sample(output,24,20)[2]
            let outer=sample(output,24,4),expectedOuter=sample(bundle.texture,24,20)
            let completed = store.complete(bundle,success:true,revision:1,epoch:1,at:Double(i)+0.001)
            return .init(previousSerial: previousSerial, serial: pair.serial, status: command.status,
                centerError: centerError, horizontalDifference: horizontalDifference, verticalDifference: verticalDifference,
                outer: outer, expectedOuter: expectedOuter, completed: completed)
    }
}
struct PairedPresentationTests {
    @Test(arguments: 0..<8)
    func currentFrame_uploadsAndRendersBeforePublication(index: Int) async throws {
        let result = try await PairedObservation.render(index)
        #expect(result.previousSerial != result.serial)
        #expect(result.status == .completed)
        #expect(result.completed)
    }
    @Test(arguments: 0..<8)
    func peripheralBlackness_doesNotDelayDarkenOrFlipCenter(index: Int) async throws {
        let result = try await PairedObservation.render(index)
        #expect(result.centerError < 0.002)
        #expect(result.horizontalDifference > 0.03)
        #expect(result.verticalDifference > 0.1)
    }
    @Test(arguments: 0..<8)
    func pairedOuter_usesCurrentCommandAndBlackDecision(index: Int) async throws {
        let result = try await PairedObservation.render(index)
        if index % 2 == 0 {
            #expect(try #require(zip(result.outer, result.expectedOuter).map { abs($0 - $1) }.max()) < 0.002)
        } else { #expect(Array(result.outer.prefix(3)) == [0, 0, 0]) }
    }
}
