import Foundation
import CoreImage
import Metal
import ImageIO

struct F5LinearImage {
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
        F5CaptureProvenance(decodeRevision:F5Version.decoder,colorBridgeRevision:F5Version.colorBridge,
            profileSHA256:quality.profileSHA256,referenceFrameID:reference.id,
            inputWidth:reference.raster.activeArea.width,inputHeight:reference.raster.activeArea.height,
            frameSHA256:manifest.frames.sorted{$0.burstIndex<$1.burstIndex}.map(\.dng.sha256),
            actualExposures:manifest.frames.sorted{$0.burstIndex<$1.burstIndex}.map(\.actualExposure),whiteBalanceOwner:"matrix",
            transformSHA256:color.hash,qualityClassCounts:quality.qualityClassCounts,flags:quality.flags,solveStatus:quality.solveStatus)
    }
    var image: CIImage {
        get throws {
            let data=try raster.mappedData(expectedBytes:width*height*16)
            guard let linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB) else {throw F5Failure(.colorTransformInvalid,"Linear sRGB is unavailable.")}
            let oriented=CIImage(bitmapData:data,bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:linear)
                .oriented(forExifOrientation:Int32(orientation))
            return oriented.transformed(by:CGAffineTransform(translationX:-oriented.extent.minX,y:-oriented.extent.minY))
        }
    }
}

enum F5ImagePipeline {
    struct Result { let file: TemporaryHEIFFile, snapshot: CaptureSnapshot }
    static func render(resources: ColorResources, _ source: F5BurstSource, snapshot: CaptureSnapshot, progress: @escaping @Sendable (Double)->Void,
                       isCancelled: @escaping @Sendable ()->Bool) throws -> Result {
        let reconstruction=try F5Reconstructor.reconstruct(source,progress:{progress($0*0.7)},isCancelled:isCancelled)
        let provenance=reconstruction.provenance(source.manifest)
        let metadata=reconstruction.photoMetadata.addingCaptureProvenance("GlassCam F5\n" + String(decoding:try F5Hash.json(provenance),as:UTF8.self))
        let output=TemporaryHEIFFile(captureDate:metadata.captureDate)
        let recipe=try ImagePipeline.writeF5HEIF(resources: resources, reconstruction,metadata:metadata,recipe:snapshot.recipe,to:output.url,
            isCancelled:isCancelled,progress:{progress(0.7+0.3*$0)})
        return .init(file:output,snapshot:CaptureSnapshot(recipe:recipe,output:snapshot.output,quality:.f5,f5:provenance,archiveF5RAW:snapshot.archiveF5RAW))
    }
}

enum F5Reconstructor {
    static func reconstruct(_ source:F5BurstSource,shaderURL:URL?=nil,progress:(Double)->Void={_ in},
                            isCancelled:@escaping ()->Bool={false}) throws -> F5LinearImage {
        let start=ProcessInfo.processInfo.systemUptime,manifest=source.manifest
        let acquisitionFlags=try manifest.validate(directory:source.directory)
        guard !acquisitionFlags.contains(.isoChanged) else {
            throw F5Failure(.isoChanged,"The delivered frames use different ISO values and cannot share one calibrated noise model. The original RAW frames were retained.")
        }
        guard let profile=manifest.profile else {throw F5Failure(.unqualified,"This recorded burst has no calibrated main-camera profile.")}
        try profile.validate(synthetic:manifest.synthetic)
        let records=manifest.frames.sorted{$0.burstIndex<$1.burstIndex}
        guard records.allSatisfy({profile.matches($0,hardware:manifest.hardwareModel,os:manifest.osBuild)}) else {throw F5Failure(.profileMismatch,"The burst does not match its immutable main-camera profile.")}
        guard !acquisitionFlags.contains(.physicalCameraChanged),!acquisitionFlags.contains(.apertureChanged),!acquisitionFlags.contains(.focusChanged),!acquisitionFlags.contains(.profileMismatch) else {throw F5Failure(.profileMismatch,"The physical imaging configuration changed during the burst.")}
        let mainTimes=records.filter{$0.role == .main}.map(\.actualExposure).sorted(),mainExposure=(mainTimes[1]+mainTimes[2])/2
        let width=records[0].raster.activeArea.width,height=records[0].raster.activeArea.height
        let device=try F5MetalDevice(maximumBytes:profile.policy.maximumWorkingBytes,shaderURL:shaderURL,isCancelled:isCancelled)
        var frames:[F5MetalFrame]=[]
        for record in records {
            let codes=try Data(contentsOf:record.mosaic.url(in:source.directory),options:.mappedIfSafe)
            let frame=try F5CanonicalFrame(record:record,codes:codes,profile:profile,mainExposure:mainExposure)
            frames.append(try F5MetalFrame.upload(frame,to:device))
        }
        let likelihood=try F5MetalLikelihood.load(profile:profile,directory:source.directory,device:device)
        let geometry=try F5GeometryInitializer.make(frames:frames,manifest:manifest,profile:profile,device:device)
        let reference=records[geometry.reference],color=try F5ColorBridge.make(metadata:reference.metadata,profile:profile)
        progress(0.1)
        let scratch=try F5MetalScratch(width:width,height:height,coreSize:profile.policy.blockSize,device:device)
        let nativeCoefficients=try device.allocate(width*height*3*4,label:"F5 native spline coefficients")
        let noise=try device.allocate(width*height*4,label:"F5 frozen native noise scale")
        let refFrame=frames[geometry.reference]
        try device.run { command in
            try device.encode("f5_initialize_native",count:width*height,buffers:[refFrame.raw.metal,refFrame.table.metal,nativeCoefficients.metal,noise.metal],command:command) { F5MetalDevice.value(refFrame.uniforms,at:4,encoder:$0) }
        }
        let native=F5MetalLevel(width:width,height:height,scale:1,reference:geometry.reference,policy:profile.policy,device:device,frames:frames,scratch:scratch,likelihood:likelihood,
            coefficients:nativeCoefficients,noise:noise,motion:geometry.motion,motionDirection:geometry.direction,motionBounds:geometry.bounds,validEventCount:width*height*5)
        native.motionEdgeWeights=geometry.edgeWeights
        _ = try native.countEvents()
        let deadline=start+profile.policy.maximumProcessingSeconds
        let expired={ProcessInfo.processInfo.systemUptime>=deadline}
        var epochs=try native.solve(epoch:0,budgetExpired:expired,progress:{progress(0.1+0.2*$0)})
        guard epochs.contains(where:{!$0.objectives.isEmpty}) else {throw F5Failure(.budgetStop,"The processing budget expired before a native solve could be validated. The five RAW frames were retained.")}
        let firstQuality=try native.quality(alignments:geometry.alignments,requireConvergence:false)
        if firstQuality.contains(where:{!$0.excludedFrames.isEmpty}) {
            try native.reviseEligibility(firstQuality)
            // A safety fallback must finish even when the preferred SR budget
            // has expired. Its time is included in the report, never hidden.
            let fallbackDeadline=max(deadline,ProcessInfo.processInfo.systemUptime+profile.policy.maximumProcessingSeconds)
            let fallbackEpochs = try native.solve(epoch:1,budgetExpired:{ProcessInfo.processInfo.systemUptime>=fallbackDeadline},progress:{progress(0.3+0.1*$0)})
            guard fallbackEpochs.contains(where:{!$0.objectives.isEmpty}) else {
                throw F5Failure(.numericalStall,"The revised native fallback could not be validated. The five RAW frames were retained.")
            }
            epochs += fallbackEpochs
        }
        try native.freezeNoiseScale()
        var finalLevel=native,flags=acquisitionFlags,solveStatus="NATIVE_ONLY"
        let nativeStalled=epochs.contains(where:{$0.stopReason == "NUMERICAL_STALL"})
        if nativeStalled {flags.insert(.numericalStall);solveStatus="NATIVE_NUMERICAL_STALL"}
        let nativeConverged=epochs.last?.stopReason == "CONVERGED"
        if !nativeConverged { flags.insert(.budgetStop) }
        if !geometry.referenceQualified {flags.insert(.motionUncertain)}
        let resolutionSupported=firstQuality.contains { tile in
            tile.support != .referenceOnly && tile.minimumInformation>=profile.policy.minimumModeInformation &&
            tile.conditionNumber<=profile.policy.maximumModeCondition && tile.residualRMS<=profile.policy.maximumResidualSigma
        }
        if nativeConverged && !resolutionSupported {solveStatus="NATIVE_INSUFFICIENT_SR_INFORMATION"}
        if !expired() && nativeConverged && !nativeStalled && resolutionSupported && geometry.referenceQualified && !flags.contains(.nonuniformMains) && !flags.contains(.longCaptureWindow) {
            do {
                let coefficients=try device.allocate(width*height*4*3*4,label:"F5 shared high-resolution spline coefficients")
                var g=native.uniforms;g.step = .zero
                try device.run { command in try device.encode("f5_initialize_high",count:width*height*4*3,buffers:[nativeCoefficients.metal,coefficients.metal,scratch.zero.metal],command:command) { F5MetalDevice.value(g,at:3,encoder:$0) } }
                let highMotion=try device.allocate(native.motion.metal.length,label:"F5 isolated high-resolution motion")
                let highDirection=try device.allocate(native.motionDirection.metal.length,label:"F5 isolated high-resolution motion increment")
                try device.run { command in
                    try device.copy(native.motion.metal,to:highMotion.metal,bytes:highMotion.metal.length,command:command)
                    try device.clear(highDirection.metal,command:command)
                }
                let high=F5MetalLevel(width:width,height:height,scale:2,reference:geometry.reference,policy:profile.policy,device:device,frames:frames,scratch:scratch,likelihood:likelihood,
                    coefficients:coefficients,noise:noise,motion:highMotion,motionDirection:highDirection,motionBounds:native.motionBounds,validEventCount:native.validEventCount)
                high.motionEdgeWeights=geometry.edgeWeights
                let highEpochs=try high.solve(epoch:2,budgetExpired:expired,progress:{progress(0.4+0.4*$0)})
                epochs += highEpochs
                if highEpochs.last?.stopReason == "CONVERGED" {finalLevel=high;solveStatus="CONVERGED"}
                else {flags.insert(.budgetStop)}
            } catch let failure as F5Failure where failure.code == .memoryPressure || failure.code == .numericalStall {
                flags.insert(failure.code)
            }
        } else if expired() {flags.insert(.budgetStop)}
        var quality=try finalLevel.quality(alignments:geometry.alignments,requireConvergence:solveStatus == "CONVERGED",frozenExclusions:firstQuality.map(\.excludedFrames))
        for i in quality.indices {
            quality[i].excludedFrames=firstQuality[i].excludedFrames
            if firstQuality[i].support == .referenceOnly {quality[i].support = .referenceOnly}
            if solveStatus != "CONVERGED",quality[i].support == .fullSR {quality[i].support = .nativeFusion}
        }
        for tile in quality {flags.formUnion(tile.flags)}
        var report=F5QualityReport(referenceFrameID:reference.id,profileSHA256:profile.hash,captureSpanMS:manifest.captureSpanMS,
            actualFrameCount:records.count,solveStatus:solveStatus,flags:flags.sorted{$0.rawValue<$1.rawValue},objectiveEpochs:epochs,tiles:quality)
        let raster:F5MetalLevel.LinearOutput
        do {raster=try finalLevel.writeLinearOutput(native:native,reference:reference,color:color,quality:quality,directory:source.directory)}
        catch let failure as F5Failure where failure.code == .nonfinite && finalLevel !== native {
            // A post-warp SR position is a new constraint. If it fails, sample
            // the already validated native image with positive interpolation.
            for i in quality.indices where quality[i].support == .fullSR {quality[i].support = .nativeFusion;quality[i].flags.append(.responseModelMismatch)}
            report.tiles=quality;report.flags=Array(Set(report.flags+[.responseModelMismatch])).sorted{$0.rawValue<$1.rawValue};report.solveStatus="OUTPUT_NATIVE_FALLBACK"
            raster=try native.writeLinearOutput(native:native,reference:reference,color:color,quality:quality,directory:source.directory)
        }
        report.processingSeconds=ProcessInfo.processInfo.systemUptime-start;report.allocatedBytes=device.peakBytes
        try CaptureJournal.writeProtected(F5Hash.json(report),to:source.directory.appendingPathComponent("quality.json"))
        try CaptureJournal.writeProtected(F5Hash.json(color),to:source.directory.appendingPathComponent("color-transform.json"))
        progress(1)
        return .init(raster:raster.file,width:raster.width,height:raster.height,orientation:reference.raster.orientation,color:color,quality:report,reference:reference)
    }
}
