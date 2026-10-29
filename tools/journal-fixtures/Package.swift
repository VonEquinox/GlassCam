// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JournalFixtureTools",
    platforms: [.macOS("27.0")],
    dependencies: [.package(path: "../../Packages/GlassCamKit")],
    targets: [
        .executableTarget(name: "generate_journal_fixtures",
            dependencies: [.product(name: "GlassCamKit", package: "GlassCamKit")], path: "Sources"),
    ],
    swiftLanguageModes: [.v5]
)
