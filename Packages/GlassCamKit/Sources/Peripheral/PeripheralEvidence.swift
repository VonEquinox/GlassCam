import Foundation

/// Measurements describe what was observed, never what an appearance test hopes
/// the displacement might be. Intervals are empirical feasible ranges, not
/// calibrated probabilities. Their model/search completeness is explicit.
public struct PeripheralEvidence {
    static let displayErrorThreshold = 0.10
    package enum Status: String { case measured, ambiguous, unobservable, occluded, budgetExceeded, unavailable }
    package enum Appearance: String { case compatible, mismatch, unknown }
    package var status: Status
    package var interval: ClosedRange<Double>?
    package var appearance: Appearance = .unknown
    public var reason: String
    package var searchComplete = false
    package var coverage: Double = 0
    /// A spatially corroborated large observable displacement can prove a
    /// local failure even when another part of the boundary is unobservable.
    package var confirmedSevereLowerBound: Double?
    /// A separate current-image contract. This never supplies a physical 2D
    /// interval for flat or directionally unobservable regions.
    package var visibleSeam: PeripheralVisibleEvidence?
    public var reliable: Bool {
        (status == .measured || status == .ambiguous) && searchComplete && coverage >= 0.999 && interval != nil
    }
    package var permitsDisplay: Bool {
        if (confirmedSevereLowerBound ?? 0) > Self.displayErrorThreshold { return false }
        if reliable {
            guard let interval, interval.lowerBound >= 0, interval.upperBound.isFinite,
                  interval.upperBound <= Self.displayErrorThreshold else { return false }
        }
        let visible = visibleSeam.map {
            $0.compatible && $0.nativeSupportChecked && $0.coverage >= 0.999 &&
                ($0.maximumObservableError.map { $0.isFinite && $0 >= 0 && $0 <= Self.displayErrorThreshold } ?? true)
        } ?? false
        return (reliable && appearance != .mismatch) || visible
    }
    public static func unknown(_ reason: String) -> Self {
        .init(status: .unobservable, interval: nil, reason: reason)
    }
}

package struct PeripheralVisibleEvidence {
    package let compatible: Bool
    package let coverage: Double
    package let maximumObservableError: Double?
    package let reason: String
    package let nativeSupportChecked: Bool
}
