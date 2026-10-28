import Testing
import Foundation
import CoreImage
import QuartzCore
import simd
@testable import Peripheral

struct DenseFlowTests {
    typealias F = PeripheralFixtures
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLASSCAM_DENSE_FLOW"] == "1", "Set GLASSCAM_DENSE_FLOW=1 for independent Vision flow"))
    func shiftedExposureInput_preservesIndependentXYDisplacement() throws {
        let w=384,h=512,dx=8,dy=10
        let image=CIImage(cvPixelBuffer:try F.pixelBuffer(rgba:F.texture(width:w,height:h,seed:1289),width:w,height:h))
            .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:1.5]).cropped(to:CGRect(x:0,y:0,width:w,height:h))
        let a=PeripheralAlignmentWorker().bitmap(image,bounds:CGRect(x:0,y:0,width:w,height:h),width:w,height:h)
        var b=a
        for y in 0..<h {for x in 0..<w {for c in 0..<3 {
            let value=Float(a[(max(0,y-dy)*w+max(0,x-dx))*4+c])*0.8+24
            b[(y*w+x)*4+c]=UInt8(max(0,min(255,Int(value.rounded()))))
        }}}
        let pair=PeripheralFrameSource.Pair(center:try F.pixelBuffer(rgba:a,width:w,height:h),outer:try F.pixelBuffer(rgba:b,width:w,height:h),
            receipt:CACurrentMediaTime(),configuration:.init(outputIndex:1,fieldOfViewRatio:1,epoch:1),serial:1)
        guard let proposal=try PeripheralDenseSolver.compute(pair,homography:matrix_identity_float3x3,id:9) else { throw CocoaError(.coderInvalidValue) }
        var errors:[Float]=[],xs:[Float]=[],ys:[Float]=[]
        for y in stride(from:40,to:h-40,by:4) {for x in stride(from:40,to:w-40,by:4) {
            let i=(y*w+x)*4
            if proposal.rgba[i+2]>0.5 {errors.append(abs(proposal.rgba[i]-Float(dx))+abs(proposal.rgba[i+1]+Float(dy)));xs.append(proposal.rgba[i]);ys.append(-proposal.rgba[i+1])}
        }}
        errors.sort()
        xs.sort();ys.sort();print("Dense golden dx/dy medians",xs[xs.count/2],ys[ys.count/2])
        #expect(errors.count > 3000)
        let median=errors[errors.count/2],p90=errors[errors.count*9/10]
        print("Dense independent golden: median L1 pixel error=\(median), p90=\(p90), FB fraction=\(proposal.consistentFraction)")
        #expect(median < 2)
        #expect(p90 < 4)
        print("PASS: actual bidirectional Vision flow on independently generated displacement/exposure input")
    }
}
