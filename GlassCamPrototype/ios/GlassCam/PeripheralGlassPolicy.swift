import Foundation

/// Monotonic host time, never frame PTS. Unknown quality is not zero error.
/// This value type has no camera/UI dependencies and is exercised with a clock.
struct PeripheralGlassPolicy {
    static let darkeningThreshold = 0.10
    static let recoveryThreshold = 0.08
    static let darkeningDuration = 0.30
    static let recoveryDuration = 0.40
    static let recoveryStability = 0.40

    private(set) var targetOpacity = 1.0
    private var startOpacity = 1.0
    private var startedAt = 0.0
    private var duration = 0.0
    private var stableSince: Double?
    private var lastTime = -Double.infinity

    func opacity(at time: Double) -> Double {
        guard time.isFinite, duration > 0 else { return targetOpacity }
        let t = min(1, max(0, (time - startedAt) / duration))
        let eased = t * t * (3 - 2 * t)
        return startOpacity + (targetOpacity - startOpacity) * eased
    }

    mutating func update(error: Double?, available: Bool, at time: Double, measuredAt: Double? = nil) {
        guard time.isFinite else { return }
        let now = max(lastTime, time)
        let sampleTime = measuredAt ?? now
        lastTime = now
        guard available, let error, error.isFinite, error >= 0,
              sampleTime.isFinite, sampleTime <= now else {
            stableSince = nil
            transition(to: 1, at: now, duration: Self.darkeningDuration)
            return
        }
        if error > Self.darkeningThreshold {
            stableSince = nil
            transition(to: 1, at: now, duration: Self.darkeningDuration)
        } else if error < Self.recoveryThreshold {
            // Animation draws may reuse a measurement. Only newly sampled
            // alignment history advances the continuous recovery window.
            if stableSince == nil { stableSince = sampleTime }
            if sampleTime - (stableSince ?? sampleTime) >= Self.recoveryStability {
                transition(to: 0, at: now, duration: Self.recoveryDuration)
            }
        } else {
            stableSince = nil
        }
    }

    private mutating func transition(to value: Double, at time: Double, duration: Double) {
        guard targetOpacity != value else { return }
        startOpacity = opacity(at: time)
        startedAt = time
        targetOpacity = value
        self.duration = duration
    }
}
