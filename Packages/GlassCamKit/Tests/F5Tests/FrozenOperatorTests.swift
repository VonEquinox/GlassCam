import Testing
import Foundation
import CF5
import Metal
@testable import F5

private struct FrozenMeasurements {
    let values: [String: Double]
    let statuses: [String: Int32]
    let cancelledSteps: [Bool]
    let cancelledImages: [(Data, Data)]
    let acceptedSteps: [Bool]
    let fallbackStatuses: [Int32]
    let objectives: [Double]
    let retainedFrames: [Bool]
    static let native = Result { try measure("native") }
    static let mapped = Result { try measure("mapped") }
    static let gain = Result { try measure("gain") }
    static func observation(_ mapping: String) throws -> Self {
        try (mapping == "mapped" ? mapped : mapping == "gain" ? gain : native).get()
    }
    static func measure(_ mapping: String) throws -> Self {
        let context = try F5TestContext(mapping: mapping)
        let fixture = context.fixture, shader = try F5TestContext.shader
        var values: [String: Double] = [:], statuses: [String: Int32] = [:]
        var cancelledSteps: [Bool] = [], acceptedSteps: [Bool] = [], retainedFrames: [Bool] = []
        var cancelledImages: [(Data, Data)] = [], fallbackStatuses: [Int32] = [], objectives: [Double] = []
        var initializationError = 0.0
        let width=8,height=6,scale=2,n=width*height*scale*scale*3
        let device=try F5MetalDevice(maximumBytes:256*1024*1024,shaderURL:shader,isCancelled:{false})
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
                initializationError = max(initializationError, abs(Double(initialized[(e.color*height+y)*width+x])-expected))
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
        values["trialNormal"] = zip(gpuNormal,afterTrial).map { Double(abs($0-$1)) }.max() ?? 0
        try level.prepare(SIMD4(0,0,16,12),tau:1e-6)
        _ = try level.evaluate(direction:db,mode:1)
        let reloaded=Array(UnsafeBufferPointer(start:scratch.fine.q.metal.contents().assumingMemoryBound(to:Float.self),count:n))
        values["reloadedNormal"] = zip(gpuNormal,reloaded).map { Double(abs($0-$1)) }.max() ?? 0
        _ = try level.evaluate()
        let excessive=try device.upload(d.map{$0*1000},label:"Direction blocked by physical intensities")
        try level.addLocalConstraintDamping(excessive)
        let guardedObjective=try level.evaluate()
        let guardedGradient=Array(UnsafeBufferPointer(start:scratch.fine.q.metal.contents().assumingMemoryBound(to:Float.self),count:n))
        values["dampedObjective"] = abs(guardedObjective-actual)
        values["dampedGradient"] = zip(gpuGradient,guardedGradient).map { Double(abs($0-$1)) }.max() ?? 0
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
        values["expectedDampingEnergy"] = expectedEnergy
        values["dampingEnergy"] = abs(actualEnergy-expectedEnergy)/expectedEnergy
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
        values["cachedMotion"] = sqrt(motionError/max(1e-30,motionNorm))
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
        statuses["objective"] = status
        func error(_ a:[Float],_ b:[Double])->Double {let numerator=zip(a,b).reduce(0.0){$0+pow(Double($1.0)-$1.1,2)},denominator=b.reduce(0.0){$0+$1*$1};return sqrt(numerator/max(1e-30,denominator))}
        let ge=error(gpuGradient,gradient),de=error(gpuDiagonal,diagonal),qe=error(gpuNormal,normal)
        print("F5 frozen objective GPU",actual,"CPU",objective,"gradient",ge,"Jacobi",de,"normal",qe)
        values["objective"] = abs(actual-objective)/max(1,abs(objective))
        values["gradient"] = ge; values["diagonal"] = de; values["normal"] = qe
        var tiledGradient=[Float](repeating:0,count:n),tiledObjective=0.0
        for tile:SIMD4<UInt32> in [SIMD4(8,8,8,4),SIMD4(0,0,8,8),SIMD4(0,8,8,4),SIMD4(8,0,8,8)] {
            try level.prepare(tile,tau:1e-6,globalObjective:true);tiledObjective += try level.evaluate()
            let local=scratch.fine.q.metal.contents().assumingMemoryBound(to:Float.self),pixels=Int(tile.z*tile.w)
            for c in 0..<3 {for y in 0..<Int(tile.w){for x in 0..<Int(tile.z){
                tiledGradient[(c*height*scale+Int(tile.y)+y)*width*scale+Int(tile.x)+x]=local[c*pixels+y*Int(tile.z)+x]
            }}}
        }
        values["tiledGradient"] = error(tiledGradient,gradient)
        values["tiledObjective"] = abs(tiledObjective-objective)/abs(objective)
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
        statuses["guided"] = guidedStatus
        values["guidedObjective"] = abs(guidedGPUObjective-guidedObjective)/abs(guidedObjective)
        values["guidedGradient"] = error(guidedGPUGradient,guidedGradient)
        values["guidedDiagonal"] = error(guidedGPUDiagonal,guidedDiagonal)
        values["guidedNormal"] = error(guidedGPUNormal,guidedNormal)
        print("F5 guided color prior GPU/FP64 gradient",error(guidedGPUGradient,guidedGradient),"normal",error(guidedGPUNormal,guidedNormal))
        level.colorAxis=nil;level.colorAxisShape = .zero
        // Verify the fallback against the independent full FP64 objective,
        // including a conditional tile and cancellation before any mutation.
        var previousObjective=objective
        objectives.append(objective)
        for tile:SIMD4<UInt32> in [SIMD4(0,0,16,12),SIMD4(4,4,8,6)] {
            try level.prepare(tile,tau:1e-6)
            let before=Data(bytes:cb.metal.contents(),count:n*4)
            cancelledSteps.append(try level.feasibleGradientStep(budgetExpired:{true}))
            cancelledImages.append((before, Data(bytes:cb.metal.contents(),count:n*4)))
            acceptedSteps.append(try level.feasibleGradientStep(budgetExpired:{false}))
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
            fallbackStatuses.append(nextStatus); objectives.append(nextObjective)
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
            retainedFrames.append(retained)
        }
        values["initialization"] = initializationError
        return FrozenMeasurements(values: values, statuses: statuses, cancelledSteps: cancelledSteps,
            cancelledImages: cancelledImages, acceptedSteps: acceptedSteps, fallbackStatuses: fallbackStatuses,
            objectives: objectives, retainedFrames: retainedFrames)
    }
}

@Suite(.serialized)
struct FrozenOperatorTests {
    // Bounds are the pre-refactor CPU/GPU certificate tolerances, unchanged.
    static let bounds: [(String, Double)] = [
        ("initialization", 2e-6), ("trialNormal", 1e-6), ("reloadedNormal", 1e-6),
        ("dampedObjective", 1e-6), ("dampedGradient", 1e-6), ("dampingEnergy", 1e-4),
        ("cachedMotion", 1e-5), ("objective", 1e-5), ("gradient", 1e-4), ("diagonal", 1e-4),
        ("normal", 1e-4), ("tiledGradient", 1e-4), ("tiledObjective", 1e-5),
        ("guidedObjective", 1e-5), ("guidedGradient", 1e-4), ("guidedDiagonal", 1e-4), ("guidedNormal", 1e-4)
    ]
    @Test(arguments: ["native", "mapped", "gain"], bounds)
    func frozenGPUOperator_preservesIndependentReference(mapping: String, bound: (String, Double)) throws {
        let result = try FrozenMeasurements.observation(mapping)
        let actual = try #require(result.values[bound.0])
        #expect(actual < bound.1)
    }
    @Test(arguments: ["native", "mapped", "gain"])
    func objectiveReferences_succeedAndDampingHasPositiveEnergy(mapping: String) throws {
        let result = try FrozenMeasurements.observation(mapping)
        #expect(result.statuses == ["objective": 0, "guided": 0])
        #expect(try #require(result.values["expectedDampingEnergy"]) > 0)
    }
    @Test(arguments: ["native", "mapped", "gain"], [0, 1])
    func cancelledFeasibleStep_preservesImage(mapping: String, tile: Int) throws {
        let result = try FrozenMeasurements.observation(mapping)
        #expect(result.cancelledSteps[tile] == false)
        #expect(result.cancelledImages[tile].0 == result.cancelledImages[tile].1)
    }
    @Test(arguments: ["native", "mapped", "gain"], [0, 1])
    func feasibleStep_reducesIndependentObjective(mapping: String, tile: Int) throws {
        let result = try FrozenMeasurements.observation(mapping)
        #expect(result.acceptedSteps[tile])
        #expect(result.fallbackStatuses[tile] == 0)
        #expect(result.objectives[tile + 1].isFinite)
        #expect(result.objectives[tile + 1] < result.objectives[tile])
    }
    @Test(arguments: ["native", "mapped", "gain"])
    func ambiguousShortFrame_keepsReliableMainObservations(mapping: String) throws {
        let result = try FrozenMeasurements.observation(mapping)
        #expect(result.retainedFrames == [true, true, false, true, true])
    }
    @Test(arguments: 0...5)
    func shortGenericUpload_keepsEveryValue(length: Int) throws {
        let device = try F5MetalDevice(maximumBytes: 256 * 1024 * 1024, shaderURL: F5TestContext.shader, isCancelled: { false })
        let floats = [Float](repeating: 512, count: length), words = (0..<length).map { UInt32($0 * 17) }
        let fb = try device.upload(floats, label: "short Float regression"), wb = try device.upload(words, label: "short UInt regression")
        let actualFloats = Array(UnsafeBufferPointer(start: fb.metal.contents().assumingMemoryBound(to: Float.self), count: length))
        let actualWords = Array(UnsafeBufferPointer(start: wb.metal.contents().assumingMemoryBound(to: UInt32.self), count: length))
        #expect(actualFloats == floats)
        #expect(actualWords == words)
    }
}
