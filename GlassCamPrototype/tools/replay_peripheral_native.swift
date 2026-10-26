import Foundation
import AVFoundation
import CoreImage
import QuartzCore
import simd
import Metal

/// Full native YUV replay, through the production worker. Virtual observation
/// time permits deterministic image diagnostics; real elapsed work is reported
/// separately and must not be called phone performance or a real video trace.
@main
struct NativeFieldReplay {
    static var selectedTolerance: Double {
        guard let i=CommandLine.arguments.firstIndex(of:"--tolerance"),i+1<CommandLine.arguments.count,
              let value=Double(CommandLine.arguments[i+1]) else {return PeripheralTolerance.defaultValue}
        return PeripheralTolerance.normalized(value)
    }
    static func realClockStatic(_ worker:PeripheralAlignmentWorker,center:CVPixelBuffer,outer:CVPixelBuffer,
        cm:PeripheralFrameMetadata,om:PeripheralFrameMetadata,config:PeripheralFrameSource.Configuration,
        calibration:PeripheralCalibration?,seams:PeripheralSeams,window:CGRect,queueLag:Double) throws -> [String:Any] {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {return ["available":false]}
        let colorSpace=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let context=CIContext(mtlDevice:device,options:[.cacheIntermediates:false,.workingColorSpace:colorSpace])
        let store=PeripheralLiveTextureStore(),live=PeripheralLivePipeline()
        // Cold worker deliberately starts alongside the live renderer. A slow
        // first model request must not delay the raw current wide-angle view.
        let background=PeripheralAlignmentWorker()
        let start=CACurrentMediaTime()
        var serial:UInt64=1000,uploads=0,draws=0,warmDraws=0,warmBlack=0
        var ages:[Double]=[],submissionMS:[Double]=[],opacity=[Double](repeating:1,count:4)
        while CACurrentMediaTime()-start<3 {
            let begun=CACurrentMediaTime();serial &+= 1;draws += 1
            let pair=PeripheralFrameSource.Pair(center:center,outer:outer,receipt:begun-queueLag,configuration:config,
                serial:serial,centerMetadata:cm,outerMetadata:om,calibration:calibration,
                pairingMode:"real-clock-synthetic-current-pixels",measuredFrameInterval:1/60)
            background.request(pair,seams:seams,window:window)
            let frame=live.update(pair:pair,analysis:background.latest(),enabled:true,epoch:1,seams:seams,
                window:window,tolerance:selectedTolerance,at:begun)
            opacity=live.opacities(bundle:store.completed,revision:1,at:begun,tolerance:selectedTolerance)
            let active=(0..<4).filter {$0<2 ? seams.contains(.horizontal):seams.contains(.vertical)}
            if begun-start>0.5 {
                warmDraws += 1
                if active.contains(where:{opacity[$0]>=0.999}) {warmBlack += 1}
            }
            if let frame {
                let command=queue.makeCommandBuffer()!
                if let upload=try store.prepare(frame,revision:1,at:begun,device:device,context:context,
                    command:command,colorSpace:colorSpace) {
                    command.commit();command.waitUntilCompleted();withExtendedLifetime(upload.1) {}
                    let end=CACurrentMediaTime()
                    store.complete(upload.0,success:command.status == .completed,revision:1,epoch:1,at:end)
                    uploads += 1;ages.append((end-pair.observedAt)*1000)
                }
            }
            submissionMS.append((CACurrentMediaTime()-begun)*1000)
            let next=max(begun+1/60,ceil((CACurrentMediaTime()-start)*60)/60+start)
            let remaining=next-CACurrentMediaTime()
            if remaining>0 {usleep(useconds_t(min(0.1,remaining)*1_000_000))}
        }
        return ["available":true,"scope":"Mac actual-clock current-pixel live pipeline + real GPU + cold asynchronous matching; static input, no camera/video/system Glass",
            "duration":CACurrentMediaTime()-start,"recordedInputQueueLagMS":queueLag*1000,"draws":draws,
            "gpuUploads":uploads,"uploadSubmissionMS":submissionMS,"uploadedPixelAgesMS":ages,
            "warmDraws":warmDraws,"warmFullyBlackFrames":warmBlack,"edgeOpacities":opacity,"worker":background.runtimeState()]
    }

    /// Actual production Metal shader, without the system Liquid Glass layer.
    /// This is an offline preview of static recorded pixels, never a screenshot.
    static func render(_ value:PeripheralAlignmentResult,photo:[Double],window:[Double],opacity:[Double],to target:URL,liveFrame:PeripheralLiveFrame? = nil) throws {
        guard let pair=liveFrame?.pair ?? value.inputPair,let image=liveFrame?.image() ?? value.renderOuterImage(),
              let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { return }
        let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let context=CIContext(mtlDevice:device,options:[.cacheIntermediates:false,.workingColorSpace:space,
            .workingFormat:CIFormat.RGBAh.rawValue])
        let w=Int(window[0].rounded()),h=Int(window[1].rounded())
        func texture(_ width:Int,_ height:Int)->MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
            d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite,.renderTarget]
            return device.makeTexture(descriptor:d)!
        }
        let camera=texture(CVPixelBufferGetWidth(pair.outer),CVPixelBufferGetHeight(pair.outer)),output=texture(w,h)
        let command=queue.makeCommandBuffer()!
        let outerDestination=CIRenderDestination(mtlTexture:camera,commandBuffer:command)
        outerDestination.colorSpace=space;outerDestination.isFlipped=true
        let outerTask=try context.startTask(toRender:image,to:outerDestination)
        let central=CIImage(cvPixelBuffer:pair.center).transformed(by:CGAffineTransform(
            scaleX:photo[2]/Double(CVPixelBufferGetWidth(pair.center)),y:photo[3]/Double(CVPixelBufferGetHeight(pair.center))))
            .transformed(by:CGAffineTransform(translationX:photo[0],y:Double(h)-photo[1]-photo[3]))
            .composited(over:CIImage(color:.clear).cropped(to:CGRect(x:0,y:0,width:w,height:h)))
        let centerDestination=CIRenderDestination(mtlTexture:output,commandBuffer:command)
        centerDestination.colorSpace=space;centerDestination.isFlipped=true
        let centerTask=try context.startTask(toRender:central,to:centerDestination)
        let library=try device.makeLibrary(source:PeripheralGlassShader.source,options:nil)
        let d=MTLRenderPipelineDescriptor();d.vertexFunction=library.makeFunction(name:"glassVertex")
        d.fragmentFunction=library.makeFunction(name:"glassFragment");d.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline=try device.makeRenderPipelineState(descriptor:d)
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output
        pass.colorAttachments[0].loadAction = .load;pass.colorAttachments[0].storeAction = .store
        var u=PeripheralGlassUniforms(photo:SIMD4(Float(photo[0]/window[0]),Float(photo[1]/window[1]),
            Float(photo[2]/window[0]),Float(photo[3]/window[1])),viewport:SIMD2(Float(w),Float(h)),
            blackOpacity:0,photoToOuter:liveFrame?.matrix ?? value.photoToOuter,gain:SIMD4(repeating:1))
        u.edgeOpacity=SIMD4(Float(opacity[0]),Float(opacity[1]),Float(opacity[2]),Float(opacity[3]))
        let gains=liveFrame?.gains ?? value.edgeGains
        var g=(0..<4).map { SIMD4(gains[$0],Float(1)) },b=[SIMD4<Float>](repeating:.zero,count:4)
        for side in 0..<4 where gains.affine(side) { g[side]=SIMD4(gains.encodedSlope[side],2);b[side]=SIMD4(gains.encodedBias[side],0) }
        u.gainTop=g[0];u.gainBottom=g[1];u.gainLeft=g[2];u.gainRight=g[3]
        u.biasTop=b[0];u.biasBottom=b[1];u.biasLeft=b[2];u.biasRight=b[3]
        let encoder=command.makeRenderCommandEncoder(descriptor:pass)!
        encoder.setRenderPipelineState(pipeline);encoder.setFragmentTexture(camera,index:0)
        encoder.setFragmentBytes(&u,length:MemoryLayout<PeripheralGlassUniforms>.stride,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);encoder.endEncoding()
        command.commit();command.waitUntilCompleted()
        withExtendedLifetime((outerTask,centerTask)) {}
        guard command.status == .completed else { throw command.error ?? NSError(domain:"ReplayMetal",code:1) }
        var bytes=[Float16](repeating:0,count:w*h*4)
        bytes.withUnsafeMutableBytes {output.getBytes($0.baseAddress!,bytesPerRow:w*8,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)}
        let preview=bytes.withUnsafeBytes {CIImage(bitmapData:Data($0),bytesPerRow:w*8,size:CGSize(width:w,height:h),format:.RGBAh,colorSpace:space)}
        try context.writePNGRepresentation(of:preview,to:target,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,options:[:])
    }
    static func buffer(_ row: [String:Any],root:URL) throws -> CVPixelBuffer {
        let w = row["width"] as! Int, h = row["height"] as! Int
        let format = OSType((row["pixelFormat"] as! NSNumber).uint32Value)
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,w,h,format,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&result) == kCVReturnSuccess else { fatalError("CV fixture") }
        let pixel = result!, planar = CVPixelBufferIsPlanar(pixel)
        CVPixelBufferLockBaseAddress(pixel,[])
        defer { CVPixelBufferUnlockBaseAddress(pixel,[]) }
        for plane in row["planes"] as! [[String:Any]] {
            let index = plane["index"] as! Int, sourceStride = plane["bytesPerRow"] as! Int
            let height = plane["height"] as! Int
            let data = try Data(contentsOf:root.appendingPathComponent(plane["file"] as! String))
            guard data.count == sourceStride*height else { fatalError("Incomplete source plane") }
            let targetStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixel,index) : CVPixelBufferGetBytesPerRow(pixel)
            let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixel,index)! : CVPixelBufferGetBaseAddress(pixel)!
            data.withUnsafeBytes { source in
                for y in 0..<height { memcpy(base+y*targetStride,source.baseAddress!+y*sourceStride,min(sourceStride,targetStride)) }
            }
        }
        if let attachments = row["attachmentsDescription"] as? [String:String] {
            for key in [kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey,kCVImageBufferYCbCrMatrixKey] {
                if let value = attachments[key as String] { CVBufferSetAttachment(pixel,key,value as CFString,.shouldPropagate) }
            }
        }
        return pixel
    }
    static func matrix(_ value: Any?) -> simd_float3x3? {
        guard let a = value as? [[NSNumber]],a.count == 3 else { return nil }
        return simd_float3x3(columns:(SIMD3(a[0][0].floatValue,a[0][1].floatValue,a[0][2].floatValue),
            SIMD3(a[1][0].floatValue,a[1][1].floatValue,a[1][2].floatValue),SIMD3(a[2][0].floatValue,a[2][1].floatValue,a[2][2].floatValue)))
    }
    static func metadata(_ buffer: CVPixelBuffer,row:[String:Any]) -> PeripheralFrameMetadata {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:buffer,formatDescriptionOut:&description)
        var timing = CMSampleTimingInfo(duration:CMTime(seconds:row["frameInterval"] as? Double ?? 1/60,preferredTimescale:1_000_000_000),
            presentationTimeStamp:CMTime(seconds:row["pts"] as? Double ?? 0,preferredTimescale:1_000_000_000),decodeTimeStamp:.invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:buffer,formatDescription:description!,sampleTiming:&timing,sampleBufferOut:&sample)
        if var k = matrix(row["K_columns"]) {
            let data = withUnsafeBytes(of:&k) { Data($0) }
            CMSetAttachment(sample!,key:kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,value:data as CFData,attachmentMode:kCMAttachmentMode_ShouldPropagate)
        }
        return PeripheralFrameMetadata(sample!,id:(row["id"] as? NSNumber)?.uint64Value ?? 0,clock:nil)
    }
    static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), output = URL(fileURLWithPath:CommandLine.arguments[2])
        let folders = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix("record-") }.sorted { $0.path < $1.path }
        var reports: [[String:Any]] = []
        for (index,folder) in folders.enumerated() {
            try autoreleasepool {
                let record = try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("manifest.json"))) as! [String:Any]
                let roles = record["roles"] as! [String:String], pairs = record["pairs"] as! [String:[String:Any]]
                let inputRole = roles["analysisPair"] ?? roles["tapPair"]!
                let input = pairs[inputRole]!
                let center = try buffer(input["center"] as! [String:Any],root:folder)
                let outer = try buffer(input["outer"] as! [String:Any],root:folder)
                let cm = metadata(center,row:input["centerMetadata"] as! [String:Any])
                let om = metadata(outer,row:input["outerMetadata"] as! [String:Any])
                let config = PeripheralFrameSource.Configuration(outputIndex:1,fieldOfViewRatio:(input["ratio"] as! NSNumber).floatValue,epoch:1)
                let worker = PeripheralAlignmentWorker()
                let time = 100.0
                var calibration: PeripheralCalibration?
                if let c = input["calibration"] as? [String:Any],let rotation = matrix(c["R_columns"]),let t = c["t_mm"] as? [NSNumber] {
                    calibration = .init(identity:c["identity"] as! String,rotation:rotation,
                        translation:SIMD3(t[0].floatValue,t[1].floatValue,t[2].floatValue),outputRotation:(c["outputRotation"] as! NSNumber).floatValue)
                }
                let pair = PeripheralFrameSource.Pair(center:center,outer:outer,receipt:time,configuration:config,serial:1,
                    centerMetadata:cm,outerMetadata:om,calibration:calibration,pairingMode:"native-replay",measuredFrameInterval:1/60)
                let oldRenderer = record["renderer"] as! [String:Any], photo = oldRenderer["photoRect"] as! [Double], window = oldRenderer["windowSize"] as! [Double]
                let bounds = CGRect(x:-photo[0]/photo[2],y:-photo[1]/photo[3],width:window[0]/photo[2],height:window[1]/photo[3])
                let seams = PeripheralSeams(photo:CGRect(x:photo[0],y:photo[1],width:photo[2],height:photo[3]),window:CGSize(width:window[0],height:window[1]))
                let start = CACurrentMediaTime()
                let hint = CommandLine.arguments.contains("--recorded-candidate") ? matrix((record["analysis"] as! [String:Any])["H_columns"]) : nil
                var value = worker.analyze(pair,seams:seams,window:bounds,now:{ time+0.01 },acquisitionCandidate:hint,tolerance:selectedTolerance)
                let initial = PeripheralRecordJSON.alignment(value)
                let waiting = CACurrentMediaTime()
                if CommandLine.arguments.contains("--wait-dense"), value != nil {
                    // Offline only: the app NEVER waits for the dense worker.
                    // Its result is a proposal; this second CURRENT analysis
                    // must independently validate it before any policy update.
                    while worker.denseRefinementStatus()["busy"] as? Bool == true && CACurrentMediaTime()-waiting < 30 { usleep(10_000) }
                    value = worker.analyze(pair,seams:seams,window:bounds,now:{ time+0.01 },acquisitionCandidate:hint,tolerance:selectedTolerance)
                }
                var row: [String:Any] = ["scene":index+1,"id":record["id"]!,"realElapsedMS":(CACurrentMediaTime()-start)*1000,
                    "replayedInputRole":roles["analysisPair"] == nil ? "tapPair":"analysisPair","initialAcquisitionAlignment":initial,"denseWarmupWaitMS":(CACurrentMediaTime()-waiting)*1000,
                    "alignment":PeripheralRecordJSON.alignment(value),"diagnostic":worker.latestDiagnostic()?.metadata ?? [:]]
                if let value {
                    if CommandLine.arguments.contains("--rasters"), let native = value.nativeSeam {
                        for strip in native.strips {
                            let stem = "scene-\(index+1)-edge-\(strip.edge)-\(strip.width)x\(strip.height)"
                            try Data(strip.reference).write(to:output.deletingLastPathComponent().appendingPathComponent(stem+"-reference.rgba"))
                            try Data(strip.outer).write(to:output.deletingLastPathComponent().appendingPathComponent(stem+"-outer.rgba"))
                        }
                    }
                    row["permitsDisplay"] = value.evidence.permitsDisplay
                    row["permitsAnyDisplay"] = value.permitsAnyDisplay
                    row["nativeTiles"] = value.nativeSeam?.diagnostics ?? []
                    var policy = PeripheralGlassPolicy(), readiness = PeripheralReadiness()
                    var regional = PeripheralRegionalGlassPolicy()
                    let activeEdges = (0..<4).filter { $0 < 2 ? seams.contains(.horizontal):seams.contains(.vertical) }
                    var repeatedPermits: [Bool] = [], repeatedReasons: [String] = [], repeatedElapsed: [Double] = []
                    var current = value
                    let live=PeripheralLivePipeline(),liveTextures=PeripheralLiveTextureStore()
                    let gpu=MTLCreateSystemDefaultDevice()!,gpuQueue=gpu.makeCommandQueue()!
                    let displaySpace=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
                    let displayContext=CIContext(mtlDevice:gpu,options:[.cacheIntermediates:false,.workingColorSpace:displaySpace])
                    var liveEdges=[Double](repeating:1,count:4),liveFrames:[[String:Any]]=[],lastLive:PeripheralLiveFrame?
                    for frame in 0...72 {
                        let now = time+Double(frame)/60
                        regional.tick(at:now,sourceAvailable:true,epoch:1)
                        if frame%5 == 0 {
                            // Re-run the actual stateful worker, not merely the
                            // policy with a duplicated reliable result. Pixels
                            // and capture metadata remain the same static input;
                            // these synthetic observations are NOT camera video.
                            if frame > 0 {
                                let repeatedPair = PeripheralFrameSource.Pair(center:center,outer:outer,receipt:now,
                                    configuration:config,serial:UInt64(frame/5+1),centerMetadata:cm,outerMetadata:om,
                                    calibration:calibration,pairingMode:"synthetic-static-native-replay",measuredFrameInterval:1/60)
                                let repeatedStart = CACurrentMediaTime()
                                if let next = worker.analyze(repeatedPair,seams:seams,window:bounds,now:{ now+0.01 },acquisitionCandidate:hint,tolerance:selectedTolerance) {
                                    current = next
                                }
                                repeatedElapsed.append((CACurrentMediaTime()-repeatedStart)*1000)
                            }
                            repeatedPermits.append(current.isFresh(for:1,at:now) && current.evidence.permitsDisplay)
                            repeatedReasons.append(current.evidence.reason)
                            policy.tick(at:now,sourceAvailable:true,epoch:1)
                            policy.update(evidence:current.evidence,sampleID:current.pairID,sampleEpoch:1,
                                observedAt:current.receipt,expiresAt:current.expiresAt,at:now,sourceAvailable:true,currentEpoch:1)
                            regional.update((0..<4).map { current.evidence(forEdge:$0) },sampleID:current.pairID,epoch:1,
                                observedAt:current.receipt,expiresAt:current.expiresAt,at:now,sourceAvailable:true,expectedInterval:1/12)
                        } else { policy.tick(at:now,sourceAvailable:true,epoch:1) }
                        let livePair=PeripheralFrameSource.Pair(center:center,outer:outer,receipt:now-0.025,
                            configuration:config,serial:UInt64(frame+10_000),centerMetadata:cm,outerMetadata:om,
                            calibration:calibration,pairingMode:"synthetic-static-live-display",measuredFrameInterval:1/60)
                        if let liveFrame=live.update(pair:livePair,analysis:current,enabled:true,epoch:1,seams:seams,
                            window:bounds,tolerance:selectedTolerance,at:now+0.01) {
                            let uploadCommand=gpuQueue.makeCommandBuffer()!
                            let upload=try liveTextures.prepare(liveFrame,revision:1,at:now+0.01,device:gpu,context:displayContext,
                                command:uploadCommand,colorSpace:displaySpace)
                            liveEdges=live.opacities(bundle:liveTextures.completed,revision:1,at:now+0.01,tolerance:selectedTolerance)
                            if let upload {
                                uploadCommand.commit();uploadCommand.waitUntilCompleted();withExtendedLifetime(upload.1) {}
                                liveTextures.complete(upload.0,success:uploadCommand.status == .completed,revision:1,epoch:1,at:now+0.012)
                            }
                            lastLive=liveTextures.completed?.frame
                            liveFrames.append(["time":now-time,"edgeOpacities":liveEdges,"texturePairID":lastLive?.pair.serial ?? 0,
                                "modelPairID":lastLive?.analysisPairID ?? 0,"mappingBasis":lastLive?.mappingBasis ?? "none"])
                        }
                        readiness.update(ready:frame > 0 && current.isFresh(for:1,at:now) && current.evidence.permitsDisplay,at:now)
                        regional.prepared((0..<4).map { side in frame > 0 && current.isFresh(for:1,at:now) && current.evidence(forEdge:side).permitsDisplay },at:now)
                    }
                    row["staticRepeatedProductionPermitsDisplay"] = repeatedPermits
                    row["staticRepeatedProductionReasons"] = repeatedReasons
                    row["staticRepeatedProductionElapsedMS"] = repeatedElapsed
                    row["staticRepeatedInputQualityOpacity"] = policy.opacity(at:time+1.2)
                    row["staticRepeatedWholeBoundaryEffectiveOpacity"] = max(policy.opacity(at:time+1.2),readiness.opacity(at:time+1.2))
                    let edges = regional.opacities(at:time+1.2)
                    row["staticRepeatedInputEdgeOpacities"] = edges
                    row["activeEdges"] = activeEdges
                    row["staticRepeatedInputEffectiveOpacity"] = activeEdges.map { edges[$0] }.max() ?? 1
                    row["staticRepeatedInputMinimumOpacity"] = activeEdges.map { edges[$0] }.min() ?? 1
                    row["staticFinalAlignment"] = PeripheralRecordJSON.alignment(current)
                    row["staticFinalNativeTiles"] = current.nativeSeam?.diagnostics ?? []
                    let liveMinimum:Double = activeEdges.map {liveEdges[$0]}.min() ?? 1
                    row["livePreview"] = ["edgeOpacities":liveEdges,"minimumOpacity":liveMinimum,
                        "maximumOpacity":activeEdges.map {liveEdges[$0]}.max() ?? 1,"frames":liveFrames,
                        "mappingBasis":lastLive?.mappingBasis ?? "none","pixelUpdates":liveFrames.count,
                        "scope":"production live pipeline + real GPU; static pixels with virtual observation time"]
                    if CommandLine.arguments.contains("--render") {
                        let target=output.deletingLastPathComponent().appendingPathComponent("scene-\(index+1)-offline-Metal.png")
                        try render(current,photo:photo,window:window,opacity:liveEdges,to:target,liveFrame:lastLive)
                        row["offlineMetalPreview"]=target.lastPathComponent
                    }
                    if CommandLine.arguments.contains("--real-clock"),[1,3,7].contains(index+1) {
                        row["realClockStaticLiveness"]=try realClockStatic(worker,center:center,outer:outer,cm:cm,om:om,
                            config:config,calibration:calibration,seams:seams,window:bounds,
                            queueLag:max(0,min(0.1,(input["receipt"] as? Double ?? 0)-(input["observedAt"] as? Double ?? 0))))
                    }
                    if let candidate = pairs[roles["renderCandidatePair"] ?? ""],
                       let a = PeripheralMotion.raster(center), let b = PeripheralMotion.raster(try buffer(candidate["center"] as! [String:Any],root:folder)) {
                        row["actualRecordedEndpointMotionAnalysisPixels"] = PeripheralMotion.displacement(a,b,minimumMatches:3) ?? .nan
                    }
                }
                reports.append(row)
            }
        }
        try PeripheralRecordJSON.data(["scope":"full-native-production-worker; static repeated-input liveness is synthetic, not recorded video",
            "recordedCandidateUsed":CommandLine.arguments.contains("--recorded-candidate"),"tolerance":selectedTolerance,
            "records":reports]).write(to:output,options:.atomic)
        print("Native production replay: \(reports.count) scenes")
    }
}
