import Combine
import CoreMotion
import UIKit

/// A stable gravity direction, independent of the interface rotation lock.
/// Flat placement, diagonal holds and acceleration spikes keep the last value.
struct CameraGravityOrientation {
    private(set) var orientation: UIInterfaceOrientation?
    private var candidate: UIInterfaceOrientation?
    private var candidateCount = 0

    mutating func update(x: Double, y: Double, z: Double) -> UIInterfaceOrientation? {
        let magnitudeSquared = x * x + y * y + z * z
        guard magnitudeSquared.isFinite, (0.64...1.44).contains(magnitudeSquared),
              abs(z) < 0.85, max(abs(x), abs(y)) >= 0.70,
              abs(abs(x) - abs(y)) >= 0.20 else {
            candidate = nil; candidateCount = 0
            return nil
        }
        let next: UIInterfaceOrientation
        if abs(x) > abs(y) {
            next = x < 0 ? .landscapeRight : .landscapeLeft
        } else {
            next = y < 0 ? .portrait : .portraitUpsideDown
        }
        guard next != orientation else {
            candidate = nil; candidateCount = 0
            return nil
        }
        if candidate == next { candidateCount += 1 }
        else { candidate = next; candidateCount = 1 }
        guard candidateCount >= 3 else { return nil }
        orientation = next; candidate = nil; candidateCount = 0
        return next
    }
}

@MainActor
final class CameraMotion: ObservableObject {
    @Published private(set) var orientation: UIInterfaceOrientation?
    private let manager = CMMotionManager()
    private var detector = CameraGravityOrientation()

    func setActive(_ active: Bool) {
        guard active else {
            manager.stopAccelerometerUpdates()
            return
        }
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        manager.accelerometerUpdateInterval = 1.0 / 20.0
        manager.startAccelerometerUpdates(to: .main) { [weak self] sample, _ in
            guard let self, let a = sample?.acceleration,
                  let changed = self.detector.update(x: a.x, y: a.y, z: a.z) else { return }
            self.orientation = changed
        }
    }

    deinit { manager.stopAccelerometerUpdates() }
}
