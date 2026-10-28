import CLUMIX
import Foundation

enum LUMIXPhotoStyleCatalog {
    struct Look: Identifiable, Sendable {
        let id: String
        let name: String
        let index: Int
    }
    static let looks: [Look] = (0..<Int(lumix_look_count())).compactMap { index in
        guard let key = lumix_look_key(index), let name = lumix_look_name(index) else { return nil }
        return Look(id: String(cString: key), name: String(cString: name), index: index)
    }
}
