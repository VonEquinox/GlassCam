import SwiftUI
import UIKit

struct CameraFocusGesture: UIViewRepresentable {
    let enabled: Bool
    let focus: (CGPoint, Bool) -> Void
    let reset: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(focus: focus, reset: reset) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.reset(_:)))
        doubleTap.numberOfTapsRequired = 2
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.5
        tap.require(toFail: doubleTap)
        tap.require(toFail: hold)
        view.addGestureRecognizer(tap); view.addGestureRecognizer(doubleTap); view.addGestureRecognizer(hold)
        view.isUserInteractionEnabled = enabled
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        view.isUserInteractionEnabled = enabled
        context.coordinator.focus = focus; context.coordinator.resetAction = reset
    }

    final class Coordinator: NSObject {
        var focus: (CGPoint, Bool) -> Void
        var resetAction: () -> Void
        init(focus: @escaping (CGPoint, Bool) -> Void, reset: @escaping () -> Void) {
            self.focus = focus; resetAction = reset
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            focus(gesture.location(in: gesture.view), false)
        }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            focus(gesture.location(in: gesture.view), true)
        }
        @objc func reset(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { resetAction() }
        }
    }
}

struct CameraFocusIndicator: View {
    @ObservedObject var camera: CameraController
    let source: CGRect

    var body: some View {
        if let target = camera.metering.point {
            let point = CameraMeteringGeometry.viewPoint(target, source: source, orientation: camera.previewOrientation)
            ZStack {
                Circle().strokeBorder(.white.opacity(0.85), lineWidth: 0.8)
                Image(systemName: "plus").font(.system(size: 12, weight: .ultraLight))
            }
            .frame(width: 52, height: 52)
            .scaleEffect(camera.meteringAdjusting ? 1.15 : 1)
            .opacity(camera.meteringAdjusting ? 0.65 : 1)
            .animation(.easeOut(duration: 0.2), value: camera.meteringAdjusting)
            .position(point)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Button {
                    camera.setMetering(camera.metering.resumingContinuous())
                } label: {
                    Text(camera.metering.locked ? "AE/AF LOCK" : "AE/AF")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(8)
                }
                .accessibilityLabel("Reset focus and metering")
                .accessibilityIdentifier("camera.focus.reset")
                Image(systemName: "sun.max").font(.system(size: 13, weight: .light))
                    .accessibilityHidden(true)
                Slider(value: Binding(get: { Double(camera.metering.exposureBias) }, set: {
                    var updated = camera.metering; updated.exposureBias = Float($0)
                    camera.setMetering(updated)
                }), in: Double(camera.exposureBiasRange.lowerBound)...Double(camera.exposureBiasRange.upperBound), step: 0.1)
                .frame(width: 100)
                .rotationEffect(.degrees(-90))
                .frame(width: 32, height: 100)
                .accessibilityLabel("Camera exposure compensation")
                .accessibilityValue(Text("\(Double(camera.metering.exposureBias), specifier: "%+.1f") EV"))
                .accessibilityIdentifier("camera.exposure")
                .disabled(camera.exposureBiasRange.lowerBound == camera.exposureBiasRange.upperBound)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .position(x: min(source.maxX - 42, max(source.minX + 42, point.x + 60)),
                      y: min(source.maxY - 90, max(source.minY + 90, point.y)))
            .disabled(!camera.canReserveCapture)
        }
    }
}

@MainActor
final class CameraHaptics {
    private let press = UIImpactFeedbackGenerator(style: .light)
    private let complete = UIImpactFeedbackGenerator(style: .rigid)
    private let warning = UINotificationFeedbackGenerator()

    func shutterPressed() {
        press.impactOccurred()
        complete.prepare(); warning.prepare()
    }
    func exposureCompleted() { complete.impactOccurred(); press.prepare() }
    func failed() { warning.notificationOccurred(.warning); press.prepare() }
}
