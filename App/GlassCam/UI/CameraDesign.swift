import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI

/// App-owned optical glass surfaces and etched viewfinder typography.
/// The viewfinder periphery itself is a single-sheet Liquid Glass cutout
/// (`PeripheralLiquidGlass`); resting peripheral labels read as laser-etched
/// lens engravings, condensing into illuminated glass only when active.
struct CameraCard<Content: View>: View {
    var title: LocalizedStringKey
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold, design: .rounded)).textCase(.uppercase)
                .tracking(1.5).foregroundStyle(.white.opacity(0.62))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.015)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.05)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
        }
    }
}

struct CameraSettingsBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.06, blue: 0.08).opacity(0.56),
                    Color(red: 0.02, green: 0.03, blue: 0.04).opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { geometry in
                RadialGradient(
                    colors: [Color(red: 0.14, green: 0.23, blue: 0.26).opacity(0.28), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: max(geometry.size.width, geometry.size.height) * 0.75
                )
            }
        }.ignoresSafeArea()
    }
}

/// Etched optical label on the peripheral glass: unboxed engraving at rest,
/// raised illuminated glass capsule when active.
struct EtchedGlassChip: ViewModifier {
    var active = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, active ? 13 : 8)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(active ? .white : .white.opacity(0.88))
            .background {
                if active {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.24), .white.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.55), .white.opacity(0.16)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.75
                            )
                        }
                } else {
                    Capsule()
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                        .padding(.vertical, 6)
                }
            }
    }
}

struct CameraPill: ViewModifier {
    var selected = false
    func body(content: Content) -> some View {
        content.modifier(EtchedGlassChip(active: selected))
    }
}

struct CameraPageHeader: View {
    let title: LocalizedStringKey
    var backIdentifier = "settings.back"
    var backLabel: LocalizedStringKey = "Back to camera"
    let back: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Button(action: back) {
                Image(systemName: "arrow.left").font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.20), lineWidth: 0.6))
            }.accessibilityLabel(Text(backLabel)).accessibilityIdentifier(backIdentifier)
            Text(title).font(.system(size: 26, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
        }.foregroundStyle(.white).padding(.horizontal, 22).padding(.vertical, 12)
    }
}

/// Optical lens shutter button: metallic rim, translucent refractive lens core,
/// condensing capture animation, and smooth orbital progress arc during grading.
struct OpticalLensShutterLabel: View {
    let diameter: CGFloat
    let isCapturing: Bool
    let isWorking: Bool
    let progress: Double
    @State private var orbitAngle: Double = -90

    private var clampedProgress: Double {
        guard progress.isFinite else { return 0.12 }
        return min(0.96, max(0.08, progress))
    }

    var body: some View {
        let coreScale: CGFloat = isCapturing ? 0.80 : (isWorking ? 0.88 : 1.0)
        ZStack {
            // Outer beveled bezel ring
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.92), .white.opacity(0.38), .white.opacity(0.76)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2.0
                )
            // Inner precision hair-ring
            Circle()
                .strokeBorder(.white.opacity(0.26), lineWidth: 0.6)
                .padding(4)

            // Orbital luminous progress arc (replaces system ProgressView spinner)
            if isCapturing || isWorking {
                let trimEnd = isCapturing ? 0.28 : clampedProgress
                Circle()
                    .trim(from: 0, to: trimEnd)
                    .stroke(
                        AngularGradient(
                            colors: [
                                .white.opacity(0.15),
                                Color(red: 0.84, green: 0.94, blue: 1.0),
                                .white
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(isCapturing ? orbitAngle : -90))
                    .padding(1)
                    .animation(.easeInOut(duration: 0.28), value: clampedProgress)
            }

            // Refractive translucent glass lens core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(isCapturing ? 0.58 : (isWorking ? 0.28 : 0.44)),
                            Color(red: 0.88, green: 0.94, blue: 1.0).opacity(isCapturing ? 0.34 : 0.18),
                            .white.opacity(isWorking ? 0.10 : 0.24)
                        ],
                        center: UnitPoint(x: 0.34, y: 0.28),
                        startRadius: diameter * 0.03,
                        endRadius: diameter * 0.44
                    )
                )
                .glassEffect(.regular.interactive(), in: Circle())
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.82), .white.opacity(0.14), .white.opacity(0.45)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
                }
                .padding(6.5)
                .scaleEffect(coreScale)
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: coreScale)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .onChange(of: isCapturing, initial: true) { _, capturing in
            if capturing {
                orbitAngle = -90
                withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                    orbitAngle = 270
                }
            } else {
                orbitAngle = -90
            }
        }
    }
}
