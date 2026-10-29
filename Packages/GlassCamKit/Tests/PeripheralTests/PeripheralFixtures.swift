import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import simd
@testable import Peripheral
import GlassCamTestSupport

enum PeripheralFixtures {
    static func good(_ error: Double = 0.01) -> PeripheralEvidence {
        .init(status: .measured,interval: error...error,appearance: .compatible,reason: "fixture",searchComplete: true,coverage: 1)
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
    static func crop(_ image: [UInt8],sourceWidth: Int,x: Int,y: Int,width: Int,height: Int) -> [UInt8] {
        var out = [UInt8](repeating:255,count:width*height*4)
        for yy in 0..<height { for xx in 0..<width { for c in 0..<4 { out[(yy*width+xx)*4+c] = image[((yy+y)*sourceWidth+xx+x)*4+c] } } }
        return out
    }
    static func fixture(dx: Int = 0,dy: Int = 0,seed: UInt64 = 8) -> (a:[UInt8],b:[UInt8]) {
        let w = 192,h = 256,p = 32,extra = 40,sw = w+2*p+2*extra
        let scene = texture(width:sw,height:h+2*p+2*extra,seed:seed)
        return (crop(scene,sourceWidth:sw,x:extra+p,y:extra+p,width:w,height:h),
                crop(scene,sourceWidth:sw,x:extra-dx,y:extra-dy,width:w+2*p,height:h+2*p))
    }
    static func sample(time: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(nil,32,32,kCVPixelFormatType_32BGRA,nil,&pixel) == kCVReturnSuccess else { throw CocoaError(.coderInvalidValue) }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel!, formatDescriptionOut: &format) == noErr else { throw CocoaError(.coderInvalidValue) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1,timescale: 30),
            presentationTimeStamp: CMTime(seconds: time,preferredTimescale: 60000), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel!,formatDescription: format!,
            sampleTiming: &timing,sampleBufferOut: &buffer) == noErr else { throw CocoaError(.coderInvalidValue) }
        return buffer!
    }
    static func pixelBuffer(rgba: [UInt8], width: Int, height: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &result) == kCVReturnSuccess else { throw CocoaError(.coderInvalidValue) }
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

    static func measure(_ a:[UInt8],_ b:[UInt8],fundamental:simd_float3x3? = nil,budget:Int = 90_000_000) throws -> PeripheralAlignmentWorker.SeamMeasurement {
        guard let result = PeripheralAlignmentWorker.measureSeams(reference:a,warped:b,width:192,height:256,warpedPadding:32,
            seams:.horizontal,certifiedGeometry:true,previousGain:SIMD3(repeating:1),allowPartial:true,
            fundamental:fundamental,comparisonBudget:budget) else { throw CocoaError(.coderInvalidValue) }
        return result
    }
}
