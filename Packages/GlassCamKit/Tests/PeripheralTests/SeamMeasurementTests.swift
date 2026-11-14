import Testing
import Foundation
import CoreImage
import simd
@testable import Peripheral

struct SeamMeasurementTests {
    typealias F = PeripheralFixtures
    @Test func alignedTexture_hasCompleteIndependentEvidence() throws {
        let zero = F.fixture(), aligned = try F.measure(zero.a,zero.b)
        #expect(aligned.evidence.reliable)
        #expect(aligned.residual == 0)
        #expect(aligned.geometryVerified)
        #expect(aligned.segments.count == 24)
    }
    @Test func searchBoundary_doesNotCertifyCompleteDisplacement() throws {
        let truncated = F.fixture(dx:30), atLimit = try F.measure(truncated.a,truncated.b)
        #expect(!atLimit.evidence.reliable)
    }
    @Test func exhaustedBudget_doesNotAcceptPartialPeak() throws {
        let zero = F.fixture()
        let budget = try F.measure(zero.a,zero.b,budget:1000)
        #expect(!budget.evidence.reliable)
        #expect(budget.evidence.status == .budgetExceeded)
        #expect(budget.comparisons <= 1000)
    }
    @Test func weakUniqueLargeShift_isNotHiddenByAppearance() throws {
        let zero = F.fixture()
        var weakA = zero.a, weakB = zero.b
        for i in stride(from:0,to:weakA.count,by:4) { for c in 0..<3 { weakA[i+c] = 112+weakA[i+c]%33 } }
        // Use the same radiometric transform on the true +24 displacement.
        let displaced = F.fixture(dx:24)
        weakA = displaced.a; weakB = displaced.b
        for i in stride(from:0,to:weakA.count,by:4) { for c in 0..<3 { weakA[i+c] = 112+weakA[i+c]%33 } }
        for i in stride(from:0,to:weakB.count,by:4) { for c in 0..<3 { weakB[i+c] = 112+weakB[i+c]%33 } }
        let weak = try F.measure(weakA,weakB)
        #expect(weak.evidence.reliable)
        #expect(weak.evidence.interval!.lowerBound > 0.10)
    }
    @Test func localOcclusion_isNotCertifiedClear() throws {
        let zero = F.fixture()
        var occluded = zero.b
        for y in 32..<32+30 { for x in 32+50..<32+76 { for c in 0..<3 { occluded[(y*256+x)*4+c] = 0 } } }
        let blind = try F.measure(zero.a,occluded)
        let incorrectlyCertified = [blind.evidence].filter(\.reliable).filter { $0.appearance != .mismatch }
        #expect(incorrectlyCertified.isEmpty)
    }
    @Test func thinLineSevereShift_keepsConfirmedDisplacement() throws {
        var lineA = [UInt8](repeating:255,count:192*256*4), lineB = [UInt8](repeating:255,count:256*320*4)
        for i in stride(from:0,to:lineA.count,by:4) { for c in 0..<3 { lineA[i+c] = 128 } }
        for i in stride(from:0,to:lineB.count,by:4) { for c in 0..<3 { lineB[i+c] = 128 } }
        for y in 0..<256 { for c in 0..<3 { lineA[(y*192+96)*4+c] = 0 } }
        for y in 0..<320 { for c in 0..<3 { lineB[(y*256+152)*4+c] = 0 } }
        let line = try F.measure(lineA,lineB)
        #expect((line.evidence.confirmedSevereLowerBound ?? 0) > 0.10)
        let understatedResiduals = [line].filter { $0.evidence.reliable }.map(\.residual).filter { !($0 > 0.1) }
        #expect(understatedResiduals.isEmpty)
    }
    @Test func independentPhotometry_updatesAtFixedGeometry() throws {
        let zero = F.fixture()
        var brighter = zero.b
        for i in stride(from:0,to:brighter.count,by:4) { for c in 0..<3 { brighter[i+c] = UInt8(min(242,Int(Float(brighter[i+c])*1.1))) } }
        let exposure = try F.measure(zero.a,brighter)
        #expect(exposure.evidence.reliable)
        #expect(exposure.residual < 0.01)
        #expect(exposure.photometryVerified)
        #expect(exposure.gain.x < 1)
    }
    @Test func differentDepths_cannotBeAveragedIntoFalseClear() throws {
        let zero = F.fixture()
        // Multiple planes: no single small scalar may certify both depths.
        let near = F.fixture(dx:24)
        var twoPlanes = zero.b
        for y in 0..<320 { for x in 128..<256 { for c in 0..<4 { twoPlanes[(y*256+x)*4+c] = near.b[(y*256+x)*4+c] } } }
        let planes = try F.measure(zero.a,twoPlanes)
        let understatedIntervals = [planes.evidence].filter(\.reliable).map { $0.interval!.upperBound }.filter { !($0 > 0.10) }
        #expect(understatedIntervals.isEmpty)
    }
    @Test func flatWall_doesNotInventGeometry() throws {
        let zero = F.fixture()
        var flatA = zero.a,flatB = zero.b
        for i in stride(from:0,to:flatA.count,by:4) { for c in 0..<3 { flatA[i+c] = 128 } }
        for i in stride(from:0,to:flatB.count,by:4) { for c in 0..<3 { flatB[i+c] = 128 } }
        #expect(try !F.measure(flatA,flatB).evidence.reliable)
    }
    @Test(arguments: [(5, -3), (24, 0), (-24, 0), (0, 24)])
    func knownTranslation_keepsActualDisplacement(inputOffset: (Int, Int)) throws {
        let (dx, dy) = inputOffset
            let input = F.fixture(dx:dx,dy:dy), measured = try F.measure(input.a,input.b)
            #expect(measured.evidence.reliable)
            #expect(abs(measured.residual - hypot(Double(dx), Double(dy)) / 192) < 0.001)
    }
    @Test func validatedEpipolarConstraint_reducesSearchWithoutChangingShift() throws {
        let displaced = F.fixture(dx: 24), zero = F.fixture()
        let aligned = try F.measure(zero.a, zero.b)
        let f = simd_float3x3(SIMD3(0,0,0),SIMD3(0,0,1),SIMD3(0,-1,0))
        let epipolar = try F.measure(displaced.a,displaced.b,fundamental:f)
        #expect(epipolar.evidence.reliable)
        #expect(abs(epipolar.residual - 0.125) < 0.001)
        #expect(epipolar.comparisons < aligned.comparisons)
    }
    @Test func incorrectEpipolarConvention_fallsBackToCompleteSearch() throws {
        let displaced = F.fixture(dx: 24)
        let wrongF = simd_float3x3(SIMD3(0,0,-1),SIMD3(0,0,0),SIMD3(1,0,0))
        let fallback = try F.measure(displaced.a,displaced.b,fundamental:wrongF)
        #expect(fallback.evidence.reliable)
        #expect(abs(fallback.residual - 0.125) < 0.001)
    }
    @Test(arguments: [(64, 64), (96, 128), (192, 144), (256, 192)])
    func paddedSupport_coversEveryImageSize(size: (Int, Int)) throws {
        let (tw, th) = size
            let sw = tw+64, scene = F.texture(width:sw,height:th+64,seed:UInt64(tw+th))
            let photo = F.crop(scene,sourceWidth:sw,x:32,y:32,width:tw,height:th)
            let value = PeripheralAlignmentWorker.measureSeams(reference:photo,warped:scene,width:tw,height:th,
                warpedPadding:32,seams:.horizontal,certifiedGeometry:true,allowPartial:true)!
            #expect(value.evidence.reliable)
    }
    @Test func periodicTexture_doesNotClaimUniqueGeometry() throws {
        let center = (0..<192 * 256).flatMap { index -> [UInt8] in let value: UInt8 = index % 192 % 24 < 12 ? 64 : 192; return [value, value, value, 255] }
        let outer = (0..<256 * 320).flatMap { index -> [UInt8] in let value: UInt8 = (index % 256 - 32 + 240) % 24 < 12 ? 64 : 192; return [value, value, value, 255] }
        #expect(try !F.measure(center, outer).evidence.reliable)
    }
}
