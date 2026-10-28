import CHNCS
// Compiles the production Swift/C++ code, not a separate Python model.
// Run: python3 -B scripts/test_apple_images.py
import Foundation
import CoreImage
import ImageIO
import Metal
import QuartzCore
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
    static let targetLinear = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let context = CIContext(options: [.workingColorSpace: linear,
                                             .workingFormat: CIFormat.RGBAf.rawValue,
                                             .cacheIntermediates: false])
    static let targetContext = CIContext(options: [.workingColorSpace: targetLinear,
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
            exposureEV: 0, illuminantKelvin: processed.recipe.illuminantKelvin, settings: settings, effects: effects,
            whiteBalance: processed.recipe.photoWhiteBalance)
        try require(try error(pixels(processed.comparisonSource.image), originalRGBA) < 1e-6,
                    "Comparison source does not use the declared top-left crop")
        try require(try error(pixels(processed.image.image), expected) < 1e-6,
                    "Effect and comparison source select different crop rows")
    }

    static func checkSpatial(_ input: ImportedImage, preset: String, baselineSharpness: Double) throws {
        var settings = recipe(preset).hncs
        let effects = EffectToggles.standard
        for revision in [11, 12] {
            settings.renderRevision = revision
            var work = try HNCSEngine.presetWork(linearSRGB: input.linearRGB, width: input.width,
                height: input.height, exposureEV: 0, captureKelvin: 6500, settings: settings)
            let workScale = settings.usesExtendedWorkingDomain ? try HNCSEngine.workingScale(maximum: work.max() ?? 0) : 1
            let status = work.withUnsafeMutableBufferPointer { buffer in
                preset.withCString {
                    if settings.usesExtendedWorkingDomain {
                        return hncs_prepare_apple_hdr_spatial(buffer.baseAddress, input.width, input.height, $0, 1, 1, baselineSharpness, workScale)
                    }
                    return hncs_apply_spatial_native_sharpness(buffer.baseAddress, input.width, input.height, $0, 1, 1, baselineSharpness)
                }
            }
            try require(status == 0, "Native spatial oracle failed")
            let expected = try HNCSEngine.finishPresetWork(work, width: input.width, height: input.height,
                exposureEV: 0, captureKelvin: 6500, settings: settings, workScale: workScale)
            let actual = try HNCSEngine.exportLinearRGBA(linearSRGB: input.linearRGB, width: input.width,
                height: input.height, exposureEV: 0, illuminantKelvin: 6500, settings: settings, effects: effects,
                baselineSharpness: baselineSharpness)
            try require(actual == expected, "Swift spatial file path differs from native memory path or loses BaselineSharpness")
        }
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

    static func checkDisplayHeadroom() throws {
        func raster(_ value: Float, width: Int = 8) throws -> PreviewRaster {
            var rgba = [Float](repeating: value, count: width * 8 * 4)
            for alpha in stride(from: 3, to: rgba.count, by: 4) { rgba[alpha] = 1 }
            return try PreviewRaster(linearRGBA: rgba, width: width, height: 8)
        }
        let hdr = try raster(8), lowerHDR = try raster(2), sdr = try raster(0.5)
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .rgba16Float
        layer.colorspace = linear
        layer.drawableSize = CGSize(width: 8, height: 8)
        // Reuse the same display layer as SwiftUI does when the latest photo
        // changes. HDR -> lower HDR -> SDR must replace the old display range.
        for (image, expected) in [(hdr, Float(8)), (lowerHDR, 2), (sdr, 1)] {
            let originalPixels = pixels(image.image)
            let peak = PreviewDisplay.headroom(source: image, processed: nil, comparisonFraction: nil)
            try require(peak == expected, "Display range differs from the actual RGB pixels")
            PreviewDisplay.configure(layer, headroom: peak)
            try require(layer.wantsExtendedDynamicRangeContent == (expected > 1), "Stale EDR request after changing photos")
            if #available(macOS 26, *) {
                try require(layer.contentsHeadroom == CGFloat(expected), "Photo headroom never reached the display layer")
                try require(layer.preferredDynamicRange == .high && layer.toneMapMode == .ifSupported,
                            "The display layer cannot adapt HDR to the screen")
            } else {
                try require((layer.edrMetadata != nil) == (expected > 1), "Legacy HDR display metadata missing or stale")
            }
            try require(layer.nextDrawable()?.texture.pixelFormat == .rgba16Float,
                        "Configured HDR layer could not acquire a float drawable")
            try require(try error(pixels(image.image), originalPixels) == 0, "Display configuration changed the source pixels")
        }
        // Hidden or incompatible comparison images must not darken a lone photo
        // by declaring headroom from content that isn't being displayed.
        try require(PreviewDisplay.headroom(source: hdr, processed: lowerHDR, comparisonFraction: nil) == 2,
                    "Effect-only display used hidden original highlights")
        try require(PreviewDisplay.headroom(source: hdr, processed: lowerHDR, comparisonFraction: 0) == 8 &&
                    PreviewDisplay.headroom(source: hdr, processed: lowerHDR, comparisonFraction: 1) == 2 &&
                    PreviewDisplay.headroom(source: hdr, processed: lowerHDR, comparisonFraction: 0.5) == 8,
                    "Comparison display range does not cover its visible inputs")
        try require(PreviewDisplay.headroom(source: sdr, processed: try raster(8, width: 4), comparisonFraction: nil) == 1,
                    "A stale differently sized effect changed display headroom")
    }

    static func checkExport(_ input: ImportedImage, recipe: ProcessingRecipe,
                            directory: URL, name: String, scale requestedScale: Double = 1,
                            settings explicitSettings: ExportSettings? = nil) throws {
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
        let settings: ExportSettings = explicitSettings ?? (requestedScale == 1 ? .native : .init(
            targetWidth: Int(Double(input.width) * requestedScale), targetHeight: Int(Double(input.height) * requestedScale)))
        let outputSize = try settings.dimensions(sourceWidth: full.width, sourceHeight: full.height, crop: recipe.crop)
        let scale = explicitSettings == nil ? requestedScale : Double(outputSize.height) / Double(processed.image.height)
        try ImagePipeline.writeHEIF(processed, to: actualURL, settings: settings)
        let directURL = directory.appendingPathComponent(name + "-direct.heic")
        var sourceDimensions: (Int, Int)?
        let directRecipe = try ImagePipeline.writeHEIF(sourceFile: input.sourceFile, recipe: recipe,
            to: directURL, settings: settings, onSourceDimensions: { sourceDimensions = ($0, $1) })
        try require(sourceDimensions?.0 == full.width && sourceDimensions?.1 == full.height,
                    "Reported source size differs from the full decoder extent before recipe cropping")
        try require(directRecipe == processed.recipe, "Direct export changed the frozen white balance or recipe")
        guard let directImage = CIImage(contentsOf: directURL, options: [.expandToHDR: true]),
              let legacyImage = CIImage(contentsOf: actualURL, options: [.expandToHDR: true]) else {
            throw CheckFailure(description: "Direct HEIF output cannot be decoded")
        }
        try require(try error(pixels(directImage), pixels(legacyImage)) == 0,
                    "Skipping the RAW effect preview changed encoded image pixels")
        var expected = oracle.image.image
        if #available(macOS 26, *) { expected = expected.settingContentHeadroom(0) }
        if scale != 1 {
            expected = expected.applyingFilter("CILanczosScaleTransform",
                parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
                .cropped(to: CGRect(x: 0, y: 0, width: Double(processed.image.width) * scale,
                                    height: Double(processed.image.height) * scale))
        }
        // Both native and resized exports clamp in the destination primaries.
        // Leaving this out lets ImageIO choose a different gamut mapping.
        expected = expected.applyingFilter("CIColorClamp",parameters:[
            "inputMinComponents":CIVector(x:0,y:0,z:0,w:1),
            "inputMaxComponents":CIVector(x:CGFloat(ImagePipeline.maximumHDRValue),y:CGFloat(ImagePipeline.maximumHDRValue),z:CGFloat(ImagePipeline.maximumHDRValue),w:1)])
            .cropped(to:CGRect(x:0,y:0,width:Double(processed.image.width)*scale,height:Double(processed.image.height)*scale))
        if #available(macOS 26, *) {
            let peak = pixels(oracle.image.image).max() ?? 1
            expected = expected.settingContentHeadroom(max(1, peak))
        }
        // Compare through the same codec to separate row/effect errors from HEIF loss.
        let expectedContext = recipe.usesExtendedHNCSWorkingDomain ? targetContext : context
        try expectedContext.writeHEIF10Representation(of: expected, to: expectedURL, colorSpace: pq, options: [:])
        guard let actualImage = CIImage(contentsOf: actualURL, options: [.expandToHDR: true]),
              let expectedImage = CIImage(contentsOf: expectedURL, options: [.expandToHDR: true]) else {
            throw CheckFailure(description: "HEIF output cannot be reopened")
        }
        try require(actualImage.extent == expectedImage.extent, "HEIF output dimensions differ")
        let maximum = try error(pixels(actualImage), pixels(expectedImage))
        try require(maximum < 0.02, "Full-source HEIF \(name) differs from the whole-frame oracle: \(maximum)")
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
        // Keep the old gain-map contract as a LEGACY replay check. Revision 12
        // has independent HDR-domain/edge checks, not this formula as an oracle.
        let legacyRecipe = ProcessingRecipe(mode: .hncs, exposureEV: 0, illuminantKelvin: 6500,
            simulationIndex: 0, seed: 0, hncs: .legacyStandard)
        let processed = try ImagePipeline.process(input, recipe: legacyRecipe)
        let source = input.linearRGB
        var base = source
        for i in stride(from: 0, to: base.count, by: 3) {
            let gain = max(1, source[i], source[i + 1], source[i + 2])
            for channel in 0..<3 { base[i + channel] /= gain }
        }
        var expected = try HNCSEngine.exportLinearRGBA(linearSRGB: base, width: input.width,
            height: input.height, exposureEV: 0, illuminantKelvin: processed.recipe.illuminantKelvin, settings: .legacyStandard,
            whiteBalance: processed.recipe.photoWhiteBalance)
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

    static func checkHDRSpatialStructure(_ directory: URL) throws {
        let width = 33, height = 17
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let value: Float = (15...17).contains(x) ? 2.1 : 2
            for c in 0..<3 { rgba[(y * width + x) * 4 + c] = value }
        } }
        let raster = try PreviewRaster(linearRGBA: rgba, width: width, height: height)
        let url = directory.appendingPathComponent("bright-detail.heic")
        try targetContext.writeHEIF10Representation(of: raster.image, to: url, colorSpace: pq, options: [:])
        let source = try SourceImageFile(data: Data(contentsOf: url), fileExtension: "heic")
        // Explicit pre-codec vector: the assertion is about spatial behaviour,
        // independent of HEVC chroma quantization and thumbnail decoding.
        let input = ImportedImage(sourceFile: source, exportSettings: .native,
            linearRGB: (0..<(width * height)).flatMap { Array(rgba[($0 * 4)..<($0 * 4 + 3)]) },
            width: width, height: height, original: raster, sourceDescription: "HDR neutral edge")
        func render(_ sharp: Bool) throws -> [Float] {
            let recipe = ProcessingRecipe(mode: .hncs, exposureEV: 0, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 0, hncs: .standard,
                effects: EffectToggles(applyGrain: false, applySharpness: sharp, applyExtraCrop: false))
            return pixels(try ImagePipeline.process(input, recipe: recipe).image.image)
        }
        let off = try render(false), on = try render(true)
        let dark = ((height / 2) * width + 14) * 4
        let bright = ((height / 2) * width + 15) * 4
        try require(on[bright] - on[dark] > off[bright] - off[dark] + 0.005,
                    "HDR neutral detail still bypasses the production spatial pass")
        try require(on[bright] > 1 && on.allSatisfy(\.isFinite), "HDR spatial output was clipped or invalid")
    }

    static func checkCaptureMetadata(_ directory: URL) async throws {
        let width = 32, height = 24
        var rgba = [Float](repeating: 2, count: width * height * 4)
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 1 }
        let raster = try PreviewRaster(linearRGBA: rgba, width: width, height: height)
        let file = TemporaryHEIFFile()
        try targetContext.writeHEIF10Representation(of: raster.image, to: file.url, colorSpace: pq, options: [:])
        let before = pixels(CIImage(contentsOf: file.url, options: [.expandToHDR: true])!)
        let original: [String: Any] = [
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Fixture Camera",
                kCGImagePropertyTIFFModel as String: "Three-lens fixture",
                kCGImagePropertyTIFFDateTime as String: "2026:10:19 11:22:33",
                kCGImagePropertyTIFFOrientation as String: 6
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:10:19 11:22:33",
                kCGImagePropertyExifDateTimeDigitized as String: "2026:10:19 11:22:33",
                kCGImagePropertyExifOffsetTime as String: "+08:00",
                kCGImagePropertyExifOffsetTimeOriginal as String: "+08:00",
                kCGImagePropertyExifOffsetTimeDigitized as String: "+08:00",
                kCGImagePropertyExifSubsecTimeOriginal as String: "125",
                kCGImagePropertyExifSubsecTimeDigitized as String: "125",
                kCGImagePropertyExifExposureTime as String: 1.0 / 125,
                kCGImagePropertyExifFNumber as String: 2.8,
                kCGImagePropertyExifISOSpeedRatings as String: [200],
                kCGImagePropertyExifFocalLength as String: 5.7,
                kCGImagePropertyExifFocalLenIn35mmFilm as String: 26,
                kCGImagePropertyExifLensModel as String: "Fixture Lens",
                kCGImagePropertyExifLensMake as String: "Fixture Camera",
                kCGImagePropertyExifLensSpecification as String: [5.7, 5.7, 2.8, 2.8],
                kCGImagePropertyExifMakerNote as String: Data([1, 2, 3, 4]),
                kCGImagePropertyExifPixelXDimension as String: 9000,
                kCGImagePropertyExifPixelYDimension as String: 6000
            ]
        ]
        let metadata = PhotoMetadata(properties: original)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 3, minute: 22, second: 33))!.addingTimeInterval(0.125)
        try require(abs((metadata.captureDate?.timeIntervalSince(date) ?? 10)) < 0.001,
                    "Capture timestamp lost its offset or subseconds")
        let bareSource = CGImageSourceCreateWithURL(file.url as CFURL, nil)!
        let bareProperties = CGImageSourceCopyPropertiesAtIndex(bareSource, 0, nil) as! [String: Any]
        do {
            try metadata.validate(in: bareProperties)
            throw CheckFailure(description: "A successful encode without capture fields was accepted")
        } catch PipelineError.metadata {}
        try targetContext.writeHEIF10Representation(
            of: raster.image.settingProperties(metadata.encodingProperties(width: width, height: height)),
            to: file.url, colorSpace: pq, options: [:])
        let after = pixels(CIImage(contentsOf: file.url, options: [.expandToHDR: true])!)
        try require(try error(before, after) == 0, "Encoding capture metadata changed image pixels")
        func check(_ properties: [String: Any]) throws {
            let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
            try require(tiff?[kCGImagePropertyTIFFMake as String] as? String == "Fixture Camera" &&
                        tiff?[kCGImagePropertyTIFFModel as String] as? String == "Three-lens fixture" &&
                        exif?[kCGImagePropertyExifLensModel as String] as? String == "Fixture Lens", "Capture identity was lost")
            try require(exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int] == [200] &&
                        abs(((exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 1) - 1.0 / 125) < 1e-7,
                        "Exposure metadata was lost")
            try require(exif?[kCGImagePropertyExifMakerNote as String] == nil &&
                        (exif?[kCGImagePropertyExifPixelXDimension as String] as? NSNumber)?.intValue == width &&
                        (exif?[kCGImagePropertyExifPixelYDimension as String] as? NSNumber)?.intValue == height &&
                        ((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1) == 1,
                        "RAW metadata restored stale geometry or MakerNote offsets")
            try require(abs(PhotoMetadata(properties: properties).captureDate?.timeIntervalSince(date) ?? 10) < 0.001,
                        "Encoded capture date did not survive reload")
            try require(exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String == "+08:00" &&
                        exif?[kCGImagePropertyExifSubsecTimeOriginal as String] as? String == "125" &&
                        exif?[kCGImagePropertyExifSubsecTimeDigitized as String] as? String == "125",
                        "Native EXIF timezone or subsecond fields were omitted")
        }
        let retained = try SourceImageFile(data: Data(contentsOf: file.url), fileExtension: "heic")
        let output = TemporaryHEIFFile(captureDate: retained.metadata.captureDate)
        try ImagePipeline.writeHEIF(sourceFile: retained, recipe: .standard, to: output.url, settings: .native)
        let container = CGImageSourceCreateWithURL(output.url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as! [String: Any]
        try metadata.validate(in: properties)
        try check(properties)
        try require((properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10 &&
                    CIImage(contentsOf: output.url)?.colorSpace?.isHDR() == true,
                    "Capture metadata changed the HDR/10-bit output")
        let provider = ShareDelivery.makeProvider(for: output)
        let jpeg: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CheckFailure(description: "Missing JPEG metadata fixture")) }
            }
        }
        let jpegSource = CGImageSourceCreateWithData(jpeg as CFData, nil)!
        try check(CGImageSourceCopyPropertiesAtIndex(jpegSource, 0, nil) as! [String: Any])
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

    static func checkNativeGradationMigration() throws {
        var settings = HNCSSettings.standard
        settings.presetKey = "nature"
        settings.filmCurve = .linear
        settings.workingSpace = .lstar
        settings.intent = .reproduction
        settings.whiteBalancePolicy = .preset
        settings.factoryKelvinOverride = 4000
        settings.applyToneCurve = false
        var historicalSettings = settings; historicalSettings.renderRevision = 11
        let expected = ProcessingRecipe(mode: .hncs, exposureEV: -0.3, illuminantKelvin: 6500,
            simulationIndex: 0, seed: 0, hncs: historicalSettings,
            effects: EffectToggles(applyGrain: false, applySharpness: false, applyExtraCrop: false))
        var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as! [String: Any]
        var storedHNCS = payload["hncs"] as! [String: Any]
        storedHNCS.removeValue(forKey: "whiteBalancePolicy")
        let suite = "glasscam-native-gradation-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var photoSettings = settings; photoSettings.whiteBalancePolicy = .photo
        let cameraExpected = ProcessingRecipe(mode: expected.mode, exposureEV: expected.exposureEV,
            illuminantKelvin: 6500, simulationIndex: 0, seed: 0, hncs: photoSettings, effects: expected.effects)
        for revision in [8, 9, 10, 11] {
            storedHNCS["renderRevision"] = revision
            payload["hncs"] = storedHNCS
            let oldData = try JSONSerialization.data(withJSONObject: payload)
            let restored = try JSONDecoder().decode(ProcessingRecipe.self, from: oldData)
            try require(restored == expected && restored.hncs.renderRevision == 11 && restored.hncs.whiteBalancePolicy == .preset,
                        "Old photo recipe changed its original WB, HNCS selections or effect switches")
            defaults.set(oldData, forKey: "editor.processingRecipe.revision8.v1")
            try require(CameraSettingsStore(defaults: defaults).recipe == cameraExpected,
                        "Camera defaults did not migrate WB independently of frozen photo recipes")
        }
        for policy in HNCSWhiteBalancePolicy.allCases {
            var selected = settings; selected.whiteBalancePolicy = policy
            let recipe = ProcessingRecipe(mode: .hncs, exposureEV: -0.3, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 0, hncs: selected, effects: expected.effects)
            let data = try JSONEncoder().encode(recipe)
            try require(try JSONDecoder().decode(ProcessingRecipe.self, from: data) == recipe,
                        "Explicit WB selection did not survive photo recipe round-trip")
            defaults.set(data, forKey: "editor.processingRecipe.revision8.v1")
            let store = CameraSettingsStore(defaults: defaults)
            try require(store.recipe == recipe && CameraSettingsStore(defaults: defaults).recipe == recipe,
                        "Explicit camera WB choice was overwritten on reload")
        }
        for cropEnabled in [true, false] {
            var square = historicalSettings; square.presetKey = "square-crop"
            let effects = EffectToggles(applyGrain: false, applySharpness: true, applyExtraCrop: cropEnabled)
            let historical = ProcessingRecipe(mode: .hncs, exposureEV: -0.3, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 0, hncs: square, effects: effects)
            let data = try JSONEncoder().encode(historical)
            defaults.set(data, forKey: "editor.processingRecipe.revision8.v1")
            let camera = CameraSettingsStore(defaults: defaults)
            var migrated = square; migrated.presetKey = "standard"; migrated.renderRevision = 12
            let future = ProcessingRecipe(mode: .hncs, exposureEV: -0.3, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 0, hncs: migrated, effects: effects)
            try require(camera.recipe == future && CameraSettingsStore(defaults: defaults).recipe == future,
                        "Legacy square camera preference did not migrate and persist independently")
            camera.hncs.presetKey = "square-crop"
            try require(camera.recipe.crop == .none, "An injected legacy camera preference created a new square photo")
            let restored = try JSONDecoder().decode(ProcessingRecipe.self, from: data)
            try require(restored == historical && restored.crop == (cropEnabled ? .centeredSquare : .none),
                        "Camera-only migration changed a frozen historical photo recipe")
        }
        try require(!HNCSEngine.cameraPresets.contains { $0.id == "square-crop" } &&
                    HNCSEngine.presets.contains { $0.id == "square-crop" },
                    "Camera catalog and legacy recipe catalog lost their compatibility boundary")
        storedHNCS.removeValue(forKey: "renderRevision")
        payload["hncs"] = storedHNCS
        let unversioned = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONSerialization.data(withJSONObject: payload))
        try require(unversioned.hncs.renderRevision == 11 && !unversioned.usesExtendedHNCSWorkingDomain,
                    "An unversioned durable recipe silently adopted the new HDR domain")
        for unsupported in [7, 13, 99] {
            storedHNCS["renderRevision"] = unsupported
            payload["hncs"] = storedHNCS
            let data = try JSONSerialization.data(withJSONObject: payload)
            let rejected = try JSONDecoder().decode(ProcessingRecipe.self, from: data)
            try require(!rejected.isValid, "Unknown HNCS render revision was silently accepted")
        }
    }

    static func checkAutomaticWhiteBalance(_ input: ImportedImage) throws {
        let warm = PhotoWhiteBalance(origin: .appleRAW, temperature: 2850, tint: 4,
                                     x: 0.44757, y: 0.40745)
        let tinted = PhotoWhiteBalance(origin: .appleRAW, temperature: 5200, tint: 25,
                                       x: 0.34, y: 0.38)
        let frozen = ProcessingRecipe.standard.resolvingWhiteBalance(warm)
        try require(frozen.photoWhiteBalance == warm && frozen.illuminantKelvin != 6500,
                    "Automatic photo WB was replaced by fixed 6500K")
        try require(frozen.resolvingWhiteBalance(tinted) == frozen, "Retry retargeted frozen WB")
        let decoded = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONEncoder().encode(frozen))
        try require(decoded == frozen, "Temperature/tint/xy did not survive recipe round-trip")
        let invalid = PhotoWhiteBalance(origin: .appleRAW, temperature: 5000, tint: 0, x: .nan, y: 0.3)
        try require(!invalid.isValid, "Invalid white point accepted")
        let a = try HNCSEngine.exportLinearRGBA(linearSRGB: input.linearRGB, width: input.width,
            height: input.height, exposureEV: 0, illuminantKelvin: 6500, whiteBalance: warm)
        let b = try HNCSEngine.exportLinearRGBA(linearSRGB: input.linearRGB, width: input.width,
            height: input.height, exposureEV: 0, illuminantKelvin: 6500, whiteBalance: tinted)
        let again = try HNCSEngine.exportLinearRGBA(linearSRGB: input.linearRGB, width: input.width,
            height: input.height, exposureEV: 0, illuminantKelvin: 6500, whiteBalance: warm)
        try require(try error(a, b) > 0.001, "Changed white point reused stale context")
        try require(a == again, "Returning to frozen white point changed render")
        let direct = try ImagePipeline.process(input, recipe: .standard)
        try require(direct.recipe.photoWhiteBalance == input.whiteBalance,
                    "Pipeline failed to bind the photo's white point")

        // Actual failing phone whitepoint. Check user-visible rendering and
        // cache identity for both policies, not just a persisted enum value.
        let tele = PhotoWhiteBalance(origin: .appleRAW, temperature: 5393, tint: 44.5,
                                     x: 0.33567193150520325, y: 0.37427031993865967)
        var nature = HNCSSettings.standard; nature.presetKey = "nature"; nature.workingSpace = .lstar
        let gray = [Float](repeating: 0.18, count: 4 * 4 * 3)
        let effects = EffectToggles(applyGrain: false, applySharpness: false, applyExtraCrop: false)
        func render(_ settings: HNCSSettings) throws -> [Float] {
            try HNCSEngine.exportLinearRGBA(linearSRGB: gray, width: 4, height: 4,
                exposureEV: 0, illuminantKelvin: 6500, settings: settings, effects: effects, whiteBalance: tele)
        }
        let automatic = try render(nature)
        nature.whiteBalancePolicy = .preset
        let fixed = try render(nature)
        let legacyGolden: [Float] = [0.26048735, 0.33648133, 0.23170701]
        try require(zip(fixed.prefix(3), legacyGolden).allSatisfy { abs($0 - $1) < 1e-7 },
                    "Original Nature WB replay no longer matches pre-fix output")
        try require(fixed[1] / ((fixed[0] + fixed[2]) / 2) > 1.25,
                    "Failing scene no longer reproduces the original green cast")
        try require(abs(automatic[1] / ((automatic[0] + automatic[2]) / 2) - 1) < 0.025,
                    "Photo WB did not keep neutral gray neutral through Nature")
        let fixedRecipe = ProcessingRecipe(mode: .hncs, exposureEV: 0, illuminantKelvin: 6500,
            simulationIndex: 0, seed: 0, hncs: nature, photoWhiteBalance: tele)
        try require(fixedRecipe.whiteBalanceDescription == "Preset WB · Nature · 5500 K",
                    "Review labels a preset-rebalanced photo as automatic WB")
        nature.whiteBalancePolicy = .photo
        try require(try render(nature) == automatic, "WB policy reused a stale cached context")
        try require(ProcessingRecipe.standard.resolvingWhiteBalance(tele).whiteBalanceDescription == tele.description,
                    "Automatic WB review lost the per-photo value")
    }

    static func checkRAW(_ source: URL, directory: URL) throws {
        let input = try ImagePipeline.load(data: Data(contentsOf: source), fileExtension: "dng")
        let processed = try ImagePipeline.process(input, recipe: .standard)
        let asShot = PhotoWhiteBalance.asShot(CIRAWFilter(imageURL: source)!)
        try require(asShot.origin == .appleRAW && asShot == input.whiteBalance &&
                    processed.recipe.photoWhiteBalance == asShot, "RAW as-shot WB was not frozen")
        let rawRecipe = processed.source.rawDecode
        let sourceBaseline = try ImagePipeline.baselineSharpness(in: CIRAWFilter(imageURL: source)!.properties)
        try require(rawRecipe.sharpnessAmount == 0 && rawRecipe.baselineSharpness == sourceBaseline,
                    "HNCS failed to disable decoder sharpness or bind the actual RAW baseline")
        let snapshot = try ImagePipeline.inspectRAW(sourceFile: input.sourceFile, recipe: rawRecipe)
        let configured = snapshot["configured"] as! [String: Any]
        try require((configured["sharpness_supported"] as? Bool) != true ||
                    (configured["sharpness_amount"] as? NSNumber)?.floatValue == 0,
                    "Apple sharpness remains active before native USM")
        let decoded = try JSONDecoder().decode(RAWDecodeRecipe.self, from: JSONEncoder().encode(rawRecipe))
        try require(decoded == rawRecipe, "Frozen RAW policy did not survive Codable")
        let again = try ImagePipeline.process(processed.source, recipe: .standard)
        try require(again.source.rawDecode == rawRecipe && again.source.linearRGB == processed.source.linearRGB,
                    "Retry reconfigured the decoded RAW or repeated its decoder pass")
        print("PASS: per-RAW BaselineSharpness \(sourceBaseline), decoder sharpness disabled, policy/retry stable")
        print("PASS: RAW \(asShot.description); xy (\(asShot.x), \(asShot.y)); virtual model CCT \(processed.recipe.illuminantKelvin)")
        let output = directory.appendingPathComponent("raw-hdr.heic")
        let started = Date()
        try ImagePipeline.writeHEIF(processed, to: output, progress: { progress in
            if progress == 0 || progress == 0.9 { print("  real RAW export progress: \(progress)"); fflush(stdout) }
        })
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
        try require(maximum.allSatisfy { $0.isFinite } && maximum.max()! > 1, "RAW HDR export lost superwhite pixels")
        print("PASS: real RAW \(width)×\(height) → 10-bit PQ HEIF; decoded peak \(maximum.max()!); bytes \((try Data(contentsOf: output)).count); seconds \(Date().timeIntervalSince(started))")
        let captureFraming = CaptureFraming(cameraID: "offline-RAW-fixture", nativePixelCount: width * height,
                                           deliveredWidth: width, deliveredHeight: height)
        for mode in [24, 48] {
            let settings = ExportSettings.camera(mode, framing: captureFraming)
            let target = directory.appendingPathComponent("raw-camera-\(mode).heic")
            var sourceDimensions: (Int, Int)?
            try ImagePipeline.writeHEIF(sourceFile: processed.source.sourceFile, recipe: processed.recipe,
                to: target, settings: settings, rawDecode: processed.source.rawDecode,
                onSourceDimensions: { sourceDimensions = ($0, $1) })
            try require(sourceDimensions?.0 == width && sourceDimensions?.1 == height,
                        "Real RAW source size reporting differs from its oriented full decoder extent")
            let encoded = CGImageSourceCreateWithURL(target as CFURL, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as! [String: Any]
            let expected = try settings.dimensions(sourceWidth: width, sourceHeight: height, crop: processed.recipe.crop)
            try require((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == expected.width &&
                        (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == expected.height &&
                        (properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10,
                        "Real RAW camera output dimensions/depth did not follow its policy")
            if expected.width == width && expected.height == height {
                try require(try Data(contentsOf: target) == Data(contentsOf: output),
                            "Native-sized camera mode changed the existing RAW export")
            }
            print("PASS: real RAW camera \(mode)MP policy → \(expected.width)×\(expected.height), 10-bit; native-sized output preserves original HEIF bytes")
        }
    }

    static func main() async {
        do {
            guard (2...3).contains(CommandLine.arguments.count) else { throw CheckFailure(description: "Pass a temporary fixture directory and optional DNG") }
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try checkNativeGradationMigration()
            print("PASS: revision 12 preserves old photo rendering/WB, migrates future camera defaults, and rejects unknown revisions")
            try require(try ImagePipeline.baselineSharpness(in: [:]) == 0, "Missing RAW baseline must follow native zero fallback")
            for baseline in [0.0, 0.5, 1.0, 1.5, 2.0] {
                let properties: [String: Any] = [kCGImagePropertyDNGDictionary as String:
                    [kCGImagePropertyDNGBaselineSharpness as String: baseline]]
                try require(try ImagePipeline.baselineSharpness(in: properties) == baseline, "RAW baseline was hard-coded")
            }
            for baseline in [-1.0, Double.nan, Double.infinity, "1.5"] as [Any] {
                do {
                    _ = try ImagePipeline.baselineSharpness(in: [kCGImagePropertyDNGDictionary as String:
                        [kCGImagePropertyDNGBaselineSharpness as String: baseline]])
                    throw CheckFailure(description: "Malformed RAW baseline accepted")
                } catch is PipelineError {}
            }
            print("PASS: missing, varied and malformed RAW sharpness metadata")
            try checkWorkRows()
            print("PASS: Foundation work-file row order and uneven partitions")
            for (width, height) in [(7, 10), (10, 7), (257, 390)] {
                try checkCrop(fixture(directory, width: width, height: height))
            }
            print("PASS: odd portrait/landscape crops select identical before/after pixels")
            let spatial = try fixture(directory, width: 7, height: 131)
            for preset in ["standard", "nature", "saturated", "grayscale-red-filter", "film-grain-artistic", "high"] {
                for baseline in [0.0, 1.5] { try checkSpatial(spatial, preset: preset, baselineSharpness: baseline) }
            }
            print("PASS: Swift native-USM/portable-grain file route matches memory with per-RAW baseline")
            try checkMetal()
            print("PASS: actual Metal preview destination preserves quadrant coordinates and 2×/4×/8× HDR pixels")
            try checkDisplayHeadroom()
            print("PASS: real Metal display layer receives per-photo HDR headroom, enables tone mapping, and resets for SDR")
            let full = try fixture(directory, width: 257, height: 389)
            try checkAutomaticWhiteBalance(full)
            print("PASS: production automatic WB snapshot, Codable, cache invalidation and per-photo binding")
            try await CaptureWorkflowChecks.run(fixture: full)
            try CaptureOutputChecks.run()
            try await CaptureRecoveryChecks.run(fixture: full, directory: directory)
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
            print("PASS: 7 real HEIF exports match full-frame processing; direct export has identical decoded pixels")
            try checkExport(fixture(directory, width: 200, height: 300), recipe: .standard,
                            directory: directory, name: "camera-interpolated-24", settings: .camera(24))
            print("PASS: adaptive 24MP interpolation matches independent full-frame linear-light HEIF output")
            let hdr = try hdrFixture(directory)
            try checkHDR(hdr, directory: directory)
            print("PASS: HDR import, highlight ratios, 10-bit PQ metadata, and 7 HDR exports; direct export has identical decoded pixels")
            try checkHDRSpatialStructure(directory)
            print("PASS: neutral HDR detail participates in the production sharpening pass")
            try await checkCaptureMetadata(directory)
            print("PASS: capture metadata in the initial encode, timestamp, HDR encoding and JPEG metadata retention")
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
