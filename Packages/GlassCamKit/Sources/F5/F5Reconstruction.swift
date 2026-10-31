import ImagingCore
import Capture
import CF5
import Foundation
import Metal
import simd

struct F5CaptureProvenance: Codable, CaptureProvenance {
    func resolutionDescription(width: Int, height: Int) -> String {
        String(format: "%@ · %d RAW · Output %.1f MP", frameSHA256.count == 1 ? "Speed" : "Balanced", frameSHA256.count, Double(width * height) / 1_000_000)
    }
    let decodeRevision: String, colorBridgeRevision: String, profileSHA256: String, referenceFrameID: String
    let inputWidth: Int, inputHeight: Int, frameSHA256: [String], actualExposures: [Double]
    let whiteBalanceOwner: String, transformSHA256: String
    let qualityClassCounts: [String: Int], flags: [F5Code], solveStatus: String
}

struct F5InitialGeometry {
    let reference: Int
    let motion, direction, edgeWeights: F5MetalBuffer
    let bounds: [SIMD4<Float>], alignments: [F5AlignmentValue]
    let referenceQualified: Bool
}

enum F5GeometryInitializer {
    static func make(frames: [F5MetalFrame], manifest: F5BurstManifest, profile: F5DeviceProfile,
                     device: F5MetalDevice) throws -> F5InitialGeometry {
        let width=Int(frames[0].uniforms.active.z),height=Int(frames[0].uniforms.active.w)
        let fineWidth=(width+1)/2,fineHeight=(height+1)/2
        var guides:[F5MetalBuffer]=[],guideInputs:[F5GuideInput]=[],sharpness=[Double](repeating:-1,count:5)
        var step=1
        while max(fineWidth,fineHeight)/step>512 {step*=2}
        let guideWidth=(fineWidth+step-1)/step,guideHeight=(fineHeight+step-1)/step
        for (index,frame) in frames.enumerated() {
            try autoreleasepool {
                let fine=try device.allocate(fineWidth*fineHeight*16,label:"F5 half-density initialization guide")
                let scores=try device.allocate(((fineWidth+15)/16)*((fineHeight+15)/16)*8,label:"F5 noise-corrected reference sharpness")
                let small=try device.allocate(guideWidth*guideHeight*16,label:"F5 motion pyramid input")
                try device.run { command in
                    try device.encode("f5_guide",count:fineWidth*fineHeight,buffers:[frame.raw.metal,frame.table.metal,fine.metal],command:command) { e in
                        F5MetalDevice.value(frame.uniforms,at:3,encoder:e);F5MetalDevice.value(SIMD4<UInt32>(UInt32(fineWidth),UInt32(fineHeight),2,0),at:4,encoder:e)
                    }
                    try device.encode("f5_guide_sharpness",count:scores.metal.length/8,buffers:[fine.metal,scores.metal],command:command) { e in F5MetalDevice.value(SIMD4<UInt32>(UInt32(fineWidth),UInt32(fineHeight),2,0),at:2,encoder:e) }
                    try device.encode("f5_down_guide",count:guideWidth*guideHeight,buffers:[fine.metal,small.metal],command:command) { e in
                        F5MetalDevice.value(SIMD4<UInt32>(UInt32(fineWidth),UInt32(fineHeight),UInt32(step),0),at:2,encoder:e)
                        F5MetalDevice.value(SIMD2<UInt32>(UInt32(guideWidth),UInt32(guideHeight)),at:3,encoder:e)
                    }
                }
                let values=scores.metal.contents().bindMemory(to:SIMD2<Float>.self,capacity:scores.metal.length/8)
                let usable=(0..<(scores.metal.length/8)).map{Double(values[$0].x)}.filter{$0.isFinite && $0>=0}.sorted()
                if !usable.isEmpty {sharpness[index]=usable[usable.count/2]}
                guides.append(small)
                guideInputs.append(F5GuideInput(rgba:small.metal.contents().assumingMemoryBound(to:Float.self),width:UInt32(guideWidth),height:UInt32(guideHeight),pixel_size:Double(step*2)))
            }
        }
        let framesByIndex=manifest.frames.sorted{$0.burstIndex<$1.burstIndex},times=framesByIndex.map(\.timestamp)
        let center=((times.min() ?? 0)+(times.max() ?? 0))/2
        let qualified=[0,1,3,4].filter{sharpness[$0]>=profile.policy.minimumReferenceSharpness}
        let pool=qualified.isEmpty ? [0,1,3,4] : qualified
        let reference=pool.sorted {a,b in
            let da=abs(times[a]-center),db=abs(times[b]-center)
            if abs(da-db)>1e-9{return da<db};if sharpness[a] != sharpness[b]{return sharpness[a]>sharpness[b]};return times[a]<times[b]
        }[0]
        var selected=Int32(reference),alignments=[F5AlignmentValue](repeating:F5AlignmentValue(),count:5)
        let status=guideInputs.withUnsafeBufferPointer { input in times.withUnsafeBufferPointer { timestamps in
            alignments.withUnsafeMutableBufferPointer { output in f5_align(input.baseAddress,timestamps.baseAddress,profile.policy.minimumReferenceSharpness,&selected,output.baseAddress) }
        } }
        guard status==0 else {throw F5Failure(.ambiguousRegistration,"The five guide pyramids could not be registered.")}
        let columns=(width+31)/32+1,rows=(height+31)/32+1,count=columns*rows
        var nodes=[SIMD2<Float>](repeating:.zero,count:count*5),bounds:[SIMD4<Float>]=[]
        for frame in 0..<5 {
            var a=alignments[frame].affine
            let affine=withUnsafeBytes(of:&a){Array($0.bindMemory(to:Double.self))}
            var lower=SIMD2<Float>(repeating:.infinity),upper=SIMD2<Float>(repeating:-.infinity)
            for y in 0..<rows {for x in 0..<columns {
                let px=Double(x*32),py=Double(y*32)
                let value:SIMD2<Float>=frame==reference ? .zero : SIMD2(Float(affine[0]*px+affine[1]*py+affine[2]-px),Float(affine[3]*px+affine[4]*py+affine[5]-py))
                guard value.x.isFinite,value.y.isFinite,abs(value.x)<Float(width),abs(value.y)<Float(height) else {throw F5Failure(.ambiguousRegistration,"Registration left the sensor field.")}
                nodes[frame*count+y*columns+x]=value;lower=simd_min(lower,value);upper=simd_max(upper,value)
            }}
            bounds.append(SIMD4(lower.x,lower.y,upper.x,upper.y))
        }
        let guide=guides[reference].metal.contents().bindMemory(to:SIMD4<Float>.self,capacity:guideWidth*guideHeight)
        func pixel(_ x:Int,_ y:Int)->Float {guide[min(guideHeight-1,max(0,y))*guideWidth+min(guideWidth-1,max(0,x))].x}
        var gradients=[Float](repeating:0,count:count)
        for y in 0..<rows {for x in 0..<columns {
            let u=x*32/(step*2),v=y*32/(step*2)
            gradients[y*columns+x]=hypot(pixel(u+1,v)-pixel(u-1,v),pixel(u,v+1)-pixel(u,v-1))/2
        }}
        let sorted=gradients.sorted(),noiseFloor=sqrt(max(1e-12,guide[guideWidth*guideHeight/2].y))
        let g90=max(noiseFloor,sorted[min(sorted.count-1,Int(Double(sorted.count-1)*0.9))])
        let weights=gradients.map{0.05+0.95*exp(-$0*$0/(g90*g90))}
        return try .init(reference:reference,motion:device.upload(nodes,label:"F5 shared motion nodes"),
            direction:device.upload([SIMD2<Float>](repeating:.zero,count:nodes.count),label:"F5 feasible motion increment"),
            edgeWeights:device.upload(Array(repeating:weights,count:5).flatMap{$0},label:"F5 fixed guide edge weights"),
            bounds:bounds,alignments:alignments,referenceQualified:!qualified.isEmpty)
    }
}

extension F5MetalLevel {
    func quality(alignments: [F5AlignmentValue], requireConvergence: Bool, frozenExclusions:[[Int]]?=nil) throws -> [F5QualityReport.Tile] {
        let columns=(width+31)/32,rows=(height+31)/32,total=columns*rows,capacity=min(64,total)
        let samples=try device.allocate(capacity*120*MemoryLayout<F5GPUEvent>.stride,label:"F5 stratified information samples")
        let summaries=try device.allocate(capacity*5*2*16,label:"F5 quality summaries")
        let hypothesisScores=try device.allocate(capacity*5*16,label:"F5 frozen-image hypothesis likelihoods")
        var offsets:[SIMD2<Float>]=[]
        for alignment in alignments {
            var peaks=alignment.hypotheses
            let values=withUnsafeBytes(of:&peaks){Array($0.bindMemory(to:Double.self))}
            offsets += (0..<3).map{SIMD2(Float(values[$0*2]-values[0]),Float(values[$0*2+1]-values[1]))}
        }
        let hypotheses=try device.upload(offsets,label:"F5 three retained registration hypotheses")
        var result:[F5QualityReport.Tile]=[]
        for start in stride(from:0,to:total,by:capacity) {
            let count=min(capacity,total-start),batch=SIMD4<UInt32>(UInt32(columns),UInt32(rows),UInt32(start),UInt32(count))
            try prepare(tiles[0],tau:1e-8)
            try device.run { command in
                for frame in 0..<5 {
                    var g=uniforms;g.options.w=UInt32(frame);g.step = .zero
                    try device.encode("f5_quality_samples",count:count*24,buffers:[frames[frame].raw.metal,frames[frame].table.metal,coefficients.metal,motion.metal,motionDirection.metal,samples.metal],command:command) { e in
                        F5MetalDevice.value(frames[frame].uniforms,at:6,encoder:e);F5MetalDevice.value(g,at:7,encoder:e);F5MetalDevice.value(batch,at:8,encoder:e)
                        F5MetalDevice.value(likelihood.uniforms,at:9,encoder:e);e.setBuffer(likelihood.table.metal,offset:0,index:10);e.setBuffer(scratch.zero.metal,offset:0,index:11)
                        e.setBuffer(frames[frame].eligibility.metal,offset:0,index:12)
                    }
                    try device.encode("f5_quality_summary",count:count*256,buffers:[frames[frame].raw.metal,frames[frame].table.metal,coefficients.metal,motion.metal,motionDirection.metal,summaries.metal],command:command) { e in
                        F5MetalDevice.value(frames[frame].uniforms,at:6,encoder:e);F5MetalDevice.value(g,at:7,encoder:e);F5MetalDevice.value(batch,at:8,encoder:e)
                        F5MetalDevice.value(motionBounds[frame],at:9,encoder:e);e.setBuffer(scratch.zero.metal,offset:0,index:10)
                        e.setBuffer(frames[frame].eligibility.metal,offset:0,index:11)
                    }
                }
                var g=uniforms;g.step = .zero
                try device.encode("f5_hypothesis_scores",count:count*5,
                    buffers:[samples.metal,coefficients.metal,hypotheses.metal,hypothesisScores.metal,scratch.zero.metal],command:command) { e in
                    F5MetalDevice.value(g,at:5,encoder:e);F5MetalDevice.value(UInt32(count*5),at:6,encoder:e)
                    F5MetalDevice.value(likelihood.uniforms,at:7,encoder:e);e.setBuffer(likelihood.table.metal,offset:0,index:8)
                }
            }
            let sampleValues=samples.metal.contents().bindMemory(to:F5GPUEvent.self,capacity:count*120)
            let summary=summaries.metal.contents().bindMemory(to:SIMD4<Float>.self,capacity:count*10)
            let sigma=noise.metal.contents().bindMemory(to:Float.self,capacity:width*height)
            let nodes=motion.metal.contents().bindMemory(to:SIMD2<Float>.self,capacity:meshColumns*meshRows*5)
            let rawScores=hypothesisScores.metal.contents().bindMemory(to:SIMD4<Float>.self,capacity:count*5)
            for index in 0..<count {
                let tile=start+index,x=(tile%columns)*32,y=(tile/columns)*32
                var intervals=[Double](repeating:0,count:5),upper=intervals,lower=intervals,flags:[F5Code]=[]
                var squared=0.0,eventCount=0.0,validMains=0.0,validShort=0.0
                var excluded=Set(frozenExclusions?[tile] ?? []), reliableCompanions=0,newFailure=false
                func reject(_ frame:Int) {
                    if frozenExclusions==nil {excluded.insert(frame)}
                    else if !excluded.contains(frame) {newFailure=true}
                }
                var gaps=[Double](repeating:0,count:5)
                for frame in 0..<5 {
                    let counts=summary[(index*5+frame)*2],metrics=summary[(index*5+frame)*2+1]
                    if counts.x>0 {intervals[frame]=Double(counts.y/counts.x);upper[frame]=Double(counts.z/counts.x);lower[frame]=Double(counts.w/counts.x)}
                    if frame != reference {
                        let scores=rawScores[index*5+frame]
                        gaps[frame]=scores.w>=8 ? Double(min(scores.y,scores.z)-scores.x) : 0
                        if gaps[frame]<policy.ambiguityNLLGap {flags.append(.ambiguousRegistration);reject(frame)}
                        if alignments[frame].cycle_error>policy.maximumCycleError {flags.append(.occlusion);reject(frame)}
                    }
                    if metrics.w>16,abs(Double(metrics.z/metrics.w))>policy.maximumResidualSigma {
                        flags.append(.flicker);if frame != reference {reject(frame)}
                    }
                    if !excluded.contains(frame) {
                        squared+=Double(metrics.x);eventCount+=Double(metrics.y)
                        if frame==2{validShort+=Double(counts.y)}else{validMains+=Double(counts.y)}
                        if frame != reference && counts.y>0 { reliableCompanions+=1 }
                    }
                }
                var inputs:[F5InformationSample]=[]
                var seen=Set<UInt64>()
                for j in 0..<120 {
                    let e=sampleValues[index*120+j]
                    guard e.info.w<3,!excluded.contains(Int(e.info.z)),e.score.x.isFinite,e.score.y.isFinite,e.score.z.isFinite,e.score.w.isFinite else {continue}
                    let key=(UInt64(e.info.z)<<40)|(UInt64(e.source.z)<<20)|UInt64(e.source.y)
                    guard seen.insert(key).inserted else {continue}
                    inputs.append(F5InformationSample(x:Double(e.at.x),y:Double(e.at.y),gain:Double(e.at.z),mean:Double(e.score.x),dx:Double(e.score.y),dy:Double(e.score.z),curvature:Double(e.score.w),color:e.info.x,phase:e.info.y,frame:e.info.z,kind:e.info.w))
                }
                var information=F5InformationResult()
                let noiseScale=Double(sigma[min(height-1,y+16)*width+min(width-1,x+16)])
                if !inputs.isEmpty {
                    let status=inputs.withUnsafeBufferPointer { f5_information($0.baseAddress,$0.count,noiseScale,Int32(reference),&information) }
                    guard status==0 else {throw F5Failure(.nonfinite,"Local conditional information is not finite.")}
                }
                let residual = eventCount > 0 ? sqrt(squared/eventCount) : 0
                var response=true
                for frame in 0..<5 where frame != reference && !excluded.contains(frame) {
                    let nx=min(meshColumns-2,x/32),ny=min(meshRows-2,y/32),base=(frame*meshRows+ny)*meshColumns+nx
                    let dx=(nodes[base+1]-nodes[base])/32,dy=(nodes[base+meshColumns]-nodes[base])/32
                    if max(abs(dx.x),abs(dx.y),abs(dy.x),abs(dy.y))>Float(policy.maximumWarpJacobianDeviation) {response=false}
                }
                if !response {flags.append(.responseModelMismatch)}
                var support:F5QualityReport.Support = .nativeFusion
                if validMains==0 && validShort==0 {support=eventCount>0 ? .highlightMissing : .invalid;flags.append(.highlightMissing)}
                else if reliableCompanions==0 {support = .referenceOnly}
                else if requireConvergence && !newFailure && response && !flags.contains(.flicker) && validMains>0 && residual<=policy.maximumResidualSigma && information.minimum>=policy.minimumModeInformation && information.condition<=policy.maximumModeCondition {support = .fullSR}
                if residual>policy.maximumResidualSigma {flags.append(.responseModelMismatch)}
                result.append(.init(x:x,y:y,width:min(32,width-x),height:min(32,height-y),support:support,
                    flags:Array(Set(flags)).sorted{$0.rawValue<$1.rawValue},validFractions:intervals,upperCensoredFractions:upper,lowerCensoredFractions:lower,
                    residualRMS:residual,minimumInformation:information.minimum,conditionNumber:information.condition,
                    shortOnly:validMains==0 && validShort>0,diagnosticSampleCount:inputs.count,motionInformationRank:Int(information.motion_rank),shortInformation:information.short_information,
                    excludedFrames:excluded.sorted(),registrationNLLGaps:gaps))
            }
        }
        return result
    }
    func reviseEligibility(_ quality: [F5QualityReport.Tile]) throws {
        let classes=quality.map { tile in tile.excludedFrames.reduce(UInt32(0)) { $0 | (1 << UInt32($1)) } }
        let map=try device.upload(classes,label:"F5 one-time eligibility revision")
        try prepare(tiles[0],tau:1e-8)
        try device.run { command in
            for frame in 0..<5 {
                var g=uniforms;g.options.w=UInt32(frame);g.step = .zero
                try device.encode("f5_set_eligibility",count:(width*height+31)/32,
                    buffers:[frames[frame].raw.metal,frames[frame].table.metal,motion.metal,motionDirection.metal,map.metal,frames[frame].eligibility.metal],command:command) { e in
                    F5MetalDevice.value(frames[frame].uniforms,at:6,encoder:e);F5MetalDevice.value(g,at:7,encoder:e)
                }
            }
        }
        _ = try countEvents()
    }
}
