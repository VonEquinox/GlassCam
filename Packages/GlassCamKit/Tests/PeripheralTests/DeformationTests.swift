import Testing
import Foundation
import simd
@testable import Peripheral

struct DeformationTests {
    static func assessment(_ offsets:[SIMD2<Double>],change:((inout [[String:Any]])->Void)? = nil) -> PeripheralPaneAssessment {
            var rows:[[String:Any]]=(0..<12).map { i in
                let textured=(4..<4+offsets.count).contains(i)
                let offset=textured ? offsets[i-4]:.zero,d=simd_length(offset)
                return ["edge":0,"start":i*16,"end":(i+1)*16,"nativeScale":1.0,"nativeSampleCount":128,
                    "nativeEdgeSupport":textured ? [64,64]:[0,0],"nativeWeakEdgeSupport":textured ? [128,128]:[0,0],
                    "currentNativeGrayVariance":textured ? [0.01,0.01]:[0.0,0.0],"nativeNoiseSigma":[0.0,0.0],
                    "currentNativeGrayNCC":textured ? 0.1:1.0,"flatBothNative": !textured,
                    "segmentStatus":textured ? "measured":"unobservable","segmentSearchComplete":true,
                    "segmentRepeated":false,"segmentPeak":0.99,"segment":i,
                    "segmentVisibleShiftLower":max(0,(d-sqrt(0.5))/192),"segmentVisibleShiftUpper":(d+sqrt(0.5))/192,
                    "segmentPoint":[Double(i*16+8),10.0],"segmentBestDisplacement":[offset.x,offset.y],
                    "segmentForwardBackward":0.0,"segmentDisplacementUncertainty":sqrt(0.5),
                    "missingStructureExtentFraction":0.0]
            }
            change?(&rows)
            var result=PeripheralAlignmentResult(epoch:1,receipt:0,photoAspectRatio:0.75,
                photoToOuter:matrix_identity_float3x3,residual:.nan,gain:SIMD3(repeating:1),seams:.horizontal,expiresAt:0.2)
            result.nativeSeam=PeripheralNativeSeam(strips:[],gains:.init(),evidence:.init(compatible:false,coverage:1,
                maximumObservableError:nil,reason:"controlled-matches",nativeSupportChecked:true),diagnostics:rows)
            return PeripheralPaneAssessment.measure(result,edge:0)
        }

    @Test func uniformTranslation_isNotRelativeDeformation() {
        let result = Self.assessment([SIMD2(14, 0), SIMD2(14, 0), SIMD2(14, 0)])
        #expect(result.deformation == nil)
        #expect(result.darkness(tolerance: 1) == 1)
    }
    @Test func supportedLocalVariation_isNotDilutedByFlatMajority() {
        let result = Self.assessment([SIMD2(6, 0), SIMD2(14, 0), SIMD2(22, 0)])
        #expect(result.darkness(tolerance: 1) == 1)
        #expect((result.deformation ?? 0) > 0.30)
    }
    @Test func legacyVectorsWithoutUncertainty_keepDisplacementWithoutInventingDeformation() {
        let result = Self.assessment([SIMD2(6, 0), SIMD2(14, 0), SIMD2(22, 0)]) { rows in
            for index in rows.indices { rows[index].removeValue(forKey: "segmentDisplacementUncertainty") }
        }
        #expect(result.deformation == nil)
        #expect(result.darkness(tolerance: 1) == 1)
    }
    @Test func relativeShear_shadesBelowAbsoluteThresholdAndRespectsTolerance() {
        let result = Self.assessment([SIMD2(-4, 0), .zero, SIMD2(4, 0)])
        #expect(result.localizedError == nil)
        #expect((result.error ?? 0) < 0.025)
        #expect(result.darkness(tolerance: 1) > 0.1)
        #expect(result.darkness(tolerance: 4) < result.darkness(tolerance: 1))
    }
    static let unsupportedOffsets: [[SIMD2<Double>]] = [
        [SIMD2(2, 0), SIMD2(2, 0), SIMD2(2, 0)], [SIMD2(-0.5, 0), .zero, SIMD2(0.5, 0)],
        [.zero, SIMD2(14, 0), .zero], [SIMD2(-4, 0), SIMD2(4, 0)]
    ]
    @Test(arguments: unsupportedOffsets)
    func insufficientDeformationEvidence_keepsPaneClear(offsets: [SIMD2<Double>]) {
        let result = Self.assessment(offsets)
        #expect(result.deformation == nil)
        #expect(result.darkness(tolerance: 1) == 0)
    }
    @Test(arguments: ["ambiguous", "repeated", "incomplete", "bad-reverse", "duplicate", "uncertain", "gap"])
    func unreliableVectors_cannotEstablishDeformation(kind: String) {
        let result = Self.assessment([SIMD2(-4, 0), .zero, SIMD2(4, 0)]) { rows in
            switch kind {
            case "ambiguous": rows[5]["segmentStatus"] = "ambiguous"
            case "repeated": rows[5]["segmentRepeated"] = true
            case "incomplete": rows[5]["segmentSearchComplete"] = false
            case "bad-reverse": rows[5]["segmentForwardBackward"] = 3.0
            case "duplicate": rows[5]["segment"] = 4
            case "gap": rows[6]["segmentPoint"] = [160.0, 10.0]
            default: for index in rows.indices { rows[index]["segmentDisplacementUncertainty"] = 2.7 }
            }
        }
        #expect(result.deformation == nil)
        #expect(result.darkness(tolerance: 1) == 0)
    }
    @Test(arguments: [0, 1])
    func actualCameraPixels_carryNonuniformDisplacementIntoShade(edge: Int) throws {
        let w=192,h=256,ow=384,oh=512
        var center=[UInt8](repeating:128,count:w*h*4),outer=[UInt8](repeating:128,count:ow*oh*4)
        for i in stride(from:3,to:center.count,by:4) {center[i]=255}
        for i in stride(from:3,to:outer.count,by:4) {outer[i]=255}
        for y in [10,h-11] {for (j,x) in [72,88,104].enumerated() {
            let patch=PeripheralFixtures.texture(width:15,height:15,seed:UInt64(351+y+j*71)),dx=[6,14,22][j]
            for py in 0..<15 {for px in 0..<15 {for c in 0..<3 {
                let value=patch[(py*15+px)*4+c]
                center[((y-7+py)*w+x-7+px)*4+c]=value
                outer[((128+y-7+py)*ow+96+x+dx-7+px)*4+c]=value
            }}}
        }}
        let pair=PeripheralFrameSource.Pair(center:try PeripheralFixtures.pixelBuffer(rgba:center,width:w,height:h),
            outer:try PeripheralFixtures.pixelBuffer(rgba:outer,width:ow,height:oh),receipt:30,
            configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:60)
        let measured=PeripheralAlignmentWorker().analyze(pair,seams:.horizontal,
            window:CGRect(x:0,y:-0.25,width:1,height:1.5),now:{30.01},tolerance:1)!
        let measuredPanes=(0...1).map {PeripheralPaneAssessment.measure(measured,edge:$0)}
        #expect((measuredPanes[edge].deformation ?? 0) > 0.30)
        #expect(measuredPanes[edge].darkness(tolerance: 1) > 0.99)
    }
}

struct TemporalShadeSample {
    let frame: Int
    let time: Double
    let opacity: [Double]
}

enum TemporalShadeFixtures {
    static func deformation(spike: Bool) -> [TemporalShadeSample] {
        let clear = PeripheralPaneAssessment(error: 0, supportFraction: 1, reason: "clear")
        let bent = PeripheralPaneAssessment(reason: "verified-bend", deformation: 0.4)
        var policy = PeripheralPreviewPolicy(), samples: [TemporalShadeSample] = []
        for frame in 0...360 {
            let time = Double(frame) / 60
            let bad = spike ? frame == 120 : (120..<240).contains(frame)
            if frame % 5 == 0 { policy.observe([bad ? bent : clear, clear, clear, clear], at: time) }
            samples.append(.init(frame: frame, time: time, opacity: policy.update(at: time, ready: true, tolerance: 1)))
        }
        return samples
    }
    static func adverse(_ name: String) -> [TemporalShadeSample] {
        let clear = PeripheralPaneAssessment(error: 0, supportFraction: 1, reason: "current-clear-seam")
        let bad = PeripheralPaneAssessment(error: 0.14, supportFraction: 1, reason: "current-bad-seam")
        var policy = PeripheralPreviewPolicy(), samples: [TemporalShadeSample] = []
        for frame in 0...420 {
            let time = Double(frame) / 60
            var observation = clear
            if time >= 2 {
                switch name {
                case "step": observation = bad
                case "spike": observation = frame < 125 ? bad : clear
                case "alternating": observation = time < 3 || (frame / 5) % 2 == 0 ? bad : clear
                case "unknown": observation = time < 3 || (frame / 5) % 2 == 0 ? bad : .init()
                case "sparse-recovery": observation = time < 4 ? bad : PeripheralPaneAssessment(error: 0, supportFraction: 0.1, reason: "only-few-matches", observationCoverage: 0.2)
                default: observation = time < 4 ? bad : clear
                }
            }
            if frame % 5 == 0 { policy.observe([observation, observation, clear, clear], at: time, tolerance: 1) }
            samples.append(.init(frame: frame, time: time, opacity: policy.update(at: time, ready: true, tolerance: 1)))
        }
        return samples
    }
}

struct TemporalShadeTests {
    @Test(arguments: [false, true])
    func deformation_keepsHorizontalPanesLinked(spike: Bool) {
        let samples = TemporalShadeFixtures.deformation(spike: spike)
        #expect(samples.map { $0.opacity[0] } == samples.map { $0.opacity[1] })
    }
    @Test func isolatedDeformation_doesNotFlashBlack() throws {
        let values = TemporalShadeFixtures.deformation(spike: true).filter { $0.frame >= 120 }.map { $0.opacity[0] }
        #expect(try #require(values.max()) < 0.01)
    }
    @Test func persistentDeformation_staysDarkUntilStableRecovery() throws {
        let samples = TemporalShadeFixtures.deformation(spike: false)
        #expect(try #require(samples.filter { (145...275).contains($0.frame) }.map { $0.opacity[0] }.min()) > 0.99)
        #expect(try #require(samples.filter { $0.frame >= 330 }.map { $0.opacity[0] }.max()) < 0.01)
    }
    @Test(arguments: ["step", "spike", "alternating", "unknown", "recovery", "sparse-recovery"])
    func adverseTransitions_keepHorizontalShadeLinked(name: String) {
        let samples = TemporalShadeFixtures.adverse(name)
        #expect(samples.map { $0.opacity[0] } == samples.map { $0.opacity[1] })
    }
    @Test(arguments: ["step", "alternating", "unknown", "recovery", "sparse-recovery"])
    func persistentBadEvidence_darkensWithinDeclaredDeadline(name: String) throws {
        let black = try #require(TemporalShadeFixtures.adverse(name).first { $0.time >= 2 && $0.opacity[0] >= 0.95 })
        #expect(black.time - 2 <= 0.35)
    }
    @Test func isolatedBadObservation_doesNotFlashBlack() throws {
        let values = TemporalShadeFixtures.adverse("spike").filter { $0.time >= 2 }.map { $0.opacity[0] }
        #expect(try #require(values.max()) < 0.01)
    }
    @Test(arguments: ["alternating", "unknown", "sparse-recovery"])
    func intermittentOrSparseGoodEvidence_cannotReopenBadSeam(name: String) throws {
        let values = TemporalShadeFixtures.adverse(name).filter { $0.time >= 3.5 }.map { $0.opacity[0] }
        #expect(try #require(values.min()) >= 0.95)
    }
    @Test func sustainedGoodEvidence_waitsForStabilityThenRecovers() throws {
        let samples = TemporalShadeFixtures.adverse("recovery")
        let values = samples.filter { (4...4.6).contains($0.time) }.map { $0.opacity[0] }
        let clear = try #require(samples.first { $0.time >= 4 && $0.opacity[0] <= 0.05 })
        #expect(try #require(values.min()) >= 0.95)
        #expect(clear.time - 4 < 1.5)
    }
    @Test func overdueAnalysis_requiresContinuousReturningCoverage() throws {
        let clear = PeripheralPaneAssessment(error: 0, supportFraction: 1, reason: "clear")
        var policy = PeripheralPreviewPolicy(), samples: [TemporalShadeSample] = []
        for frame in 0...300 {
            let time = Double(frame) / 60
            if frame % 5 == 0 {
                let input: PeripheralPaneAssessment = (2..<3).contains(time) ? .init() : clear
                policy.observe([input, input, clear, clear], at: time)
            }
            samples.append(.init(frame: frame, time: time, opacity: policy.update(at: time, ready: true, tolerance: 1)))
        }
        #expect(try #require(samples.filter { (3..<3.6).contains($0.time) }.map { $0.opacity[0] }.min()) > 0.95)
        #expect(try #require(samples.filter { $0.time >= 4.5 }.map { $0.opacity[0] }.max()) < 0.01)
    }
}
