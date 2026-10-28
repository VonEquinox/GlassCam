import Testing
import Foundation
import CoreVideo
import simd
@testable import Peripheral

struct ControlledDisparityTests {
    typealias F = PeripheralFixtures
    @Test(arguments: [2, 24])
    func knownRawPixelShift_controlsGlassWithoutWarping(shift: Int) throws {
        let canvas=F.texture(width:512,height:640,seed:298341)
        func crop(_ x:Int,_ y:Int,_ w:Int,_ h:Int)throws -> CVPixelBuffer {
            var values=[UInt8]();values.reserveCapacity(w*h*4)
            for row in y..<y+h {values.append(contentsOf:canvas[(row*512+x)*4..<(row*512+x+w)*4])}
            return try F.pixelBuffer(rgba:values,width:w,height:h)
        }
        let center=try crop(160,192,192,256)
            let outer=try crop(64+shift,64,384,512)
            let pair=PeripheralFrameSource.Pair(center:center,outer:outer,receipt:10,
                configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:UInt64(shift))
            let result=PeripheralAlignmentWorker().analyze(pair,seams:.horizontal,
                window:CGRect(x:0,y:-0.25,width:1,height:1.5),now:{10.01},tolerance:1)!
            let shade=(0...1).map {PeripheralPaneAssessment.measure(result,edge:$0).darkness(tolerance:1)}.max()!
            if shift == 2 { #expect(shade < 0.001) } else { #expect(shade > 0.999) }
    }
    @Test func localObjectDisplacement_cannotBeOutvotedByFlatMajority() throws {
        let canvas = F.texture(width: 512, height: 640, seed: 298341)
        // Only one third of the seam contains the displaced object. Flat
        // background must not dilute it into an all-clear global percentile.
        var localScene=canvas
        for y in 0..<640 {for x in 0..<512 where x<160 || x>=224 {
            for c in 0..<3 {localScene[(y*512+x)*4+c]=128}
        }}
        let localCenter=try F.pixelBuffer(rgba:F.crop(localScene,sourceWidth:512,x:160,y:192,width:192,height:256),width:192,height:256)
        let localOuter=try F.pixelBuffer(rgba:F.crop(localScene,sourceWidth:512,x:78,y:64,width:384,height:512),width:384,height:512)
        let localPair=PeripheralFrameSource.Pair(center:localCenter,outer:localOuter,receipt:20,
            configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:50)
        let localResult=PeripheralAlignmentWorker().analyze(localPair,seams:.horizontal,
            window:CGRect(x:0,y:-0.25,width:1,height:1.5),now:{20.01},tolerance:1)!
        let localShade=(0...1).map {PeripheralPaneAssessment.measure(localResult,edge:$0).darkness(tolerance:1)}.max()!
        #expect(localShade > 0.95)
    }
}
