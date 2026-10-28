import CHNCS
import Foundation

public enum HNCSPresetCatalog {
    public struct Preset: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let flags: UInt32
        let whiteBalanceKelvin: Int?
        public var hasOptionalSharpness: Bool { flags & 16 != 0 }
    }

    private struct PresetWhiteBalance: Decodable {
        let color_temperature: Int?
    }

    /// Catalog names come from the exact backend assets. Source-defined no-op
    /// tools are not presented as fake effects; spatial looks use a separate pass.
    /// New camera UI excludes the legacy square look; saved photo recipes still decode it.
    public static var cameraPresets: [Preset] { presets.filter { $0.id != "square-crop" } }

    static let presets: [Preset] = (0..<Int(hncs_preset_count())).compactMap { index in
        guard let key = hncs_preset_key(index), let name = hncs_preset_name(index) else { return nil }
        let flags = hncs_preset_flags(key)
        let id = String(cString: key)
        guard id == "standard" || flags & (1 | 2 | 4 | 8) != 0 else { return nil }
        guard let json = hncs_preset_settings_json(key),
              let white = try? JSONDecoder().decode(PresetWhiteBalance.self,
                  from: Data(String(cString: json).utf8)) else { return nil }
        let kelvin = white.color_temperature ?? 0
        return Preset(id: id, name: String(cString: name), flags: flags,
                      whiteBalanceKelvin: kelvin > 0 ? kelvin : nil)
    }

}
