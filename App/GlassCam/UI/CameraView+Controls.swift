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
            let dialActive = filterDialVisible && !workflow.isWorking && !camera.isCapturing
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    opticalSpecReadout
                    qualityButton
                    Spacer(minLength: 4)
                    statusButton
                    gridButton
                }
                Spacer(minLength: 0)
            }
            .modifier(CameraChromeRegion(rect: chrome.first))

            VStack(spacing: dialActive ? 8 : 10) {
                Spacer(minLength: 0)
                if dialActive {
                    OpticalFilterDial(settings: settings) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            filterDialVisible = false
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                } else {
                    styleDialToggle(useSheet: false)
                }
                HStack {
                    thumbnailButton
                    Spacer(minLength: 12)
                    shutter(diameter: dialActive ? min(74, max(56, chrome.second.height - 92)) : 80)
                    Spacer(minLength: 12)
                    settingsButton
                }
            }
            .modifier(CameraChromeRegion(rect: chrome.second))

        case .landscape:
            VStack(spacing: 8) {
                opticalSpecReadout
                qualityButton
                styleDialToggle(useSheet: true, compact: true)
                Text(photoAspectLabel)
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.62))
                Spacer(minLength: 0)
                gridButton
            }
            .modifier(CameraChromeRegion(rect: chrome.first))

            VStack(spacing: 8) {
                statusButton
                Spacer(minLength: 0)
                shutter(diameter: 78)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    thumbnailButton
                    settingsButton
                }
            }
            .modifier(CameraChromeRegion(rect: chrome.second))

        case .compactHorizontal:
            HStack(spacing: 8) {
                opticalSpecReadout
                qualityButton
                styleDialToggle(useSheet: true, compact: true)
                Spacer(minLength: 0)
                statusButton
                gridButton
            }
            .modifier(CameraChromeRegion(rect: chrome.first))

            HStack {
                thumbnailButton
                Spacer(minLength: 8)
                shutter(diameter: 56)
                Spacer(minLength: 8)
                settingsButton
            }
            .modifier(CameraChromeRegion(rect: chrome.second))

        case .compactVertical:
            VStack(spacing: 8) {
                opticalSpecReadout
                qualityButton
                styleDialToggle(useSheet: true, compact: true)
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

    /// Read-only optical engraving replacing the disabled 24 MP fake button and
    /// permanently disabled zoom strip.
    var opticalSpecReadout: some View {
        HStack(spacing: 4) {
            Text("1×")
            Text("·").foregroundStyle(.white.opacity(0.38))
            Text("24 MP")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        .tracking(0.6)
        .foregroundStyle(.white.opacity(0.76))
        .padding(.horizontal, 4)
        .frame(minHeight: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Main lens, photo output")
        .accessibilityValue("24 MP")
        .accessibilityIdentifier("camera.resolution")
    }

    var gridButton: some View {
        Button { settings.gridVisible.toggle() } label: {
            Image(systemName: "grid")
                .font(.system(size: 18, weight: gridVisible ? .medium : .light))
                .foregroundStyle(gridVisible ? .white : .white.opacity(0.55))
                .frame(width: 44, height: 44)
                .background {
                    if gridVisible {
                        Circle().fill(.white.opacity(0.14))
                            .overlay(Circle().strokeBorder(.white.opacity(0.32), lineWidth: 0.6))
                    }
                }
        }
        .accessibilityLabel(Text(LocalizedStringKey(gridVisible ? "Hide composition grid" : "Show composition grid")))
        .accessibilityValue(Text(LocalizedStringKey(gridVisible ? "On" : "Off")))
        .accessibilityIdentifier("camera.grid")
    }

    private var currentLookDescriptor: OpticalLookDescriptor {
        let items = OpticalLookDescriptor.items(
            mode: colorMode,
            resources: resources,
            family: settings.ffcs.cameraFamily
        )
        let id = OpticalLookDescriptor.currentID(settings: settings)
        return items.first { $0.id == id }
            ?? OpticalLookDescriptor(
                id: id,
                title: selectedStyleTitle,
                shortTitle: selectedStyleTitle,
                traitKey: "Natural",
                primaryColor: .white,
                secondaryColor: .gray,
                isMonochrome: false
            )
    }

    func styleDialToggle(useSheet: Bool, compact: Bool = false) -> some View {
        let active = useSheet ? (activePanel == .looks) : filterDialVisible
        let descriptor = currentLookDescriptor
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            if useSheet {
                activePanel = .looks
            } else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    filterDialVisible.toggle()
                }
            }
        } label: {
            if compact {
                HStack(spacing: 5) {
                    OpticalSwatchDot(look: descriptor, size: 10)
                    Image(systemName: "camera.filters").font(.system(size: 16, weight: .regular))
                }
                .modifier(EtchedGlassChip(active: active))
            } else {
                HStack(spacing: 7) {
                    OpticalSwatchDot(look: descriptor, size: 10)
                    Text(colorMode.title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.62))
                    Text("·").foregroundStyle(.white.opacity(0.35))
                    Text(descriptor.shortTitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .lineLimit(1)
                    if abs(settings.exposure) >= 0.01 {
                        Text(String(format: "%+.1f", settings.exposure))
                            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color(red: 0.98, green: 0.84, blue: 0.52))
                    }
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .modifier(EtchedGlassChip(active: active))
            }
        }
        .disabled(workflow.isWorking || camera.isCapturing)
        .accessibilityLabel("Choose photo style")
        .accessibilityIdentifier("camera.style")
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

    var qualityButton: some View {
        Menu {
            ForEach(CaptureQuality.allCases, id: \.self) { quality in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    settings.captureQuality = quality
                } label: {
                    if settings.captureQuality == quality {
                        Label(quality == .balanced ? "Balanced · 4 RAW" : quality.title, systemImage: "checkmark")
                    } else {
                        Text(quality == .balanced ? "Balanced · 4 RAW" : quality.title)
                    }
                }.accessibilityIdentifier("camera.quality.\(quality.rawValue)")
            }
        } label: {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(settings.captureQuality.title))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.52))
            }
            .modifier(EtchedGlassChip(active: false))
        }
        .disabled(!workflow.canCapture || camera.isCapturing)
        .accessibilityLabel("Capture priority")
        .accessibilityValue(settings.captureQuality.title)
        .accessibilityIdentifier("camera.quality")
        .accessibilityHint("Choose single RAW Speed or four-frame Balanced")
    }

    var statusButton: some View {
        CaptureStatusPill(
            workflow: workflow,
            camera: camera,
            experimentalLiveColor: experimentalLiveColor,
            liveProxyStatus: liveProxyStatus,
            estimatedOutputLabel: estimatedOutputLabel,
            onOpenStatus: { activePanel = .status }
        )
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

    var estimatedOutputLabel: String {
        if settings.captureQuality == .balanced { return "Balanced · 4 RAW · 24 MP output" }
        if settings.captureQuality == .speed { return "Speed · Single RAW · 24 MP output" }
        return "HDR"
    }

    var thumbnailButton: some View {
        Button {
            activePanel = nil
            filterDialVisible = false
            if let capture = workflow.latest {
                reviewedCapture = capture
            }
        } label: {
            Group {
                if let thumbnail {
                    PrecisionPreview(source: thumbnail)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.45), .white.opacity(0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.7
                    )
            )
        }
        .disabled(!CameraControlsAvailability.canReview(hasPhoto: workflow.latest != nil, working: workflow.isWorking))
        .accessibilityLabel("View latest saved photo")
        .accessibilityIdentifier("camera.thumbnail")
    }

    var settingsButton: some View {
        Button {
            activePanel = nil
            filterDialVisible = false
            settingsPresented = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 19, weight: .light))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.05), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.20), lineWidth: 0.6))
        }
        .disabled(camera.isCapturing || camera.isConfiguring || workflow.phase == .authorizing)
        .accessibilityLabel("Camera settings and photo effects")
        .accessibilityIdentifier("camera.settings")
    }
}

private struct CaptureStatusPill: View {
    @ObservedObject var workflow: CaptureWorkflow
    @ObservedObject var camera: CameraController
    let experimentalLiveColor: Bool
    let liveProxyStatus: LiveColorProxyStatus
    let estimatedOutputLabel: String
    let onOpenStatus: () -> Void

    private var needsAttention: Bool {
        workflow.phase == .failed || workflow.phase == .saveOutcomeUnknown
    }

    private var summaryStatus: String {
        if camera.isCapturing { return "Capturing RAW" }
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
        return "HDR"
    }

    var body: some View {
        Button(action: onOpenStatus) {
            HStack(spacing: 5) {
                Circle()
                    .fill(
                        needsAttention ? Color(red: 1.0, green: 0.65, blue: 0.32)
                        : (workflow.isWorking || camera.isCapturing) ? Color(red: 0.75, green: 0.92, blue: 1.0)
                        : .white.opacity(0.62)
                    )
                    .frame(width: 5, height: 5)
                Text(LocalizedStringKey(summaryStatus))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(needsAttention ? Color(red: 1.0, green: 0.82, blue: 0.58) : .white.opacity(0.82))
        }
        .accessibilityLabel(Text(LocalizedStringKey(summaryStatus)))
        .accessibilityValue(Text(LocalizedStringKey(workflow.status.isEmpty ? estimatedOutputLabel : workflow.status)))
        .accessibilityIdentifier("capture.status.summary")
    }
}
