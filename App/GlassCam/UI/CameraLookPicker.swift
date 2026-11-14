import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI
import UIKit

/// Optical chromatic signature and short descriptor for every bundled look,
/// letting users identify tone & color character at a glance without guessing.
struct OpticalLookDescriptor: Identifiable, Equatable {
    let id: String
    let title: String
    let shortTitle: String
    let traitKey: String
    let primaryColor: Color
    let secondaryColor: Color
    let isMonochrome: Bool

    static func items(mode: ColorMode, resources: ColorResources, family: FFCSCameraFamily) -> [OpticalLookDescriptor] {
        switch mode {
        case .hncs:
            return HNCSEngine.cameraPresets.map { describeHNCS(id: $0.id, name: $0.name) }
        case .ffcs:
            return FFCSEngine.simulations(resources: resources, for: family).map {
                describeFFCS(id: $0.id, name: $0.name)
            }
        case .lumix:
            return LUMIXEngine.looks.map { describeLUMIX(id: $0.id, name: $0.name) }
        }
    }

    static func currentID(settings: CameraSettingsStore) -> String {
        switch settings.colorMode {
        case .hncs: return settings.hncs.presetKey
        case .ffcs: return String(settings.simulationIndex)
        case .lumix: return settings.lumix.photoStyle
        }
    }

    static func apply(id: String, to settings: CameraSettingsStore) {
        switch settings.colorMode {
        case .hncs:
            guard settings.hncs.presetKey != id else { return }
            settings.hncs.presetKey = id
        case .ffcs:
            guard let index = Int(id), settings.simulationIndex != index else { return }
            settings.simulationIndex = index
        case .lumix:
            guard settings.lumix.photoStyle != id else { return }
            settings.lumix.photoStyle = id
        }
    }

    private static func compactTitle(_ raw: String) -> String {
        if let range = raw.range(of: " · ") {
            let prefix = String(raw[..<range.lowerBound])
            let suffix = String(raw[range.upperBound...])
            switch prefix {
            case "White Balance": return "WB · \(suffix)"
            case "Film Grain": return "Grain · \(suffix)"
            case "Grayscale": return "B&W · \(suffix)"
            case "Sharpness": return "Sharp · \(suffix)"
            case "Color Corrections": return suffix
            case "Exposure": return suffix
            case "Gradation Curves": return suffix
            default: return suffix
            }
        }
        return raw
    }

    private static func describeHNCS(id: String, name: String) -> OpticalLookDescriptor {
        let short = compactTitle(name)
        if id.hasPrefix("grayscale-") {
            let filterColor: Color = id.contains("red") ? Color(red: 0.92, green: 0.42, blue: 0.36)
                : id.contains("green") ? Color(red: 0.46, green: 0.84, blue: 0.58)
                : Color(red: 0.46, green: 0.68, blue: 0.96)
            return .init(id: id, title: name, shortTitle: short, traitKey: "Filtered B&W",
                         primaryColor: .white.opacity(0.9), secondaryColor: filterColor, isMonochrome: true)
        }
        if id.hasPrefix("film-grain-") {
            return .init(id: id, title: name, shortTitle: short, traitKey: "Silver Grain",
                         primaryColor: Color(red: 0.88, green: 0.84, blue: 0.76),
                         secondaryColor: Color(red: 0.56, green: 0.58, blue: 0.64), isMonochrome: false)
        }
        if id.hasPrefix("sharpness-") || id == "high" || id == "medium" {
            return .init(id: id, title: name, shortTitle: short, traitKey: "Crisp Detail",
                         primaryColor: Color(red: 0.82, green: 0.92, blue: 1.0),
                         secondaryColor: Color(red: 0.48, green: 0.64, blue: 0.82), isMonochrome: false)
        }
        switch id {
        case "standard":
            return .init(id: id, title: name, shortTitle: short, traitKey: "True Natural",
                         primaryColor: Color(red: 0.95, green: 0.93, blue: 0.88),
                         secondaryColor: Color(red: 0.62, green: 0.78, blue: 0.88), isMonochrome: false)
        case "nature":
            return .init(id: id, title: name, shortTitle: short, traitKey: "Lush Foliage",
                         primaryColor: Color(red: 0.42, green: 0.84, blue: 0.58),
                         secondaryColor: Color(red: 0.36, green: 0.68, blue: 0.92), isMonochrome: false)
        case "portrait":
            return .init(id: id, title: name, shortTitle: short, traitKey: "Smooth Skin",
                         primaryColor: Color(red: 0.96, green: 0.76, blue: 0.66),
                         secondaryColor: Color(red: 0.84, green: 0.58, blue: 0.54), isMonochrome: false)
        case "product":
            return .init(id: id, title: name, shortTitle: short, traitKey: "Studio Clean",
                         primaryColor: Color(red: 0.92, green: 0.94, blue: 0.97),
                         secondaryColor: Color(red: 0.66, green: 0.72, blue: 0.80), isMonochrome: false)
        case "saturated":
            return .init(id: id, title: name, shortTitle: short, traitKey: "Rich Chroma",
                         primaryColor: Color(red: 0.98, green: 0.56, blue: 0.34),
                         secondaryColor: Color(red: 0.28, green: 0.74, blue: 0.92), isMonochrome: false)
        case "extra-contrast":
            return .init(id: id, title: name, shortTitle: short, traitKey: "Deep Contrast",
                         primaryColor: .white,
                         secondaryColor: Color(red: 0.36, green: 0.40, blue: 0.48), isMonochrome: false)
        case "lighten":
            return .init(id: id, title: name, shortTitle: short, traitKey: "Airy Shadow",
                         primaryColor: Color(red: 0.98, green: 0.96, blue: 0.88),
                         secondaryColor: Color(red: 0.74, green: 0.84, blue: 0.94), isMonochrome: false)
        case "tungsten":
            return .init(id: id, title: name, shortTitle: short, traitKey: "2850K Cool",
                         primaryColor: Color(red: 0.54, green: 0.78, blue: 0.98),
                         secondaryColor: Color(red: 0.38, green: 0.56, blue: 0.90), isMonochrome: false)
        case "fluorescent":
            return .init(id: id, title: name, shortTitle: short, traitKey: "3800K Neutral",
                         primaryColor: Color(red: 0.72, green: 0.88, blue: 0.96),
                         secondaryColor: Color(red: 0.78, green: 0.68, blue: 0.92), isMonochrome: false)
        case "daylight", "flash":
            return .init(id: id, title: name, shortTitle: short, traitKey: "5500K Daylight",
                         primaryColor: Color(red: 0.98, green: 0.88, blue: 0.64),
                         secondaryColor: Color(red: 0.68, green: 0.84, blue: 0.96), isMonochrome: false)
        case "cloudy", "shade":
            return .init(id: id, title: name, shortTitle: short, traitKey: "Warm Cast",
                         primaryColor: Color(red: 0.98, green: 0.76, blue: 0.44),
                         secondaryColor: Color(red: 0.90, green: 0.56, blue: 0.38), isMonochrome: false)
        default:
            return .init(id: id, title: name, shortTitle: short, traitKey: "Natural",
                         primaryColor: Color(red: 0.90, green: 0.90, blue: 0.88),
                         secondaryColor: Color(red: 0.60, green: 0.72, blue: 0.84), isMonochrome: false)
        }
    }

    private static func describeFFCS(id: Int, name: String) -> OpticalLookDescriptor {
        let upper = name.uppercased()
        if upper.contains("ACROS") || upper.contains("MONOCHROME") {
            let filterColor: Color = upper.contains("+R") ? Color(red: 0.92, green: 0.42, blue: 0.36)
                : upper.contains("+G") ? Color(red: 0.46, green: 0.84, blue: 0.58)
                : upper.contains("+YE") ? Color(red: 0.96, green: 0.84, blue: 0.38)
                : Color(red: 0.56, green: 0.58, blue: 0.62)
            let trait = upper.contains("ACROS") ? "Fine B&W" : "Smooth B&W"
            return .init(id: String(id), title: name, shortTitle: name, traitKey: trait,
                         primaryColor: .white.opacity(0.92), secondaryColor: filterColor, isMonochrome: true)
        }
        switch upper {
        case "PROVIA":
            return .init(id: String(id), title: name, shortTitle: name, traitKey: "Standard Slide",
                         primaryColor: Color(red: 0.95, green: 0.90, blue: 0.82),
                         secondaryColor: Color(red: 0.42, green: 0.74, blue: 0.94), isMonochrome: false)
        case "VELVIA":
            return .init(id: String(id), title: name, shortTitle: name, traitKey: "Vivid Slide",
                         primaryColor: Color(red: 0.98, green: 0.52, blue: 0.30),
                         secondaryColor: Color(red: 0.22, green: 0.78, blue: 0.68), isMonochrome: false)
        case "ASTIA":
            return .init(id: String(id), title: name, shortTitle: name, traitKey: "Soft Tone",
                         primaryColor: Color(red: 0.97, green: 0.78, blue: 0.72),
                         secondaryColor: Color(red: 0.58, green: 0.82, blue: 0.92), isMonochrome: false)
        case "CLASSIC CHROME":
            return .init(id: String(id), title: name, shortTitle: "Classic Chrome", traitKey: "Documentary",
                         primaryColor: Color(red: 0.78, green: 0.74, blue: 0.64),
                         secondaryColor: Color(red: 0.40, green: 0.58, blue: 0.66), isMonochrome: false)
        case "CLASSIC NEG.":
            return .init(id: String(id), title: name, shortTitle: "Classic Neg.", traitKey: "Crisp Negative",
                         primaryColor: Color(red: 0.94, green: 0.56, blue: 0.42),
                         secondaryColor: Color(red: 0.32, green: 0.68, blue: 0.64), isMonochrome: false)
        case "NOSTALGIC NEG.":
            return .init(id: String(id), title: name, shortTitle: "Nostalgic Neg.", traitKey: "Amber Warmth",
                         primaryColor: Color(red: 0.96, green: 0.74, blue: 0.42),
                         secondaryColor: Color(red: 0.78, green: 0.48, blue: 0.36), isMonochrome: false)
        case "ETERNA":
            return .init(id: String(id), title: name, shortTitle: "Eterna", traitKey: "Cinema Soft",
                         primaryColor: Color(red: 0.68, green: 0.80, blue: 0.82),
                         secondaryColor: Color(red: 0.44, green: 0.56, blue: 0.64), isMonochrome: false)
        case "ETERNA BLEACH BYPASS":
            return .init(id: String(id), title: name, shortTitle: "Bleach Bypass", traitKey: "Silver Matte",
                         primaryColor: Color(red: 0.82, green: 0.82, blue: 0.78),
                         secondaryColor: Color(red: 0.38, green: 0.44, blue: 0.48), isMonochrome: false)
        case "PRO NEG. HI":
            return .init(id: String(id), title: name, shortTitle: "Pro Neg. Hi", traitKey: "Crisp Portrait",
                         primaryColor: Color(red: 0.95, green: 0.78, blue: 0.68),
                         secondaryColor: Color(red: 0.54, green: 0.64, blue: 0.74), isMonochrome: false)
        case "PRO NEG. STD":
            return .init(id: String(id), title: name, shortTitle: "Pro Neg. Std", traitKey: "Gentle Gradation",
                         primaryColor: Color(red: 0.94, green: 0.84, blue: 0.78),
                         secondaryColor: Color(red: 0.68, green: 0.76, blue: 0.82), isMonochrome: false)
        case "SEPIA":
            return .init(id: String(id), title: name, shortTitle: "Sepia", traitKey: "Warm Tint",
                         primaryColor: Color(red: 0.88, green: 0.72, blue: 0.50),
                         secondaryColor: Color(red: 0.56, green: 0.42, blue: 0.28), isMonochrome: false)
        case "REALA ACE":
            return .init(id: String(id), title: name, shortTitle: "Reala Ace", traitKey: "True Neutral",
                         primaryColor: Color(red: 0.92, green: 0.92, blue: 0.88),
                         secondaryColor: Color(red: 0.46, green: 0.76, blue: 0.72), isMonochrome: false)
        default:
            return .init(id: String(id), title: name, shortTitle: name, traitKey: "Film Look",
                         primaryColor: Color(red: 0.90, green: 0.88, blue: 0.82),
                         secondaryColor: Color(red: 0.52, green: 0.72, blue: 0.84), isMonochrome: false)
        }
    }

    private static func describeLUMIX(id: String, name: String) -> OpticalLookDescriptor {
        if id.contains("monochrome") {
            let trait = id == "leica-monochrome" ? "Deep Contrast B&W"
                : id == "l-monochrome-d" ? "Dynamic B&W"
                : id == "l-monochrome-s" ? "Silky B&W"
                : "Monochrome"
            return .init(id: id, title: name, shortTitle: name, traitKey: trait,
                         primaryColor: .white.opacity(0.94),
                         secondaryColor: Color(red: 0.46, green: 0.48, blue: 0.52), isMonochrome: true)
        }
        switch id {
        case "standard":
            return .init(id: id, title: name, shortTitle: name, traitKey: "Balanced",
                         primaryColor: Color(red: 0.94, green: 0.92, blue: 0.88),
                         secondaryColor: Color(red: 0.54, green: 0.76, blue: 0.90), isMonochrome: false)
        case "vivid":
            return .init(id: id, title: name, shortTitle: name, traitKey: "High Chroma",
                         primaryColor: Color(red: 0.98, green: 0.54, blue: 0.34),
                         secondaryColor: Color(red: 0.24, green: 0.78, blue: 0.72), isMonochrome: false)
        case "natural":
            return .init(id: id, title: name, shortTitle: name, traitKey: "Soft Chroma",
                         primaryColor: Color(red: 0.88, green: 0.92, blue: 0.84),
                         secondaryColor: Color(red: 0.58, green: 0.78, blue: 0.76), isMonochrome: false)
        case "landscape":
            return .init(id: id, title: name, shortTitle: name, traitKey: "Sky & Greens",
                         primaryColor: Color(red: 0.38, green: 0.84, blue: 0.58),
                         secondaryColor: Color(red: 0.32, green: 0.66, blue: 0.96), isMonochrome: false)
        case "portrait":
            return .init(id: id, title: name, shortTitle: name, traitKey: "Warm Complexion",
                         primaryColor: Color(red: 0.97, green: 0.78, blue: 0.68),
                         secondaryColor: Color(red: 0.84, green: 0.58, blue: 0.54), isMonochrome: false)
        case "flat", "like709":
            return .init(id: id, title: name, shortTitle: name, traitKey: "Wide Roll-off",
                         primaryColor: Color(red: 0.80, green: 0.82, blue: 0.84),
                         secondaryColor: Color(red: 0.54, green: 0.60, blue: 0.66), isMonochrome: false)
        case "classic-neo":
            return .init(id: id, title: name, shortTitle: name, traitKey: "Nostalgic Film",
                         primaryColor: Color(red: 0.92, green: 0.78, blue: 0.54),
                         secondaryColor: Color(red: 0.42, green: 0.68, blue: 0.74), isMonochrome: false)
        default:
            return .init(id: id, title: name, shortTitle: name, traitKey: "Cinema Curve",
                         primaryColor: Color(red: 0.86, green: 0.78, blue: 0.64),
                         secondaryColor: Color(red: 0.44, green: 0.64, blue: 0.78), isMonochrome: false)
        }
    }
}

/// Miniature optical filter swatch: monochrome silver ring or dual-arc color bead.
struct OpticalSwatchDot: View {
    let look: OpticalLookDescriptor
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            if look.isMonochrome {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [look.primaryColor, Color.white.opacity(0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .strokeBorder(look.secondaryColor.opacity(0.9), lineWidth: 1.3)
            } else {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [look.primaryColor, look.secondaryColor, look.primaryColor],
                            center: .center
                        )
                    )
                Circle()
                    .strokeBorder(.white.opacity(0.45), lineWidth: 0.6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Horizontal optical filter dial placed directly over the peripheral glass,
/// keeping the central 4:3 photograph completely unobstructed while scrolling.
struct OpticalFilterDial: View {
    @Environment(\.colorResources) private var resources
    @ObservedObject var settings: CameraSettingsStore
    let onDismiss: () -> Void
    @State private var scrolledID: String?

    private var items: [OpticalLookDescriptor] {
        OpticalLookDescriptor.items(mode: settings.colorMode, resources: resources, family: settings.ffcs.cameraFamily)
    }

    var body: some View {
        let current = OpticalLookDescriptor.currentID(settings: settings)
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(ColorMode.allCases) { mode in
                    let active = settings.colorMode == mode
                    Button {
                        guard settings.colorMode != mode else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        settings.colorMode = mode
                    } label: {
                        Text(mode.title)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(0.8)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 26)
                            .foregroundStyle(active ? .white : .white.opacity(0.58))
                            .background {
                                if active {
                                    Capsule()
                                        .fill(.white.opacity(0.20))
                                        .overlay(Capsule().strokeBorder(.white.opacity(0.42), lineWidth: 0.6))
                                }
                            }
                    }
                    .accessibilityIdentifier("camera.dial.engine.\(mode.rawValue)")
                }
                Spacer(minLength: 4)
                if let activeLook = items.first(where: { $0.id == current }) {
                    Text(LocalizedStringKey(activeLook.traitKey))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 28, height: 26)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .accessibilityLabel("Close filter dial")
                .accessibilityIdentifier("camera.dial.close")
            }
            .padding(.horizontal, 10)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(items) { item in
                            let active = item.id == current
                            let live = settings.experimentalLiveColor &&
                                LiveColorRecipe(resources: resources, settings: settings,
                                    simulationIndex: Int(item.id)).unsupportedReason == nil
                            Button {
                                select(item.id)
                            } label: {
                                HStack(spacing: 6) {
                                    OpticalSwatchDot(look: item, size: active ? 11 : 9)
                                    Text(item.shortTitle)
                                        .font(.system(size: 12, weight: active ? .semibold : .regular, design: .rounded))
                                        .lineLimit(1)
                                    if live {
                                        Text("LIVE").font(.system(size: 8, weight: .bold, design: .rounded))
                                            .foregroundStyle(.mint)
                                            .accessibilityLabel("Approximate live preview available")
                                    }
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 32)
                                .foregroundStyle(active ? .white : .white.opacity(0.75))
                                .background {
                                    if active {
                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: [.white.opacity(0.26), .white.opacity(0.10)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .overlay {
                                                Capsule().strokeBorder(
                                                    LinearGradient(
                                                        colors: [.white.opacity(0.62), .white.opacity(0.20)],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    ),
                                                    lineWidth: 0.8
                                                )
                                            }
                                    } else {
                                        Capsule()
                                            .fill(.white.opacity(0.05))
                                            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                                    }
                                }
                            }
                            .id(item.id)
                            .accessibilityLabel(item.title)
                            .accessibilityValue(Text(LocalizedStringKey(item.traitKey)))
                            .accessibilityAddTraits(active ? .isSelected : [])
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 10)
                }
                .scrollPosition(id: $scrolledID, anchor: .center)
                .onAppear {
                    scrolledID = current
                    proxy.scrollTo(current, anchor: .center)
                }
                .onChange(of: settings.colorMode) { _, _ in
                    let updated = OpticalLookDescriptor.currentID(settings: settings)
                    scrolledID = updated
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(updated, anchor: .center)
                    }
                }
            }
            .frame(height: 32)
        }
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.65
                        )
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.filterDial")
    }

    private func select(_ id: String) {
        let current = OpticalLookDescriptor.currentID(settings: settings)
        guard id != current else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        OpticalLookDescriptor.apply(id: id, to: settings)
    }
}

/// Full-list optical style selector used inside compact/landscape/accessibility sheets.
struct CameraLookPicker: View {
    @Environment(\.colorResources) private var resources
    @ObservedObject var settings: CameraSettingsStore
    let selected: () -> Void

    var body: some View {
        let items = OpticalLookDescriptor.items(
            mode: settings.colorMode,
            resources: resources,
            family: settings.ffcs.cameraFamily
        )
        let current = OpticalLookDescriptor.currentID(settings: settings)
        VStack(spacing: 14) {
            Picker("Color engine", selection: $settings.colorMode) {
                ForEach(ColorMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented)
            ForEach(items) { look in
                lookButton(look, active: look.id == current) {
                    UISelectionFeedbackGenerator().selectionChanged()
                    OpticalLookDescriptor.apply(id: look.id, to: settings)
                    selected()
                }
            }
        }
    }

    private func lookButton(_ look: OpticalLookDescriptor, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                OpticalSwatchDot(look: look, size: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(look.title)
                        .font(.system(size: 17, weight: active ? .semibold : .medium, design: .rounded))
                    Text(LocalizedStringKey(look.traitKey))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(.white.opacity(active ? 0.95 : 0.22))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(active ? 0.12 : 0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(active ? 0.34 : 0.08), lineWidth: 0.65)
                    }
            }
        }.buttonStyle(.plain)
    }
}
