import Foundation
import Combine

/// Output preferences belong to a physical camera, never a virtual zoom position.
/// Preview bounds are separate, global user preferences and do not resize the RAW.
final class CameraSettingsStore: ObservableObject {
    static let centerPreviewCaps = [1280, 1920, 2560, 3840, 4096]
    static let peripheralPreviewCaps = [640, 960, 1280]
    @Published var centerPreviewLongEdge: Int {
        didSet { defaults.set(centerPreviewLongEdge, forKey: "camera.preview.center.longEdge") }
    }
    @Published var peripheralPreviewLongEdge: Int {
        didSet { defaults.set(peripheralPreviewLongEdge, forKey: "camera.preview.peripheral.longEdge") }
    }
    @Published private(set) var outputSelections: [String: Int]
    private let defaults: UserDefaults
    private static let outputsKey = "camera.output.megapixels.byPhysicalLens.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let center = defaults.integer(forKey: "camera.preview.center.longEdge")
        let peripheral = defaults.integer(forKey: "camera.preview.peripheral.longEdge")
        centerPreviewLongEdge = Self.centerPreviewCaps.contains(center) ? center : 1920
        peripheralPreviewLongEdge = Self.peripheralPreviewCaps.contains(peripheral) && peripheral < (Self.centerPreviewCaps.contains(center) ? center : 1920) ? peripheral : 960
        outputSelections = defaults.dictionary(forKey: Self.outputsKey) as? [String: Int] ?? [:]
    }

    func outputMegapixels(physicalCameraID: String, mode: String) -> Int? {
        outputSelections[key(physicalCameraID: physicalCameraID, mode: mode)]
    }

    func setOutputMegapixels(_ value: Int, physicalCameraID: String, mode: String) {
        guard [12, 24, 48].contains(value) else { return }
        outputSelections[key(physicalCameraID: physicalCameraID, mode: mode)] = value
        defaults.set(outputSelections, forKey: Self.outputsKey)
    }

    private func key(physicalCameraID: String, mode: String) -> String {
        // Encoding makes separators in the opaque device identifier unambiguous.
        "\(mode):\(Data(physicalCameraID.utf8).base64EncodedString())"
    }
}
