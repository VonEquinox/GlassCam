import Foundation

/// Pure recovery admission and frame-duration ordering shared with the capture
/// backend. No observer can restart a disposed generation or a pending shutter.
enum CameraSessionRecovery {
    enum Event { case interruptionEnded, mediaServicesReset, seriousPressure }
    enum Action: Equatable { case ignore, finishCapture, rebuild, rebuildCenterOnly }
    static func action(for event: Event,currentGeneration: Bool,cancelled: Bool,capturing: Bool,multiCam: Bool) -> Action {
        guard currentGeneration, !cancelled else { return .ignore }
        if capturing { return event == .mediaServicesReset ? .finishCapture : .ignore }
        if event == .seriousPressure { return multiCam ? .rebuildCenterOnly : .ignore }
        return .rebuild
    }
    /// A smaller positive duration is a higher frame rate. Raise max first only
    /// when the new duration would otherwise exceed the current upper bound.
    static func raisesMaximumFirst(target: Double,currentMaximum: Double) -> Bool {
        target.isFinite && currentMaximum.isFinite && target > currentMaximum
    }
    struct Budget {
        private var admitted: [Double] = []
        private var lastTime = -Double.infinity
        var attempts: Int { admitted.count }
        mutating func admit(at time: Double) -> Bool {
            guard time.isFinite, time >= lastTime else { return false }
            lastTime = time
            admitted.removeAll { time-$0 >= 30 }
            guard admitted.count < 2 else { return false }
            admitted.append(time); return true
        }
    }
}
