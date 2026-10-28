import ImagingCore
import Foundation
import CoreImage
import Metal
import simd

/// A display preference, separate from the strict measurement/certificate in
/// PeripheralEvidence. Unknown disparity remains unknown in saved evidence.
package struct PeripheralPaneAssessment {
    package init(error: Double? = nil, mismatchFraction: Double = 0, supportFraction: Double = 0,
                 missingStructureFraction: Double = 0, corroboratedShiftLower: Double? = nil, reason: String = "unobserved",
                 observationCoverage: Double = 1, affectedFraction: Double = 0, localizedError: Double? = nil, deformation: Double? = nil) {
        self.error = error; self.mismatchFraction = mismatchFraction; self.supportFraction = supportFraction
        self.missingStructureFraction = missingStructureFraction; self.corroboratedShiftLower = corroboratedShiftLower
        self.reason = reason; self.observationCoverage = observationCoverage; self.affectedFraction = affectedFraction
        self.localizedError = localizedError; self.deformation = deformation
    }
    package var error: Double?
    package var mismatchFraction = 0.0
    package var supportFraction = 0.0
    package var missingStructureFraction = 0.0
    package var corroboratedShiftLower: Double?
    package var reason = "unobserved"
    package var observationCoverage = 1.0
    package var affectedFraction = 0.0
    package var localizedError:Double?
    /// Conservative change in displacement per analysis pixel along a seam.
    /// This is a display-continuity measure, not optical lens distortion.
    package var deformation:Double?

    private struct VectorMatch {
        let point:SIMD2<Double>
        let offset:SIMD2<Double>
        let uncertainty:Double
        let segment:Int
    }
    private struct LocalMatch {
        let distance:Double
        let lower:Double
        let vector:VectorMatch?
    }

    private static func deformation(in matches:[LocalMatch]) -> Double? {
        let vectors=matches.compactMap(\.vector)
        guard vectors.count==matches.count,vectors.count>=3,
              Set(vectors.map(\.segment)).count==vectors.count else {return nil}
        var changes:[(vector:SIMD2<Double>,lower:Double)]=[]
        for (a,b) in zip(vectors,vectors.dropFirst()) {
            let spacing=simd_distance(a.point,b.point)
            // Adjacent independent 16-pixel patches only. Missing matches and
            // duplicate/corner anchors cannot become apparent deformation.
            guard spacing>=8,spacing<=24 else {return nil}
            let change=(b.offset-a.offset)/spacing
            let lower=max(0,simd_length(b.offset-a.offset)-a.uncertainty-b.uncertainty)/spacing
            changes.append((change,lower))
        }
        var result=0.0
        for (a,b) in zip(changes,changes.dropFirst()) {
            // A single wrong middle match produces opposing changes. Require
            // two supported changes with a compatible direction instead.
            guard a.lower>0,b.lower>0,
                  simd_dot(a.vector,b.vector)>=0.5*simd_length(a.vector)*simd_length(b.vector) else {continue}
            result=max(result,min(a.lower,b.lower))
        }
        return result>0 ? result:nil
    }

    package func darkness(tolerance: Double) -> Double {
        let scale = pow(PeripheralTolerance.normalized(tolerance),0.25)
        func ramp(_ value: Double, _ low: Double, _ high: Double) -> Double {
            let t = max(0,min(1,(value-low)/(high-low)))
            return t*t*(3-2*t)
        }
        // Tolerance enlarges the acceptable displacement; it never erases
        // a coherent structure that exists in only one of the two images.
        let displacement = error.map { ramp($0,0.025*scale,0.065*scale) } ?? 0
        let confirmed = corroboratedShiftLower.map { ramp($0,0.025*scale,0.065*scale) } ?? 0
        let missing = ramp(missingStructureFraction,0.08,0.22)
        let broadMismatch = ramp(mismatchFraction,0.18,0.45)
        let localized=localizedError.map {ramp($0,0.025*scale,0.065*scale)} ?? 0
        // 10–30% relative displacement change shades a reliably observed local
        // stretch/bend, including when its absolute displacement is still small.
        let shape=deformation.map {ramp($0,0.10*scale,0.30*scale)} ?? 0
        return max(shape,max(localized,max(confirmed,max(missing,max(displacement*min(1,supportFraction/0.25),broadMismatch)))))
    }

    package static func measure(_ result: PeripheralAlignmentResult, edge: Int) -> Self {
        let rows = result.nativeSeam?.diagnostics.filter { $0["edge"] as? Int == edge }
            .sorted {($0["start"] as? Int ?? 0)<($1["start"] as? Int ?? 0)} ?? []
        guard !rows.isEmpty else { return .init() }
        var distances: [Double] = [], bad = 0.0, supported = 0, missing = 0.0,observed=0
        var localMatches:[LocalMatch?]=[]
        var affected=0.0
        func visibleRisk(_ distance:Double)->Double {
            let t=max(0,min(1,(distance-0.025)/0.04))
            return t*t*(3-2*t)
        }
        for row in rows {
            let support = row["nativeEdgeSupport"] as? [Int] ?? [0,0]
            let weak = row["nativeWeakEdgeSupport"] as? [Int] ?? [0,0]
            let variances = (row["currentNativeGrayVariance"] as? [NSNumber])?.map { $0.doubleValue } ?? [0,0]
            let noise = (row["nativeNoiseSigma"] as? [NSNumber])?.map { $0.doubleValue } ?? [0,0]
            let ncc = (row["currentNativeGrayNCC"] as? NSNumber)?.doubleValue ?? 0
            let upper = (row["segmentVisibleShiftUpper"] as? NSNumber)?.doubleValue
            let lower = (row["segmentVisibleShiftLower"] as? NSNumber)?.doubleValue ?? 0
            let normalUpper=(row["segmentNormalUpper"] as? NSNumber)?.doubleValue
            let normalLower=(row["segmentNormalLower"] as? NSNumber)?.doubleValue ?? 0
            let short = 192*min(1,1/result.photoAspectRatio)
            let boundedNormal=normalUpper.map {$0.isFinite && $0>=0 && $0-normalLower<=3/short} == true
            // An ambiguous candidate interval's far endpoint is uncertainty,
            // not an observed large displacement. Keep physical UNKNOWN intact.
            let bounded2D=row["segmentStatus"] as? String == "measured" ||
                (row["segmentStatus"] == nil && upper.map {$0.isFinite && $0-lower<=3/short} == true)
            let knownMatch = row["segmentSearchComplete"] as? Bool == true && row["segmentRepeated"] as? Bool != true &&
                (boundedNormal || bounded2D) && upper.map {$0.isFinite && $0>=0} == true
            let matchedDistance=boundedNormal ? ((normalUpper ?? 0)+normalLower)/2:((upper ?? 0)+lower)/2
            let matchedLower=boundedNormal ? normalLower:lower
            let peak = (row["segmentPeak"] as? NSNumber)?.doubleValue ?? .nan
            let distance = (row["robustObservableDistanceNative"] as? NSNumber)?.doubleValue ??
                (row["maxObservableDistanceNative"] as? NSNumber)?.doubleValue ?? 0
            let nativeScale = (row["nativeScale"] as? NSNumber)?.doubleValue ?? 1
            let normalizedDistance = (distance/max(1,nativeScale)+1)/short
            let sampleCount=(row["nativeSampleCount"] as? NSNumber)?.doubleValue ?? 0
            let hasLine = support.count == 2 && Double(max(support[0],support[1])) >= max(3,0.005*sampleCount)
            let hasCounterpart = weak.count == 2 && min(weak[0],weak[1]) >= 3
            let visibleSignal = hasLine || (row["flatBothNative"] as? Bool != true &&
                variances.count==2 && min(variances[0],variances[1])>0.00005)
            var vector:VectorMatch?
            if knownMatch,visibleSignal,row["segmentStatus"] as? String == "measured",peak.isFinite,peak>=0.95,
               let fb=(row["segmentForwardBackward"] as? NSNumber)?.doubleValue,(0...1).contains(fb),
               let point=(row["segmentPoint"] as? [NSNumber])?.map({$0.doubleValue}),point.count==2,point.allSatisfy(\.isFinite),
               let offset=(row["segmentBestDisplacement"] as? [NSNumber])?.map({$0.doubleValue}),offset.count==2,offset.allSatisfy(\.isFinite),
               let segment=row["segment"] as? Int,segment>=0,
               let uncertainty=(row["segmentDisplacementUncertainty"] as? NSNumber)?.doubleValue,
               uncertainty.isFinite,(sqrt(0.5)-0.000001...3).contains(uncertainty) {
                vector=VectorMatch(point:SIMD2(point[0],point[1]),offset:SIMD2(offset[0],offset[1]),
                    uncertainty:uncertainty,segment:segment)
            }
            localMatches.append(knownMatch && visibleSignal ? LocalMatch(distance:matchedDistance,lower:matchedLower,vector:vector):nil)
            let asymmetry = variances.count==2 && max(variances[0],variances[1])>0.0005 &&
                min(variances[0],variances[1])*16<max(variances[0],variances[1]) && ncc<0.3
            let missingLine = hasLine && !knownMatch &&
                ((!hasCounterpart && normalizedDistance>0.06) || (asymmetry && normalizedDistance>0.04))
            let missingExtent=(row["missingStructureExtentFraction"] as? NSNumber)?.doubleValue ?? (missingLine ? 1:0)
            // Current visible seam damage is independent of whether a local
            // feature also found a correspondence elsewhere in the image.
            // A flat majority cannot outvote a substantial displaced section.
            if hasLine {
                missing += missingExtent
                let displacementRisk=knownMatch && visibleSignal ? visibleRisk(matchedDistance):0
                affected += max(displacementRisk,missingExtent)
            }
            if row["flatBothNative"] as? Bool == true && !hasLine {distances.append(0);observed += 1}
            else if knownMatch, visibleSignal {distances.append(matchedDistance);supported += 1;observed += 1}
            else if hasLine && hasCounterpart && !missingLine {
                distances.append(normalizedDistance);supported += 1
                observed += 1
            }
            else if missingLine {observed += 1}
            let textured = variances.count==2 && noise.count==2 && (0..<2).allSatisfy {
                variances[$0] > max(0.00005,4*noise[$0]*noise[$0])
            }
            // Zero-offset NCC can be low for a harmless 3–5 pixel shift.
            // A completed local correspondence measures that shift directly;
            // it is used for opacity only, never to warp the displayed image.
            if hasLine && !knownMatch {
                let signalExtent=min(1,Double(support.max() ?? 0)/max(3,0.05*sampleCount))
                let searchFailed=row["segmentSearchComplete"] as? Bool == true && peak.isFinite
                let correlationFailure=searchFailed ? max(0,min(1,(0.70-peak)/0.30)):0
                let grayDisagreement=max(0,min(1,(0.4-ncc)/0.4))
                let unmatchedDamage = textured ? correlationFailure*signalExtent*grayDisagreement:0
                // Count actual damage continuously. A tile failing a Boolean
                // test cannot suddenly contribute a full 1/12 of the pane.
                bad += max(missingExtent,unmatchedDamage)
            }
        }
        distances.sort()
        // Retain measured flat tiles in the spatial population and interpolate
        // the percentile; never promote an ambiguous interval's far endpoint.
        let position=Double(max(0,distances.count-1))*0.75
        let index=Int(position),fraction=position-Double(index)
        let error=distances.isEmpty ? nil:distances[index]*(1-fraction)+distances[min(index+1,distances.count-1)]*fraction
        let localCount=max(2,Int(ceil(Double(rows.count)*0.25)))
        var localized:Double?,localLower:Double?,deformation:Double?
        if rows.count>=localCount {
            for start in 0...(rows.count-localCount) {
                let group=localMatches[start..<(start+localCount)].compactMap {$0}
                guard group.count==localCount else {continue}
                if let shape=Self.deformation(in:group) {deformation=max(deformation ?? 0,shape)}
                let values=group.map(\.distance).sorted(),bounds=group.map(\.lower).sorted()
                let middle=(group.count-1)/2,lower=bounds[middle]
                guard bounds[0]>0.025,lower>0.045 else {continue}
                // The whole contiguous group must have a confirmed displacement,
                // with a substantial majority error. A stretch must not escape
                // merely because adjacent displacements differ in magnitude.
                localized=max(localized ?? 0,values[middle])
                localLower=max(localLower ?? 0,lower)
            }
        }
        var value = Self(error:error,mismatchFraction:Double(bad)/Double(rows.count),
            supportFraction:Double(supported)/Double(rows.count),missingStructureFraction:Double(missing)/Double(rows.count),
            corroboratedShiftLower:localLower,
            reason:observed==0 ? "unobserved":missing>0 ? "unmatched-visible-structure":"direct-seam-distribution",
            observationCoverage:Double(observed)/Double(rows.count),affectedFraction:affected/Double(rows.count),localizedError:localized,
            deformation:deformation)
        if result.evidence.reliable, let lower=result.evidence.interval?.lowerBound, lower.isFinite {
            value.error=max(value.error ?? 0,lower);value.supportFraction=1
        }
        return value
    }
}

/// Confirm adverse evidence quickly; require continuous positive evidence to
/// release it. Worsening and recovery must not share a symmetric median delay.
private struct PeripheralSeamEstimate {
    private var adverse:[(Double,PeripheralPaneAssessment)]=[]
    private var recovery:[PeripheralPaneAssessment]=[]
    private var recoverySince:Double?
    private var lastInputAt:Double?
    public private(set) var value=PeripheralPaneAssessment()
    public private(set) var observedAt:Double?
    public private(set) var decision="awaiting-first-observation"
    mutating func observe(_ observation:PeripheralPaneAssessment,at time:Double,tolerance:Double) {
        guard observation.reason != "unobserved",observation.observationCoverage>0 else {
            recoverySince=nil;recovery=[];lastInputAt=nil
            decision="unknown-does-not-release-shade";return
        }
        if lastInputAt.map({time-$0>0.26}) ?? true {recoverySince=nil;recovery=[]}
        lastInputAt=time
        guard observedAt != nil else {
            value=observation;observedAt=time;decision="first-observation";return
        }
        observedAt=time
        var measured=observation
        // Preserve subpixel stability without attenuating a real step change.
        if let old=value.error,let new=measured.error,abs(old-new)<=1.0/192 {measured.error=old}
        if let old=value.localizedError,let new=measured.localizedError,abs(old-new)<=1.0/192 {measured.localizedError=old}
        if let old=value.deformation,let new=measured.deformation,abs(old-new)<=1.0/32 {measured.deformation=old}
        if abs(value.missingStructureFraction-measured.missingStructureFraction)<=0.02 {measured.missingStructureFraction=value.missingStructureFraction}
        if abs(value.affectedFraction-measured.affectedFraction)<=0.02 {measured.affectedFraction=value.affectedFraction}
        if abs(value.mismatchFraction-measured.mismatchFraction)<=0.02 {measured.mismatchFraction=value.mismatchFraction}
        // Releasing shade needs a larger measured improvement than adding it;
        // otherwise a few edge pixels changing strength can repeatedly reopen.
        if let old=value.error,let new=measured.error,new<old,old-new<=2.0/192 {measured.error=old}
        if let old=value.localizedError,let new=measured.localizedError,new<old,old-new<=2.0/192 {measured.localizedError=old}
        if let old=value.deformation,let new=measured.deformation,new<old,old-new<=1.0/16 {measured.deformation=old}
        if measured.missingStructureFraction<value.missingStructureFraction,
           value.missingStructureFraction-measured.missingStructureFraction<=0.04 {measured.missingStructureFraction=value.missingStructureFraction}
        if measured.mismatchFraction<value.mismatchFraction,
           value.mismatchFraction-measured.mismatchFraction<=0.04 {measured.mismatchFraction=value.mismatchFraction}
        let current=value.darkness(tolerance:tolerance),wanted=measured.darkness(tolerance:tolerance)
        adverse.removeAll {time-$0.0>0.35}
        if wanted>current+0.02 {
            recoverySince=nil;recovery=[]
            let strong=(measured.corroboratedShiftLower ?? 0)>=0.065 ||
                measured.missingStructureFraction>=0.22 || measured.affectedFraction>=0.25
            adverse.append((time,measured))
            if strong || adverse.count>=2 {
                // Two adverse observations can straddle one uncertain reading.
                // Take the less severe of the last two, rather than averaging
                // old clear frames into a newly detected unsafe seam.
                value=strong ? measured:adverse.suffix(2).min(by:{$0.1.darkness(tolerance:tolerance)<$1.1.darkness(tolerance:tolerance)})!.1
                adverse=[];decision="confirmed-worsening"
            } else {decision="confirming-worsening"}
        } else if wanted<current-0.02 {
            guard measured.observationCoverage>=0.65 else {
                recoverySince=nil;recovery=[];decision="insufficient-recovery-coverage";return
            }
            if recoverySince==nil {recoverySince=time}
            recovery.append(measured)
            if recovery.count>3 {recovery.removeFirst()}
            if time-recoverySince!>=0.65 && recovery.count>=3 {
                value=recovery.sorted {$0.darkness(tolerance:tolerance)<$1.darkness(tolerance:tolerance)}[recovery.count/2]
                adverse=[];decision="stable-recovery"
            } else {decision="waiting-for-stable-recovery"}
        } else {
            recoverySince=nil;recovery=[];decision="within-measurement-deadband"
        }
    }
}

/// Fresh camera pixels determine availability. Analysis adjusts shade smoothly;
/// top and bottom share the darker requirement before debounce and smoothing.
package struct PeripheralPreviewPolicy {
    package init() {}
    private var alpha = [Double](repeating:1,count:4)
    private var target = [Double](repeating:1,count:4)
    private var lastSample: Double?
    private var lastTick: Double?
    private var shownSince: Double?
    private var missingSince: Double?
    private var observations = [PeripheralPaneAssessment](repeating:.init(),count:4)
    private var rawObservations=[PeripheralPaneAssessment](repeating:.init(),count:4)
    private var estimates=[PeripheralSeamEstimate](repeating:.init(),count:4)
    private var checked = [Bool](repeating:false,count:4)
    private var recheckNeeded=[Bool](repeating:false,count:4)
    private var recheckSince=[Double?](repeating:nil,count:4)
    private var recheckLast=[Double?](repeating:nil,count:4)
    public private(set) var reasons = [String](repeating:"live-preview-awaiting-analysis",count:4)

    package mutating func observe(_ values: [PeripheralPaneAssessment], at time: Double,
                          tolerance:Double = PeripheralTolerance.defaultValue) {
        guard values.count == 4, time.isFinite, lastSample.map({time>$0}) ?? true else { return }
        rawObservations=values
        var inputs=values
        if values[0].reason != "unobserved",values[1].reason != "unobserved" {
            let a=values[0].darkness(tolerance:tolerance),b=values[1].darkness(tolerance:tolerance)
            let worse=a==b ? ((values[0].error ?? 0) >= (values[1].error ?? 0) ? values[0]:values[1]):(a>b ? values[0]:values[1])
            inputs[0]=worse;inputs[1]=worse
        }
        for edge in 0..<4 {
            if checked[edge],estimates[edge].observedAt.map({time-$0>0.45}) == true {recheckNeeded[edge]=true}
            estimates[edge].observe(inputs[edge],at:time,tolerance:tolerance)
            observations[edge] = estimates[edge].value; checked[edge] = estimates[edge].observedAt != nil
            if recheckNeeded[edge] {
                if inputs[edge].reason != "unobserved",inputs[edge].observationCoverage>=0.65 {
                    if recheckLast[edge].map({time-$0>0.26}) == true {recheckSince[edge]=nil}
                    if recheckSince[edge]==nil {recheckSince[edge]=time}
                    recheckLast[edge]=time
                    if time-recheckSince[edge]!>=0.65 {recheckNeeded[edge]=false;recheckSince[edge]=nil}
                } else {recheckSince[edge]=nil;recheckLast[edge]=nil}
            }
        }
        lastSample = time
    }
    package mutating func update(at time: Double, ready: Bool, tolerance: Double) -> [Double] {
        guard time.isFinite, lastTick.map({ time >= $0 }) ?? true else { return [Double](repeating:1,count:4) }
        let dt = min(0.1,max(0,time-(lastTick ?? time))); lastTick = time
        let recent = (0..<4).map {estimates[$0].observedAt.map {time-$0<=0.45} ?? false}
        for edge in 0..<4 where checked[edge] && !recent[edge] {
            recheckNeeded[edge]=true;recheckSince[edge]=nil;recheckLast[edge]=nil
        }
        // Merge before temporal filtering so switching the worse seam from
        // top to bottom cannot briefly brighten both during their handoff.
        let wantedOpacities = sharingTopBottom((0..<4).map {
            recent[$0] && checked[$0] && !recheckNeeded[$0] ? observations[$0].darkness(tolerance:tolerance):1
        })
        for edge in 0..<4 {
            target[edge] = wantedOpacities[edge]
            let rate = target[edge] > alpha[edge] ? 1/0.14 : 1/0.60
            let travel = dt*rate
            alpha[edge] += max(-travel,min(travel,target[edge]-alpha[edge]))
            reasons[edge] = !checked[edge] ? "awaiting-first-direct-seam-check" : !recent[edge] ? "direct-seam-check-overdue" :
                recheckNeeded[edge] ? "waiting-for-continuous-current-evidence" :
                target[edge] > 0 ? "persistent-broad-mismatch" : "within-display-tolerance"
        }
        if !ready || !checked.contains(true) {
            if missingSince == nil { missingSince = time }
            if time-missingSince! > 0.20 { shownSince = nil }
            return [Double](repeating:1,count:4)
        }
        if let missingSince, time-missingSince > 0.20 { shownSince = nil }
        missingSince = nil
        if shownSince == nil { shownSince = time }
        let startup = max(0,1-(time-shownSince!)/0.20)
        return sharingTopBottom((0..<4).map { checked[$0] ? max(alpha[$0],startup):1 })
    }
    private func sharingTopBottom(_ values: [Double]) -> [Double] {
        var shared = values
        let darkest = max(values[0],values[1])
        shared[0] = darkest; shared[1] = darkest
        return shared
    }
    package var targets: [Double] { sharingTopBottom((0..<4).map { checked[$0] ? target[$0]:1 }) }
    package var diagnostics: [[String:Any]] {
        observations.enumerated().map { edge,value -> [String:Any] in
            var row:[String:Any] = ["edge":edge,"checked":checked[edge],"visibleError":value.error ?? .nan,
             "mismatchFraction":value.mismatchFraction,"supportFraction":value.supportFraction,
             "missingStructureFraction":value.missingStructureFraction,
             "corroboratedShiftLower":value.corroboratedShiftLower ?? .nan,
             "observationCoverage":value.observationCoverage,
             "rawVisibleError":rawObservations[edge].error ?? .nan,
             "rawMissingStructureFraction":rawObservations[edge].missingStructureFraction,
             "rawObservationCoverage":rawObservations[edge].observationCoverage,
             "affectedFraction":value.affectedFraction,"rawAffectedFraction":rawObservations[edge].affectedFraction,
             "localizedError":value.localizedError ?? .nan,"rawLocalizedError":rawObservations[edge].localizedError ?? .nan,
             "transitionDecision":estimates[edge].decision,
             "recheckNeeded":recheckNeeded[edge],"recheckSince":recheckSince[edge] ?? .nan,
             "reason":value.reason,"observedAt":estimates[edge].observedAt ?? .nan]
            row["deformation"]=value.deformation ?? .nan
            row["rawDeformation"]=rawObservations[edge].deformation ?? .nan
            return row
        }
    }
}

/// Current pixels with fixed FOV scale/centering. An earlier raw-seam analysis
/// controls only shade; its fitted transforms never enter this image.
public struct PeripheralLiveFrame {
    public let pair: PeripheralFrameSource.Pair
    public let matrix: simd_float3x3
    public let gains: PeripheralEdgeGains
    public var refinement: PeripheralDenseRefinement?
    public var refinementStrength: Float
    public let analysisPairID: UInt64
    public let analysisObservedAt: Double?
    let modelPair: PeripheralFrameSource.Pair?
    public var mappingBasis: String
    public let seams: PeripheralSeams
    public let tolerance: Double
    public let margin: Float
    public func image() -> CIImage? { CIImage(cvPixelBuffer:pair.outer) }
}

/// Shared by the renderer and offline tests. Camera pixels use only fixed FOV
/// scale/centering. Independent raw-seam measurements control opacity.
public final class PeripheralLivePipeline {
    public init() {}
    public static let pixelLifetime = 0.20
    private var epoch: UInt64 = .max
    private var seams: PeripheralSeams = []
    private var dimensions = SIMD4<Int>(repeating:0)
    private var accepted: PeripheralAlignmentResult?
    private var lastAnalysisID: UInt64 = 0
    private var policy = PeripheralPreviewPolicy()
    private var currentWindow = CGRect.zero
    private var mappingAvailable = false
    public private(set) var sourceAvailable = false
    public private(set) var lastReason = "no-live-source"
    public private(set) var lastAnalysisAge = Double.infinity
    public var targets: [Double] { policy.targets }
    public var reasons: [String] { policy.reasons }
    public var assessments: [[String:Any]] { policy.diagnostics }

    public func update(pair: PeripheralFrameSource.Pair?, analysis: PeripheralAlignmentResult?, enabled: Bool,
                epoch: UInt64, seams: PeripheralSeams, window: CGRect, tolerance: Double,
                at time: Double) -> PeripheralLiveFrame? {
        currentWindow = window; mappingAvailable = false
        let size = pair.map { SIMD4(CVPixelBufferGetWidth($0.center),CVPixelBufferGetHeight($0.center),
            CVPixelBufferGetWidth($0.outer),CVPixelBufferGetHeight($0.outer)) } ?? dimensions
        if self.epoch != epoch || self.seams != seams || size != dimensions {
            self.epoch = epoch; self.seams = seams; dimensions = size
            accepted = nil; lastAnalysisID = 0; policy = .init()
        }
        sourceAvailable = enabled && pair?.epoch == epoch && time.isFinite &&
            pair.map { time >= $0.observedAt && time-$0.observedAt <= Self.pixelLifetime } == true
        guard sourceAvailable, let pair, pair.ratio.isFinite, pair.ratio > 1.02,
              size.x > 0, size.y > 0, size.z > 0, size.w > 0 else { lastReason = "no-fresh-live-source"; return nil }
        let w = 192, h = Int((Double(w)*Double(size.y)/Double(size.x)).rounded())
        let fixed = PeripheralAlignmentWorker.samplingTransform(homography:matrix_identity_float3x3,width:w,height:h,ratio:pair.ratio)
        let margin = PeripheralProjection.margin(fixed,window:window,width:size.z,height:size.w) ?? -.infinity
        guard margin >= 2 else { lastReason = "live-source-does-not-cover-window"; return nil }
        if let analysis, analysis.directStitch, analysis.epoch == epoch, analysis.seams == seams,
           analysis.pairID > lastAnalysisID, time >= analysis.receipt, time-analysis.receipt <= 0.65,
           abs(analysis.photoAspectRatio-Double(size.x)/Double(size.y)) < 0.001,
           analysis.inputPair.map({ $0.serial==analysis.pairID && $0.epoch==epoch &&
               CVPixelBufferGetWidth($0.center)==size.x && CVPixelBufferGetHeight($0.center)==size.y &&
               CVPixelBufferGetWidth($0.outer)==size.z && CVPixelBufferGetHeight($0.outer)==size.w && abs($0.ratio-pair.ratio)<0.0001 }) == true {
            lastAnalysisID = analysis.pairID
            accepted = analysis
            policy.observe((0..<4).map {PeripheralPaneAssessment.measure(analysis,edge:$0)},at:analysis.receipt,tolerance:tolerance)
        }
        lastAnalysisAge = accepted.map { time-$0.receipt } ?? .infinity
        lastReason = "live-direct-field-of-view-stitch"; mappingAvailable = true
        return .init(pair:pair,matrix:fixed,gains:.init(),refinement:nil,
            refinementStrength:0,analysisPairID:accepted?.pairID ?? 0,analysisObservedAt:accepted?.receipt,modelPair:accepted?.inputPair,
            mappingBasis:lastReason,seams:seams,tolerance:tolerance,margin:margin)
    }

    public func resourceValid(_ bundle: PeripheralLiveTextureStore.Bundle?, revision: UInt64, at time: Double) -> Bool {
        guard sourceAvailable, mappingAvailable, let bundle else { return false }
        let required = 2+Float(max(dimensions.z,dimensions.w))*(bundle.frame.refinement?.maximumOffset ?? 0)*bundle.frame.refinementStrength/bundle.frame.pair.ratio
        let margin = PeripheralProjection.margin(bundle.frame.matrix,window:currentWindow,width:dimensions.z,height:dimensions.w) ?? -.infinity
        return bundle.revision == revision && bundle.frame.pair.epoch == epoch && bundle.frame.seams == seams &&
            time >= bundle.frame.pair.observedAt && time-bundle.frame.pair.observedAt <= Self.pixelLifetime && margin >= required
    }
    public func opacities(bundle: PeripheralLiveTextureStore.Bundle?, revision: UInt64, at time: Double, tolerance: Double) -> [Double] {
        policy.update(at:time,ready:resourceValid(bundle,revision:revision,at:time),tolerance:tolerance)
    }
}

/// One pending upload, one completed texture and one spare. Render at camera
/// cadence; never wait for an analysis certificate to upload new camera pixels.
public final class PeripheralLiveTextureStore {
    public init() {}
    public final class Bundle {
        public let texture: MTLTexture
        public let centerTexture: MTLTexture?
        let centerTask: CIRenderTask?
        public let frame: PeripheralLiveFrame
        public let revision: UInt64, ticket: UInt64
        public init(texture:MTLTexture,frame:PeripheralLiveFrame,revision:UInt64,ticket:UInt64,
             centerTexture:MTLTexture? = nil,centerTask:CIRenderTask? = nil) {
            self.texture=texture;self.frame=frame;self.revision=revision;self.ticket=ticket
            self.centerTexture=centerTexture;self.centerTask=centerTask
        }
    }
    public private(set) var completed: Bundle?
    private var pending: Bundle?
    private var spare: MTLTexture?
    private var spareCenter: MTLTexture?
    private var ticket: UInt64 = 0
    private var nextAttempt = 0.0
    public private(set) var failureReason: String?
    public func reset() { ticket &+= 1; completed=nil;pending=nil;spare=nil;spareCenter=nil;nextAttempt=0;failureReason=nil }
    public func prepare(_ frame:PeripheralLiveFrame,revision:UInt64,at time:Double,device:MTLDevice,context:CIContext,
                 command:MTLCommandBuffer,colorSpace:CGColorSpace,includeCenter:Bool = false,
                 centerImage:CIImage? = nil) throws -> (Bundle,CIRenderTask)? {
        guard pending == nil, time >= nextAttempt, time >= frame.pair.observedAt,
              time-frame.pair.observedAt <= PeripheralLivePipeline.pixelLifetime,
              frame.margin >= 2, completed?.frame.pair.serial != frame.pair.serial || completed?.revision != revision else {return nil}
        let w=CVPixelBufferGetWidth(frame.pair.outer),h=CVPixelBufferGetHeight(frame.pair.outer)
        if spare?.width != w || spare?.height != h {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:w,height:h,mipmapped:false)
            d.usage=[.shaderRead,.shaderWrite,.renderTarget];spare=device.makeTexture(descriptor:d)
        }
        guard let texture=spare else {failureReason="texture-allocation-failed";nextAttempt=time+0.05;return nil}
        do {
            var central:MTLTexture?,centralTask:CIRenderTask?
            if includeCenter {
                let cw=CVPixelBufferGetWidth(frame.pair.center),ch=CVPixelBufferGetHeight(frame.pair.center)
                if spareCenter?.width != cw || spareCenter?.height != ch {
                    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:cw,height:ch,mipmapped:false)
                    d.usage=[.shaderRead,.shaderWrite,.renderTarget];spareCenter=device.makeTexture(descriptor:d)
                }
                guard let centerTexture=spareCenter else {throw NSError(domain:"PairedPreviewTexture",code:1)}
                let destination=CIRenderDestination(mtlTexture:centerTexture,commandBuffer:command)
                destination.colorSpace=colorSpace;destination.isFlipped=true
                centralTask=try context.startTask(toRender:centerImage ?? CIImage(cvPixelBuffer:frame.pair.center),to:destination)
                central=centerTexture
            }
            let destination=CIRenderDestination(mtlTexture:texture,commandBuffer:command)
            destination.colorSpace=colorSpace;destination.isFlipped=true
            // Direct stitching reads the camera-delivered pixels without a
            // scene-fitted transform, optical flow or color correction.
            let refined=frame.image()
            var actual=frame
            if refined == nil {
                actual.refinement=nil;actual.refinementStrength=0;actual.mappingBasis="live-homography-without-optional-kernel"
            }
            let image=refined ?? CIImage(cvPixelBuffer:frame.pair.outer)
            let task=try context.startTask(toRender:image,to:destination)
            ticket &+= 1
            let bundle=Bundle(texture:texture,frame:actual,revision:revision,ticket:ticket,
                centerTexture:central,centerTask:centralTask)
            pending=bundle;spare=nil
            if includeCenter {spareCenter=nil}
            return (bundle,task)
        } catch {failureReason="live-texture-encode-failed";nextAttempt=time+0.05;throw error}
    }
    @discardableResult
    public func complete(_ bundle:Bundle,success:Bool,revision:UInt64,epoch:UInt64,at time:Double) -> Bool {
        guard pending === bundle,bundle.ticket == ticket,bundle.revision == revision,bundle.frame.pair.epoch == epoch else {return false}
        pending=nil
        if success {spare=completed?.texture;spareCenter=completed?.centerTexture;completed=bundle;failureReason=nil;nextAttempt=0}
        else {spare=bundle.texture;spareCenter=bundle.centerTexture;failureReason="live-texture-upload-failed";nextAttempt=time+0.05}
        return true
    }
}
