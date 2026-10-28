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
    @Test(arguments: [2.0, 3, 4, 6], [0, 10, 20, 30])
    func predefinedWeakRotatedExposurePositives_keepVisiblePermission(contrast: Double, index: Int) throws {
        let (a, b) = Self.fixture(contrast: contrast, index: index), w = 192, h = 256
        let value = try F.measure(a, b)
        let outer = F.crop(b, sourceWidth: w + 64, x: 32, y: 32, width: w, height: h)
        let strips = [0, 1].map { edge in PeripheralNativeSeam.Strip(edge: edge, width: w, height: 12,
            reference: F.crop(a, sourceWidth: w, x: 0, y: edge == 0 ? 0 : h - 12, width: w, height: 12),
            outer: F.crop(outer, sourceWidth: w, x: 0, y: edge == 0 ? 0 : h - 12, width: w, height: 12), nativeScale: 1) }
        let native = PeripheralNativeSeam.selectPhotometry(strips, candidate: PeripheralNativeSeam.estimate(strips), preferred: nil,
            segments: value.segments, analysisWidth: w, analysisHeight: h, geometryVerified: false, severe: value.evidence.confirmedSevereLowerBound)
        #expect(native.evidence.compatible)
    }
}

struct DenseWarpTests {
    typealias F = PeripheralFixtures
    @Test func independentDenseWarp_keepsAxisSignScaleAndCenterDomain() throws {
        let denseW=192,denseH=256,shiftX=6,shiftY=9
        let denseReference=F.texture(width:denseW,height:denseH,seed:919)
        var denseTarget=denseReference
        for y in 0..<denseH { for x in 0..<denseW { for c in 0..<4 {
            denseTarget[(y*denseW+x)*4+c]=denseReference[(max(0,y-shiftY)*denseW+max(0,x-shiftX))*4+c]
        } } }
        var denseValues=[Float](repeating:1,count:denseW*denseH*4)
        for i in stride(from:0,to:denseValues.count,by:4) { denseValues[i]=Float(shiftX);denseValues[i+1] = -Float(shiftY) }
        let exactDense=PeripheralDenseRefinement(id:7,epoch:1,sourcePairID:1,homography:matrix_identity_float3x3,
            width:denseW,height:denseH,rgba:denseValues,consistentFraction:1,elapsedMS:0,maximumOffset:0.04)
        let exactImage=exactDense.outerImage(CIImage(cvPixelBuffer:try F.pixelBuffer(rgba:denseTarget,width:denseW,height:denseH)),
            centerSize:CGSize(width:denseW,height:denseH),ratio:1)!
        let exactBytes=PeripheralAlignmentWorker().bitmap(exactImage,bounds:CGRect(x:0,y:0,width:denseW,height:denseH),width:denseW,height:denseH)
        var exactError=0.0
        for y in 16..<denseH-16 { for x in 16..<denseW-16 { for c in 0..<3 {
            exactError += Double(abs(Int(exactBytes[(y*denseW+x)*4+c])-Int(denseReference[(y*denseW+x)*4+c])))
        } } }
        #expect(exactError / Double((denseW - 32) * (denseH - 32) * 3) < 1.5)
    }
    @Test func spatiallyVaryingFlow_keepsUpperAndLowerRegions() throws {
        let denseW=192,denseH=256,shiftX=6,shiftY=9
        let denseReference=F.texture(width:denseW,height:denseH,seed:919)
        var denseTarget=denseReference
        for y in 0..<denseH { for x in 0..<denseW { for c in 0..<4 {
            denseTarget[(y*denseW+x)*4+c]=denseReference[(max(0,y-shiftY)*denseW+max(0,x-shiftX))*4+c]
        } } }
        var denseValues=[Float](repeating:1,count:denseW*denseH*4)
        for i in stride(from:0,to:denseValues.count,by:4) { denseValues[i]=Float(shiftX);denseValues[i+1] = -Float(shiftY) }
        var spatialTarget=denseReference,spatialValues=denseValues
        for y in 0..<denseH {for x in 0..<denseW {
            let sign=y<denseH/2 ? 1:-1
            let sx=max(0,min(denseW-1,x-sign*shiftX)),sy=max(0,min(denseH-1,y-sign*shiftY))
            for c in 0..<4 {spatialTarget[(y*denseW+x)*4+c]=denseReference[(sy*denseW+sx)*4+c]}
            spatialValues[(y*denseW+x)*4]=Float(sign*shiftX)
            spatialValues[(y*denseW+x)*4+1] = -Float(sign*shiftY)
        }}
        let spatial=PeripheralDenseRefinement(id:8,epoch:1,sourcePairID:1,homography:matrix_identity_float3x3,
            width:denseW,height:denseH,rgba:spatialValues,consistentFraction:1,elapsedMS:0,maximumOffset:0.04)
        let spatialImage=spatial.outerImage(CIImage(cvPixelBuffer:try F.pixelBuffer(rgba:spatialTarget,width:denseW,height:denseH)),
            centerSize:CGSize(width:denseW,height:denseH),ratio:1)!
        let spatialBytes=PeripheralAlignmentWorker().bitmap(spatialImage,bounds:CGRect(x:0,y:0,width:denseW,height:denseH),width:denseW,height:denseH)
        var spatialError=0.0,spatialCount=0
        for y in 16..<denseH-16 where abs(y-denseH/2)>20 {for x in 16..<denseW-16 {for c in 0..<3 {
            spatialError += Double(abs(Int(spatialBytes[(y*denseW+x)*4+c])-Int(denseReference[(y*denseW+x)*4+c])));spatialCount += 1
        }}}
        #expect(spatialError / Double(spatialCount) < 1.5)
    }
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
