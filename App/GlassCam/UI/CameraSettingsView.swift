import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

/// An independent page; all controls update the same persisted shutter settings.
struct CameraSettingsView: View {
    @Environment(\.colorResources) private var resources
    @ObservedObject var settings: CameraSettingsStore
    @ObservedObject var camera: CameraController
    @ObservedObject var rawTests: RAWTestRecorder
    @ObservedObject var workflow: CaptureWorkflow
    let canRecordF5: Bool
    let options: [CameraController.OutputOption]
    let physicalCameraID: String?
    let mode: String
    let onBack: () -> Void
    @State private var advanced = false

    private var outputSelection: Binding<Int> {
        Binding(get: { settings.captureQuality.outputMegapixels(preferred:
                    physicalCameraID.map { settings.outputMegapixels(physicalCameraID: $0, mode: mode) } ?? settings.preferredOutputMegapixels) },
                set: { value in
                    guard !settings.captureQuality.usesBayer, let id = physicalCameraID,
                          options.contains(where: { $0.megapixels == value }) else { return }
                    settings.setOutputMegapixels(value, physicalCameraID: id, mode: mode)
                })
    }
    var body: some View {
        VStack(spacing: 0) {
            CameraPageHeader(title: advanced ? "Advanced" : "Settings",
                             backLabel: advanced ? "Back to settings" : "Back to camera") {
                if advanced { advanced = false } else { onBack() }
            }.disabled(rawTests.isRecording)
            ScrollView {
                VStack(spacing: 18) {
                    if advanced { advancedCards } else { commonCards }
                    Text("GLASSCAM").font(.system(size: 10, weight: .medium)).tracking(4)
                        .foregroundStyle(.white.opacity(0.25)).padding(.vertical, 18)
                }.padding(.horizontal, 20).padding(.top, 12)
                    .frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden).disabled(rawTests.isRecording)
        }
        .background(CameraSettingsBackground()).foregroundStyle(.white)
        .interactiveDismissDisabled(rawTests.isRecording)
        .preferredColorScheme(.dark).tint(.white).buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.22), value: advanced)
    }

    @ViewBuilder private var commonCards: some View {
        CameraCard(title: "Photo output", symbol: "photo.stack") {
            Picker("Capture priority", selection: $settings.captureQuality) {
                ForEach(CaptureQuality.allCases, id: \.self) { quality in Text(quality.title).tag(quality) }
            }.pickerStyle(.segmented).accessibilityIdentifier("settings.captureQuality")
            if settings.captureQuality == .balanced {
                HStack { Text("Sampling"); Spacer(); Text("2× in each dimension").foregroundStyle(.secondary) }
                Text("Balanced combines four equal-exposure Bayer RAW frames with curvature reconstruction at 2× sampling.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            } else if settings.captureQuality == .speed {
                Text("Speed uses one 12 MP Bayer RAW with noise reduction, bad-pixel correction, demosaicing and lens correction.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            } else {
                Picker("Resolution", selection: outputSelection) {
                    ForEach([24,48],id:\.self) { value in Text("\(value) MP").tag(value) }
                }.pickerStyle(.segmented).disabled(physicalCameraID == nil || options.isEmpty)
                    .accessibilityIdentifier("settings.resolution")
            }
            HStack { Text("Format"); Spacer(); Text("10-bit HDR HEIF").foregroundStyle(.secondary) }.font(.subheadline)
            if !settings.captureQuality.usesBayer {
                Text("Photos save automatically. In 48 MP mode, smaller framed sources save at 24 MP.")
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
            }
        }
        F5SettingsCard(camera: camera, settings: settings, rawTests: rawTests, workflow: workflow, canRecord: canRecordF5)
        CameraCard(title: "Photo style", symbol: "camera.filters") {
            Picker("Color engine", selection: $settings.colorMode) {
                ForEach(ColorMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented).accessibilityIdentifier("settings.engine")
            if settings.colorMode == .hncs {
                Picker("Phocus preset", selection: $settings.hncs.presetKey) {
                    ForEach(HNCSEngine.cameraPresets) { preset in Text(preset.name).tag(preset.id) }
                }.pickerStyle(.menu).accessibilityIdentifier("settings.preset")
                Picker("White balance", selection: $settings.hncs.whiteBalancePolicy) {
                    ForEach(HNCSWhiteBalancePolicy.allCases) { value in Text(LocalizedStringKey(value.title)).tag(value) }
                }.pickerStyle(.menu).accessibilityIdentifier("settings.whiteBalance")
                Text(LocalizedStringKey(settings.hncs.whiteBalancePolicy == .photo
                     ? "Keeps each photo’s own white balance."
                     : "Uses the original preset white balance, when specified."))
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
            } else if settings.colorMode == .ffcs {
                Picker("Film simulation", selection: $settings.simulationIndex) {
                    ForEach(FFCSEngine.simulations(resources: resources, for: settings.ffcs.cameraFamily)) { look in Text(look.name).tag(look.id) }
                }.pickerStyle(.menu).accessibilityIdentifier("ffcs.simulation")
            } else {
                LUMIXPhotoStyleControls(settings: $settings.lumix)
            }
            HStack {
                Text("Effect exposure")
                Spacer()
                Text(String(format: "%+.2f EV", settings.exposure)).monospacedDigit().foregroundStyle(.secondary)
            }.font(.subheadline)
            Slider(value: $settings.exposure, in: -2...2, step: 0.05)
                .accessibilityLabel("Photo effect exposure")
            EffectToggleControls(effects: $settings.effects, mode: settings.colorMode)
        }
        CameraCard(title: "Viewfinder", symbol: "viewfinder") {
            Toggle("Composition grid", isOn: $settings.gridVisible).accessibilityIdentifier("settings.grid")
            Text("The clear central frame is your photo. The outer glass darkens when camera views cannot align reliably.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
        }
        Button { advanced = true } label: {
            CameraCard(title: "Advanced", symbol: "slider.horizontal.3") {
                HStack {
                    Text("Color processing & preview").font(.subheadline)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.subheadline)
                }
            }
        }.accessibilityIdentifier("settings.advanced")
    }

    @ViewBuilder private var advancedCards: some View {
        CameraCard(title: "Color processing", symbol: "slider.horizontal.3") {
            if settings.colorMode == .hncs {
                HNCSPresetControls(settings: $settings.hncs, showCommon: false)
            } else if settings.colorMode == .ffcs {
                FFCSReferenceControls(settings: $settings.ffcs, simulationIndex: $settings.simulationIndex)
            } else {
                LUMIXPhotoStyleControls(settings: $settings.lumix)
                Text("Keeps each photo’s own white balance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        CameraCard(title: "Preview", symbol: "viewfinder") {
            Picker("Preview long-edge limit", selection: $settings.centerPreviewLongEdge) {
                ForEach(CameraSettingsStore.centerPreviewCaps, id: \.self) { value in Text("\(value) px").tag(value) }
            }.pickerStyle(.menu)
            Toggle("Experimental live color (approx.)", isOn: $settings.experimentalLiveColor)
            Text("Approximate color only; the saved photo uses the complete selected effect.")
                .font(.caption).foregroundStyle(.secondary)
        }
        CameraCard(title: "Adjustments", symbol: "arrow.counterclockwise") {
            Button("Reset effect adjustments") {
                settings.exposure = 0
                if settings.colorMode == .hncs { settings.hncs = .standard }
            }
            Text("Resets effect exposure and the HNCS look. Output, grain and sharpening choices stay saved.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
