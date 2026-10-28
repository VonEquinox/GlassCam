import ImagingCore
import Foundation
import AVFoundation
import CoreImage
import QuartzCore
import simd
import OSLog
import Accelerate
import CryptoKit

public final class PeripheralAlignmentWorker {
    private let clock: () -> Double
    public convenience init() { self.init(clock: CACurrentMediaTime) }
    init(clock: @escaping () -> Double) { self.clock = clock }
    static let measurementInterval = 1.0/12.0
    static let registrationInterval = 0.4
    static let measurementLifetime = 0.20
    static func expectedMeasurementInterval(frameInterval: Double) -> Double {
        guard frameInterval.isFinite, frameInterval >= 1.0/120, frameInterval <= 0.1 else { return measurementInterval }
        return ceil(measurementInterval/frameInterval-1e-6)*frameInterval
    }
    private struct Registration {
        let epoch: UInt64
        let matrix: simd_float3x3
        var verifiedAt: Double
        let id: UInt64
        var refinementID: UInt64 = 0
    }
    private struct EpipolarVerification {
        let identity: String
        let measuredAt: Double
        let center: simd_float3x3
        let outer: simd_float3x3
    }
    private var epipolarVerification: EpipolarVerification?
    private struct Photometry {
        var gain: SIMD3<Float>
        var measuredAt: Double
        var updatedAt: Double
        var id: UInt64
        var geometryID: UInt64
    }
    let queue = DispatchQueue(label: "dev.glasscam.peripheral.registration",qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastRequest = -Double.infinity
    private var result: PeripheralAlignmentResult?
    private var diagnostic: PeripheralAnalysisSnapshot?
    private var runtime: [String:Any] = ["phase":"idle","completedCount":0]
    public func runtimeState() -> [String:Any] { lock.lock(); defer { lock.unlock() }; return runtime }
    private func stage(_ name:String) {
        lock.lock(); runtime["phase"] = name; runtime["stageAt"] = CACurrentMediaTime(); lock.unlock()
    }
    private var registration: Registration?
    private var photometry: Photometry?
    private var edgePhotometry: (gain: PeripheralEdgeGains, observedAt: Double)?
    private var lastRegistrationAttempt = -Double.infinity
    private var analysisEpoch: UInt64?
    private var analysisDimensions = SIMD2<Int>(0,0)
    private var analysisSeams: PeripheralSeams = .all
    private var nextGeometryID: UInt64 = 0
    private let recorder = PeripheralDiagnosticRecorder.shared
    private let signposter = OSSignposter(subsystem: "dev.glasscam.prototype",category: "PeripheralAnalysis")
    let context = CIContext(options: [.cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    public func latest() -> PeripheralAlignmentResult? { lock.lock(); defer { lock.unlock() }; return result }
    public func latestDiagnostic() -> PeripheralAnalysisSnapshot? { lock.lock(); defer { lock.unlock() }; return diagnostic }
    var isAnalyzing: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    package func denseRefinementStatus() -> [String:Any] { ["busy":false,"status":"disabled-for-direct-stitch"] }
    @discardableResult
    public func request(_ pair: PeripheralFrameSource.Pair, seams: PeripheralSeams = .all,
                 window: CGRect = CGRect(x: 0,y: 0,width: 1,height: 1)) -> Bool {
        lock.lock()
        guard !busy, pair.receipt-lastRequest >= Self.measurementInterval else { lock.unlock(); return false }
        busy = true; lastRequest = pair.receipt; lock.unlock()
        lock.lock(); runtime["phase"] = "queued"; runtime["pairID"] = pair.serial
        runtime["queuedAt"] = clock(); lock.unlock()
        let tolerance = PeripheralTolerance.shared.value
        queue.async { [self,pair] in
            let value = autoreleasepool { analyze(pair,seams: seams,window: window,now: clock,tolerance:tolerance) }
            lock.lock()
            // Includes diagnostic enqueue/callback scheduling in the deadline.
            if let value, value.isFresh(for: pair.epoch,at: clock()) { result = value }
            runtime["phase"] = value == nil ? "finished-without-publication" : "published"
            runtime["completedCount"] = (runtime["completedCount"] as? Int ?? 0)+1
            runtime["finishedAt"] = clock()
            busy = false; lock.unlock()
        }
        return true
    }
    package func analyze(_ pair: PeripheralFrameSource.Pair, seams: PeripheralSeams = .all,
                 window: CGRect = CGRect(x: 0,y: 0,width: 1,height: 1),
                 now: () -> Double = CACurrentMediaTime,
                 acquisitionCandidate: simd_float3x3? = nil,
                 tolerance requestedTolerance: Double = PeripheralTolerance.defaultValue) -> PeripheralAlignmentResult? {
        let started = CACurrentMediaTime()
        stage("starting")
        let tolerance = PeripheralTolerance.normalized(requestedTolerance)
        let interval = signposter.beginInterval("Analyze")
        defer { signposter.endInterval("Analyze",interval) }
        var diagnosticReference: [UInt8] = [], diagnosticWarped: [UInt8] = []
        var diagnosticNative: [PeripheralNativeSeam.Strip] = []
        var diagnosticRefinement: PeripheralDenseRefinement?
        var diagnosticState: [String: Any] = ["available": true, "published": false,
            "implementation":"fixed-field-of-view-direct-stitch-v5",
            "measurementDomain":"original-pixels-fixed-field-of-view",
            "tolerance":tolerance,
            "epoch": pair.epoch, "pairID": pair.serial, "startedAt": started,
            "seams": seams.rawValue,
            "window": [window.minX, window.minY, window.width, window.height]]
        defer {
            diagnosticState["finishedAt"] = CACurrentMediaTime()
            diagnosticState["elapsedMS"] = (CACurrentMediaTime() - started) * 1000
            let snapshot = PeripheralAnalysisSnapshot(pair: pair, reference: diagnosticReference,
                warped: diagnosticWarped, metadata: diagnosticState,nativeStrips:diagnosticNative,refinement:diagnosticRefinement)
            lock.lock(); diagnostic = snapshot; lock.unlock()
        }
        func reject(_ reason: String) -> PeripheralAlignmentResult? {
            diagnosticState["reason"] = reason
            PeripheralDiagnostics.trace("alignment rejected: \(reason), age=\(now()-pair.observedAt) pair=\(pair.serial) elapsedMS=\((CACurrentMediaTime()-started)*1000)")
            return nil
        }
        guard now() >= pair.observedAt, now()-pair.observedAt < Self.measurementLifetime,
              !seams.isEmpty else { return reject("expired-input-or-no-seams") }
        let center = CIImage(cvPixelBuffer: pair.center), outer = CIImage(cvPixelBuffer: pair.outer)
        guard center.extent.width > 0, outer.extent.width > 0,
              abs(center.extent.width/center.extent.height-outer.extent.width/outer.extent.height) < 0.01 else { return reject("frame-aspect") }
        let w = 192, h = Int((192*center.extent.height/center.extent.width).rounded())
        guard (96...320).contains(h) else { return reject("analysis-dimensions") }
        if analysisEpoch != pair.epoch || analysisDimensions != SIMD2(w,h) || analysisSeams != seams {
            registration = nil; photometry = nil; edgePhotometry = nil; epipolarVerification = nil; lastRegistrationAttempt = -.infinity
            analysisEpoch = pair.epoch; analysisDimensions = SIMD2(w,h); analysisSeams = seams
        }
        let bounds = CGRect(x: 0,y: 0,width: w,height: h), width = CGFloat(w), height = CGFloat(h)
        let ratio = CGFloat(pair.ratio), tx = width*(1-ratio)/2, ty = height*(1-ratio)/2
        let reference = center.transformed(by: CGAffineTransform(scaleX: width/center.extent.width,y: height/center.extent.height)).cropped(to: bounds)
        let floating = outer.transformed(by: CGAffineTransform(scaleX: width*ratio/outer.extent.width,y: height*ratio/outer.extent.height))
            .transformed(by: CGAffineTransform(translationX: tx,y: ty))
        let readback = signposter.beginInterval("CIReadback")
        stage("reference-readback")
        let referenceBytes = bitmap(reference,bounds: bounds,width: w,height: h)
        diagnosticReference = referenceBytes
        diagnosticState["width"] = w; diagnosticState["height"] = h
        diagnosticState["referenceFormat"] = "RGBA8-sRGB-top-left"
        signposter.endInterval("CIReadback",readback)
        let halo = max(8,Int(Double(min(w,h))*0.16))+2
        diagnosticState["padding"] = halo
        let searchBounds = bounds.insetBy(dx: -CGFloat(halo),dy: -CGFloat(halo))
        // The displayed seam is a fixed field-of-view crop. Measure exactly
        // that crop: fitting a homography/flow first would hide its real error.
        let candidates: [(matrix: simd_float3x3,refreshed: Bool,refinement:PeripheralDenseRefinement?)] =
            [(matrix_identity_float3x3,registration == nil,nil)]
        var selected: (matrix: simd_float3x3,refreshed: Bool,measurement: SeamMeasurement,bytes: [UInt8],margin: Float,refinement:PeripheralDenseRefinement?,outerImage:CIImage,grayScore:Double)?
        var comparisons = 0
        var candidateDiagnostics: [[String: Any]] = []
        diagnosticState["candidateCount"] = candidates.count
        for candidate in candidates {
            stage("candidate-matching")
            guard now()-pair.observedAt < Self.measurementLifetime else { break }
            let transform = Self.samplingTransform(homography: candidate.matrix,width: w,height: h,ratio: pair.ratio)
            candidateDiagnostics.append(["H_columns": PeripheralRecordJSON.matrix(candidate.matrix),
                "photoToOuter_columns": PeripheralRecordJSON.matrix(transform), "refreshed": candidate.refreshed,
                "margin": PeripheralProjection.margin(transform,window:window,
                    width:CVPixelBufferGetWidth(pair.outer),height:CVPixelBufferGetHeight(pair.outer)) ?? -.infinity,
                "requiredMargin": candidate.refreshed ? 4 : 2])
            let candidateOuter = outer
            let candidateFloating = candidateOuter.transformed(by:CGAffineTransform(scaleX:width*ratio/outer.extent.width,y:height*ratio/outer.extent.height))
                .transformed(by:CGAffineTransform(translationX:tx,y:ty))
            guard let margin = PeripheralProjection.margin(transform,window: window,
                width: CVPixelBufferGetWidth(pair.outer),height: CVPixelBufferGetHeight(pair.outer)), margin >= (candidate.refreshed ? 4 : 2),
                let warped = Self.warp(candidateFloating,by: candidate.matrix) else { continue }
            let bytes = bitmap(warped,bounds: searchBounds,width: w+2*halo,height: h+2*halo)
            let grayScore = Self.grayBoundaryScore(referenceBytes,bytes,width:w,height:h,padding:halo,seams:seams)
            candidateDiagnostics[candidateDiagnostics.count-1]["currentGrayBoundaryScore"] = grayScore
            if let old = selected, grayScore < old.grayScore-0.001 { continue }
            // F is enabled only after CURRENT image correspondences independently
            // validate its output coordinate convention; no assumed horizontal line.
            let empiricalF = Self.analysisFundamental(pair,homography: candidate.matrix,width: w,height: h)
            if let empiricalF { diagnosticState["runtimeF_bitmap_columns"] = PeripheralRecordJSON.matrix(empiricalF) }
            diagnosticState["F_coordinateDomain"] = "top-left-analysis-reference-to-top-left-warped-without-halo"
            let certifiedEpipolar: Bool
            if let verification = epipolarVerification, let calibration = pair.calibration,
               verification.identity == calibration.identity, pair.observedAt-verification.measuredAt <= Self.registrationInterval,
               let c = pair.centerMetadata, let o = pair.outerMetadata, let kc = c.intrinsic, let ko = o.intrinsic,
               Self.intrinsicDrift(kc,from:verification.center,width:c.width,height:c.height) < 0.5,
               Self.intrinsicDrift(ko,from:verification.outer,width:o.width,height:o.height) < 0.5 {
                certifiedEpipolar = true
            } else { certifiedEpipolar = false }
            let matchingInterval = signposter.beginInterval("SeamMatching")
            let measurement = Self.measureSeams(reference: referenceBytes,warped: bytes,width: w,height: h,
                warpedPadding: halo,seams: seams,certifiedGeometry: registration != nil,
                previousGain: photometry?.gain,allowPartial: true,
                fundamental: empiricalF,epipolarCertified: certifiedEpipolar,comparisonBudget: max(0,120_000_000-comparisons),deadline: pair.observedAt+Self.measurementLifetime,clock: now)
            signposter.endInterval("SeamMatching",matchingInterval)
            guard let measured = measurement else { continue }
            if measured.epipolarVerified, !certifiedEpipolar,
               let identity = pair.calibration?.identity, let kc = pair.centerMetadata?.intrinsic, let ko = pair.outerMetadata?.intrinsic {
                epipolarVerification = .init(identity:identity,measuredAt:pair.observedAt,center:kc,outer:ko)
            }
            comparisons += measured.comparisons
            // Rank mapping proposals by the CURRENT overlapping grayscale
            // boundary. A count of unique correlation peaks is not a measure
            // of how well the proposed image actually joins the photograph.
            // This score supplies no certificate; native checks below do that.
            if let old = selected {
                if grayScore < old.grayScore-0.001 { continue }
                if abs(grayScore-old.grayScore) <= 0.001 && measured.evidence.coverage < old.measurement.evidence.coverage { continue }
                if abs(grayScore-old.grayScore) <= 0.001 && measured.evidence.coverage == old.measurement.evidence.coverage {
                    let oldError = old.measurement.evidence.interval?.upperBound ?? .infinity
                    let newError = measured.evidence.interval?.upperBound ?? .infinity
                    let saferCoverage = old.margin < 4 && margin >= 4 && newError <= oldError+1/Double(min(w,h))
                    if !saferCoverage && newError >= oldError-1/Double(min(w,h)) { continue }
                }
            }
            selected = (candidate.matrix,candidate.refreshed,measured,bytes,margin,candidate.refinement,candidateOuter,grayScore)
        }
        diagnosticState["candidates"] = candidateDiagnostics
        diagnosticState["comparisons"] = comparisons
        guard let selected else {
            if recorder.recordsPixels {
                let bytes = bitmap(floating,bounds:searchBounds,width:w+2*halo,height:h+2*halo)
                recorder.record(reference:referenceBytes,warped:bytes,width:w,height:h,padding:halo,
                    pair:pair,reason:"no-renderable-candidate",status:"unavailable",matrix:nil,
                    comparisons:comparisons,coverage:0,segments:[],gain:photometry?.gain ?? SIMD3(repeating:1))
            }
            return reject("no-renderable-candidate")
        }
        let measured = selected.measurement
        diagnosticRefinement = selected.refinement
        diagnosticState["denseRefinement"] = denseRefinementStatus()
        diagnosticState["activeRefinementID"] = selected.refinement?.id ?? 0
        diagnosticState["geometryInput"] = "normalized-grayscale-and-native-structure"
        diagnosticState["structuredColorDifferenceControlsOpacity"] = false
        // Direct display has no fitted H or RGB model to certify. Repeating a
        // full search on nine interior patches delayed seam publication while
        // contributing no measurement used by the actual shade estimator.
        let interior:SeamMeasurement?=nil
        let currentGeometryVerified = measured.geometryVerified || interior?.geometryVerified == true
        diagnosticState["interiorGeometryVerified"] = false
        diagnosticState["interiorSearch"]="disabled-unused-by-direct-stitch"
        diagnosticState["interiorSupport"] = interior?.segments.filter { $0.status == .measured }.count ?? 0
        diagnosticState["epipolarFailureReason"] = measured.epipolarVerified ? "none" : "factory-F-not-validated-by-all-independent-probes"
        diagnosticWarped = selected.bytes
        diagnosticState["H_columns"] = PeripheralRecordJSON.matrix(selected.matrix)
        diagnosticState["coverageMargin"] = selected.margin
        diagnosticState["geometryVerified"] = measured.geometryVerified
        diagnosticState["photometryVerified"] = measured.photometryVerified
        diagnosticState["epipolarVerified"] = measured.epipolarVerified
        diagnosticState["epipolarProbeDistancesAnalysisPixels"] = measured.epipolarProbeDistances
        diagnosticState["epipolarProbeThresholdAnalysisPixels"] = 1
        diagnosticState["measurementEvidence"] = PeripheralRecordJSON.evidence(measured.evidence)
        diagnosticState["segments"] = measured.segments.map { segment -> [String: Any] in
            var row: [String: Any] = ["index": segment.index, "point": [segment.point.x,segment.point.y],
                "status": segment.status.rawValue, "searchComplete": segment.searchComplete,
                "gradientEigenvalues": [segment.gradientEigenvalues.x,segment.gradientEigenvalues.y],
                "observableNormal": [segment.observableNormal.x,segment.observableNormal.y]]
            if let range = segment.interval { row["interval"] = [range.lowerBound,range.upperBound] }
            if let best = segment.best { row["bestDisplacement"] = [best.x,best.y] }
            if let fb = segment.forwardBackward { row["forwardBackward"] = fb }
            if let noise = segment.noiseScale { row["analysisNoiseMAD"] = noise }
            if let range = segment.normalInterval { row["normalInterval"] = [range.lowerBound,range.upperBound] }
            row["signalStandardDeviation"] = segment.signalStandardDeviation
            row["repeatedStructure"] = segment.repeatedStructure
            return row
        }
        let geometryID: UInt64
        var verifiedAt = selected.refreshed ? -Double.infinity : registration?.verifiedAt ?? -.infinity
        if selected.refreshed { nextGeometryID &+= 1; geometryID = nextGeometryID }
        else { geometryID = registration?.id ?? 0 }
        if currentGeometryVerified { verifiedAt = pair.observedAt }
        registration = .init(epoch: pair.epoch,matrix: selected.matrix,verifiedAt: verifiedAt,id: geometryID)
        registration?.refinementID = selected.refinement?.id ?? 0
        let photoMeasurement = measured.photometryVerified ? measured : (interior ?? measured)
        if photoMeasurement.photometryVerified {
            let target = photoMeasurement.gain
            if var old = photometry, old.geometryID == geometryID {
                let dt = max(0,pair.observedAt-old.updatedAt), beta = Float(1-exp(-dt/0.12))
                for c in 0..<3 {
                    let delta = log(target[c])-log(old.gain[c])
                    old.gain[c] = exp(log(old.gain[c])+max(-Float(dt)*1.3863,min(Float(dt)*1.3863,beta*delta)))
                }
                old.measuredAt = pair.observedAt; old.updatedAt = pair.observedAt; old.id &+= 1; photometry = old
            } else { photometry = .init(gain: target,measuredAt: pair.observedAt,updatedAt: pair.observedAt,id: 1,geometryID: geometryID) }
        }
        let geometryExpiry = verifiedAt+Self.registrationInterval+0.10
        let photoExpiry = (photometry?.geometryID == geometryID ? photometry?.measuredAt ?? -.infinity : -.infinity)+Self.measurementLifetime
        var evidence = measured.evidence
        var gateReasons: [String] = []
        let screenScale = Double(min(w,h))/min(Double(w)*window.width,Double(h)*window.height)
        let confirmedLarge = max(evidence.confirmedSevereLowerBound ?? 0,
            evidence.reliable ? evidence.interval?.lowerBound ?? 0 : 0)*screenScale > 0.10
        if !confirmedLarge && now() > geometryExpiry { gateReasons.append(verifiedAt.isFinite ? "global-geometry-expired" : "geometry-never-certified") }
        if !confirmedLarge && now() > photoExpiry { gateReasons.append(photometry == nil ? "photometry-never-certified" : "photometry-expired") }
        if let delta = pair.ptsDelta {
            // Current paired images themselves are checked below. Unknown
            // temporal flow is not a fabricated zero, nor a blanket 1ms veto.
            if abs(delta) > min(1.0/60,pair.frameInterval) { gateReasons.append("capture-skew-outside-pair-domain") }
        }
        let gain = photometry?.gain ?? SIMD3(repeating: 1)
        if measured.photometryVerified, (0..<3).contains(where: { abs(log(gain[$0]/measured.gain[$0])) > 0.08 }) {
            evidence.appearance = .mismatch; evidence.reason = "photometry-settling"
        }
        let nativeStarted = CACurrentMediaTime()
        stage("native-boundary-readback")
        let strips = PeripheralNativeSeam.read(center:center,outerImage:selected.outerImage,ratio:pair.ratio,matrix:selected.matrix,
            analysisWidth:w,analysisHeight:h,seams:seams,context:context)
        diagnosticNative = strips
        diagnosticState["nativeReadbackMS"] = (CACurrentMediaTime()-nativeStarted)*1000
        let photoStarted = CACurrentMediaTime()
        var edgeGains = PeripheralEdgeGains()
        diagnosticState["nativePhotometryMS"] = (CACurrentMediaTime()-photoStarted)*1000
        let verifyStarted = CACurrentMediaTime()
        stage("native-boundary-verification")
        let native = PeripheralNativeSeam.evaluate(strips,gains:edgeGains,segments:measured.segments,
            analysisWidth:w,analysisHeight:h,geometryVerified:currentGeometryVerified || now() <= geometryExpiry,
            severe:evidence.confirmedSevereLowerBound,tolerance:tolerance)
        edgeGains = native.gains; edgePhotometry = (edgeGains,pair.observedAt)
        diagnosticState["nativeVerificationMS"] = (CACurrentMediaTime()-verifyStarted)*1000
        evidence.visibleSeam = native.evidence
        if native.evidence.compatible && !evidence.reliable { evidence.reason = "native-visible-seam" }
        if !native.evidence.compatible { evidence.appearance = .mismatch }
        diagnosticState["nativeSeamTiles"] = native.diagnostics
        diagnosticState["geometryReacquisition"] = ["attempted":false,"lastSuccess":verifiedAt,
            "support":interior?.segments.filter { $0.status == .measured }.count ?? 0,
            "failureReason":currentGeometryVerified ? "none" : "insufficient-independent-distributed-correspondences",
            "nextRegistrationRetry":lastRegistrationAttempt+Self.registrationInterval]
        diagnosticState["photometryReacquisition"] = ["attempted":true,
            "lastSuccess":photometry?.measuredAt ?? -.infinity,
            "failureReason":photoMeasurement.photometryVerified ? "none" : "insufficient-unsaturated-physical-correspondences",
            "visiblePhotometryVerified":native.evidence.compatible]
        diagnosticState["edgeGains"] = (0..<4).map { [edgeGains[$0].x,edgeGains[$0].y,edgeGains[$0].z] }
        diagnosticState["visiblePhotometryModel"] = "original-camera-colors-no-display-correction"
        diagnosticState["edgeEncodedSlope"] = edgeGains.encodedSlope.map { [$0.x,$0.y,$0.z] }
        diagnosticState["edgeEncodedBias"] = edgeGains.encodedBias.map { [$0.x,$0.y,$0.z] }
        diagnosticState["edgeAffineModelSelected"] = (0..<4).map { edgeGains.affine($0) }
        // Native appearance certifies its own current pixels and applied gains;
        // it cannot extend the independent physical geometry/photo certificates.
        let pairedTimingValid = !gateReasons.contains("capture-skew-outside-pair-domain")
        if !pairedTimingValid { evidence.visibleSeam = nil }
        if !confirmedLarge && (!gateReasons.isEmpty && !native.evidence.compatible || !pairedTimingValid) {
            evidence = .unknown(gateReasons.joined(separator:","))
        }
        let oneCompleteEdge = (0..<4).contains { edge in
            let rows = native.diagnostics.filter { $0["edge"] as? Int == edge }
            return !rows.isEmpty && rows.allSatisfy { $0["passed"] as? Bool == true }
        }
        let expires = (pairedTimingValid && oneCompleteEdge) || evidence.visibleSeam?.compatible == true || confirmedLarge ? pair.observedAt+Self.measurementLifetime :
            min(pair.observedAt+Self.measurementLifetime,min(geometryExpiry,photoExpiry))
        let publicationExpired = now()-pair.observedAt >= Self.measurementLifetime
        diagnosticState["gateReasons"] = gateReasons
        diagnosticState["evidence"] = PeripheralRecordJSON.evidence(evidence)
        diagnosticState["reason"] = publicationExpired ? "expired-before-publication" : evidence.reason
        recorder.record(reference: referenceBytes,warped: selected.bytes,width: w,height: h,padding: halo,
            pair: pair,reason: publicationExpired ? "expired-before-publication" : evidence.reason,
            status: publicationExpired ? "expired" : evidence.status.rawValue,matrix: selected.matrix,
            comparisons: comparisons,coverage: evidence.coverage,segments: measured.segments,gain: gain,
            severeLowerBound: evidence.confirmedSevereLowerBound)
        guard now()-pair.observedAt < Self.measurementLifetime else { return reject("expired-before-publication") }
        PeripheralDiagnostics.trace("alignment status=\(evidence.status.rawValue) pair=\(pair.serial) ms=\((CACurrentMediaTime()-started)*1000) comparisons=\(comparisons) coverage=\(evidence.coverage) margin=\(selected.margin)")
        var value = PeripheralAlignmentResult(epoch: pair.epoch,receipt: pair.observedAt,
            photoAspectRatio: Double(center.extent.width/center.extent.height),
            photoToOuter: Self.samplingTransform(homography: selected.matrix,width: w,height: h,ratio: pair.ratio),
            residual: evidence.interval?.upperBound ?? .nan,gain: gain,seams: seams,
            expiresAt: evidence.permitsDisplay ? max(pair.observedAt,expires) : pair.observedAt+Self.measurementLifetime)
        value.evidence = evidence; value.pairID = pair.serial; value.geometryID = geometryID
        value.photometryID = photometry?.id ?? 0; value.completedAt = now()
        value.geometryExpiresAt = geometryExpiry; value.photometryExpiresAt = photoExpiry
        value.centerPTS = pair.centerMetadata?.pts; value.outerPTS = pair.outerMetadata?.pts
        value.motionDistance = pair.motionDistance; value.motionGeneration = pair.motionGeneration
        value.inputPair = pair; value.edgeGains = edgeGains; value.gateReasons = gateReasons; value.nativeSeam = native
        value.visiblePhotometryID = pair.serial
        value.refinement = nil
        value.directStitch = true
        value.tolerance = tolerance
        diagnosticState["published"] = true
        diagnosticState["result"] = PeripheralRecordJSON.alignment(value)
        return value
    }
}
