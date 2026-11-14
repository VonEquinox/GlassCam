import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

struct CaptureReview: View {
    let capture: SavedCapture
    let onBack: () -> Void
    @State private var fullPreview: PreviewRaster?
    @State private var sharing = false
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let scale = min(5, max(1, zoom * pinch))
                let maxX = proxy.size.width * (scale - 1) / 2
                let maxY = proxy.size.height * (scale - 1) / 2
                PrecisionPreview(source: fullPreview ?? capture.preview)
                    .scaleEffect(scale)
                    .offset(x: min(maxX, max(-maxX, pan.width + drag.width)),
                            y: min(maxY, max(-maxY, pan.height + drag.height)))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .gesture(MagnificationGesture().updating($pinch) { value, state, _ in state = value }
                        .onEnded { value in zoom = min(5, max(1, zoom * value)); if zoom == 1 { pan = .zero } })
                    .simultaneousGesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            pan = CGSize(width: min(maxX, max(-maxX, pan.width + value.translation.width)),
                                         height: min(maxY, max(-maxY, pan.height + value.translation.height)))
                        })
                    .onTapGesture(count: 2) { zoom = zoom == 1 ? 2 : 1; pan = .zero }
                    .accessibilityLabel("HDR photo")
                    .accessibilityAction(named: "Zoom in") { zoom = min(5, zoom + 1) }
                    .accessibilityAction(named: "Reset zoom") { zoom = 1; pan = .zero }
            }.clipped().background(Color.black)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                if let description = capture.resolutionDescription {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("review.resolution")
                }
                if let white = capture.snapshot.recipe.whiteBalanceDescription {
                    Text(white).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("review.whiteBalance")
                }
                }.padding(8).frame(maxWidth: .infinity).background(Color.black)
            }
            .navigationTitle("\(capture.width) × \(capture.height) · HDR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Camera", action: onBack) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share HDR photo")
                }
            }
        }.preferredColorScheme(.dark).tint(.white)
            .task(id: capture.id) {
                fullPreview = nil
                fullPreview = try? await capture.loadFullPreview()
            }
            .sheet(isPresented: $sharing) { ShareSheet(file: capture.file) }
    }
}
