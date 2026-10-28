import Testing
import Foundation
@testable import Peripheral
@testable import Capture

struct PeripheralPolicyTests {
    typealias F = PeripheralFixtures
    @Test func continuousFreshEvidence_recoversAfterStablePeriod() {
        var policy = PeripheralGlassPolicy(); F.warm(&policy)
        #expect(!policy.latched)
        #expect(policy.opacity(at: 1) == 0)
    }
    @Test func unknownEvidence_doesNotRenewCertificateOrLatchEarly() {
        var policy = PeripheralGlassPolicy(); F.warm(&policy)
        let deadline = policy.certificateDeadline
        F.feed(&policy, .unknown("low-confidence-peak"), 1.083333, id: 13)
        #expect(!policy.latched)
        #expect(policy.certificateDeadline == deadline)
        #expect(policy.targetOpacity == 0)
    }
    @Test func freshEvidenceAfterUnknown_preservesTransparencyUntilDeadline() {
        var policy = PeripheralGlassPolicy(); F.warm(&policy)
        F.feed(&policy, .unknown("low-confidence-peak"), 1.083333, id: 13)
        F.feed(&policy, F.good(), 1.166667, id: 14)
        #expect(!policy.latched)
        policy.tick(at: 1.37, sourceAvailable: true, epoch: 1)
        #expect(policy.latched)
    }
    @Test func confirmedLargeDisplacement_latchesAndDarkensInPointThreeSeconds() {
        var policy = PeripheralGlassPolicy(); F.warm(&policy)
        F.feed(&policy, F.good(0.15), 1.083333, id: 13)
        #expect(policy.latched)
        #expect(policy.targetOpacity == 1)
        #expect(policy.opacity(at: 1.39) == 1)
    }
    @Test(arguments: [(0, true), (4, true), (5, false)])
    func drawPause_requiresNewContinuousRecovery(input: (Int, Bool)) {
        var policy = PeripheralGlassPolicy(); F.warm(&policy)
        F.feed(&policy, F.good(), 1.5, id: 13)
        if input.0 > 0 { for index in 1...input.0 { F.feed(&policy, F.good(), 1.5 + Double(index) / 12, id: 13 + UInt64(index)) } }
        #expect(policy.latched == input.1)
    }
    @Test(arguments: [(1.93, UInt64(19), 1.6), (1.94, UInt64(17), 1.94)])
    func staleOrOutOfOrderEvidence_cannotRenewDeadline(input: (Double, UInt64, Double)) {
        var policy = PeripheralGlassPolicy(); F.warm(&policy, from: 0.916667, id: 6)
        let deadline = policy.certificateDeadline
        F.feed(&policy, F.good(), input.0, id: input.1, observed: input.2)
        #expect(policy.certificateDeadline == deadline)
    }
    @Test func sourceLoss_forcesBlack() {
        var policy = PeripheralGlassPolicy(); F.warm(&policy)
        policy.tick(at: 1.05, sourceAvailable: false, epoch: 1)
        #expect(policy.forcedBlack)
        #expect(policy.latched)
    }
    @Test func oldEpochEvidence_cannotOpenNewSource() {
        var policy = PeripheralGlassPolicy(); F.warm(&policy)
        policy.tick(at: 2, sourceAvailable: true, epoch: 2)
        policy.update(evidence: F.good(), sampleID: 100, sampleEpoch: 1, observedAt: 2.01,
            expiresAt: 2.21, at: 2.01, sourceAvailable: true, currentEpoch: 2)
        #expect(policy.latched)
        #expect(policy.certificateDeadline == -.infinity)
    }
    @Test func sparseEvidence_doesNotCountAsContinuousRecovery() {
        var policy = PeripheralGlassPolicy()
        F.feed(&policy, F.good(), 0, id: 0); F.feed(&policy, F.good(), 0.5, id: 1)
        #expect(policy.latched)
    }
    @Test(arguments: 13...36)
    func periodicUncertainPeaks_keepFreshReliableCoverage(last: Int) {
        var policy = PeripheralGlassPolicy(); F.warm(&policy)
        for index in 13...last { F.feed(&policy, index % 4 == 0 ? .unknown("false-peak") : F.good(), Double(index) / 12, id: UInt64(index)) }
        #expect(!policy.latched)
    }
    @Test func crossThresholdInterval_doesNotClaimSmallOrLarge() {
        var policy = PeripheralGlassPolicy(); F.warm(&policy)
        var ambiguous = F.good(); ambiguous.interval = 0.02...0.15
        F.feed(&policy, ambiguous, 1.08, id: 13)
        #expect(!policy.latched)
        #expect(policy.certificateDeadline == 1.2)
    }
    @Test(arguments: [60.0, 30, 15])
    func supportedAnalysisCadence_recovers(fps: Double) {
        let interval = PeripheralAlignmentWorker.expectedMeasurementInterval(frameInterval: 1 / fps)
        var policy = PeripheralGlassPolicy()
        for index in 0...12 { F.feed(&policy, F.good(), Double(index) * interval, id: UInt64(index), interval: interval) }
        #expect(!policy.latched)
    }
    @Test(arguments: 1...120)
    func increasingError_neverReducesDarkness(step: Int) {
        #expect(PeripheralGlassPolicy.darkness(forError: Double(step) / 1000) >= PeripheralGlassPolicy.darkness(forError: Double(step - 1) / 1000))
    }
    @Test(arguments: [(0.05, 0.0), (0.075, 0.5), (0.10, 1.0)])
    func darkness_usesDeclaredFiveToTenPercentCurve(input: (Double, Double)) {
        #expect(abs(PeripheralGlassPolicy.darkness(forError: input.0) - input.1) < 0.00001)
    }
    @Test func smallCompleteAmbiguousSet_remainsReliable() {
        var evidence = F.good(); evidence.status = .ambiguous; evidence.interval = 0.01...0.035
        #expect(evidence.reliable)
    }
    static func visibleEvidence() -> PeripheralEvidence {
        var evidence = PeripheralEvidence.unknown("physical-displacement-unobservable")
        evidence.visibleSeam = .init(compatible: true, coverage: 1, maximumObservableError: nil,
            reason: "native-visible-seam", nativeSupportChecked: true)
        return evidence
    }
    @Test func visibleEvidence_doesNotInventPhysicalGeometry() {
        let evidence = Self.visibleEvidence()
        #expect(evidence.interval == nil)
        #expect(!evidence.reliable)
    }
    @Test(arguments: [(25, 1.0), (72, 0.0)])
    func qualityRecovery_isIndependentFromResourceReadiness(input: (Int, Double)) {
        var policy = PeripheralGlassPolicy(), readiness = PeripheralReadiness()
        for frame in 0...input.0 {
            let time = Double(frame) / 60
            if frame % 5 == 0 { F.feed(&policy, Self.visibleEvidence(), time, id: UInt64(frame / 5 + 1)) }
            else { policy.tick(at: time, sourceAvailable: true, epoch: 1) }
            readiness.update(ready: frame >= 30, at: time)
        }
        #expect(!policy.latched)
        #expect(readiness.opacity(at: Double(input.0) / 60) == input.1)
        if input.0 == 72 { #expect(policy.opacity(at: 1.2) == 0) }
    }
    @Test func unknownObservation_cannotExtendVisibleCertificate() {
        var policy = PeripheralGlassPolicy()
        for index in 0...14 { F.feed(&policy, Self.visibleEvidence(), Double(index) / 12, id: UInt64(index)) }
        let deadline = policy.certificateDeadline
        F.feed(&policy, .unknown("no-new-visible-proof"), 1.25, id: 20)
        #expect(policy.certificateDeadline == deadline)
        policy.tick(at: 1.5, sourceAvailable: true, epoch: 1)
        #expect(policy.latched)
    }
    @Test func severeGeometry_overridesVisibleAppearance() {
        var policy = PeripheralGlassPolicy(); F.warm(&policy)
        var evidence = Self.visibleEvidence(); evidence.confirmedSevereLowerBound = 0.125
        F.feed(&policy, evidence, 1.05, id: 13)
        #expect(policy.latched)
    }
    @Test func independentPanes_keepValidUpperPaneClear() {
        var panes = PeripheralRegionalGlassPolicy()
        for frame in 0...72 {
            let time = Double(frame) / 60
            panes.tick(at: time, sourceAvailable: true, epoch: 1)
            if frame % 5 == 0 {
                panes.update([Self.visibleEvidence(), .unknown("lower-seam-occluded"), .unknown("no-pane"), .unknown("no-pane")],
                    sampleID: UInt64(frame / 5 + 1), epoch: 1, observedAt: time, expiresAt: time + 0.2, at: time,
                    sourceAvailable: true, expectedInterval: 1 / 12)
            }
            panes.prepared([frame > 0, false, false, false], at: time)
        }
        #expect(panes.opacities(at: 1.2)[0] == 0)
        #expect(panes.opacities(at: 1.2)[1] == 1)
        panes.prepared([false, false, false, false], at: 1.21)
        #expect(panes.opacities(at: 1.21)[0] == 1)
    }
}

struct SessionRecoveryTests {
    @Test(arguments: [15.0, 30, 60], [15.0, 30, 60])
    func durationChange_keepsValidInterval(oldFPS: Double, newFPS: Double) {
        var minimum = 1 / oldFPS, maximum = minimum
        let target = 1 / newFPS
        if CameraSessionRecovery.raisesMaximumFirst(target: target, currentMaximum: maximum) {
            maximum = target; #expect(minimum <= maximum); minimum = target
        } else {
            minimum = target; #expect(minimum <= maximum); maximum = target
        }
        #expect(minimum == target)
        #expect(maximum == target)
    }
    @Test func recoveryBudget_boundsAutomaticRebuildsAndRejectsBackwardsTime() {
        var budget = CameraSessionRecovery.Budget()
        let admission = [budget.admit(at: 0), budget.admit(at: 1), budget.admit(at: 2), budget.admit(at: -1), budget.admit(at: 31)]
        #expect(admission == [true, true, false, false, true])
    }
    @Test func mediaServicesReset_finishesPendingCapture() {
        #expect(CameraSessionRecovery.action(for: .mediaServicesReset, currentGeneration: true, cancelled: false, capturing: true, multiCam: true) == .finishCapture)
    }
    @Test(arguments: [(false, false), (true, true)])
    func staleOrCancelledSession_doesNotRestart(input: (Bool, Bool)) {
        #expect(CameraSessionRecovery.action(for: .interruptionEnded, currentGeneration: input.0, cancelled: input.1, capturing: false, multiCam: true) == .ignore)
    }
    @Test func seriousPressure_preservesCentralCapture() {
        #expect(CameraSessionRecovery.action(for: .seriousPressure, currentGeneration: true, cancelled: false, capturing: false, multiCam: true) == .rebuildCenterOnly)
    }
}
