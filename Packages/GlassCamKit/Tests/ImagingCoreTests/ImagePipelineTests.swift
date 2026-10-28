import Testing
@testable import ImagingCore
@testable import Capture
import GlassCamTestSupport
import CHNCS
import Foundation
import CoreImage
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@Suite(.serialized) struct ImagePipelineTests {
    static let resources = TestResources.colors
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
        guard a.count == b.count else { throw CheckFailure(description: "Pixel counts differ: \(a.count) versus \(b.count)") }
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
        return input
    }

    @Test static func hdrImport_keepsSuperwhiteSourcePixels() throws {
        let work = try TestDirectory()
        let input = try hdrFixture(work.url)
        #expect((input.linearRGB.max() ?? 0) > 7.5)
    }

    @Test(arguments: [1, 7, 64], [1, 29, 131])
    static func workFile_unevenReadPartitionsPreserveRowsAndChannels(writeRows: Int, readRows: Int) throws {
        let width = 7, height = 131
        let expected = (0..<(width * height * 3)).map { Float($0) }
        let file = try HNCSPresetWorkFile(width: width, height: height)
        for start in stride(from: 0, to: height, by: writeRows) {
            let rows = min(writeRows, height - start)
            try file.writeTopDownRows(Array(expected[(start * width * 3)..<((start + rows) * width * 3)]),
                                      originY: start, rows: rows)
        }
        try file.prepareForSpatialPass()
        let expectedBytes = expected.withUnsafeBytes { Data($0) }
        #expect(try Data(contentsOf: file.url) == expectedBytes, "Spatial work file changed top-down rows")
        var actual = [Float]()
        for start in stride(from: 0, to: height, by: readRows) {
            actual += try file.readTopDownRows(originY: start, rows: min(readRows, height - start))
        }
        #expect(actual == expected, "Changing read partitions changed row or channel order")
    }

    @Test(arguments: [(7, 10), (10, 7), (257, 390)])
    static func squareCrop_comparisonSelectsIdenticalSourcePixels(size: (Int, Int)) throws {
        let work = try TestDirectory()
        let input = try fixture(work.url, width: size.0, height: size.1)

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
        let processed = try ImagePipeline.process(resources: resources, input, recipe: recipe)
        let expected = try HNCSEngine.exportLinearRGBA(linearSRGB: rgb, width: side, height: side,
            exposureEV: 0, illuminantKelvin: processed.recipe.illuminantKelvin, settings: settings, effects: effects,
            whiteBalance: processed.recipe.photoWhiteBalance)
        #expect(try error(pixels(processed.comparisonSource.image), originalRGBA) < 1e-6, "Comparison source does not use the declared top-left crop")
        #expect(try error(pixels(processed.image.image), expected) < 1e-6, "Effect and comparison source select different crop rows")
    }

    @Test(arguments: ["standard", "nature", "saturated", "grayscale-red-filter", "film-grain-artistic", "high"].flatMap { preset in [0.0, 1.5].flatMap { baseline in [11, 12].map { (preset, baseline, $0) } } })
    static func spatialWorkFile_matchesNativeMemoryPath(scenario: (String, Double, Int)) throws {
        let directoryOwner = try TestDirectory()
        let input = try fixture(directoryOwner.url, width: 7, height: 131)
        let (preset, baselineSharpness, revision) = scenario

        var settings = recipe(preset).hncs
        let effects = EffectToggles.standard
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
            #expect(status == 0, "Native spatial oracle failed")
            let expected = try HNCSEngine.finishPresetWork(work, width: input.width, height: input.height,
                exposureEV: 0, captureKelvin: 6500, settings: settings, workScale: workScale)
            let actual = try HNCSEngine.exportLinearRGBA(linearSRGB: input.linearRGB, width: input.width,
                height: input.height, exposureEV: 0, illuminantKelvin: 6500, settings: settings, effects: effects,
                baselineSharpness: baselineSharpness)
            #expect(actual == expected, "Swift spatial file path differs from native memory path or loses BaselineSharpness")

    }

    @Test
    static func metalPreview_preservesQuadrantsAndHDRValues() throws {
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
        #expect(command.status == .completed, "Metal command failed")
        var half = [UInt16](repeating: 0, count: marker.count)
        half.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let actual = half.map { Float(Float16(bitPattern: $0)) }
        #expect(try error(actual, marker) < 1e-6, "Metal destination reversed or shifted the source")
    }

    @Test
    static func hdrSpatialProcessing_sharpensNeutralHighlightDetail() throws {
        let work = try TestDirectory()
        let directory = work.url

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
            return pixels(try ImagePipeline.process(resources: resources, input, recipe: recipe).image.image)
        }
        let off = try render(false), on = try render(true)
        let dark = ((height / 2) * width + 14) * 4
        let bright = ((height / 2) * width + 15) * 4
        #expect(on[bright] - on[dark] > off[bright] - off[dark] + 0.005, "HDR neutral detail still bypasses the production spatial pass")
        #expect(on[bright] > 1, "HDR spatial output was clipped or invalid")
        #expect(on.allSatisfy { $0.isFinite }, "HDR spatial output was clipped or invalid")
    }

    @Test
    static func cancellation_discardsOutputAndRetainsSource() throws {
        let work = try TestDirectory()
        let directory = work.url
        let input = try fixture(directory, width: 257, height: 389)

        let processed = try ImagePipeline.process(resources: resources, input, recipe: .standard)
        let cancellation = ImageOperationCancellation()
        let url = directory.appendingPathComponent("cancelled.heic")
        do {
            try ImagePipeline.writeHEIF(resources: resources, processed, to: url, isCancelled: { cancellation.isCancelled }) {
                if $0 > 0.1 { cancellation.cancel() }
            }
            throw CheckFailure(description: "Cancelled export completed")
        } catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: url.path), "Cancelled export published a file")
        #expect(FileManager.default.fileExists(atPath: input.sourceFile.url.path), "Cancellation lost the source")
    }

    @Test
    static func legacyHDR_preservesHighlightRatiosAndTenBitEncoding() throws {
        let work = try TestDirectory()
        let directory = work.url
        let input = try hdrFixture(directory)

        // Keep the old gain-map contract as a LEGACY replay check. Revision 12
        // has independent HDR-domain/edge checks, not this formula as an oracle.
        let legacyRecipe = ProcessingRecipe(mode: .hncs, exposureEV: 0, illuminantKelvin: 6500,
            simulationIndex: 0, seed: 0, hncs: .legacyStandard)
        let processed = try ImagePipeline.process(resources: resources, input, recipe: legacyRecipe)
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
        #expect(try error(pixels(processed.image.image), expected) < 1e-5, "HDR preview did not preserve source highlight ratios through the effect")
        let file = directory.appendingPathComponent("hdr-metadata.heic")
        try ImagePipeline.writeHEIF(resources: resources, processed, to: file)
        guard let container = CGImageSourceCreateWithURL(file as CFURL, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any],
              let decoded = CGImageSourceCreateImageAtIndex(container, 0,
                  [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary),
              let image = CIImage(contentsOf: file, options: [.expandToHDR: true]) else {
            throw CheckFailure(description: "HDR HEIF could not be reopened")
        }
        #expect((metadata[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10, "HDR export lacks 10-bit PQ color encoding")
        #expect(decoded.colorSpace?.isHDR() == true, "HDR export lacks 10-bit PQ color encoding")
        #expect((pixels(image).max() ?? 0) > 2, "HDR metadata exists but encoded pixels were clipped to SDR")
    }

    @Test(arguments: ["standard", "square-crop", "film-grain-artistic", "high", "ffcs-neutral", "ffcs-overlay", "downsample"].flatMap { name in [false, true].map { (name, $0) } } + [("camera24", false)])
    static func fullSourceExport_matchesWholeFrameAndDirectEncoding(scenario: (String, Bool)) throws {
        let work = try TestDirectory()
        let directory = work.url
        let (name, hdr) = scenario
        let requestedScale: Double = name == "downsample" ? 0.5 : 1
        let explicitSettings: ExportSettings? = name == "camera24" ? .camera(24) : nil
        let input = try hdr ? hdrFixture(directory) : fixture(directory,
            width: name == "downsample" ? 256 : (name == "camera24" ? 200 : 257),
            height: name == "downsample" ? 384 : (name == "camera24" ? 300 : 389))
        let recipe: ProcessingRecipe
        if name.hasPrefix("ffcs") {
            recipe = ProcessingRecipe(mode: .ffcs, exposureEV: 0, illuminantKelvin: 6500, simulationIndex: 0, seed: 0,
                hncs: .standard, ffcs: FFCSSettings(applyReferenceAdjustments: name == "ffcs-overlay", sharpenRadius: 2.3))
        } else { recipe = Self.recipe(["downsample", "camera24"].contains(name) ? "standard" : name) }

        let processed = try ImagePipeline.process(resources: resources, input, recipe: recipe)
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
        let oracle = try ImagePipeline.process(resources: resources, full, recipe: recipe)
        let actualURL = directory.appendingPathComponent(name + "-actual.heic")
        let expectedURL = directory.appendingPathComponent(name + "-expected.heic")
        let settings: ExportSettings = explicitSettings ?? (requestedScale == 1 ? .native : .init(
            targetWidth: Int(Double(input.width) * requestedScale), targetHeight: Int(Double(input.height) * requestedScale)))
        let outputSize = try settings.dimensions(sourceWidth: full.width, sourceHeight: full.height, crop: recipe.crop)
        let scale = explicitSettings == nil ? requestedScale : Double(outputSize.height) / Double(processed.image.height)
        try ImagePipeline.writeHEIF(resources: resources, processed, to: actualURL, settings: settings)
        let directURL = directory.appendingPathComponent(name + "-direct.heic")
        var sourceDimensions: (Int, Int)?
        let directRecipe = try ImagePipeline.writeHEIF(resources: resources, sourceFile: input.sourceFile, recipe: recipe,
            to: directURL, settings: settings, onSourceDimensions: { sourceDimensions = ($0, $1) })
        #expect(sourceDimensions.map { [$0.0, $0.1] } == [full.width, full.height])
        #expect(directRecipe == processed.recipe, "Direct export changed the frozen white balance or recipe")
        guard let directImage = CIImage(contentsOf: directURL, options: [.expandToHDR: true]),
              let legacyImage = CIImage(contentsOf: actualURL, options: [.expandToHDR: true]) else {
            throw CheckFailure(description: "Direct HEIF output cannot be decoded")
        }
        #expect(try error(pixels(directImage), pixels(legacyImage)) == 0, "Skipping the RAW effect preview changed encoded image pixels")
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
        #expect(actualImage.extent == expectedImage.extent, "HEIF output dimensions differ")
        let maximum = try error(pixels(actualImage), pixels(expectedImage))
        #expect(maximum < 0.02, "Full-source HEIF \(name) differs from the whole-frame oracle: \(maximum)")
        print("  \(name): maximum decoded HEIF difference \(maximum)")
    }

    @Test func absentBaselineSharpness_usesNativeZero() throws {
        #expect(try ImagePipeline.baselineSharpness(in: [:]) == 0)
    }
    @Test(arguments: [0.0, 0.5, 1.0, 1.5, 2.0])
    func rawBaselineSharpness_preservesMetadata(value: Double) throws {
        #expect(try ImagePipeline.baselineSharpness(in: [kCGImagePropertyDNGDictionary as String:
            [kCGImagePropertyDNGBaselineSharpness as String: value]]) == value)
    }
    @Test(arguments: [-1.0, .nan, .infinity])
    func malformedBaselineSharpness_rejectsNonfiniteOrNegative(value: Double) {
        #expect(throws: PipelineError.self) {
            try ImagePipeline.baselineSharpness(in: [kCGImagePropertyDNGDictionary as String:
                [kCGImagePropertyDNGBaselineSharpness as String: value]])
        }
    }
    @Test func stringBaselineSharpness_isRejected() {
        #expect(throws: PipelineError.self) {
            try ImagePipeline.baselineSharpness(in: [kCGImagePropertyDNGDictionary as String:
                [kCGImagePropertyDNGBaselineSharpness as String: "1.5"]])
        }
    }

}
