import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

struct PhotoFrameGuide: View {
    static func grid(size: CGSize) -> Path {
                    Path { path in
                        for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                            path.move(to: CGPoint(x: size.width * fraction, y: 0))
                            path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                            path.move(to: CGPoint(x: 0, y: size.height * fraction))
                            path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                        }
                    }
    }
    let gridVisible: Bool
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if gridVisible {
                    Self.grid(size: proxy.size).stroke(.white.opacity(0.24), lineWidth: 0.5)
                }
            }
        }
    }
}
