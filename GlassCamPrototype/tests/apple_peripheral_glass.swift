import Foundation
import Darwin
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import simd

/// Execute only after test authorization. No camera, Photos or UI automation.
@main
struct PeripheralGlassChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.00001) -> Bool { abs(a-b) < tolerance }

    static func main() throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.contains("--benchmark") { try benchmark(); return }
        if CommandLine.arguments.contains("--dense-gold") { try denseGoldChecks(); return }
        recoveryChecks()
        policyChecks()
        projectionChecks()
        rasterChecks()
        seamChecks()
        motionChecks()
        try mailboxChecks()
        try diagnosticChecks()
        directStitchChecks()
        try shaderChecks()
        try fieldRepairChecks()
        try livePreviewChecks()
        try pairedPresentationChecks()
        controlledDisparityChecks()
        localDeformationChecks()
        adverseResponseChecks()
        print("PASS: peripheral policy, projection, residual, mailbox, direct seam measurement and Metal center exclusion")
    }

    static func denseGoldChecks() throws {
        let w=384,h=512,dx=8,dy=10
        let image=CIImage(cvPixelBuffer:pixelBuffer(rgba:texture(width:w,height:h,seed:1289),width:w,height:h))
            .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:1.5]).cropped(to:CGRect(x:0,y:0,width:w,height:h))
        let a=PeripheralAlignmentWorker().bitmap(image,bounds:CGRect(x:0,y:0,width:w,height:h),width:w,height:h)
        var b=a
        for y in 0..<h {for x in 0..<w {for c in 0..<3 {
            let value=Float(a[(max(0,y-dy)*w+max(0,x-dx))*4+c])*0.8+24
            b[(y*w+x)*4+c]=UInt8(max(0,min(255,Int(value.rounded()))))
        }}}
        let pair=PeripheralFrameSource.Pair(center:pixelBuffer(rgba:a,width:w,height:h),outer:pixelBuffer(rgba:b,width:w,height:h),
            receipt:CACurrentMediaTime(),configuration:.init(outputIndex:1,fieldOfViewRatio:1,epoch:1),serial:1)
        guard let proposal=try PeripheralDenseSolver.compute(pair,homography:matrix_identity_float3x3,id:9) else {fatalError("Known shifted/exposure input produced no dense proposal")}
        var errors:[Float]=[],xs:[Float]=[],ys:[Float]=[]
        for y in stride(from:40,to:h-40,by:4) {for x in stride(from:40,to:w-40,by:4) {
            let i=(y*w+x)*4
            if proposal.rgba[i+2]>0.5 {errors.append(abs(proposal.rgba[i]-Float(dx))+abs(proposal.rgba[i+1]+Float(dy)));xs.append(proposal.rgba[i]);ys.append(-proposal.rgba[i+1])}
        }}
        errors.sort()
        xs.sort();ys.sort();print("Dense golden dx/dy medians",xs[xs.count/2],ys[ys.count/2])
        require(errors.count>3000,"Too few independent forward/backward-consistent dense vectors")
        let median=errors[errors.count/2],p90=errors[errors.count*9/10]
        print("Dense independent golden: median L1 pixel error=\(median), p90=\(p90), FB fraction=\(proposal.consistentFraction)")
        require(median<2 && p90<4,"Actual Vision flow lost the known independent x/y displacement under an exposure change")
        print("PASS: actual bidirectional Vision flow on independently generated displacement/exposure input")
    }

    static func fieldRepairChecks() throws {
        var bounded = good(); bounded.status = .ambiguous; bounded.interval = 0.01...0.035
        require(bounded.reliable,"A complete small candidate set was discarded for its nonunique topology")
        var flat = PeripheralEvidence.unknown("physical-displacement-unobservable")
        flat.visibleSeam = .init(compatible:true,coverage:1,maximumObservableError:nil,
            reason:"native-visible-seam",nativeSupportChecked:true)
        var policy = PeripheralGlassPolicy(), readiness = PeripheralReadiness()
        for i in 0...72 {
            let now = Double(i)/60
            if i%5 == 0 { feed(&policy,flat,now,id:UInt64(i/5+1)) }
            else { policy.tick(at:now,sourceAvailable:true,epoch:1) }
            readiness.update(ready:i >= 30,at:now)
            if i == 25 { require(!policy.latched && readiness.opacity(at:now) == 1,"Resource wait erased quality recovery") }
        }
        require(flat.interval == nil && !flat.reliable,"Visible evidence fabricated a physical zero")
        require(policy.opacity(at:1.2) == 0 && readiness.opacity(at:1.2) == 0,"Independent quality/resource startup never reached clear")
        let deadline = policy.certificateDeadline
        feed(&policy,.unknown("no-new-visible-proof"),1.25,id:20)
        require(policy.certificateDeadline == deadline,"Unknown extended a visible certificate")
        policy.tick(at:1.5,sourceAvailable:true,epoch:1)
        require(policy.latched,"Expired visible proof remained clear")
        var bad = flat; bad.confirmedSevereLowerBound = 0.125
        var protection = PeripheralGlassPolicy(); warm(&protection)
        feed(&protection,bad,1.05,id:13)
        require(protection.latched,"Visible appearance bypassed independently corroborated severe geometry")
        var panes=PeripheralRegionalGlassPolicy()
        for frame in 0...72 {
            let now=Double(frame)/60
            panes.tick(at:now,sourceAvailable:true,epoch:1)
            if frame%5 == 0 {
                panes.update([flat,.unknown("lower-seam-occluded"),.unknown("no-pane"),.unknown("no-pane")],
                    sampleID:UInt64(frame/5+1),epoch:1,observedAt:now,expiresAt:now+0.2,at:now,
                    sourceAvailable:true,expectedInterval:1/12)
            }
            panes.prepared([frame>0,false,false,false],at:now)
        }
        require(panes.opacities(at:1.2)[0] == 0 && panes.opacities(at:1.2)[1] == 1,
            "An independently valid upper pane was blackened by an invalid lower seam")
        panes.prepared([false,false,false,false],at:1.21)
        require(panes.opacities(at:1.21)[0] == 1,"A current certificate revealed a different/unready GPU bundle")

        let width = 192, height = 20
        let suite = "GlassCamToleranceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let calibration = PeripheralTolerance(defaults:defaults)
        require(calibration.value == 1,"New calibration did not start at 1.00")
        calibration.value = 2.13
        require(close(PeripheralTolerance(defaults:defaults).value,2.15),"The selected calibration was not persisted at the displayed precision")
        calibration.value = .nan
        require(calibration.value == 1,"Invalid calibration did not restore the default")
        var pixels = [UInt8](repeating:128,count:width*height*4)
        for i in stride(from:3,to:pixels.count,by:4) { pixels[i] = 255 }
        func check(_ a:[UInt8],_ b:[UInt8],geometry:Bool = true,
                   segments:[PeripheralAlignmentWorker.SegmentEvidence] = [],tolerance:Double = 1) -> PeripheralNativeSeam {
            let strip = PeripheralNativeSeam.Strip(edge:0,width:width,height:height,reference:a,outer:b,nativeScale:1)
            return PeripheralNativeSeam.evaluate([strip],gains:PeripheralEdgeGains(),segments:segments,
                analysisWidth:192,analysisHeight:256,geometryVerified:geometry,severe:nil,tolerance:tolerance)
        }
        require(check(pixels,pixels,geometry:false).evidence.compatible,"Genuinely flat native support could not get visible evidence")
        var defect = pixels
        for x in 50..<76 { for c in 0..<3 { defect[x*4+c] = 0 } }
        require(!check(defect,pixels).evidence.compatible,"Outermost-row defect was hidden between matching supports")
        var thin = pixels
        for y in 0..<height { for c in 0..<3 { thin[(y*width+70)*4+c] = 0 } }
        require(!check(thin,pixels).evidence.compatible,"A one-native-pixel line disappeared into the flat branch")
        var blurred = pixels, shiftedBlur = pixels
        let kernel = (-5...5).map { exp(-Double($0*$0)/12.5) }
        let weight = kernel.reduce(0,+)
        for y in 0..<height { for dx in -5...5 { for c in 0..<3 {
            let value = UInt8((128-128*kernel[dx+5]/weight).rounded())
            blurred[(y*width+70+dx)*4+c] = value
            shiftedBlur[(y*width+86+dx)*4+c] = value
        } } }
        let weakCounterpart = check(thin,blurred,geometry:false)
        require(weakCounterpart.evidence.compatible,"A correctly aligned sharp line lost its verified weak blurred counterpart")
        require(!check(thin,shiftedBlur,geometry:false).evidence.compatible,"A displaced blurred line bypassed native correspondence guards")
        var nearbyLine = pixels
        for y in 0..<height {for c in 0..<3 {nearbyLine[(y*width+77)*4+c] = 0}}
        require(!check(thin,nearbyLine,geometry:false,tolerance:0.25).evidence.compatible &&
            !check(thin,nearbyLine,geometry:false,tolerance:1).evidence.compatible &&
            check(thin,nearbyLine,geometry:false,tolerance:4).evidence.compatible,
            "The tolerance control did not change the actual current-image acceptance of a known small line shift")
        require(!check(thin,pixels,geometry:false,tolerance:4).evidence.compatible,
            "Maximum calibration accepted completely absent line support")
        var uncovered = nearbyLine; uncovered[3] = 0
        require(!check(thin,uncovered,geometry:false,tolerance:4).evidence.compatible,
            "Calibration bypassed genuine missing native pixels")
        // The exact renderer-side dense warp must obey both axes independently.
        // These pixels and vectors are constructed without Vision or fitted H.
        let denseW=192,denseH=256,shiftX=6,shiftY=9
        let denseReference=texture(width:denseW,height:denseH,seed:919)
        var denseTarget=denseReference
        for y in 0..<denseH { for x in 0..<denseW { for c in 0..<4 {
            denseTarget[(y*denseW+x)*4+c]=denseReference[(max(0,y-shiftY)*denseW+max(0,x-shiftX))*4+c]
        } } }
        var denseValues=[Float](repeating:1,count:denseW*denseH*4)
        for i in stride(from:0,to:denseValues.count,by:4) { denseValues[i]=Float(shiftX);denseValues[i+1] = -Float(shiftY) }
        let exactDense=PeripheralDenseRefinement(id:7,epoch:1,sourcePairID:1,homography:matrix_identity_float3x3,
            width:denseW,height:denseH,rgba:denseValues,consistentFraction:1,elapsedMS:0,maximumOffset:0.04)
        let exactImage=exactDense.outerImage(CIImage(cvPixelBuffer:pixelBuffer(rgba:denseTarget,width:denseW,height:denseH)),
            centerSize:CGSize(width:denseW,height:denseH),ratio:1)!
        let exactBytes=PeripheralAlignmentWorker().bitmap(exactImage,bounds:CGRect(x:0,y:0,width:denseW,height:denseH),width:denseW,height:denseH)
        var exactError=0.0
        for y in 16..<denseH-16 { for x in 16..<denseW-16 { for c in 0..<3 {
            exactError += Double(abs(Int(exactBytes[(y*denseW+x)*4+c])-Int(denseReference[(y*denseW+x)*4+c])))
        } } }
        require(exactError/Double((denseW-32)*(denseH-32)*3) < 1.5,"Dense CI/Metal warp changed x/y sign, scale, or center-relative domain")
        var spatialTarget=denseReference,spatialValues=denseValues
        for y in 0..<denseH {for x in 0..<denseW {
            let sign=y<denseH/2 ? 1:-1
            let sx=max(0,min(denseW-1,x-sign*shiftX)),sy=max(0,min(denseH-1,y-sign*shiftY))
            for c in 0..<4 {spatialTarget[(y*denseW+x)*4+c]=denseReference[(sy*denseW+sx)*4+c]}
            spatialValues[(y*denseW+x)*4]=Float(sign*shiftX)
            spatialValues[(y*denseW+x)*4+1] = -Float(sign*shiftY)
        }}
        let spatial=PeripheralDenseRefinement(id:8,epoch:1,sourcePairID:1,homography:matrix_identity_float3x3,
            width:denseW,height:denseH,rgba:spatialValues,consistentFraction:1,elapsedMS:0,maximumOffset:0.04)
        let spatialImage=spatial.outerImage(CIImage(cvPixelBuffer:pixelBuffer(rgba:spatialTarget,width:denseW,height:denseH)),
            centerSize:CGSize(width:denseW,height:denseH),ratio:1)!
        let spatialBytes=PeripheralAlignmentWorker().bitmap(spatialImage,bounds:CGRect(x:0,y:0,width:denseW,height:denseH),width:denseW,height:denseH)
        var spatialError=0.0,spatialCount=0
        for y in 16..<denseH-16 where abs(y-denseH/2)>20 {for x in 16..<denseW-16 {for c in 0..<3 {
            spatialError += Double(abs(Int(spatialBytes[(y*denseW+x)*4+c])-Int(denseReference[(y*denseW+x)*4+c])));spatialCount += 1
        }}}
        require(spatialError/Double(spatialCount)<1.5,"A spatially varying flow field was flipped between its upper and lower regions")
        var highResolution = [UInt8](repeating:128,count:768*1024*4)
        for i in stride(from:3,to:highResolution.count,by:4) { highResolution[i] = 255 }
        for y in 0..<1024 { for c in 0..<3 { highResolution[(y*768+71)*4+c] = 0 } }
        let nativePixel = pixelBuffer(rgba:highResolution,width:768,height:1024)
        let nativeContext = CIContext(options:[.cacheIntermediates:false])
        let nativeStrips = PeripheralNativeSeam.read(center:CIImage(cvPixelBuffer:nativePixel),
            outerImage:CIImage(cvPixelBuffer:nativePixel),ratio:1,matrix:matrix_identity_float3x3,
            analysisWidth:192,analysisHeight:256,seams:.horizontal,context:nativeContext)
        require(nativeStrips[0].width == 768 && nativeStrips[0].outer[71*4] < 3 && nativeStrips[0].outer[70*4] > 120,
            "Native validation downsampled away a one-pixel line before checking")
        let periodic = (0..<width*height).flatMap { i -> [UInt8] in
            let v:UInt8 = (i%width)%24 < 12 ? 40 : 220; return [v,v,v,255]
        }
        let repetitive = PeripheralAlignmentWorker.SegmentEvidence(index:0,point:SIMD2(10,10),status:.ambiguous,
            interval:nil,best:nil,forwardBackward:0,searchComplete:true,
            gradientEigenvalues:SIMD2(0,1),observableNormal:SIMD2(1,0),noiseScale:0,
            repeatedStructure:true)
        require(!check(periodic,periodic,segments:[repetitive]).evidence.compatible,"Periodic structure was certified flat")
        let checkerboard = (0..<width*height).flatMap { i -> [UInt8] in
            let v:UInt8 = ((i%width)/4+(i/width)/4)%2 == 0 ? 40:220
            return [v,v,v,255]
        }
        require(!check(checkerboard,checkerboard,geometry:false).evidence.compatible,
            "A periodic 2D texture escaped by cancelling in the mean boundary profile")
        var radiometricSource = pixels, radiometricReference = pixels
        for y in 0..<height { for x in 0..<width { for c in 0..<3 {
            let value = 0.1+0.8*Float(x)/Float(width-1)
            radiometricSource[(y*width+x)*4+c] = UInt8((255*value).rounded())
            var target = value*0.7+0.06
            if x%19 == 0 { target = min(0.9,target+0.25) } // independent occlusion outliers
            radiometricReference[(y*width+x)*4+c] = UInt8((255*target).rounded())
        } } }
        let fitted = PeripheralNativeSeam.estimate([.init(edge:0,width:width,height:height,
            reference:radiometricReference,outer:radiometricSource,nativeScale:1)])
        require(abs(fitted.encodedSlope[0].x-0.7) < 0.025 && abs(fitted.encodedBias[0].x-0.06) < 0.015,
            "Robust independent photometry did not recover known tone slope/bias in the presence of outliers")

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal required") }
        let context = CIContext(mtlDevice:device,options:[.cacheIntermediates:false])
        let space = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let buffer = pixelBuffer(rgba:texture(width:192,height:256,seed:79),width:192,height:256)
        require(PeripheralTemporalAppearance.compatible(buffer,buffer,seams:.all),"An unchanged native input could not preserve temporal appearance")
        let changed = pixelBuffer(rgba:[UInt8](repeating:255,count:192*256*4),width:192,height:256)
        require(!PeripheralTemporalAppearance.compatible(buffer,changed,seams:.all),"A changed current native boundary reused old visible proof")
        let pair = PeripheralFrameSource.Pair(center:buffer,outer:buffer,receipt:10,
            configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:8),serial:1)
        var alignment = PeripheralAlignmentResult(epoch:8,receipt:10,photoAspectRatio:0.75,
            photoToOuter:matrix_identity_float3x3,residual:.nan,gain:SIMD3(repeating:1),seams:.all,expiresAt:10.2)
        alignment.inputPair = pair; alignment.pairID = pair.serial
        let store = PeripheralTextureStore(), command = queue.makeCommandBuffer()!
        guard let prepared = try store.prepare(alignment:alignment,revision:2,epoch:8,commandID:1,at:10,
            device:device,context:context,command:command,colorSpace:space,samplingLegal:true) else { fatalError("UNKNOWN was not prepared behind black") }
        require(store.completed == nil,"Encoding was labeled completed before GPU success")
        command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(prepared.1) {}
        require(command.status == .completed,"Real original-buffer CI upload failed")
        require(store.complete(prepared.0,success:true,revision:2,epoch:8,at:10.01),"Correct upload completion rejected")
        require(store.completed?.pair === pair && store.completed?.alignment.pairID == 1,"Texture/measurement identity was split")
        require(!store.completed!.alignment.evidence.permitsDisplay,"Preparing UNKNOWN silently authorized display")
        store.reset()
        require(!store.complete(prepared.0,success:true,revision:2,epoch:8,at:10.02) && store.completed == nil,"Late callback resurrected a reset source")
        let failedCommand = queue.makeCommandBuffer()!
        let failed = try store.prepare(alignment:alignment,revision:3,epoch:8,commandID:2,at:10.03,
            device:device,context:context,command:failedCommand,colorSpace:space,samplingLegal:true)!
        failedCommand.commit(); failedCommand.waitUntilCompleted()
        require(store.complete(failed.0,success:false,revision:3,epoch:8,at:10.04),"Failure callback was not consumed")
        require(store.completed == nil && store.nextAttempt >= 10.09,"Failed resource became displayable or retried unboundedly")
        store.reset()
        let partialPair=PeripheralFrameSource.Pair(center:buffer,outer:buffer,receipt:10,
            configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:8),serial:2)
        var partial=alignment;partial.inputPair=partialPair;partial.pairID=2
        partial.nativeSeam=PeripheralNativeSeam.evaluate([
            .init(edge:0,width:width,height:height,reference:pixels,outer:pixels,nativeScale:1),
            .init(edge:1,width:width,height:height,reference:thin,outer:pixels,nativeScale:1)],
            gains:PeripheralEdgeGains(),segments:[],analysisWidth:192,analysisHeight:256,geometryVerified:false,severe:nil)
        require(!partial.evidence.permitsDisplay && partial.evidence(forEdge:0).permitsDisplay && !partial.evidence(forEdge:1).permitsDisplay,
            "Partial native evidence fabricated a complete-boundary certificate")
        let partialCommand=queue.makeCommandBuffer()!
        let partialUpload=try store.prepare(alignment:partial,revision:4,epoch:8,commandID:3,at:10.05,
            device:device,context:context,command:partialCommand,colorSpace:space,samplingLegal:true)!
        partialCommand.commit();partialCommand.waitUntilCompleted();withExtendedLifetime(partialUpload.1) {}
        require(store.complete(partialUpload.0,success:partialCommand.status == .completed,revision:4,epoch:8,at:10.06) && store.displayable === partialUpload.0,
            "A valid independently certified pane was held behind a whole-boundary resource gate")
        var tuned=partial;tuned.tolerance=2
        let tunedCommand=queue.makeCommandBuffer()!
        guard let tunedUpload=try store.prepare(alignment:tuned,revision:4,epoch:8,commandID:4,at:10.07,
            device:device,context:context,command:tunedCommand,colorSpace:space,samplingLegal:true) else {
            fatalError("A new tolerance reused the completed bundle's previous matching evidence")
        }
        tunedCommand.commit();tunedCommand.waitUntilCompleted();withExtendedLifetime(tunedUpload.1) {}
        require(store.complete(tunedUpload.0,success:tunedCommand.status == .completed,revision:4,epoch:8,at:10.08) &&
            store.displayable?.alignment.tolerance == 2,"GPU bundle lost its own tolerance identity")
        print("PASS: bounded ambiguous evidence; native flat/line/outer-row/periodic checks; 12Hz quality + delayed readiness; real GPU UNKNOWN preparation; immutable identities, late callback and failure retry")
    }

    static func benchmark() throws {
        let input = fixture()
        let f = simd_float3x3(SIMD3(0,0,0),SIMD3(0,0,1),SIMD3(0,-1,0))
        var reports: [[String:Any]] = []
        for mode in ["complete-2d-fallback","image-verified-epipolar-tracking"] {
            var times: [Double] = [], count = 0
            for i in 0..<22 {
                let start = CACurrentMediaTime()
                let value = PeripheralAlignmentWorker.measureSeams(reference:input.a,warped:input.b,width:192,height:256,
                    warpedPadding:32,seams:.horizontal,certifiedGeometry:true,previousGain:SIMD3(repeating:1),allowPartial:true,
                    fundamental:mode == "complete-2d-fallback" ? nil : f,epipolarCertified:mode != "complete-2d-fallback")!
                require(value.evidence.reliable,"Benchmark input was not reliably matched")
                if i >= 2 { times.append((CACurrentMediaTime()-start)*1000) }
                count = value.comparisons
            }
            times.sort()
            reports.append(["mode":mode,"samples":times.count,"meanMS":times.reduce(0,+)/Double(times.count),
                "p95MS":times[Int(ceil(0.95*Double(times.count)))-1],"maxMS":times.last!,"sampleComparisons":count])
        }
        let output: [String:Any] = ["scope":"Mac CPU matching microbenchmark only, excludes capture/CI/Vision/display/phone power",
            "os":ProcessInfo.processInfo.operatingSystemVersionString,"results":reports]
        let bytes = try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys])
        print(String(data:bytes,encoding:.utf8)!)
    }
    static func recoveryChecks() {
        for oldFPS in [15.0,30,60] { for newFPS in [15.0,30,60] {
            var minimum = 1/oldFPS, maximum = minimum
            let target = 1/newFPS
            if CameraSessionRecovery.raisesMaximumFirst(target:target,currentMaximum:maximum) {
                maximum = target; require(minimum <= maximum,"Transient invalid duration interval")
                minimum = target
            } else {
                minimum = target; require(minimum <= maximum,"Transient invalid duration interval")
                maximum = target
            }
            require(minimum == target && maximum == target,"Frame duration transition incorrect")
        } }
        var budget = CameraSessionRecovery.Budget()
        require(budget.admit(at:0) && budget.admit(at:1) && !budget.admit(at:2),"Automatic rebuilds are unbounded")
        require(!budget.admit(at:-1) && budget.admit(at:31),"Recovery time window invalid")
        require(CameraSessionRecovery.action(for:.mediaServicesReset,currentGeneration:true,cancelled:false,capturing:true,multiCam:true) == .finishCapture,"Reset abandoned a pending shutter")
        require(CameraSessionRecovery.action(for:.interruptionEnded,currentGeneration:false,cancelled:false,capturing:false,multiCam:true) == .ignore,"Old session event rebuilt a new graph")
        require(CameraSessionRecovery.action(for:.interruptionEnded,currentGeneration:true,cancelled:true,capturing:false,multiCam:true) == .ignore,"Background cancellation restarted capture")
        require(CameraSessionRecovery.action(for:.seriousPressure,currentGeneration:true,cancelled:false,capturing:false,multiCam:true) == .rebuildCenterOnly,"Pressure did not preserve central capture separately")
        print("PASS: production recovery admission, pending shutter preservation, old generation/cancel rejection and all 15/30/60 duration transitions")
    }
    static func good(_ error: Double = 0.01) -> PeripheralEvidence {
        .init(status: .measured,interval: error...error,appearance: .compatible,reason: "fixture",searchComplete: true,coverage: 1)
    }
    static func feed(_ policy: inout PeripheralGlassPolicy,_ evidence: PeripheralEvidence?,_ time: Double,
                     id: UInt64,epoch: UInt64 = 1,observed: Double? = nil,source: Bool = true,interval: Double = 1.0/12) {
        let observed = observed ?? time
        policy.update(evidence: evidence,sampleID: id,sampleEpoch: epoch,observedAt: observed,
            expiresAt: observed+0.2,at: time,sourceAvailable: source,currentEpoch: epoch,expectedInterval:interval)
    }
    static func warm(_ policy: inout PeripheralGlassPolicy,from: Double = 0,id: UInt64 = 0) {
        for i in 0...12 { feed(&policy,good(),from+Double(i)/12,id: id+UInt64(i)) }
    }
    static func policyChecks() {
        var policy = PeripheralGlassPolicy()
        warm(&policy)
        require(!policy.latched && policy.opacity(at: 1) == 0,"Continuous fresh samples did not recover")
        let deadline = policy.certificateDeadline
        feed(&policy,.unknown("low-confidence-peak"),1.083333,id:13)
        require(!policy.latched && policy.certificateDeadline == deadline && policy.targetOpacity == 0,
                "An unknown sample latched black or renewed its certificate")
        feed(&policy,good(),1.166667,id:14)
        require(!policy.latched,"A single low confidence peak interrupted transparent state")
        policy.tick(at:1.37,sourceAvailable:true,epoch:1)
        require(policy.latched,"Persistent unknown outlived its absolute deadline")
        var trueBad = PeripheralGlassPolicy(); warm(&trueBad)
        feed(&trueBad,good(0.15),1.083333,id:13)
        require(trueBad.latched && trueBad.targetOpacity == 1,"Confirmed large displacement did not latch immediately")
        require(trueBad.opacity(at:1.39) == 1,"Confirmed large displacement failed full 0.3s darkening")
        var gap = PeripheralGlassPolicy(); warm(&gap)
        feed(&gap,good(),1.5,id:13)
        require(gap.latched,"New evidence bypassed expiry after a draw pause")
        for i in 1...4 { feed(&gap,good(),1.5+Double(i)/12,id:13+UInt64(i)) }
        require(gap.latched,"Recovery finished without 0.4 seconds of new continuous evidence")
        feed(&gap,good(),1.5+5.0/12,id:18)
        require(!gap.latched,"Continuous recovery failed after a pause")
        let priorDeadline = gap.certificateDeadline
        feed(&gap,good(),1.93,id:19,observed:1.6)
        require(gap.certificateDeadline == priorDeadline,"A stale observation renewed quality")
        feed(&gap,good(),1.94,id:17)
        require(gap.certificateDeadline == priorDeadline,"An older ID renewed quality")
        gap.tick(at:1.95,sourceAvailable:false,epoch:1)
        require(gap.forcedBlack && gap.latched,"Hard source loss did not force black")
        gap.tick(at:2,sourceAvailable:true,epoch:2)
        gap.update(evidence:good(),sampleID:100,sampleEpoch:1,observedAt:2.01,expiresAt:2.21,at:2.01,sourceAvailable:true,currentEpoch:2)
        require(gap.latched && gap.certificateDeadline == -.infinity,"Old source callback changed a new epoch")
        var sparse = PeripheralGlassPolicy()
        feed(&sparse,good(),0,id:0); feed(&sparse,good(),0.5,id:1)
        require(sparse.latched,"Two widely separated samples counted as continuous recovery")
        var periodic = PeripheralGlassPolicy(); warm(&periodic)
        for i in 13...36 {
            feed(&periodic,i%4 == 0 ? .unknown("false-peak") : good(),Double(i)/12,id:UInt64(i))
            require(!periodic.latched,"Periodic uncertain peaks caused false black despite fresh reliable coverage")
        }
        var crossed = PeripheralGlassPolicy(); warm(&crossed)
        var ambiguous = good(); ambiguous.interval = 0.02...0.15
        feed(&crossed,ambiguous,1.08,id:13)
        require(!crossed.latched && crossed.certificateDeadline == 1.2,"Cross-threshold interval was treated as confirmed large or small")
        for fps in [60.0,30,15] {
            let interval = PeripheralAlignmentWorker.expectedMeasurementInterval(frameInterval:1/fps)
            var fallback = PeripheralGlassPolicy()
            for i in 0...12 { feed(&fallback,good(),Double(i)*interval,id:UInt64(i),interval:interval) }
            require(!fallback.latched,"Legitimate \(fps) FPS analysis cadence never recovered")
        }
        var previous = -1.0
        for i in 0...120 { let alpha = PeripheralGlassPolicy.darkness(forError:Double(i)/1000); require(alpha >= previous,"Nonmonotonic darkness"); previous = alpha }
        require(close(PeripheralGlassPolicy.darkness(forError:0.075),0.5),"5–10% curve changed")
        print("PASS: production policy deadlines, transient/persistent unknown, true large displacement, epochs, ordering, pauses and continuous recovery")
    }

    static func projectionChecks() {
        let identity = PeripheralAlignmentWorker.samplingTransform(homography: matrix_identity_float3x3,
            width: 192, height: 256, ratio: 2)
        let center = PeripheralAlignmentWorker.project(SIMD2(0.5,0.5), using: identity)!
        let corner = PeripheralAlignmentWorker.project(SIMD2(0,0), using: identity)!
        require(simd_length(center-SIMD2(0.5,0.5)) < 0.00001, "Center UV moved")
        require(simd_length(corner-SIMD2(0.25,0.25)) < 0.00001, "Top-left crop mapping flipped")
        var h = matrix_identity_float3x3
        h.columns.2 = SIMD3(12,16,1)
        let matrix = PeripheralAlignmentWorker.samplingTransform(homography: h, width: 192, height: 256, ratio: 2)
        let moved = PeripheralAlignmentWorker.project(SIMD2(0.5,0.5), using: matrix)!
        require(close(Double(moved.x),0.5-12.0/384.0), "Floating-to-reference transform was not inverted")
        require(close(Double(moved.y),0.5+16.0/512.0), "CI bottom-left to texture top-left conversion failed")
        require(PeripheralAlignmentWorker.project(.zero, using: simd_float3x3()) == nil, "Degenerate projection was admitted")
        require(PeripheralSeams(photo: CGRect(x: 0,y: 185,width: 440,height: 586),
            window: CGSize(width: 440,height: 956)) == .horizontal,
            "Portrait checked a vertical boundary without an adjacent peripheral pane")
        require(PeripheralSeams(photo: CGRect(x: 185,y: 0,width: 586,height: 440),
            window: CGSize(width: 956,height: 440)) == .vertical,
            "Landscape checked a horizontal boundary without an adjacent peripheral pane")
        require(PeripheralSeams(photo: CGRect(x: 0,y: 0,width: 440,height: 956),
            window: CGSize(width: 440,height: 956)).isEmpty,
            "A full-window photograph invented a peripheral seam")
        print("PASS: independent pixel-space translation, inverse and y-axis golden vectors")
    }

    static func rasterChecks() {
        let w = 5,h = 3
        var pixels = [UInt8](repeating:255,count:w*h*4)
        for y in 0..<h { for x in 0..<w {
            pixels[(y*w+x)*4] = UInt8(20+x*30)
            pixels[(y*w+x)*4+1] = UInt8(20+y*60)
            pixels[(y*w+x)*4+2] = UInt8(10+x*9+y*11)
        } }
        let image = CIImage(cvPixelBuffer:pixelBuffer(rgba:pixels,width:w,height:h))
            .transformed(by:CGAffineTransform(translationX:17,y:23))
        let values = PeripheralAlignmentWorker().bitmap(image,bounds:CGRect(x:17,y:23,width:w,height:h),width:w,height:h)
        require(values == pixels,"CV buffer → CI → nonzero-extent bitmap flipped rows or ignored bytesPerRow")
        print("PASS: nonsymmetric 5x3 CV buffer → CI → bitmap golden, nonzero extent and top-to-bottom row order")
    }
    static func texture(width: Int, height: Int, seed: UInt64) -> [UInt8] {
        var state = seed
        var image = [UInt8](repeating: 255, count: width*height*4)
        for i in stride(from: 0, to: image.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let value = UInt8(32 + ((state >> 32) % 192))
            image[i] = value; image[i+1] = value; image[i+2] = value
        }
        return image
    }
    static func crop(_ image: [UInt8],sourceWidth: Int,x: Int,y: Int,width: Int,height: Int) -> [UInt8] {
        var out = [UInt8](repeating:255,count:width*height*4)
        for yy in 0..<height { for xx in 0..<width { for c in 0..<4 { out[(yy*width+xx)*4+c] = image[((yy+y)*sourceWidth+xx+x)*4+c] } } }
        return out
    }
    static func fixture(dx: Int = 0,dy: Int = 0,seed: UInt64 = 8) -> (a:[UInt8],b:[UInt8]) {
        let w = 192,h = 256,p = 32,extra = 40,sw = w+2*p+2*extra
        let scene = texture(width:sw,height:h+2*p+2*extra,seed:seed)
        return (crop(scene,sourceWidth:sw,x:extra+p,y:extra+p,width:w,height:h),
                crop(scene,sourceWidth:sw,x:extra-dx,y:extra-dy,width:w+2*p,height:h+2*p))
    }
    static func measure(_ a:[UInt8],_ b:[UInt8],fundamental:simd_float3x3? = nil,budget:Int = 90_000_000) -> PeripheralAlignmentWorker.SeamMeasurement {
        PeripheralAlignmentWorker.measureSeams(reference:a,warped:b,width:192,height:256,warpedPadding:32,
            seams:.horizontal,certifiedGeometry:true,previousGain:SIMD3(repeating:1),allowPartial:true,
            fundamental:fundamental,comparisonBudget:budget)!
    }
    static func seamChecks() {
        let zero = fixture(), aligned = measure(zero.a,zero.b)
        require(aligned.evidence.reliable && aligned.residual == 0 && aligned.geometryVerified,"Aligned unique texture did not produce independent evidence")
        require(aligned.segments.count == 24,"Full horizontal boundary segmentation missing")
        for (dx,dy) in [(5,-3),(24,0),(-24,0),(0,24)] {
            let input = fixture(dx:dx,dy:dy), measured = measure(input.a,input.b)
            require(measured.evidence.reliable && close(measured.residual,hypot(Double(dx),Double(dy))/192,0.001),
                "Known translation lost its actual displacement: \(dx),\(dy)")
        }
        let truncated = fixture(dx:30), atLimit = measure(truncated.a,truncated.b)
        require(!atLimit.evidence.reliable,"Search boundary was certified as complete small displacement")
        let budget = measure(zero.a,zero.b,budget:1000)
        require(!budget.evidence.reliable && budget.evidence.status == .budgetExceeded && budget.comparisons <= 1000,"Budget exhaustion silently accepted a partial peak")
        var weakA = zero.a, weakB = zero.b
        for i in stride(from:0,to:weakA.count,by:4) { for c in 0..<3 { weakA[i+c] = 112+weakA[i+c]%33 } }
        // Use the same radiometric transform on the true +24 displacement.
        let displaced = fixture(dx:24)
        weakA = displaced.a; weakB = displaced.b
        for i in stride(from:0,to:weakA.count,by:4) { for c in 0..<3 { weakA[i+c] = 112+weakA[i+c]%33 } }
        for i in stride(from:0,to:weakB.count,by:4) { for c in 0..<3 { weakB[i+c] = 112+weakB[i+c]%33 } }
        let weak = measure(weakA,weakB)
        require(weak.evidence.reliable && weak.evidence.interval!.lowerBound > 0.10,"Appearance similarity concealed a unique large shift")
        var occluded = zero.b
        for y in 32..<32+30 { for x in 32+50..<32+76 { for c in 0..<3 { occluded[(y*256+x)*4+c] = 0 } } }
        let blind = measure(zero.a,occluded)
        require(!blind.evidence.reliable || blind.evidence.appearance == .mismatch,"Occlusion in the old six-window blind spot was certified clear")
        var lineA = [UInt8](repeating:255,count:192*256*4), lineB = [UInt8](repeating:255,count:256*320*4)
        for i in stride(from:0,to:lineA.count,by:4) { for c in 0..<3 { lineA[i+c] = 128 } }
        for i in stride(from:0,to:lineB.count,by:4) { for c in 0..<3 { lineB[i+c] = 128 } }
        for y in 0..<256 { for c in 0..<3 { lineA[(y*192+96)*4+c] = 0 } }
        for y in 0..<320 { for c in 0..<3 { lineB[(y*256+152)*4+c] = 0 } }
        let line = measure(lineA,lineB)
        require((line.evidence.confirmedSevereLowerBound ?? 0) > 0.10,"Corroborated thin-line normal shift was lost among flat segments")
        var linePolicy = PeripheralGlassPolicy(); warm(&linePolicy)
        feed(&linePolicy,line.evidence,1.08,id:13)
        require(linePolicy.latched && linePolicy.reason == "confirmed-local-displacement","A confirmed severe local structure waited for unrelated unknown expiry")
        require(!line.evidence.reliable || line.residual > 0.1,"Displaced salient line became certain zero")
        for y in 0..<256 { for x in 0..<192 { for c in 0..<3 { lineA[(y*192+x)*4+c] = x%24 < 12 ? 64:192 } } }
        for y in 0..<320 { for x in 0..<256 { for c in 0..<3 { lineB[(y*256+x)*4+c] = (x-32+240)%24 < 12 ? 64:192 } } }
        let periodic = measure(lineA,lineB)
        require(!periodic.evidence.reliable,"Periodic texture was uniquely certified by current appearance")
        let f = simd_float3x3(SIMD3(0,0,0),SIMD3(0,0,1),SIMD3(0,-1,0))
        let epipolar = measure(displaced.a,displaced.b,fundamental:f)
        require(epipolar.evidence.reliable && close(epipolar.residual,0.125,0.001),"Validated horizontal epipolar search changed a known shift")
        require(epipolar.comparisons < aligned.comparisons,"Physical constraint did not reduce complete search work")
        let wrongF = simd_float3x3(SIMD3(0,0,-1),SIMD3(0,0,0),SIMD3(1,0,0))
        let fallback = measure(displaced.a,displaced.b,fundamental:wrongF)
        require(fallback.evidence.reliable && close(fallback.residual,0.125,0.001),"Unvalidated coordinate convention forced an incorrect 1D match")
        var brighter = zero.b
        for i in stride(from:0,to:brighter.count,by:4) { for c in 0..<3 { brighter[i+c] = UInt8(min(242,Int(Float(brighter[i+c])*1.1))) } }
        let exposure = measure(zero.a,brighter)
        require(exposure.evidence.reliable && exposure.residual < 0.01 && exposure.photometryVerified && exposure.gain.x < 1,
                "Independent photometry did not update under a fixed geometric mapping")
        // Multiple planes: no single small scalar may certify both depths.
        let near = fixture(dx:24)
        var twoPlanes = zero.b
        for y in 0..<320 { for x in 128..<256 { for c in 0..<4 { twoPlanes[(y*256+x)*4+c] = near.b[(y*256+x)*4+c] } } }
        let planes = measure(zero.a,twoPlanes)
        require(!planes.evidence.reliable || planes.evidence.interval!.upperBound > 0.10,"Two depth layers were averaged into false clear")
        var flatA = zero.a,flatB = zero.b
        for i in stride(from:0,to:flatA.count,by:4) { for c in 0..<3 { flatA[i+c] = 128 } }
        for i in stride(from:0,to:flatB.count,by:4) { for c in 0..<3 { flatB[i+c] = 128 } }
        require(!measure(flatA,flatB).evidence.reliable,"Cold uniform wall acquired fictitious geometry")
        for (tw,th) in [(64,64),(96,128),(192,144),(256,192)] {
            let sw = tw+64, scene = texture(width:sw,height:th+64,seed:UInt64(tw+th))
            let photo = crop(scene,sourceWidth:sw,x:32,y:32,width:tw,height:th)
            let value = PeripheralAlignmentWorker.measureSeams(reference:photo,warped:scene,width:tw,height:th,
                warpedPadding:32,seams:.horizontal,certifiedGeometry:true,allowPartial:true)!
            require(value.evidence.reliable,"Padded support failed at \(tw)x\(th)")
        }
        let moved = fixture(dx:4)
        let centerNext = crop(moved.b,sourceWidth:256,x:32,y:32,width:192,height:256)
        let oldRaster = PeripheralMotion.raster(pixelBuffer(rgba:moved.a,width:192,height:256))!
        let nextRaster = PeripheralMotion.raster(pixelBuffer(rgba:centerNext,width:192,height:256))!
        let drift = PeripheralMotion.displacement(oldRaster,nextRaster)
        require(drift != nil && (3...5.5).contains(drift!),"Temporal sentinel lost a known four-analysis-pixel motion")
        let flatRaster = PeripheralMotion.raster(pixelBuffer(rgba:flatA,width:192,height:256))!
        require(PeripheralMotion.displacement(flatRaster,flatRaster) == nil,"Unobservable temporal motion was silently zero")
        print("PASS: known small/large shifts, appearance-shortcut counterexamples, complete search/limits, occlusion coverage, F validation/fallback and independent photometry; comparisons 2D=\(aligned.comparisons), constrained=\(epipolar.comparisons)")
    }
    static func motionChecks() {
        // Retain all 160 old fixtures, but do not require unavailable geometry
        // to become transparent. The invariant is no confident false-large peak.
        let w = 192,h = 256,p = 32
        var falseLarge = 0, measuredCount = 0, unknownCount = 0, nativeVisibleCount = 0
        for contrast in [2.0,3.0,4.0,6.0] { for index in 0..<40 {
            let angle = 4*sin(Double(index)*0.18)*Double.pi/180, cs = cos(angle), sn = sin(angle)
            var a = [UInt8](repeating:255,count:w*h*4), b = [UInt8](repeating:255,count:(w+64)*(h+64)*4)
            var seed = UInt64(534+index), other = UInt64(839+index)
            for y in -p..<h+p { for x in -p..<w+p {
                let u = cs*Double(x-w/2)-sn*Double(y-h/2)+Double(w/2)
                let v = sn*Double(x-w/2)+cs*Double(y-h/2)+Double(h/2)
                let c = y < 42 || y >= h-42 ? contrast : 30
                let value = 128+c*(sin(u*0.17)+0.7*sin((u+v)*0.093)+0.3*sin(v*0.73))
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                other = other &* 6364136223846793005 &+ 1442695040888963407
                let aa = UInt8(max(0,min(255,Int(value.rounded())+Int((seed>>32)%9)-4)))
                let bb = UInt8(max(0,min(255,Int(value.rounded())+Int((other>>32)%9)-4+20)))
                for channel in 0..<3 {
                    b[((y+p)*(w+64)+x+p)*4+channel] = bb
                    if (0..<w).contains(x), (0..<h).contains(y) { a[(y*w+x)*4+channel] = aa }
                }
            } }
            let value = measure(a,b)
            if (value.evidence.confirmedSevereLowerBound ?? 0) > 0.10 { falseLarge += 1 }
            if value.evidence.reliable { measuredCount += 1; if value.evidence.interval!.lowerBound > 0.10 { falseLarge += 1 } }
            else { unknownCount += 1 }
            if index%10 == 0 {
                let outer = crop(b,sourceWidth:w+64,x:32,y:32,width:w,height:h)
                let strips = [0,1].map { edge in PeripheralNativeSeam.Strip(edge:edge,width:w,height:12,
                    reference:crop(a,sourceWidth:w,x:0,y:edge == 0 ? 0 : h-12,width:w,height:12),
                    outer:crop(outer,sourceWidth:w,x:0,y:edge == 0 ? 0 : h-12,width:w,height:12),nativeScale:1) }
                let native = PeripheralNativeSeam.selectPhotometry(strips,candidate:PeripheralNativeSeam.estimate(strips),preferred:nil,segments:value.segments,
                    analysisWidth:w,analysisHeight:h,geometryVerified:false,severe:value.evidence.confirmedSevereLowerBound)
                if native.evidence.compatible { nativeVisibleCount += 1 }
                else {
                    print("Native positive rejected: contrast=\(contrast), index=\(index), affine=\(native.gains.encodedAffineEdges)")
                    for row in native.diagnostics where row["passed"] as? Bool != true {
                        print(row.filter { ["edge","start","colorPass","flatBothNative","nativeStructurePass","nativePeriodicProfile","currentNativeGrayNCC","currentNativeGrayAgreement","nativeNoiseSigma","maximumRawGradient"].contains($0.key) })
                    }
                }
            }
        } }
        require(falseLarge == 0,"Known-zero weak/noisy scenes produced confirmed large disparity")
        require(nativeVisibleCount == 16,"A predefined native weak/rotated/exposure positive lost visible permission")
        print("PASS: 160 zero-relative-disparity noise/rotation fixtures: falseLarge=\(falseLarge), measured=\(measuredCount), unknown=\(unknownCount); unknown does not certify transparency")
        print("Native visible positives among 16 predefined noise/common-rotation/exposure fixtures: \(nativeVisibleCount)")
    }

    static func sample(time: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        require(CVPixelBufferCreate(nil,32,32,kCVPixelFormatType_32BGRA,nil,&pixel) == kCVReturnSuccess, "CVPixelBuffer allocation")
        var format: CMVideoFormatDescription?
        require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel!, formatDescriptionOut: &format) == noErr,
                "Video format")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1,timescale: 30),
            presentationTimeStamp: CMTime(seconds: time,preferredTimescale: 60000), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        require(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel!,formatDescription: format!,
            sampleTiming: &timing,sampleBufferOut: &buffer) == noErr, "Sample buffer")
        return buffer!
    }
    static func mailboxChecks() throws {
        let source = PeripheralFrameSource(); source.configure(outputIndex:1,ratio:2)
        let selection = source.selection()
        source.offer(center:try sample(time:1),outer:try sample(time:1.004),selection:selection,receipt:100)
        require(source.latest()?.serial == 1 && close(source.latest()!.ptsDelta!,0.004),"Paired PTS metadata lost")
        source.offer(center:try sample(time:1),outer:try sample(time:1.004),selection:selection,receipt:100.01)
        require(source.latest()?.serial == 1,"Consumed frame pair was reused")
        source.reset(); source.offer(center:try sample(time:2),outer:try sample(time:2),selection:selection,receipt:100.02)
        require(source.latest() == nil,"Old epoch callback accepted")
        let buffered = PeripheralFrameSource(); buffered.configure(outputIndex:1,ratio:2)
        let config = buffered.selection()
        buffered.offer(center:try sample(time:0),outer:nil,selection:config,receipt:100)
        buffered.offer(center:nil,outer:try sample(time:0.016),selection:config,receipt:100.001)
        require(buffered.latest() == nil,"Split callbacks greedily paired before nearest-neighbour window")
        buffered.offer(center:try sample(time:1.0/60),outer:nil,selection:config,receipt:100.016)
        require(buffered.latest() != nil && abs(buffered.latest()!.ptsDelta!) < 0.001,"Bounded nearest pairing selected a worse old center")
        buffered.configure(outputIndex:1,ratio:3)
        require(buffered.latest() == nil,"Zoom retained old geometry")
        buffered.invalidate()
        buffered.offer(center:try sample(time:2),outer:try sample(time:2),selection:buffered.selection())
        require(buffered.latest() == nil,"Invalidated source accepted frames")
        let s = try sample(time:3)
        let k = simd_float3x3(SIMD3(410,0,0),SIMD3(0,420,0),SIMD3(15.2,16.3,1))
        let data = withUnsafeBytes(of:k) { Data($0) }
        CMSetAttachment(s,key:kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,value:data as CFData,attachmentMode:kCMAttachmentMode_ShouldPropagate)
        let meta = PeripheralFrameMetadata(s,id:7,clock:nil)
        require(meta.intrinsic == k && meta.id == 7 && meta.pts == 3 && meta.hostCaptureTime == nil,"Aligned K read or timestamp-domain flag wrong")
        let rt = simd_float4x3(SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(0,0,1),SIMD3(-12,3,0.5))
        let extrinsic = withUnsafeBytes(of:rt) { Data($0) }
        let calibration = PeripheralCalibration.decode(extrinsic,identity:"fixture",outputRotation:0)
        require(calibration?.translation == SIMD3(-12,3,0.5),"Factory translation direction/unit or SIMD padding incorrect")
        require(PeripheralCalibration.decode(Data(repeating:0,count:48),identity:"invalid",outputRotation:0) == nil,"Malformed calibration accepted")
        let pixel = CMSampleBufferGetImageBuffer(s)!
        let pair = PeripheralFrameSource.Pair(center:pixel,outer:pixel,receipt:0,
            configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:1,
            centerMetadata:meta,outerMetadata:meta,calibration:calibration)
        var h = matrix_identity_float3x3; h[2] = SIMD3(4,-6,1)
        let f = PeripheralAlignmentWorker.analysisFundamental(pair,homography:h,width:192,height:256)!
        let world = SIMD3<Float>(35,-20,1000), outerWorld = world+SIMD3(-12,3,0.5)
        let c = k*world, o = k*outerWorld
        let pc = SIMD3(c.x/c.z,c.y/c.z,1), po = SIMD3(o.x/o.z,o.y/o.z,1)
        // Independent upper-left pixel transforms for 32x32 -> 192x256,
        // outer FOV scale2, and (+4,-6) CI translation -> (+4,+6) bitmap.
        let ac = simd_float3x3(SIMD3(6,0,0),SIMD3(0,8,0),SIMD3(0,0,1))
        let ao = simd_float3x3(SIMD3(12,0,0),SIMD3(0,16,0),SIMD3(-92,-122,1))
        require(abs(simd_dot(ao*po,f*(ac*pc))) < 0.0001,"K/R/t → CI/H → top-left bitmap epipolar direction is wrong")
        print("PASS: bounded nearest pairing, original PTS/IDs, no reuse, geometry epochs, aligned K/R/t decoding and clock-domain flags")
    }

    static func pixelBuffer(rgba: [UInt8], width: Int, height: Int) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        require(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &result) == kCVReturnSuccess,
            "Registration fixture pixel buffer allocation")
        let buffer = result!
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width {
            let source = (y*width+x)*4, destination = y*row+x*4
            pointer[destination] = rgba[source+2]; pointer[destination+1] = rgba[source+1]
            pointer[destination+2] = rgba[source]; pointer[destination+3] = rgba[source+3]
        } }
        return buffer
    }

    static func diagnosticChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glasscam-ring-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let input = fixture(), cb = pixelBuffer(rgba:input.a,width:192,height:256), ob = pixelBuffer(rgba:input.b,width:256,height:320)
        var clock = 0.0, serial:UInt64 = 0
        let recorder = PeripheralDiagnosticRecorder(enabled:true,directory:root,clock:{clock})
        func emit(_ recorder: PeripheralDiagnosticRecorder,_ status:String) {
            serial += 1; clock += 1.0/12
            let pair = PeripheralFrameSource.Pair(center:cb,outer:ob,receipt:clock,
                configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:serial)
            recorder.record(reference:input.a,warped:input.b,width:192,height:256,padding:32,pair:pair,
                reason:status,status:status,matrix:status == "unknown" ? nil : matrix_identity_float3x3,comparisons:0,coverage:1,segments:[],gain:SIMD3(repeating:1))
        }
        func finish(_ recorder: PeripheralDiagnosticRecorder) {
            let timeout = CACurrentMediaTime()+5
            while recorder.statistics.writing && CACurrentMediaTime() < timeout { Thread.sleep(forTimeInterval:0.005) }
            require(!recorder.statistics.writing,"Asynchronous diagnostic writer stalled")
        }
        for _ in 0..<24 { emit(recorder,"measured") }
        for event in 0..<4 {
            clock += 6
            let status = event%2 == 0 ? "unknown" : "measured"
            emit(recorder,status)
            for _ in 0..<12 { emit(recorder,status) }
            finish(recorder)
        }
        require(recorder.statistics.events == 3 && recorder.statistics.bytes < 64*1024*1024,"Diagnostic storage grew beyond hard event/byte limits")
        let events = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
        require(events.count == 3,"Event quota did not match saved directories")
        let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:events[0].appendingPathComponent("manifest.json"))) as! [String:Any]
        let frames = manifest["frames"] as! [[String:Any]]
        require(frames.count == 36 && frames[0]["referenceSHA256"] != nil,"Pre/post event replay or raw-byte hashes missing")
        let failure = root.appendingPathComponent("blocked")
        FileManager.default.createFile(atPath:failure.path,contents:Data([0]))
        let retry = PeripheralDiagnosticRecorder(enabled:true,directory:failure,clock:{clock})
        emit(retry,"measured"); retry.trigger("synthetic-renderer-failure"); emit(retry,"measured")
        for _ in 0..<12 { emit(retry,"measured") }; finish(retry)
        require(retry.statistics.events == 0,"Failed I/O consumed a successful-event quota")
        try FileManager.default.removeItem(at:failure)
        clock += 6; retry.trigger("synthetic-retry"); emit(retry,"measured")
        for _ in 0..<12 { emit(retry,"measured") }; finish(retry)
        require(retry.statistics.events == 1,"Diagnostic writer could not recover from a filesystem failure")
        print("PASS: exact-byte pre/post ring, SHA-256 manifests, async I/O failure/retry and 3-event/64MiB hard bounds")
    }

    static func directStitchChecks() {
        let width = 384,height = 512,cropX = 100,cropY = 126
        let outer = texture(width:width,height:height,seed:2619)
        let center = crop(outer,sourceWidth:width,x:cropX,y:cropY,width:192,height:256)
        let worker = PeripheralAlignmentWorker()
        func pair(_ pixels:[UInt8],time:Double,serial:UInt64,epoch:UInt64 = 7) -> PeripheralFrameSource.Pair {
            .init(center:pixelBuffer(rgba:pixels,width:192,height:256),outer:pixelBuffer(rgba:outer,width:width,height:height),receipt:time,
                configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:epoch),serial:serial)
        }
        // Explicit virtual clock only for geometric correctness; real-time
        // freshness and asynchronous publication are separately exercised below.
        guard let aligned = worker.analyze(pair(center,time:100,serial:1),seams:.horizontal,now:{100}) else {
            fatalError("Direct seam analysis could not measure a known overlapping scene")
        }
        require(aligned.evidence.reliable && (0.02...0.04).contains(aligned.residual),"Direct seam measurement did not retain the known crop offset")
        require(aligned.isFresh(for:7,at:100.1) && !aligned.isFresh(for:7,at:100.21) && !aligned.isFresh(for:8,at:100.1),"Result epoch/deadline invalid")
        let mapped = PeripheralAlignmentWorker.project(SIMD2(0.5,0.5),using:aligned.photoToOuter)!
        let expected = SIMD2<Float>(0.5,0.5)
        require(simd_length(mapped-expected) < 0.00001 && aligned.directStitch && aligned.refinement == nil,"Direct stitching applied a scene-fitted correction")
        require(worker.analyze(pair(center,time:100,serial:1),seams:.horizontal,now:{101}) == nil,"Expired input accepted")
        var occluded = center
        for y in 0..<30 { for x in 50..<76 { for c in 0..<3 { occluded[(y*192+x)*4+c] = 0 } } }
        let unknown = worker.analyze(pair(occluded,time:100.1,serial:2),seams:.horizontal,now:{100.1})
        require(unknown == nil || !unknown!.evidence.reliable || unknown!.evidence.appearance == .mismatch,"Worker hid actual boundary occlusion")
        let resumed = worker.analyze(pair(center,time:100.2,serial:3),seams:.horizontal,now:{100.2})
        require(resumed?.evidence.reliable == true,"Worker did not recover after temporary unknown")
        let live = PeripheralAlignmentWorker()
        let frame = pair(center,time:CACurrentMediaTime(),serial:1,epoch:8)
        require(live.request(frame,seams:.horizontal),"Bounded asynchronous worker refused initial request")
        require(!live.request(frame,seams:.horizontal),"Worker queued a duplicate concurrent task")
        let timeout = CACurrentMediaTime()+5
        while live.isAnalyzing && CACurrentMediaTime() < timeout { Thread.sleep(forTimeInterval:0.005) }
        require(!live.isAnalyzing,"Single analysis worker stalled")
        require(live.latest() != nil,"Warmed real-time worker did not publish within its hard deadline")
        let actual = live.latest()!
        require(actual.completedAt-actual.receipt <= 0.20 && actual.epoch == 8,"Asynchronous publication admitted expired/wrong epoch result")
        print("Real-clock warmed analysis ms: \((actual.completedAt-actual.receipt)*1000)")
        let domain = CGRect(x:0,y:-0.25,width:1,height:1.5)
        let legal = aligned.photoToOuter
        require((PeripheralProjection.margin(legal,window:domain,width:384,height:512) ?? -1) >= 2,"Legal full-window coverage rejected")
        var illegal = legal; illegal[2].x -= 1
        require((PeripheralProjection.margin(illegal,window:domain,width:384,height:512) ?? -1) < 2,"Out-of-texture candidate admitted")
        print("PASS: production direct FOV/CI, crop orientation, candidate coverage, unknown/recovery, explicit virtual time and bounded real-clock asynchronous publication")
    }

    static func shaderChecks() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A real Metal device is required")
        }
        let library = try device.makeLibrary(source: PeripheralGlassShader.source, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "glassVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "glassFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,width: 32,height: 32,mipmapped: false)
        inputDescriptor.storageMode = .shared; inputDescriptor.usage = .shaderRead
        let input = device.makeTexture(descriptor: inputDescriptor)!
        let color: [Float16] = [0.25,0.5,2,1]
        let pixels = (0..<(32*32)).flatMap { _ in color }
        pixels.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0,0,32,32),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 32*8) }
        let w = 96,h = 192
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,width: w,height: h,mipmapped: false)
        outputDescriptor.storageMode = .shared; outputDescriptor.usage = [.renderTarget,.shaderRead]
        let output = device.makeTexture(descriptor: outputDescriptor)!
        let transform = PeripheralAlignmentWorker.samplingTransform(homography: matrix_identity_float3x3,width: 192,height: 256,ratio: 2)
        for blackness: Float in [0,0.5,1] {
            var uniforms = PeripheralGlassUniforms(photo: SIMD4(0,Float(1.0/6.0),1,Float(2.0/3.0)),
                viewport: SIMD2(Float(w),Float(h)),blackOpacity: blackness,photoToOuter: transform,gain: SIMD4(repeating: 1))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
            let command = queue.makeCommandBuffer()!, encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(input,index: 0)
            encoder.setFragmentBytes(&uniforms,length: MemoryLayout<PeripheralGlassUniforms>.stride,index: 0)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3); encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            require(command.status == .completed, "Metal glass rendering failed")
            var bytes = [Float16](repeating: 0,count: w*h*4)
            bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow: w*8,from: MTLRegionMake2D(0,0,w,h),mipmapLevel: 0) }
            for y in 0..<h { for x in 0..<w {
                let i = (y*w+x)*4
                if (32..<160).contains(y) {
                    require(bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 0,
                            "Glass modified a central photo pixel")
                } else {
                    require(bytes[i+3] == 1,"Perimeter was not fully owned by glass")
                    if blackness == 1 { require(bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0,"Blackening left transmitted light") }
                    else {
                        // Unblurred, undimmed transmission scaled only by darkness.
                        let keep = 1 - blackness
                        for (c, expected) in [Float(0.25), 0.5, 2].enumerated() {
                            require(abs(Float(bytes[i+c]) - expected*keep) < 0.002,
                                    "Periphery brightness must match the source, scaled only by darkness")
                        }
                    }
                }
            } }
        }
        var edgeUniforms = PeripheralGlassUniforms(photo:SIMD4(0,Float(1.0/6.0),1,Float(2.0/3.0)),
            viewport:SIMD2(Float(w),Float(h)),blackOpacity:0,photoToOuter:transform,gain:SIMD4(repeating:1))
        edgeUniforms.gainTop = SIMD4(0.5,0.5,0.5,1); edgeUniforms.gainBottom = SIMD4(1.5,1.5,1.5,1)
        edgeUniforms.gainLeft = SIMD4(repeating:1); edgeUniforms.gainRight = SIMD4(repeating:1)
        let edgePass = MTLRenderPassDescriptor()
        edgePass.colorAttachments[0].texture = output; edgePass.colorAttachments[0].loadAction = .clear
        edgePass.colorAttachments[0].storeAction = .store
        edgePass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
        let edgeCommand = queue.makeCommandBuffer()!, edgeEncoder = edgeCommand.makeRenderCommandEncoder(descriptor:edgePass)!
        edgeEncoder.setRenderPipelineState(pipeline); edgeEncoder.setFragmentTexture(input,index:0)
        edgeEncoder.setFragmentBytes(&edgeUniforms,length:MemoryLayout<PeripheralGlassUniforms>.stride,index:0)
        edgeEncoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); edgeEncoder.endEncoding()
        edgeCommand.commit(); edgeCommand.waitUntilCompleted()
        var edgePixels = [Float16](repeating:0,count:w*h*4)
        edgePixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:w*8,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0) }
        require(abs(Float(edgePixels[(10*w+48)*4])-0.125) < 0.002 && abs(Float(edgePixels[(180*w+48)*4])-0.375) < 0.002,
            "Actual shader did not apply independently verified top/bottom linear photometry")
        edgeUniforms.gainTop = SIMD4(0.7,0.7,0.7,2); edgeUniforms.gainBottom = edgeUniforms.gainTop
        edgeUniforms.biasTop = SIMD4(0.06,0.06,0.06,0); edgeUniforms.biasBottom = edgeUniforms.biasTop
        let affineCommand = queue.makeCommandBuffer()!, affineEncoder = affineCommand.makeRenderCommandEncoder(descriptor:edgePass)!
        affineEncoder.setRenderPipelineState(pipeline); affineEncoder.setFragmentTexture(input,index:0)
        affineEncoder.setFragmentBytes(&edgeUniforms,length:MemoryLayout<PeripheralGlassUniforms>.stride,index:0)
        affineEncoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); affineEncoder.endEncoding()
        affineCommand.commit(); affineCommand.waitUntilCompleted()
        edgePixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:w*8,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0) }
        require(abs(Float(edgePixels[(10*w+48)*4])-0.1594601) < 0.002,
            "Native sRGB photometry and the actual linear Metal output disagree (double/missing transfer function)")
        edgeUniforms.edgeOpacity=SIMD4(1,0,1,1)
        let regionalCommand=queue.makeCommandBuffer()!, regionalEncoder=regionalCommand.makeRenderCommandEncoder(descriptor:edgePass)!
        regionalEncoder.setRenderPipelineState(pipeline);regionalEncoder.setFragmentTexture(input,index:0)
        regionalEncoder.setFragmentBytes(&edgeUniforms,length:MemoryLayout<PeripheralGlassUniforms>.stride,index:0)
        regionalEncoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);regionalEncoder.endEncoding()
        regionalCommand.commit();regionalCommand.waitUntilCompleted()
        edgePixels.withUnsafeMutableBytes {output.getBytes($0.baseAddress!,bytesPerRow:w*8,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)}
        require(edgePixels[(10*w+48)*4] == 0 && Float(edgePixels[(180*w+48)*4])>0.15,
            "Actual Metal per-pane opacity blackened the independent clear pane or exposed a rejected pane")
        require(edgePixels[(80*w+48)*4+3] == 0,"Regional glass wrote a central photo pixel")
        var ramp = [Float16](repeating:1,count:32*32*4)
        for y in 0..<32 { for x in 0..<32 {
            ramp[(y*32+x)*4] = Float16(Float(x)/32)
            ramp[(y*32+x)*4+1] = Float16(Float(y)/32)
            ramp[(y*32+x)*4+2] = Float16(Float(x+2*y)/96)
        } }
        ramp.withUnsafeBytes { input.replace(region:MTLRegionMake2D(0,0,32,32),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:32*8) }
        var uniforms = PeripheralGlassUniforms(photo:SIMD4(0,Float(1.0/6.0),1,Float(2.0/3.0)),
            viewport:SIMD2(Float(w),Float(h)),blackOpacity:0,photoToOuter:transform,gain:SIMD4(repeating:1))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let command = queue.makeCommandBuffer()!, encoder = command.makeRenderCommandEncoder(descriptor:pass)!
        encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(input,index:0)
        encoder.setFragmentBytes(&uniforms,length:MemoryLayout<PeripheralGlassUniforms>.stride,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        var result = [Float16](repeating:0,count:w*h*4)
        result.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:w*8,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0) }
        for y in [3,17,174,188] { for x in [5,27,61,89] {
            let sx = (Float(x)+0.5)/Float(w), sy = (Float(y)+0.5)/Float(h)
            let expectedX = 0.25+0.5*sx-0.5/32
            let expectedY = 0.25+0.5*((sy-1.0/6)/(2.0/3))-0.5/32
            let i = (y*w+x)*4
            require(abs(Float(result[i])-expectedX) < 0.002 && abs(Float(result[i+1])-expectedY) < 0.002,
                "Asymmetric shader sampling flipped an axis or used the wrong UV transform")
        } }
        print("PASS: actual Metal shader, asymmetric UV/ramp sampling and central RGBA exclusion at all glass states")
    }
}

extension PeripheralGlassChecks {
    static func localDeformationChecks() {
        func assessment(_ offsets:[SIMD2<Double>],change:((inout [[String:Any]])->Void)? = nil) -> PeripheralPaneAssessment {
            var rows:[[String:Any]]=(0..<12).map { i in
                let textured=(4..<4+offsets.count).contains(i)
                let offset=textured ? offsets[i-4]:.zero,d=simd_length(offset)
                return ["edge":0,"start":i*16,"end":(i+1)*16,"nativeScale":1.0,"nativeSampleCount":128,
                    "nativeEdgeSupport":textured ? [64,64]:[0,0],"nativeWeakEdgeSupport":textured ? [128,128]:[0,0],
                    "currentNativeGrayVariance":textured ? [0.01,0.01]:[0.0,0.0],"nativeNoiseSigma":[0.0,0.0],
                    "currentNativeGrayNCC":textured ? 0.1:1.0,"flatBothNative": !textured,
                    "segmentStatus":textured ? "measured":"unobservable","segmentSearchComplete":true,
                    "segmentRepeated":false,"segmentPeak":0.99,"segment":i,
                    "segmentVisibleShiftLower":max(0,(d-sqrt(0.5))/192),"segmentVisibleShiftUpper":(d+sqrt(0.5))/192,
                    "segmentPoint":[Double(i*16+8),10.0],"segmentBestDisplacement":[offset.x,offset.y],
                    "segmentForwardBackward":0.0,"segmentDisplacementUncertainty":sqrt(0.5),
                    "missingStructureExtentFraction":0.0]
            }
            change?(&rows)
            var result=PeripheralAlignmentResult(epoch:1,receipt:0,photoAspectRatio:0.75,
                photoToOuter:matrix_identity_float3x3,residual:.nan,gain:SIMD3(repeating:1),seams:.horizontal,expiresAt:0.2)
            result.nativeSeam=PeripheralNativeSeam(strips:[],gains:.init(),evidence:.init(compatible:false,coverage:1,
                maximumObservableError:nil,reason:"controlled-matches",nativeSupportChecked:true),diagnostics:rows)
            return PeripheralPaneAssessment.measure(result,edge:0)
        }
        let uniform=assessment([SIMD2(14,0),SIMD2(14,0),SIMD2(14,0)])
        let varying=assessment([SIMD2(6,0),SIMD2(14,0),SIMD2(22,0)])
        require(uniform.deformation==nil && uniform.darkness(tolerance:1)==1,"Uniform translation became apparent deformation")
        require(varying.darkness(tolerance:1)==1 && (varying.deformation ?? 0)>0.30,
            "A flat majority still hides the 6/14/22-pixel localized deformation")
        let legacy=assessment([SIMD2(6,0),SIMD2(14,0),SIMD2(22,0)]) { rows in
            for i in rows.indices {rows[i].removeValue(forKey:"segmentDisplacementUncertainty")}
        }
        require(legacy.deformation==nil && legacy.darkness(tolerance:1)==1,
            "Missing vector evidence fabricated deformation or disabled continuous local displacement")
        let shear=assessment([SIMD2(-4,0),.zero,SIMD2(4,0)])
        require(shear.localizedError==nil && (shear.error ?? 0)<0.025 && shear.darkness(tolerance:1)>0.1,
            "Reliable relative deformation was ignored below the absolute-shift threshold")
        require(shear.darkness(tolerance:4)<shear.darkness(tolerance:1),"Deformation ignores the user's tolerance")
        for offsets:[SIMD2<Double>] in [
            [SIMD2(2,0),SIMD2(2,0),SIMD2(2,0)],
            [SIMD2(-0.5,0),.zero,SIMD2(0.5,0)],
            [.zero,SIMD2(14,0),.zero],
            [SIMD2(-4,0),SIMD2(4,0)]
        ] {
            let value=assessment(offsets)
            require(value.deformation==nil && value.darkness(tolerance:1)==0,
                "Small motion, quantization, one bad match or insufficient support darkened the pane")
        }
        for kind in ["ambiguous","repeated","incomplete","bad-reverse","duplicate","uncertain","gap"] {
            let value=assessment([SIMD2(-4,0),.zero,SIMD2(4,0)]) { rows in
                switch kind {
                case "ambiguous":rows[5]["segmentStatus"]="ambiguous"
                case "repeated":rows[5]["segmentRepeated"]=true
                case "incomplete":rows[5]["segmentSearchComplete"]=false
                case "bad-reverse":rows[5]["segmentForwardBackward"]=3.0
                case "duplicate":rows[5]["segment"]=4
                case "gap":rows[6]["segmentPoint"]=[160.0,10.0]
                default:for i in rows.indices {rows[i]["segmentDisplacementUncertainty"]=2.7}
                }
            }
            require(value.deformation==nil && value.darkness(tolerance:1)==0,
                "Unreliable \(kind) vectors were promoted to deformation")
        }
        // Actual corresponding camera pixels: three unique patches have known
        // displacements of 6, 14 and 22 pixels along each horizontal seam.
        let w=192,h=256,ow=384,oh=512
        var center=[UInt8](repeating:128,count:w*h*4),outer=[UInt8](repeating:128,count:ow*oh*4)
        for i in stride(from:3,to:center.count,by:4) {center[i]=255}
        for i in stride(from:3,to:outer.count,by:4) {outer[i]=255}
        for y in [10,h-11] {for (j,x) in [72,88,104].enumerated() {
            let patch=texture(width:15,height:15,seed:UInt64(351+y+j*71)),dx=[6,14,22][j]
            for py in 0..<15 {for px in 0..<15 {for c in 0..<3 {
                let value=patch[(py*15+px)*4+c]
                center[((y-7+py)*w+x-7+px)*4+c]=value
                outer[((128+y-7+py)*ow+96+x+dx-7+px)*4+c]=value
            }}}
        }}
        let pair=PeripheralFrameSource.Pair(center:pixelBuffer(rgba:center,width:w,height:h),
            outer:pixelBuffer(rgba:outer,width:ow,height:oh),receipt:30,
            configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:60)
        let measured=PeripheralAlignmentWorker().analyze(pair,seams:.horizontal,
            window:CGRect(x:0,y:-0.25,width:1,height:1.5),now:{30.01},tolerance:1)!
        let measuredPanes=(0...1).map {PeripheralPaneAssessment.measure(measured,edge:$0)}
        require(measuredPanes.allSatisfy {($0.deformation ?? 0)>0.30 && $0.darkness(tolerance:1)>0.99},
            "Real pixel matching did not carry the supported nonuniform displacement into glass shading")

        let clear=PeripheralPaneAssessment(error:0,supportFraction:1,reason:"clear")
        let bent=PeripheralPaneAssessment(reason:"verified-bend",deformation:0.4)
        for spike in [false,true] {
            var policy=PeripheralPreviewPolicy()
            for frame in 0...360 {
                let time=Double(frame)/60
                let bad=spike ? frame==120:(120..<240).contains(frame)
                if frame%5==0 {policy.observe([bad ? bent:clear,clear,clear,clear],at:time)}
                let alpha=policy.update(at:time,ready:true,tolerance:1)
                require(alpha[0]==alpha[1],"Deformation split upper/lower glass shading")
                if spike && frame>=120 {require(alpha[0]<0.01,"One deformation spike flashed black")}
                if !spike && (145...240).contains(frame) {require(alpha[0]>0.99,"Persistent deformation did not darken")}
                if !spike && (240...275).contains(frame) {require(alpha[0]>0.99,"Deformation shade reopened without stable recovery")}
                if frame>=330 {require(alpha[0]<0.01,"Stable recovery never cleared the deformation shade")}
            }
        }
        print("PASS local deformation: nonuniform displacement, uncertainty/direction checks, actual camera pixels, tolerance and asymmetric temporal shading")
    }

    static func adverseResponseChecks() {
        let clear=PeripheralPaneAssessment(error:0,supportFraction:1,reason:"current-clear-seam")
        let bad=PeripheralPaneAssessment(error:0.14,supportFraction:1,reason:"current-bad-seam")
        for name in ["step","spike","alternating","unknown","recovery","sparse-recovery"] {
            var policy=PeripheralPreviewPolicy(),blackAt:Double?,clearAt:Double?,peakAfterSpike=0.0
            for frame in 0...420 {
                let t=Double(frame)/60
                var observation=clear
                if t>=2 {
                    switch name {
                    case "step":observation=bad
                    case "spike":observation=frame<125 ? bad:clear
                    case "alternating":observation=t<3 || (frame/5)%2==0 ? bad:clear
                    case "unknown":observation=t<3 || (frame/5)%2==0 ? bad:.init()
                    case "sparse-recovery":
                        observation=t<4 ? bad:PeripheralPaneAssessment(error:0,supportFraction:0.1,reason:"only-few-matches",observationCoverage:0.2)
                    default:observation=t<4 ? bad:clear
                    }
                }
                if frame%5==0 {policy.observe([observation,observation,clear,clear],at:t,tolerance:1)}
                let alpha=policy.update(at:t,ready:true,tolerance:1)
                require(alpha[0]==alpha[1],"Bad/recovery transitions split horizontal shade")
                if t>=2 && alpha[0]>=0.95 && blackAt==nil {blackAt=t}
                if name=="spike" && t>=2 {peakAfterSpike=max(peakAfterSpike,alpha[0])}
                if ["alternating","unknown","sparse-recovery"].contains(name),t>=3.5 {
                    require(alpha[0]>=0.95,"Intermittent or sparse good evidence reopened a bad seam: \(name)")
                }
                if name=="recovery",t>=4 {
                    if t<=4.6 {require(alpha[0]>=0.95,"Glass reopened before sustained current good evidence")}
                    if alpha[0]<=0.05 && clearAt==nil {clearAt=t}
                }
            }
            if name=="spike" {require(peakAfterSpike<0.01,"A single uncorroborated analysis spike flashed black")}
            else {require(blackAt.map {$0-2<=0.35} == true,"Persistent bad seam did not darken within 350 ms: \(name)")}
            if name=="recovery" {require(clearAt.map {$0-4<1.5} == true,"Stable good evidence failed to recover")}
        }
        var interrupted=PeripheralPreviewPolicy()
        for frame in 0...300 {
            let t=Double(frame)/60
            if frame%5==0 {
                let input:PeripheralPaneAssessment=(2..<3).contains(t) ? .init():clear
                interrupted.observe([input,input,clear,clear],at:t)
            }
            let alpha=interrupted.update(at:t,ready:true,tolerance:1)
            if (3..<3.6).contains(t) {require(alpha[0]>0.95,"First returning observation reopened an overdue seam")}
            if t>=4.5 {require(alpha[0]<0.01,"Continuous current evidence failed to recover after the outage")}
        }
        print("PASS adverse response: 95% black within 350 ms of persistent bad evidence; isolated spike rejected; alternating/unknown/sparse evidence cannot reopen; sustained good evidence recovers within 1.5 s")
        print("PASS overdue analysis: one returning match cannot reopen; continuous current coverage restores the preview")
    }

    static func controlledDisparityChecks() {
        let canvas=texture(width:512,height:640,seed:298341)
        func crop(_ x:Int,_ y:Int,_ w:Int,_ h:Int)->CVPixelBuffer {
            var values=[UInt8]();values.reserveCapacity(w*h*4)
            for row in y..<y+h {values.append(contentsOf:canvas[(row*512+x)*4..<(row*512+x+w)*4])}
            return pixelBuffer(rgba:values,width:w,height:h)
        }
        let center=crop(160,192,192,256)
        for shift in [2,24] {
            let outer=crop(64+shift,64,384,512)
            let pair=PeripheralFrameSource.Pair(center:center,outer:outer,receipt:10,
                configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:UInt64(shift))
            let result=PeripheralAlignmentWorker().analyze(pair,seams:.horizontal,
                window:CGRect(x:0,y:-0.25,width:1,height:1.5),now:{10.01},tolerance:1)!
            let shade=(0...1).map {PeripheralPaneAssessment.measure(result,edge:$0).darkness(tolerance:1)}.max()!
            require(shift==2 ? shade<0.001:shade>0.999,
                "Independent known \(shift)-pixel displacement failed the actual raw-seam shade decision: \(shade)")
        }
        // Only one third of the seam contains the displaced object. Flat
        // background must not dilute it into an all-clear global percentile.
        var localScene=canvas
        for y in 0..<640 {for x in 0..<512 where x<160 || x>=224 {
            for c in 0..<3 {localScene[(y*512+x)*4+c]=128}
        }}
        let localCenter=pixelBuffer(rgba:Self.crop(localScene,sourceWidth:512,x:160,y:192,width:192,height:256),width:192,height:256)
        let localOuter=pixelBuffer(rgba:Self.crop(localScene,sourceWidth:512,x:78,y:64,width:384,height:512),width:384,height:512)
        let localPair=PeripheralFrameSource.Pair(center:localCenter,outer:localOuter,receipt:20,
            configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:50)
        let localResult=PeripheralAlignmentWorker().analyze(localPair,seams:.horizontal,
            window:CGRect(x:0,y:-0.25,width:1,height:1.5),now:{20.01},tolerance:1)!
        let localShade=(0...1).map {PeripheralPaneAssessment.measure(localResult,edge:$0).darkness(tolerance:1)}.max()!
        require(localShade>0.95,"Flat background outvoted the visibly displaced local object: \(localShade)")
        print("PASS controlled raw pixels: 2/192 displacement stays clear; 24/192 displacement becomes opaque without warping either image")
        print("PASS local raw pixels: displaced textured object covering one third of the seam becomes opaque against the flat majority")
    }

    static func pairedPresentationChecks() throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {fatalError("Metal required")}
        let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let context=CIContext(mtlCommandQueue:queue,options:[.cacheIntermediates:false,.workingColorSpace:space])
        let library=try device.makeLibrary(source:PeripheralGlassShader.source,options:nil)
        let d=MTLRenderPipelineDescriptor();d.vertexFunction=library.makeFunction(name:"glassVertex")
        d.fragmentFunction=library.makeFunction(name:"pairedPreviewFragment");d.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline=try device.makeRenderPipelineState(descriptor:d)
        let outputDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:48,height:96,mipmapped:false)
        outputDescriptor.storageMode = .shared;outputDescriptor.usage=[.renderTarget,.shaderRead]
        let output=device.makeTexture(descriptor:outputDescriptor)!,store=PeripheralLiveTextureStore()
        func sample(_ t:MTLTexture,_ x:Int,_ y:Int)->[Float] {
            var result=[Float16](repeating:0,count:4)
            result.withUnsafeMutableBytes {t.getBytes($0.baseAddress!,bytesPerRow:8,from:MTLRegionMake2D(x,y,1,1),mipmapLevel:0)}
            return result.map {Float($0)}
        }
        for i in 0..<8 {
            let v=UInt8(30+i*25)
            let centralPixels:[UInt8]=(0..<(48*64)).flatMap {p -> [UInt8] in
                let green=UInt8(10+2*(p%48)),blue=UInt8(20+3*(p/48))
                return [v,green,blue,255]
            }
            let c=pixelBuffer(rgba:centralPixels,width:48,height:64)
            let o=pixelBuffer(rgba:(0..<48*64).flatMap {_ in [20,v,30,255]},width:48,height:64)
            let pair=PeripheralFrameSource.Pair(center:c,outer:o,receipt:Double(i),configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:UInt64(i+1))
            let frame=PeripheralLiveFrame(pair:pair,matrix:simd_float3x3(SIMD3(0.5,0,0),SIMD3(0,0.5,0),SIMD3(0.25,0.25,1)),
                gains:.init(),refinement:nil,refinementStrength:0,analysisPairID:0,analysisObservedAt:nil,modelPair:nil,
                mappingBasis:"test-fixed-FOV",seams:.horizontal,tolerance:1,margin:8)
            let command=queue.makeCommandBuffer()!
            let upload=try store.prepare(frame,revision:1,at:Double(i),device:device,context:context,command:command,
                colorSpace:space,includeCenter:true)!
            require(store.completed?.frame.pair.serial != pair.serial,"Test failed to exercise an uncompleted current upload")
            let bundle=upload.0
            var u=PeripheralGlassUniforms(photo:SIMD4(0,Float(1.0/6),1,Float(2.0/3)),viewport:SIMD2(48,96),
                blackOpacity: i%2==0 ? 0:1,photoToOuter:frame.matrix,gain:SIMD4(repeating:1))
            u.centerEnabled=1
            let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output
            pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
            let encoder=command.makeRenderCommandEncoder(descriptor:pass)!
            encoder.setRenderPipelineState(pipeline);encoder.setFragmentTexture(bundle.texture,index:0)
            encoder.setFragmentTexture(bundle.centerTexture!,index:1)
            encoder.setFragmentBytes(&u,length:MemoryLayout<PeripheralGlassUniforms>.stride,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);encoder.endEncoding()
            command.commit();command.waitUntilCompleted();withExtendedLifetime(upload.1) {}
            require(command.status == .completed,"Paired GPU render failed")
            let center=sample(output,24,48),expectedCenter=sample(bundle.centerTexture!,24,32)
            require(zip(center,expectedCenter).allSatisfy {abs($0-$1)<0.002},"Current center frame was delayed or darkened by the periphery")
            require(sample(output,42,48)[1]>sample(output,4,48)[1]+0.03 &&
                sample(output,24,74)[2]>sample(output,24,20)[2]+0.1,
                "Paired center preview flipped a camera axis or sampled the wrong photo rectangle")
            let outer=sample(output,24,4),expectedOuter=sample(bundle.texture,24,20)
            if i%2==0 {require(zip(outer,expectedOuter).allSatisfy {abs($0-$1)<0.002},"Current peripheral frame did not share the center's command")}
            else {require(outer[0]==0 && outer[1]==0 && outer[2]==0,"Black peripheral decision failed")}
            require(store.complete(bundle,success:true,revision:1,epoch:1,at:Double(i)+0.001),"Paired resource completion failed")
        }
        print("PASS paired presentation: 8 changing center/outer frame pairs uploaded and sampled in the same GPU command; no previous-frame read; peripheral black never changes center")
    }

    static func livePreviewChecks() throws {
        // Independent behavior requirements: uncertain images remain live,
        // isolated defects do not black a pane, sustained large errors shade.
        let missing=PeripheralPaneAssessment(error:nil,mismatchFraction:0.5,supportFraction:0,missingStructureFraction:0.5,reason:"occluded-boundary")
        require(missing.darkness(tolerance:4)==1,"Maximum tolerance erased a visible structure absent in the other camera")
        var hold=PeripheralPreviewPolicy()
        for i in 0...60 {
            let t=Double(i)/60;hold.observe([missing,missing,.init(),.init()],at:t)
            require(hold.update(at:t,ready:true,tolerance:4)[0]==1,"A known-invalid first scene briefly opened during startup")
        }
        require(hold.update(at:2,ready:true,tolerance:4)[0]==1,"A missing new analysis automatically made a known-bad seam transparent")
        let compatible=PeripheralPaneAssessment(reason:"checked-flat-agreement")
        var policy = PeripheralPreviewPolicy()
        require(policy.update(at:-0.01,ready:true,tolerance:4).allSatisfy {$0==1},"Unchecked startup was assumed transparent")
        for i in 0...60 {
            let t=Double(i)/60
            policy.observe([compatible,compatible,compatible,compatible],at:t)
            let alpha=policy.update(at:t,ready:true,tolerance:1)
            if i>=40 {require(alpha.allSatisfy {$0<0.001},"Checked startup did not finish its bounded opening transition")}
        }
        let moderate=PeripheralPaneAssessment(error:0.03,mismatchFraction:0,supportFraction:1,reason:"known-displacement")
        require(moderate.darkness(tolerance:1)>0.01 && moderate.darkness(tolerance:4)==0,
            "Tolerance does not actually expand the accepted displacement")
        let large=PeripheralPaneAssessment(error:0.3,mismatchFraction:0.8,supportFraction:1,reason:"known-large-displacement")
        for i in 61...72 {
            let t=Double(i)/60
            if i%5==0 {policy.observe([large,compatible,compatible,compatible],at:t)}
            let alpha=policy.update(at:t,ready:true,tolerance:1)
            require(alpha[0]==alpha[1],"Horizontal shading split during quick worsening")
        }
        for i in 73...126 {
            let t=Double(i)/60;policy.observe([large,compatible,compatible,compatible],at:t)
            let alpha=policy.update(at:t,ready:true,tolerance:1)
            require(alpha[0]==alpha[1],"Top and bottom diverged while darkening")
            if i==126 {require(alpha[0]>0.99 && alpha[2]==0 && alpha[3]==0,"Top distortion did not shade both horizontal panes or affected the side panes")}
        }
        for i in 127...240 {
            let t=Double(i)/60;policy.observe([compatible,compatible,compatible,compatible],at:t)
            let alpha=policy.update(at:t,ready:true,tolerance:1)
            require(alpha[0]==alpha[1],"Top and bottom diverged while recovering")
            if i==240 {require(alpha.allSatisfy {$0<0.001},"Checked recovery latched old shading permanently")}
        }
        require(policy.update(at:5,ready:false,tolerance:4).allSatisfy {$0==1},"Missing pixels were revealed by tolerance")

        var linked=PeripheralPreviewPolicy()
        let halfShade=PeripheralPaneAssessment(error:0.045,supportFraction:1,reason:"moderate-visible-shift")
        for i in 0...120 {
            let t=Double(i)/60
            // Swap which horizontal pane is worse; neither averaging nor a
            // darker side pane may change their common half-opacity.
            linked.observe(i<60 ? [moderate,halfShade,compatible,large]:[halfShade,moderate,compatible,large],at:t)
            let opacity=linked.update(at:t,ready:true,tolerance:1)
            require(opacity[0]==opacity[1],"Horizontal panes did not share the darker shade")
            if i>=40 {
                require(abs(opacity[0]-0.5)<0.000001 && opacity[2]==0 && opacity[3]==1,
                    "Shared shading averaged the horizontal errors or included a side pane")
                require(abs(linked.targets[0]-0.5)<0.000001 && linked.targets[0]==linked.targets[1],
                    "Recorded shading targets disagree with the common horizontal target")
            }
        }

        var stable=PeripheralPreviewPolicy(),minimum=1.0,maximum=0.0
        for i in 0..<240 {
            let t=Double(i)/60
            let noise=i<60 ? 0:((i/5)%2==0 ? 0.004:-0.004)
            let reading=PeripheralPaneAssessment(error:0.045+noise,supportFraction:1,reason:"quantized-correspondence")
            if i%5==0 {stable.observe([reading,reading,compatible,compatible],at:t)}
            let alpha=stable.update(at:t,ready:true,tolerance:1)
            if i>=60 {minimum=min(minimum,alpha[0]);maximum=max(maximum,alpha[0])}
        }
        require(maximum-minimum<0.001,"Subpixel measurement quantization still oscillates the glass")
        // A completely unobservable result must not manufacture a new zero
        // disparity reading and reopen a known bad seam.
        var unknownResult=PeripheralAlignmentResult(epoch:1,receipt:0,photoAspectRatio:0.75,
            photoToOuter:matrix_identity_float3x3,residual:.nan,gain:SIMD3(repeating:1),seams:.horizontal,expiresAt:1)
        unknownResult.nativeSeam=PeripheralNativeSeam(strips:[],gains:.init(),evidence:.init(compatible:false,coverage:0,
            maximumObservableError:nil,reason:"ambiguous",nativeSupportChecked:true),diagnostics:[
                ["edge":0,"flatBothNative":false,"nativeEdgeSupport":[0,0],"nativeWeakEdgeSupport":[0,0],
                 "nativePeriodicProfile":true,"segmentSearchComplete":false]])
        require(PeripheralPaneAssessment.measure(unknownResult,edge:0).reason=="unobserved",
            "An ambiguous correspondence was converted into zero visible error")

        let w=192,h=256
        var flat=[UInt8](repeating:128,count:w*20*4),line:[UInt8]
        for i in stride(from:3,to:flat.count,by:4) {flat[i]=255};line=flat
        for y in 0..<20 {for c in 0..<3 {line[(y*w+70)*4+c]=0}}
        let native=PeripheralNativeSeam.evaluate([.init(edge:0,width:w,height:20,reference:line,outer:flat,nativeScale:1)],
            gains:.init(),segments:[],analysisWidth:w,analysisHeight:h,geometryVerified:false,severe:nil)
        var local=PeripheralAlignmentResult(epoch:1,receipt:0,photoAspectRatio:0.75,photoToOuter:matrix_identity_float3x3,
            residual:.nan,gain:SIMD3(repeating:1),seams:.horizontal,expiresAt:0.2)
        local.nativeSeam=native
        require(!native.evidence.compatible && PeripheralPaneAssessment.measure(local,edge:0).darkness(tolerance:1)==0,
            "One local missing line blackened the entire visible pane")

        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {fatalError("Metal required")}
        let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let context=CIContext(mtlDevice:device,options:[.cacheIntermediates:false,.workingColorSpace:space])
        let pipeline=PeripheralLivePipeline(),store=PeripheralLiveTextureStore()
        let pixels=(0..<3).map { index in pixelBuffer(rgba:(0..<w*h).flatMap { _ -> [UInt8] in
            index==0 ? [200,40,20,255] : index==1 ? [20,190,30,255] : [30,40,210,255]
        },width:w,height:h) }
        let window=CGRect(x:0,y:-0.3,width:1,height:1.6)
        var lastPair:PeripheralFrameSource.Pair!,firstColor:Float16=0,lastColor:Float16=0
        var capturedFrame:PeripheralLiveFrame?
        for i in 0...120 {
            let t=10+Double(i)/60
            let pair=PeripheralFrameSource.Pair(center:pixels[0],outer:pixels[i<60 ? 0:2],receipt:t-0.025,
                configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:UInt64(i+1))
            lastPair=pair
            // First 30 frames have no observation; then supply a checked flat
            // boundary. Pixel uploads never wait, while unchecked output masks.
            let tolerance=i<60 ? 1.0:4.0
            var checked=PeripheralAlignmentResult(epoch:1,receipt:pair.observedAt,photoAspectRatio:0.75,
                photoToOuter:matrix_identity_float3x3,residual:.nan,gain:SIMD3(repeating:1),seams:.horizontal,expiresAt:pair.observedAt+0.2)
            checked.inputPair=pair;checked.pairID=pair.serial;checked.directStitch=true
            checked.nativeSeam=PeripheralNativeSeam.evaluate([
                .init(edge:0,width:w,height:20,reference:flat,outer:flat,nativeScale:1),
                .init(edge:1,width:w,height:20,reference:flat,outer:flat,nativeScale:1)],gains:.init(),segments:[],analysisWidth:w,analysisHeight:h,geometryVerified:false,severe:nil)
            guard let frame=pipeline.update(pair:pair,analysis:i<30 ? nil:checked,enabled:true,epoch:1,seams:.horizontal,
                window:window,tolerance:tolerance,at:t) else {fatalError("Startup requires a finished Vision result")}
            capturedFrame=frame
            let command=queue.makeCommandBuffer()!
            guard let upload=try store.prepare(frame,revision:1,at:t,device:device,context:context,command:command,colorSpace:space) else {fatalError("Fresh camera frame was not uploaded")}
            // Exactly as in draw: sample the previous completed GPU resource.
            let alpha=pipeline.opacities(bundle:store.completed,revision:1,at:t,tolerance:tolerance)
            if i<30 {require(alpha[0]==1 && alpha[1]==1,"An unchecked first frame was made transparent")}
            if i>=75 {require(alpha[0]<0.001 && alpha[1]<0.001,"Checked live preview went black during tolerance change")}
            command.commit();command.waitUntilCompleted();withExtendedLifetime(upload.1) {}
            require(store.complete(upload.0,success:command.status == .completed,revision:1,epoch:1,at:t+0.005),"Live upload completion lost its identity")
            require(store.completed?.frame.pair === pair && store.completed?.frame.analysisPairID==(i<30 ? 0:pair.serial),"Current pixels were relabeled as old matched pixels")
            if i==10 || i==120 {
                var color=[Float16](repeating:0,count:4)
                color.withUnsafeMutableBytes {store.completed!.texture.getBytes($0.baseAddress!,bytesPerRow:8,
                    from:MTLRegionMake2D(w/2,h/2,1,1),mipmapLevel:0)}
                if i==10 {firstColor=color[0]} else {lastColor=color[0]}
            }
        }
        require(firstColor>lastColor+0.2,"Displayed live image froze while its boundary was being checked")
        _=pipeline.update(pair:lastPair,analysis:nil,enabled:true,epoch:1,seams:.horizontal,window:window,tolerance:4,at:12.3)
        require(pipeline.opacities(bundle:store.completed,revision:1,at:12.3,tolerance:4)[0]==1,"A stopped source kept stale pixels visible")
        _=pipeline.update(pair:nil,analysis:nil,enabled:true,epoch:2,seams:.horizontal,window:window,tolerance:4,at:12.4)
        require(!pipeline.resourceValid(store.completed,revision:1,at:12.4),"A source epoch change reused an old texture")
        let pendingStore=PeripheralLiveTextureStore(),lateCommand=queue.makeCommandBuffer()!
        let late=try pendingStore.prepare(capturedFrame!,revision:1,at:12,device:device,context:context,command:lateCommand,colorSpace:space)!
        pendingStore.reset();lateCommand.commit();lateCommand.waitUntilCompleted();withExtendedLifetime(late.1) {}
        require(!pendingStore.complete(late.0,success:true,revision:1,epoch:1,at:12.01) && pendingStore.completed==nil,
            "A late GPU callback resurrected a reset live source")
        // The latest good mapping may be older than a pixel lease. Use it on
        // NEW pixels without changing the original evidence's identity/time.
        let live=PeripheralLivePipeline()
        var model=local;model.inputPair=lastPair;model.pairID=lastPair.serial
        model = PeripheralAlignmentResult(epoch:1,receipt:12,photoAspectRatio:0.75,
            photoToOuter:PeripheralAlignmentWorker.samplingTransform(homography:matrix_identity_float3x3,width:w,height:h,ratio:2),
            residual:.nan,gain:SIMD3(repeating:1),seams:.horizontal,expiresAt:12.2)
        model.inputPair=lastPair;model.pairID=lastPair.serial;model.directStitch=true
        let newer=PeripheralFrameSource.Pair(center:pixels[0],outer:pixels[2],receipt:12.28,
            configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:999)
        let remapped=live.update(pair:newer,analysis:model,enabled:true,epoch:1,seams:.horizontal,window:window,tolerance:1,at:12.3)!
        require(remapped.pair === newer && remapped.analysisPairID==model.pairID && remapped.analysisObservedAt==12 && model.expiresAt==12.2,
            "Retaining a mapping falsified its old certificate or used old pixels")
        var alteredMatrix=model.photoToOuter;alteredMatrix[2].x += 0.04
        var unwanted=PeripheralAlignmentResult(epoch:1,receipt:12.31,photoAspectRatio:0.75,photoToOuter:alteredMatrix,
            residual:0,gain:SIMD3(repeating:1.5),seams:.horizontal,expiresAt:12.51)
        unwanted.pairID=1000;unwanted.directStitch=true
        unwanted.refinement=PeripheralDenseRefinement(id:100,epoch:1,sourcePairID:999,homography:matrix_identity_float3x3,
            width:2,height:2,rgba:[Float](repeating:2,count:16),consistentFraction:1,elapsedMS:0,maximumOffset:0.02)
        unwanted.inputPair=PeripheralFrameSource.Pair(center:pixels[0],outer:pixels[2],receipt:12.31,
            configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:1000)
        let unwarped=live.update(pair:newer,analysis:unwanted,enabled:true,epoch:1,seams:.horizontal,window:window,tolerance:1,at:12.32)!
        let originalMatrix=PeripheralAlignmentWorker.samplingTransform(homography:matrix_identity_float3x3,width:w,height:h,ratio:2)
        require(unwarped.matrix==originalMatrix && unwarped.refinement==nil && unwarped.gains.top==SIMD3<Float>(repeating:1),
            "A legacy fitted geometry or photometry changed the direct preview")
        let directBytes=PeripheralAlignmentWorker().bitmap(unwarped.image()!,bounds:CGRect(x:0,y:0,width:w,height:h),width:w,height:h)
        require(directBytes==PeripheralAlignmentWorker().bitmap(CIImage(cvPixelBuffer:newer.outer),bounds:CGRect(x:0,y:0,width:w,height:h),width:w,height:h),
            "Direct preview changed camera pixels before fixed crop sampling")
        let invalid=PeripheralFrameSource.Pair(center:pixels[0],outer:pixels[2],receipt:13,
            configuration:.init(outputIndex:1,fieldOfViewRatio:1.05,epoch:3),serial:1)
        require(live.update(pair:invalid,analysis:nil,enabled:true,epoch:3,seams:.horizontal,window:window,tolerance:4,at:13)==nil,
            "Tolerance sampled outside the camera's real field of view")
        let fitted=PeripheralLivePipeline()
        _=fitted.update(pair:newer,analysis:model,enabled:true,epoch:1,seams:.horizontal,window:window,tolerance:1,at:12.3)
        let hugeWindow=CGRect(x:-1,y:-1,width:3,height:3)
        require(fitted.update(pair:newer,analysis:model,enabled:true,epoch:1,seams:.horizontal,window:hugeWindow,tolerance:1,at:12.31)==nil &&
            !fitted.resourceValid(store.completed,revision:1,at:12.31),"Resizing reused a texture that no longer covered the viewport")
        // Exercise the user's actual irregular render-clock sequence. Camera
        // delivery was available throughout; current pixels now upload without
        // the old measured-frame expiry/readiness stalls from that trace.
        let fixtureURL=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("fixtures/phone-glass-timing-20261023.json")
        let timing=try JSONSerialization.jsonObject(with:Data(contentsOf:fixtureURL)) as! [String:Any]
        let history=timing["rows"] as! [[String:Any]]
        let timed=PeripheralLivePipeline(),timedStore=PeripheralLiveTextureStore()
        var warmed=0
        for (index,row) in history.enumerated() {
            let time=20+(row["time"] as! Double)
            let current=PeripheralFrameSource.Pair(center:pixels[0],outer:pixels[index%3],receipt:time-0.044,
                configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:2),serial:UInt64(index+1))
            var observation=PeripheralAlignmentResult(epoch:2,receipt:current.observedAt,photoAspectRatio:0.75,
                photoToOuter:matrix_identity_float3x3,residual:.nan,gain:SIMD3(repeating:1),seams:.horizontal,expiresAt:current.observedAt+0.2)
            observation.inputPair=current;observation.pairID=current.serial;observation.directStitch=true
            observation.nativeSeam=PeripheralNativeSeam.evaluate([
                .init(edge:0,width:w,height:20,reference:flat,outer:flat,nativeScale:1),
                .init(edge:1,width:w,height:20,reference:flat,outer:flat,nativeScale:1)],gains:.init(),segments:[],analysisWidth:w,analysisHeight:h,geometryVerified:false,severe:nil)
            let frame=timed.update(pair:current,analysis:observation,enabled:row["sourceAvailable"] as! Bool,
                epoch:2,seams:.horizontal,window:window,tolerance:4,at:time)!
            let command=queue.makeCommandBuffer()!
            let upload=try timedStore.prepare(frame,revision:2,at:time,device:device,context:context,command:command,colorSpace:space)!
            let alpha=timed.opacities(bundle:timedStore.completed,revision:2,at:time,tolerance:4)
            if time>=21 {warmed += 1;require(alpha[0]==0 && alpha[1]==0,"Recorded phone scheduling still caused a black flash in the live path")}
            command.commit();command.waitUntilCompleted();withExtendedLifetime(upload.1) {}
            require(timedStore.complete(upload.0,success:command.status == .completed,revision:2,epoch:2,at:time+0.005),"Timed current-frame upload failed")
        }
        require(warmed>100,"Phone schedule fixture did not exercise enough warmed frames")
        for (file,near) in [("direct-stitch-near-computer-20261025.json",true),("direct-stitch-distant-scene-20261025.json",false)] {
            let url=fixtureURL.deletingLastPathComponent().appendingPathComponent(file)
            let document=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
            var result=PeripheralAlignmentResult(epoch:1,receipt:0,photoAspectRatio:document["aspect"] as! Double,
                photoToOuter:matrix_identity_float3x3,residual:.nan,gain:SIMD3(repeating:1),seams:.horizontal,expiresAt:0.2)
            result.nativeSeam=PeripheralNativeSeam(strips:[],gains:.init(),evidence:.init(compatible:false,coverage:0,
                maximumObservableError:nil,reason:"actual-direct-pixel-observations",nativeSupportChecked:true),diagnostics:document["tiles"] as! [[String:Any]])
            let decisions=(0...1).map {PeripheralPaneAssessment.measure(result,edge:$0).darkness(tolerance:near ? 4:1)}
            require(near ? decisions.max()!>0.999:decisions.allSatisfy {$0<0.001},
                "Actual near/far counterexample failed with shared maximum: \(file)")
        }
        print("PASS recorded phone draw clock with synthetic current camera pixels: \(warmed) warmed checked frames fully clear, pixel uploads independent of matching")
        print("PASS live preview: actual GPU current-pixel refresh without analysis, tolerance changes, source loss/epoch/late completion, retained model identity, broad vs local mismatch and distortion allowance")
    }
}
