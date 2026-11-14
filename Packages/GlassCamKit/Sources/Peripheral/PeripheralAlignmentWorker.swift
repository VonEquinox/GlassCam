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
    public static let matchingTolerance = 0.1
    private let clock: () -> Double
    public convenience init() { self.init(clock: CACurrentMediaTime) }
    init(clock: @escaping () -> Double) { self.clock = clock }
    static let measurementInterval = 1.0/12.0
    static let registrationInterval = 0.4
    static let measurementLifetime = 0.20
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
    private var registration: Registration?
    private var photometry: Photometry?
    private var analysisEpoch: UInt64?
    private var analysisDimensions = SIMD2<Int>(0,0)
    private var analysisSeams: PeripheralSeams = .all
    private var nextGeometryID: UInt64 = 0
    private let signposter = OSSignposter(subsystem: "dev.glasscam.prototype",category: "PeripheralAnalysis")
    let context = CIContext(options: [.cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    public func latest() -> PeripheralAlignmentResult? { lock.lock(); defer { lock.unlock() }; return result }
    var isAnalyzing: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    @discardableResult
    public func request(_ pair: PeripheralFrameSource.Pair, seams: PeripheralSeams = .all,
                 window: CGRect = CGRect(x: 0,y: 0,width: 1,height: 1)) -> Bool {
        lock.lock()
        guard !busy, pair.receipt-lastRequest >= Self.measurementInterval else { lock.unlock(); return false }
        busy = true; lastRequest = pair.receipt; lock.unlock()
        queue.async { [self,pair] in
            let value = autoreleasepool { analyze(pair,seams: seams,window: window,now: clock) }
            lock.lock()
            // Includes diagnostic enqueue/callback scheduling in the deadline.
            if let value, value.isFresh(for: pair.epoch,at: clock()) { result = value }
            busy = false; lock.unlock()
        }
        return true
    }
    package func analyze(_ pair: PeripheralFrameSource.Pair, seams: PeripheralSeams = .all,
                 window: CGRect = CGRect(x: 0,y: 0,width: 1,height: 1),
                 now: () -> Double = CACurrentMediaTime,
                 acquisitionCandidate: simd_float3x3? = nil,
                 tolerance requestedTolerance: Double = PeripheralAlignmentWorker.matchingTolerance) -> PeripheralAlignmentResult? {
        let started = CACurrentMediaTime()
        let tolerance = requestedTolerance.isFinite && requestedTolerance > 0 ? requestedTolerance : Self.matchingTolerance
        let interval = signposter.beginInterval("Analyze")
        defer { signposter.endInterval("Analyze",interval) }
        func reject(_ reason: String) -> PeripheralAlignmentResult? {
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
            registration = nil; photometry = nil; epipolarVerification = nil
            analysisEpoch = pair.epoch; analysisDimensions = SIMD2(w,h); analysisSeams = seams
        }
        let bounds = CGRect(x: 0,y: 0,width: w,height: h), width = CGFloat(w), height = CGFloat(h)
        let ratio = CGFloat(pair.ratio), tx = width*(1-ratio)/2, ty = height*(1-ratio)/2
        let reference = center.transformed(by: CGAffineTransform(scaleX: width/center.extent.width,y: height/center.extent.height)).cropped(to: bounds)
        let readback = signposter.beginInterval("CIReadback")
        let referenceBytes = bitmap(reference,bounds: bounds,width: w,height: h)
        signposter.endInterval("CIReadback",readback)
        let halo = max(8,Int(Double(min(w,h))*0.16))+2
        let searchBounds = bounds.insetBy(dx: -CGFloat(halo),dy: -CGFloat(halo))
        // The displayed seam is a fixed field-of-view crop. Measure exactly
        // that crop: fitting a homography/flow first would hide its real error.
        let candidateMatrix = matrix_identity_float3x3
        let candidateRefreshed = registration == nil
        guard now()-pair.observedAt < Self.measurementLifetime else {
            return reject("no-renderable-candidate")
        }
        let transform = Self.samplingTransform(homography: candidateMatrix,width: w,height: h,ratio: pair.ratio)
        let candidateFloating = outer.transformed(by:CGAffineTransform(scaleX:width*ratio/outer.extent.width,y:height*ratio/outer.extent.height))
            .transformed(by:CGAffineTransform(translationX:tx,y:ty))
        guard let margin = PeripheralProjection.margin(transform,window: window,
            width: CVPixelBufferGetWidth(pair.outer),height: CVPixelBufferGetHeight(pair.outer)),
            margin >= (candidateRefreshed ? 4 : 2),
            let warped = Self.warp(candidateFloating,by: candidateMatrix) else {
            return reject("no-renderable-candidate")
        }
        let bytes = bitmap(warped,bounds: searchBounds,width: w+2*halo,height: h+2*halo)
        // F is enabled only after CURRENT image correspondences independently
        // validate its output coordinate convention; no assumed horizontal line.
        let empiricalF = Self.analysisFundamental(pair,homography: candidateMatrix,width: w,height: h)
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
            fundamental: empiricalF,epipolarCertified: certifiedEpipolar,comparisonBudget: 120_000_000,deadline: pair.observedAt+Self.measurementLifetime,clock: now)
        signposter.endInterval("SeamMatching",matchingInterval)
        guard let measured = measurement else {
            return reject("no-renderable-candidate")
        }
        if measured.epipolarVerified, !certifiedEpipolar,
           let identity = pair.calibration?.identity, let kc = pair.centerMetadata?.intrinsic, let ko = pair.outerMetadata?.intrinsic {
            epipolarVerification = .init(identity:identity,measuredAt:pair.observedAt,center:kc,outer:ko)
        }
        let comparisons = measured.comparisons
        let selected: (matrix: simd_float3x3, refreshed: Bool, measurement: SeamMeasurement, margin: Float, refinement: PeripheralDenseRefinement?, outerImage: CIImage) =
            (candidateMatrix, candidateRefreshed, measured, margin, nil, outer)
        // Direct display has no fitted H or RGB model to certify. Repeating a
        // full search on nine interior patches delayed seam publication while
        // contributing no measurement used by the actual shade estimator.
        let interior:SeamMeasurement?=nil
        let currentGeometryVerified = measured.geometryVerified || interior?.geometryVerified == true
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
        let strips = PeripheralNativeSeam.read(center:center,outerImage:selected.outerImage,ratio:pair.ratio,matrix:selected.matrix,
            analysisWidth:w,analysisHeight:h,seams:seams,context:context)
        var edgeGains = PeripheralEdgeGains()
        let native = PeripheralNativeSeam.evaluate(strips,gains:edgeGains,segments:measured.segments,
            analysisWidth:w,analysisHeight:h,geometryVerified:currentGeometryVerified || now() <= geometryExpiry,
            severe:evidence.confirmedSevereLowerBound,tolerance:tolerance)
        edgeGains = native.gains
        evidence.visibleSeam = native.evidence
        if native.evidence.compatible && !evidence.reliable { evidence.reason = "native-visible-seam" }
        if !native.evidence.compatible { evidence.appearance = .mismatch }
        // Native appearance certifies its own current pixels and applied gains;
        // it cannot extend the independent physical geometry/photo certificates.
        let pairedTimingValid = !gateReasons.contains("capture-skew-outside-pair-domain")
        if !pairedTimingValid { evidence.visibleSeam = nil }
        if !confirmedLarge && (!gateReasons.isEmpty && !native.evidence.compatible || !pairedTimingValid) {
            evidence = .unknown(gateReasons.joined(separator:","))
        }
        let oneCompleteEdge = (0..<4).contains { edge in
            let rows = native.tiles.filter { $0.edge == edge }
            return !rows.isEmpty && rows.allSatisfy(\.passed)
        }
        let expires = (pairedTimingValid && oneCompleteEdge) || evidence.visibleSeam?.compatible == true || confirmedLarge ? pair.observedAt+Self.measurementLifetime :
            min(pair.observedAt+Self.measurementLifetime,min(geometryExpiry,photoExpiry))
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
        value.inputPair = pair; value.edgeGains = edgeGains; value.gateReasons = gateReasons; value.nativeSeam = native
        value.visiblePhotometryID = pair.serial
        value.refinement = nil
        value.directStitch = true
        value.tolerance = tolerance
        return value
    }
}
