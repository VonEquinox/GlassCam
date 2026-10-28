import SwiftUI

@main
struct GlassCamApp: App {
    private let resources = ColorResources(resourceDirectory: Bundle.main.resourceURL)
    var body: some Scene {
        WindowGroup {
#if GLASSCAM_PERFORMANCE
            if ProcessInfo.processInfo.environment["GLASSCAM_PERFORMANCE_RUN"] != nil {
                DevicePerformanceView(resources: resources).preferredColorScheme(.dark)
            } else {
                ContentView(resources: resources).preferredColorScheme(.dark)
            }
#else
            ContentView(resources: resources).preferredColorScheme(.dark)
#endif
        }
    }
}

private struct ColorResourcesKey: EnvironmentKey {
    static let defaultValue = ColorResources(resourceDirectory: nil)
}

extension EnvironmentValues {
    var colorResources: ColorResources {
        get { self[ColorResourcesKey.self] }
        set { self[ColorResourcesKey.self] = newValue }
    }
}
