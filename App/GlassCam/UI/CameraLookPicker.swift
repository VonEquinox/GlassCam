import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import AVFoundation
import UIKit

struct CameraLookPicker: View {
    @Environment(\.colorResources) private var resources
    @ObservedObject var settings: CameraSettingsStore
    let selected: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Picker("Color engine", selection: $settings.colorMode) {
                ForEach(ColorMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented)
            if settings.colorMode == .hncs {
                ForEach(HNCSEngine.cameraPresets) { look in
                    lookButton(look.name, active: settings.hncs.presetKey == look.id) {
                        settings.hncs.presetKey = look.id; selected()
                    }
                }
            } else if settings.colorMode == .ffcs {
                ForEach(FFCSEngine.simulations(resources: resources, for: settings.ffcs.cameraFamily)) { look in
                    lookButton(look.name, active: settings.simulationIndex == look.id) {
                        settings.simulationIndex = look.id; selected()
                    }
                }
            } else {
                ForEach(LUMIXEngine.looks) { look in
                    lookButton(look.name, active: settings.lumix.photoStyle == look.id) {
                        settings.lumix.photoStyle = look.id; selected()
                    }
                }
            }
        }
    }
    private func lookButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 23, weight: .regular, design: .serif))
                Spacer()
                Image(systemName: active ? "checkmark.circle.fill" : "circle").foregroundStyle(.white.opacity(active ? 1 : 0.2))
            }.padding(18).background(.white.opacity(active ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }
}
