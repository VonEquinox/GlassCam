import ImagingCore
import Foundation

/// Pure recovery admission and frame-duration ordering shared with the capture
/// backend. No observer can restart a disposed generation or a pending shutter.
public enum CameraSessionRecovery {
    public enum Event { case interruptionEnded, mediaServicesReset, seriousPressure }
    public enum Action: Equatable { case ignore, finishCapture, rebuild, rebuildCenterOnly }
    public static func action(for event: Event,currentGeneration: Bool,cancelled: Bool,capturing: Bool,multiCam: Bool) -> Action {
        guard currentGeneration, !cancelled else { return .ignore }
        if capturing { return event == .mediaServicesReset ? .finishCapture : .ignore }
        if event == .seriousPressure { return multiCam ? .rebuildCenterOnly : .ignore }
        return .rebuild
    }
    /// A smaller positive duration is a higher frame rate. Raise max first only
    /// when the new duration would otherwise exceed the current upper bound.
    public static func raisesMaximumFirst(target: Double,currentMaximum: Double) -> Bool {
        target.isFinite && currentMaximum.isFinite && target > currentMaximum
    }
    public struct Budget {
        public init() {}
        private var admitted: [Double] = []
        private var lastTime = -Double.infinity
        public var attempts: Int { admitted.count }
        public mutating func admit(at time: Double) -> Bool {
            guard time.isFinite, time >= lastTime else { return false }
            lastTime = time
            admitted.removeAll { time-$0 >= 30 }
            guard admitted.count < 2 else { return false }
            admitted.append(time); return true
        }
    }
}
