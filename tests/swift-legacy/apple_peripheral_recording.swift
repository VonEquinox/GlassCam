import Foundation
import AVFoundation
import QuartzCore
import simd

@main
struct RecordingTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func buffer(_ format: OSType, seed: Int) -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        require(CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, "create original pixel buffer")
        let result = pixel!
        require(CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess, "lock fixture")
        let planar = CVPixelBufferIsPlanar(result)
        for plane in 0..<(planar ? CVPixelBufferGetPlaneCount(result) : 1) {
            let base = planar ? CVPixelBufferGetBaseAddressOfPlane(result,plane)! : CVPixelBufferGetBaseAddress(result)!
            let bytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(result,plane)*CVPixelBufferGetHeightOfPlane(result,plane)
                               : CVPixelBufferGetBytesPerRow(result)*CVPixelBufferGetHeight(result)
            for i in 0..<bytes { base.assumingMemoryBound(to: UInt8.self)[i] = UInt8((i*17+seed+plane*31)%256) }
        }
        CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }
    static func sample(_ pixel: CVPixelBuffer) -> CMSampleBuffer {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,formatDescriptionOut:&description)
        var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:30),
            presentationTimeStamp:CMTime(value:1234567,timescale:600),decodeTimeStamp:.invalid)
        var sample: CMSampleBuffer?
        require(CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,
            formatDescription:description!,sampleTiming:&timing,sampleBufferOut:&sample) == noErr,"original timing fixture")
        var k = simd_float3x3(SIMD3(777,0,0),SIMD3(0,778,0),SIMD3(4,3,1))
        let data = withUnsafeBytes(of: &k) { Data($0) }
        CMSetAttachment(sample!,key:kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,value:data as CFData,attachmentMode:kCMAttachmentMode_ShouldPropagate)
        return sample!
    }
    static func metadata(_ pixel: CVPixelBuffer, id: UInt64) -> PeripheralFrameMetadata {
        PeripheralFrameMetadata(sample(pixel), id: id, clock: nil)
    }
    static func save(_ recorder: PeripheralStateRecorder, pair: PeripheralFrameSource.Pair?,
                     pending: [PeripheralUnpairedInput] = []) throws -> URL {
        let gate = DispatchSemaphore(value:0)
        var result: Result<URL,Error>?
        require(recorder.record(pair:pair,camera:["isReady":pair != nil,"status":"fixture","NaN":Double.nan,"tolerance":2.15],unpaired:pending) {
            result = $0; gate.signal()
        },"save admitted")
        require(gate.wait(timeout:.now()+10) == .success,"save finishes")
        return try result!.get()
    }
    static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let recorder = PeripheralStateRecorder(directory:root.appendingPathComponent("records"))
        let absent = try save(recorder,pair:nil)
        let empty = try JSONSerialization.jsonObject(with:Data(contentsOf:absent.appendingPathComponent("manifest.json"))) as! [String:Any]
        require((empty["pairs"] as! [String:Any]).isEmpty,"stopped camera record is preserved")
        require((empty["camera"] as! [String:Any])["NaN"] as? String == "NaN","nonfinite values have explicit JSON representation")
        let a = buffer(kCVPixelFormatType_32BGRA,seed:7)
        let b = buffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,seed:23)
        let m = metadata(a,id:9001)
        var config = PeripheralFrameSource.Configuration(); config.epoch = 4; config.fieldOfViewRatio = 1.7
        let pair = PeripheralFrameSource.Pair(center:a,outer:b,receipt:CACurrentMediaTime(),configuration:config,
            serial:18,centerMetadata:m,outerMetadata:metadata(b,id:9002),pairingMode:"original-fixture")
        // Same counters in a different source must not overwrite the previous pair.
        let old = PeripheralFrameSource.Pair(center:a,outer:b,receipt:pair.receipt-0.1,configuration:config,serial:18)
        let rgba = (0..<8*6*4).map { UInt8($0%256) }
        let fieldValues=(0..<2*2*4).map {Float($0)*0.125}
        let refinement=PeripheralDenseRefinement(id:22,epoch:4,sourcePairID:18,homography:matrix_identity_float3x3,
            width:2,height:2,rgba:fieldValues,consistentFraction:0.95,elapsedMS:120,maximumOffset:0.02)
        let snapshot = PeripheralAnalysisSnapshot(pair:old,reference:rgba,warped:[],metadata:[
            "available":true,"published":false,"reason":"expired-before-publication", "width":8,"height":6,"padding":0],
            nativeStrips:[.init(edge:0,width:8,height:6,reference:rgba,outer:rgba,nativeScale:1)],refinement:refinement)
        let renderFieldValues=fieldValues.map {$0+1}
        let renderField=PeripheralDenseRefinement(id:23,epoch:4,sourcePairID:17,homography:matrix_identity_float3x3,
            width:2,height:2,rgba:renderFieldValues,consistentFraction:0.9,elapsedMS:100,maximumOffset:0.02)
        let frame=PeripheralLiveFrame(pair:pair,matrix:matrix_identity_float3x3,gains:.init(),refinement:renderField,
            refinementStrength:0.7,analysisPairID:old.serial,analysisObservedAt:old.observedAt,modelPair:old,
            mappingBasis:"live-retained-spatial-proposal",seams:.horizontal,tolerance:2.15,margin:4)
        recorder.updateRenderer(["phase":"submitted","hostTime":pair.receipt,"effectiveBlackOpacity":1.0,
            "policyReason":"evidence-expired","rejectionReasons":["measurement-expired"],"forcedBlack":false,
            "infinity":Double.infinity],pair:pair,texturePair:pair,analysis:snapshot,renderedFrame:frame)
        recorder.gpuEvent(["commandID":1,"status":4])
        let saved = try save(recorder,pair:pair)
        let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:saved.appendingPathComponent("manifest.json"))) as! [String:Any]
        require((manifest["camera"] as! [String:Any])["tolerance"] as? Double == 2.15,"Exact selected tolerance was lost in the exported record")
        let pairs = manifest["pairs"] as! [String:[String:Any]]
        require(pairs.count == 2,"distinct source times remain distinct")
        let roles = manifest["roles"] as! [String:String]
        require(roles["tapPair"] != roles["analysisPair"],"analysis and current frame roles remain distinct")
        require(roles["texturePair"]==roles["tapPair"] && roles["renderModelPair"]==roles["analysisPair"],
            "Live display mixed current pixels and the model's earlier source frame")
        let storedRenderField=try Data(contentsOf:saved.appendingPathComponent("render-refinement.rgba32f"))
        require(storedRenderField==renderFieldValues.withUnsafeBytes {Data($0)},"The actual rendered field was replaced by the latest analysis field")
        let centerMetadata = pairs[roles["tapPair"]!]!["centerMetadata"] as! [String:Any]
        require(centerMetadata["pts"] as! Double == 1234567.0/600,"original PTS retained")
        require((centerMetadata["K_columns"] as! [[NSNumber]])[0][0].floatValue == 777,"intrinsics retained")
        for pairRow in pairs.values {
            for stream in ["center","outer"] {
                let row = pairRow[stream] as! [String:Any]
                let planes = row["planes"] as! [[String:Any]]
                require(planes.count == (stream == "center" ? 1 : 2),"original plane count")
                for (p,plane) in planes.enumerated() {
                    let bytes = try Data(contentsOf:saved.appendingPathComponent(plane["file"] as! String))
                    require(bytes.count == (plane["bytesPerRow"] as! Int)*(plane["height"] as! Int),"all original row bytes retained")
                    let seed = stream == "center" ? 7 : 23
                    require(bytes.enumerated().allSatisfy { $0.element == UInt8(($0.offset*17+seed+p*31)%256) },"byte exact including 10-bit planes and padding")
                }
            }
        }
        let storedReference = try Data(contentsOf:saved.appendingPathComponent("analysis-reference.rgba"))
        let storedField=try Data(contentsOf:saved.appendingPathComponent("dense-refinement.rgba32f"))
        require(storedField == fieldValues.withUnsafeBytes {Data($0)},"Original refinement vectors were not preserved byte-for-byte")
        require(storedReference == Data(rgba),"exact analysis bytes retained separately")
        let nativeReference = try Data(contentsOf:saved.appendingPathComponent("native-edge-0-reference.rgba"))
        require(nativeReference == Data(rgba),"Native verification support was not retained byte-for-byte")
        let source = PeripheralFrameSource()
        source.configure(outputIndex:1,ratio:1.7)
        source.offer(center:sample(a),outer:nil,selection:source.selection())
        let pending = source.recordingSnapshot()
        require(pending.pair == nil && pending.pending.count == 1,"unmatched original is visible to manual capture")
        let unmatched = try save(PeripheralStateRecorder(directory:root.appendingPathComponent("unmatched")),pair:nil,pending:pending.pending)
        let pendingManifest = try JSONSerialization.jsonObject(with:Data(contentsOf:unmatched.appendingPathComponent("manifest.json"))) as! [String:Any]
        require((pendingManifest["unpairedInputs"] as! [[String:Any]]).count == 1,"unpaired original saved despite no stereo pair")
        let worker = PeripheralAlignmentWorker()
        require(worker.analyze(pair,now:{ pair.observedAt+1 }) == nil,"expired input is rejected")
        require(worker.latestDiagnostic()?.metadata["reason"] as? String == "expired-input-or-no-seams","actual rejection is retained for manual diagnosis")
        // New service instance discovers previous records instead of deleting them.
        let restarted = PeripheralStateRecorder(directory:root.appendingPathComponent("records"))
        let exportGate = DispatchSemaphore(value:0)
        var exportResult: Result<URL,Error>?
        require(restarted.export { exportResult=$0; exportGate.signal() },"export admitted")
        require(exportGate.wait(timeout:.now()+10) == .success,"export finishes")
        let zip = try exportResult!.get()
        try FileManager.default.moveItem(at:zip,to:root.appendingPathComponent("export.zip"))
        require(FileManager.default.fileExists(atPath:saved.appendingPathComponent("manifest.json").path),"export never deletes originals")
        let full = PeripheralStateRecorder(directory:root.appendingPathComponent("full"),maxBytes:1)
        do { _ = try save(full,pair:pair); fatalError("full store must report failure") }
        catch { require(error is PeripheralStateRecorder.RecordingError,"storage limit reports real error") }
        let fullContents = try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("full").path)
        require(fullContents.isEmpty,"failed record leaves no partial folder")
        let blocker = root.appendingPathComponent("blocker")
        try Data([1]).write(to:blocker)
        do { _ = try save(PeripheralStateRecorder(directory:blocker),pair:nil); fatalError("I/O failure must not report saved") }
        catch { }
        print("PASS manual records: native BGRA + 10-bit YUV bytes/stride, metadata/K/PTS, rejected analysis, missing camera, limits, restart and ZIP export")
    }
}
