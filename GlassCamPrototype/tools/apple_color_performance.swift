// Mac-only measurement of the actual production RAW -> HDR HEIF pipeline.
// No camera capture, phone installation, or Photos transactions.
import Foundation
import CoreImage
import ImageIO
import CryptoKit
import Metal
import Darwin

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func cpuSeconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
}
private func peakRSS() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return UInt64(usage.ru_maxrss)
}
private final class ProgressMarks: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var marks = [String: Double]()
    func record(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        for level in [0.0, 0.1, 0.45, 0.65, 0.85, 0.9, 1.0] {
            let key = String(level)
            if value + 1e-10 >= level && marks[key] == nil {
                marks[key] = ProcessInfo.processInfo.systemUptime - started
            }
        }
    }
    var values: [String: Double] { lock.lock(); defer { lock.unlock() }; return marks }
}
private func decodedEvidence(_ url: URL) throws -> [String: Any] {
    guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
          let color = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    else { throw PipelineError.invalidImage }
    let width = Int(image.extent.width), height = Int(image.extent.height)
    let context = CIContext(options: [.workingColorSpace: color, .workingFormat: CIFormat.RGBAf.rawValue,
                                      .cacheIntermediates: false])
    var hash = SHA256(), peak: Float = 0, minimum: Float = .infinity
    for y in stride(from: 0, to: height, by: 64) {
        let rows = min(64, height - y)
        var pixels = [Float](repeating: 0, count: width * rows * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                bounds: CGRect(x: 0, y: y, width: width, height: rows), format: .RGBAf, colorSpace: color)
        }
        pixels.withUnsafeBytes { hash.update(bufferPointer: $0) }
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 { peak = max(peak, pixels[index + channel]); minimum = min(minimum, pixels[index + channel]) }
        }
    }
    return ["rgba_float32_sha256": hash.finalize().map { String(format: "%02x", $0) }.joined(),
            "width": width, "height": height, "linear_rgb_peak": peak, "linear_rgb_minimum": minimum,
            "bits_per_channel": properties[kCGImagePropertyDepth as String] ?? NSNull(),
            "profile": properties[kCGImagePropertyProfileName as String] ?? ""]
}

@main enum ColorPerformanceMain {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 6 else { throw PipelineError.invalidImage }
        let sourceURL = URL(fileURLWithPath: args[1]), directory = URL(fileURLWithPath: args[2])
        let name = args[3], variant = args[4], rounds = Int(args[5])!
        let requestedBackend: Int32 = variant == "metal-color" ? 2 : (variant == "metal-matrix" ? 1 : 0)
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "color_study_select_backend") {
            typealias SelectBackend = @convention(c) (Int32) -> Void
            unsafeBitCast(symbol, to: SelectBackend.self)(requestedBackend)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: sourceURL)
        let hncsMode = name.hasPrefix("hncs-")
        var hncs = HNCSSettings.standard
        hncs.presetKey = name == "hncs-nature" ? "nature" : "standard"
        hncs.workingSpace = .lstar
        let recipe = ProcessingRecipe(mode: hncsMode ? .hncs : .ffcs, exposureEV: -0.05,
            illuminantKelvin: 6500, simulationIndex: name == "ffcs-acros" ? 8 : 0, seed: 0, hncs: hncs)
        let info = ProcessInfo.processInfo
        var report: [String: Any] = ["status": "running", "configuration": name, "variant": variant,
            "os": info.operatingSystemVersionString, "logical_cpus": info.processorCount,
            "gpu": MTLCreateSystemDefaultDevice()?.name ?? "none", "thermal_start": info.thermalState.rawValue,
            "low_power": info.isLowPowerModeEnabled, "source_sha256": digest(data), "source_bytes": data.count,
            "recipe": String(data: try JSONEncoder().encode(recipe), encoding: .utf8)!,
            "scope": "Mac production retain + RAW/HDR processing + HEIF + review decode; excludes camera and Photos."]
        var captures = [[String: Any]]()
        func publish() throws {
            report["captures"] = captures
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        }
        try publish()
        for round in 0...rounds {
            for megapixels in round % 2 == 0 ? [48, 24] : [24, 48] {
                let row: [String: Any] = try autoreleasepool {
                    var times = [String: Double]()
                    func timed<T>(_ key: String, _ operation: () throws -> T) rethrows -> T {
                        let start = info.systemUptime
                        defer { times[key] = info.systemUptime - start }
                        return try operation()
                    }
                    let path = directory.appendingPathComponent("round-\(round)-\(megapixels)mp.heic")
                    let output: ExportSettings = megapixels == 48 ? .native : .init(targetWidth: 5656, targetHeight: 4242)
                    let started = info.systemUptime, cpuStart = cpuSeconds()
                    let retained = try timed("retain") { try SourceImageFile(data: data, fileExtension: "dng") }
                    let progress = ProgressMarks()
                    _ = try timed("full_export") {
                        try ImagePipeline.writeHEIF(sourceFile: retained, recipe: recipe, to: path,
                            settings: output, progress: { progress.record($0) })
                    }
                    let review = try timed("review_decode") {
                        try ImagePipeline.load(data: Data(contentsOf: path), fileExtension: "heic")
                    }
                    var result: [String: Any] = ["round": round, "cold_or_warmup": round == 0,
                        "megapixels": megapixels, "seconds": times, "total_seconds": info.systemUptime - started,
                        "cpu_seconds": cpuSeconds() - cpuStart, "progress_seconds": progress.values,
                        "process_peak_rss_bytes_before_verification": peakRSS(),
                        "review_dimensions": [review.width, review.height], "thermal": info.thermalState.rawValue,
                        "file": path.path]
                    let encoded = try Data(contentsOf: path)
                    result["encoded_sha256"] = digest(encoded); result["encoded_bytes"] = encoded.count
                    if round == 0 { result["decoded"] = try decodedEvidence(path) }
                    return result
                }
                captures.append(row); try publish()
                print("COLOR-PERF \(variant) \(name) \(megapixels)MP round \(round): \(row["total_seconds"]!) s")
                fflush(stdout)
            }
        }
        report["status"] = "complete"; report["thermal_end"] = info.thermalState.rawValue
        report["process_peak_rss_bytes_including_verification"] = peakRSS()
        if requestedBackend > 0, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "metal_study_stats") {
            typealias Stats = @convention(c) (UnsafeMutablePointer<Double>?, Int) -> Int32
            var values = [Double](repeating: 0, count: 10)
            let code = values.withUnsafeMutableBufferPointer { unsafeBitCast(symbol, to: Stats.self)($0.baseAddress, $0.count) }
            guard code == 0, values[5] > 0, values[3] > 0 else { throw PipelineError.rendering }
            if requestedBackend == 2 && values[9] != values[5] { throw PipelineError.rendering }
            report["metal_study"] = Dictionary(uniqueKeysWithValues: zip(
                ["compile_seconds", "copy_seconds", "submit_wait_seconds", "gpu_timestamp_seconds", "cpu_tail_seconds", "calls", "uploaded_bytes", "cached_buffer_bytes", "unified_memory", "color_calls"], values))
        }
        try publish()
    }
}
