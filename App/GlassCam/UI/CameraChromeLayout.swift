import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

/// Controls use only the intersection of natural spare regions and the safe area.
/// When that space cannot hold real touch targets, a separate plain panel takes
/// over. Crucially, this helper never returns or changes a photograph rectangle.
struct CameraChromeLayout {
    enum Style: Equatable { case portrait, landscape, compactHorizontal, compactVertical, separate }
    let style: Style
    let first: CGRect
    let second: CGRect

    init(framing: CameraFraming, safeArea: EdgeInsets, needsAccessiblePanel: Bool) {
        let window = framing.window
        let safe = CGRect(x: safeArea.leading, y: safeArea.top,
                          width: max(0, window.width - safeArea.leading - safeArea.trailing),
                          height: max(0, window.height - safeArea.top - safeArea.bottom))
        func usable(_ rect: CGRect) -> CGRect {
            let intersection = rect.intersection(safe)
            guard !intersection.isNull, intersection.width > 16, intersection.height > 16 else { return .zero }
            return intersection.insetBy(dx: 8, dy: 4)
        }
        if framing.usesVerticalControls {
            first = usable(CGRect(x: 0, y: 0, width: framing.photo.minX, height: window.height))
            second = usable(CGRect(x: framing.photo.maxX, y: 0,
                                   width: window.width - framing.photo.maxX, height: window.height))
            if !needsAccessiblePanel, min(first.width, second.width) >= 100,
               min(first.height, second.height) >= 408 {
                style = .landscape
            } else if !needsAccessiblePanel, first.width >= 68, second.width >= 64,
                      min(first.height, second.height) >= 264 {
                style = .compactVertical
            } else { style = .separate }
        } else {
            first = usable(CGRect(x: 0, y: 0, width: window.width, height: framing.photo.minY))
            second = usable(CGRect(x: 0, y: framing.photo.maxY, width: window.width,
                                   height: window.height - framing.photo.maxY))
            if !needsAccessiblePanel, first.height >= 94, second.height >= 140,
               min(first.width, second.width) >= 276 {
                style = .portrait
            } else if !needsAccessiblePanel, first.height >= 44, second.height >= 56,
                      min(first.width, second.width) >= 312 {
                style = .compactHorizontal
            } else { style = .separate }
        }
    }
}
