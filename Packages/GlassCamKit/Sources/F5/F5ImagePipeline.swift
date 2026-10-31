import ImagingCore
import Capture
import Foundation
import CoreImage
import Metal
import ImageIO

struct F5LinearImage: SceneLinearImage {
    func validatedWhiteBalance() throws -> PhotoWhiteBalance {
        let white = color.whiteBalance
        guard white.isValid, color.whiteBalanceOwner == "matrix" else {
            throw F5Failure(.colorTransformInvalid, "Invalid F5 white-balance ownership.")
        }
        return white
    }
    var sourceISO: Int { Int(reference.actualISO.rounded()) }
    var baselineSharpness: Double { reference.metadata.baselineSharpness ?? 0 }
    let raster: ExportRasterFile
    let width: Int, height: Int, orientation: Int
    let color: F5ColorTransformRecord
    let quality: F5QualityReport
    let reference: F5FrameRecord
    var photoMetadata: PhotoMetadata {
        reference.metadata.photographic?.photoMetadata ?? PhotoMetadata(properties: [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifExposureTime as String: reference.actualExposure,
                kCGImagePropertyExifISOSpeedRatings as String: [reference.actualISO],
                kCGImagePropertyExifFNumber as String: reference.aperture]])
    }
    func provenance(_ manifest: F5BurstManifest) -> F5CaptureProvenance {
        F5CaptureProvenance(decodeRevision:F5Version.decoder,colorBridgeRevision:color.colorBridgeRevision,
            profileSHA256:quality.profileSHA256,referenceFrameID:reference.id,
            inputWidth:reference.raster.activeArea.width,inputHeight:reference.raster.activeArea.height,
            frameSHA256:manifest.frames.sorted{$0.burstIndex<$1.burstIndex}.map(\.dng.sha256),
            actualExposures:manifest.frames.sorted{$0.burstIndex<$1.burstIndex}.map(\.actualExposure),whiteBalanceOwner:"matrix",
            transformSHA256:color.hash,qualityClassCounts:quality.qualityClassCounts,flags:quality.flags,solveStatus:quality.solveStatus)
    }
    var image: CIImage {
        get throws {
            guard let linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB) else {throw F5Failure(.colorTransformInvalid,"Linear sRGB is unavailable.")}
            let oriented=try raster.tiledImage(width:width,height:height,colorSpace:linear)
                .oriented(forExifOrientation:Int32(orientation))
            return oriented.transformed(by:CGAffineTransform(translationX:-oriented.extent.minX,y:-oriented.extent.minY))
        }
    }
    func validateImageReads() throws { try raster.validateImageReads() }
}

enum F5ImagePipeline {
    typealias Result = CaptureRenderResult
    static func render(resources: ColorResources, _ source: F5BurstSource, snapshot: CaptureSnapshot, progress: @escaping @Sendable (Double)->Void,
                       isCancelled: @escaping @Sendable ()->Bool, shaderURL: URL? = nil, archiveRoot: URL? = nil) throws -> Result {
        guard snapshot.recipe.isValid, snapshot.quality.bayerFrameCount == source.manifest.frames.count else {
            throw F5Failure(.damagedBundle,"The Bayer frame count does not match the frozen capture mode.")
        }
        let reconstruction = try autoreleasepool {
            try F5Reconstructor.reconstruct(source,shaderURL:shaderURL,progress:{progress($0*0.7)},isCancelled:isCancelled)
        }
        if snapshot.quality == .balanced, snapshot.rawArchiveID != nil {
            _ = try archive(reconstruction,source: source,snapshot: snapshot,archiveRoot: archiveRoot,isCancelled: isCancelled)
        }
        let provenance=reconstruction.provenance(source.manifest)
        let metadata=reconstruction.photoMetadata.addingCaptureProvenance("GlassCam F5\n" + String(decoding:try F5Hash.json(provenance),as:UTF8.self))
        let output=TemporaryHEIFFile(captureDate:metadata.captureDate)
        let recipe=try ImagePipeline.writeF5HEIF(resources: resources, reconstruction,metadata:metadata,recipe:snapshot.recipe,to:output.url,
            isCancelled:isCancelled,progress:{progress(0.7+0.3*$0)})
        return .init(file:output,snapshot:CaptureSnapshot(recipe:recipe,output:snapshot.output,quality:snapshot.quality,f5:provenance,archiveF5RAW:snapshot.archiveF5RAW,rawArchiveID:snapshot.rawArchiveID))
    }

    static func archiveRAW(_ source: F5BurstSource,snapshot: CaptureSnapshot,
                           progress: @escaping @Sendable (Double) -> Void,isCancelled: @escaping @Sendable () -> Bool,
                           shaderURL: URL? = nil,archiveRoot: URL? = nil) throws -> URL {
        guard snapshot.quality == .balanced, source.manifest.frames.count == 4, snapshot.rawArchiveID != nil else {
            throw F5Failure(.damagedBundle,"RAW scene recording requires a four-frame Balanced capture and an archive ID.")
        }
        let reconstruction = try autoreleasepool {
            try F5Reconstructor.reconstruct(source,shaderURL:shaderURL,progress: { progress($0 * 0.9) },isCancelled:isCancelled)
        }
        let destination = try archive(reconstruction,source:source,snapshot:snapshot,archiveRoot:archiveRoot,isCancelled:isCancelled)
        progress(1)
        return destination
    }

    private static func archive(_ reconstruction: F5LinearImage, source: F5BurstSource,snapshot: CaptureSnapshot,
                                archiveRoot: URL?,isCancelled: @escaping @Sendable () -> Bool) throws -> URL {
        guard let id = snapshot.rawArchiveID else { throw CaptureJournal.Failure.damaged }
        return try CaptureRAWStore.retain(id: id,quality: .balanced,
                sourceIdentity: source.manifest.id.uuidString + ":" + reconstruction.color.hash + ":" + F5Version.build,root: archiveRoot) { directory in
                try F5FloatArchive.write(input: source.directory.appendingPathComponent("linear-camera.f32"),
                    to: directory.appendingPathComponent("balanced-camera.dng"),width: reconstruction.width,height: reconstruction.height,
                    reference: reconstruction.reference,cameraDNG: true,whiteScale: reconstruction.color.inputScale,cancelled: isCancelled)
                try F5FloatArchive.write(input: reconstruction.raster.url,to: directory.appendingPathComponent("balanced-linear.tiff"),
                    width: reconstruction.width,height: reconstruction.height,reference: reconstruction.reference,
                    cameraDNG: false,whiteScale: reconstruction.color.inputScale,cancelled: isCancelled)
                for (name,data) in [("capture.json",try F5Hash.json(snapshot)),("color-transform.json",try F5Hash.json(reconstruction.color)),
                    ("source-metadata.json",try F5Hash.json(reconstruction.reference.metadata))] {
                    try CaptureJournal.writeProtected(data,to: directory.appendingPathComponent(name))
                }
            }
    }

}

enum F5Reconstructor {
    static func reconstruct(_ source: F5BurstSource, shaderURL: URL? = nil,
                            progress: @escaping (Double) -> Void = { _ in },
                            isCancelled: @escaping () -> Bool = { false }) throws -> F5LinearImage {
        let start = ProcessInfo.processInfo.systemUptime, manifest = source.manifest
        var flags = try manifest.validate(directory: source.directory)
        guard !flags.contains(.isoChanged) else {
            throw F5Failure(.isoChanged, "Bayer frames have inconsistent ISO values. The original RAW frames were retained.")
        }
        let incompatible: Set<F5Code> = [.physicalCameraChanged, .apertureChanged, .focusChanged, .profileMismatch, .nonuniformMains]
        guard flags.isDisjoint(with: incompatible) else {
            throw F5Failure(.profileMismatch, "The Bayer imaging configuration or main exposure changed during capture.")
        }
        let all = manifest.frames.sorted { $0.burstIndex < $1.burstIndex }
        let mains = all.filter { $0.role == .main }
        guard [1,4].contains(mains.count) else { throw F5Failure(.frameMissing, "Bayer rendering requires one or four main frames.") }
        // The second main frame is the temporal reference used by the selected
        // curvature reconstruction. C++ consumes reference-first frame order.
        let reference = mains[min(1,mains.count - 1)]
        let ordered = [reference] + mains.filter { $0.id != reference.id }
        let profile: F5DeviceProfile
        if let supplied = manifest.profile { profile = supplied }
        else {
            guard !manifest.synthetic else { throw F5Failure(.profileMismatch, "Synthetic RAW requires an explicit synthetic noise model.") }
            profile = try F5BayerModel.make(reference, hardware: manifest.hardwareModel, os: manifest.osBuild)
        }
        try profile.validate(synthetic: manifest.synthetic, requireProduct: false)
        guard mains.allSatisfy({ profile.matches($0, hardware: manifest.hardwareModel, os: manifest.osBuild) }) else {
            throw F5Failure(.profileMismatch, "The Bayer frames do not match their sensor characterization.")
        }
        let width = reference.raster.activeArea.width, height = reference.raster.activeArea.height
        let scale = mains.count == 1 ? 1 : 2
        let capacity = try source.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        let required = Int64(width) * Int64(height) * Int64(scale * scale) * 48 + 128 * 1024 * 1024
        if let capacity, capacity < required { throw CocoaError(.fileWriteOutOfSpace) }
        let color = try F5ColorBridge.rendering(metadata: reference.metadata, profile: profile)
        let device = try F5MetalDevice(maximumBytes: profile.policy.maximumWorkingBytes, shaderURL: shaderURL, isCancelled: isCancelled)
        let times = mains.map(\.actualExposure).sorted()
        let exposure = times.count == 1 ? times[0] : (times[1] + times[2]) / 2
        let result = try autoreleasepool {
            try cameraRaster(ordered, source: source, profile: profile, mainExposure: exposure,
                             scale: scale, device: device, progress: { progress($0 * 0.85) })
        }
        for tile in result.tiles { flags.formUnion(tile.flags) }
        var report = F5QualityReport(referenceFrameID: reference.id, profileSHA256: profile.hash,
            captureSpanMS: manifest.captureSpanMS, actualFrameCount: all.count,
            solveStatus: mains.count == 1 ? "RAW_SINGLE_CURVATURE" : "CURVATURE_NATIVE_FUSION",
            flags: flags.sorted { $0.rawValue < $1.rawValue }, objectiveEpochs: [], tiles: result.tiles)
        let output = try F5CurvatureOutput.write(result.raster, nativeWidth: width, nativeHeight: height,
            metadata: reference.metadata, matrix: color.cameraToLinearSRGB.values, device: device,
            progress: { progress(0.85 + $0 * 0.15) })
        try persistCamera(output, reference: reference, color: color, scale: scale, directory: source.directory)
        report.processingSeconds = ProcessInfo.processInfo.systemUptime - start
        report.allocatedBytes = device.peakBytes
        try CaptureJournal.writeProtected(F5Hash.json(report), to: source.directory.appendingPathComponent("quality.json"))
        try CaptureJournal.writeProtected(F5Hash.json(color), to: source.directory.appendingPathComponent("color-transform.json"))
        progress(1)
        return .init(raster: output.linear, width: output.width, height: output.height,
                     orientation: reference.raster.orientation, color: color, quality: report, reference: reference)
    }

    private static func cameraRaster(_ records: [F5FrameRecord], source: F5BurstSource, profile: F5DeviceProfile,
                                     mainExposure: Double, scale: Int, device: F5MetalDevice,
                                     progress: @escaping (Double) -> Void) throws -> (raster: F5CurvatureRaster.Result, tiles: [F5QualityReport.Tile]) {
        let reference = records[0], width = reference.raster.activeArea.width, height = reference.raster.activeArea.height
        // Integer uploads are freed after normalization, before FFT workspaces
        // are allocated. Numerical image processing stays in C++ / Metal.
        let decoded = try normalize(records, directory: source.directory, profile: profile, mainExposure: mainExposure, device: device)
        let phases = reference.raster.cfa
        let cfa = phases.map { UInt32($0.color) }
        let exposure = reference.actualExposure / mainExposure
        let alpha = phases.map { Float(profile.noise[$0.rawValue].kappa / (exposure * profile.noise[$0.rawValue].gain)) }
        let beta = phases.map { Float(pow(profile.noise[$0.rawValue].readSigma / (exposure * profile.noise[$0.rawValue].gain), 2)) }
        let registration = try F5CurvatureRegistration(device: device, width: width, height: height, frames: records.count,
            cfa: cfa, alpha: alpha, beta: beta, raw: decoded.values, kinds: decoded.kinds, progress: { progress($0 * 0.25) })
        let tiles = support(registration, records: records)
        let prepared = try F5CurvatureBayerSource(device: device, width: width, height: height, frames: records.count, tileSize: 16,
            cfa: cfa, alpha: alpha, beta: beta, raw: decoded.values, flow: registration.flow, reliability: registration.reliability)
        let raster = try F5CurvatureRaster(device: device).reconstruct(source: prepared, scale: scale,
            progress: { progress(0.25 + $0 * 0.75) })
        return (raster, tiles)
    }

    private static func normalize(_ records: [F5FrameRecord], directory: URL, profile: F5DeviceProfile,
                                  mainExposure: Double, device: F5MetalDevice) throws -> F5CurvatureRAW {
        let frames = try records.map { record in
            let codes = try Data(contentsOf: record.mosaic.url(in: directory), options: .mappedIfSafe)
            let canonical = try F5CanonicalFrame(record: record, codes: codes, profile: profile, mainExposure: mainExposure)
            return try F5MetalFrame.upload(canonical, to: device)
        }
        return try F5CurvatureRAW(frames: frames, device: device)
    }

    private static func support(_ registration: F5CurvatureRegistration, records: [F5FrameRecord]) -> [F5QualityReport.Tile] {
        let columns = (registration.width + 31) / 32, rows = (registration.height + 31) / 32
        let buffer = registration.summary
        defer { withExtendedLifetime(buffer) {} }
        let summaries = buffer.metal.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        return (0..<columns * rows).map { i in
            let values = (0..<records.count).map { summaries[$0 * columns * rows + i] }
            let excluded = values.indices.filter { $0 > 0 && values[$0].x < 0.05 }
            let support: F5QualityReport.Support = records.count == 1 || excluded.count == records.count - 1 ? .referenceOnly : .nativeFusion
            var flags: [F5Code] = excluded.isEmpty ? [] : [.occlusion]
            if values.allSatisfy({ $0.y > 0.99 }) { flags.append(.highlightMissing) }
            let x = i % columns * 32, y = i / columns * 32
            // Curvature uses photometric reliability, not the old spline
            // optimizer's objective, conditional rank or convergence claim.
            return .init(x: x, y: y, width: min(32,registration.width-x), height: min(32,registration.height-y), support: support,
                flags: flags, validFractions: values.map { Double(max(0,1-$0.y-$0.z-$0.w)) },
                upperCensoredFractions: values.map { Double($0.y) }, lowerCensoredFractions: values.map { Double($0.z) },
                residualRMS: 0, minimumInformation: 0, conditionNumber: 0, shortOnly: false,
                excludedFrames: excluded.map { records[$0].burstIndex })
        }
    }

    private static func persistCamera(_ output: F5CurvatureOutput.Result, reference: F5FrameRecord,
                                      color: F5ColorTransformRecord, scale: Int, directory: URL) throws {
        let final = directory.appendingPathComponent("linear-camera.f32")
        let pending = directory.appendingPathComponent("linear-camera-writing-\(UUID().uuidString).f32")
        try FileManager.default.copyItem(at: output.camera.url, to: pending)
        if FileManager.default.fileExists(atPath: final.path) { _ = try FileManager.default.replaceItemAt(final, withItemAt: pending) }
        else { try FileManager.default.moveItem(at: pending, to: final) }
        let post = try F5PostOperations.records(reference.metadata)
        let descriptor: [String: Any] = ["revision": F5Version.decoder, "semantics": "camera_linear_no_wb",
            "width": output.width, "height": output.height, "channels": 4, "alpha": 1,
            "layout": "interleaved_top_to_bottom", "component": "float32", "byte_order": "little",
            "row_bytes": output.width * 16, "orientation": reference.raster.orientation,
            "reference_frame_id": reference.id, "profile_sha256": color.profileSHA256, "white_scale": color.inputScale,
            "sha256": try F5Hash.file(final), "post_reconstruction_warp_count": post.warpCount,
            "post_reconstruction_gain_map_count": post.gainCount, "post_opcode_ids": post.ids.map(Int.init),
            "opcode_range_policy": F5Version.opcodeRangePolicy, "default_crop_origin": reference.metadata.cropOrigin,
            "output_scale": scale, "baseline_exposure_owner": "camera_to_linear_matrix"]
        try CaptureJournal.writeProtected(JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys]),
                                          to: directory.appendingPathComponent("linear-camera.json"))
    }
}

// Preserve the format-specific entry for existing F5 callers.
extension ImagePipeline {
    static func writeF5HEIF(resources: ColorResources, _ image: F5LinearImage, metadata: PhotoMetadata,
        recipe: ProcessingRecipe, to url: URL, isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (Double) -> Void) throws -> ProcessingRecipe {
        try writeLinearHEIF(resources: resources, image, metadata: metadata, recipe: recipe, to: url,
            isCancelled: isCancelled, progress: progress)
    }
}
