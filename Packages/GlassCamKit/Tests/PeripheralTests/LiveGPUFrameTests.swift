import Testing
import Foundation
import CoreImage
import Metal
import simd
@testable import Peripheral
import GlassCamTestSupport

private struct LiveGPUObservation {
    var startup: [[Double]], warmedAlpha: [[Double]], timedAlpha: [[Double]]
    var admissions: [Bool], timedAdmissions: [Bool]
    var actualPairs: [ObjectIdentifier?], expectedPairs: [ObjectIdentifier]
    var actualAnalysis: [UInt64?], expectedAnalysis: [UInt64]
    let firstColor: Float16, lastColor: Float16
    let stoppedOpacity: Double, epochResourceValid: Bool, lateAccepted: Bool, lateHasCompleted: Bool
    let remappedPair: ObjectIdentifier, newerPair: ObjectIdentifier
    let remappedAnalysis: UInt64, modelAnalysis: UInt64, remappedTime: Double?, modelExpiry: Double
    let unwarpedMatrix: simd_float3x3, originalMatrix: simd_float3x3, hasRefinement: Bool, topGain: SIMD3<Float>
    let directBytes: [UInt8], originalBytes: [UInt8]
    let hasInvalidResult: Bool, hasResizedResult: Bool, resizedResourceValid: Bool, warmed: Int
    static let value = Task { try await measure() }
    static func measure() async throws -> Self {
        var startup: [[Double]] = [], warmedAlpha: [[Double]] = [], timedAlpha: [[Double]] = []
        var admissions: [Bool] = [], timedAdmissions: [Bool] = []
        var actualPairs: [ObjectIdentifier?] = [], expectedPairs: [ObjectIdentifier] = []
        var actualAnalysis: [UInt64?] = [], expectedAnalysis: [UInt64] = []
        let w = 192, h = 256, flat = NativeSeamTests.flat
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw CocoaError(.featureUnsupported) }
        let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let context=CIContext(mtlDevice:device,options:[.cacheIntermediates:false,.workingColorSpace:space])
        let pipeline=PeripheralLivePipeline(),store=PeripheralLiveTextureStore()
        let pixels=try (0..<3).map { index in try PeripheralFixtures.pixelBuffer(rgba:(0..<w*h).flatMap { _ -> [UInt8] in
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
                window:window,tolerance:tolerance,at:t) else { throw CocoaError(.coderInvalidValue) }
            capturedFrame=frame
            let command=queue.makeCommandBuffer()!
            guard let upload=try store.prepare(frame,revision:1,at:t,device:device,context:context,command:command,colorSpace:space) else { throw CocoaError(.coderInvalidValue) }
            // Exactly as in draw: sample the previous completed GPU resource.
            let alpha=pipeline.opacities(bundle:store.completed,revision:1,at:t,tolerance:tolerance)
            if i<30 { startup.append(alpha) }
            if i>=75 { warmedAlpha.append(alpha) }
            await withCheckedContinuation { continuation in command.addCompletedHandler { _ in continuation.resume() }; command.commit() };withExtendedLifetime(upload.1) {}
            admissions.append(store.complete(upload.0,success:command.status == .completed,revision:1,epoch:1,at:t+0.005))
            actualPairs.append(store.completed.map { ObjectIdentifier($0.frame.pair) }); expectedPairs.append(ObjectIdentifier(pair))
            actualAnalysis.append(store.completed?.frame.analysisPairID); expectedAnalysis.append(i<30 ? 0:pair.serial)
            if i==10 || i==120 {
                var color=[Float16](repeating:0,count:4)
                color.withUnsafeMutableBytes {store.completed!.texture.getBytes($0.baseAddress!,bytesPerRow:8,
                    from:MTLRegionMake2D(w/2,h/2,1,1),mipmapLevel:0)}
                if i==10 {firstColor=color[0]} else {lastColor=color[0]}
            }
        }

        _=pipeline.update(pair:lastPair,analysis:nil,enabled:true,epoch:1,seams:.horizontal,window:window,tolerance:4,at:12.3)
        let stoppedOpacity = pipeline.opacities(bundle:store.completed,revision:1,at:12.3,tolerance:4)[0]
        _=pipeline.update(pair:nil,analysis:nil,enabled:true,epoch:2,seams:.horizontal,window:window,tolerance:4,at:12.4)
        let epochResourceValid = pipeline.resourceValid(store.completed,revision:1,at:12.4)
        let pendingStore=PeripheralLiveTextureStore(),lateCommand=queue.makeCommandBuffer()!
        let late=try pendingStore.prepare(capturedFrame!,revision:1,at:12,device:device,context:context,command:lateCommand,colorSpace:space)!
        pendingStore.reset();await withCheckedContinuation { continuation in lateCommand.addCompletedHandler { _ in continuation.resume() }; lateCommand.commit() };withExtendedLifetime(late.1) {}
        let lateAccepted = pendingStore.complete(late.0,success:true,revision:1,epoch:1,at:12.01)
        let lateHasCompleted = pendingStore.completed != nil
        // The latest good mapping may be older than a pixel lease. Use it on
        // NEW pixels without changing the original evidence's identity/time.
        let live=PeripheralLivePipeline()
        var model = PeripheralAlignmentResult(epoch:1,receipt:12,photoAspectRatio:0.75,
            photoToOuter:PeripheralAlignmentWorker.samplingTransform(homography:matrix_identity_float3x3,width:w,height:h,ratio:2),
            residual:.nan,gain:SIMD3(repeating:1),seams:.horizontal,expiresAt:12.2)
        model.inputPair=lastPair;model.pairID=lastPair.serial;model.directStitch=true
        let newer=PeripheralFrameSource.Pair(center:pixels[0],outer:pixels[2],receipt:12.28,
            configuration:.init(outputIndex:1,fieldOfViewRatio:2,epoch:1),serial:999)
        let remapped=live.update(pair:newer,analysis:model,enabled:true,epoch:1,seams:.horizontal,window:window,tolerance:1,at:12.3)!
        let remappedPair = ObjectIdentifier(remapped.pair), newerPair = ObjectIdentifier(newer)
        let remappedAnalysis = remapped.analysisPairID, modelAnalysis = model.pairID
        let remappedTime = remapped.analysisObservedAt, modelExpiry = model.expiresAt
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
        let unwarpedMatrix = unwarped.matrix, hasRefinement = unwarped.refinement != nil, topGain = unwarped.gains.top
        let directBytes=PeripheralAlignmentWorker().bitmap(unwarped.image()!,bounds:CGRect(x:0,y:0,width:w,height:h),width:w,height:h)
        let originalBytes = PeripheralAlignmentWorker().bitmap(CIImage(cvPixelBuffer:newer.outer),bounds:CGRect(x:0,y:0,width:w,height:h),width:w,height:h)
        let invalid=PeripheralFrameSource.Pair(center:pixels[0],outer:pixels[2],receipt:13,
            configuration:.init(outputIndex:1,fieldOfViewRatio:1.05,epoch:3),serial:1)
        let invalidResult = live.update(pair:invalid,analysis:nil,enabled:true,epoch:3,seams:.horizontal,window:window,tolerance:4,at:13)
        let fitted=PeripheralLivePipeline()
        _=fitted.update(pair:newer,analysis:model,enabled:true,epoch:1,seams:.horizontal,window:window,tolerance:1,at:12.3)
        let hugeWindow=CGRect(x:-1,y:-1,width:3,height:3)
        let resizedResult = fitted.update(pair:newer,analysis:model,enabled:true,epoch:1,seams:.horizontal,window:hugeWindow,tolerance:1,at:12.31)
        let resizedResourceValid = fitted.resourceValid(store.completed,revision:1,at:12.31)
        // Exercise the user's actual irregular render-clock sequence. Camera
        // delivery was available throughout; current pixels now upload without
        // the old measured-frame expiry/readiness stalls from that trace.
        let fixtureURL=TestResources.fixtures.appendingPathComponent("peripheral/phone-glass-timing-20261023.json")
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
            if time>=21 {warmed += 1;timedAlpha.append(alpha)}
            await withCheckedContinuation { continuation in command.addCompletedHandler { _ in continuation.resume() }; command.commit() };withExtendedLifetime(upload.1) {}
            timedAdmissions.append(timedStore.complete(upload.0,success:command.status == .completed,revision:2,epoch:2,at:time+0.005))
        }

        return .init(startup: startup, warmedAlpha: warmedAlpha, timedAlpha: timedAlpha, admissions: admissions,
            timedAdmissions: timedAdmissions, actualPairs: actualPairs, expectedPairs: expectedPairs,
            actualAnalysis: actualAnalysis, expectedAnalysis: expectedAnalysis, firstColor: firstColor, lastColor: lastColor,
            stoppedOpacity: stoppedOpacity, epochResourceValid: epochResourceValid, lateAccepted: lateAccepted,
            lateHasCompleted: lateHasCompleted, remappedPair: remappedPair, newerPair: newerPair,
            remappedAnalysis: remappedAnalysis, modelAnalysis: modelAnalysis, remappedTime: remappedTime, modelExpiry: modelExpiry,
            unwarpedMatrix: unwarpedMatrix, originalMatrix: originalMatrix, hasRefinement: hasRefinement, topGain: topGain,
            directBytes: directBytes, originalBytes: originalBytes, hasInvalidResult: invalidResult != nil,
            hasResizedResult: resizedResult != nil, resizedResourceValid: resizedResourceValid, warmed: warmed)
    }
}
@Suite(.serialized)
struct LiveGPUFrameTests {
    @Test func uncheckedStartup_masksBothHorizontalPanes() async throws {
        let value = try await LiveGPUObservation.value.value
        #expect(Set(value.startup.flatMap { Array($0.prefix(2)) }) == [1])
    }
    @Test func checkedFrames_remainClearAcrossToleranceChange() async throws {
        let value = try await LiveGPUObservation.value.value
        #expect(try #require(value.warmedAlpha.flatMap { Array($0.prefix(2)) }.max()) < 0.001)
    }
    @Test func completedUpload_keepsActualPixelAndAnalysisIdentities() async throws {
        let value = try await LiveGPUObservation.value.value
        #expect(Set(value.admissions) == [true])
        #expect(value.actualPairs == value.expectedPairs.map(Optional.some))
        #expect(value.actualAnalysis == value.expectedAnalysis.map(Optional.some))
    }
    @Test func currentPixels_continueRefreshingWithoutAnalysis() async throws {
        let value = try await LiveGPUObservation.value.value
        #expect(value.firstColor > value.lastColor + 0.2)
    }
    @Test func sourceStopAndEpochChange_hideStaleResources() async throws {
        let value = try await LiveGPUObservation.value.value
        #expect(value.stoppedOpacity == 1)
        #expect(!value.epochResourceValid)
    }
    @Test func lateGPUCompletion_cannotResurrectResetSource() async throws {
        let value = try await LiveGPUObservation.value.value
        #expect(!value.lateAccepted)
        #expect(!value.lateHasCompleted)
    }
    @Test func retainedMapping_keepsOriginalEvidenceTimeAndNewPixels() async throws {
        let value = try await LiveGPUObservation.value.value
        #expect(value.remappedPair == value.newerPair)
        #expect(value.remappedAnalysis == value.modelAnalysis)
        #expect(value.remappedTime == 12)
        #expect(value.modelExpiry == 12.2)
    }
    @Test func directPreview_ignoresLegacyFittedGeometryAndPhotometry() async throws {
        let value = try await LiveGPUObservation.value.value
        #expect(value.unwarpedMatrix == value.originalMatrix)
        #expect(!value.hasRefinement)
        #expect(value.topGain == SIMD3<Float>(repeating: 1))
        #expect(value.directBytes == value.originalBytes)
    }
    @Test func insufficientFieldOfViewAndResize_cannotReuseTexture() async throws {
        let value = try await LiveGPUObservation.value.value
        #expect(!value.hasInvalidResult)
        #expect(!value.hasResizedResult)
        #expect(!value.resizedResourceValid)
    }
    @Test func recordedIrregularDrawClock_keepsCheckedCurrentFramesClear() async throws {
        let value = try await LiveGPUObservation.value.value
        #expect(value.warmed > 100)
        #expect(Set(value.timedAlpha.flatMap { Array($0.prefix(2)) }) == [0])
        #expect(Set(value.timedAdmissions) == [true])
    }
    @Test(arguments: [("direct-stitch-near-computer-20261025.json", true), ("direct-stitch-distant-scene-20261025.json", false)])
    func recordedNearAndFarScenes_preserveShadeDecision(input: (String, Bool)) throws {
        let url = TestResources.fixtures.appendingPathComponent("peripheral").appendingPathComponent(input.0)
        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let aspect = try #require(document["aspect"] as? Double), tiles = try #require(document["tiles"] as? [[String: Any]])
        var result = PeripheralAlignmentResult(epoch: 1, receipt: 0, photoAspectRatio: aspect,
            photoToOuter: matrix_identity_float3x3, residual: .nan, gain: SIMD3(repeating: 1), seams: .horizontal, expiresAt: 0.2)
        result.nativeSeam = PeripheralNativeSeam(strips: [], gains: .init(), evidence: .init(compatible: false, coverage: 0,
            maximumObservableError: nil, reason: "actual-direct-pixel-observations", nativeSupportChecked: true), diagnostics: tiles)
        let maximum = try #require((0...1).map { PeripheralPaneAssessment.measure(result, edge: $0).darkness(tolerance: input.1 ? 4 : 1) }.max())
        if input.1 { #expect(maximum > 0.999) } else { #expect(maximum < 0.001) }
    }
}
