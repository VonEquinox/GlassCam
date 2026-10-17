// Diagnostic harness shared by a macOS runner and an isolated iPhone test app.
// Reads an existing RAW; it never captures a photo or writes to the Photos library.
import Foundation
import CoreImage
import ImageIO
import Metal
import CryptoKit

enum AppleHNCSStudy {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func run(sourceURL: URL, directory: URL, label: String, rounds: Int = 3,
                    direct: Bool = false, preset: String = "standard", workingSpace: HNCSWorkingSpace = .legacy,
                    exposureEV: Double = 0, comparePaths: Bool = false, runID: String = UUID().uuidString,
                    deferCompletion: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = ProcessInfo.processInfo
        var report: [String: Any] = ["label": label, "run_id": runID, "os": info.operatingSystemVersionString,
            "cpu_count": info.processorCount, "thermal_start": info.thermalState.rawValue,
            "export_path": comparePaths ? "paired_current_build" : (direct ? "direct" : "preview_then_export"),
            "preset": preset, "working_space": workingSpace.rawValue, "exposure_ev": exposureEV,
            "low_power": info.isLowPowerModeEnabled, "scope": "Existing RAW bytes through automatic processing, HEIF and review decode; camera and Photos transaction excluded"]
        var captures = [[String: Any]]()
        func publish(_ status: String) throws {
            report["status"] = status; report["captures"] = captures
            let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            print("HNCS-STUDY \(status)"); fflush(stdout)
        }
        try publish("starting")
        do {
            let data = try Data(contentsOf: sourceURL)
            report["source_bytes"] = data.count
            report["source_sha256"] = digest(data)
            let input = try ImagePipeline.load(data: data, fileExtension: "dng")
            report["preview_width"] = input.width; report["preview_height"] = input.height
            report["white_balance"] = input.whiteBalance.description
            report["white_xy"] = [input.whiteBalance.x, input.whiteBalance.y]
            report["source_hdr_fraction"] = stride(from: 0, to: input.linearRGB.count, by: 3).reduce(0) {
                $0 + (max(input.linearRGB[$1], input.linearRGB[$1 + 1], input.linearRGB[$1 + 2]) > 1 ? 1 : 0)
            }.double / Double(input.width * input.height)
            try writeRaster(input.original, name: "apple-decoded", directory: directory)
            for key in ["standard", "nature"] {
                var hncs = HNCSSettings.standard; hncs.presetKey = key; hncs.workingSpace = workingSpace
                let recipe = ProcessingRecipe(mode: .hncs, exposureEV: exposureEV, illuminantKelvin: 6500,
                    simulationIndex: 0, seed: 0, hncs: hncs)
                let started = info.systemUptime
                let rendered = try ImagePipeline.process(input, recipe: recipe)
                report["\(key)_preview_seconds"] = info.systemUptime - started
                report["\(key)_uses_spatial"] = hncs.requiresSpatial(effects: .standard)
                try writeRaster(rendered.image, name: key, directory: directory)
            }
            report["cpu_kernel"] = try kernelBenchmarks(white: input.whiteBalance)
            if let device = MTLCreateSystemDefaultDevice() {
                report["gpu"] = device.name
                do {
                    _ = try device.makeLibrary(source: "#include <metal_stdlib>\nusing namespace metal;\nkernel void fp64(device double *v [[buffer(0)]], uint i [[thread_position_in_grid]]) { v[i] *= 0.5; }", options: nil)
                    report["metal_fp64"] = "compiled"
                } catch { report["metal_fp64"] = error.localizedDescription }
            }
            try publish("color and kernel checks complete")
            var settings = HNCSSettings.standard; settings.presetKey = preset; settings.workingSpace = workingSpace
            let recipe = ProcessingRecipe(mode: .hncs, exposureEV: exposureEV, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 0, hncs: settings)
            for round in 0..<rounds {
                // Alternate output order to reduce systematic cache/order bias.
                for megapixels in round % 2 == 0 ? [48, 24] : [24, 48] {
                  // Both routes use this build's color core. This isolates the
                  // removed preview; it is not a historical before/after build.
                  let paths = comparePaths ? (round % 2 == 0 ? [false, true] : [true, false]) : [direct]
                  for directPath in paths {
                    let path = directPath ? "direct" : "preview_then_export"
                    try publish("processing \(megapixels)MP \(path) round \(round + 1)")
                    let sample = try autoreleasepool { () -> [String: Any] in
                        var times = [String: Double]()
                        func timed<T>(_ name: String, _ action: () throws -> T) rethrows -> T {
                            let start = info.systemUptime
                            defer { times[name] = info.systemUptime - start }
                            return try action()
                        }
                        let output: ExportSettings = megapixels == 48 ? .native : .init(targetWidth: 5656, targetHeight: 4242)
                        let overall = info.systemUptime
                        let retained = try timed("retain") { try SourceImageFile(data: data, fileExtension: "dng") }
                        let file = TemporaryHEIFFile()
                        let marks = StudyProgress()
                        if directPath {
                            _ = try timed("full_export") {
                                try ImagePipeline.writeHEIF(sourceFile: retained, recipe: recipe,
                                    to: file.url, settings: output, progress: { marks.record($0) })
                            }
                        } else {
                            let loaded = try timed("raw_preview_decode") { try ImagePipeline.load(sourceFile: retained, exportSettings: output) }
                            let rendered = try timed("preview_effect") { try ImagePipeline.process(loaded, recipe: recipe) }
                            try timed("full_export") {
                                try ImagePipeline.writeHEIF(rendered, to: file.url, progress: { marks.record($0) })
                            }
                        }
                        let review = try timed("review_decode") { try ImagePipeline.load(data: Data(contentsOf: file.url), fileExtension: "heic") }
                        let elapsed = info.systemUptime - overall
                        var result: [String: Any] = ["megapixels": megapixels, "round": round + 1, "path": path,
                            "seconds": times, "total_seconds": elapsed,
                            "review_dimensions": [review.width, review.height],
                            "thermal": info.thermalState.rawValue, "export_progress_seconds": marks.values]
                        // Verification is deliberately outside the timed processing path.
                        result["encoded_sha256"] = digest(try Data(contentsOf: file.url))
                        if round == 0 { result["decoded_rgba_sha256"] = try decodedDigest(file.url) }
                        return result
                    }
                    captures.append(sample)
                    try publish("completed \(megapixels)MP \(path) round \(round + 1)")
                  }
                }
            }
            if comparePaths {
                var comparisons = [[String: Any]]()
                for megapixels in [24, 48] {
                    let samples = captures.filter { $0["megapixels"] as? Int == megapixels }
                    let encoded = Set(samples.compactMap { $0["encoded_sha256"] as? String })
                    let decoded = Set(samples.compactMap { $0["decoded_rgba_sha256"] as? String })
                    guard samples.count == rounds * 2, encoded.count == 1, decoded.count == 1 else {
                        throw StudyVerificationError("Direct and preview-based exports differ at \(megapixels)MP")
                    }
                    comparisons.append(["megapixels": megapixels, "encoded_files": samples.count,
                        "all_encoded_files_identical": true, "first_pair_decoded_rgba_identical": true])
                }
                report["path_comparison"] = comparisons
            }
            report["thermal_end"] = info.thermalState.rawValue
            try publish(deferCompletion ? "awaiting live capture verification" : "complete")
        } catch {
            report["error"] = error.localizedDescription
            try? publish("failed")
            throw error
        }
    }

    /// Exercise the real automatic workflow, including its actual retain/process
    /// services. Only the camera callback and Photos transaction are substituted.
    @MainActor
    static func verifyLiveCapture(sourceURL: URL, directory: URL) async throws {
        let url = directory.appendingPathComponent("report.json")
        var report = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        func publish(_ status: String) throws {
            report["status"] = status
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: url, options: .atomic)
        }
        do {
            let samples = report["captures"] as! [[String: Any]]
            guard let expected = samples.first(where: { $0["megapixels"] as? Int == 24 })?["encoded_sha256"] as? String,
                  let space = HNCSWorkingSpace(rawValue: report["working_space"] as! String) else {
                throw StudyVerificationError("Missing 24MP comparison or working space")
            }
            let data = try Data(contentsOf: sourceURL)
            var hncs = HNCSSettings.standard
            hncs.presetKey = report["preset"] as! String; hncs.workingSpace = space
            let recipe = ProcessingRecipe(mode: .hncs, exposureEV: report["exposure_ev"] as! Double,
                illuminantKelvin: 6500, simulationIndex: 0, seed: 0, hncs: hncs)
            let snapshot = CaptureSnapshot(recipe: recipe, output: .init(targetWidth: 5656, targetHeight: 4242))
            var checks = [[String: Any]]()
            for memoryFallback in [false, true] {
                try publish("verifying live capture \(memoryFallback ? "memory" : "file")")
                var saves = 0
                var firstFile: TemporaryHEIFFile?
                var sameFile = true
                var services = CaptureWorkflow.Services.live(authorize: {}, save: { file in
                    saves += 1
                    if let firstFile { sameFile = sameFile && firstFile === file }
                    else { firstFile = file }
                    if saves == 1 { throw StudyVerificationError("Injected Photos save failure") }
                })
                if memoryFallback {
                    services.retain = { _ in throw StudyVerificationError("Injected source retention failure") }
                }
                let workflow = CaptureWorkflow(services: services)
                workflow.capture(snapshot: snapshot) { $0(.success(data)) }
                var retried = false
                let deadline = ProcessInfo.processInfo.systemUptime + 180
                while true {
                    if workflow.phase == .failed {
                        guard !retried, saves == 1, workflow.canRetry else {
                            throw StudyVerificationError(workflow.status)
                        }
                        retried = true; workflow.retry()
                    }
                    if workflow.phase == .idle { break }
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw StudyVerificationError("Automatic workflow timed out")
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard let saved = workflow.latest, retried, saves == 2, sameFile,
                      saved.snapshot.recipe.photoWhiteBalance?.origin == .appleRAW,
                      saved.snapshot.recipe == recipe.resolvingWhiteBalance(saved.snapshot.recipe.photoWhiteBalance!),
                      saved.snapshot.output == snapshot.output,
                      saved.width * saved.height <= 5656 * 4242,
                      digest(try Data(contentsOf: saved.file.url)) == expected else {
                    throw StudyVerificationError("Automatic capture changed the recipe, HEIF, or save retry ownership")
                }
                checks.append(["source": memoryFallback ? "memory_fallback" : "retained_file",
                    "encoded_sha256": expected, "matches_pipeline_export": true,
                    "width": saved.width, "height": saved.height, "save_attempts": saves,
                    "retry_reused_same_file": sameFile, "white_balance": saved.snapshot.recipe.photoWhiteBalance!.description])
            }
            report["live_capture_verification"] = checks
            report["live_capture_scope"] = "Production CaptureWorkflow and live retain/process services; injected existing RAW callback and failing/retried Photos stub. No camera capture or Photos writes."
            try publish("complete")
        } catch {
            report["error"] = error.localizedDescription
            try? publish("failed")
            throw error
        }
    }

    static func kernelBenchmarks(white: PhotoWhiteBalance) throws -> [[String: Any]] {
        let count = 8064 * 64
        var state: UInt32 = 928
        let pixels: [Float] = (0..<(count * 3)).map { _ in
            state = state &* 1664525 &+ 1013904223
            return Float(state >> 8) / 16777216
        }
        var result = [[String: Any]]()
        for preset in ["standard", "nature"] {
            guard let context = preset.withCString({ hncs_create_preset_whitepoint(0, white.x, white.y, 0, 0, 0, 4, 2, $0, 1) }) else {
                throw HNCSEngine.Error.invalidSettings
            }
            defer { hncs_destroy(context) }
            var output = [Float](repeating: 0, count: count * 4)
            var times: [UInt32: [Double]] = [1: [], 2: [], 4: []]
            var referenceHash: String?
            for round in 0..<6 {
                let order: [UInt32] = round % 2 == 0 ? [1, 2, 4] : [4, 2, 1]
                for workers in order {
                    let start = ProcessInfo.processInfo.systemUptime
                    let status = pixels.withUnsafeBufferPointer { source in
                        output.withUnsafeMutableBufferPointer { destination in
                            hncs_process_linear_rgba_parallel(context, source.baseAddress, destination.baseAddress, count, workers)
                        }
                    }
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    guard status == 0 else { throw HNCSEngine.Error.invalidPixels }
                    if round > 0 { times[workers]!.append(elapsed) }
                    let hash = output.withUnsafeBytes { digest(Data($0)) }
                    if let referenceHash, hash != referenceHash { throw HNCSEngine.Error.invalidPixels }
                    referenceHash = hash
                }
            }
            result.append(["preset": preset, "pixels_per_call": count,
                "seconds_1_worker": times[1]!, "seconds_2_workers": times[2]!, "seconds_4_workers": times[4]!,
                "all_workers_bit_identical": true, "rgba_sha256": referenceHash!])
        }
        return result
    }

    static func writeRaster(_ raster: PreviewRaster, name: String, directory: URL) throws {
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue])
        let width = raster.width, height = raster.height
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { context.render(raster.image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
            bounds: raster.image.extent, format: .RGBAf, colorSpace: linear) }
        try rgba.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent(name + ".rgba32f")) }
    }

    static func decodedDigest(_ url: URL) throws -> String {
        guard let image = CIImage(contentsOf: url, options: [.expandToHDR: true]) else { throw PipelineError.invalidImage }
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue,
                                          .cacheIntermediates: false])
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var hash = SHA256()
        for start in stride(from: 0, to: height, by: 64) {
            let rows = min(64, height - start)
            var rgba = [Float](repeating: 0, count: width * rows * 4)
            rgba.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                bounds: CGRect(x: 0, y: start, width: width, height: rows), format: .RGBAf, colorSpace: linear) }
            rgba.withUnsafeBytes { hash.update(data: Data($0)) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private struct StudyVerificationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension Int { var double: Double { Double(self) } }

private final class StudyProgress: @unchecked Sendable {
    private let start = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var recorded = [String: Double]()
    var values: [String: Double] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ progress: Double) {
        guard progress == 0 || progress == 0.85 || progress == 0.9 || progress == 1 else { return }
        lock.lock(); defer { lock.unlock() }
        recorded[String(progress)] = ProcessInfo.processInfo.systemUptime - start
    }
}
