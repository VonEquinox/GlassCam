import CF5
import Foundation
import Metal

func require(_ ok: Bool, _ message: String) throws { if !ok { throw NSError(domain:"F5Test",code:1,userInfo:[NSLocalizedDescriptionKey:message]) } }

@main struct F5MetalNumerics {
    static func main() throws {
        fputs("F5 GPU test: compile library\n",stderr)
        let shader = URL(fileURLWithPath: CommandLine.arguments[1])
        let device = try F5MetalDevice(maximumBytes: 256*1024*1024,shaderURL:shader,isCancelled:{false})
        let width = 14, height = 10, scale = 2, n = width*height*3
        let coefficients = (0..<n).map { Float(0.3 + 0.15*sin(Double($0)*0.137)) }
        let x = try device.upload(coefficients,label:"signed test coefficients")
        let positions: [SIMD4<Float>] = [.init(0,0,0,0),.init(0.5,0.5,1,0),.init(6.99,4.99,2,0),.init(3.13,2.76,0,0),.init(1.21,3.89,2,0)]
        let points = try device.upload(positions,label:"independent subpixel positions")
        let output = try device.allocate(positions.count*16,label:"operator samples"), zero = try device.upload([Float](repeating:0,count:16),label:"zero")
        let g = F5GPUGrid(shape:.init(UInt32(width/scale),UInt32(height/scale),UInt32(scale),1),core:.init(0,0,UInt32(width),UInt32(height)),field:.zero,counts:.zero,bin:.init(0,0,2,2),objective:.zero,regularizer:.zero,step:.zero,options:.zero)
        try device.run { command in try device.encode("f5_probe_operator",count:positions.count,buffers:[x.metal,points.metal,output.metal,zero.metal],command:command) { e in F5MetalDevice.value(g,at:4,encoder:e);F5MetalDevice.value(UInt32(positions.count),at:5,encoder:e) } }
        fputs("F5 GPU test: operator completed\n",stderr)
        let samples = output.metal.contents().bindMemory(to:SIMD4<Float>.self,capacity:positions.count)
        let doubleCoefficients = coefficients.map(Double.init)
        var maximum = 0.0
        for i in positions.indices {
            var value = 0.0, dx = 0.0, dy = 0.0
            let status = doubleCoefficients.withUnsafeBufferPointer { f5_reference_sample($0.baseAddress,Int32(width),Int32(height),Int32(scale),Double(positions[i].x),Double(positions[i].y),Int32(positions[i].z),&value,&dx,&dy) }
            try require(status==0,"CPU reference sample failed")
            maximum=max(maximum,abs(Double(samples[i].x)-value),abs(Double(samples[i].y)-dx),abs(Double(samples[i].z)-dy))
        }
        try require(maximum<1e-5,"FP32 spline/derivative differs from FP64: \(maximum)")
        let inverseOutput=try device.allocate(n*4,label:"Spline inverse result"),recurrence=try device.allocate(n*4,label:"Spline inverse recurrence")
        for interior in [false,true] {for axis:UInt32 in [0,1] {
            let core=SIMD4<UInt32>(interior ? 3:0,interior ? 2:0,UInt32(width),UInt32(height))
            let shape=SIMD4<UInt32>(UInt32(interior ? width+6:width),UInt32(interior ? height+4:height),1,1)
            try device.run {command in
                try device.encode("f5_spline_inverse",count:(axis==0 ? height:width)*3,buffers:[x.metal,inverseOutput.metal,recurrence.metal],command:command) {e in
                    F5MetalDevice.value(core,at:3,encoder:e);F5MetalDevice.value(shape,at:4,encoder:e);F5MetalDevice.value(axis,at:5,encoder:e)
                }
            }
            let solved=inverseOutput.metal.contents().assumingMemoryBound(to:Float.self)
            var worst=0.0
            for c in 0..<3 {for y in 0..<height {for x in 0..<width {
                let i=(c*height+y)*width+x,position=axis==0 ? x:y,length=axis==0 ? width:height,stride=axis==0 ? 1:width
                let diagonal=4+(!interior && position==0 ? 1:0)+(!interior && position==length-1 ? 1:0)
                var recovered=Double(diagonal)*Double(solved[i])
                if position>0 {recovered+=Double(solved[i-stride])}
                if position+1<length {recovered+=Double(solved[i+stride])}
                worst=max(worst,abs(recovered/6-Double(coefficients[i])))
            }}}
            try require(worst<2e-7,"Spline preconditioner does not invert the conditional three-tap matrix")
        }}
        fputs("F5 GPU test: operator matched\n",stderr)
        try physicalStep(device)
        var events:[F5GPUEvent]=[],means:[Float]=[]
        for mean:Float in [0.0001,0.001,0.03,0.2,0.5] { for kind:UInt32 in [0,1,2] {
            let lo:Float=kind==0 ? mean-0.004 : 0.2, hi:Float=kind==0 ? mean+0.004 : 0.02
            events.append(.init(at:.zero,interval:.init(lo,hi,0.01,0.015),score:.zero,info:.init(0,0,0,kind),source:.init(1/16384,0,0,0)));means.append(mean)
        } }
        for mean:Float in [0.0001,0.1,0.9] {for width:Float in [1/65023,1e-8] {
            events.append(.init(at:.init(0,0,1,width),interval:.init(mean-width/2,mean+width/2,0.01,0.015),score:.zero,
                info:.init(0,0,0,0),source:.init(1/65536,0,0,0)));means.append(mean)
        }}
        // The real retained burst has thousands of electrons in bright areas
        // and much narrower code intervals than the original small fixtures.
        for mean:Float in [0.000001,0.0001,0.001,0.01,0.1,0.5,1.2] {for residual:Float in [-6,-2,0,2,6] {
            let k:Float=0.00010030885,s:Float=0.0005210402,width:Float=1/(4*3567)
            let center=mean+residual*sqrt(k*mean+s*s)
            events.append(.init(at:.init(0,0,1,width),interval:.init(center-width/2,center+width/2,k,s),score:.zero,
                info:.init(0,0,0,0),source:.init(1/16384,0,0,0)));means.append(mean)
        }}
        let eb=try device.upload(events,label:"PG events"),mb=try device.upload(means,label:"PG predicted means"),out=try device.allocate(events.count*16,label:"PG results")
        let lut=F5GPULUT(layout:.zero,domain:.init(0,1,-16,1),width:.zero,limits:.init(100000,0,0,0))
        try device.run { command in try device.encode("f5_probe_likelihood",count:events.count,buffers:[eb.metal,mb.metal,out.metal],command:command) { e in F5MetalDevice.value(lut,at:3,encoder:e);e.setBuffer(zero.metal,offset:0,index:4);F5MetalDevice.value(UInt32(events.count),at:5,encoder:e) } }
        fputs("F5 GPU test: likelihood completed\n",stderr)
        let results=out.metal.contents().bindMemory(to:SIMD4<Float>.self,capacity:events.count)
        var nllError=0.0,scoreError=0.0
        for i in events.indices {
            let e=events[i];var reference=F5LikelihoodValue()
            let center=Double((e.interval.x+e.interval.y)/2)
            let lower=e.at.w>0 ? center-Double(e.at.w)/2 : Double(e.interval.x),upper=e.at.w>0 ? center+Double(e.at.w)/2 : Double(e.interval.y)
            let status=f5_pg_event(.init(lower:lower,upper:upper,kappa:Double(e.interval.z),read_sigma:Double(e.interval.w),uniform_probability:1/16384,kind:e.info.w),Double(means[i]),&reference)
            try require(status==0,"Exact PG reference failed")
            let ne=abs(Double(results[i].x)-reference.nll),se=abs(Double(results[i].y)-reference.score)*sqrt(Double(e.interval.z*means[i]+e.interval.w*e.interval.w))
            if ne>1e-4 || se>1e-3 { print("PG mismatch",i,"mean",means[i],"kind",e.info.w,"GPU",results[i],"CPU",reference,"errors",ne,se) }
            nllError=max(nllError,ne);scoreError=max(scoreError,se)
        }
        try require(nllError<1e-4&&scoreError<1e-3,"PG CPU/GPU certificate failed")
        print("F5 Metal spline max error",maximum,"PG NLL error",nllError,"standardized score error",scoreError)
    }
    static func physicalStep(_ device:F5MetalDevice) throws {
        let width=12,height=10,n=width*height*3
        for scale in [1,2] {for interior in [false,true] {
            let ox=interior ? 2:0,oy=interior ? 2:0,cw=interior ? width-4:width,ch=interior ? height-4:height
            var coefficients=[Float](repeating:0.2,count:n),full=[Float](repeating:0,count:n),local:[Float]=[]
            for y in 0..<3 {for x in 0..<3 {coefficients[y*width+x]=2e-6}}
            coefficients[n-1] = -0.01
            for c in 0..<3 {for y in oy..<oy+ch {for x in ox..<ox+cw {
                let i=(c*height+y)*width+x,v=Float(sin(Double(i)*0.37)-0.2);full[i]=v;local.append(v)
            }}}
            let points:[SIMD4<Float>]=[.init(0.17,0.83,0,0),.init(Float(width)/Float(scale)-0.18,Float(height)/Float(scale)-0.13,2,0),.init(2.37/Float(scale),2.29/Float(scale),1,0)]
            let events=points.map{F5GPUEvent(at:SIMD4($0.x,$0.y,1,0),interval:.zero,score:.zero,info:SIMD4(UInt32($0.z),0,0,0),source:.zero)}
            let cpuPoints=points.map{F5InformationSample(x:Double($0.x),y:Double($0.y),gain:1,mean:0,dx:0,dy:0,curvature:0,color:UInt32($0.z),phase:0,frame:0,kind:0)}
            let cb=try device.upload(coefficients,label:"Constraint signed coefficients"),db=try device.upload(local,label:"Constraint proposed step")
            let eb=try device.upload(events,label:"Constraint subpixel samples"),limits=try device.allocate(local.count*4,label:"Constraint local limits")
            let grid=F5GPUGrid(shape:SIMD4(UInt32(width/scale),UInt32(height/scale),UInt32(scale),0),core:SIMD4(UInt32(ox),UInt32(oy),UInt32(cw),UInt32(ch)),
                field:SIMD4(0,0,Int32(width),Int32(height)),counts:SIMD4(UInt32(events.count),0,0,0),bin:.zero,objective:.zero,regularizer:.zero,step:SIMD4(0,1,0,0),options:.zero)
            try device.run {command in
                try device.encode("f5_step_limit_initialize",count:local.count,buffers:[limits.metal],command:command) {F5MetalDevice.value(UInt32(local.count),at:1,encoder:$0)}
                try device.encode("f5_step_limit_physical",count:width*height*3+events.count,buffers:[cb.metal,db.metal,eb.metal,limits.metal],command:command) {F5MetalDevice.value(grid,at:4,encoder:$0)}
                try device.encode("f5_step_limit_apply",count:local.count,buffers:[db.metal,limits.metal],command:command) {F5MetalDevice.value(UInt32(local.count),at:2,encoder:$0)}
            }
            var expected=[Double](repeating:0,count:n)
            let status=coefficients.map(Double.init).withUnsafeBufferPointer {c in full.map(Double.init).withUnsafeBufferPointer {d in
                cpuPoints.withUnsafeBufferPointer {p in f5_reference_limit_direction(c.baseAddress,d.baseAddress,&expected,Int32(width/scale),Int32(height/scale),Int32(scale),p.baseAddress,p.count)}
            }}
            try require(status==0,"Independent physical-step reference failed")
            let actual=db.metal.contents().assumingMemoryBound(to:Float.self);var error=0.0,index=0
            for c in 0..<3 {for y in oy..<oy+ch {for x in ox..<ox+cw {
                error=max(error,abs(Double(actual[index])-expected[(c*height+y)*width+x]));index+=1
            }}}
            try require(error<2e-6,"Physical step differs from FP64, scale \(scale), interior \(interior): \(error)")
            print("F5 local physical step",scale,interior,"FP64 error",error)
        }}
    }
}
