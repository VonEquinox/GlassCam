import Foundation
import CoreImage
import Metal

enum Check {
    static func that(_ value:Bool,_ message:String) throws {if !value{throw F5Failure(.damagedBundle,message)}}
}

@main struct F5ContractTests {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("F5 failure: \(error.localizedDescription)\n",stderr);exit(1) }
    }
    @MainActor static func run() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),shader=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let fixture=try F5Fixtures.make(directory:root.appendingPathComponent(UUID().uuidString))
        try contracts(fixture)
        if let oracle=ProcessInfo.processInfo.environment["F5_SDK_ORACLE"] {try colorOracle(profile:fixture.profile,root:root,oracle:oracle)}
        fputs("F5 metadata contracts passed\n",stderr)
        try await journal(fixture,root:root)
        fputs("F5 journal contracts passed\n",stderr)
        try frozenOperator(fixture,shader:shader)
        let mapped=try F5Fixtures.make(directory:root.appendingPathComponent(UUID().uuidString),codeDivisor:4)
        try nativeCodeMapping(mapped)
        try frozenOperator(mapped,shader:shader)
        let spatial=try F5Fixtures.make(directory:root.appendingPathComponent(UUID().uuidString),additionalDNGTags:[F5Fixtures.stage2GainTag()])
        try frozenOperator(spatial,shader:shader)
        let stripFixture=try F5Fixtures.make(directory:root.appendingPathComponent(UUID().uuidString),width:72,height:70)
        try motionStrips(stripFixture,shader:shader)
        let noiseFixture=try F5Fixtures.make(directory:root.appendingPathComponent(UUID().uuidString),width:24,height:24)
        try nativeNoiseScale(noiseFixture,shader:shader)
        try postOpcodes(root:root,shader:shader,oracle:ProcessInfo.processInfo.environment["F5_SDK_PIXEL_ORACLE"])
        if let path=ProcessInfo.processInfo.environment["F5_REAL_BURST"],let oracle=ProcessInfo.processInfo.environment["F5_SDK_PIXEL_ORACLE"] {
            try realBundle(URL(fileURLWithPath:path),output:root,shader:shader,oracle:oracle)
        }
        let changedISO=try F5Fixtures.make(directory:root.appendingPathComponent(UUID().uuidString),deliveredISOs:[100,100,64,100,100])
        try Check.that(changedISO.source.manifest.flags.contains(.isoChanged) && changedISO.source.manifest.flags.contains(.exposureAdjusted),"Acquisition audit flags were discarded at commit")
        do {_ = try F5Reconstructor.reconstruct(changedISO.source,shaderURL:shader);throw F5Failure(.damagedBundle,"Different-ISO frames entered one noise model")}
        catch let failure as F5Failure {try Check.that(failure.code == .isoChanged,"ISO mismatch must stop before reconstruction")}
        if let lut=ProcessInfo.processInfo.environment["F5_TEST_LUT_PACKAGE"] {try lookupTable(fixture,shader:shader,directory:URL(fileURLWithPath:lut))}
        if CommandLine.arguments[3] == "pipeline" || CommandLine.arguments[3] == "all" {
            let image=try F5Reconstructor.reconstruct(fixture.source,shaderURL:shader)
            try Check.that(image.width==16 && image.height==12,"F5 output was not sampled at 2× density")
            try Check.that(image.quality.actualFrameCount==5 && image.color.whiteBalanceOwner=="matrix","F5 provenance was lost")
            let epochs=Dictionary(grouping:image.quality.objectiveEpochs){$0.id/9}
            try Check.that(epochs.values.allSatisfy{$0.reduce(0){$0+$1.completedCycles}<=fixture.profile.policy.maxCycles},"F5 exceeded its declared cycle limit")
            try Check.that(image.quality.objectiveEpochs.filter{$0.stopReason=="CONVERGED"}.allSatisfy{$0.standardizedMotionGradient<fixture.profile.policy.standardizedGradientTolerance},"Image-only stationarity was called joint convergence")
            let comment="GlassCam F5\n" + String(decoding:try F5Hash.json(image.provenance(fixture.source.manifest)),as:UTF8.self)
            let metadata=image.photoMetadata.addingCaptureProvenance(comment)
            let output=root.appendingPathComponent("f5-result.heic")
            _ = try ImagePipeline.writeF5HEIF(image,metadata:metadata,recipe:.standard,to:output,isCancelled:{false},progress:{_ in})
            guard let source=CGImageSourceCreateWithURL(output as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] else {throw PipelineError.encoding}
            try Check.that((properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue==10,"F5 HEIF is not 10-bit")
            try metadata.validate(in:properties)
            let exif=properties[kCGImagePropertyExifDictionary as String] as? [String:Any]
            try Check.that(exif?[kCGImagePropertyExifUserComment as String] as? String == comment,"Final HEIF lost F5 provenance")
            try Check.that(metadata.captureDate != nil,"The independent DNG parser lost capture date/timezone")
            print("PASS F5 camera-linear -> color matrix -> production HDR HEIF",image.quality.solveStatus)
        }
        print("PASS F5 production contracts, journal, and frozen CPU/GPU objective")
    }
    static func motionStrips(_ fixture:F5Fixtures.Fixture,shader:URL) throws {
        let width=72,height=70,columns=(width+31)/32+1,rows=(height+31)/32+1,nodes=columns*rows*5
        let device=try F5MetalDevice(maximumBytes:256*1024*1024,shaderURL:shader,isCancelled:{false})
        let frames=try fixture.canonical.map{try F5MetalFrame.upload($0,to:device)}
        for frame in frames {
            let mask=frame.eligibility.metal.contents().assumingMemoryBound(to:UInt32.self)
            for i in stride(from:0,to:width*height,by:17) {mask[i/32] &= ~(UInt32(1)<<UInt32(i%32))}
        }
        let lookup=try F5MetalLikelihood.load(profile:fixture.profile,directory:fixture.source.directory,device:device)
        let offsets=(0..<nodes).map{SIMD2<Float>(0.2*sin(Float($0)*0.31),0.17*cos(Float($0)*0.23))}
        let motion=try device.upload(offsets,label:"Strip motion"),direction=try device.upload(offsets.map{$0*0.1},label:"Strip direction")
        let edge=try device.upload([Float](repeating:0.8,count:nodes),label:"Strip motion weights")
        let bounds=[SIMD4<Float>](repeating:SIMD4(-0.3,-0.3,0.3,0.3),count:5)
        for scale in [1,2] {
            let coefficients=try device.upload((0..<width*height*scale*scale*3).map{Float(0.24+0.035*sin(Double($0)*0.13))},label:"Strip image")
            let noise=try device.upload([Float](repeating:0.02,count:width*height),label:"Strip noise")
            let scratch=try F5MetalScratch(width:width,height:height,coreSize:16,device:device)
            let level=F5MetalLevel(width:width,height:height,scale:scale,reference:1,policy:fixture.profile.policy,device:device,frames:frames,scratch:scratch,likelihood:lookup,
                coefficients:coefficients,noise:noise,motion:motion,motionDirection:direction,motionBounds:bounds,validEventCount:width*height*5)
            level.motionEdgeWeights=edge;try level.prepare(SIMD4(0,0,16,16),tau:1e-6)
            func calculate(_ parallel:Bool)throws->[[Float]] {
                level.parallelMotion=parallel
                try device.run {command in
                    try device.clear(scratch.motionDataNormal.metal,command:command)
                    try level.encodeMotion(command:command,direction:direction,mode:0,target:scratch.motion.gradient)
                }
                return [scratch.motion.gradient,scratch.motion.diagonal,scratch.motionDataNormal].map {buffer in
                    Array(UnsafeBufferPointer(start:buffer.metal.contents().assumingMemoryBound(to:Float.self),count:buffer===scratch.motionDataNormal ? nodes*36:nodes*2))
                }
            }
            let serial=try calculate(false),before=device.allocatedBytes,parallel=try calculate(true)
            try Check.that(device.allocatedBytes-before==width*64*16,"Motion cache exceeded its 64-row storage bound")
            for i in serial.indices {
                let error=zip(serial[i],parallel[i]).reduce(0.0){$0+pow(Double($1.0-$1.1),2)}
                let norm=serial[i].reduce(0.0){$0+Double($1*$1)}
                try Check.that(sqrt(error/max(1e-30,norm))<1e-6,"Parallel motion changed gradient, diagonal or normal blocks")
                print("F5 parallel motion",scale,i,"relative error",sqrt(error/max(1e-30,norm)))
            }
        }
    }
    static func nativeNoiseScale(_ fixture:F5Fixtures.Fixture,shader:URL) throws {
        let width=24,height=24
        let device=try F5MetalDevice(maximumBytes:128*1024*1024,shaderURL:shader,isCancelled:{false})
        let frames=try fixture.canonical.map{try F5MetalFrame.upload($0,to:device)}
        let coefficients=try device.upload([Float](repeating:0.3,count:width*height*3),label:"Known constant radiance")
        let noise=try device.upload([Float](repeating:0,count:width*height),label:"Information scale")
        let motion=try device.upload([SIMD2<Float>](repeating:.zero,count:20),label:"Zero noise-control motion")
        let scratch=try F5MetalScratch(width:width,height:height,coreSize:16,device:device)
        let lookup=try F5MetalLikelihood.load(profile:fixture.profile,directory:fixture.source.directory,device:device)
        let level=F5MetalLevel(width:width,height:height,scale:1,reference:1,policy:fixture.profile.policy,device:device,frames:frames,scratch:scratch,likelihood:lookup,
            coefficients:coefficients,noise:noise,motion:motion,motionDirection:motion,motionBounds:[SIMD4<Float>](repeating:.zero,count:5),validEventCount:width*height*5)
        for excludeShort in [false,true] {
            if excludeShort {try device.run {try device.clear(frames[2].eligibility.metal,command:$0)}}
            try level.freezeNoiseScale()
            var precision=0.0,floor=Double.infinity
            for i in 0..<5 where !excludeShort || i != 2 {
                let e=fixture.canonical[i].event(x:12,y:12),gain=e.exposure*e.eta
                precision+=gain*gain/(e.kappa*0.3*gain+e.readSigma*e.readSigma);floor=min(floor,e.readSigma/gain)
            }
            let expected=max(floor,sqrt(3/precision)),actual=noise.metal.contents().assumingMemoryBound(to:Float.self)[12*width+12]
            try Check.that(abs(Double(actual)-expected)<2e-6,"Native information scale lost shot noise, exposure or exclusion semantics")
            print("F5 initial information scale",excludeShort,actual,"expected",expected)
        }
    }
    static func contracts(_ f:F5Fixtures.Fixture) throws {
        try F5Fixtures.decoderContracts()
        let manifest=f.source.manifest
        try Check.that(try manifest.validate(directory:f.source.directory).isEmpty,"Synthetic burst failed its physical contract")
        try Check.that(manifest.frames.count==5 && manifest.requestOrder==[0,1,2,3,4],"Five-frame request budget changed")
        try Check.that(try F5ExposurePlan.groups(maxBracketCount:3)==[[0,1,2],[3,4]],"3-frame brackets changed L,L,S,L,L")
        try Check.that(try F5ExposurePlan.groups(maxBracketCount:2)==[[0,1],[2,3],[4]],"2-frame bracket splitting changed")
        let plan=try F5ExposurePlan.make(ae:0.02,iso:100,minimum:1e-5,maximum:1,quantum:1e-6)
        try Check.that(plan.main<=1/120 && plan.short<plan.main && plan.flags.contains(.meteringUncertain) && plan.flags.contains(.motionUncertain),"Uncalibrated exposure plan claimed calibrated metering")
        do {_ = try F5ExposurePlan.make(ae:136e-6,iso:80,minimum:14e-6,maximum:1,quantum:1e-9);throw F5Failure(.damagedBundle,"A hardware-clamped short exposure passed product planning")}
        catch let failure as F5Failure {try Check.that(failure.code == .shortExposureLimited,"Minimum exposure conflict used the wrong status")}
        let probe=try F5ExposurePlan.make(ae:136e-6,iso:80,minimum:14e-6,maximum:1,quantum:1e-9,allowClampedProbe:true)
        try Check.that(probe.flags.contains(.shortExposureLimited),"A clamped probe claimed an eight-times-shorter frame")
        do {try f.profile.validate(synthetic:false);throw F5Failure(.damagedBundle,"Synthetic profile qualified real hardware")}
        catch let error as F5Failure {try Check.that(error.code == .unqualified,"Synthetic profile rejection used wrong status")}
        let first=f.canonical[0],e=first.event(x:0,y:0)
        try Check.that(e.color==0 && e.phase==0 && e.x==0.5 && e.y==0.5,"Odd ActiveArea shifted the CFA origin")
        try Check.that(e.lower<e.upper && first.record.raster.rowBytes==24,"Padding or interval semantics changed")
        let color=try F5ColorBridge.make(metadata:first.record.metadata,profile:f.profile)
        try Check.that(color.whiteBalanceOwner=="matrix" && color.decodeRevision==F5Version.decoder,"Color bridge lost WB/revision ownership")
        let v=[-0.1,0.4,2.0],out=color.cameraToLinearSRGB.apply(v)
        try Check.that(out.allSatisfy(\.isFinite) && out.contains{$0<0},"The linear color bridge clamped negative or HDR values")
        let defaults=UserDefaults(suiteName:"F5Tests-\(UUID().uuidString)")!
        defaults.set("speed",forKey:"camera.capture.quality.v1")
        try Check.that(CameraSettingsStore(defaults:defaults).captureQuality == .f5,"Old Speed preference did not migrate")
        let old=CaptureSnapshot(recipe:.standard,output:.camera(12),quality:.speed)
        let replay=try JSONDecoder().decode(CaptureSnapshot.self,from:JSONEncoder().encode(old))
        try Check.that(replay.quality == .speed && replay.output.cameraMegapixels==12,"Legacy pending Speed photo was retargeted to F5")
        try Check.that(!CaptureQuality.allCases.contains(.speed) && CaptureQuality.allCases.contains(.f5),"Speed remains in the capture choices")
        try F5BayerLayout.validate(fourCC:0x62676734,metadata:first.record.metadata)
        do {try F5BayerLayout.validate(fourCC:0x72676734,metadata:first.record.metadata);throw F5Failure(.damagedBundle,"Odd CFA mismatch was accepted")}
        catch let error as F5Failure {try Check.that(error.code == .unsupportedRAW,"CFA mismatch used wrong status")}
        try Check.that(CaptureSnapshot(recipe:.standard,output:.camera(48),quality:.f5).output.cameraMegapixels==nil,"F5 inherited the old megapixel resize policy")
    }
    static func nativeCodeMapping(_ fixture:F5Fixtures.Fixture) throws {
        let source=fixture.canonical[0],a=source.record.raster.activeArea
        var data=source.codes
        let values:[UInt16]=[2112,2113,2114,2115,13544]
        for (x,value) in values.enumerated() {
            let offset=a.top*source.record.raster.rowBytes+(a.left+x)*2
            data[offset]=UInt8(value&255);data[offset+1]=UInt8(value>>8)
        }
        let frame=try F5CanonicalFrame(record:source.record,codes:data,profile:fixture.profile,mainExposure:0.008)
        for (x,value) in values.enumerated() {
            let event=frame.event(x:x,y:0)
            let expected=(Double(value)/4-528)/3567
            try Check.that(event.code==value && abs((event.lower+event.upper)/2-expected)<1e-12,"Native low bits or DNG black units were lost")
            try Check.that(abs(event.upper-event.lower-0.25/3567)<1e-12 && abs(event.uniformProbability-1/16384.0)<1e-12,"Native quantization and outlier domains were conflated with DNG")
        }
        let color=try F5ColorBridge.make(metadata:source.record.metadata,profile:fixture.profile)
        try Check.that(color.inputScale==3567,"Native code conversion applied an extra factor to the color bridge")
    }
    static func postOpcodes(root:URL,shader:URL,oracle:String?) throws {
        let device=try F5MetalDevice(maximumBytes:64*1024*1024,shaderURL:shader,isCancelled:{false})
        var report:[[String:Any]]=[],outputs:[String:[Float]]=[:]
        for (name,dng) in try F5Fixtures.postOpcodeFixtures() {
            let metadata=try F5DNGMetadata.read(dng),width=metadata.activeArea.width,height=metadata.activeArea.height
            let correction=try F5RAWCorrections(metadata:metadata)
            try Check.that(correction.gains.isEmpty,"A Stage3 gain map was also applied in the RAW prediction")
            let post=try F5PostOperations.records(metadata)
            let controls=(0..<3).flatMap{Array(repeating:Float(0.02)*Float($0+1),count:width*height)}
            let input=try device.upload(controls,label:"Constant scene-linear RGB"),quality=try device.upload([UInt32](repeating:1,count:((width+31)/32)*((height+31)/32)),label:"Native output support")
            let operations=try device.upload(post.data,label:"Ordered opcode fixture")
            let output=try device.allocate(width*height*16,label:"Opcode result"),failure=try device.allocate(4,label:"Opcode failure")
            let grid=F5GPUGrid(shape:SIMD4(UInt32(width),UInt32(height),1,0),core:.zero,field:.zero,counts:.zero,bin:.zero,
                objective:.zero,regularizer:.zero,step:.zero,options:.zero)
            let options=F5GPUOutput(shape:SIMD4(UInt32(width),UInt32(height),0,UInt32(height)),
                crop:SIMD4(0,0,Float(width),Float(height)),options:SIMD4(UInt32(post.ids.count),1,0,0))
            try device.run { command in
                try device.clear(failure.metal,command:command)
                try device.encode("f5_output_strip",count:width*height,buffers:[input.metal,input.metal,quality.metal,operations.metal,output.metal,failure.metal],command:command) {
                    F5MetalDevice.value(grid,at:6,encoder:$0);F5MetalDevice.value(options,at:7,encoder:$0)
                }
            }
            try Check.that(failure.metal.contents().load(as:UInt32.self)==0,"Post-reconstruction operation failed")
            let actual=Array(UnsafeBufferPointer(start:output.metal.contents().assumingMemoryBound(to:Float.self),count:width*height*4))
            outputs[name]=actual
            if name == "hdr_extension" {
                try Check.that(abs(actual[0]-2)<1e-6 && abs(actual[1]-4)<1e-6 && abs(actual[2]-6)<1e-6,"The declared scene-HDR extension silently clipped recovered highlights")
                continue
            }
            if let oracle {
                let file=root.appendingPathComponent("opcode-\(name).dng"),raw=root.appendingPathComponent("opcode-\(name).f32")
                try dng.write(to:file)
                let task=Process(),pipe=Pipe();task.executableURL=URL(fileURLWithPath:oracle);task.arguments=["--opcode3-probe",file.path,raw.path];task.standardOutput=pipe
                try task.run();let description=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
                guard task.terminationStatus==0,let info=try JSONSerialization.jsonObject(with:description) as? [String:Any],
                      info["width"] as? Int == width,info["height"] as? Int == height else {throw F5Failure(.unsupportedOpcode,"SDK opcode probe failed")}
                let bytes=try Data(contentsOf:raw),expected=bytes.withUnsafeBytes{Array($0.bindMemory(to:Float.self))}
                try Check.that(expected.count==width*height*3,"SDK opcode probe dimensions changed")
                var maximum=0.0
                for pixel in 0..<(width*height) {for channel in 0..<3 {maximum=max(maximum,abs(Double(actual[pixel*4+channel]-expected[pixel*3+channel])))}}
                print("SDK post-opcode",name,"maximum error",maximum)
                try Check.that(maximum<5e-5,"Ordered Stage3 operations disagree with Adobe SDK")
                report.append(["fixture":name,"maximum_error":maximum,"dng_sha256":F5Hash.data(dng)])
            }
        }
        let difference=zip(outputs["gain_before_warp"]!,outputs["gain_after_warp"]!).map{abs($0-$1)}.max()!
        try Check.that(difference>0.01,"Gain and geometry were regrouped instead of preserving opcode order")
        if oracle != nil {try JSONSerialization.data(withJSONObject:["synthetic":true,"sdk":"Adobe DNG SDK 1.7.1","fixtures":report,
            "comparison_domain":"positive values below unit clipping","hdr_extension":F5Version.opcodeRangePolicy],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("opcode-validation.json"))}
    }
    static func realBundle(_ directory:URL,output:URL,shader:URL,oracle:String) throws {
        let source=try F5BurstSource(directory:directory),flags=try source.manifest.validate(directory:nil)
        if flags.contains(.isoChanged) {
            do {_ = try F5Reconstructor.reconstruct(source,shaderURL:shader);throw F5Failure(.damagedBundle,"Legacy real probe bypassed the ISO guard")}
            catch let failure as F5Failure {try Check.that(failure.code == .isoChanged,"A real ISO mismatch used the wrong status")}
        }
        let reference=source.manifest.frames.first{$0.burstIndex==1}!,metadata=reference.metadata
        let correction=try F5RAWCorrections(metadata:metadata),post=try F5PostOperations.records(metadata)
        let raw=output.appendingPathComponent("real-opcode-reference.f32")
        let task=Process(),pipe=Pipe();task.executableURL=URL(fileURLWithPath:oracle)
        task.arguments=["--opcode3-probe",try reference.dng.url(in:directory).path,raw.path];task.standardOutput=pipe
        try task.run();let description=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
        guard task.terminationStatus==0,let info=try JSONSerialization.jsonObject(with:description) as? [String:Any] else {throw F5Failure(.unsupportedOpcode,"Real DNG opcode oracle failed")}
        let width=metadata.activeArea.width,height=metadata.activeArea.height
        try Check.that(info["width"] as? Int == width && info["height"] as? Int == height,"Real DNG opcode dimensions changed")
        let expected=try Data(contentsOf:raw,options:.mappedIfSafe)
        try Check.that(expected.count==width*height*3*4,"Real DNG opcode result size changed")
        let device=try F5MetalDevice(maximumBytes:256*1024*1024,shaderURL:shader,isCancelled:{false})
        let input=try device.allocate(width*height*3*4,label:"Constant RGB for real opcode audit")
        let controls=input.metal.contents().assumingMemoryBound(to:Float.self)
        for c in 0..<3 {controls.advanced(by:c*width*height).initialize(repeating:Float(0.02)*Float(c+1),count:width*height)}
        let quality=try device.upload([UInt32](repeating:1,count:((width+31)/32)*((height+31)/32)),label:"Native audit support")
        let operations=try device.upload(post.data.isEmpty ? [.zero] : post.data,label:"Real DNG opcode metadata")
        let strip=try device.allocate(4*16,label:"Real opcode audit strip"),failure=try device.allocate(4,label:"Opcode failure")
        let grid=F5GPUGrid(shape:SIMD4(UInt32(width),UInt32(height),1,0),core:.zero,field:.zero,counts:.zero,bin:.zero,objective:.zero,regularizer:.zero,step:.zero,options:.zero)
        var maximum=0.0,components=0
        for y in [0,height/2,height-2] {for x in [0,width/2,width-2] {
            let options=F5GPUOutput(shape:SIMD4(2,2,0,2),crop:SIMD4(Float(x),Float(y),2,2),options:SIMD4(UInt32(post.ids.count),1,0,0))
            try device.run {command in
                try device.clear(failure.metal,command:command)
                try device.encode("f5_output_strip",count:4,buffers:[input.metal,input.metal,quality.metal,operations.metal,strip.metal,failure.metal],command:command) {
                    F5MetalDevice.value(grid,at:6,encoder:$0);F5MetalDevice.value(options,at:7,encoder:$0)
                }
            }
            try Check.that(failure.metal.contents().load(as:UInt32.self)==0,"Real opcode GPU audit failed")
            let actual=strip.metal.contents().assumingMemoryBound(to:Float.self)
            expected.withUnsafeBytes { bytes in
                let values=bytes.bindMemory(to:Float.self)
                for dy in 0..<2 {for dx in 0..<2 {for c in 0..<3 {
                    let value=values[((y+dy)*width+x+dx)*3+c]
                    maximum=max(maximum,abs(Double(actual[(dy*2+dx)*4+c]-value)));components += 1
                }}}
            }
        }}
        try Check.that(maximum<3e-6,"Real DNG gain-map evaluation differs from Adobe SDK")
        let report:[String:Any]=["synthetic":false,"qualification":"UNQUALIFIED","hardware_model":source.manifest.hardwareModel,
            "os_build":source.manifest.osBuild,"source_dng_sha256":reference.dng.sha256,"original_bundle_verified":true,
            "recomputed_flags":flags.map(\.rawValue).sorted(),"stage2_maps_in_prediction":correction.gains.count,
            "stage3_opcode_ids":post.ids.map(Int.init),"sdk_probe":"constant RGB, no scene photons or noise fitting",
            "compared_components":components,"maximum_error":maximum,"opcode_range_policy":F5Version.opcodeRangePolicy]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("real-opcode-validation.json"))
        print("PASS real-device input audit and SDK/Metal post opcodes",components,"components; maximum error",maximum)
    }
    static func colorOracle(profile:F5DeviceProfile,root:URL,oracle:String) throws {
        var report:[[String:Any]]=[]
        for (name,data) in try F5Fixtures.colorFixtures() {
            let file=root.appendingPathComponent("color-\(name).dng");try data.write(to:file)
            let actual=try F5ColorBridge.make(metadata:F5DNGMetadata.read(data),profile:profile)
            let task=Process(),pipe=Pipe();task.executableURL=URL(fileURLWithPath:oracle);task.arguments=[file.path];task.standardOutput=pipe
            try task.run();let bytes=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
            guard task.terminationStatus==0,let object=try JSONSerialization.jsonObject(with:bytes) as? [String:[Double]],
                  let white=object["white_xy"],let matrix=object["camera_to_xyz_d50"] else {throw F5Failure(.colorTransformInvalid,"Adobe DNG SDK oracle failed \(name)")}
            let matrixError=zip(actual.cameraToXYZD50.values,matrix).map{abs($0-$1)}.max()!,whiteError=max(abs(actual.whiteX-white[0]),abs(actual.whiteY-white[1]))
            print("SDK color",name,"matrix",matrixError,"white",whiteError)
            report.append(["fixture":name,"matrix_max_error":matrixError,"white_max_error":whiteError,"sha256":F5Hash.data(data)])
            try Check.that(matrixError<2e-6 && whiteError<2e-7,"The independent color bridge disagrees with Adobe SDK: \(name)")
        }
        try JSONSerialization.data(withJSONObject:["synthetic":true,"sdk":"Adobe DNG SDK 1.7.1","fixtures":report],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("color-validation.json"))
    }
    static func lookupTable(_ fixture:F5Fixtures.Fixture,shader:URL,directory:URL) throws {
        var object=try JSONSerialization.jsonObject(with:F5Hash.json(fixture.profile)) as! [String:Any]
        object["likelihood"]=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("likelihood-descriptor.json")))
        let profile=try JSONDecoder().decode(F5DeviceProfile.self,from:JSONSerialization.data(withJSONObject:object))
        try profile.validate(synthetic:true)
        let device=try F5MetalDevice(maximumBytes:32*1024*1024,shaderURL:shader,isCancelled:{false})
        let table=try F5MetalLikelihood.load(profile:profile,directory:directory,device:device)
        var events:[F5GPUEvent]=[],means:[Float]=[]
        for phase:UInt32 in 0..<4 {for kind:UInt32 in 0..<3 {for electrons:Float in [0.008,0.073,0.183] {
            let k=Float(profile.noise[Int(phase)].kappa),s=Float(profile.noise[Int(phase)].readSigma),mean=k*electrons
            let width=1/Float(profile.whiteScale),center=mean+0.317*sqrt(k*mean+s*s)
            events.append(.init(at:.init(0,0,1,width),interval:.init(kind==0 ? center-width/2:center,kind==0 ? center+width/2:center,k,s),
                score:.zero,info:.init(0,phase,0,kind),source:.init(1/65536,0,0,0)));means.append(mean)
        }}}
        let eb=try device.upload(events,label:"LUT held-out events"),mb=try device.upload(means,label:"LUT held-out means"),out=try device.allocate(events.count*16,label:"LUT probe")
        try device.run {command in try device.encode("f5_probe_likelihood",count:events.count,buffers:[eb.metal,mb.metal,out.metal],command:command) {e in
            F5MetalDevice.value(table.uniforms,at:3,encoder:e);e.setBuffer(table.table.metal,offset:0,index:4);F5MetalDevice.value(UInt32(events.count),at:5,encoder:e)
        }}
        let values=out.metal.contents().assumingMemoryBound(to:SIMD4<Float>.self)
        var nll=0.0,score=0.0
        for i in events.indices {
            let e=events[i],center=Double((e.interval.x+e.interval.y)/2)
            var literal=F5LikelihoodValue()
            let status=f5_pg_event(.init(lower:e.info.w==0 ? center-Double(e.at.w)/2:Double(e.interval.x),upper:e.info.w==0 ? center+Double(e.at.w)/2:Double(e.interval.y),
                kappa:Double(e.interval.z),read_sigma:Double(e.interval.w),uniform_probability:1/65536,kind:e.info.w),Double(means[i]),&literal)
            try Check.that(status==0,"LUT's literal comparison failed")
            nll=max(nll,abs(Double(values[i].x)-literal.nll));score=max(score,abs(Double(values[i].y)-literal.score)*sqrt(Double(e.interval.z*means[i]+e.interval.w*e.interval.w)))
        }
        try Check.that(nll<1e-4 && score<1e-3,"Production LUT interpolation violated its error contract")
        print("F5 actual Metal LUT NLL error",nll,"standardized score error",score)
    }
    static func journal(_ f:F5Fixtures.Fixture,root:URL) async throws {
        let directory=root.appendingPathComponent("journal-\(UUID().uuidString)"),journal=CaptureJournal(directory:directory)
        let id=UUID(),snapshot=CaptureSnapshot(recipe:.standard,output:.camera(48),quality:.f5)
        let record=try journal.retainBurst(f.source,id:id,snapshot:snapshot)
        try Check.that(record.schemaVersion==2 && record.sourceKind=="f5","Journal stored a burst as a single DNG")
        let recovered=try CaptureJournal(directory:directory).load()
        try Check.that(recovered?.id==id && recovered?.snapshot.quality == .f5,"A restart lost the immutable F5 transaction")
        let source=try F5BurstSource(directory:journal.burstURL)
        try Check.that(source.manifest.frames.count==5,"Restart lost RAW frames")
        let victim=try source.manifest.frames[4].mosaic.url(in:source.directory),original=try Data(contentsOf:victim)
        var corrupted=original;corrupted[0]^=1;try corrupted.write(to:victim)
        var rejected=false
        do {_ = try journal.load()}
        catch let error as F5Failure {rejected=error.code == .damagedBundle}
        try Check.that(rejected,"A changed RAW hash was accepted")
        try original.write(to:victim);try journal.clear(id:id)
        try Check.that(!FileManager.default.fileExists(atPath:directory.path),"Completed/discarded burst was not released")
        let archive=try F5ArchiveStore.retain(f.source,captureID:id,root:root.appendingPathComponent("archives"))
        let again=try F5ArchiveStore.retain(f.source,captureID:id,root:root.appendingPathComponent("archives"))
        try Check.that(archive==again && (try F5BurstSource(directory:archive)).manifest.frames.count==5,"RAW archive was not durable/idempotent")
        let failed=try F5BurstTransaction(snapshot:snapshot,purpose:"synthetic-test",root:root.appendingPathComponent("failed-delivery"))
        try failed.register(requestID:900,indices:[0])
        let damaged=Data([0,1,2,3]),delivery=try failed.retainDelivery(requestID:900,sequenceCount:1,dng:damaged)
        failed.cancel(.unsupportedRAW)
        let late=try failed.retainDelivery(requestID:900,sequenceCount:1,dng:Data([4,5,6,7]))
        try delivery.dng.verify(in:failed.directory);try late.dng.verify(in:failed.directory)
        try Check.that(delivery.dng.path != late.dng.path,"Late conflicting payload overwrote the original delivery")
    }
    static func frozenOperator(_ fixture:F5Fixtures.Fixture,shader:URL) throws {
        let width=8,height=6,scale=2,n=width*height*scale*scale*3
        let device=try F5MetalDevice(maximumBytes:256*1024*1024,shaderURL:shader,isCancelled:{false})
        for length in 0...5 {
            let floats=[Float](repeating:512,count:length),words=(0..<length).map{UInt32($0*17)}
            let fb=try device.upload(floats,label:"short Float regression"),wb=try device.upload(words,label:"short UInt regression")
            let actualFloats=Array(UnsafeBufferPointer(start:fb.metal.contents().assumingMemoryBound(to:Float.self),count:length))
            let actualWords=Array(UnsafeBufferPointer(start:wb.metal.contents().assumingMemoryBound(to:UInt32.self),count:length))
            try Check.that(actualFloats==floats && actualWords==words,"A short generic upload corrupted values")
        }
        let frames=try fixture.canonical.map{try F5MetalFrame.upload($0,to:device)}
        let cardinal=try device.allocate(width*height*3*4,label:"Observed-site initializer regression")
        try device.run {command in
            try device.encode("f5_initialize_cardinal_samples",count:width*height,buffers:[frames[1].raw.metal,frames[1].table.metal,cardinal.metal],command:command) {F5MetalDevice.value(frames[1].uniforms,at:3,encoder:$0)}
        }
        let initialized=cardinal.metal.contents().assumingMemoryBound(to:Float.self)
        for y in 0..<height {for x in 0..<width {
            let e=fixture.canonical[1].event(x:x,y:y)
            if e.kind.rawValue<3 {
                let observation=e.kind.rawValue==1 ? e.lower:e.kind.rawValue==2 ? 0:(e.lower+e.upper)/2
                let expected=max(1e-6,observation/(e.exposure*e.eta))
                try Check.that(abs(Double(initialized[(e.color*height+y)*width+x])-expected)<2e-6,
                    "Cardinal initializer changed an observed CFA site, including the two green phases")
            }
        }}
        let scratch=try F5MetalScratch(width:width,height:height,coreSize:16,device:device)
        let lookup=try F5MetalLikelihood.load(profile:fixture.profile,directory:fixture.source.directory,device:device)
        let x=(0..<n).map{Float(0.24+0.035*sin(Double($0)*0.13))},d=(0..<n).map{Float(sin(Double($0)*0.71)*0.01)}
        let cb=try device.upload(x,label:"FP32 controls"),db=try device.upload(d,label:"independent direction")
        let noise=try device.upload([Float](repeating:0.02,count:width*height),label:"frozen prior noise")
        let translations:[Float]=[0.5,0.5,0,0,-0.5,0.5,0.5,-0.5,-0.5,-0.5]
        var nodes:[SIMD2<Float>]=[];for f in 0..<5{nodes += Array(repeating:SIMD2(translations[f*2],translations[f*2+1]),count:4)}
        let motion=try device.upload(nodes,label:"known motion"),md=try device.upload([SIMD2<Float>](repeating:.zero,count:20),label:"zero motion direction")
        let bounds=(0..<5).map{SIMD4(translations[$0*2],translations[$0*2+1],translations[$0*2],translations[$0*2+1])}
        let level=F5MetalLevel(width:width,height:height,scale:scale,reference:1,policy:fixture.profile.policy,device:device,frames:frames,scratch:scratch,likelihood:lookup,
            coefficients:cb,noise:noise,motion:motion,motionDirection:md,motionBounds:bounds,validEventCount:width*height*5)
        try level.prepare(SIMD4(0,0,16,12),tau:1e-6)
        let actual=try level.evaluate()
        let gpuGradient=Array(UnsafeBufferPointer(start:scratch.fine.q.metal.contents().assumingMemoryBound(to:Float.self),count:n))
        let gpuDiagonal=Array(UnsafeBufferPointer(start:scratch.fine.diagonal.metal.contents().assumingMemoryBound(to:Float.self),count:n))
        _ = try level.evaluate(direction:db,mode:1)
        let gpuNormal=Array(UnsafeBufferPointer(start:scratch.fine.q.metal.contents().assumingMemoryBound(to:Float.self),count:n))
        // A rejected trial may have very different mixture responsibilities.
        // It must not replace the curvature frozen for the current PCG solve.
        _ = try level.evaluate(direction:db,mode:2,alpha:0.25)
        _ = try level.evaluate(direction:db,mode:1)
        let afterTrial=Array(UnsafeBufferPointer(start:scratch.fine.q.metal.contents().assumingMemoryBound(to:Float.self),count:n))
        try Check.that(zip(gpuNormal,afterTrial).allSatisfy{abs($0-$1)<1e-6},"A trial step changed the frozen normal operator")
        try level.prepare(SIMD4(0,0,16,12),tau:1e-6)
        _ = try level.evaluate(direction:db,mode:1)
        let reloaded=Array(UnsafeBufferPointer(start:scratch.fine.q.metal.contents().assumingMemoryBound(to:Float.self),count:n))
        try Check.that(zip(gpuNormal,reloaded).allSatisfy{abs($0-$1)<1e-6},"Reloading a coarse tile used an invalid likelihood cache")
        _ = try level.evaluate()
        let excessive=try device.upload(d.map{$0*1000},label:"Direction blocked by physical intensities")
        try level.addLocalConstraintDamping(excessive)
        let guardedObjective=try level.evaluate()
        let guardedGradient=Array(UnsafeBufferPointer(start:scratch.fine.q.metal.contents().assumingMemoryBound(to:Float.self),count:n))
        try Check.that(abs(guardedObjective-actual)<1e-6 && zip(gpuGradient,guardedGradient).allSatisfy{abs($0-$1)<1e-6},
            "Local feasibility damping changed the image objective or its gradient")
        _ = try level.evaluate(direction:db,mode:1)
        let guardedNormal=Array(UnsafeBufferPointer(start:scratch.fine.q.metal.contents().assumingMemoryBound(to:Float.self),count:n))
        let expectedEnergy: Double = try {
            let weights=scratch.fieldGuard.metal.contents().assumingMemoryBound(to:SIMD4<Float>.self)
            let eventWeights=scratch.eventGuard.metal.contents().assumingMemoryBound(to:Float.self)
            let events=scratch.events.metal.contents().assumingMemoryBound(to:F5GPUEvent.self)
            let values=d.map(Double.init)
            func sample(_ px:Double,_ py:Double,_ c:Int)->Double {
                var v=0.0,dx=0.0,dy=0.0
                _ = values.withUnsafeBufferPointer { f5_reference_sample($0.baseAddress,Int32(width*scale),Int32(height*scale),Int32(scale),px,py,Int32(c),&v,&dx,&dy) }
                return v
            }
            var total=0.0
            for y in 0..<height*scale {for x in 0..<width*scale {for c in 0..<3 {
                let v=sample((Double(x)+0.5)/Double(scale),(Double(y)+0.5)/Double(scale),c)
                total+=Double(weights[y*width*scale+x][c])*v*v
            }}}
            for i in 0..<Int(level.uniforms.counts.x) where eventWeights[i]>0 {
                let e=events[i],v=sample(Double(e.at.x),Double(e.at.y),Int(e.info.x))
                total+=Double(eventWeights[i])*v*v
            }
            return total
        }()
        let actualEnergy=zip(d,zip(guardedNormal,gpuNormal)).reduce(0.0){$0+Double($1.0)*Double($1.1.0-$1.1.1)}
        try Check.that(expectedEnergy>0 && abs(actualEnergy-expectedEnergy)/expectedEnergy<1e-4,
            "Physical constraint damping differs from independent B-transpose W B energy")
        try level.prepare(SIMD4(0,0,16,12),tau:1e-6)
        let motionValues=(0..<20).map{SIMD2<Float>(sin(Float($0)*0.3)*0.1,cos(Float($0)*0.7)*0.1)}
        let motionTest=try device.upload(motionValues,label:"Independent motion normal direction")
        let edgeWeights=try device.upload([Float](repeating:0.8,count:20),label:"Frozen motion regularization weights")
        func motionNormal(_ mode:Float)throws->[Float] {
            try device.run { command in
                for f in 0..<5 {
                    var grid=level.uniforms;grid.options.w=UInt32(f);grid.step=SIMD4(0,mode,0,0)
                    try device.encode("f5_motion_normal",count:4,
                        buffers:[frames[f].raw.metal,frames[f].table.metal,cb.metal,motion.metal,motionTest.metal,edgeWeights.metal,
                                 frames[f].eligibility.metal,scratch.motion.q.metal,scratch.motion.diagonal.metal],command:command) { e in
                        F5MetalDevice.value(frames[f].uniforms,at:9,encoder:e);F5MetalDevice.value(grid,at:10,encoder:e)
                        F5MetalDevice.value(lookup.uniforms,at:11,encoder:e);e.setBuffer(lookup.table.metal,offset:0,index:12)
                        e.setBuffer(scratch.zero.metal,offset:0,index:13);e.setBuffer(scratch.motionDataNormal.metal,offset:0,index:14)
                    }
                }
            }
            return Array(UnsafeBufferPointer(start:scratch.motion.q.metal.contents().assumingMemoryBound(to:Float.self),count:40))
        }
        _ = try motionNormal(0)
        let cachedMotion=try motionNormal(1),directMotion=try motionNormal(3)
        let motionError=zip(cachedMotion,directMotion).reduce(0.0){$0+pow(Double($1.0-$1.1),2)}
        let motionNorm=directMotion.reduce(0.0){$0+Double($1*$1)}
        try Check.that(sqrt(motionError/max(1e-30,motionNorm))<1e-5,"Cached motion normal differs from direct RAW-event integration")
        var observations:[F5Observation]=[]
        for frame in fixture.canonical {for y in 0..<height{for x in 0..<width{let e=frame.event(x:x,y:y);observations.append(.init(x:e.x,y:e.y,lower:e.lower,upper:e.upper,exposure:e.exposure,eta:e.eta,kappa:e.kappa,read_sigma:e.readSigma,uniform_probability:e.uniformProbability,color:UInt32(e.color),phase:UInt32(e.phase),frame:UInt32(e.frame),kind:e.kind.rawValue))}}}
        var objective=0.0,gradient=[Double](repeating:0,count:n),diagonal=gradient,normal=gradient
        let status=observations.withUnsafeBufferPointer { events in x.map(Double.init).withUnsafeBufferPointer { coefficients in
            d.map(Double.init).withUnsafeBufferPointer { direction in translations.map(Double.init).withUnsafeBufferPointer { motion in
                gradient.withUnsafeMutableBufferPointer { grad in diagonal.withUnsafeMutableBufferPointer { diag in normal.withUnsafeMutableBufferPointer { q in
                    f5_reference_evaluate(events.baseAddress,events.count,coefficients.baseAddress,direction.baseAddress,motion.baseAddress,Int32(width),Int32(height),Int32(scale),1,0.02,
                        fixture.profile.policy.lambdaY,fixture.profile.policy.lambdaC,fixture.profile.policy.outlierProbability,1e-6,&objective,grad.baseAddress,diag.baseAddress,q.baseAddress)
                } } }
            } }
        } }
        try Check.that(status==0,"FP64 objective failed")
        func error(_ a:[Float],_ b:[Double])->Double {let numerator=zip(a,b).reduce(0.0){$0+pow(Double($1.0)-$1.1,2)},denominator=b.reduce(0.0){$0+$1*$1};return sqrt(numerator/max(1e-30,denominator))}
        let ge=error(gpuGradient,gradient),de=error(gpuDiagonal,diagonal),qe=error(gpuNormal,normal)
        print("F5 frozen objective GPU",actual,"CPU",objective,"gradient",ge,"Jacobi",de,"normal",qe)
        try Check.that(abs(actual-objective)/max(1,abs(objective))<1e-5,"GPU event objective mismatch")
        try Check.that(ge<1e-4 && de<1e-4 && qe<1e-4,"GPU adjoint/normal/regularizer mismatch")
        var tiledGradient=[Float](repeating:0,count:n),tiledObjective=0.0
        for tile:SIMD4<UInt32> in [SIMD4(8,8,8,4),SIMD4(0,0,8,8),SIMD4(0,8,8,4),SIMD4(8,0,8,8)] {
            try level.prepare(tile,tau:1e-6,globalObjective:true);tiledObjective += try level.evaluate()
            let local=scratch.fine.q.metal.contents().assumingMemoryBound(to:Float.self),pixels=Int(tile.z*tile.w)
            for c in 0..<3 {for y in 0..<Int(tile.w){for x in 0..<Int(tile.z){
                tiledGradient[(c*height*scale+Int(tile.y)+y)*width*scale+Int(tile.x)+x]=local[c*pixels+y*Int(tile.z)+x]
            }}}
        }
        try Check.that(error(tiledGradient,gradient)<1e-4 && abs(tiledObjective-objective)/abs(objective)<1e-5,"Conditional tile boundaries changed the shared objective or adjoint")
        let colorCorners:[SIMD4<Float>]=[SIMD4(0.3,0.8,0.5,0.1),SIMD4(0.7,0.5,0.2,0.8),SIMD4(0.6,0.7,0.4,0.2),SIMD4(0.2,0.4,0.9,0.9)]
        let lumaCorners:[Float]=[1.5,8,3,4]
        let colorRecords=colorCorners.enumerated().flatMap {[$0.element,SIMD4<Float>(lumaCorners[$0.offset],0,0,0)]}
        level.colorAxis=try device.upload(colorRecords,label:"Independent varying local color directions")
        level.colorAxisShape=SIMD4(2,2,8,2)
        var axes:[Double]=[],confidence:[Double]=[],lumaScale:[Double]=[]
        for y in 0..<height*scale {for x in 0..<width*scale {
            let u=max(0,(Double(x)+0.5)/Double(scale)-0.5)/8,v=max(0,(Double(y)+0.5)/Double(scale)-0.5)/8
            for c in 0..<3 {axes.append((1-v)*((1-u)*Double(colorCorners[0][c])+u*Double(colorCorners[1][c]))+v*((1-u)*Double(colorCorners[2][c])+u*Double(colorCorners[3][c])))}
            confidence.append((1-v)*((1-u)*Double(colorCorners[0].w)+u*Double(colorCorners[1].w))+v*((1-u)*Double(colorCorners[2].w)+u*Double(colorCorners[3].w)))
            lumaScale.append((1-v)*((1-u)*Double(lumaCorners[0])+u*Double(lumaCorners[1]))+v*((1-u)*Double(lumaCorners[2])+u*Double(lumaCorners[3])))
        }}
        axes += confidence
        axes += lumaScale
        try level.prepare(SIMD4(0,0,16,12),tau:1e-6)
        let guidedGPUObjective=try level.evaluate()
        let guidedGPUGradient=Array(UnsafeBufferPointer(start:scratch.fine.q.metal.contents().assumingMemoryBound(to:Float.self),count:n))
        let guidedGPUDiagonal=Array(UnsafeBufferPointer(start:scratch.fine.diagonal.metal.contents().assumingMemoryBound(to:Float.self),count:n))
        _ = try level.evaluate(direction:db,mode:1)
        let guidedGPUNormal=Array(UnsafeBufferPointer(start:scratch.fine.q.metal.contents().assumingMemoryBound(to:Float.self),count:n))
        var guidedObjective=0.0,guidedGradient=[Double](repeating:0,count:n),guidedDiagonal=guidedGradient,guidedNormal=guidedGradient
        let guidedStatus=observations.withUnsafeBufferPointer { events in x.map(Double.init).withUnsafeBufferPointer { coefficients in
            d.map(Double.init).withUnsafeBufferPointer { direction in translations.map(Double.init).withUnsafeBufferPointer { motion in
                axes.withUnsafeBufferPointer { axes in guidedGradient.withUnsafeMutableBufferPointer { grad in
                    guidedDiagonal.withUnsafeMutableBufferPointer { diag in guidedNormal.withUnsafeMutableBufferPointer { q in
                        f5_reference_evaluate_guided(events.baseAddress,events.count,coefficients.baseAddress,direction.baseAddress,motion.baseAddress,
                            Int32(width),Int32(height),Int32(scale),1,0.02,fixture.profile.policy.lambdaY,fixture.profile.policy.lambdaC,
                            fixture.profile.policy.outlierProbability,1e-6,axes.baseAddress,axes.baseAddress!.advanced(by:n),axes.baseAddress!.advanced(by:n+n/3),
                            &guidedObjective,grad.baseAddress,diag.baseAddress,q.baseAddress)
                    }}
                }}
            }}
        }}
        try Check.that(guidedStatus==0 && abs(guidedGPUObjective-guidedObjective)/abs(guidedObjective)<1e-5 &&
            error(guidedGPUGradient,guidedGradient)<1e-4 && error(guidedGPUDiagonal,guidedDiagonal)<1e-4 && error(guidedGPUNormal,guidedNormal)<1e-4,
            "Frozen spatially varying color prior differs from FP64 objective/gradient/normal/diagonal")
        print("F5 guided color prior GPU/FP64 gradient",error(guidedGPUGradient,guidedGradient),"normal",error(guidedGPUNormal,guidedNormal))
        level.colorAxis=nil;level.colorAxisShape = .zero
        // Verify the fallback against the independent full FP64 objective,
        // including a conditional tile and cancellation before any mutation.
        var previousObjective=objective
        for tile:SIMD4<UInt32> in [SIMD4(0,0,16,12),SIMD4(4,4,8,6)] {
            try level.prepare(tile,tau:1e-6)
            let before=Data(bytes:cb.metal.contents(),count:n*4)
            try Check.that(try !level.feasibleGradientStep(budgetExpired:{true}),"Cancelled diagonal step was accepted")
            try Check.that(before==Data(bytes:cb.metal.contents(),count:n*4),"Cancelled diagonal step changed the image")
            try Check.that(try level.feasibleGradientStep(budgetExpired:{false}),"Feasible diagonal descent did not progress")
            let current=Array(UnsafeBufferPointer(start:cb.metal.contents().assumingMemoryBound(to:Float.self),count:n)).map(Double.init)
            var nextObjective=0.0
            let nextStatus=observations.withUnsafeBufferPointer {events in current.withUnsafeBufferPointer {coefficients in
                d.map(Double.init).withUnsafeBufferPointer {direction in translations.map(Double.init).withUnsafeBufferPointer {motion in
                    gradient.withUnsafeMutableBufferPointer {grad in diagonal.withUnsafeMutableBufferPointer {diag in normal.withUnsafeMutableBufferPointer {q in
                        f5_reference_evaluate(events.baseAddress,events.count,coefficients.baseAddress,direction.baseAddress,motion.baseAddress,Int32(width),Int32(height),Int32(scale),1,0.02,
                            fixture.profile.policy.lambdaY,fixture.profile.policy.lambdaC,fixture.profile.policy.outlierProbability,1e-6,&nextObjective,grad.baseAddress,diag.baseAddress,q.baseAddress)
                    }}}
                }}
            }}
            try Check.that(nextStatus==0 && nextObjective.isFinite && nextObjective<previousObjective,"Diagonal fallback did not decrease the independent constrained objective")
            print("F5 feasible diagonal objective",previousObjective,"->",nextObjective)
            previousObjective=nextObjective
        }
        let quality=F5QualityReport.Tile(x:0,y:0,width:8,height:6,support:.nativeFusion,flags:[.ambiguousRegistration],
            validFractions:Array(repeating:1,count:5),upperCensoredFractions:Array(repeating:0,count:5),lowerCensoredFractions:Array(repeating:0,count:5),
            residualRMS:0,minimumInformation:0,conditionNumber:1,shortOnly:false,excludedFrames:[2])
        try level.reviseEligibility([quality])
        let center=3*width+3
        for frame in 0..<5 {
            let words=frames[frame].eligibility.metal.contents().assumingMemoryBound(to:UInt32.self)
            let retained=words[center/32]&(1<<UInt32(center%32)) != 0
            try Check.that(retained == (frame != 2),"An ambiguous short frame discarded reliable main-frame observations")
        }
    }
}
