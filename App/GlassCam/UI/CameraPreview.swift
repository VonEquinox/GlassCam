import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

struct CameraPreview: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let gravity: AVLayerVideoGravity
    func makeUIView(context: Context) -> CameraPreviewHost { CameraPreviewHost() }
    func updateUIView(_ uiView: CameraPreviewHost, context: Context) {
        uiView.install(layer, gravity: gravity)
    }
    static func dismantleUIView(_ uiView: CameraPreviewHost, coordinator: ()) {
        uiView.preview?.removeFromSuperlayer()
        uiView.preview = nil
    }
}
