import SwiftUI

/// App-owned chrome. No system glass/backdrop effects and no view snapshots.
struct CameraCard<Content: View>: View {
    var title: LocalizedStringKey
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold)).textCase(.uppercase)
                .tracking(1.5).foregroundStyle(.white.opacity(0.58))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.075), .white.opacity(0.025)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.035)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
        }
    }
}

struct CameraSettingsBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.031, blue: 0.037)
            GeometryReader { geometry in
                RadialGradient(colors: [Color(red: 0.10, green: 0.17, blue: 0.18).opacity(0.6), .clear],
                               center: .topTrailing, startRadius: 0,
                               endRadius: max(geometry.size.width, geometry.size.height) * 0.8)
            }
        }.ignoresSafeArea()
    }
}

struct CameraPill: ViewModifier {
    var selected = false
    func body(content: Content) -> some View {
        content.padding(.horizontal, 14).frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(selected ? .black : .white)
            .background(selected ? Color.white.opacity(0.94) : Color.black.opacity(0.28), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0 : 0.22), lineWidth: 0.6))
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
                Image(systemName: "arrow.left").font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.07), in: Circle())
            }.accessibilityLabel(Text(backLabel)).accessibilityIdentifier(backIdentifier)
            Text(title).font(.system(size: 28, weight: .semibold, design: .rounded))
            Spacer(minLength: 0)
        }.foregroundStyle(.white).padding(.horizontal, 22).padding(.vertical, 12)
    }
}
