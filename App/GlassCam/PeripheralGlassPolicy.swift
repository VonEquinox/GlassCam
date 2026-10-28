import Foundation

/// User calibration multiplier for current-image matching. It never changes
/// frame identity, native pixel coverage or the lifetime of camera pixels.
final class PeripheralTolerance {
    static let shared = PeripheralTolerance()
    static let defaultValue = 1.0
    static let range = 0.25...4.0
    static let step = 0.05
    static let key = "peripheralMatchingTolerance"
    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return (max(range.lowerBound,min(range.upperBound,value))/step).rounded()*step
    }
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var stored: Double
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = Self.normalized(defaults.object(forKey: Self.key) as? Double ?? Self.defaultValue)
    }
    var value: Double {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set {
            lock.lock(); defer { lock.unlock() }
            stored = Self.normalized(newValue)
            defaults.set(stored,forKey:Self.key)
        }
    }
}

/// Measurements describe what was observed, never what an appearance test hopes
/// the displacement might be. Intervals are empirical feasible ranges, not
/// calibrated probabilities. Their model/search completeness is explicit.
struct PeripheralEvidence {
    enum Status: String { case measured, ambiguous, unobservable, occluded, budgetExceeded, unavailable }
    enum Appearance: String { case compatible, mismatch, unknown }
    var status: Status
    var interval: ClosedRange<Double>?
    var appearance: Appearance = .unknown
    var reason: String
    var searchComplete = false
    var coverage: Double = 0
    /// A spatially corroborated large observable displacement can prove a
    /// local failure even when another part of the boundary is unobservable.
    var confirmedSevereLowerBound: Double?
    /// A separate current-image contract. This never supplies a physical 2D
    /// interval for flat or directionally unobservable regions.
    var visibleSeam: PeripheralVisibleEvidence?
    var reliable: Bool {
        (status == .measured || status == .ambiguous) && searchComplete && coverage >= 0.999 && interval != nil
    }
    var permitsDisplay: Bool {
        if (confirmedSevereLowerBound ?? 0) > PeripheralGlassPolicy.darkeningThreshold { return false }
        if reliable {
            guard let interval, interval.lowerBound >= 0, interval.upperBound.isFinite,
                  interval.upperBound <= PeripheralGlassPolicy.darkeningThreshold else { return false }
        }
        let visible = visibleSeam.map {
            $0.compatible && $0.nativeSupportChecked && $0.coverage >= 0.999 &&
                ($0.maximumObservableError.map { $0.isFinite && $0 >= 0 && $0 <= PeripheralGlassPolicy.darkeningThreshold } ?? true)
        } ?? false
        return (reliable && appearance != .mismatch) || visible
    }
    static func unknown(_ reason: String) -> Self {
        .init(status: .unobservable, interval: nil, reason: reason)
    }
}

struct PeripheralVisibleEvidence {
    let compatible: Bool
    let coverage: Double
    let maximumObservableError: Double?
    let reason: String
    let nativeSupportChecked: Bool
}

/// Resource readiness has no authority to reset quality recovery. A missing
/// resource masks immediately; a newly completed legal resource fades in.
struct PeripheralReadiness {
    private var ready = false
    private var lastTime: Double?
    private var unavailableSince: Double?
    private var readyDuration = 0.0
    mutating func update(ready: Bool, at time: Double) {
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true else { return }
        if let lastTime, self.ready { readyDuration += time-lastTime }
        if let unavailableSince, time-unavailableSince > PeripheralGlassPolicy.measurementLifetime {
            readyDuration = 0
        }
        if ready { unavailableSince = nil }
        else if self.ready || unavailableSince == nil { unavailableSince = time }
        lastTime = time
        self.ready = ready
    }
    func opacity(at time: Double) -> Double {
        // Missing pixels mask immediately. A short upload/expiry gap does not
        // erase time already spent showing independently checked resources.
        guard ready else { return 1 }
        let duration = readyDuration+max(0,time-(lastTime ?? time))
        return max(0,1-duration/PeripheralGlassPolicy.recoveryDuration)
    }
}

/// A bad lower seam must not revoke an independently current upper seam.
/// Every pane retains the same expiry, hysteresis and GPU-readiness rules.
struct PeripheralRegionalGlassPolicy {
    private var quality = [PeripheralGlassPolicy](repeating:PeripheralGlassPolicy(),count:4)
    private var resources = [PeripheralReadiness](repeating:PeripheralReadiness(),count:4)
    mutating func tick(at time:Double,sourceAvailable:Bool,epoch:UInt64) {
        for side in 0..<4 { quality[side].tick(at:time,sourceAvailable:sourceAvailable,epoch:epoch) }
    }
    mutating func update(_ evidence:[PeripheralEvidence],sampleID:UInt64,epoch:UInt64,observedAt:Double,
                         expiresAt:Double,at time:Double,sourceAvailable:Bool,expectedInterval:Double) {
        guard evidence.count == 4 else { return }
        for side in 0..<4 {
            quality[side].update(evidence:evidence[side],sampleID:sampleID,sampleEpoch:epoch,observedAt:observedAt,
                expiresAt:expiresAt,at:time,sourceAvailable:sourceAvailable,currentEpoch:epoch,expectedInterval:expectedInterval)
        }
    }
    mutating func prepared(_ ready:[Bool],at time:Double) {
        guard ready.count == 4 else { return }
        for side in 0..<4 { resources[side].update(ready:ready[side],at:time) }
    }
    func qualityOpacities(at time:Double)->[Double] { quality.map { $0.opacity(at:time) } }
    func readinessOpacities(at time:Double)->[Double] { resources.map { $0.opacity(at:time) } }
    func opacities(at time:Double)->[Double] { (0..<4).map { max(quality[$0].opacity(at:time),resources[$0].opacity(at:time)) } }
    var reasons:[String] { quality.map { $0.reason } }
    var deadlines:[Double] { quality.map { $0.certificateDeadline } }
    var targets:[Double] { quality.map { $0.targetOpacity } }
}

/// Host-clock policy. Unknown observations never renew the last good certificate.
/// Source identity is authoritative; an old asynchronous result cannot change it.
struct PeripheralGlassPolicy {
    static let fadeStart = 0.05
    static let darkeningThreshold = 0.10
    static let recoveryThreshold = 0.08
    static let darkeningDuration = 0.30
    static let recoveryDuration = 0.40
    static let recoveryStability = 0.40
    static let measurementLifetime = 0.20

    private(set) var targetOpacity = 1.0
    private var recoveryLatched = true
    private var proofExpired = true
    var latched: Bool { recoveryLatched || proofExpired }
    private(set) var forcedBlack = true
    private(set) var reason = "startup"
    private(set) var filteredError: Double?
    private(set) var certificateDeadline = -Double.infinity
    private var startOpacity = 1.0
    private var startedAt = 0.0
    private var stableSince: Double?
    private var previousRecoverySample: Double?
    private var recoverySamples = 0
    private var lastTime = -Double.infinity
    private var lastMeasurementTime = -Double.infinity
    private var lastID: UInt64?
    private var epoch: UInt64?
    private var lastCertifiedObservation: Double?

    static func darkness(forError error: Double) -> Double {
        let t = min(1, max(0, (error - fadeStart) / (darkeningThreshold - fadeStart)))
        return t * t * (3 - 2 * t)
    }
    func opacity(at time: Double) -> Double {
        guard time.isFinite else { return targetOpacity }
        // Expiry still masks on the absolute observation deadline. It does not
        // erase the separate history of good observations arriving in order.
        if forcedBlack || time > certificateDeadline { return 1 }
        let rate = targetOpacity >= startOpacity ? 1 / Self.darkeningDuration : 1 / Self.recoveryDuration
        let travel = max(0, time - startedAt) * rate
        return targetOpacity >= startOpacity ? min(targetOpacity, startOpacity + travel)
                                             : max(targetOpacity, startOpacity - travel)
    }
    mutating func tick(at time: Double, sourceAvailable: Bool, epoch currentEpoch: UInt64) {
        guard time.isFinite else { return }
        let now = max(lastTime,time)
        if epoch != currentEpoch {
            self = Self(); epoch = currentEpoch; startedAt = now
        }
        lastTime = now
        guard sourceAvailable else {
            forcedBlack = true; certificateDeadline = -.infinity
            filteredError = nil; latch(at: now, reason: "source-unavailable"); return
        }
        forcedBlack = false
        proofExpired = now > certificateDeadline
        if proofExpired { reason = certificateDeadline == -.infinity ? "never-certified" : "evidence-expired" }
    }
    mutating func update(evidence: PeripheralEvidence?, sampleID: UInt64, sampleEpoch: UInt64,
                         observedAt: Double, expiresAt: Double, at time: Double,
                         sourceAvailable: Bool, currentEpoch: UInt64,
                         expectedInterval: Double = 1.0/12) {
        // Check expiry BEFORE accepting a new sample, including after draw pauses.
        guard time.isFinite, time >= lastTime else { return }
        tick(at: time, sourceAvailable: sourceAvailable, epoch: currentEpoch)
        guard sourceAvailable, sampleEpoch == currentEpoch, time.isFinite,
              observedAt.isFinite, expiresAt.isFinite, observedAt <= time,
              time-observedAt <= Self.measurementLifetime, time <= expiresAt,
              observedAt > lastMeasurementTime, lastID.map({ sampleID > $0 }) ?? true else { return }
        let previousTime = lastMeasurementTime
        lastID = sampleID; lastMeasurementTime = observedAt
        if let lower = evidence?.confirmedSevereLowerBound, lower.isFinite, lower > Self.darkeningThreshold {
            latch(at: time, reason: "confirmed-local-displacement"); return
        }
        let visual = evidence?.visibleSeam
        let visualGood = visual?.compatible == true && visual?.nativeSupportChecked == true && (visual?.coverage ?? 0) >= 0.999
        let physical = evidence?.reliable == true ? evidence?.interval : nil
        // Visible consistency is its own decision basis; an unknown physical
        // displacement stays unknown in the evidence and the recordings.
        let interval = physical ?? (visualGood ? (0...(visual?.maximumObservableError ?? 0)) : nil)
        guard let evidence, let interval,
              interval.lowerBound.isFinite, interval.upperBound.isFinite,
              interval.lowerBound >= 0 else {
            reason = evidence?.reason ?? "measurement-unknown"
            resetRecovery(); return
        }
        if interval.lowerBound > Self.darkeningThreshold {
            latch(at: time, reason: "confirmed-large-displacement"); return
        }
        guard interval.upperBound <= Self.darkeningThreshold,
              (visualGood || evidence.appearance != .mismatch) else {
            reason = evidence.appearance == .mismatch ? "appearance-mismatch" : "ambiguous-threshold"
            resetRecovery(); return
        }
        // Continuity belongs to capture observations, not to the remaining
        // time after CPU/GPU processing. Slow delivery can briefly exhaust a
        // lease even while successive checked captures remain continuous.
        let continuous = lastCertifiedObservation.map { observedAt-$0 <= Self.measurementLifetime } ?? false
        if !continuous {
            recoveryLatched = true; resetRecovery(); filteredError = nil
            retarget(1,at:time)
        }
        lastCertifiedObservation = observedAt
        certificateDeadline = min(expiresAt,observedAt+Self.measurementLifetime)
        proofExpired = time > certificateDeadline
        let error = interval.upperBound
        if let old = filteredError, previousTime.isFinite {
            let tau = error >= old ? 0.10 : 0.20
            filteredError = old+(error-old)*(1-exp(-(observedAt-previousTime)/tau))
        } else { filteredError = error }
        if recoveryLatched {
            guard error < Self.recoveryThreshold else { resetRecovery(); return }
            // Consecutive checked captures may span processing gaps, but
            // never more than the absolute observation lifetime.
            let maxGap = Self.measurementLifetime
            if previousRecoverySample == nil || observedAt-previousRecoverySample! > maxGap {
                stableSince = observedAt; recoverySamples = 0
            }
            previousRecoverySample = observedAt; recoverySamples += 1
            guard observedAt-(stableSince ?? observedAt) >= Self.recoveryStability,
                  recoverySamples >= 3 else { return }
            recoveryLatched = false; resetRecovery()
        }
        reason = visualGood && !evidence.reliable ? "visible-seam-compatible" : "reliable-bounded"
        retarget(Self.darkness(forError: error >= Self.darkeningThreshold ? error : filteredError ?? error), at: time)
    }
    /// Compatibility entry for independent scalar callers. Scalars here are
    /// explicitly asserted reliable by the caller; production uses evidence.
    mutating func update(error: Double?, available: Bool, at time: Double, measuredAt: Double? = nil) {
        let sample = measuredAt ?? time
        let value = error.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let evidence = value.map { PeripheralEvidence(status: .measured, interval: $0...$0,
            appearance: .compatible, reason: "scalar-caller", searchComplete: true, coverage: 1) }
        let id = sample.isFinite && sample >= 0 && sample < 1e9 ? UInt64((sample*1e6).rounded()) : 0
        update(evidence: evidence, sampleID: id, sampleEpoch: 0, observedAt: sample,
               expiresAt: sample+Self.measurementLifetime, at: time,
               sourceAvailable: available, currentEpoch: 0)
    }
    private mutating func resetRecovery() {
        stableSince = nil; previousRecoverySample = nil; recoverySamples = 0
    }
    private mutating func latch(at time: Double, reason: String) {
        recoveryLatched = true; lastCertifiedObservation = nil
        resetRecovery(); self.reason = reason
        retarget(1, at: time)
    }
    private mutating func retarget(_ value: Double, at time: Double) {
        guard targetOpacity != value else { return }
        startOpacity = opacity(at: time); startedAt = time; targetOpacity = value
    }
}
