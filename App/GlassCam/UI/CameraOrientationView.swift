import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

final class CameraOrientationView: UIView {
    var changed: ((UIInterfaceOrientation) -> Void)?
    private var previous: UIInterfaceOrientation?
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let orientation = window?.windowScene?.interfaceOrientation,
              orientation != .unknown, orientation != previous else { return }
        previous = orientation
        // Do not publish camera changes during SwiftUI's layout pass.
        DispatchQueue.main.async { [weak self] in self?.changed?(orientation) }
    }
}
