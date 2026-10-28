import Foundation

enum ImageFileProtection {
    // Mac command-line validation cannot request the iOS data-protection class.
    // Ordinary atomic writes work there; iOS capture files keep full protection.
#if os(macOS)
    static let writeOptions: Data.WritingOptions = [.atomic]
    static let attributes: [FileAttributeKey: Any]? = nil
#else
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    static let attributes: [FileAttributeKey: Any]? = [.protectionKey: FileProtectionType.complete]
#endif

    static func apply(to url: URL) throws {
        if let attributes { try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path) }
    }
}
