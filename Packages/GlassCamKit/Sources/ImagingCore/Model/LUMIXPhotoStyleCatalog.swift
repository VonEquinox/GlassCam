import CLUMIX
import Foundation

public enum LUMIXPhotoStyleCatalog {
    public struct Look: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let index: Int
    }
    public static let looks: [Look] = (0..<Int(lumix_look_count())).compactMap { index in
        guard let key = lumix_look_key(index), let name = lumix_look_name(index) else { return nil }
        return Look(id: String(cString: key), name: String(cString: name), index: index)
    }
}
