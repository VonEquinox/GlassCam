import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

struct CompactCameraPanel {
    private(set) var offered = false
    mutating func offer(hasGeometry: Bool, style: CameraChromeLayout.Style, settingsPresented: Bool,
                        reviewing: Bool, capturing: Bool) -> Bool {
        guard hasGeometry else { return false }
        guard style == .separate else { offered = false; return false }
        guard !offered, !settingsPresented, !reviewing, !capturing else { return false }
        offered = true
        return true
    }
}

enum CameraControlsAvailability {
    static func canReview(hasPhoto: Bool, working: Bool) -> Bool { hasPhoto && !working }
}
