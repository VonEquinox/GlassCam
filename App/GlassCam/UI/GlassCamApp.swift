import ImagingCore
import Capture
import F5
import Peripheral
import SwiftUI

@main
struct GlassCamApp: App {
    private let formats = CaptureFormats([F5CaptureFormat()])
    private let resources = ColorResources(resourceDirectory: Bundle.main.resourceURL)
    var body: some Scene {
        WindowGroup {
            ContentView(resources: resources, formats: formats).preferredColorScheme(.dark)
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
