#if GLASSCAM_PERFORMANCE
import SwiftUI
import Foundation
import ImageIO
import CoreImage
import CryptoKit
import Metal
import Darwin

/// Compiled only for an explicitly requested Release device benchmark. It
/// calls the production export/review APIs without a camera session or Photos
/// transaction, and writes every sample before starting the next one.
struct DevicePerformanceView: View {
    let resources: ColorResources
    @State private var status = "Preparing device measurement…"
    @State private var started = false
    var body: some View {
        VStack(spacing: 20) {
            Text("GlassCam performance").font(.title2)
            Text(status).font(.body.monospacedDigit()).multilineTextAlignment(.center)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
        .task {
            guard !started else { return }
            started = true
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.isBatteryMonitoringEnabled = true
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DevicePerformance.run(resources: resources) { message in
                    Task { @MainActor in status = message }
                } }
            }.value
            switch result {
            case .success: status = "Measurement complete. Report saved."
            case .failure(let error): status = error.localizedDescription
            }
            UIApplication.shared.isIdleTimerDisabled = false
            // devicectl --console receives a reliable terminal status. This is
            // unreachable in ordinary app builds and ordinary app launches.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            switch result {
            case .success: exit(0)
            case .failure: exit(1)
            }
        }
    }
}

private enum DevicePerformance {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    static func peakRSS() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return UInt64(usage.ru_maxrss)
    }
    static func machine() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }
    static func runtimeState() -> [String: Any] {
        DispatchQueue.main.sync {
            let info = ProcessInfo.processInfo
            return ["thermal": info.thermalState.rawValue,
                    "low_power": info.isLowPowerModeEnabled,
                    "battery_level": UIDevice.current.batteryLevel,
                    "battery_state": UIDevice.current.batteryState.rawValue,
                    "application_state": UIApplication.shared.applicationState.rawValue]
        }
    }
    static func run(resources: ColorResources, update: @escaping @Sendable (String) -> Void) throws {
#if targetEnvironment(simulator)
        throw NSError(domain: "DevicePerformance", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Physical iPhone required."])
#else
        let environment = ProcessInfo.processInfo.environment
        let runID = environment["GLASSCAM_PERFORMANCE_RUN"] ?? ""
        let name = environment["GLASSCAM_PERFORMANCE_CONFIG"] ?? "hncs-standard"
        let rounds = Int(environment["GLASSCAM_PERFORMANCE_ROUNDS"] ?? "5") ?? 5
        let sizes = (environment["GLASSCAM_PERFORMANCE_SIZES"] ?? "48,24").split(separator: ",").compactMap { Int($0) }
        let controls = environment["GLASSCAM_PERFORMANCE_CONTROLS"] != "0"
        guard !runID.isEmpty, runID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              ["hncs-standard", "hncs-nature", "ffcs-provia", "ffcs-acros"].contains(name),
              (0...10).contains(rounds), !sizes.isEmpty, sizes.allSatisfy({ [24, 48].contains($0) }) else {
            throw PipelineError.invalidImage
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sourceURL = documents.appendingPathComponent("PerformanceInput/source.dng")
        let directory = documents.appendingPathComponent("PerformanceResults/\(runID)/\(name)")
        let reportURL = directory.appendingPathComponent("report.json")
        guard !FileManager.default.fileExists(atPath: reportURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = try Data(contentsOf: sourceURL)
        if let expected = environment["GLASSCAM_PERFORMANCE_SOURCE_SHA256"], hash(input) != expected {
            throw PipelineError.invalidImage
        }
        var hncs = HNCSSettings.standard
        hncs.presetKey = name == "hncs-nature" ? "nature" : "standard"
        hncs.workingSpace = .lstar
        let recipe = ProcessingRecipe(mode: name.hasPrefix("hncs-") ? .hncs : .ffcs,
            exposureEV: -0.05, illuminantKelvin: 6500,
            simulationIndex: name == "ffcs-acros" ? 8 : 0, seed: 0, hncs: hncs)
        let info = ProcessInfo.processInfo
        var report: [String: Any] = [
            "status": "running", "run_id": runID, "configuration": name,
            "started_at": ISO8601DateFormatter().string(from: Date()),
            "machine": machine(), "os": info.operatingSystemVersionString,
            "logical_cpus": info.processorCount, "physical_memory_bytes": info.physicalMemory,
            "gpu": MTLCreateSystemDefaultDevice()?.name ?? "none",
            "source_sha256": hash(input), "source_bytes": input.count,
            "recipe": String(data: try JSONEncoder().encode(recipe), encoding: .utf8)!,
            "build": "Release -O; C++ -O3 -fno-fast-math -ffp-contract=off; GLASSCAM_PERFORMANCE",
            "scope": "Physical iPhone, foreground, no debugger: retain RAW + production export + HEIF review decode. Excludes camera capture, Photos save, app launch, input transfer and output hashing. Camera session is not running.",
            "stage_scope": "Non-overlapping synchronous wall spans. color_engine includes Swift bridge/context/buffer work. spatial_sharpness includes its native file I/O. heif_encode_ci includes deferred Core Image resize/color conversion. Unattributed export includes dispatch, autorelease cleanup and instrumentation overhead.",
            "memory_scope": "getrusage process-lifetime peak RSS, not a per-export peak or isolated algorithm allocation.",
            "initial_state": runtimeState(), "warm_rounds_requested": rounds,
            "nominal_wait_limit_seconds": 180, "minimum_between_samples_seconds": 5
        ]
        var samples = [[String: Any]]()
        func publish() throws {
            report["samples"] = samples
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
        }
        func log(_ message: String) {
            print("GLASSCAM-DEVICE-PERF \(message)")
            fflush(stdout)
            update(message)
        }
        func pauseForThermal() -> Double {
            let start = info.systemUptime
            Thread.sleep(forTimeInterval: 5)
            while info.thermalState != .nominal && info.systemUptime - start < 180 {
                log("Waiting for nominal thermal state; current=\(info.thermalState.rawValue)")
                Thread.sleep(forTimeInterval: 5)
            }
            return info.systemUptime - start
        }
        try publish()
        do {
            var schedule = [(round: Int, megapixels: Int, control: Bool)]()
            for round in 0...rounds {
                for size in round % 2 == 0 ? sizes : Array(sizes.reversed()) {
                    schedule.append((round, size, false))
                }
            }
            if controls { for size in sizes { schedule.append((rounds + 1, size, true)) } }
            for (index, item) in schedule.enumerated() {
                let wait = pauseForThermal()
                let stateBefore = runtimeState()
                guard stateBefore["application_state"] as? Int == UIApplication.State.active.rawValue else {
                    throw NSError(domain: "DevicePerformance", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "App left the foreground; timing aborted."])
                }
                log("\(name) \(item.megapixels)MP \(index + 1)/\(schedule.count)\(item.control ? " timing-off control" : "")")
                let sample: [String: Any] = try autoreleasepool {
                    var times = [String: Double]()
                    func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
                        let start = info.systemUptime
                        defer { times[name] = info.systemUptime - start }
                        return try body()
                    }
                    let output = item.megapixels == 48 ? ExportSettings.native : .init(targetWidth: 5656, targetHeight: 4242)
                    let filename = item.control ? "control-\(item.megapixels)mp.heic" : "round-\(item.round)-\(item.megapixels)mp.heic"
                    let path = directory.appendingPathComponent(filename)
                    let timing = item.control ? nil : PipelineTiming()
                    let started = info.systemUptime, cpuStarted = cpuSeconds()
                    let retained = try timed("retain_raw") { try SourceImageFile(data: input, fileExtension: "dng") }
                    let resolved = try timed("full_export") {
                        try ImagePipeline.writeHEIF(resources: resources, sourceFile: retained, recipe: recipe, to: path,
                            settings: output, timing: timing)
                    }
                    let review = try timed("review_decode") {
                        try ImagePipeline.load(data: Data(contentsOf: path), fileExtension: "heic")
                    }
                    let total = info.systemUptime - started
                    let cpu = cpuSeconds() - cpuStarted
                    let stateAfter = runtimeState()
                    let peak = peakRSS()
                    // Evidence generation is deliberately after the timer stops.
                    let encoded = try Data(contentsOf: path)
                    guard let imageSource = CGImageSourceCreateWithData(encoded as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
                          let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
                        throw PipelineError.encoding
                    }
                    let stages = timing?.seconds ?? [:]
                    return ["round": item.round, "megapixels": item.megapixels,
                        "warmup": item.round == 0, "first_export_in_process": index == 0,
                        "timing_off_control": item.control, "seconds": times,
                        "stages_seconds": stages, "stage_calls": timing?.calls ?? [:],
                        "stage_first_seconds": timing?.firstSeconds ?? [:],
                        "stage_maximum_seconds": timing?.maximumSeconds ?? [:],
                        "thermal_states_during_render": (timing?.thermalStates ?? []).sorted(),
                        "export_unattributed_seconds": item.control ? 0 : times["full_export"]! - stages.values.reduce(0, +),
                        "total_seconds": total, "cpu_seconds": cpu,
                        "state_before": stateBefore, "state_after": stateAfter,
                        "thermal_wait_seconds": wait, "process_lifetime_peak_rss_bytes": peak,
                        "review_dimensions": [review.width, review.height], "output_dimensions": [width, height],
                        "output_depth": properties[kCGImagePropertyDepth as String] ?? NSNull(),
                        "output_profile": properties[kCGImagePropertyProfileName as String] ?? "",
                        "output_is_hdr": CIImage(contentsOf: path)?.colorSpace?.isHDR() == true,
                        "encoded_bytes": encoded.count, "encoded_sha256": hash(encoded), "file": filename,
                        "resolved_recipe": String(data: try JSONEncoder().encode(resolved), encoding: .utf8)!]
                }
                samples.append(sample)
                try publish()
                log("Completed \(name) \(item.megapixels)MP: \(sample["total_seconds"]!) s, thermal \(stateBefore["thermal"]!) → \((sample["state_after"] as! [String: Any])["thermal"]!)")
            }
            report["status"] = "complete"
            report["finished_at"] = ISO8601DateFormatter().string(from: Date())
            report["final_state"] = runtimeState()
            try publish()
            log("REPORT Documents/PerformanceResults/\(runID)/\(name)/report.json")
        } catch {
            report["status"] = "failed"
            report["error"] = String(describing: error)
            try? publish()
            log("FAILED \(error)")
            throw error
        }
#endif
    }
}
#endif
