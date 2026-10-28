import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

final class CameraPreviewHost: UIView {
    var preview: AVSampleBufferDisplayLayer?
    func install(_ preview: AVSampleBufferDisplayLayer, gravity: AVLayerVideoGravity) {
        if self.preview !== preview {
            self.preview?.removeFromSuperlayer()
            self.preview = preview
            layer.addSublayer(preview)
        }
        backgroundColor = .black
        clipsToBounds = true
        preview.videoGravity = gravity
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview?.frame = bounds
        CATransaction.commit()
    }
}
