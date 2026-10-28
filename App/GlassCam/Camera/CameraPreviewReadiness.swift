import ImagingCore
import Capture
import F5
import Peripheral
import AVFoundation
import Combine
import OSLog
import UIKit
import ImageIO

/// The session queue waits for an actual frame; lifecycle and timeout checks stay
/// separate so tests can advance either event without a wall-clock delay.
enum CameraPreviewReadiness {
    static func wait(next: () -> DispatchTimeoutResult, expired: () -> Bool, validate: () throws -> Void) throws {
        while next() != .success {
            try validate()
            if expired() {
                throw CameraFailure("A physical camera preview did not deliver its negotiated frame within 5 seconds. Select the lens again to retry.")
            }
        }
        try validate()
    }
}
