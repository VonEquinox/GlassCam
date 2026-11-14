import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

/// Optical bevel cut along the outer edge of the central photograph aperture.
/// Every stroke is placed outside `rect` (`dx: -0.5, dy: -0.5` and outward),
/// preserving zero overlay coverage inside the central photograph pixels.
struct PhotoFrameBoundary: View {
    let rect: CGRect
    var isCapturing = false
    @State private var pulse = false

    static func apertureCutout(window: CGRect, photo: CGRect) -> Path {
        Path { path in
            path.addRect(window)
            if photo.width > 0, photo.height > 0 {
                path.addRect(photo)
            }
        }
    }

    static func bevelRect(for photo: CGRect) -> CGRect {
        guard photo.width > 0, photo.height > 0 else { return .zero }
        return photo.insetBy(dx: -0.5, dy: -0.5)
    }

    static func cornerTicks(for photo: CGRect, length: CGFloat = 9) -> Path {
        guard photo.width > 0, photo.height > 0 else { return Path() }
        let rim = photo.insetBy(dx: -0.75, dy: -0.75)
        let arm = min(length, min(rim.width, rim.height) * 0.25)
        return Path { path in
            for (x, dx) in [(rim.minX, CGFloat(1)), (rim.maxX, CGFloat(-1))] {
                for (y, dy) in [(rim.minY, CGFloat(1)), (rim.maxY, CGFloat(-1))] {
                    path.move(to: CGPoint(x: x, y: y + dy * arm))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + dx * arm, y: y))
                }
            }
        }
    }

    var body: some View {
        let rim = Self.bevelRect(for: rect)
        if !rim.isEmpty {
            ZStack {
                Path { $0.addRect(rim) }
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(isCapturing ? 0.72 : 0.40),
                                .white.opacity(isCapturing ? 0.36 : 0.16),
                                .white.opacity(isCapturing ? 0.48 : 0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isCapturing ? 1.0 : 0.65
                    )
                if isCapturing {
                    Path { $0.addRect(rect.insetBy(dx: -1.5, dy: -1.5)) }
                        .stroke(
                            Color(red: 0.86, green: 0.94, blue: 1.0).opacity(pulse ? 0.52 : 0.18),
                            lineWidth: 1.2
                        )
                }
                Self.cornerTicks(for: rect)
                    .stroke(
                        .white.opacity(isCapturing ? 0.85 : 0.48),
                        style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .miter)
                    )
            }
            .animation(.easeInOut(duration: 0.22), value: isCapturing)
            .onChange(of: isCapturing, initial: true) { _, capturing in
                if capturing {
                    withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                } else {
                    pulse = false
                }
            }
        }
    }
}
