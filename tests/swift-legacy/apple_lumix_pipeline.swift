// Exercises production settings, preview dispatch, strip export and HDR encoding.
import Foundation
import CoreImage
import ImageIO

private enum Failure: Error { case check(String) }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure.check(message) }
}

@main struct LUMIXPipelineChecks {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue])
        func pixels(_ image: CIImage) -> [Float] {
            let width = Int(image.extent.width), height = Int(image.extent.height)
            var output = [Float](repeating: 0, count: width*height*4)
            output.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: width*16, bounds: image.extent,
                               format: .RGBAf, colorSpace: linear)
            }
            return output
        }
        func maximumDifference(_ a: [Float], _ b: [Float]) throws -> Float {
            try require(a.count == b.count, "Image dimensions changed during processing")
            return zip(a, b).map { abs($0 - $1) }.max() ?? 0
        }
        func lumixRecipe(_ settings: LUMIXSettings = .standard, ev: Double = 0,
                         pipelineRevision: Int = ProcessingRecipe.currentPipelineRevision) -> ProcessingRecipe {
            ProcessingRecipe(mode: .lumix, exposureEV: ev, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 0, hncs: .standard, lumix: settings, pipelineRevision: pipelineRevision)
        }
        // An image taller than two export strips, with saturated colors and >1 headroom.
        let width = 33, height = 131
        var rgba = [Float](repeating: 1, count: width*height*4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y*width+x)*4
            rgba[offset] = 0.08 + Float(x)/Float(width-1)*2.4
            rgba[offset+1] = 0.08 + Float(y)/Float(height-1)*2.4
            rgba[offset+2] = 0.12 + Float((x+y)%11)/10*2
        } }
        let sourceRaster = try PreviewRaster(linearRGBA: rgba, width: width, height: height)
        let sourceURL = directory.appendingPathComponent("source.tiff")
        try context.writeTIFFRepresentation(of: sourceRaster.image, to: sourceURL, format: .RGBAf,
                                            colorSpace: linear, options: [:])
        let retained = try SourceImageFile(data: Data(contentsOf: sourceURL), fileExtension: "tiff")
        let input = ImportedImage(sourceFile: retained, exportSettings: .native,
            linearRGB: (0..<(width*height)).flatMap { Array(rgba[($0*4)..<($0*4+3)]) },
            width: width, height: height, original: sourceRaster, sourceDescription: "Float32 HDR fixture")
        // Full-source export must be compared against full-source decoded pixels.
        // The preview's ImageIO thumbnail decoder can produce different HDR chroma.
        let decoded = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true, .expandToHDR: true])!
        let fullRGBA = pixels(decoded)
        let full = ImportedImage(sourceFile: input.sourceFile, exportSettings: .native,
            linearRGB: (0..<(width*height)).flatMap { Array(fullRGBA[($0*4)..<($0*4+3)]) },
            width: width, height: height, original: try PreviewRaster(linearRGBA: fullRGBA, width: width, height: height),
            sourceDescription: "Full-source HDR oracle")
        func floatInput(_ values: [Float], width: Int, height: Int) throws -> ImportedImage {
            ImportedImage(sourceFile: retained, exportSettings: .native,
                linearRGB: (0..<(width*height)).flatMap { Array(values[($0*4)..<($0*4+3)]) },
                width: width, height: height, original: try PreviewRaster(linearRGBA: values, width: width, height: height),
                sourceDescription: "Exposure fixture")
        }
        var previews = [[Float]]()
        for look in LUMIXEngine.looks {
            let recipe = ProcessingRecipe(mode: .lumix, exposureEV: 0, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 0, hncs: .standard, lumix: LUMIXSettings(photoStyle: look.id))
            try require(recipe.isValid, "Invalid listed LUMIX recipe")
            let processed = try ImagePipeline.process(input, recipe: recipe)
            try require(processed.recipe.mode == .lumix && processed.recipe.lumix.photoStyle == look.id,
                        "The rendered recipe lost the selected Photo Style")
            try require(processed.recipe.photoWhiteBalance == input.whiteBalance && processed.recipe.crop == .none,
                        "LUMIX changed the photo white point or framing")
            let values = pixels(processed.image.image)
            try require(values.allSatisfy(\.isFinite) && (values.max() ?? 0) > 1,
                        "LUMIX preview is invalid or clipped HDR headroom")
            previews.append(values)
            if ["standard", "l-monochrome"].contains(look.id) {
                let output = directory.appendingPathComponent(look.id+".heic")
                try ImagePipeline.writeHEIF(processed, to: output)
                guard let image = CIImage(contentsOf: output, options: [.expandToHDR: true]),
                      let container = CGImageSourceCreateWithURL(output as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [String: Any] else {
                    throw Failure.check("Could not reopen LUMIX HEIF")
                }
                try require(Int(image.extent.width) == width && Int(image.extent.height) == height,
                            "LUMIX full-source export changed dimensions")
                try require((properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue == 10,
                            "LUMIX export lost 10-bit encoding")
                let actual = pixels(image)
                try require((actual.max() ?? 0) > 1 && actual.allSatisfy(\.isFinite), "Export lost HDR pixels")
                let oracle = try ImagePipeline.process(full, recipe: recipe)
                var expected = oracle.image.image
                if #available(macOS 26, *) { expected = expected.settingContentHeadroom(max(1, pixels(expected).max() ?? 1)) }
                let expectedURL = directory.appendingPathComponent(look.id+"-expected.heic")
                try context.writeHEIF10Representation(of: expected, to: expectedURL, colorSpace: pq, options: [:])
                let expectedPixels = pixels(CIImage(contentsOf: expectedURL, options: [.expandToHDR: true])!)
                let maximumError = zip(expectedPixels, actual).map { abs($0-$1) }.max() ?? 0
                try require(maximumError < 0.02, "Strip export differs from full-frame original LUT output: \(maximumError)")
                let directURL = directory.appendingPathComponent(look.id+"-direct.heic")
                let directRecipe = try ImagePipeline.writeHEIF(sourceFile: input.sourceFile, recipe: recipe,
                    to: directURL, settings: .native)
                let directPixels = pixels(CIImage(contentsOf: directURL, options: [.expandToHDR: true])!)
                try require(directRecipe == processed.recipe, "Skipping the preview changed the frozen LUMIX recipe: \(directRecipe) versus \(processed.recipe)")
                let directError = zip(directPixels, actual).map { abs($0-$1) }.max() ?? 0
                try require(directError == 0, "Skipping the preview changed \(look.name) exported pixels: max \(directError)")
                print("PASS HDR HEIF \(look.name): full-frame/strip max difference \(maximumError)")
            }
        }
        try require(zip(previews[0],previews[1]).contains { abs($0-$1) > 0.01 }, "Standard and Vivid rendered identically")

        // Exposure must be equivalent to scaling scene-linear source pixels,
        // including colored highlights crossing 1.0 and multiple export strips.
        for style in ["standard", "l-monochrome"] {
            for ev: Double in [-2, -1, 1, 2] {
                let recipe = lumixRecipe(LUMIXSettings(photoStyle: style), ev: ev)
                let actual = try ImagePipeline.process(full, recipe: recipe)
                var scaled = fullRGBA
                let scale = Float(exp2(ev))
                for pixel in 0..<(width*height) { for channel in 0..<3 { scaled[pixel*4+channel] *= scale } }
                let expected = try ImagePipeline.process(floatInput(scaled, width: width, height: height),
                    recipe: lumixRecipe(LUMIXSettings(photoStyle: style)))
                try require(try maximumDifference(pixels(actual.image.image), pixels(expected.image.image)) == 0,
                            "LUMIX exposure clipped HDR magnitude or changed highlight color")
                let label = "\(style)-ev\(ev)"
                let output = directory.appendingPathComponent(label+".heic")
                let direct = directory.appendingPathComponent(label+"-direct.heic")
                let oracle = directory.appendingPathComponent(label+"-expected.heic")
                try ImagePipeline.writeHEIF(actual, to: output)
                _ = try ImagePipeline.writeHEIF(sourceFile: retained, recipe: recipe, to: direct, settings: .native)
                try context.writeHEIF10Representation(of: expected.image.image, to: oracle, colorSpace: pq, options: [:])
                let outputPixels = pixels(CIImage(contentsOf: output, options: [.expandToHDR: true])!)
                try require(try maximumDifference(outputPixels, pixels(CIImage(contentsOf: direct, options: [.expandToHDR: true])!)) == 0,
                            "Direct and previewed LUMIX exposure exports differ")
                try require(try maximumDifference(outputPixels, pixels(CIImage(contentsOf: oracle, options: [.expandToHDR: true])!)) < 0.02,
                            "Strip export did not apply exposure before HDR splitting")
            }
        }
        let bright = try floatInput([2, 2, 2, 1], width: 1, height: 1)
        for ev: Double in [0, 1, 2] {
            let result = try ImagePipeline.process(bright, recipe: lumixRecipe(ev: ev))
            let value = Float(2 * exp2(ev))
            try require(pixels(result.image.image).prefix(3).allSatisfy { abs($0 - value) < 0.0001 },
                        "Positive exposure stopped increasing HDR white")
        }
        // Frozen photos keep their original rendering; only new camera recipes
        // migrate to the current revision, including preferences saved by v2.
        let v2 = try JSONDecoder().decode(LUMIXSettings.self,
            from: Data("{\"photoStyle\":\"standard\",\"renderRevision\":2}".utf8))
        try require(v2.isValid, "Saved LUMIX v2 is no longer supported")
        for ev: Double in [0, 1, 2] {
            let result = try ImagePipeline.process(bright, recipe: lumixRecipe(v2, ev: ev, pipelineRevision: 1))
            try require(pixels(result.image.image).prefix(3).allSatisfy { $0 == 2 },
                        "A saved LUMIX v2 photo changed its exposure behavior")
        }
        print("PASS LUMIX HDR exposure: ±1/2 EV, colored highlights, strip/direct export and v2 replay")
        let lumix = LUMIXSettings(photoStyle: "cinelike-d2")
        let frozen = ProcessingRecipe(mode: .lumix, exposureEV: -0.3, illuminantKelvin: 6500,
            simulationIndex: 0, seed: 7, hncs: .standard, lumix: lumix).resolvingWhiteBalance(.renderedD65)
        let restored = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONEncoder().encode(frozen))
        try require(restored == frozen && restored.lumix == lumix, "Durable recipe changed LUMIX settings")
        let suiteName = "GlassCam.LUMIXChecks."+UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = CameraSettingsStore(defaults: defaults)
        settings.lumix = lumix; settings.colorMode = .lumix
        let reloaded = CameraSettingsStore(defaults: defaults)
        try require(reloaded.colorMode == .lumix && reloaded.lumix == lumix, "Camera preferences lost LUMIX")
        defaults.set(try JSONEncoder().encode(lumixRecipe(v2)), forKey: "editor.processingRecipe.revision8.v1")
        let migratedCamera = CameraSettingsStore(defaults: defaults)
        try require(migratedCamera.recipe.lumix.renderRevision == LUMIXSettings.currentRenderRevision && v2.renderRevision == 2,
                    "Migrating future camera captures changed a saved v2 recipe")
        settings.colorMode = .ffcs
        try require(settings.lumix == lumix && frozen.lumix == lumix, "Switching engines changed a frozen recipe")
        // Old recipes keep their engine and white-balance semantics without any LUMIX key.
        for mode in [ColorMode.hncs, .ffcs] {
            let old = ProcessingRecipe(mode: mode, exposureEV: 0, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 0, hncs: .standard)
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
            object.removeValue(forKey: "lumix")
            let migrated = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONSerialization.data(withJSONObject: object))
            try require(migrated == old, "Old \(mode.title) recipe migrated to different pixels")
            _ = try ImagePipeline.process(input, recipe: migrated)
        }
        var invalid = LUMIXSettings.standard; invalid.photoStyle = "not-a-real-look"
        try require(!invalid.isValid, "Unknown Photo Style was accepted")
        invalid = .standard; invalid.contrast = .nan
        try require(!invalid.isValid, "NaN contrast was accepted")
        invalid = .standard; invalid.sourceISO = 0
        try require(!invalid.isValid, "Invalid source ISO was accepted")
        let v1 = try JSONDecoder().decode(LUMIXSettings.self, from: Data("{\"photoStyle\":\"standard\",\"renderRevision\":1}".utf8))
        try require(v1.isValid && v1.renderRevision == 1, "Saved LUMIX v1 recipe changed revisions")
        let oldRecipe = ProcessingRecipe(mode: .lumix, exposureEV: 0, illuminantKelvin: 6500,
            simulationIndex: 0, seed: 0, hncs: .standard, lumix: v1)
        try require(oldRecipe.resolvingLUMIXSourceISO(50).lumix == v1, "A saved v1 photo gained a new ISO correction")
        _ = try ImagePipeline.process(input, recipe: oldRecipe)
        var adjusted = LUMIXSettings(photoStyle: "standard", contrast: 1.5, saturation: -2)
        adjusted.sourceISO = 64
        let adjustedRecipe = ProcessingRecipe(mode: .lumix, exposureEV: 0, illuminantKelvin: 4000,
            simulationIndex: 0, seed: 0, hncs: .standard, lumix: adjusted)
        let adjustedRoundTrip = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONEncoder().encode(adjustedRecipe))
        try require(adjustedRoundTrip == adjustedRecipe, "Per-photo CCT/ISO/contrast/saturation did not survive replay")
        try require(adjustedRecipe.resolvingLUMIXSourceISO(80).lumix.sourceISO == 64, "Export replaced a frozen ISO")
        let currentISO = ProcessingRecipe(mode: .lumix, exposureEV: 0, illuminantKelvin: 6500,
            simulationIndex: 0, seed: 0, hncs: .standard).resolvingLUMIXSourceISO(80)
        try require(currentISO.lumix.sourceISO == 80, "Capture ISO was not bound")
        let resolvedPolicy = currentISO.sourceDecodeRecipe(RAWDecodeRecipe.current.withoutDecoderSharpness)
        try require(resolvedPolicy.rendering == .cameraNeutral && resolvedPolicy.sharpnessAmount == nil,
                    "LUMIX inherited a previous HNCS decoder override")
        // Input policy is durable independently of native engine revisions.
        // A journal written before this field existed must replay its old look.
        for mode in ColorMode.allCases {
            let neutral = ProcessingRecipe(mode: mode, exposureEV: 0, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 0, hncs: .standard)
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(neutral)) as! [String: Any]
            object.removeValue(forKey: "rawInputPolicy")
            let old = try JSONDecoder().decode(ProcessingRecipe.self, from: JSONSerialization.data(withJSONObject: object))
            try require(old.rawInputPolicy == .legacy && neutral.rawInputPolicy == .cameraNeutral,
                        "A missing input policy silently changed an old photo")
            let bound = old.resolvingWhiteBalance(.renderedD65).resolvingLUMIXSourceISO(80)
            try require(bound.rawInputPolicy == .legacy, "Binding capture metadata replaced the old input policy")
            try require(neutral.sourceDecodeRecipe(.current).rendering == .cameraNeutral,
                        "A new \(mode.title) capture kept Apple's global tone curve")
            defaults.set(try JSONEncoder().encode(old), forKey: "editor.processingRecipe.revision8.v1")
            try require(CameraSettingsStore(defaults: defaults).recipe.rawInputPolicy == .cameraNeutral &&
                        old.rawInputPolicy == .legacy, "Future camera migration changed a frozen photo")
        }
        print("PASS input policy: all engines, old journals, metadata binding and camera-only migration")
        // Optional real retained ProRAW. This reads an existing capture only.
        if CommandLine.arguments.count > 2 {
            let rawURL = URL(fileURLWithPath: CommandLine.arguments[2])
            let rawData = try Data(contentsOf: rawURL)
            // Reuse each processed source, as a same-photo editor would. Compare
            // both dimensions and actual pixels with independently selected engines.
            for basePolicy in [RAWDecodeRecipe.current,
                RAWDecodeRecipe(rendering: .sceneLinear, linearExposureEV: -0.5,
                    decoderExposureEV: 0.25, edrAmount: 1, sharpnessAmount: 0.35)] {
                let source = try ImagePipeline.load(data: rawData, fileExtension: "dng",
                    previewMaximumEdge: 256, rawDecode: basePolicy)
                var reused = source
                for mode: ColorMode in [.lumix, .hncs, .ffcs, .lumix] {
                    let target = ProcessingRecipe(mode: mode, exposureEV: 0, illuminantKelvin: 6500,
                        simulationIndex: 0, seed: 0, hncs: .standard)
                    let direct = try ImagePipeline.process(source, recipe: target)
                    let switched = try ImagePipeline.process(reused, recipe: target)
                    try require(switched.source.baseRAWDecode == source.rawDecode &&
                                switched.source.previewMaximumEdge == 256 &&
                                switched.source.rawDecode == direct.source.rawDecode,
                                "Switching from LUMIX lost the original RAW decode configuration")
                    try require(switched.image.width == direct.image.width && switched.image.height == direct.image.height,
                                "Repeated engine changes shrank the RAW preview")
                    try require(try maximumDifference(pixels(switched.image.image), pixels(direct.image.image)) < 0.000001,
                                "The RAW output depends on previously selected color engines")
                    reused = switched.source
                }
            }
            print("PASS real ProRAW engine round trips preserve pixels, dimensions and custom decode settings")
            let photo = try ImagePipeline.load(data: rawData, fileExtension: "dng")
            let recipe = ProcessingRecipe(mode: .lumix, exposureEV: 0, illuminantKelvin: 6500,
                simulationIndex: 0, seed: 0, hncs: .standard)
            let processed = try ImagePipeline.process(photo, recipe: recipe)
            try require(processed.source.rawDecode.rendering == .cameraNeutral, "ProRAW kept Apple's global contrast curve")
            try require(processed.recipe.lumix.sourceISO == photo.sourceISO ?? 100, "ProRAW ISO was not frozen")
            try require(processed.recipe.photoWhiteBalance == processed.source.whiteBalance, "ProRAW white point changed")
            let output = directory.appendingPathComponent("existing-proraw-lumix.heic")
            var dimensions = [Int]()
            let final = try ImagePipeline.writeHEIF(sourceFile: photo.sourceFile, recipe: processed.recipe,
                to: output, settings: .native, onSourceDimensions: { dimensions = [$0, $1] })
            let image = CIImage(contentsOf: output, options: [.expandToHDR: true])!
            try require(dimensions == [Int(image.extent.width), Int(image.extent.height)], "ProRAW export used a preview")
            try require(final == processed.recipe, "ProRAW direct export changed the durable recipe")
            try require((try Data(contentsOf: output)).count > 1000, "ProRAW output is empty")
            let evidence: [String: Any] = ["source": rawURL.path, "output": output.path, "width": dimensions[0],
                "height": dimensions[1], "sourceISO": final.lumix.sourceISO!, "inputRendering": "cameraNeutral",
                "previewWidth": processed.image.width, "previewHeight": processed.image.height,
                "recipe": String(data: try JSONEncoder().encode(final), encoding: .utf8)!]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("existing-proraw.json"))
            print("PASS existing ProRAW → full-size LUMIX HEIF: \(dimensions), ISO \(final.lumix.sourceISO!)")
            // Same retained capture, real decoder settings and full-resolution
            // direct/review exports for all three camera engines.
            let auditInput = try ImagePipeline.load(data: rawData, fileExtension: "dng", previewMaximumEdge: 512)
            var audit = [[String: Any]]()
            for mode in ColorMode.allCases {
                let target = ProcessingRecipe(mode: mode, exposureEV: 0, illuminantKelvin: 6500,
                    simulationIndex: 0, seed: 0, hncs: .standard)
                let after = try ImagePipeline.process(auditInput, recipe: target)
                let inspection = try ImagePipeline.inspectRAW(sourceFile: auditInput.sourceFile,
                    recipe: after.source.rawDecode)
                let configured = inspection["configured"] as! [String: Any]
                let original = inspection["defaults"] as! [String: Any]
                try require((configured["boost_amount"] as! NSNumber).floatValue == 0 &&
                            (configured["baseline_exposure"] as! NSNumber) == (original["baseline_exposure"] as! NSNumber) &&
                            (configured["local_tone_map_amount"] as! NSNumber) == (original["local_tone_map_amount"] as! NSNumber) &&
                            (configured["edr_amount"] as! NSNumber).floatValue == 1,
                            "\(mode.title) removed the photo's exposure/local map or retained global contrast")
                var legacyLUMIX = LUMIXSettings.standard; legacyLUMIX.renderRevision = 3
                let previous = ProcessingRecipe(mode: mode, exposureEV: 0, illuminantKelvin: 6500,
                    simulationIndex: 0, seed: 0, hncs: .standard, lumix: legacyLUMIX, rawInputPolicy: .legacy)
                let before = try ImagePipeline.process(auditInput, recipe: previous)
                for (label, raster) in [("before", before.image), ("after", after.image)] {
                    let name = mode.rawValue+"-"+label
                    let values = pixels(raster.image)
                    try values.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent(name+".rgba32f")) }
                    let diagnostic = raster.image.applyingFilter("CIColorClamp", parameters: [
                        "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)]).cropped(to: raster.image.extent)
                    try context.writePNGRepresentation(of: diagnostic, to: directory.appendingPathComponent(name+".png"),
                        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
                }
                let output = directory.appendingPathComponent(mode.rawValue+"-neutral-full.heic")
                let direct = directory.appendingPathComponent(mode.rawValue+"-neutral-direct.heic")
                try ImagePipeline.writeHEIF(after, to: output)
                let bound = try ImagePipeline.writeHEIF(sourceFile: auditInput.sourceFile, recipe: target,
                    to: direct, settings: .native)
                try require(bound == after.recipe && (try Data(contentsOf: output)) == (try Data(contentsOf: direct)),
                            "\(mode.title) direct/review real ProRAW exports differ")
                let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(output as CFURL, nil)!, 0, nil)! as NSDictionary
                try require((props[kCGImagePropertyDepth] as! NSNumber).intValue == 10,
                            "\(mode.title) lost 10-bit output")
                audit.append(["mode": mode.rawValue, "inspection": inspection,
                    "previewWidth": after.image.width, "previewHeight": after.image.height,
                    "fullWidth": props[kCGImagePropertyPixelWidth]!, "fullHeight": props[kCGImagePropertyPixelHeight]!,
                    "directReviewBytesIdentical": true, "output": output.path])
                print("PASS \(mode.title) camera-neutral RAW; full-source direct/review HEIF bytes identical")
                fflush(stdout)
            }
            try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("camera-neutral-audit.json"))
        }
        print("PASS 16 LUMIX previews, HDR export, immutable recipes, preference restoration, HNCS/FFCS compatibility")
    }
}
