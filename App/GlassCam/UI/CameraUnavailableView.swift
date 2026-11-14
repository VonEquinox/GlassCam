import AVFoundation
import SwiftUI
import UIKit

struct CameraUnavailableView: View {
    @ObservedObject var camera: CameraController
    let offersControls: Bool
    let onRetry: () -> Void
    let onControls: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "camera.fill").font(.largeTitle)
                Text(camera.status).font(.callout).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !camera.isConfiguring {
                    Button("Retry camera", action: onRetry).padding(10)
                    if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
                if offersControls {
                    Button("Open camera controls", action: onControls).frame(minHeight: 44)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
    }
}
