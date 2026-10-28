import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

struct PhotoFrameBoundary: View {
    let rect: CGRect
    var body: some View {
        Path { path in
            let r = rect.insetBy(dx: -1, dy: -1)
            let length: CGFloat = 18
            for (x, dx) in [(r.minX, CGFloat(1)), (r.maxX, CGFloat(-1))] {
                for (y, dy) in [(r.minY, CGFloat(1)), (r.maxY, CGFloat(-1))] {
                    path.move(to: CGPoint(x: x, y: y + dy * length))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + dx * length, y: y))
                }
            }
        }.stroke(.white.opacity(0.65), style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }
}
