import SwiftUI

@main
struct GlassCamApp: App {
    var body: some Scene {
        WindowGroup {
#if GLASSCAM_PERFORMANCE
            if ProcessInfo.processInfo.environment["GLASSCAM_PERFORMANCE_RUN"] != nil {
                DevicePerformanceView().preferredColorScheme(.dark)
            } else {
                ContentView().preferredColorScheme(.dark)
            }
#else
            ContentView().preferredColorScheme(.dark)
#endif
        }
    }
}
