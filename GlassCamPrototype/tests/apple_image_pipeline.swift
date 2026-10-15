// Compiles the production Swift/C++ code, not a separate Python model.
// Run: python3 -B tools/test_apple_images.py
import Foundation
import CoreImage
import ImageIO
import Metal
import UniformTypeIdentifiers

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}

@main struct AppleImageChecks {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
    static let context = CIContext(options: [.workingColorSpace: linear,
                                             .workingFormat: CIFormat.RGBAf.rawValue,
                                             .cacheIntermediates: false])

    static func pixels(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var output = [Float](repeating: 0, count: width * height * 4)
        output.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                           bounds: image.extent, format: .RGBAf, colorSpace: linear)
        }
        return output
    }

    static func error(_ a: [Float], _ b: [Float]) throws -> Float {
        try require(a.count == b.count, "Pixel counts differ")
        return zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    static func fixture(_ directory: URL, width: Int, height: Int) throws -> ImportedImage {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            rgba[i] = 0.05 + 0.8 * Float(y) / Float(max(1, height - 1))
            rgba[i + 1] = 0.05 + 0.8 * Float(x) / Float(max(1, width - 1))
            rgba[i + 2] = y < height / 2 ? 0.2 : 0.6
        } }
        let raster = try PreviewRaster(linearRGBA: rgba, width: width, height: height)
        let url = directory.appendingPathComponent("source-\(width)x\(height).png")
        try context.writePNGRepresentation(of: raster.image, to: url, format: .RGBA16,
                                           colorSpace: sRGB, options: [:])
        return try ImagePipeline.load(data: Data(contentsOf: url), fileExtension: "png",
                                      previewMaximumEdge: 4096)
    }

    static func recipe(_ preset: String) -> ProcessingRecipe {
        var settings = HNCSSettings.standard
        settings.presetKey = preset
        return ProcessingRecipe(mode: .hncs, exposureEV: 0, illuminantKelvin: 6500,
                                simulationIndex: 0, seed: 0, hncs: settings)
    }

    static func checkWorkRows() throws {
        let width = 7, height = 131
        let expected = (0..<(width * height * 3)).map { Float($0) }
        let file = try HNCSPresetWorkFile(width: width, height: height)
        for start in stride(from: 0, to: height, by: 64) {
            let rows = min(64, height - start)
            try file.writeTopDownRows(Array(expected[(start * width * 3)..<((start + rows) * width * 3)]),
                                      originY: start, rows: rows)
        }
        try file.prepareForSpatialPass()
        let expectedBytes = expected.withUnsafeBytes { Data($0) }
        try require(try Data(contentsOf: file.url) == expectedBytes, "Spatial work file changed top-down rows")
        var actual = [Float]()
        for start in stride(from: 0, to: height, by: 29) {
            actual += try file.readTopDownRows(originY: start, rows: min(29, height - start))
        }
        try require(actual == expected, "Changing read partitions changed row or channel order")
    }

    static func checkCrop(_ input: ImportedImage) throws {
        var settings = HNCSSettings.standard
        settings.presetKey = "square-crop"
        let effects = EffectToggles(applyGrain: false, applySharpness: false)
        let recipe = ProcessingRecipe(mode: .hncs, exposureEV: 0, illuminantKelvin: 6500,
                                      simulationIndex: 0, seed: 0, hncs: settings, effects: effects)
        let side = min(input.width, input.height)
        let top = (input.height - side) / 2, left = (input.width - side) / 2
        var rgb = [Float](), originalRGBA = [Float]()
        for y in top..<(top + side) { for x in left..<(left + side) {
            let i = (y * input.width + x) * 3
            let triplet = input.linearRGB[i..<(i + 3)]
            rgb.append(contentsOf: triplet)
            originalRGBA.append(contentsOf: triplet); originalRGBA.append(1)
        } }
        let processed = try ImagePipeline.process(input, recipe: recipe)
        let expected = try HNCSEngine.exportLinearRGBA(linearSRGB: rgb, width: side, height: side,
            exposureEV: 0, illuminantKelvin: 6500, settings: settings, effects: effects)
        try require(try error(pixels(processed.comparisonSource.image), originalRGBA) < 1e-6,
                    "Comparison source does not use the declared top-left crop")
        try require(try error(pixels(processed.image.image), expected) < 1e-6,
                    "Effect and comparison source select different crop rows")
    }

    static func checkSpatial(_ input: ImportedImage, preset: String) throws {
        let settings = recipe(preset).hncs
        let effects = EffectToggles.standard
        var work = try HNCSEngine.presetWork(linearSRGB: input.linearRGB, width: input.width,
            height: input.height, exposureEV: 0, captureKelvin: 6500, settings: settings)
        let status = work.withUnsafeMutableBufferPointer { buffer in
            preset.withCString { hncs_apply_spatial_preset(buffer.baseAddress, input.width, input.height, $0, 1, 1) }
        }
        try require(status == 0, "Native spatial oracle failed")
        let expected = try HNCSEngine.finishPresetWork(work, width: input.width, height: input.height,
            exposureEV: 0, captureKelvin: 6500, settings: settings)
        let actual = try HNCSEngine.exportLinearRGBA(linearSRGB: input.linearRGB, width: input.width,
            height: input.height, exposureEV: 0, illuminantKelvin: 6500, settings: settings, effects: effects)
        try require(try error(actual, expected) < 1e-6, "Swift spatial file path differs from the top-down native oracle")
    }

    static func checkMetal() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let command = queue.makeCommandBuffer() else { throw CheckFailure(description: "Metal unavailable") }
        let width = 8, height = 132
        var marker = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            marker[i] = y < height / 2 ? 0 : 2
            marker[i + 1] = y < height / 2 ? 4 : 0
            marker[i + 2] = x < width / 2 ? 0 : 8
        } }
        let raster = try PreviewRaster(linearRGBA: marker, width: width, height: height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw CheckFailure(description: "Metal texture unavailable")
        }
        let gpu = CIContext(mtlDevice: device, options: [.workingColorSpace: linear,
                                                       .workingFormat: CIFormat.RGBAf.rawValue])
        let task = try PreviewRendering.render(raster.image, with: gpu, to: texture,
                                               commandBuffer: command, colorSpace: linear)
        command.commit(); command.waitUntilCompleted()
        _ = try task.waitUntilCompleted()
        try require(command.status == .completed, "Metal command failed")
        var half = [UInt16](repeating: 0, count: marker.count)
        half.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let actual = half.map { Float(Float16(bitPattern: $0)) }
        try require(try error(actual, marker) < 1e-6, "Metal destination reversed or shifted the source")
    }

    static func checkExport(_ input: ImportedImage, recipe: ProcessingRecipe,
                            directory: URL, name: String, scale: Double = 1) throws {
        let processed = try ImagePipeline.process(input, recipe: recipe)
        // The preview thumbnail and full-source ImageIO/CI decoders can differ,
        // especially for HDR chroma. The whole-frame oracle must use full pixels.
        let decoded = CIImage(contentsOf: input.sourceFile.url,
                              options: [.applyOrientationProperty: true, .expandToHDR: true])!
        let fullRGBA = pixels(decoded)
        var fullRGB = [Float]()
        for i in stride(from: 0, to: fullRGBA.count, by: 4) { fullRGB += fullRGBA[i..<(i + 3)] }
        let full = ImportedImage(sourceFile: input.sourceFile, exportSettings: input.exportSettings,
            linearRGB: fullRGB, width: Int(decoded.extent.width), height: Int(decoded.extent.height),
            original: try PreviewRaster(linearRGBA: fullRGBA, width: Int(decoded.extent.width), height: Int(decoded.extent.height)),
            sourceDescription: "Full-frame oracle")
        let oracle = try ImagePipeline.process(full, recipe: recipe)
        let actualURL = directory.appendingPathComponent(name + "-actual.heic")
        let expectedURL = directory.appendingPathComponent(name + "-expected.heic")
        let settings: ExportSettings = scale == 1 ? .native : .init(
            targetWidth: Int(Double(input.width) * scale), targetHeight: Int(Double(input.height) * scale))
        try ImagePipeline.writeHEIF(processed, to: actualURL, settings: settings)
        var expected = oracle.image.image
        if #available(macOS 26, *) { expected = expected.settingContentHeadroom(0) }
        if scale != 1 {
            expected = expected.applyingFilter("CILanczosScaleTransform",
                parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
                .cropped(to: CGRect(x: 0, y: 0, width: Double(processed.image.width) * scale,
                                    height: Double(processed.image.height) * scale))
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputMaxComponents": CIVector(x: CGFloat(ImagePipeline.maximumHDRValue), y: CGFloat(ImagePipeline.maximumHDRValue), z: CGFloat(ImagePipeline.maximumHDRValue), w: 1)])
                .cropped(to: CGRect(x: 0, y: 0, width: Double(processed.image.width) * scale,
                                    height: Double(processed.image.height) * scale))
        }
        if #available(macOS 26, *) {
            let peak = pixels(oracle.image.image).max() ?? 1
            expected = expected.settingContentHeadroom(max(1, peak))
        }
        // Compare through the same codec to separate row/effect errors from HEIF loss.
        try context.writeHEIF10Representation(of: expected, to: expectedURL, colorSpace: pq, options: [:])
        guard let actualImage = CIImage(contentsOf: actualURL, options: [.expandToHDR: true]),
              let expectedImage = CIImage(contentsOf: expectedURL, options: [.expandToHDR: true]) else {
            throw CheckFailure(description: "HEIF output cannot be reopened")
        }
        try require(actualImage.extent == expectedImage.extent, "HEIF output dimensions differ")
        let maximum = try error(pixels(actualImage), pixels(expectedImage))
        try require(maximum < 0.02, "Full-source HEIF differs from the whole-frame oracle: \(maximum)")
        print("  \(name): maximum decoded HEIF difference \(maximum)")
    }

    static func hdrFixture(_ directory: URL) throws -> ImportedImage {
        let width = 256, height = 384
        var rgba = [Float](repeating: 1, count: width * height * 4)
        let levels: [Float] = [0.1, 0.5, 1, 2, 4, 8]
        for y in 0..<height { for x in 0..<width {
            let level = levels[y / 64]
            let i = (y * width + x) * 4
            rgba[i] = level
            rgba[i + 1] = level * (0.5 + 0.5 * Float(x) / Float(width - 1))
            rgba[i + 2] = level * 0.6
        } }
        let raster = try PreviewRaster(linearRGBA: rgba, width: width, height: height)
        let url = directory.appendingPathComponent("hdr-source.heic")
        try context.writeHEIF10Representation(of: raster.image, to: url, colorSpace: pq, options: [:])
        let input = try ImagePipeline.load(data: Data(contentsOf: url), fileExtension: "heic", previewMaximumEdge: 4096)
        try require((input.linearRGB.max() ?? 0) > 7.5, "HDR import discarded source highlights")
        return input
    }

    static func checkHDR(_ input: ImportedImage, directory: URL) throws {
        let processed = try ImagePipeline.process(input, recipe: .standard)
        let source = input.linearRGB
        var base = source
        for i in stride(from: 0, to: base.count, by: 3) {
            let gain = max(1, source[i], source[i + 1], source[i + 2])
            for channel in 0..<3 { base[i + channel] /= gain }
        }
        var expected = try HNCSEngine.exportLinearRGBA(linearSRGB: base, width: input.width,
            height: input.height, exposureEV: 0, illuminantKelvin: 6500, settings: .standard)
        for pixel in 0..<(source.count / 3) {
            let i = pixel * 3
            let gain = max(1, source[i], source[i + 1], source[i + 2])
            for channel in 0..<3 { expected[pixel * 4 + channel] *= gain }
        }
        try require(try error(pixels(processed.image.image), expected) < 1e-5,
                    "HDR preview did not preserve source highlight ratios through the effect")
        let file = directory.appendingPathComponent("hdr-metadata.heic")
        try ImagePipeline.writeHEIF(processed, to: file)
        guard let container = CGImageSourceCreateWithURL(file as CFURL, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any],
              let decoded = CGImageSourceCreateImageAtIndex(container, 0,
                  [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary),
              let image = CIImage(contentsOf: file, options: [.expandToHDR: true]) else {
            throw CheckFailure(description: "HDR HEIF could not be reopened")
        }
        try require((metadata[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10 &&
                    decoded.colorSpace?.isHDR() == true, "HDR export lacks 10-bit PQ color encoding")
        try require((pixels(image).max() ?? 0) > 2, "HDR metadata exists but encoded pixels were clipped to SDR")
        for preset in ["standard", "square-crop", "film-grain-artistic", "high"] {
            try checkExport(input, recipe: recipe(preset), directory: directory, name: "hdr-hncs-" + preset)
        }
        for overlay in [false, true] {
            let recipe = ProcessingRecipe(mode: .ffcs, exposureEV: 0, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 0, hncs: .standard,
                ffcs: FFCSSettings(applyReferenceAdjustments: overlay, sharpenRadius: 2.3))
            try checkExport(input, recipe: recipe, directory: directory, name: "hdr-ffcs-\(overlay)")
        }
        try checkExport(input, recipe: .standard, directory: directory, name: "hdr-downsample", scale: 0.5)
    }

    static func checkCancellation(_ input: ImportedImage, directory: URL) throws {
        let processed = try ImagePipeline.process(input, recipe: .standard)
        let cancellation = ImageOperationCancellation()
        let url = directory.appendingPathComponent("cancelled.heic")
        do {
            try ImagePipeline.writeHEIF(processed, to: url, isCancelled: { cancellation.isCancelled }) {
                if $0 > 0.1 { cancellation.cancel() }
            }
            throw CheckFailure(description: "Cancelled export completed")
        } catch is CancellationError {}
        try require(!FileManager.default.fileExists(atPath: url.path), "Cancelled export published a file")
        try require(FileManager.default.fileExists(atPath: input.sourceFile.url.path), "Cancellation lost the source")
    }

    static func checkShare(_ input: ImportedImage) async throws {
        let file = TemporaryHEIFFile()
        let processed = try ImagePipeline.process(input, recipe: .standard)
        try ImagePipeline.writeHEIF(processed, to: file.url)
        let original = try Data(contentsOf: file.url)
        let provider = ShareDelivery.makeProvider(for: file)
        func load(_ type: UTType) async throws -> Data {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: CheckFailure(description: "Share provider returned no data")) }
                }
            }
        }
        let heic = try await load(.heic)
        try require(heic == original, "Sharing changed the original HEIF bytes")
        let jpeg = try await load(.jpeg)
        let cached = try await load(.jpeg)
        try require(jpeg == cached, "Repeated JPEG requests did not preserve the cached representation")
        guard let image = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] else {
            throw CheckFailure(description: "Compatibility JPEG cannot be decoded")
        }
        try require(CGImageSourceGetType(image) as String? == UTType.jpeg.identifier, "Share returned the wrong format")
        try require((metadata[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == input.width &&
                    (metadata[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == input.height &&
                    (metadata[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 8,
                    "Compatibility JPEG changed dimensions or depth")
        if (input.linearRGB.max() ?? 0) > 1 {
            let jpegImage = CIImage(data: jpeg)!
            let decoded = pixels(jpegImage)
            let last = ((input.height - 32) * input.width + input.width / 2) * 4
            let middle = ((input.height - 96) * input.width + input.width / 2) * 4
            print("  JPEG HDR tone-map samples: \(Array(decoded[middle..<(middle + 3)])), \(Array(decoded[last..<(last + 3)]))")
            // JPEG loss and color conversion can slightly overshoot 1. Reference
            // white may map to 1; the two source highlights must stay distinct.
            try require(decoded[middle] < 0.95 && decoded[last] - decoded[middle] > 0.05,
                        "JPEG compatibility clipped distinct HDR highlights instead of tone mapping")
        }
    }

    static func checkRAW(_ source: URL, directory: URL) throws {
        let input = try ImagePipeline.load(data: Data(contentsOf: source), fileExtension: "dng")
        let processed = try ImagePipeline.process(input, recipe: .standard)
        let output = directory.appendingPathComponent("raw-hdr.heic")
        let started = Date()
        try ImagePipeline.writeHEIF(processed, to: output) { progress in
            if progress == 0 || progress == 0.9 { print("  real RAW export progress: \(progress)"); fflush(stdout) }
        }
        let raw = CIRAWFilter(imageURL: source)!
        raw.extendedDynamicRangeAmount = 1
        let image = CIImage(contentsOf: output, options: [.expandToHDR: true])!
        let container = CGImageSourceCreateWithURL(output as CFURL, nil)!
        let metadata = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as! [String: Any]
        let native = raw.nativeSize
        let width = (metadata[kCGImagePropertyPixelWidth as String] as! NSNumber).intValue
        let height = (metadata[kCGImagePropertyPixelHeight as String] as! NSNumber).intValue
        try require(min(width, height) == Int(min(native.width, native.height)) &&
                    max(width, height) == Int(max(native.width, native.height)), "RAW HDR export changed native resolution")
        try require((metadata[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10 &&
                    image.colorSpace?.isHDR() == true, "RAW export is not 10-bit HDR")
        let maximum = pixels(image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)]))
        try require(maximum.allSatisfy { $0.isFinite }, "RAW HDR export has invalid pixel values")
        print("PASS: real RAW \(width)×\(height) → 10-bit PQ HEIF; decoded peak \(maximum.max()!); bytes \((try Data(contentsOf: output)).count); seconds \(Date().timeIntervalSince(started))")
    }

    static func main() async {
        do {
            guard (2...3).contains(CommandLine.arguments.count) else { throw CheckFailure(description: "Pass a temporary fixture directory and optional DNG") }
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try checkWorkRows()
            print("PASS: Foundation work-file row order and uneven partitions")
            for (width, height) in [(7, 10), (10, 7), (257, 390)] {
                try checkCrop(fixture(directory, width: width, height: height))
            }
            print("PASS: odd portrait/landscape crops select identical before/after pixels")
            let spatial = try fixture(directory, width: 7, height: 131)
            for preset in ["film-grain-artistic", "high"] { try checkSpatial(spatial, preset: preset) }
            print("PASS: Swift spatial file processing matches native grain and sharpening")
            try checkMetal()
            print("PASS: actual Metal preview destination preserves quadrant coordinates and 2×/4×/8× HDR pixels")
            let full = try fixture(directory, width: 257, height: 389)
            for preset in ["standard", "square-crop", "film-grain-artistic", "high"] {
                try checkExport(full, recipe: recipe(preset), directory: directory, name: "hncs-" + preset)
            }
            for overlay in [false, true] {
                let settings = FFCSSettings(applyReferenceAdjustments: overlay, sharpenRadius: 2.3)
                let recipe = ProcessingRecipe(mode: .ffcs, exposureEV: 0, illuminantKelvin: 6500,
                    simulationIndex: 0, seed: 0, hncs: .standard, ffcs: settings)
                try checkExport(full, recipe: recipe, directory: directory, name: "ffcs-\(overlay)")
            }
            try checkExport(fixture(directory, width: 256, height: 384), recipe: .standard,
                            directory: directory, name: "hncs-downsample", scale: 0.5)
            print("PASS: 7 real HEIF exports match full-frame processing, including halos and resize")
            let hdr = try hdrFixture(directory)
            try checkHDR(hdr, directory: directory)
            print("PASS: HDR import, highlight ratios, 10-bit PQ metadata, and 7 HDR full-frame/strip/resize exports")
            try checkCancellation(full, directory: directory)
            print("PASS: cancellation discards output while retaining the source")
            try await checkShare(full)
            try await checkShare(hdr)
            print("PASS: real share provider preserves HEIF and delivers cached full-size JPEG")
            if CommandLine.arguments.count == 3 {
                try checkRAW(URL(fileURLWithPath: CommandLine.arguments[2]), directory: directory)
            }
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
