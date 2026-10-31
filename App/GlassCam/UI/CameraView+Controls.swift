import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

extension CameraView {
    @ViewBuilder
    func controls(framing: CameraFraming, chrome: CameraChromeLayout) -> some View {
        switch chrome.style {
        case .portrait:
            VStack(spacing: 6) {
                HStack {
                    resolutionButton
                    Spacer(minLength: 8)
                    wordmark
                    Spacer(minLength: 8)
                    gridButton
                }
                captureMetadata
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            VStack(spacing: 10) {
                HStack {
                    Spacer(minLength: 0)
                    zoomButtons
                    lensIndicator
                    Spacer(minLength: 0)
                }
                HStack {
                    thumbnailButton
                    Spacer(minLength: 12)
                    shutter(diameter: 82)
                    Spacer(minLength: 12)
                    settingsButton
                }
            }
            .modifier(CameraChromeRegion(rect: chrome.second))
        case .landscape:
            VStack(spacing: 8) {
                wordmark.font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                resolutionButton
                qualityButton
                compactStyleButton
                Text(photoAspectLabel).font(.caption.weight(.semibold))
                lensIndicator
                Text("RAW").font(.caption.weight(.semibold)).tracking(2)
                gridButton
                Spacer(minLength: 0)
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            VStack(spacing: 8) {
                statusButton
                verticalZoomButtons
                thumbnailButton
                Spacer(minLength: 0)
                shutter(diameter: 82)
                Spacer(minLength: 0)
                settingsButton
            }
            .modifier(CameraChromeRegion(rect: chrome.second))
        case .compactHorizontal:
            HStack(spacing: 8) {
                resolutionButton
                qualityButton
                compactStyleButton
                Spacer(minLength: 0)
                statusButton
                Spacer(minLength: 0)
                gridButton
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            HStack {
                thumbnailButton
                lensIndicator
                Spacer(minLength: 8)
                shutter(diameter: 56)
                Spacer(minLength: 8)
                settingsButton
            }
            .modifier(CameraChromeRegion(rect: chrome.second))
        case .compactVertical:
            VStack(spacing: 8) {
                resolutionButton
                qualityButton
                compactStyleButton
                lensIndicator
                Spacer(minLength: 0)
                gridButton
                thumbnailButton
            }
            .modifier(CameraChromeRegion(rect: chrome.first))
            VStack(spacing: 8) {
                statusButton
                Spacer(minLength: 0)
                shutter(diameter: 56)
                Spacer(minLength: 0)
                settingsButton
            }
            .modifier(CameraChromeRegion(rect: chrome.second))
        case .separate:
            EmptyView()
        }
    }

    private var wordmark: some View {
        Text("GLASSCAM").font(.system(size: 14, weight: .semibold))
            .tracking(3.5).lineLimit(1).minimumScaleFactor(0.65)
            .accessibilityLabel("GlassCam")
    }

    private var gridButton: some View {
        Button { settings.gridVisible.toggle() } label: {
            Image(systemName: "grid").font(.system(size: 21, weight: .light))
                .foregroundStyle(gridVisible ? .white : .white.opacity(0.55))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(Text(LocalizedStringKey(gridVisible ? "Hide composition grid" : "Show composition grid")))
        .accessibilityValue(Text(LocalizedStringKey(gridVisible ? "On" : "Off")))
        .accessibilityIdentifier("camera.grid")
    }

    private var captureMetadata: some View {
        HStack(spacing: 12) {
            styleButton
            qualityButton
            Spacer(minLength: 4)
            statusButton
        }.font(.system(size: 12, weight: .medium)).lineLimit(1)
    }

    var styleButton: some View {
        Button { activePanel = .looks } label: {
            HStack(spacing: 7) {
                Image(systemName: "camera.filters")
                Text(selectedStyleTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }.modifier(CameraPill())
        }.disabled(workflow.isWorking || camera.isCapturing)
            .accessibilityLabel("Choose photo style").accessibilityIdentifier("camera.style")
            .accessibilityValue(selectedStyleTitle)
    }

    private var selectedStyleTitle: String {
        switch colorMode {
        case .hncs: return hncs.presetTitle
        case .ffcs: return FFCSEngine.simulations(resources: resources, for: settings.ffcs.cameraFamily)
            .first { $0.id == settings.simulationIndex }?.name ?? "FFCS"
        case .lumix: return settings.lumix.title
        }
    }

    private var compactStyleButton: some View {
        Button { activePanel = .looks } label: {
            Image(systemName: "camera.filters").font(.system(size: 20))
                .frame(width: 44, height: 44)
        }.disabled(workflow.isWorking || camera.isCapturing)
            .accessibilityLabel("Choose photo style").accessibilityValue(selectedStyleTitle)
            .accessibilityIdentifier("camera.style")
    }

    var resolutionButton: some View {
        Button {} label: {
            Text(settings.captureQuality == .balanced ? "2× sampling" : "12 MP")
                .font(.system(size: 11, weight: .semibold))
                .modifier(CameraPill())
        }.disabled(true)
            .accessibilityLabel("Photo output")
            .accessibilityValue(settings.captureQuality == .balanced ? "2× sampling" : "12 MP")
            .accessibilityIdentifier("camera.resolution")
    }

    var qualityButton: some View {
        Menu {
            ForEach(CaptureQuality.allCases, id: \.self) { quality in
                Button { settings.captureQuality = quality } label: {
                    if settings.captureQuality == quality {
                        Label(quality == .balanced ? "Balanced · 4 RAW" : quality.title, systemImage: "checkmark")
                    } else {
                        Text(quality == .balanced ? "Balanced · 4 RAW" : quality.title)
                    }
                }.accessibilityIdentifier("camera.quality.\(quality.rawValue)")
            }
        } label: {
            Text(settings.captureQuality.title)
                .font(.system(size: 11, weight: .semibold))
                .modifier(CameraPill())
        }
        .disabled(!workflow.canCapture || camera.isCapturing)
        .accessibilityLabel("Capture priority")
        .accessibilityValue(settings.captureQuality.title)
        .accessibilityIdentifier("camera.quality")
        .accessibilityHint("Choose single RAW Speed or four-frame Balanced")
    }

    private var statusButton: some View {
        Button { activePanel = .status } label: {
            HStack(spacing: 6) {
                if workflow.isWorking || camera.isPreviewFrozen { ProgressView().controlSize(.mini) }
                else { Circle().fill(.white.opacity(0.65)).frame(width: 4, height: 4) }
                Text(LocalizedStringKey(summaryStatus))
                    .font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(minWidth: 44, minHeight: 44).foregroundStyle(.white.opacity(0.78))
        }.accessibilityLabel(Text(LocalizedStringKey(summaryStatus)))
            .accessibilityValue(Text(LocalizedStringKey(workflow.status)))
            .accessibilityIdentifier("capture.status.summary")
    }

    private var summaryStatus: String {
        if camera.isCapturing || camera.isPreviewFrozen { return "Capturing RAW" }
        switch workflow.phase {
        case .authorizing: return "Preparing photo"
        case .capturing: return "Capturing RAW"
        case .retaining: return "Retaining photo"
        case .processing: return "Processing photo"
        case .saving: return "Saving photo"
        case .restoring: return "Restoring photo"
        case .paused: return "Photo paused"
        case .failed, .saveOutcomeUnknown: return "Photo needs attention"
        case .idle: break
        }
        if workflow.status.hasPrefix("Saved HDR") { return "Saved to Photos" }
        if experimentalLiveColor && liveProxyStatus.isShowingEffect && camera.isReady { return "Approx. preview · HDR" }
        return estimatedOutputLabel
    }

    private var photoAspectLabel: String {
        guard let size = camera.geometry?.sensorPhotoDimensions,
              size.width > 0, size.height > 0 else { return "—" }
        let long = Int(max(size.width, size.height))
        let short = Int(min(size.width, size.height))
        var a = long, b = short
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        return "\(long / a):\(short / a)"
    }

    private var lensIndicator: some View {
        Button { activePanel = .zoom } label: {
            Text(CameraZoomRange.label(camera.requestedZoom)).font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!workflow.canCapture || camera.isCapturing || settings.captureQuality.usesBayer)
        .accessibilityLabel("Focal length controls")
        .accessibilityValue(CameraZoomRange.label(camera.appliedZoom))
        .accessibilityIdentifier("camera.zoom")
    }

    var estimatedOutputLabel: String {
        if settings.captureQuality == .balanced { return "Balanced · 4 RAW · 2× output grid" }
        if settings.captureQuality == .speed { return "Speed · Single RAW · 12 MP" }
        return "HDR"
    }

    var zoomButtons: some View {
        HStack(spacing: 8) { zoomStops }
    }

    private var verticalZoomButtons: some View {
        VStack(spacing: 4) { zoomStops }
    }

    private var zoomStops: some View {
        ForEach(camera.zoomRange.stops) { stop in
            Button { camera.setZoom(stop.factor) } label: {
                Text(CameraZoomRange.label(stop.factor))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .background(abs(camera.appliedZoom - stop.factor) < 0.04 ? Color.white.opacity(0.24) : Color.white.opacity(0.08))
                    .clipShape(Capsule())
            }
            .onLongPressGesture(minimumDuration: 0.4) { activePanel = .zoom }
            .accessibilityLabel(Text(LocalizedStringKey(stop.title)))
            .accessibilityValue(CameraZoomRange.label(stop.factor))
            .accessibilityIdentifier("camera.zoom.\(stop.title)")
        }
        .disabled(!workflow.canCapture || camera.isCapturing || camera.isConfiguring || settings.captureQuality.usesBayer)
    }

    var zoomRuler: some View {
        VStack(spacing: 20) {
            Text(CameraZoomRange.label(camera.requestedZoom)).font(.title2.monospacedDigit())
                .accessibilityIdentifier("camera.zoom.readout")
            zoomButtons
            if camera.zoomRange.upperBound > camera.zoomRange.lowerBound {
                Slider(value: Binding(get: { log2(camera.requestedZoom) },
                                      set: { camera.setZoom(pow(2, $0)) }),
                       in: log2(camera.zoomRange.lowerBound)...log2(camera.zoomRange.upperBound))
                    .disabled(!workflow.canCapture || settings.captureQuality.usesBayer)
                    .accessibilityLabel("Continuous focal length")
                    .accessibilityValue(CameraZoomRange.label(camera.appliedZoom))
                    .accessibilityIdentifier("camera.zoom.ruler")
            }
            Text(LocalizedStringKey(camera.currentFraming.lensName ?? "Automatic lens selection"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }

    var thumbnailButton: some View {
        Button {
            activePanel = nil
            if let capture = workflow.latest {
                destination = .photo(capture)
            }
        } label: {
            Group {
                if let thumbnail {
                    PrecisionPreview(source: thumbnail)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 21, weight: .light))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.5), lineWidth: 0.7))
        }
        .disabled(!CameraControlsAvailability.canReview(hasPhoto: workflow.latest != nil, working: workflow.isWorking))
        .accessibilityLabel("View latest saved photo")
        .accessibilityIdentifier("camera.thumbnail")
    }

    var settingsButton: some View {
        Button { activePanel = nil; destination = .settings } label: {
            Image(systemName: "gearshape").font(.system(size: 21, weight: .light))
                .frame(width: 44, height: 44)
        }
        .disabled(camera.isCapturing || camera.isConfiguring || workflow.phase == .authorizing)
        .accessibilityLabel("Camera settings and photo effects")
        .accessibilityIdentifier("camera.settings")
    }
}
