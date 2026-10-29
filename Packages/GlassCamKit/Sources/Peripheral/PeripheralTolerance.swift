import Foundation

/// User calibration multiplier for current-image matching. It never changes
/// frame identity, native pixel coverage or the lifetime of camera pixels.
public final class PeripheralTolerance {
    public static let shared = PeripheralTolerance()
    public static let defaultValue = 1.0
    public static let range = 0.25...4.0
    public static let step = 0.05
    public static let key = "peripheralMatchingTolerance"
    package static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return (max(range.lowerBound,min(range.upperBound,value))/step).rounded()*step
    }
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var stored: Double
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = Self.normalized(defaults.object(forKey: Self.key) as? Double ?? Self.defaultValue)
    }
    public var value: Double {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set {
            lock.lock(); defer { lock.unlock() }
            stored = Self.normalized(newValue)
            defaults.set(stored,forKey:Self.key)
        }
    }
}
