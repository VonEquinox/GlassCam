import Testing
import Foundation
import CoreImage
import simd
@testable import Peripheral

struct WeakMotionTests {
    typealias F = PeripheralFixtures
    static func fixture(contrast: Double, index: Int) -> (a: [UInt8], b: [UInt8]) {
        let w = 192, h = 256, p = 32
            let angle = 4*sin(Double(index)*0.18)*Double.pi/180, cs = cos(angle), sn = sin(angle)
            var a = [UInt8](repeating:255,count:w*h*4), b = [UInt8](repeating:255,count:(w+64)*(h+64)*4)
            var seed = UInt64(534+index), other = UInt64(839+index)
            for y in -p..<h+p { for x in -p..<w+p {
                let u = cs*Double(x-w/2)-sn*Double(y-h/2)+Double(w/2)
                let v = sn*Double(x-w/2)+cs*Double(y-h/2)+Double(h/2)
                let c = y < 42 || y >= h-42 ? contrast : 30
                let value = 128+c*(sin(u*0.17)+0.7*sin((u+v)*0.093)+0.3*sin(v*0.73))
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                other = other &* 6364136223846793005 &+ 1442695040888963407
                let aa = UInt8(max(0,min(255,Int(value.rounded())+Int((seed>>32)%9)-4)))
                let bb = UInt8(max(0,min(255,Int(value.rounded())+Int((other>>32)%9)-4+20)))
                for channel in 0..<3 {
                    b[((y+p)*(w+64)+x+p)*4+channel] = bb
                    if (0..<w).contains(x), (0..<h).contains(y) { a[(y*w+x)*4+channel] = aa }
                }
            } }
        return (a, b)
    }
    @Test(arguments: [2.0, 3, 4, 6], 0..<40)
    func zeroRelativeDisparityWithNoiseAndRotation_neverClaimsLargeShift(contrast: Double, index: Int) throws {
        let input = Self.fixture(contrast: contrast, index: index)
        let value = try F.measure(input.a, input.b)
        #expect((value.evidence.confirmedSevereLowerBound ?? 0) <= 0.10)
        if value.evidence.reliable { #expect(try #require(value.evidence.interval).lowerBound <= 0.10) }
    }

}

struct NativeBoundarySamplingTests {
    typealias F = PeripheralFixtures
    @Test func nativeValidation_preservesSinglePixelLineBeforeChecking() throws {
        var highResolution = [UInt8](repeating:128,count:768*1024*4)
        for i in stride(from:3,to:highResolution.count,by:4) { highResolution[i] = 255 }
        for y in 0..<1024 { for c in 0..<3 { highResolution[(y*768+71)*4+c] = 0 } }
        let nativePixel = try F.pixelBuffer(rgba:highResolution,width:768,height:1024)
        let nativeContext = CIContext(options:[.cacheIntermediates:false])
        let nativeStrips = PeripheralNativeSeam.read(center:CIImage(cvPixelBuffer:nativePixel),
            outerImage:CIImage(cvPixelBuffer:nativePixel),ratio:1,matrix:matrix_identity_float3x3,
            analysisWidth:192,analysisHeight:256,seams:.horizontal,context:nativeContext)
        #expect(nativeStrips[0].width == 768)
        #expect(nativeStrips[0].outer[71 * 4] < 3)
        #expect(nativeStrips[0].outer[70 * 4] > 120)
    }
}
