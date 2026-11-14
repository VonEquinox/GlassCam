import ImagingCore
import Capture
import SwiftUI
import UIKit

struct CaptureReview: View {
    @Environment(\.colorResources) private var resources
    let capture: SavedCapture
    let onBack: () -> Void
    @State private var fullPreview: PreviewRaster?
    @State private var loadFailed = false
    @State private var loadAttempt = UUID()
    @State private var sharing = false
    @State private var details = false
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let scale = min(5, max(1, zoom * pinch))
            let limits = CaptureReviewGeometry.panLimits(viewport: proxy.size, image: imageSize, scale: scale)
            let pull = scale == 1 && drag.height > abs(drag.width) ? drag.height : 0
            let offset = CaptureReviewGeometry.clamp(CGSize(width: pan.width + drag.width,
                                                            height: pan.height + drag.height), to: limits)
            ZStack {
                PrecisionPreview(source: capture.preview)
                if let fullPreview {
                    PrecisionPreview(source: fullPreview).transition(.opacity)
                }
            }
            .scaleEffect(scale * (1 - min(0.25, pull / max(1, proxy.size.height) * 0.35)))
            .offset(x: offset.width, y: offset.height + pull)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.18), value: drag == .zero)
            .gesture(MagnificationGesture().updating($pinch) { value, state, _ in state = value }
                .onEnded { value in
                    zoom = min(5, max(1, zoom * value))
                    pan = CaptureReviewGeometry.clamp(pan, to: CaptureReviewGeometry.panLimits(
                        viewport: proxy.size, image: imageSize, scale: zoom))
                })
            .simultaneousGesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    if CaptureReviewGeometry.shouldDismiss(scale: scale, translation: value.translation,
                                                            predicted: value.predictedEndTranslation) {
                        onBack()
                    } else {
                        pan = CaptureReviewGeometry.clamp(CGSize(width: pan.width + value.translation.width,
                                                                 height: pan.height + value.translation.height), to: limits)
                    }
                })
            .onTapGesture(count: 2) {
                withAnimation(.snappy(duration: 0.2)) { zoom = zoom == 1 ? 2 : 1; pan = .zero }
            }
            .accessibilityLabel("HDR photo")
            .accessibilityIdentifier("review.photo")
            .accessibilityAction(named: "Zoom in") { zoom = min(5, zoom + 1) }
            .accessibilityAction(named: "Reset zoom") { zoom = 1; pan = .zero }
            .accessibilityAction(named: "Back to camera", onBack)
        }
        .clipped()
        .safeAreaInset(edge: .top) { header.padding(.horizontal, 18).padding(.top, 8) }
        .safeAreaInset(edge: .bottom) { metadata.padding(.horizontal, 18).padding(.bottom, 12) }
        .background {
            Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.68)).ignoresSafeArea()
        }
        .preferredColorScheme(.dark).tint(.white)
        .task(id: loadAttempt) {
            loadFailed = false
            do {
                let decoded = try await capture.loadFullPreview()
                try Task.checkCancellation()
                withAnimation(.easeInOut(duration: 0.15)) { fullPreview = decoded }
            } catch is CancellationError {
            } catch { loadFailed = true }
        }
        .sheet(isPresented: $sharing) { ShareSheet(file: capture.file) }
    }

    private var imageSize: CGSize {
        CGSize(width: capture.preview.width, height: capture.preview.height)
    }
    private var header: some View {
        HStack {
            Button(action: onBack) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel("Back to camera").accessibilityIdentifier("review.close")
            Spacer()
            Button { sharing = true } label: {
                Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
            }.accessibilityLabel("Share HDR photo")
        }
        .font(.system(size: 17, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: Capsule())
    }
    private var metadata: some View {
        VStack(spacing: 8) {
            if loadFailed {
                Button("Load full photo again") { loadAttempt = UUID() }
                    .font(.caption).accessibilityIdentifier("review.retryPreview")
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { details.toggle() }
            } label: {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(capture.snapshot.recipe.mode.title)
                        Text("·").foregroundStyle(.secondary)
                        Text(styleTitle).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(LocalizedStringKey(capture.snapshot.quality.title))
                        Text("· \(capture.snapshot.quality.bayerFrameCount ?? 1) RAW")
                    }
                    Text(exposureLine).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.white.opacity(0.72))
                    if details {
                        Text("\(capture.width) × \(capture.height) · 10-bit HDR")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let description = capture.resolutionDescription {
                            Text(description).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("review.resolution")
                        }
                        if let white = capture.snapshot.recipe.whiteBalanceDescription {
                            Text(white).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("review.whiteBalance")
                        }
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(14)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("review.metadata")
            .accessibilityHint("Show photo details")
        }
    }
    private var styleTitle: String {
        let recipe = capture.snapshot.recipe
        switch recipe.mode {
        case .hncs: return recipe.hncs.presetTitle
        case .ffcs: return FFCSEngine.simulations(resources: resources, for: recipe.ffcs.cameraFamily)
            .first { $0.id == recipe.simulationIndex }?.name ?? "FFCS"
        case .lumix: return recipe.lumix.title
        }
    }
    private var exposureLine: String {
        let info = capture.cameraInfo
        var fields: [String] = []
        if let focal = info.equivalentFocalLength ?? capture.snapshot.output.framing?.exifEquivalentFocalLength {
            fields.append(String(format: "%.0fmm", focal))
        }
        if let aperture = info.aperture { fields.append(String(format: "f/%.2f", aperture)) }
        if let duration = info.exposureTime {
            fields.append(duration < 1 ? String(format: "1/%.0fs", 1 / duration) : String(format: "%.2fs", duration))
        }
        if let iso = info.iso { fields.append(String(format: "ISO %.0f", iso)) }
        fields.append(String(format: "%.0fMP HDR", Double(capture.width) * Double(capture.height) / 1_000_000))
        return fields.joined(separator: "  ")
    }
}
