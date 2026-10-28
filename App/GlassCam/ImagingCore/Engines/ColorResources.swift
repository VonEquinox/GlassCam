import Foundation

/// Runtime asset locations supplied by the app or a test fixture owner.
/// This dependency is separate from the persisted photo recipe.
struct ColorResources: Equatable, Sendable {
    let resourceDirectory: URL?

    var ffcsDirectory: URL? { resourceDirectory?.appendingPathComponent("FFCS", isDirectory: true) }
    var lumixDirectory: URL? { resourceDirectory?.appendingPathComponent("LUMIX", isDirectory: true) }
}
