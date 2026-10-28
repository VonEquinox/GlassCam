import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

struct CameraOrientationObserver: UIViewRepresentable {
    let changed: (UIInterfaceOrientation) -> Void
    func makeUIView(context: Context) -> CameraOrientationView {
        let view = CameraOrientationView()
        view.changed = changed
        return view
    }
    func updateUIView(_ uiView: CameraOrientationView, context: Context) {
        uiView.changed = changed
        uiView.setNeedsLayout()
    }
}
