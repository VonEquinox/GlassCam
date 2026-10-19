import SwiftUI
import Foundation
import CoreML
import Metal
import ImageIO
import CryptoKit
import Darwin

@main struct NeuralStudyApp: App {
    @State private var status = "Preparing neural hardware study…"
    @State private var started = false
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("GlassCam hardware study").font(.title2)
                Text(status).font(.body.monospacedDigit()).multilineTextAlignment(.center)
            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black).preferredColorScheme(.dark)
            .task {
                guard !started else { return }; started = true
                UIApplication.shared.isIdleTimerDisabled = true
                UIDevice.current.isBatteryMonitoringEnabled = true
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try NeuralRun.run { message in Task { @MainActor in status = message } } }
                }.value
                UIApplication.shared.isIdleTimerDisabled = false
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                switch result {
                case .success: exit(0)
                case .failure(let error): print("NEURAL-STUDY FAILED \(error)"); fflush(stdout); exit(1)
                }
            }
        }
    }
}

private enum NeuralRun {
    static func parsed(_ pointer: UnsafePointer<CChar>?) throws -> [String: Any] {
        guard let pointer, let data = String(cString: pointer).data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PipelineError.rendering }
        if object["status"] as? String == "error" {
            throw NSError(domain: "NeuralStudy", code: 1, userInfo: [NSLocalizedDescriptionKey: object["error"] as? String ?? "Unknown study error"])
        }
        return object
    }
    static func state() -> [String: Any] {
        DispatchQueue.main.sync {
            ["thermal": ProcessInfo.processInfo.thermalState.rawValue,
             "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
             "foreground": UIApplication.shared.applicationState == .active,
             "battery": UIDevice.current.batteryLevel]
        }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func run(update: @escaping @Sendable (String) -> Void) throws {
        let env = ProcessInfo.processInfo.environment
        let phase = env["NEURAL_PHASE"] ?? "probe", runID = env["NEURAL_RUN_ID"] ?? ""
        guard !runID.isEmpty, runID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { throw PipelineError.invalidImage }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inputRoot = documents.appendingPathComponent("NeuralStudyInput")
        let outputRoot = documents.appendingPathComponent("NeuralStudyResults/\(runID)")
        let reportURL = outputRoot.appendingPathComponent("report.json")
        guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let manifestData = try Data(contentsOf: inputRoot.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
        let cases = manifest["cases"] as! [[String: Any]]
        var recipes = [String: ProcessingRecipe]()
        for value in cases {
            recipes[value["preset"] as! String] = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONSerialization.data(withJSONObject: value["recipe"]!))
        }
        let info = ProcessInfo.processInfo
        var rows = [[String: Any]]()
        var report: [String: Any] = ["status": "running", "phase": phase, "run_id": runID,
            "os": info.operatingSystemVersionString, "gpu": MTLCreateSystemDefaultDevice()?.name ?? "none",
            "started_at": ISO8601DateFormatter().string(from: Date()), "initial_state": state(),
            "manifest_sha256": digest(manifestData), "scope": "Research source-matrix/exposure substitution only; existing native colors, gradation, spatial, HDR, RAW and HEIF stages retained. No camera or Photos transaction."]
        func log(_ message: String) { print("NEURAL-STUDY \(message)"); fflush(stdout); update(message) }
        func publish() throws {
            report["rows"] = rows
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        }
        func prepare(_ preset: String, _ shape: String, _ backend: String) throws -> [String: Any] {
            var mode: Int32 = 0, units: Int32 = 0
            var model = "\(preset)-\(shape)-\(backend)"
            if backend.hasPrefix("ml-") {
                let parts = backend.split(separator: "-")
                model = "\(preset)-\(shape)-\(parts[1])"; mode = 1
                units = ["cpu": 0, "ne": 1, "gpu": 2, "all": 3][String(parts[2])]!
            } else { mode = ["cpu": 0, "scalar-fp32": 2, "tensor-fp32": 3, "tensor-fp16": 4, "tensor8-fp32": 5, "tensor8-fp16": 6][backend]! }
            return try inputRoot.path.withCString { root in try model.withCString { name in
                try parsed(neural_study_prepare(root, name, units, mode))
            } }
        }
        func cooldown() -> Double {
            let start = info.systemUptime
            Thread.sleep(forTimeInterval: 5)
            while info.thermalState != .nominal && info.systemUptime - start < 180 {
                log("Cooling; thermal=\(info.thermalState.rawValue)"); Thread.sleep(forTimeInterval: 5)
            }
            return info.systemUptime - start
        }
        func readFloats(_ url: URL) throws -> [Float] {
            try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        try publish()
        do {
            if phase.hasPrefix("trace-") {
                log("Trace attachment window: 25 seconds")
                Thread.sleep(forTimeInterval: 25)
            } else { _ = cooldown() }
            if phase == "probe" || phase == "trace-ane" || phase == "trace-tensor" {
                let pixels = try readFloats(inputRoot.appendingPathComponent("synthetic-rgb.f32"))
                let presets = phase == "probe" ? ["standard", "nature"] : ["standard"]
                var backends = ["cpu", "ml-fp32-cpu", "ml-fp32-ne", "ml-fp32-gpu", "ml-fp32-all",
                                "ml-fp16-cpu", "ml-fp16-ne", "ml-fp16-gpu", "ml-fp16-all",
                                "ml-padded16-cpu", "ml-padded16-ne", "ml-padded16-all",
                                "scalar-fp32", "tensor-fp32", "tensor-fp16", "tensor8-fp32", "tensor8-fp16"]
                if phase == "trace-ane" { backends = ["ml-fp16-cpu", "ml-fp16-ne", "ml-padded16-ne"] }
                if phase == "trace-tensor" { backends = ["scalar-fp32", "tensor-fp32", "tensor-fp16", "tensor8-fp32", "tensor8-fp16"] }
                for preset in presets {
                    let recipe = recipes[preset]!
                    for backend in backends {
                        log("\(phase) \(preset) \(backend)")
                        do {
                            let setup = try prepare(preset, "small", backend)
                            let before = state()
                            var times = [Double](), first = 0.0
                            let repetitions = phase.hasPrefix("trace-") ? 40 : 6
                            // Prime the worker pool and buffers before collecting
                            // the small point-stage measurements.
                            for _ in 0..<5 {
                                _ = try HNCSEngine.presetWork(linearSRGB: pixels, width: 512, height: 256,
                                    exposureEV: recipe.exposureEV, captureKelvin: recipe.illuminantKelvin,
                                    settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance)
                            }
                            _ = try parsed(neural_study_stats(1))
                            for iteration in 0..<repetitions {
                                let start = info.systemUptime
                                _ = try HNCSEngine.presetWork(linearSRGB: pixels, width: 512, height: 256,
                                    exposureEV: recipe.exposureEV, captureKelvin: recipe.illuminantKelvin,
                                    settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance)
                                let elapsed = info.systemUptime - start
                                if iteration == 0 { first = elapsed } else { times.append(elapsed) }
                            }
                            let metrics = try parsed(neural_study_stats(1))
                            let output = try HNCSEngine.exportLinearRGBA(linearSRGB: pixels, width: 512, height: 256,
                                exposureEV: recipe.exposureEV, illuminantKelvin: recipe.illuminantKelvin,
                                settings: recipe.hncs, effects: recipe.effects, whiteBalance: recipe.photoWhiteBalance,
                                baselineSharpness: 1.5)
                            let file = "\(preset)-\(backend).rgba32f"
                            let data = output.withUnsafeBytes { Data($0) }
                            try data.write(to: outputRoot.appendingPathComponent(file), options: .atomic)
                            rows.append(["status": "complete", "preset": preset, "backend": backend, "setup": setup,
                                "point_seconds": times, "first_point_seconds": first, "metrics": metrics,
                                "before": before, "after": state(), "output": file, "sha256": digest(data),
                                "quality_scope": "131072 synthetic pixels; native color/gradation/sharpness/finish included; HDR gains applied during host comparison."])
                        } catch { rows.append(["status": "error", "preset": preset, "backend": backend, "error": String(describing: error)]) }
                        try publish()
                    }
                }
                if phase != "trace-tensor" {
                    for units: Int32 in [0, 1, 2, 3] {
                        log("Dense convolution control units=\(units)")
                        do {
                            let setup = try inputRoot.path.withCString { root in try parsed(neural_study_prepare(root, "dense-control-fp16", units, 1)) }
                            let file = "dense-\(units).bin"
                            let result = try outputRoot.appendingPathComponent(file).path.withCString { path in
                                try parsed(neural_study_dense(phase == "trace-ane" ? 40 : 6, path))
                            }
                            rows.append(["status": "complete", "kind": "dense-control", "units": units, "setup": setup, "result": result, "state": state(), "output": file])
                        } catch { rows.append(["status": "error", "kind": "dense-control", "units": units, "error": String(describing: error)]) }
                        try publish()
                    }
                }
            } else if phase == "full" {
                let preset = env["NEURAL_PRESET"] ?? "standard", backend = env["NEURAL_BACKEND"] ?? "cpu"
                let rounds = Int(env["NEURAL_ROUNDS"] ?? "3")!
                let setup = try prepare(preset, "strip", backend)
                report["setup"] = setup; report["preset"] = preset; report["backend"] = backend
                let raw = try Data(contentsOf: documents.appendingPathComponent("PerformanceInput/source.dng"))
                report["source_sha256"] = digest(raw)
                guard digest(raw) == "4bd1990df9893381b89797d1e761925973c0c840c3cd47dce758635c7502929e" else { throw PipelineError.invalidImage }
                for round in 0...rounds {
                    for megapixels in round % 2 == 0 ? [48, 24] : [24, 48] {
                        let wait = cooldown(), before = state()
                        guard before["foreground"] as? Bool == true else { throw PipelineError.rendering }
                        log("Full \(preset) \(backend) \(megapixels)MP round \(round)")
                        let row: [String: Any] = try autoreleasepool {
                            _ = try parsed(neural_study_stats(1))
                            let timing = PipelineTiming()
                            let file = "round-\(round)-\(megapixels)mp.heic", path = outputRoot.appendingPathComponent("round-\(round)-\(megapixels)mp.heic")
                            let started = info.systemUptime
                            let source = try SourceImageFile(data: raw, fileExtension: "dng")
                            let retain = info.systemUptime - started, exportStart = info.systemUptime
                            let recipe = try ImagePipeline.writeHEIF(sourceFile: source, recipe: recipes[preset]!, to: path,
                                settings: megapixels == 48 ? .native : .init(targetWidth: 5656, targetHeight: 4242), timing: timing)
                            let exportSeconds = info.systemUptime - exportStart, reviewStart = info.systemUptime
                            _ = try ImagePipeline.load(data: Data(contentsOf: path), fileExtension: "heic")
                            let review = info.systemUptime - reviewStart, total = info.systemUptime - started
                            let metrics = try parsed(neural_study_stats(1)), encoded = try Data(contentsOf: path)
                            let meta = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(encoded as CFData, nil)!, 0, nil)! as NSDictionary
                            return ["round": round, "warmup": round == 0, "megapixels": megapixels, "total_seconds": total,
                                "retain_seconds": retain, "export_seconds": exportSeconds, "review_seconds": review,
                                "stages_seconds": timing.seconds, "metrics": metrics, "before": before, "after": state(),
                                "render_thermal_states": timing.thermalStates.sorted(), "cooldown_seconds": wait,
                                "file": file, "sha256": digest(encoded), "bytes": encoded.count,
                                "width": meta[kCGImagePropertyPixelWidth]!, "height": meta[kCGImagePropertyPixelHeight]!,
                                "depth": meta[kCGImagePropertyDepth]!,
                                "resolved_recipe": String(data: try JSONEncoder().encode(recipe), encoding: .utf8)!]
                        }
                        rows.append(row); try publish(); log("Completed \(backend) \(megapixels)MP \(row["total_seconds"]!) s")
                    }
                }
            } else { throw PipelineError.invalidImage }
            report["status"] = "complete"; report["final_state"] = state()
            report["finished_at"] = ISO8601DateFormatter().string(from: Date())
            try publish(); log("REPORT Documents/NeuralStudyResults/\(runID)/report.json")
        } catch {
            report["status"] = "failed"; report["error"] = String(describing: error)
            try? publish(); throw error
        }
    }
}
