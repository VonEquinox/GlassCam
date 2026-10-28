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
struct F5NumericalTests {
    @Test(arguments: [1, 2])
    func parallelMotion_keepsSerialBlocksWithinBoundedStorage(scale: Int) throws {
        let context = try F5TestContext(width: 72, height: 70), fixture = context.fixture, shader = try F5TestContext.shader
        let width=72,height=70,columns=(width+31)/32+1,rows=(height+31)/32+1,nodes=columns*rows*5
        let device=try F5MetalDevice(maximumBytes:256*1024*1024,shaderURL:shader,isCancelled:{false})
        let frames=try fixture.canonical.map{try F5MetalFrame.upload($0,to:device)}
        for frame in frames {
            let mask=frame.eligibility.metal.contents().assumingMemoryBound(to:UInt32.self)
            for i in stride(from:0,to:width*height,by:17) {mask[i/32] &= ~(UInt32(1)<<UInt32(i%32))}
        }
        let lookup=try F5MetalLikelihood.load(profile:fixture.profile,directory:fixture.source.directory,device:device)
        let offsets=(0..<nodes).map{SIMD2<Float>(0.2*sin(Float($0)*0.31),0.17*cos(Float($0)*0.23))}
        let motion=try device.upload(offsets,label:"Strip motion"),direction=try device.upload(offsets.map{$0*0.1},label:"Strip direction")
        let edge=try device.upload([Float](repeating:0.8,count:nodes),label:"Strip motion weights")
        let bounds=[SIMD4<Float>](repeating:SIMD4(-0.3,-0.3,0.3,0.3),count:5)
            let coefficients=try device.upload((0..<width*height*scale*scale*3).map{Float(0.24+0.035*sin(Double($0)*0.13))},label:"Strip image")
            let noise=try device.upload([Float](repeating:0.02,count:width*height),label:"Strip noise")
            let scratch=try F5MetalScratch(width:width,height:height,coreSize:16,device:device)
            let level=F5MetalLevel(width:width,height:height,scale:scale,reference:1,policy:fixture.profile.policy,device:device,frames:frames,scratch:scratch,likelihood:lookup,
                coefficients:coefficients,noise:noise,motion:motion,motionDirection:direction,motionBounds:bounds,validEventCount:width*height*5)
            level.motionEdgeWeights=edge;try level.prepare(SIMD4(0,0,16,16),tau:1e-6)
            func calculate(_ parallel:Bool)throws->[[Float]] {
                level.parallelMotion=parallel
                try device.run {command in
                    try device.clear(scratch.motionDataNormal.metal,command:command)
                    try level.encodeMotion(command:command,direction:direction,mode:0,target:scratch.motion.gradient)
                }
                return [scratch.motion.gradient,scratch.motion.diagonal,scratch.motionDataNormal].map {buffer in
                    Array(UnsafeBufferPointer(start:buffer.metal.contents().assumingMemoryBound(to:Float.self),count:buffer===scratch.motionDataNormal ? nodes*36:nodes*2))
                }
            }
            let serial=try calculate(false),before=device.allocatedBytes,parallel=try calculate(true)
            // Original parallel-motion certificate permits 1e-6 relative L2 error.
            let relativeErrors = zip(serial, parallel).map { original, updated in
                let error = zip(original, updated).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) }
                let norm = original.reduce(0.0) { $0 + Double($1 * $1) }
                return sqrt(error / max(1e-30, norm))
            }
            #expect(device.allocatedBytes - before == width * 64 * 16)
            #expect(try #require(relativeErrors.max()) < 1e-6)
    }
    @Test(arguments: [false, true])
    func initialNoiseScale_keepsShotNoiseExposureAndExclusion(excludeShort: Bool) throws {
        let context = try F5TestContext(width: 24, height: 24), fixture = context.fixture, shader = try F5TestContext.shader
        let width=24,height=24
        let device=try F5MetalDevice(maximumBytes:128*1024*1024,shaderURL:shader,isCancelled:{false})
        let frames=try fixture.canonical.map{try F5MetalFrame.upload($0,to:device)}
        let coefficients=try device.upload([Float](repeating:0.3,count:width*height*3),label:"Known constant radiance")
        let noise=try device.upload([Float](repeating:0,count:width*height),label:"Information scale")
        let motion=try device.upload([SIMD2<Float>](repeating:.zero,count:20),label:"Zero noise-control motion")
        let scratch=try F5MetalScratch(width:width,height:height,coreSize:16,device:device)
        let lookup=try F5MetalLikelihood.load(profile:fixture.profile,directory:fixture.source.directory,device:device)
        let level=F5MetalLevel(width:width,height:height,scale:1,reference:1,policy:fixture.profile.policy,device:device,frames:frames,scratch:scratch,likelihood:lookup,
            coefficients:coefficients,noise:noise,motion:motion,motionDirection:motion,motionBounds:[SIMD4<Float>](repeating:.zero,count:5),validEventCount:width*height*5)
            if excludeShort {try device.run {try device.clear(frames[2].eligibility.metal,command:$0)}}
            try level.freezeNoiseScale()
            var precision=0.0,floor=Double.infinity
            for i in 0..<5 where !excludeShort || i != 2 {
                let e=fixture.canonical[i].event(x:12,y:12),gain=e.exposure*e.eta
                precision+=gain*gain/(e.kappa*0.3*gain+e.readSigma*e.readSigma);floor=min(floor,e.readSigma/gain)
            }
            let expected=max(floor,sqrt(3/precision)),actual=noise.metal.contents().assumingMemoryBound(to:Float.self)[12*width+12]
            #expect(abs(Double(actual) - expected) < 2e-6) // Original information-scale tolerance.
            print("F5 initial information scale",excludeShort,actual,"expected",expected)
    }
    @Test(arguments: 0..<5)
    func nativeCodeMapping_keepsLowBitsAndQuantization(sample: Int) throws {
        let context = try F5TestContext(mapping: "mapped"), fixture = context.fixture
        let source=fixture.canonical[0],a=source.record.raster.activeArea
        var data=source.codes
        let values:[UInt16]=[2112,2113,2114,2115,13544]
        for (x,value) in values.enumerated() {
            let offset=a.top*source.record.raster.rowBytes+(a.left+x)*2
            data[offset]=UInt8(value&255);data[offset+1]=UInt8(value>>8)
        }
        let frame=try F5CanonicalFrame(record:source.record,codes:data,profile:fixture.profile,mainExposure:0.008)
        let event = frame.event(x: sample, y: 0), value = values[sample]
        let expected = (Double(value) / 4 - 528) / 3567
        // Original native-code contract uses 1e-12 absolute tolerance.
        #expect(event.code == value)
        #expect(abs((event.lower + event.upper) / 2 - expected) < 1e-12)
        #expect(abs(event.upper - event.lower - 0.25 / 3567) < 1e-12)
        #expect(abs(event.uniformProbability - 1 / 16384.0) < 1e-12)
    }
    @Test func nativeCodeScale_doesNotReapplyDNGDivisorToColor() throws {
        let context = try F5TestContext(mapping: "mapped"), fixture = context.fixture
        let color = try F5ColorBridge.make(metadata: fixture.canonical[0].record.metadata, profile: fixture.profile)
        #expect(color.inputScale == 3567)
    }
}
