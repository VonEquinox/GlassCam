import Testing
@testable import Capture

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
