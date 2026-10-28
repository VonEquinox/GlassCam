import Foundation

/// Runtime asset locations supplied by the app or a test fixture owner.
/// This dependency is separate from the persisted photo recipe.
public struct ColorResources: Equatable, Sendable {
    public init(resourceDirectory: URL?) { self.resourceDirectory = resourceDirectory }
    public let resourceDirectory: URL?

    public var ffcsDirectory: URL? { resourceDirectory?.appendingPathComponent("FFCS", isDirectory: true) }
    var lumixDirectory: URL? { resourceDirectory?.appendingPathComponent("LUMIX", isDirectory: true) }
}
