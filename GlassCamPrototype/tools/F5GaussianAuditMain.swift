import Foundation
import Metal

/// A fixed-geometry Gaussian subproblem. The production gather, spline and
/// prior kernels are used unchanged; only observation scores are supplied by
/// an explicitly Gaussian diagnostic kernel. No camera or product path.
@main struct F5GaussianAuditMain {
    struct Observation:Decodable {let x:Float,y:Float,mean:Float,variance:Float,gain:Float,color:UInt32}
    struct Input:Decodable {
        let width:Int,height:Int,normalizationCount:Int,noise:Float,lambdaY:Float,lambdaC:Float
        let coefficients:[Float],direction:[Float],observations:[Observation]
    }
    static let gaussianKernel="""
    kernel void f5_audit_gaussian_scores(device const float *coefficients [[buffer(0)]],device const float *direction [[buffer(1)]],device F5Event *events [[buffer(2)]],constant F5Grid &g [[buffer(3)]],uint i [[thread_position_in_grid]]) {
        if(i>=g.counts.x)return;
        F5Event e=events[i];float4 v=f5sample(coefficients,direction,e.at.xy,e.info.x,g);
        float variance=e.interval.w*e.interval.w, residual=e.at.z*v.x-e.interval.x;
        e.score=float4(0.5f*residual*residual/variance,(g.step.y==1?e.at.z*v.w:residual)/variance,1/variance,1);
        events[i]=e;
    }
    """
    static func main() {
        do {
            guard CommandLine.arguments.count==4 else {throw F5Failure(.damagedBundle,"Usage: f5-gaussian-audit input.json output-directory F5Kernels.metal")}
            let inputURL=URL(fileURLWithPath:CommandLine.arguments[1]),folder=URL(fileURLWithPath:CommandLine.arguments[2]),base=URL(fileURLWithPath:CommandLine.arguments[3])
            let input=try JSONDecoder().decode(Input.self,from:Data(contentsOf:inputURL))
            let w=input.width,h=input.height,n=w*h*3,count=input.observations.count
            guard (4...64).contains(w),(4...64).contains(h),count>0,input.normalizationCount>0,input.noise>0,
                  input.coefficients.count==n,input.direction.count==n,input.observations.allSatisfy({$0.variance>0 && $0.gain>0 && $0.color<3}) else {throw F5Failure(.damagedBundle,"Invalid Gaussian diagnostic")}
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let shader=folder.appendingPathComponent("gaussian-audit.metal")
            try (String(contentsOf:base,encoding:.utf8)+"\n"+gaussianKernel).write(to:shader,atomically:true,encoding:.utf8)
            let device=try F5MetalDevice(maximumBytes:128*1024*1024,shaderURL:shader,isCancelled:{false})
            let coefficients=try device.upload(input.coefficients,label:"Frozen Gaussian image"),direction=try device.upload(input.direction,label:"Independent normal direction")
            let events=try device.upload(input.observations.map {o in
                F5GPUEvent(at:SIMD4(o.x,o.y,o.gain,1),interval:SIMD4(o.mean,o.mean,0,sqrt(o.variance)),score:.zero,info:SIMD4(o.color,o.color,0,0),source:SIMD4(1,o.x,o.y,1))
            },label:"Independent continuous Gaussian observations")
            let counts=try device.allocate((w+3)*(h+3)*4,label:"Bins"),entries=try device.allocate((w+3)*(h+3)*32*4,label:"Bin indices")
            let failure=try device.allocate(16,label:"Failure"),gradient=try device.allocate(n*4,label:"Gradient"),diagonal=try device.allocate(n*4,label:"Diagonal")
            let field=try device.allocate(w*h*16,label:"Native field"),delta=try device.allocate(w*h*16,label:"Native delta")
            let prior=try device.allocate(w*h*64,label:"Prior rows"),values=try device.allocate(w*h*4,label:"Prior values"),fieldGradient=try device.allocate(w*h*16,label:"Prior field gradient")
            let noise=try device.upload([Float](repeating:input.noise,count:w*h),label:"Fixed noise"),zero=try device.upload([Float](repeating:0,count:16),label:"No guide")
            var grid=F5GPUGrid(shape:SIMD4(UInt32(w),UInt32(h),1,1),core:SIMD4(0,0,UInt32(w),UInt32(h)),field:SIMD4(0,0,Int32(w),Int32(h)),
                counts:SIMD4(UInt32(count),UInt32(w+3),UInt32(h+3),32),bin:SIMD4(-2,-2,2,2),
                objective:SIMD4(Float(count),Float(input.normalizationCount)/Float(w*h),0,0),regularizer:SIMD4(input.lambdaY,input.lambdaC,0,0),step:.zero,options:.zero)
            try device.run {command in
                try device.clear(counts.metal,command:command);try device.clear(failure.metal,command:command)
                try device.encode("f5_build_bins",count:count,buffers:[events.metal,counts.metal,entries.metal,failure.metal],command:command){F5MetalDevice.value(grid,at:4,encoder:$0)}
                try device.encode("f5_sort_bins",count:(w+3)*(h+3),buffers:[counts.metal,entries.metal],command:command){F5MetalDevice.value(grid,at:2,encoder:$0)}
            }
            guard failure.metal.contents().load(as:UInt32.self)==0 else {throw F5Failure(.damagedBundle,"Diagnostic bin overflow")}
            func floats(_ buffer:F5MetalBuffer,_ count:Int)->[Float] {Array(UnsafeBufferPointer(start:buffer.metal.contents().assumingMemoryBound(to:Float.self),count:count))}
            var result:[String:Any]=["qualification":"FIXED_GAUSSIAN_SUBPROBLEM_NOT_PG","count":count,"normalization_count":input.normalizationCount]
            for mode in 0...1 {
                grid.step.y=Float(mode)
                try device.run {command in
                    try device.encode("f5_audit_gaussian_scores",count:count,buffers:[coefficients.metal,direction.metal,events.metal],command:command){F5MetalDevice.value(grid,at:3,encoder:$0)}
                    try device.encode("f5_data_gather",count:n,buffers:[events.metal,counts.metal,entries.metal,gradient.metal,diagonal.metal],command:command){F5MetalDevice.value(grid,at:5,encoder:$0)}
                }
                result[mode==0 ? "data_gradient":"data_normal"]=floats(gradient,n)
                if mode==0 {
                    let e=events.metal.contents().assumingMemoryBound(to:F5GPUEvent.self)
                    result["data_objective"]=(0..<count).reduce(0.0){$0+Double(e[$1].score.x)}
                    result["data_diagonal"]=floats(diagonal,n)
                }
                try device.run {command in
                    try device.clear(gradient.metal,command:command);try device.clear(diagonal.metal,command:command)
                    try device.encode("f5_sample_field",count:w*h,buffers:[coefficients.metal,direction.metal,noise.metal,field.metal,delta.metal],command:command){F5MetalDevice.value(grid,at:5,encoder:$0)}
                    try device.encode("f5_prior_rows",count:w*h,buffers:[field.metal,delta.metal,prior.metal,values.metal],command:command){e in F5MetalDevice.value(grid,at:4,encoder:e);e.setBuffer(zero.metal,offset:0,index:5);F5MetalDevice.value(SIMD4<UInt32>.zero,at:6,encoder:e)}
                    try device.encode("f5_prior_transpose",count:w*h,buffers:[prior.metal,field.metal,delta.metal,fieldGradient.metal],command:command){F5MetalDevice.value(grid,at:4,encoder:$0)}
                    try device.encode("f5_prior_gather",count:n,buffers:[fieldGradient.metal,prior.metal,field.metal,direction.metal,gradient.metal,diagonal.metal],command:command){F5MetalDevice.value(grid,at:6,encoder:$0)}
                }
                result[mode==0 ? "prior_gradient":"prior_normal"]=floats(gradient,n)
                if mode==0 {result["prior_objective"]=floats(values,w*h).reduce(0.0){$0+Double($1)};result["prior_diagonal"]=floats(diagonal,n)}
            }
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("result.json"),options:.atomic)
        } catch {fputs("Gaussian audit: \(error.localizedDescription)\n",stderr);exit(1)}
    }
}
