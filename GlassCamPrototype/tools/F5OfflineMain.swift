import Foundation

/// An offline executable compiled by test_f5.py --build-offline. Its JSON input
/// is explicitly synthetic and cannot create an accepted device profile.
@main struct F5OfflineMain {
    struct Input: Decodable {
        let synthetic: Bool
        let width:Int,height:Int,frames:[[UInt16]]
    }
    static func main() {
        do {
            guard CommandLine.arguments.count==4 else {throw F5Failure(.damagedBundle,"Usage: f5-offline scene.json output-directory F5Kernels.metal")}
            let inputData=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
            let input=try JSONDecoder().decode(Input.self,from:inputData)
            guard input.synthetic,(4...128).contains(input.width),(4...128).contains(input.height) else {throw F5Failure(.unqualified,"This fixture runner only accepts explicitly synthetic small images.")}
            let directory=URL(fileURLWithPath:CommandLine.arguments[2]),shader=URL(fileURLWithPath:CommandLine.arguments[3])
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            var policy=F5Policy();policy.maximumProcessingSeconds=240;policy.maximumWarpJacobianDeviation=0.02
            let fixture=try F5Fixtures.make(directory:directory.appendingPathComponent("inputs"),width:input.width,height:input.height,
                inputFrames:input.frames,policyOverride:policy)
            let image=try F5Reconstructor.reconstruct(fixture.source,shaderURL:shader)
            let provenance=image.provenance(fixture.source.manifest)
            let metadata=image.photoMetadata.addingCaptureProvenance("GlassCam F5\n"+String(decoding:try F5Hash.json(provenance),as:UTF8.self))
            _ = try ImagePipeline.writeF5HEIF(image,metadata:metadata,recipe:.standard,to:directory.appendingPathComponent("result.heic"),isCancelled:{false},progress:{_ in})
            let paths=["input_scene_sha256":F5Hash.data(inputData),"burst":fixture.source.directory.path,"camera_rgb":fixture.source.directory.appendingPathComponent("linear-camera.f32").path,
                "quality":fixture.source.directory.appendingPathComponent("quality.json").path,"heif":directory.appendingPathComponent("result.heic").path]
            try CaptureJournal.writeProtected(JSONSerialization.data(withJSONObject:paths,options:[.prettyPrinted,.sortedKeys]),to:directory.appendingPathComponent("outputs.json"))
            print("F5 synthetic export",image.width,image.height,image.quality.solveStatus,fixture.source.directory.path)
        } catch {fputs("F5 offline: \(error.localizedDescription)\n",stderr);exit(1)}
    }
}
