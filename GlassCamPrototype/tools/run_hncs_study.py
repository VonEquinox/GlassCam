"""Measure the production HNCS photo pipeline with an existing RAW.

By default this compiles and runs on macOS. --prepare-ios only writes a separate
Xcode project. --run-ios DEVICE builds, installs, runs, and collects its report
with a deadline; completion never depends on the GUI app exiting. Neither mode
captures photos or writes to Photos. All artifacts stay in --output-dir.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ["ExportSettings.swift", "SourceImageStore.swift", "PhotoWhiteBalance.swift",
         "HNCSEngine.swift", "FFCSEngine.swift", "LUMIXEngine.swift", "ImagePipeline.swift", "PreviewRaster.swift",
         "CaptureWorkflow.swift"]
CPP = ["hncs.cpp", "hncs_spatial.cpp", "hncs_numpy_rng.cpp", "ffcs.cpp", "lumix.cpp"]


def call(*args):
    subprocess.run([str(x) for x in args], check=True)


def prepare_ios(args, work):
    entry = work / "StudyApp.swift"
    entry.write_text('''import SwiftUI
import UIKit
@main struct StudyApp: App {
    @State private var status = "Running HNCS study…"
    @State private var started = false
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("HNCS performance study").font(.title)
                Text(status)
                Text("Keep this app in the foreground. No camera capture or Photos writes.").font(.footnote)
            }.padding().task {
                guard !started else { return }
                started = true
                UIApplication.shared.isIdleTimerDisabled = true
                status = await Task.detached(priority: .userInitiated) {
                    do {
                        let source = Bundle.main.url(forResource: "source", withExtension: "dng")!
                        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("LABEL")
                        if INPUT_STUDY {
                            try AppleRAWInputStudy.run(sourceURL: source, directory: directory, label: "LABEL",
                                                      runID: "RUN_ID", exposureEV: EXPOSURE, selectedVariants: VARIANTS)
                        } else {
                          try AppleHNCSStudy.run(sourceURL: source, directory: directory, label: "LABEL", rounds: ROUNDS,
                                              direct: DIRECT, preset: "PRESET", workingSpace: .SPACE,
                                              exposureEV: EXPOSURE, comparePaths: COMPARE, runID: "RUN_ID",
                                              deferCompletion: VERIFY_LIVE)
                        if VERIFY_LIVE {
                            try await AppleHNCSStudy.verifyLiveCapture(sourceURL: source, directory: directory)
                        }
                        }
                        return "Complete. Results saved in Documents/LABEL."
                    } catch { return "Failed: \\(error.localizedDescription)" }
                }.value
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}
'''.replace("LABEL", args.label).replace("ROUNDS", str(args.rounds))
        .replace("DIRECT", "true" if args.direct else "false").replace("PRESET", args.preset).replace("SPACE", args.working_space)
        .replace("EXPOSURE", str(args.exposure_ev)).replace("COMPARE", "true" if args.compare_paths else "false")
        .replace("RUN_ID", args.run_id).replace("VERIFY_LIVE", "true" if args.verify_live_capture else "false")
        .replace("INPUT_STUDY", "true" if args.input_study else "false")
        .replace("VARIANTS", json.dumps(args.input_variants)))
    # Absolute file references intentionally compile the current production files.
    sources = [ROOT / "ios/GlassCam" / name for name in SWIFT]
    sources += [ROOT / "core" / name for name in CPP]
    sources += [ROOT / "tools/apple_hncs_study.swift", ROOT / "tools/apple_raw_input_study.swift", entry]
    objects = {}
    def obj(isa, **values):
        identifier = f"{len(objects) + 1:024X}"
        objects[identifier] = dict(isa=isa, **values)
        return identifier
    refs = []
    builds = []
    for source in sources:
        ref = obj("PBXFileReference", path=str(source), sourceTree="<absolute>",
                  lastKnownFileType="sourcecode.swift" if source.suffix == ".swift" else "sourcecode.cpp.cpp")
        refs.append(ref)
        builds.append(obj("PBXBuildFile", fileRef=ref))
    import shutil
    shutil.copy2(args.raw_source, work / "source.dng")
    resource = obj("PBXFileReference", path=str(work / "source.dng"), sourceTree="<absolute>", lastKnownFileType="image.dng")
    resource_build = obj("PBXBuildFile", fileRef=resource)
    product = obj("PBXFileReference", path="HNCSStudy.app", sourceTree="BUILT_PRODUCTS_DIR", explicitFileType="wrapper.application")
    group = obj("PBXGroup", children=refs + [resource, product], sourceTree="<group>")
    source_phase = obj("PBXSourcesBuildPhase", buildActionMask="2147483647", files=builds, runOnlyForDeploymentPostprocessing="0")
    resources = obj("PBXResourcesBuildPhase", buildActionMask="2147483647", files=[resource_build], runOnlyForDeploymentPostprocessing="0")
    frameworks = obj("PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0")
    settings = dict(SDKROOT="iphoneos", IPHONEOS_DEPLOYMENT_TARGET="27.0", SWIFT_VERSION="5.0",
        SWIFT_OPTIMIZATION_LEVEL="-O", SWIFT_COMPILATION_MODE="wholemodule", CLANG_CXX_LANGUAGE_STANDARD="c++17",
        OTHER_CPLUSPLUSFLAGS=["-O3", "-fno-fast-math", "-ffp-contract=off"], OTHER_LDFLAGS=["-lz"],
        HEADER_SEARCH_PATHS=[str(ROOT / "core")], SWIFT_OBJC_BRIDGING_HEADER=str(ROOT / "ios/GlassCam/GlassCam-Bridging-Header.h"),
        PRODUCT_NAME="HNCSStudy", PRODUCT_BUNDLE_IDENTIFIER="dev.glasscam.prototype.hncsstudy",
        CODE_SIGN_STYLE="Automatic", DEVELOPMENT_TEAM=args.team, GENERATE_INFOPLIST_FILE="YES",
        INFOPLIST_KEY_CFBundleDisplayName="HNCS Study", INFOPLIST_KEY_UILaunchScreen_Generation="YES",
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation="YES", TARGETED_DEVICE_FAMILY="1", SUPPORTED_PLATFORMS="iphoneos",
        ALWAYS_SEARCH_USER_PATHS="NO")
    target_config = obj("XCBuildConfiguration", name="Release", buildSettings=settings)
    target_configs = obj("XCConfigurationList", buildConfigurations=[target_config], defaultConfigurationName="Release", defaultConfigurationIsVisible="0")
    target = obj("PBXNativeTarget", name="HNCSStudy", productName="HNCSStudy", productType="com.apple.product-type.application",
                 productReference=product, buildConfigurationList=target_configs, buildPhases=[source_phase, frameworks, resources], dependencies=[], buildRules=[])
    project_config = obj("XCBuildConfiguration", name="Release", buildSettings={})
    project_configs = obj("XCConfigurationList", buildConfigurations=[project_config], defaultConfigurationName="Release", defaultConfigurationIsVisible="0")
    project = obj("PBXProject", buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en",
                  mainGroup=group, targets=[target], projectDirPath="", projectRoot="", knownRegions=["en", "Base"], attributes={"LastUpgradeCheck": "2700"})
    def encode(value):
        if isinstance(value, dict):
            return "{\n" + "\n".join(f"{json.dumps(str(k))} = {encode(v)};" for k, v in value.items()) + "\n}"
        if isinstance(value, list): return "(" + ",".join(encode(x) for x in value) + ")"
        return json.dumps(str(value))
    directory = work / "HNCSStudy.xcodeproj"
    directory.mkdir(exist_ok=True)
    (directory / "project.pbxproj").write_text(encode(dict(archiveVersion="1", objectVersion="56", classes={}, objects=objects, rootObject=project)))
    print(directory)


def run_ios(args, work):
    log_path = args.output_dir / "build.log"
    derived = args.output_dir / "DerivedData"
    print(f"Building iPhone study; log: {log_path}", flush=True)
    with log_path.open("w") as log:
        result = subprocess.run(["xcodebuild", "-project", str(work / "HNCSStudy.xcodeproj"),
            "-scheme", "HNCSStudy", "-configuration", "Release", "-destination", f"id={args.run_ios}",
            "-derivedDataPath", str(derived), "-allowProvisioningUpdates", "build"],
            stdout=log, stderr=subprocess.STDOUT, timeout=300)
    if result.returncode:
        raise SystemExit(f"iPhone build failed; see {log_path}")
    device = ["xcrun", "devicectl", "device"]
    bundle = "dev.glasscam.prototype.hncsstudy"
    app = derived / "Build/Products/Release-iphoneos/HNCSStudy.app"
    call(*device, "install", "app", "--device", args.run_ios, "--timeout", "45", app)
    # --console waits indefinitely for a SwiftUI app that intentionally stays open.
    call(*device, "process", "launch", "--device", args.run_ios, "--timeout", "30",
         "--terminate-existing", bundle)
    output = args.output_dir / args.label
    output.mkdir(exist_ok=True)
    report_path = output / "report.json"
    deadline = time.monotonic() + args.timeout
    last_status = None
    last_error = "No report received"
    while time.monotonic() < deadline:
        result = subprocess.run([*device, "copy", "from", "--device", args.run_ios, "--timeout", "15",
            "--domain-type", "appDataContainer", "--domain-identifier", bundle,
            "--source", f"Documents/{args.label}/report.json", "--destination", str(report_path)],
            capture_output=True, text=True, timeout=20)
        if result.returncode == 0:
            report = json.loads(report_path.read_text())
            # A prior run with the same label must not satisfy this run's checks.
            if report.get("run_id") == args.run_id:
                status = report.get("status")
                if status != last_status:
                    print(f"iPhone: {status}", flush=True)
                    last_status = status
                if status == "complete":
                    print(f"Verified report: {report_path}", flush=True)
                    return
                if status == "failed":
                    raise SystemExit(f"iPhone study failed: {report.get('error')}; see {report_path}")
        else:
            last_error = result.stderr.strip() or result.stdout.strip()
        time.sleep(2)
    raise SystemExit(f"iPhone study timed out after {args.timeout}s; last status: {last_status}; {last_error}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-source", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--label", default="baseline")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--direct", action="store_true", help="Measure direct RAW export without the discarded preview")
    parser.add_argument("--preset", choices=["standard", "nature"], default="standard")
    parser.add_argument("--working-space", choices=["legacy", "lstar"], default="legacy")
    parser.add_argument("--exposure-ev", type=float, default=0)
    parser.add_argument("--compare-paths", action="store_true", help="Interleave both export routes in this build and require identical output")
    parser.add_argument("--verify-live-capture", action="store_true", help="Verify actual automatic processing, retention fallback, and save retry with camera/Photos stubs")
    parser.add_argument("--input-study", action="store_true", help="Produce full-source current/scene-linear RAW input comparisons and decoder probes")
    parser.add_argument("--input-variants", nargs="+", choices=["current", "scene", "scene-baseline", "scene-hdr-baseline", "scene-hdr-aligned"],
                        default=["current", "scene", "scene-baseline", "scene-hdr-baseline"])
    parser.add_argument("--prepare-ios", action="store_true")
    parser.add_argument("--run-ios", metavar="DEVICE", help="Build and run on this connected iPhone, collecting the completed report")
    parser.add_argument("--timeout", type=int, default=600, help="Device report deadline in seconds")
    parser.add_argument("--team", default="")
    args = parser.parse_args()
    if not args.label.replace("-", "").replace("_", "").isalnum() or not 1 <= args.rounds <= 10:
        parser.error("Use an alphanumeric label and 1–10 rounds")
    if not -5 <= args.exposure_ev <= 5 or not 30 <= args.timeout <= 1800:
        parser.error("Use exposure EV within -5…5 and a timeout within 30…1800 seconds")
    if args.prepare_ios and args.run_ios:
        parser.error("Choose --prepare-ios or --run-ios")
    if (args.prepare_ios or args.run_ios) and not args.team:
        parser.error("iPhone builds require --team")
    args.run_id = str(uuid.uuid4())
    args.raw_source = args.raw_source.resolve(strict=True)
    args.output_dir = args.output_dir.resolve()
    work = args.output_dir / "build"
    work.mkdir(parents=True, exist_ok=True)
    inputs = [*(ROOT / "ios/GlassCam" / name for name in SWIFT), *(ROOT / "core" / name for name in CPP),
              *sorted((ROOT / "core").glob("*.h")), *sorted((ROOT / "core").glob("*.hpp")), *sorted((ROOT / "core").glob("*.inc")),
              ROOT / "ios/GlassCam/GlassCam-Bridging-Header.h", ROOT / "tools/apple_hncs_study.swift", ROOT / "tools/apple_raw_input_study.swift"]
    manifest = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    (args.output_dir / "source-sha256.json").write_text(json.dumps(manifest, indent=2))
    (args.output_dir / "run-config.json").write_text(json.dumps({key: str(value) if isinstance(value, Path) else value
        for key, value in vars(args).items()}, indent=2))
    if args.prepare_ios or args.run_ios:
        prepare_ios(args, work)
        if args.run_ios:
            run_ios(args, work)
        return
    library = work / "libstudy.dylib"
    call("xcrun", "clang++", "-std=c++17", "-O3", "-fno-fast-math", "-ffp-contract=off", "-dynamiclib",
         *(ROOT / "core" / name for name in CPP), "-lz", "-pthread", "-o", library)
    entry = work / "StudyMain.swift"
    entry.write_text('''import Foundation
@main struct StudyMain {
    static func main() async throws {
        let args = CommandLine.arguments
        if args[12] == "1" {
            try AppleRAWInputStudy.run(sourceURL: URL(fileURLWithPath: args[1]), directory: URL(fileURLWithPath: args[2]),
                                      label: args[3], runID: args[10], exposureEV: Double(args[8])!, selectedVariants: args[13].components(separatedBy: ","))
            return
        }
        try AppleHNCSStudy.run(sourceURL: URL(fileURLWithPath: args[1]), directory: URL(fileURLWithPath: args[2]),
                              label: args[3], rounds: Int(args[4])!, direct: args[5] == "1",
                              preset: args[6], workingSpace: HNCSWorkingSpace(rawValue: args[7])!,
                              exposureEV: Double(args[8])!, comparePaths: args[9] == "1", runID: args[10],
                              deferCompletion: args[11] == "1")
        if args[11] == "1" {
            try await AppleHNCSStudy.verifyLiveCapture(sourceURL: URL(fileURLWithPath: args[1]),
                                                     directory: URL(fileURLWithPath: args[2]))
        }
    }
}
''')
    call("xcrun", "swiftc", "-swift-version", "5", "-O", "-module-cache-path", work / "modules",
         "-I", ROOT / "core", "-import-objc-header", ROOT / "ios/GlassCam/GlassCam-Bridging-Header.h",
         *(ROOT / "ios/GlassCam" / name for name in SWIFT), ROOT / "tools/apple_hncs_study.swift", ROOT / "tools/apple_raw_input_study.swift", entry,
         "-L", work, "-lstudy", "-Xlinker", "-rpath", "-Xlinker", work, "-o", work / "study")
    call(work / "study", args.raw_source, args.output_dir / args.label, args.label, args.rounds,
         "1" if args.direct else "0", args.preset, args.working_space, args.exposure_ev,
         "1" if args.compare_paths else "0", args.run_id, "1" if args.verify_live_capture else "0", "1" if args.input_study else "0", ",".join(args.input_variants))


if __name__ == "__main__":
    main()
