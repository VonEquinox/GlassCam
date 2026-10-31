// swift-tools-version: 6.0
import PackageDescription

let strictFP: [CXXSetting] = [.unsafeFlags(["-fno-fast-math", "-ffp-contract=off"])]
let colorSettings: [CXXSetting] = strictFP + [.unsafeFlags(["-O3"])]
let f5Settings: [CXXSetting] = strictFP + [.unsafeFlags(["-O2"])]
let nativeChecks: [CXXSetting] = colorSettings + [.unsafeFlags(["-UNDEBUG"])]
let colorLinks: [LinkerSetting] = [.linkedLibrary("z"), .linkedLibrary("pthread")]

func smoke(_ name: String, dependencies: [Target.Dependency], settings: [CXXSetting] = nativeChecks) -> Target {
    .executableTarget(name: name, dependencies: dependencies, path: "NativeTests/\(name)",
                      cxxSettings: settings, linkerSettings: colorLinks)
}

let package = Package(
    name: "GlassCamKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "GlassCamCore", targets: ["CHNCS", "CFFCS", "CLUMIX", "CF5"]),
        .library(name: "GlassCamKit", targets: ["ImagingCore", "Capture", "F5", "Peripheral"]),
        .library(name: "GlassCamNative", type: .dynamic, targets: ["CHNCS", "CFFCS", "CLUMIX", "CF5"]),
        .library(name: "GlassCamNativeTestSupport", type: .dynamic, targets: ["NativeTestSupport"]),
    ],
    targets: [
        .target(name: "GlassCamTestSupport", dependencies: ["ImagingCore"], path: "Tests/TestSupport"),
        .testTarget(name: "ImagingCoreTests", dependencies: ["ImagingCore", "Capture", "GlassCamTestSupport", "NativeTestSupport"]),
        .testTarget(name: "CaptureTests", dependencies: ["Capture", "ImagingCore", "GlassCamTestSupport"]),
        .testTarget(name: "F5Tests", dependencies: ["F5", "Capture", "ImagingCore", "GlassCamTestSupport"]),
        .testTarget(name: "PeripheralTests", dependencies: ["Peripheral", "GlassCamTestSupport"]),
        .target(name: "ImagingCore", dependencies: ["CHNCS", "CFFCS", "CLUMIX", "CMetalImage"],
                resources: [.copy("Metal")]),
        .target(name: "Capture", dependencies: ["ImagingCore"]),
        .target(name: "F5", dependencies: ["CF5", "CMetalF5", "ImagingCore", "Capture"], resources: [.copy("F5Kernels.metal")]),
        .target(name: "CMetalF5", cxxSettings: strictFP + [.unsafeFlags(["-O3", "-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Metal"), .linkedFramework("Foundation")]),
        .target(name: "Peripheral", dependencies: ["ImagingCore"]),
        .target(name: "CHNCS", cxxSettings: colorSettings + [.headerSearchPath("generated")], linkerSettings: colorLinks),
        .target(name: "CFFCS", cxxSettings: colorSettings, linkerSettings: colorLinks),
        .target(name: "CLUMIX", cxxSettings: colorSettings, linkerSettings: [.linkedLibrary("z")]),
        .target(name: "CMetalImage", dependencies: ["CHNCS", "CFFCS", "CLUMIX"],
                cxxSettings: colorSettings + [.unsafeFlags(["-fobjc-arc"]), .headerSearchPath("../ImagingCore/Metal")],
                linkerSettings: [.linkedFramework("Metal"), .linkedFramework("CoreImage"), .linkedFramework("Foundation")]),
        .target(name: "CF5", cxxSettings: f5Settings),
        .target(name: "NativeTestSupport", dependencies: ["CHNCS"], path: "NativeTestSupport",
                cxxSettings: nativeChecks + [.headerSearchPath("../Sources/CHNCS/generated")]),
        smoke("hncs_smoke", dependencies: ["CHNCS"]),
        smoke("hncs_spatial_smoke", dependencies: ["CHNCS"]),
        smoke("hncs_parallel_sanitizer", dependencies: ["CHNCS"]),
        smoke("hncs_revision8_sanitizer", dependencies: ["CHNCS"]),
        smoke("hncs_native_pipeline_sanitizer", dependencies: ["CHNCS"]),
        smoke("ffcs_smoke", dependencies: ["CFFCS"]),
        smoke("ffcs_strip_sanitizer", dependencies: ["CFFCS"]),
        // These checks exercise private stages in the production translation unit.
        smoke("ffcs_color_only_test", dependencies: [], settings: nativeChecks + [.headerSearchPath("../../Sources/CFFCS/include")]),
        smoke("ffcs_effect_switches_test", dependencies: [], settings: nativeChecks + [.headerSearchPath("../../Sources/CFFCS/include")]),
        smoke("f5_core_tests", dependencies: ["CF5"], settings: f5Settings + [.unsafeFlags(["-UNDEBUG"]), .headerSearchPath("../../Sources/CF5")]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
