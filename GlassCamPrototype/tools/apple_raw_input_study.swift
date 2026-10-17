// Full-source RAW input study. Uses production HNCS/export, with an explicit
// no-HNCS diagnostic writer. No camera or Photos API is called.
import Foundation
import CoreImage
import ImageIO
import Metal

enum AppleRAWInputStudy {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!

    static func run(sourceURL: URL, directory: URL, label: String, runID: String,
                    exposureEV: Double = -0.05,
                    selectedVariants: [String] = ["current", "scene", "scene-baseline", "scene-hdr-baseline"]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: sourceURL)
        let source = try SourceImageFile(data: data, fileExtension: "dng")
        let initial = try ImagePipeline.inspectRAW(sourceFile: source)
        let defaults = initial["defaults"] as! [String: Any]
        let baseline = (defaults["baseline_exposure"] as! NSNumber).doubleValue
        let version = defaults["decoder_version"] as! String
        var variants: [(String, RAWDecodeRecipe)] = [
            ("current", RAWDecodeRecipe(decoderVersion: version)),
            ("scene", RAWDecodeRecipe(rendering: .sceneLinear, decoderVersion: version)),
            ("scene-baseline", RAWDecodeRecipe(rendering: .sceneLinear, decoderVersion: version, linearExposureEV: baseline)),
            ("scene-hdr-baseline", RAWDecodeRecipe(rendering: .sceneLinear, decoderVersion: version, linearExposureEV: baseline, edrAmount: 1))]
        let supported = variants.map { $0.0 } + ["scene-hdr-aligned"]
        guard !selectedVariants.isEmpty, selectedVariants.allSatisfy({ supported.contains($0) }) else {
            throw RawInputError("Unknown or empty RAW variants")
        }
        var alignment: [String: Any]?
        if selectedVariants.contains("scene-hdr-aligned") {
            let measured = try midtoneAlignment(source: source, decoderVersion: version, baseline: baseline)
            alignment = measured.report
            variants.append(("scene-hdr-aligned", RAWDecodeRecipe(rendering: .sceneLinear,
                decoderVersion: version, linearExposureEV: baseline + measured.ev, edrAmount: 1)))
        }
        var report: [String: Any] = ["label": label, "run_id": runID,
            "source_sha256": AppleHNCSStudy.digest(data), "source_bytes": data.count,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "cpu_count": ProcessInfo.processInfo.processorCount,
            "gpu": MTLCreateSystemDefaultDevice()?.name ?? "unavailable",
            "exposure_ev": exposureEV, "working_space": "lstar", "baseline_compensation_ev": baseline,
            "scope": "One retained RAW, full-source 24MP exports; same decoder version and captured white point. No colorimetric or Hasselblad reference measurement."]
        if let alignment { report["exposure_alignment"] = alignment }
        var configuration = [String: Any]()
        var sourceSamples = [String: Any]()
        var outputs = [[String: Any]]()
        func publish(_ status: String) throws {
            report["status"] = status; report["configurations"] = configuration
            report["source_samples"] = sourceSamples; report["outputs"] = outputs
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            print("RAW-INPUT \(status)"); fflush(stdout)
        }
        try publish("starting input study")
        do {
            var white: PhotoWhiteBalance?
            for (name, rawRecipe) in variants where selectedVariants.contains(name) {
                try publish("decoding \(name)")
                try autoreleasepool {
                    configuration[name] = try ImagePipeline.inspectRAW(sourceFile: source, recipe: rawRecipe)
                    let input = try ImagePipeline.load(sourceFile: source,
                        exportSettings: .init(targetWidth: 5656, targetHeight: 4242), rawDecode: rawRecipe)
                    if let white, white != input.whiteBalance { throw RawInputError("Decode candidate changed captured white point") }
                    white = input.whiteBalance
                    try AppleHNCSStudy.writeRaster(input.original, name: name + "-input", directory: directory)
                    sourceSamples[name] = ["width": input.width, "height": input.height,
                        "rgba_file": name + "-input.rgba32f", "white_balance": input.whiteBalance.description,
                        "white_xy": [input.whiteBalance.x, input.whiteBalance.y], "statistics": statistics(input.linearRGB)]
                    for look in ["none", "standard", "nature"] {
                        try publish("exporting \(name) \(look)")
                        let output = try autoreleasepool { () -> [String: Any] in
                            let stem = name + "-" + look
                            let url = directory.appendingPathComponent(stem + ".heic")
                            let start = ProcessInfo.processInfo.systemUptime
                            var bridge: [String: Any] = [:]
                            var parity: Any = NSNull()
                            if look == "none" {
                                try writeUnstyled(input, to: url, exposureEV: exposureEV)
                            } else {
                                var hncs = HNCSSettings.standard
                                hncs.presetKey = look; hncs.workingSpace = .lstar
                                let recipe = ProcessingRecipe(mode: .hncs, exposureEV: exposureEV,
                                    illuminantKelvin: 6500, simulationIndex: 0, seed: 0, hncs: hncs)
                                let bound = try ImagePipeline.writeHEIF(sourceFile: source, recipe: recipe,
                                    to: url, settings: input.exportSettings, rawDecode: input.rawDecode)
                                guard bound.photoWhiteBalance == input.whiteBalance else { throw RawInputError("Export changed captured WB") }
                                bridge = try bridgeParameters(preset: look, white: input.whiteBalance, exposureEV: exposureEV)
                                // A preview must retain the selected RAW recipe for a later full export.
                                let processed = try ImagePipeline.process(input, recipe: recipe)
                                let oracle = TemporaryHEIFFile()
                                try ImagePipeline.writeHEIF(processed, to: oracle.url)
                                let directHash = AppleHNCSStudy.digest(try Data(contentsOf: url))
                                let previewHash = AppleHNCSStudy.digest(try Data(contentsOf: oracle.url))
                                guard directHash == previewHash else { throw RawInputError("Direct/preview RAW recipe mismatch: \(stem)") }
                                parity = true
                            }
                            let seconds = ProcessInfo.processInfo.systemUptime - start
                            let encoded = try Data(contentsOf: url)
                            let review = try ImagePipeline.load(data: encoded, fileExtension: "heic")
                            try AppleHNCSStudy.writeRaster(review.original, name: stem + "-final", directory: directory)
                            guard let container = CGImageSourceCreateWithURL(url as CFURL, nil),
                                  let props = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any],
                                  let width = props[kCGImagePropertyPixelWidth as String] as? NSNumber,
                                  let height = props[kCGImagePropertyPixelHeight as String] as? NSNumber,
                                  let depth = props[kCGImagePropertyDepth as String] as? NSNumber,
                                  min(width.intValue, height.intValue) == 4242,
                                  max(width.intValue, height.intValue) == 5656, depth.intValue == 10,
                                  CIImage(contentsOf: url)?.colorSpace?.isHDR() == true else {
                                throw RawInputError("Invalid 24MP HDR result: \(stem)")
                            }
                            return ["variant": name, "look": look, "file": stem + ".heic",
                                "width": width, "height": height, "depth": depth,
                                "review_width": review.width, "review_height": review.height,
                                "review_rgba_file": stem + "-final.rgba32f", "encoded_sha256": AppleHNCSStudy.digest(encoded),
                                "statistics": statistics(review.linearRGB), "bridge": bridge,
                                "preview_export_identical": parity, "diagnostic_seconds_including_parity": seconds]
                        }
                        outputs.append(output)
                    }
                }
            }
            try publish("checking decoder exposure and EDR behavior")
            let neutral = try ImagePipeline.load(sourceFile: source, exportSettings: .native,
                rawDecode: RAWDecodeRecipe(rendering: .sceneLinear, decoderVersion: version))
            var probes = [[String: Any]]()
            for ev: Float in [-1, 1] {
                let input = try ImagePipeline.load(sourceFile: source, exportSettings: .native,
                    rawDecode: RAWDecodeRecipe(rendering: .sceneLinear, decoderVersion: version, decoderExposureEV: ev))
                guard input.whiteBalance == neutral.whiteBalance && input.width == neutral.width && input.height == neutral.height else {
                    throw RawInputError("Exposure probe changed geometry or captured WB")
                }
                let gain = Float(pow(2, Double(ev)))
                var count = 0, maximum: Float = 0, sum = 0.0, relative = 0.0
                for (reference, actual) in zip(neutral.linearRGB, input.linearRGB) where reference > 0.001 && reference < 0.4 {
                    let expected = reference * gain, error = abs(actual - expected)
                    count += 1; maximum = max(maximum, error); sum += Double(error)
                    relative += Double(error / expected)
                }
                guard count > 0 else { throw RawInputError("No valid exposure probe samples") }
                probes.append(["decoder_exposure_ev": ev, "channels": count,
                    "max_absolute_error_from_expected_gain": maximum,
                    "mean_absolute_error": sum / Double(count), "mean_relative_error": relative / Double(count)])
            }
            let edr = try ImagePipeline.load(sourceFile: source, exportSettings: .native,
                rawDecode: RAWDecodeRecipe(rendering: .sceneLinear, decoderVersion: version, edrAmount: 1))
            var edrMaximum: Float = 0
            var edrLowMaximum: Float = 0, edrHighChannels = 0, edrLowChannels = 0
            guard edr.linearRGB.count == neutral.linearRGB.count else { throw RawInputError("EDR probe geometry changed") }
            for (a, b) in zip(edr.linearRGB, neutral.linearRGB) {
                edrMaximum = max(edrMaximum, abs(a - b))
                if b < 0.9 { edrLowMaximum = max(edrLowMaximum, abs(a - b)); edrLowChannels += 1 }
                else { edrHighChannels += 1 }
            }
            report["decoder_exposure_probes"] = probes
            report["neutral_edr0_vs_edr1_max_absolute_error"] = edrMaximum
            report["neutral_edr_probe"] = ["edr0": statistics(neutral.linearRGB), "edr1": statistics(edr.linearRGB),
                "below_0_9_channels": edrLowChannels, "below_0_9_max_absolute_error": edrLowMaximum,
                "at_or_above_0_9_channels": edrHighChannels]
            report["thermal_end"] = ProcessInfo.processInfo.thermalState.rawValue
            try publish("complete")
        } catch {
            report["error"] = error.localizedDescription
            try? publish("failed")
            throw error
        }
    }

    /// A single diagnostic exposure scalar, measured before HNCS and reused for
    /// all three looks. This does not fit channels, curves, or a camera profile.
    static func midtoneAlignment(source: SourceImageFile, decoderVersion: String,
                                 baseline: Double) throws -> (ev: Double, report: [String: Any]) {
        try autoreleasepool {
            let reference = try ImagePipeline.load(sourceFile: source, exportSettings: .native,
                rawDecode: RAWDecodeRecipe(decoderVersion: decoderVersion))
            let candidate = try ImagePipeline.load(sourceFile: source, exportSettings: .native,
                rawDecode: RAWDecodeRecipe(rendering: .sceneLinear, decoderVersion: decoderVersion,
                    linearExposureEV: baseline, edrAmount: 1))
            guard reference.width == candidate.width, reference.height == candidate.height,
                  reference.whiteBalance == candidate.whiteBalance else {
                throw RawInputError("Exposure alignment changed geometry or captured WB")
            }
            var stops = [Double]()
            stops.reserveCapacity(reference.width * reference.height)
            for i in stride(from: 0, to: reference.linearRGB.count, by: 3) {
                let a = reference.linearRGB[i..<(i + 3)], b = candidate.linearRGB[i..<(i + 3)]
                guard a.allSatisfy({ $0 > 0 && $0 < 1 }), b.allSatisfy({ $0 > 0 && $0 < 1 }) else { continue }
                let y = 0.2126 * Double(a[i]) + 0.7152 * Double(a[i + 1]) + 0.0722 * Double(a[i + 2])
                let z = 0.2126 * Double(b[i]) + 0.7152 * Double(b[i + 1]) + 0.0722 * Double(b[i + 2])
                if y >= 0.02 && y <= 0.5 && z >= 0.002 { stops.append(log2(y / z)) }
            }
            guard stops.count >= 1024 else { throw RawInputError("Too few non-saturated midtones for exposure alignment") }
            stops.sort()
            func percentile(_ fraction: Double) -> Double {
                let position = Double(stops.count - 1) * fraction
                let lo = Int(position), hi = min(lo + 1, stops.count - 1)
                return stops[lo] + (stops[hi] - stops[lo]) * (position - Double(lo))
            }
            let ev = percentile(0.5)
            return (ev, ["extra_ev_after_baseline": ev, "total_linear_exposure_ev": baseline + ev,
                "sample_pixels": stops.count, "width": reference.width, "height": reference.height,
                "per_pixel_ev_p10": percentile(0.1), "per_pixel_ev_p90": percentile(0.9),
                "reference": "current before HNCS", "candidate": "scene-hdr-baseline before HNCS",
                "method": "Median log2(reference Y / candidate Y), linear-sRGB Y; all channels in (0,1), reference Y in [0.02,0.5], candidate Y >= 0.002. One scalar is applied before HNCS to all three looks.",
                "scope": "Relative software midtone alignment for this RAW, not physical exposure calibration or a new camera default."])
        }
    }

    static func statistics(_ rgb: [Float]) -> [String: Any] {
        var low: Float = .infinity, high: Float = -.infinity
        var negative = 0, aboveWhite = 0, bad = 0, luminance = 0.0
        for i in stride(from: 0, to: rgb.count, by: 3) {
            let values = rgb[i..<(i + 3)]
            if values.contains(where: { !$0.isFinite }) { bad += 1; continue }
            low = min(low, values.min()!); high = max(high, values.max()!)
            if values.contains(where: { $0 < 0 }) { negative += 1 }
            if values.contains(where: { $0 > 1 }) { aboveWhite += 1 }
            luminance += 0.2126 * Double(rgb[i]) + 0.7152 * Double(rgb[i + 1]) + 0.0722 * Double(rgb[i + 2])
        }
        let count = rgb.count / 3
        return ["pixels": count, "minimum": low, "maximum": high, "nonfinite_pixels": bad,
                "negative_pixels": negative, "above_reference_white_pixels": aboveWhite,
                "mean_linear_luminance": luminance / Double(count)]
    }

    static func bridgeParameters(preset: String, white: PhotoWhiteBalance, exposureEV: Double) throws -> [String: Any] {
        guard let context = preset.withCString({ hncs_create_preset_whitepoint(exposureEV, white.x, white.y,
            0, 1, 0, 4, 2, $0, 1) }) else { throw RawInputError("Cannot construct reference bridge") }
        defer { hncs_destroy(context) }
        var matrix = [Double](repeating: 0, count: 9)
        var capture = [Double](repeating: 0, count: 3), target = capture, cct = 0.0
        guard hncs_source_to_native_matrix(context, &matrix) == 0,
              hncs_preset_white_balance(context, &capture, &target, &cct) == 0 else { throw RawInputError("Bridge inspection failed") }
        return ["source_to_native_row_major": matrix, "capture_wb": capture, "target_wb": target,
                "factory_cct": cct, "exposure_ev": exposureEV,
                "scope": "Production virtual-X2D bridge after highlight normalization, before the reference UInt16 clamp"]
    }

    static func writeUnstyled(_ input: ImportedImage, to url: URL, exposureEV: Double) throws {
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue,
                                          .cacheIntermediates: false])
        var image = try ImagePipeline.fullSourceImage(input.sourceFile, whiteBalance: input.whiteBalance, rawDecode: input.rawDecode)
        let width = Int(image.extent.width), height = Int(image.extent.height)
        let dimensions = try input.exportSettings.dimensions(sourceWidth: width, sourceHeight: height)
        if exposureEV != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposureEV]) }
        image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: Double(dimensions.height) / Double(height), kCIInputAspectRatioKey: 1.0])
        let bounds = CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height)
        image = image.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputMaxComponents": CIVector(x: CGFloat(ImagePipeline.maximumHDRValue), y: CGFloat(ImagePipeline.maximumHDRValue), z: CGFloat(ImagePipeline.maximumHDRValue), w: 1)])
            .cropped(to: bounds)
        let maximum = image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: bounds)])
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { context.render(maximum, toBitmap: $0.baseAddress!, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear) }
        if #available(iOS 26, macOS 26, *) { image = image.settingContentHeadroom(max(1, values.max()!)) }
        try context.writeHEIF10Representation(of: image, to: url, colorSpace: pq, options: [:])
    }
}

private struct RawInputError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
