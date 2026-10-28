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
        .library(name: "GlassCamNative", type: .dynamic, targets: ["CHNCS", "CFFCS", "CLUMIX", "CF5"]),
        .library(name: "GlassCamNativeTestSupport", type: .dynamic, targets: ["NativeTestSupport"]),
    ],
    targets: [
        .target(name: "CHNCS", cxxSettings: colorSettings + [.headerSearchPath("generated")], linkerSettings: colorLinks),
        .target(name: "CFFCS", cxxSettings: colorSettings, linkerSettings: colorLinks),
        .target(name: "CLUMIX", cxxSettings: colorSettings, linkerSettings: [.linkedLibrary("z")]),
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
        .executableTarget(name: "profile_hncs", path: "NativeTools/profile_hncs",
            cxxSettings: colorSettings + [.headerSearchPath("../../Sources/CHNCS/include"), .headerSearchPath("../../Sources/CHNCS/generated")], linkerSettings: colorLinks),
        .executableTarget(name: "profile_ffcs", path: "NativeTools/profile_ffcs",
            cxxSettings: colorSettings + [.headerSearchPath("../../Sources/CFFCS/include")], linkerSettings: colorLinks),
        .executableTarget(name: "benchmark_lowres_color", dependencies: ["CHNCS", "CFFCS"], path: "NativeTools/benchmark_lowres_color",
            cxxSettings: colorSettings, linkerSettings: colorLinks),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
