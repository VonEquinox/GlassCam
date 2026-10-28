import Foundation
import Metal

/// macOS-only numerical experiment. This executable never creates a qualified
/// profile, calls a camera, or bypasses the application's real-capture gate.
@main struct F5DesktopQualityMain {
    struct Gain: Decodable {let rows:Int,columns:Int,originX:Float,originY:Float,spacingX:Float,spacingY:Float,values:[Float]}
    struct Frame: Decodable {
        let index:Int,codes:[UInt16],black:Float,whiteScale:Float,exposureRatio:Float,kappa:Float,readSigma:Float
        let divisor:Int,nativeWhite:Int,used:Bool,cfa:[UInt32],translation:[Float],gain:Gain
    }
    struct PriorGuide: Decodable {
        let revision:String,columns:Int,rows:Int,rawSHA256:String,values:[Float]
    }
    struct Input: Decodable {
        let revision:String,synthetic:Bool,qualification:String,name:String,width:Int,height:Int,reference:Int,frames:[Frame]
        let maximumCycles:Int,maximumSeconds:Double
        let lambdaY:Double?,lambdaC:Double?
        let colorGuide:Bool?
        let cardinalInitialization:Bool?
        let adaptiveColorGuide:Bool?
        let flatPriorBoost:Float?
        let attemptHigh:Bool?
        let geometryMode:String?
        let localDenoise:Bool?
        let malvarInitialization:Bool?
        let protectFineDetail:Bool?
        let localStepLimit:Bool?
        let parallelMotion:Bool?
        let harmonicPrior:Bool?
        let priorGuide:PriorGuide?
        let signalNoisePrior:Bool?
        let feasibleGradientFallback:Bool?
        let exportState:Bool?
    }
    static func installPriorGuide(_ guide:PriorGuide,input:Input,level:F5MetalLevel) throws {
        let columns=(input.width+7)/8+1,rows=(input.height+7)/8+1
        let codes=input.frames.flatMap(\.codes),raw=codes.withUnsafeBytes{Data($0)}
        guard guide.revision=="f5-cross-frame-color-prior-v1",guide.columns==columns,guide.rows==rows,
              guide.rawSHA256==F5Hash.data(raw),guide.values.count==columns*rows*4,guide.values.allSatisfy(\.isFinite),
              let buffer=level.colorAxis else {throw F5Failure(.profileMismatch,"The diagnostic color prior does not match its RAW inputs.")}
        let target=buffer.metal.contents().assumingMemoryBound(to:SIMD4<Float>.self)
        for i in 0..<columns*rows {
            let v=guide.values;let confidence=v[i*4+3]
            if confidence == -1 {continue} // Insufficient support keeps the original guide.
            let axis=SIMD3(v[i*4],v[i*4+1],v[i*4+2]),length=sqrt(axis.x*axis.x+axis.y*axis.y+axis.z*axis.z)
            guard (0...1).contains(confidence),axis.x>=0,axis.y>=0,axis.z>=0,length.isFinite,length>1e-6 else {throw F5Failure(.profileMismatch,"Invalid diagnostic color-prior node.")}
            target[i*2]=SIMD4(axis.x/length,axis.y/length,axis.z/length,confidence)
        }
    }
    static func upload(_ input:Frame,width:Int,height:Int,device:F5MetalDevice) throws -> F5MetalFrame {
        let g=input.gain
        guard input.codes.count==width*height,input.cfa.count==4,Set(input.cfa)==Set([0,1,2,3]),
              input.translation.count==2,input.divisor>0,input.whiteScale>0,input.kappa>0,input.readSigma>0,
              g.rows>0,g.columns>0,g.values.count==g.rows*g.columns,g.values.allSatisfy({$0.isFinite && $0>0}) else {
            throw F5Failure(.damagedBundle,"Invalid desktop diagnostic frame.")
        }
        // The smooth Stage3 map is explicitly an assumed radiometric response
        // in this experiment, not a newly certified interpretation in the app.
        var table:[Float]=[input.black]
        table += [0,0,Float(height),Float(width),1,1,Float(g.rows),Float(g.columns),
            g.originX,g.originY,g.spacingX,g.spacingY,Float(bitPattern:17),0,0,0]
        table += g.values
        let f=F5GPUFrame(shape:SIMD4(UInt32(width),UInt32(height),UInt32(width),14),
            active:SIMD4(0,0,UInt32(width),UInt32(height)),cfa:SIMD4(input.cfa[0],input.cfa[1],input.cfa[2],input.cfa[3]),
            scale:SIMD4(input.exposureRatio,input.whiteScale,0,16383),kappa:SIMD4(repeating:input.kappa),readSigma:SIMD4(repeating:input.readSigma),
            low:SIMD4(repeating:-input.black/input.whiteScale),high:SIMD4(repeating:1),gain:SIMD4(repeating:1),blackResidual:.zero,
            censorLow:.zero,censorHigh:SIMD4(repeating:UInt32(input.nativeWhite)),black:SIMD4(1,1,0,UInt32.max),
            tables:SIMD4(UInt32.max,1,0,1),extras:SIMD4(1,0,0,0),extra2:SIMD4(0,0,0,UInt32(input.divisor)))
        let raw=input.codes.withUnsafeBytes{Data($0)}
        return try .init(raw:device.upload(raw,label:"Retained real native codes"),table:device.upload(table,label:"DNG-derived diagnostic metadata"),
            eligibility:device.upload([UInt32](repeating:input.used ? .max:0,count:(width*height+31)/32),label:"Explicit diagnostic frame exclusion"),uniforms:f)
    }
    static func sampledBuffer(_ level:F5MetalLevel,native:F5MetalLevel,sampling:Int) throws -> F5MetalBuffer {
        let w=level.width*sampling,h=level.height*sampling,device=level.device
        let quality=try device.upload([UInt32](repeating:level.scale==2 ? 0:1,count:((level.width+31)/32)*((level.height+31)/32)),label:"Diagnostic sampling grid")
        let operations=try device.upload([SIMD4<Float>.zero],label:"Radiometry already included in experiment")
        let buffer=try device.allocate(w*h*16,label:"Desktop diagnostic camera RGB")
        let options=F5GPUOutput(shape:SIMD4(UInt32(w),UInt32(h),0,UInt32(h)),crop:SIMD4(0,0,Float(level.width),Float(level.height)),options:SIMD4(0,UInt32(sampling),0,0))
        try device.run {command in
            try device.clear(level.scratch.failure.metal,command:command)
            try device.encode("f5_output_strip",count:w*h,buffers:[level.coefficients.metal,native.coefficients.metal,quality.metal,operations.metal,buffer.metal,level.scratch.failure.metal],command:command) {
                F5MetalDevice.value(level.uniforms,at:6,encoder:$0);F5MetalDevice.value(options,at:7,encoder:$0)
            }
        }
        guard level.scratch.failure.metal.contents().load(as:UInt32.self)==0 else {throw F5Failure(.nonfinite,"Diagnostic output violated finite/positive sampling constraints.")}
        return buffer
    }
    static func write(_ buffer:F5MetalBuffer,width:Int,height:Int,directory:URL,name:String) throws -> [String:Any] {
        let path=directory.appendingPathComponent(name+".f32")
        try Data(bytes:buffer.metal.contents(),count:width*height*16).write(to:path,options:.atomic)
        return ["path":path.lastPathComponent,"sha256":try F5Hash.file(path),"width":width,"height":height,"channels":4,"component":"float32_le","semantics":"camera_linear_no_wb"]
    }
    static func output(_ level:F5MetalLevel,native:F5MetalLevel,directory:URL,name:String) throws -> [String:Any] {
        try write(sampledBuffer(level,native:native,sampling:2),width:level.width*2,height:level.height*2,directory:directory,name:name)
    }
    static func state(_ level:F5MetalLevel,directory:URL,name:String) throws -> [String:Any] {
        guard level.tileCount==1 else {throw F5Failure(.damagedBundle,"Diagnostic state derivatives require one tile.")}
        let (objective,metric)=try level.globalObjective(tau:1e-8)
        func buffer(_ source:F5MetalBuffer,_ suffix:String,_ shape:[Int]) throws -> [String:Any] {
            let count=shape.reduce(1,*),path=directory.appendingPathComponent(name+"-state-"+suffix+".f32")
            guard count*4<=source.metal.length else {throw F5Failure(.damagedBundle,"Invalid diagnostic state shape.")}
            try Data(bytes:source.metal.contents(),count:count*4).write(to:path,options:.atomic)
            return ["path":path.lastPathComponent,"sha256":try F5Hash.file(path),"shape":shape,"component":"float32_le"]
        }
        var value:[String:Any]=["revision":"f5-native-state-v1","reference":level.reference,"scale":level.scale,
            "width":level.width,"height":level.height,"mesh_spacing":32,
            "barrier_tau":1e-8,"image_objective":objective,"standardized_image_gradient":metric,
            "coefficients":try buffer(level.coefficients,"coefficients",[3,level.height*level.scale,level.width*level.scale]),
            "gradient":try buffer(level.scratch.fine.q,"gradient",[3,level.height*level.scale,level.width*level.scale]),
            "diagonal":try buffer(level.scratch.fine.diagonal,"diagonal",[3,level.height*level.scale,level.width*level.scale]),
            "motion_nodes":try buffer(level.motion,"motion",[5,level.meshRows,level.meshColumns,2]),
            "noise":try buffer(level.noise,"noise",[level.height,level.width])]
        if let axis=level.colorAxis {
            value["color_axis"]=try buffer(axis,"color-axis",[Int(level.colorAxisShape.y),Int(level.colorAxisShape.x),2,4])
            value["color_axis_shape"]=(0..<4).map{Int(level.colorAxisShape[$0])}
        }
        return value
    }
    static func denoisedOutput(_ native:F5MetalLevel,directory:URL,name:String) throws -> [String:Any] {
        let width=native.width,height=native.height,device=native.device
        let image=try sampledBuffer(native,native:native,sampling:1)
        let variance=try device.allocate(width*height*16,label:"Approximate native radiance variance")
        let shape=SIMD2<UInt32>(UInt32(width),UInt32(height))
        try device.run {command in
            try device.clear(variance.metal,command:command)
            for frame in native.frames {
                try device.encode("f5_dct_information",count:width*height,buffers:[image.metal,frame.raw.metal,frame.table.metal,frame.eligibility.metal,variance.metal],command:command) {e in
                    F5MetalDevice.value(frame.uniforms,at:5,encoder:e)
                }
            }
            try device.encode("f5_dct_variance",count:width*height,buffers:[variance.metal],command:command) {F5MetalDevice.value(UInt32(width*height),at:1,encoder:$0)}
        }
        let start=ProcessInfo.processInfo.systemUptime
        let filtered=try F5LocalDenoise.apply(image:image,variance:variance,width:width,height:height,device:device)
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        let output=try device.allocate(width*height*64,label:"Common 2x bilinear diagnostic output")
        try device.run {command in
            try device.encode("f5_dct_upsample",count:width*height*4,buffers:[filtered.metal,output.metal],command:command) {F5MetalDevice.value(shape,at:2,encoder:$0)}
        }
        var report=try write(output,width:width*2,height:height*2,directory:directory,name:name)
        report["seconds"]=elapsed;report["method"]="32x32 local DCT, stride 8, threshold 2.7 sigma"
        report["variance_model"]="Independent per-channel Fisher approximation; reconstructed spatial covariance not certified"
        report["qualification"]="UNQUALIFIED_DIAGNOSTIC"
        return report
    }
    static func main() {
        do {
            guard CommandLine.arguments.count==4 else {throw F5Failure(.damagedBundle,"Usage: f5-desktop-quality input.json output-directory F5Kernels.metal")}
            let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])),input=try JSONDecoder().decode(Input.self,from:data)
            guard (input.revision=="f5-real-roi-v1" && !input.synthetic || input.revision=="f5-synthetic-roi-v1" && input.synthetic),input.qualification=="UNQUALIFIED_DIAGNOSTIC",
                  (8...256).contains(input.width),(8...256).contains(input.height),input.frames.count==5,
                  input.frames.map(\.index)==Array(0..<5),[0,1,3,4].contains(input.reference),
                  input.name.allSatisfy({$0.isLetter || $0.isNumber || $0=="_"}),
                  (1...50).contains(input.maximumCycles),input.maximumSeconds>0 else {throw F5Failure(.damagedBundle,"Invalid desktop ROI contract.")}
            let directory=URL(fileURLWithPath:CommandLine.arguments[2]),shader=URL(fileURLWithPath:CommandLine.arguments[3])
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let device=try F5MetalDevice(maximumBytes:512*1024*1024,shaderURL:shader,isCancelled:{false})
            var policy=F5Policy();policy.blockSize=min(256,max(input.width,input.height)*2);policy.maxCycles=input.maximumCycles
            policy.maximumProcessingSeconds=input.maximumSeconds;policy.maximumWarpJacobianDeviation=0.03
            if let value=input.lambdaY {policy.lambdaY=value}
            if let value=input.lambdaC {policy.lambdaC=value}
            try policy.validate()
            let frames=try input.frames.map{try upload($0,width:input.width,height:input.height,device:device)}
            let scratch=try F5MetalScratch(width:input.width,height:input.height,coreSize:policy.blockSize,device:device)
            let lookup=try F5MetalLikelihood(uniforms:.init(layout:.zero,domain:SIMD4(0,1,-16,1),width:.zero,limits:SIMD4(100000,0,0,0)),table:device.upload([Float](repeating:0,count:4),label:"Literal PG, no lookup/normal approximation"))
            let nodes=((input.width+31)/32+1)*((input.height+31)/32+1)
            let offsets=input.frames.flatMap{Array(repeating:SIMD2<Float>($0.translation[0],$0.translation[1]),count:nodes)}
            let motion=try device.upload(offsets,label:"Estimated main-frame motion"),direction=try device.upload([SIMD2<Float>](repeating:.zero,count:nodes*5),label:"Joint motion increments")
            let bounds=input.frames.map{SIMD4($0.translation[0]-2,$0.translation[1]-2,$0.translation[0]+2,$0.translation[1]+2)}
            let coefficients=try device.allocate(input.width*input.height*3*4,label:"Native diagnostic spline"),noise=try device.allocate(input.width*input.height*4,label:"Native noise scale")
            let reference=frames[input.reference]
            try device.run {command in
                try device.encode("f5_initialize_native",count:input.width*input.height,buffers:[reference.raw.metal,reference.table.metal,coefficients.metal,noise.metal],command:command) {
                    F5MetalDevice.value(reference.uniforms,at:4,encoder:$0)
                }
            }
            let native=F5MetalLevel(width:input.width,height:input.height,scale:1,reference:input.reference,policy:policy,device:device,frames:frames,scratch:scratch,likelihood:lookup,
                coefficients:coefficients,noise:noise,motion:motion,motionDirection:direction,motionBounds:bounds,validEventCount:input.width*input.height*4)
            var steps: [F5SolverStepDiagnostic] = []
            let recordStep: (F5SolverStepDiagnostic) -> Void = { step in
                steps.append(step)
                if let bytes = try? JSONEncoder().encode(step), let text = String(data:bytes,encoding:.utf8) { fputs(text+"\n",stderr) }
            }
            native.stepDiagnostic = recordStep
            guard input.geometryMode==nil || ["joint","image_first","fixed_control"].contains(input.geometryMode!) else {throw F5Failure(.damagedBundle,"Unknown diagnostic geometry mode.")}
            native.refineGeometryAfterImage=input.geometryMode=="image_first"
            native.fixedGeometryControl=input.geometryMode=="fixed_control"
            native.localStepLimit=input.localStepLimit ?? false
            native.feasibleGradientFallback=input.feasibleGradientFallback ?? false
            native.parallelMotion=input.parallelMotion ?? true
            if input.colorGuide == true {try native.freezeColorAxis(adaptive:input.adaptiveColorGuide ?? false,flatPriorBoost:input.flatPriorBoost ?? 1,protectFineDetail:input.protectFineDetail ?? false,harmonicPrior:input.harmonicPrior ?? false)}
            if let guide=input.priorGuide {try installPriorGuide(guide,input:input,level:native)}
            let initializerAlpha = input.cardinalInitialization == true ? try native.initializeCardinalReference(detailCorrection:input.malvarInitialization ?? false) : Float(0)
            if input.signalNoisePrior==true {try native.freezeNoiseScale()}
            let initialNoise=Array(UnsafeBufferPointer(start:native.noise.metal.contents().assumingMemoryBound(to:Float.self),count:input.width*input.height)).sorted()
            let initialRGB = try output(native,native:native,directory:directory,name:input.name+"-initial")
            let gw=(input.width+1)/2,gh=(input.height+1)/2,columns=(input.width+31)/32+1,rows=(input.height+31)/32+1
            let guideBuffer=try device.allocate(gw*gh*16,label:"Fixed reference guide for motion regularization")
            try device.run {command in
                try device.encode("f5_guide",count:gw*gh,buffers:[reference.raw.metal,reference.table.metal,guideBuffer.metal],command:command) {
                    F5MetalDevice.value(reference.uniforms,at:3,encoder:$0);F5MetalDevice.value(SIMD4<UInt32>(UInt32(gw),UInt32(gh),2,0),at:4,encoder:$0)
                }
            }
            let guide=guideBuffer.metal.contents().assumingMemoryBound(to:SIMD4<Float>.self)
            func pixel(_ x:Int,_ y:Int)->Float {guide[min(gh-1,max(0,y))*gw+min(gw-1,max(0,x))].x}
            var gradients=[Float](repeating:0,count:nodes)
            for y in 0..<rows {for x in 0..<columns {
                let u=x*16,v=y*16;gradients[y*columns+x]=hypot(pixel(u+1,v)-pixel(u-1,v),pixel(u,v+1)-pixel(u,v-1))/2
            }}
            let sorted=gradients.sorted(),noiseFloor=sqrt(max(1e-12,guide[gw*gh/2].y))
            let g90=max(noiseFloor,sorted[min(sorted.count-1,Int(Double(sorted.count-1)*0.9))])
            let weights=gradients.map{0.05+0.95*exp(-$0*$0/(g90*g90))}
            native.motionEdgeWeights=try device.upload(Array(repeating:weights,count:5).flatMap{$0},label:"Fixed guide edge weights")
            _ = try native.countEvents()
            let begin=ProcessInfo.processInfo.systemUptime,deadline=begin+input.maximumSeconds
            let nativeEpochs=try native.solve(epoch:0,budgetExpired:{ProcessInfo.processInfo.systemUptime>=deadline},progress:{value in
                fputs("\(input.name) native \(Int(value*100))%\n",stderr)
            })
            guard nativeEpochs.contains(where:{!$0.objectives.isEmpty}) else {throw F5Failure(.budgetStop,"No validated native diagnostic iterate.")}
            var report:[String:Any]=["revision":"f5-desktop-quality-v1","synthetic":input.synthetic,"qualification":"UNQUALIFIED_DIAGNOSTIC",
                "input_sha256":F5Hash.data(data),"decoder":F5Version.decoder,"name":input.name,"used_frames":input.frames.filter(\.used).map(\.index),
                "shader_sha256":try F5Hash.file(shader),"executable_sha256":try F5Hash.file(URL(fileURLWithPath:CommandLine.arguments[0])),
                "policy":try JSONSerialization.jsonObject(with:F5Hash.json(policy)),
                "prior_variant":input.colorGuide == true ? "f5-frozen-color-axis-experiment-v1" : "f5-fixed-opponent-v1",
                "adaptive_color_guide":input.adaptiveColorGuide ?? false,
                "flat_prior_boost":input.flatPriorBoost ?? 1,
                "geometry_mode":input.geometryMode ?? "joint",
                "malvar_initialization":input.malvarInitialization ?? false,
                "protect_fine_detail":input.protectFineDetail ?? false,
                "local_step_limit":input.localStepLimit ?? false,
                "feasible_gradient_fallback":input.feasibleGradientFallback ?? false,
                "parallel_motion":native.parallelMotion,
                "harmonic_prior":input.harmonicPrior ?? false,
                "prior_guide":input.priorGuide?.revision ?? "reference_guide",
                "native_noise_scale":["method":input.signalNoisePrior==true ? "frozen_initial_information_density" : "read_noise_floor",
                    "minimum":initialNoise.first!,"median":initialNoise[initialNoise.count/2],"maximum":initialNoise.last!],
                "initial_rgb":initialRGB,
                "cardinal_initialization_fraction":initializerAlpha,
                "native_epochs":try JSONSerialization.jsonObject(with:F5Hash.json(nativeEpochs)),"native_stop":nativeEpochs.last?.stopReason ?? "UNKNOWN",
                "native_rgb":try output(native,native:native,directory:directory,name:input.name+"-metal-native")]
            let reportURL=directory.appendingPathComponent(input.name+"-metal-report.json")
            if input.exportState==true {
                report["native_state"]=try state(native,directory:directory,name:input.name)
                report["native_pixel_rgb"]=try write(sampledBuffer(native,native:native,sampling:1),width:input.width,height:input.height,directory:directory,name:input.name+"-native-pixels")
            }
            if input.localDenoise==true {report["denoised_native_rgb"]=try denoisedOutput(native,directory:directory,name:input.name+"-metal-native-dct")}
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL,options:.atomic)
            if input.attemptHigh != false && (nativeEpochs.last?.stopReason=="CONVERGED" || input.attemptHigh == true && nativeEpochs.last?.stopReason != "NUMERICAL_STALL") {
                try native.freezeNoiseScale()
                let highCoefficients=try device.allocate(input.width*input.height*12*4,label:"2x diagnostic spline")
                var grid=native.uniforms;grid.step = .zero
                try device.run {command in
                    try device.encode("f5_initialize_high",count:input.width*input.height*12,buffers:[coefficients.metal,highCoefficients.metal,scratch.zero.metal],command:command) {F5MetalDevice.value(grid,at:3,encoder:$0)}
                }
                let highMotion=try device.allocate(motion.metal.length,label:"Independent diagnostic high-grid motion")
                let highDirection=try device.allocate(direction.metal.length,label:"Independent diagnostic high-grid step")
                try device.run {command in
                    try device.copy(motion.metal,to:highMotion.metal,bytes:motion.metal.length,command:command);try device.clear(highDirection.metal,command:command)
                }
                let high=F5MetalLevel(width:input.width,height:input.height,scale:2,reference:input.reference,policy:policy,device:device,frames:frames,scratch:scratch,likelihood:lookup,
                    coefficients:highCoefficients,noise:noise,motion:highMotion,motionDirection:highDirection,motionBounds:native.motionBounds,validEventCount:native.validEventCount)
                high.motionEdgeWeights=native.motionEdgeWeights
                high.colorAxis=native.colorAxis;high.colorAxisShape=native.colorAxisShape
                high.refineGeometryAfterImage=native.refineGeometryAfterImage;high.fixedGeometryControl=native.fixedGeometryControl
                high.stepDiagnostic=recordStep
                let highDeadline=ProcessInfo.processInfo.systemUptime+input.maximumSeconds
                let epochs=try high.solve(epoch:1,budgetExpired:{ProcessInfo.processInfo.systemUptime>=highDeadline},progress:{value in fputs("\(input.name) high \(Int(value*100))%\n",stderr)})
                report["high_epochs"]=try JSONSerialization.jsonObject(with:F5Hash.json(epochs));report["high_stop"]=epochs.last?.stopReason ?? "UNKNOWN"
                if epochs.last?.stopReason=="CONVERGED" {report["high_rgb"]=try output(high,native:native,directory:directory,name:input.name+"-metal-high")}
                else if input.attemptHigh == true,epochs.contains(where:{!$0.objectives.isEmpty}) {
                    // Explicitly retained for algorithm development. This is
                    // not a converged product image or a quality qualification.
                    do {report["high_diagnostic_rgb"]=try output(high,native:native,directory:directory,name:input.name+"-metal-high-unconverged")}
                    catch {report["high_diagnostic_error"]=error.localizedDescription}
                }
            } else {report["high_stop"]="NOT_ATTEMPTED_NATIVE_NOT_CONVERGED"}
            report["seconds"]=ProcessInfo.processInfo.systemUptime-begin;report["peak_allocated_bytes"]=device.peakBytes
            report["solver_steps"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(steps))
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL,options:.atomic)
            print(reportURL.path)
        } catch {fputs("Desktop quality experiment: \(error.localizedDescription)\n",stderr);exit(1)}
    }
}
