import Foundation
import Metal
import simd

struct F5SolverStepDiagnostic: Codable {
    let stage: String
    let initialFeasibleStep: Double
    let guardedFeasibleStep: Double
    let constraintRounds: Int
    let acceptedStep: Double
    let directionalDerivative: Double
    let pcgIterations: Int
    let pcgRelativeResidual: Double
    let seconds: Double
}

final class F5PCGVectors {
    let gradient, diagonal, solution, residual, z, p, q: F5MetalBuffer
    let capacity: Int
    init(capacity: Int, device: F5MetalDevice, label: String) throws {
        self.capacity = capacity
        gradient = try device.allocate(capacity*4, label: label + " gradient")
        diagonal = try device.allocate(capacity*4, label: label + " Jacobi")
        solution = try device.allocate(capacity*4, label: label + " step")
        residual = try device.allocate(capacity*4, label: label + " residual")
        z = try device.allocate(capacity*4, label: label + " preconditioned residual")
        p = try device.allocate(capacity*4, label: label + " direction")
        q = try device.allocate(capacity*4, label: label + " normal product")
    }
}

final class F5MetalScratch {
    let fine, coarse, motion: F5PCGVectors
    let events, binCounts, binEntries, field, deltaField, prior, fieldGradient: F5MetalBuffer
    let eventValues, fieldValues, reduction, failure, zero: F5MetalBuffer
    let eventGuard, fieldGuard: F5MetalBuffer
    let motionDataNormal: F5MetalBuffer
    let eventCapacity: Int, coreSize: Int
    init(width: Int, height: Int, coreSize: Int, device: F5MetalDevice) throws {
        self.coreSize = min(coreSize, max(width*2, height*2))
        let size = self.coreSize
        eventCapacity = max(16, min(width*height*5, (size+128)*(size+128)*5))
        let fields = (size+6)*(size+6), bins = (size+3)*(size+3)
        let coarsePoints = ((width*2+6)/8+1)*((height*2+6)/8+1)*3
        fine = try F5PCGVectors(capacity: size*size*3, device: device, label: "F5 local")
        coarse = try F5PCGVectors(capacity: coarsePoints, device: device, label: "F5 coarse")
        motion = try F5PCGVectors(capacity: ((width+31)/32+1)*((height+31)/32+1)*10, device:device, label:"F5 joint motion")
        motionDataNormal = try device.allocate(motion.capacity/2*9*16,label:"F5 frozen motion data blocks")
        events = try device.allocate(eventCapacity*MemoryLayout<F5GPUEvent>.stride, label: "F5 event tile")
        binCounts = try device.allocate(bins*4, label: "F5 deterministic bin counts")
        binEntries = try device.allocate(bins*32*4, label: "F5 sorted observation indices")
        field = try device.allocate(fields*16, label: "F5 sampled field tile")
        deltaField = try device.allocate(fields*16, label: "F5 sampled step tile")
        prior = try device.allocate(fields*64, label: "F5 curvature prior tile")
        fieldGradient = try device.allocate(fields*16, label: "F5 field transpose tile")
        eventValues = try device.allocate(max(eventCapacity, max(fine.capacity, coarse.capacity))*4, label: "F5 reduced event values")
        fieldValues = try device.allocate(fields*4, label: "F5 reduced field values")
        eventGuard = try device.allocate(eventCapacity*4, label: "F5 local event constraint damping")
        fieldGuard = try device.allocate(fields*16, label: "F5 local output constraint damping")
        reduction = try device.allocate(((max(eventCapacity, max(fine.capacity, coarse.capacity))+255)/256)*4, label: "F5 scalar reductions")
        failure = try device.allocate(16, label: "F5 GPU failure word")
        zero = try device.upload([Float](repeating: 0, count: 16), label: "F5 zero direction")
    }
}

final class F5MetalLevel {
    let device: F5MetalDevice, frames: [F5MetalFrame], scratch: F5MetalScratch, likelihood: F5MetalLikelihood
    let width: Int, height: Int, scale: Int, reference: Int, policy: F5Policy
    let coefficients, noise, motion, motionDirection: F5MetalBuffer
    let meshColumns: Int, meshRows: Int
    var motionBounds: [SIMD4<Float>]
    var validEventCount: Int
    var motionAlpha: Float = 0
    var motionEdgeWeights: F5MetalBuffer?
    // Small frozen guide (one RGB direction per 8x8 native region), generated
    // once from the initial reference guide and shared by native/high solves.
    var colorAxis: F5MetalBuffer?
    var colorAxisShape = SIMD4<UInt32>.zero
    var refineGeometryAfterImage = false
    var fixedGeometryControl = false
    var localStepLimit = false
    var feasibleGradientFallback = false
    var parallelMotion = true
    private var motionPixelTerms: F5MetalBuffer?
    private(set) var motionGradient = Double.greatestFiniteMagnitude
    private var grid: F5GPUGrid
    private var eventsHaveFrozenScores = false
    private var hasLocalGuards = false
    var stepDiagnostic: ((F5SolverStepDiagnostic) -> Void)?
    var uniforms: F5GPUGrid { grid }
    var coarseCount: Int { Int(grid.options.y * grid.options.z * 3) }
    var tileCount: Int { ((width*scale+scratch.coreSize-1)/scratch.coreSize)*((height*scale+scratch.coreSize-1)/scratch.coreSize) }
    var tiles: [SIMD4<UInt32>] {
        let w = width*scale, h = height*scale, size = scratch.coreSize
        var values: [SIMD4<UInt32>] = []
        for color in 0..<4 {
            for y in stride(from: 0, to: h, by: size) { for x in stride(from: 0, to: w, by: size) {
                if ((y/size)%2)*2+(x/size)%2 == color { values.append(SIMD4(UInt32(x), UInt32(y), UInt32(min(size,w-x)), UInt32(min(size,h-y)))) }
            } }
        }
        return values
    }
    init(width: Int, height: Int, scale: Int, reference: Int, policy: F5Policy, device: F5MetalDevice,
         frames: [F5MetalFrame], scratch: F5MetalScratch, likelihood: F5MetalLikelihood,
         coefficients: F5MetalBuffer, noise: F5MetalBuffer, motion: F5MetalBuffer, motionDirection: F5MetalBuffer,
         motionBounds: [SIMD4<Float>], validEventCount: Int) {
        self.width = width; self.height = height; self.scale = scale; self.reference = reference; self.policy = policy
        self.device = device; self.frames = frames; self.scratch = scratch; self.likelihood = likelihood
        self.coefficients = coefficients; self.noise = noise; self.motion = motion; self.motionDirection = motionDirection
        self.motionBounds = motionBounds; self.validEventCount = validEventCount
        meshColumns = (width+31)/32+1; meshRows = (height+31)/32+1
        grid = F5GPUGrid(shape: SIMD4(UInt32(width),UInt32(height),UInt32(scale),UInt32(reference)), core: .zero, field: .zero,
            counts: .zero, bin: SIMD4(0,0,Int32(meshColumns),Int32(meshRows)), objective: .zero,
            regularizer: SIMD4(Float(policy.lambdaY),Float(policy.lambdaC),Float(policy.lambdaMotion),1e-6), step: .zero,
            options: SIMD4(0,UInt32((width*scale+6)/8+1),UInt32((height*scale+6)/8+1),0))
    }
    private func value<T>(_ value: T, _ index: Int, _ e: MTLComputeCommandEncoder) { F5MetalDevice.value(value, at: index, encoder: e) }
    func prepare(_ core: SIMD4<UInt32>, tau: Double, globalObjective: Bool = false) throws {
        eventsHaveFrozenScores = false
        hasLocalGuards = false
        grid.core = core
        let x = max(0,Int(core.x)-3), y = max(0,Int(core.y)-3)
        grid.field = SIMD4(Int32(x),Int32(y),Int32(min(width*scale,Int(core.x+core.z)+3)-x),Int32(min(height*scale,Int(core.y+core.w)+3)-y))
        grid.bin = SIMD4(Int32(core.x)-2,Int32(core.y)-2,Int32(meshColumns),Int32(meshRows))
        grid.counts = SIMD4(0,core.z+3,core.w+3,32)
        grid.objective = SIMD4(Float(validEventCount),Float(Double(validEventCount)/Double(width*height*scale*scale)),
            Float(Double(validEventCount)*tau/Double(width*height*scale*scale*3+validEventCount)),Float(policy.outlierProbability))
        grid.options.x = globalObjective ? 1 : 0; grid.step = SIMD4(0,0,0,motionAlpha)
        var regions: [SIMD4<UInt32>] = [], total = 0
        for bound in motionBounds {
            let left = max(0,min(width,Int(floor((Float(core.x)-2)/Float(scale)-bound.z-1))))
            let top = max(0,min(height,Int(floor((Float(core.y)-2)/Float(scale)-bound.w-1))))
            let right = min(width,max(left,Int(ceil(Float(core.x+core.z+2)/Float(scale)-bound.x+1))))
            let bottom = min(height,max(top,Int(ceil(Float(core.y+core.w+2)/Float(scale)-bound.y+1))))
            regions.append(SIMD4(UInt32(left),UInt32(top),UInt32(right-left),UInt32(bottom-top)))
            total += (right-left)*(bottom-top)
        }
        guard total <= scratch.eventCapacity else { throw F5Failure(.memoryPressure, "Accepted motion exceeds the tile event budget.") }
        grid.counts.x = UInt32(total)
        try device.run { command in
            try device.clear(scratch.binCounts.metal, command: command)
            try device.clear(scratch.failure.metal, command: command)
            var offset: UInt32 = 0
            for (i, region) in regions.enumerated() {
                var frameGrid = grid; frameGrid.options.w = UInt32(i)
                try device.encode("f5_load_events", count: Int(region.z*region.w), buffers: [frames[i].raw.metal,frames[i].table.metal,scratch.events.metal,motion.metal,motionDirection.metal,frames[i].eligibility.metal], command: command) { e in
                    value(frames[i].uniforms,6,e); value(frameGrid,7,e); value(region,8,e); value(offset,9,e)
                }
                offset += region.z*region.w
            }
            try device.encode("f5_build_bins", count: total, buffers: [scratch.events.metal,scratch.binCounts.metal,scratch.binEntries.metal,scratch.failure.metal], command: command) { value(grid,4,$0) }
            try device.encode("f5_sort_bins", count: Int(grid.counts.y*grid.counts.z), buffers: [scratch.binCounts.metal,scratch.binEntries.metal], command: command) { value(grid,2,$0) }
        }
        guard scratch.failure.metal.contents().load(as: UInt32.self) == 0 else { throw F5Failure(.responseModelMismatch, "Folded or clustered motion exceeded deterministic bin capacity.") }
    }
    private func encodeEvaluation(command: MTLCommandBuffer, direction: F5MetalBuffer, mode: Float, alpha: Float,
                                  coarse: Bool, derivatives: Bool, target: F5MetalBuffer) throws {
        grid.step = SIMD4(alpha,mode,coarse ? 1 : 0,0)
        let events = Int(grid.counts.x), fields = Int(grid.field.z*grid.field.w), n = Int(grid.core.z*grid.core.w*3)
        // Loading a different tile replaces its event cache. In particular,
        // coarse PCG must freeze scores for that tile before applying Q.
        if mode == 1 && !eventsHaveFrozenScores {
            var frozenGrid = grid
            frozenGrid.step = .zero
            try device.encode("f5_event_scores", count: events, buffers: [coefficients.metal,scratch.zero.metal,scratch.events.metal], command: command) { e in
                value(frozenGrid,3,e); value(likelihood.uniforms,4,e); e.setBuffer(likelihood.table.metal,offset:0,index:5)
            }
            eventsHaveFrozenScores = true
        }
        try device.encode("f5_event_scores", count: events, buffers: [coefficients.metal,direction.metal,scratch.events.metal], command: command) { e in
            value(grid,3,e); value(likelihood.uniforms,4,e); e.setBuffer(likelihood.table.metal,offset:0,index:5)
        }
        if mode == 0 { eventsHaveFrozenScores = true }
        try device.encode("f5_sample_field", count: fields, buffers: [coefficients.metal,direction.metal,noise.metal,scratch.field.metal,scratch.deltaField.metal], command: command) { value(grid,5,$0) }
        try device.encode("f5_prior_rows", count: fields, buffers: [scratch.field.metal,scratch.deltaField.metal,scratch.prior.metal,scratch.fieldValues.metal], command: command) { e in
            value(grid,4,e);e.setBuffer((colorAxis ?? scratch.zero).metal,offset:0,index:5);value(colorAxisShape,6,e)
        }
        if derivatives {
            try device.encode("f5_data_gather", count: n, buffers: [scratch.events.metal,scratch.binCounts.metal,scratch.binEntries.metal,target.metal,scratch.fine.diagonal.metal], command: command) { value(grid,5,$0) }
            try device.encode("f5_prior_transpose", count: fields, buffers: [scratch.prior.metal,scratch.field.metal,scratch.deltaField.metal,scratch.fieldGradient.metal], command: command) { value(grid,4,$0) }
            try device.encode("f5_prior_gather", count: n, buffers: [scratch.fieldGradient.metal,scratch.prior.metal,scratch.field.metal,direction.metal,target.metal,scratch.fine.diagonal.metal], command: command) { value(grid,6,$0) }
            if hasLocalGuards {
                try device.encode("f5_guard_gather", count:n,
                    buffers:[scratch.events.metal,scratch.binCounts.metal,scratch.binEntries.metal,scratch.field.metal,scratch.deltaField.metal,
                             scratch.fieldGuard.metal,scratch.eventGuard.metal,target.metal,scratch.fine.diagonal.metal],command:command) { value(grid,9,$0) }
            }
        }
        try device.encode("f5_event_objective", count: events, buffers: [scratch.events.metal,scratch.eventValues.metal], command: command) { value(grid,2,$0) }
    }
    func evaluate(direction: F5MetalBuffer? = nil, mode: Float = 0, alpha: Float = 0, coarse: Bool = false, derivatives: Bool = true) throws -> Double {
        let vector = direction ?? scratch.zero
        try device.run { try encodeEvaluation(command: $0, direction: vector, mode: mode, alpha: alpha, coarse: coarse, derivatives: derivatives, target: scratch.fine.q) }
        return try reduce(scratch.eventValues, count: Int(grid.counts.x)) + reduce(scratch.fieldValues, count: Int(grid.field.z*grid.field.w))
    }
    func reduce(_ values: F5MetalBuffer, count: Int, extreme: Bool? = nil) throws -> Double {
        if count == 0 { return extreme == false ? 1 : 0 }
        try device.run { command in
            if let extreme {
                try device.encode("f5_extreme", count: count, buffers: [values.metal,scratch.reduction.metal], command: command) { e in value(UInt32(count),2,e); value(UInt32(extreme ? 1 : 0),3,e) }
            } else {
                try device.encode("f5_sum", count: count, buffers: [values.metal,scratch.reduction.metal], command: command) { value(UInt32(count),2,$0) }
            }
        }
        let pointer = scratch.reduction.metal.contents().bindMemory(to: Float.self, capacity: (count+255)/256)
        var result = extreme == false ? 1.0 : 0.0
        for i in 0..<((count+255)/256) {
            if let extreme { result = extreme ? max(result,Double(pointer[i])) : min(result,Double(pointer[i])) }
            else { result += Double(pointer[i]) }
        }
        return result
    }
    private func dot(_ a: F5MetalBuffer, _ b: F5MetalBuffer, n: Int) throws -> Double {
        try device.run { command in try device.encode("f5_dot", count: n, buffers: [a.metal,b.metal,scratch.reduction.metal], command: command) { value(UInt32(n),3,$0) } }
        let values = scratch.reduction.metal.contents().bindMemory(to: Float.self, capacity: (n+255)/256)
        return (0..<((n+255)/256)).reduce(0.0) { $0 + Double(values[$1]) }
    }

    func countEvents() throws -> Int {
        var total = 0
        for tile in tiles {
            try prepare(tile, tau: 0, globalObjective: true)
            try device.run { command in
                try device.encode("f5_event_count", count: Int(grid.counts.x), buffers: [scratch.events.metal,scratch.eventValues.metal], command: command) { value(grid,2,$0) }
            }
            total += Int(try reduce(scratch.eventValues,count:Int(grid.counts.x)))
        }
        validEventCount = total
        guard total > 0 else { throw F5Failure(.frameMissing, "No valid sensor events remain in this objective epoch.") }
        return total
    }

    @discardableResult private func pcg(_ vectors: F5PCGVectors, n: Int, budgetExpired: () -> Bool,
                     apply: (F5MetalBuffer, F5MetalBuffer) throws -> Void) throws -> (iterations: Int, relativeResidual: Double) {
        try device.run { command in
            try device.encode("f5_vector_init", count:n, buffers:[vectors.gradient.metal,vectors.diagonal.metal,vectors.solution.metal,vectors.residual.metal,vectors.z.metal,vectors.p.metal], command:command) { value(UInt32(n),6,$0) }
        }
        let initial = try dot(vectors.residual,vectors.residual,n:n)
        if initial <= 1e-30 { return (0,0) }
        var rz = try dot(vectors.residual,vectors.z,n:n)
        var residual = initial
        for iteration in 0..<policy.pcgSteps {
            if budgetExpired() { return (iteration,sqrt(residual/initial)) }
            try apply(vectors.p,vectors.q)
            let pq = try dot(vectors.p,vectors.q,n:n)
            guard pq.isFinite, pq > 0, rz.isFinite, rz >= 0 else { throw F5Failure(.numericalStall,"The frozen normal operator is not positive.") }
            let alpha = Float(rz/pq)
            try device.run { command in
                try device.encode("f5_vector_update", count:n, buffers:[vectors.solution.metal,vectors.residual.metal,vectors.z.metal,vectors.p.metal,vectors.q.metal,vectors.diagonal.metal], command:command) { e in value(alpha,6,e);value(UInt32(n),7,e) }
            }
            residual = try dot(vectors.residual,vectors.residual,n:n)
            if residual <= initial*0.0001 { return (iteration+1,sqrt(residual/initial)) }
            let next = try dot(vectors.residual,vectors.z,n:n), beta = Float(next/rz)
            try device.run { command in
                try device.encode("f5_vector_direction", count:n, buffers:[vectors.p.metal,vectors.z.metal], command:command) { e in value(beta,2,e);value(UInt32(n),3,e) }
            }
            rz = next
        }
        return (policy.pcgSteps,sqrt(residual/initial))
    }
    private func positiveStep(_ direction: F5MetalBuffer, coarse: Bool) throws -> Float {
        grid.step = SIMD4(0,1,coarse ? 1 : 0,0)
        try device.run { command in
            try device.encode("f5_sample_field", count:Int(grid.field.z*grid.field.w), buffers:[coefficients.metal,direction.metal,noise.metal,scratch.field.metal,scratch.deltaField.metal], command:command) { value(grid,5,$0) }
            try device.encode("f5_positive_limits", count:Int(grid.field.z*grid.field.w), buffers:[scratch.field.metal,scratch.deltaField.metal,scratch.fieldValues.metal], command:command) { value(UInt32(grid.field.z*grid.field.w),3,$0) }
            try device.encode("f5_event_limits", count:Int(grid.counts.x), buffers:[coefficients.metal,direction.metal,scratch.events.metal,scratch.eventValues.metal], command:command) { value(grid,4,$0) }
        }
        return Float(try min(reduce(scratch.fieldValues,count:Int(grid.field.z*grid.field.w),extreme:false),reduce(scratch.eventValues,count:Int(grid.counts.x),extreme:false)))
    }
    func addLocalConstraintDamping(_ direction: F5MetalBuffer) throws {
        if !hasLocalGuards {
            try device.run { command in
                try device.clear(scratch.eventGuard.metal,command:command)
                try device.clear(scratch.fieldGuard.metal,command:command)
            }
        }
        _ = try positiveStep(direction,coarse:false)
        try device.run { command in
            try device.encode("f5_update_field_guard",count:Int(grid.field.z*grid.field.w),
                buffers:[scratch.field.metal,scratch.deltaField.metal,scratch.fine.diagonal.metal,scratch.fieldGuard.metal],command:command) { value(grid,4,$0) }
            try device.encode("f5_update_event_guard",count:Int(grid.counts.x),
                buffers:[coefficients.metal,direction.metal,scratch.events.metal,scratch.fine.diagonal.metal,scratch.eventGuard.metal],command:command) { value(grid,5,$0) }
        }
        hasLocalGuards = true
    }
    private func limitPhysicalDirection() throws {
        let n=Int(grid.core.z*grid.core.w*3)
        grid.step=SIMD4(0,1,0,0)
        try device.run {command in
            try device.encode("f5_step_limit_initialize",count:n,buffers:[scratch.fine.z.metal],command:command) {value(UInt32(n),1,$0)}
            try device.encode("f5_step_limit_physical",count:Int(grid.field.z*grid.field.w)*3+Int(grid.counts.x),
                buffers:[coefficients.metal,scratch.fine.solution.metal,scratch.events.metal,scratch.fine.z.metal],command:command) {value(grid,4,$0)}
            try device.encode("f5_step_limit_apply",count:n,buffers:[scratch.fine.solution.metal,scratch.fine.z.metal],command:command) {value(UInt32(n),2,$0)}
        }
    }
    private func commit(_ direction: F5MetalBuffer, alpha: Float, coarse: Bool) throws {
        eventsHaveFrozenScores = false
        grid.step = SIMD4(alpha,0,coarse ? 1 : 0,0)
        try device.run { command in
            try device.encode("f5_commit", count:Int(grid.core.z*grid.core.w*3), buffers:[coefficients.metal,direction.metal], command:command) { value(grid,2,$0) }
        }
    }
    private func gradientMetric() throws -> Double {
        let n = Int(grid.core.z*grid.core.w*3)
        try device.run { command in
            try device.encode("f5_gradient_metric", count:n, buffers:[scratch.fine.q.metal,scratch.fine.diagonal.metal,scratch.eventValues.metal], command:command) { value(UInt32(n),3,$0) }
        }
        return try reduce(scratch.eventValues,count:n,extreme:true)
    }
    /// A diagonal descent direction remains descending when individual
    /// negative components are shortened by the physical feasibility limiter.
    /// This uses existing scratch and the original objective, not a new prior.
    @discardableResult func feasibleGradientStep(budgetExpired: () -> Bool) throws -> Bool {
        if budgetExpired() {return false}
        let started=ProcessInfo.processInfo.systemUptime,n=Int(grid.core.z*grid.core.w*3)
        hasLocalGuards=false
        let before=try evaluate()
        guard before.isFinite else {return false}
        try device.run {command in
            try device.copy(scratch.fine.q.metal,to:scratch.fine.gradient.metal,bytes:n*4,command:command)
            try device.encode("f5_diagonal_direction",count:n,buffers:[scratch.fine.gradient.metal,scratch.fine.diagonal.metal,scratch.fine.solution.metal],command:command) {value(UInt32(n),3,$0)}
        }
        let initial=try positiveStep(scratch.fine.solution,coarse:false)
        try limitPhysicalDirection()
        let feasible=try positiveStep(scratch.fine.solution,coarse:false)
        let gd=try dot(scratch.fine.gradient,scratch.fine.solution,n:n)
        guard gd.isFinite,gd<0,feasible>0 else {return false}
        try device.run {try encodeEvaluation(command:$0,direction:scratch.fine.solution,mode:1,alpha:0,coarse:false,derivatives:true,target:scratch.fine.q)}
        let curvature=try dot(scratch.fine.solution,scratch.fine.q,n:n)
        guard curvature.isFinite,curvature>0 else {return false}
        var alpha=min(feasible,Float(-gd/curvature))
        guard alpha.isFinite,alpha>0 else {return false}
        for _ in 0..<12 {
            if budgetExpired() {return false}
            let candidate=try evaluate(direction:scratch.fine.solution,mode:2,alpha:alpha,derivatives:false)
            if candidate.isFinite,candidate<before,candidate<=before+1e-4*Double(alpha)*gd {
                try commit(scratch.fine.solution,alpha:alpha,coarse:false)
                stepDiagnostic?(.init(stage:"fine_diagonal",initialFeasibleStep:Double(initial),guardedFeasibleStep:Double(feasible),constraintRounds:0,
                    acceptedStep:Double(alpha),directionalDerivative:gd,pcgIterations:0,pcgRelativeResidual:0,seconds:ProcessInfo.processInfo.systemUptime-started))
                return true
            }
            alpha *= 0.5
        }
        return false
    }
    private func fineStep(tau: Double, budgetExpired: () -> Bool) throws -> Bool {
        let n = Int(grid.core.z*grid.core.w*3)
        for retry in 0..<3 {
            let started = ProcessInfo.processInfo.systemUptime
            hasLocalGuards = false
            try device.run { command in
                try device.clear(scratch.eventGuard.metal,command:command)
                try device.clear(scratch.fieldGuard.metal,command:command)
            }
            grid.regularizer.w = pow(10,Float(retry))*1e-6
            let before = try evaluate()
            guard before.isFinite else { throw F5Failure(.nonfinite,"The event objective or sampled field is non-finite.") }
            try device.run { try device.copy(scratch.fine.q.metal,to:scratch.fine.gradient.metal,bytes:n*4,command:$0) }
            var linear = (iterations:0,relativeResidual:1.0)
            var alpha: Float = 1, initialAlpha: Float = 1, constraintRounds = 0, limited = false
            var quadraticBacktrack: Float?
            for round in 0...6 {
                if budgetExpired() { return false }
                linear = try pcg(scratch.fine,n:n,budgetExpired:budgetExpired) { direction, target in
                    try device.run { try encodeEvaluation(command:$0,direction:direction,mode:1,alpha:0,coarse:false,derivatives:true,target:target) }
                }
                alpha = try positiveStep(scratch.fine.solution,coarse:false)
                if round == 0 { initialAlpha = alpha }
                constraintRounds = round
                if localStepLimit && round==0 && alpha<0.5 {
                    try device.run {try device.copy(scratch.fine.solution.metal,to:scratch.fine.p.metal,bytes:n*4,command:$0)}
                    try limitPhysicalDirection()
                    let derivative=try dot(scratch.fine.gradient,scratch.fine.solution,n:n)
                    let feasible=try positiveStep(scratch.fine.solution,coarse:false)
                    if derivative<0 && feasible>=0.5 {
                        // Keep a full feasible trial. If the true objective
                        // rejects it, the frozen quadratic guides backtracking.
                        try device.run {try encodeEvaluation(command:$0,direction:scratch.fine.solution,mode:1,alpha:0,coarse:false,derivatives:true,target:scratch.fine.q)}
                        let curvature=try dot(scratch.fine.solution,scratch.fine.q,n:n)
                        if curvature.isFinite && curvature>0 {limited=true;alpha=feasible;quadraticBacktrack=Float(-derivative/curvature);break}
                    }
                    if feasibleGradientFallback,try feasibleGradientStep(budgetExpired:budgetExpired) {return true}
                    try device.run {try device.copy(scratch.fine.p.metal,to:scratch.fine.solution.metal,bytes:n*4,command:$0)}
                    alpha=try positiveStep(scratch.fine.solution,coarse:false)
                }
                if alpha >= 0.5 || round == 6 { break }
                // Add PSD damping only at physical samples that limit this
                // direction. A distant dark pixel must not freeze the core.
                try addLocalConstraintDamping(scratch.fine.solution)
                _ = try evaluate()
            }
            let gd = try dot(scratch.fine.gradient,scratch.fine.solution,n:n)
            if !(gd < 0) { return false }
            let guardedAlpha = alpha
            for trial in 0..<12 {
                let candidate = try evaluate(direction:scratch.fine.solution,mode:2,alpha:alpha,derivatives:false)
                if candidate.isFinite, candidate <= before+1e-4*Double(alpha)*gd {
                    try commit(scratch.fine.solution,alpha:alpha,coarse:false)
                    stepDiagnostic?(.init(stage:limited ? "fine_limited" : "fine",initialFeasibleStep:Double(initialAlpha),guardedFeasibleStep:Double(guardedAlpha),constraintRounds:constraintRounds,
                        acceptedStep:Double(alpha),directionalDerivative:gd,
                        pcgIterations:linear.iterations,pcgRelativeResidual:linear.relativeResidual,seconds:ProcessInfo.processInfo.systemUptime-started))
                    return true
                }
                alpha *= 0.5
                if trial==0,let bound=quadraticBacktrack {alpha=min(alpha,bound)}
            }
        }
        return false
    }
    private func coarseTranspose(_ fine: F5MetalBuffer, into coarse: F5MetalBuffer, diagonal: Bool, command: MTLCommandBuffer) throws {
        let x = max(0,(Int(grid.core.x)-7)/8), y = max(0,(Int(grid.core.y)-7)/8)
        let right = min(Int(grid.options.y),(Int(grid.core.x+grid.core.z)+14)/8)
        let bottom = min(Int(grid.options.z),(Int(grid.core.y+grid.core.w)+14)/8)
        let rect = SIMD4<UInt32>(UInt32(x),UInt32(y),UInt32(right-x),UInt32(bottom-y))
        try device.encode("f5_coarse_transpose",count:(right-x)*(bottom-y)*3,buffers:[fine.metal,coarse.metal],command:command) { e in
            value(grid,2,e);value(UInt32(diagonal ? 1 : 0),3,e);value(rect,4,e)
        }
    }
    func globalObjective(tau: Double, direction: F5MetalBuffer? = nil, alpha: Float = 0) throws -> (Double,Double) {
        var objective = 0.0, maximum = 0.0
        for tile in tiles {
            try prepare(tile,tau:tau,globalObjective:true)
            objective += try evaluate(direction:direction,mode:direction == nil ? 0 : 2,alpha:alpha,coarse:direction != nil,derivatives:direction == nil && motionAlpha == 0)
            if direction == nil && motionAlpha == 0 { maximum = try max(maximum,gradientMetric()) }
        }
        return (objective,maximum)
    }
    private func coarseStep(tau: Double, budgetExpired: () -> Bool) throws -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        let vectors = scratch.coarse, n = coarseCount
        try device.run { command in try device.clear(vectors.gradient.metal,command:command);try device.clear(vectors.diagonal.metal,command:command) }
        for tile in tiles {
            if budgetExpired() { return false }
            try prepare(tile,tau:tau)
            _ = try evaluate()
            try device.run { command in
                try coarseTranspose(scratch.fine.q,into:vectors.gradient,diagonal:false,command:command)
                // P^T diag(Q) P is only a preconditioner. The normal product
                // below uses the full frozen Q, including all cross terms.
                try coarseTranspose(scratch.fine.diagonal,into:vectors.diagonal,diagonal:true,command:command)
            }
        }
        let linear = try pcg(vectors,n:n,budgetExpired:budgetExpired) { direction,target in
            try device.run { try device.clear(target.metal,command:$0) }
            for tile in tiles {
                // With one tile, the gradient pass has already populated the
                // frozen likelihood cache and PCG can reuse it throughout.
                if tileCount > 1 { try prepare(tile,tau:tau) }
                try device.run { command in
                    try encodeEvaluation(command:command,direction:direction,mode:1,alpha:0,coarse:true,derivatives:true,target:scratch.fine.q)
                    try coarseTranspose(scratch.fine.q,into:target,diagonal:false,command:command)
                }
            }
        }
        if budgetExpired() { return false }
        let gd = try dot(vectors.gradient,vectors.solution,n:n)
        if !(gd < 0) { return false }
        let before = try globalObjective(tau:tau).0
        var alpha: Float = 1
        for tile in tiles { try prepare(tile,tau:tau);alpha = try min(alpha,positiveStep(vectors.solution,coarse:true)) }
        let initialAlpha = alpha
        for _ in 0..<12 {
            let candidate = try globalObjective(tau:tau,direction:vectors.solution,alpha:alpha).0
            if candidate.isFinite, candidate <= before+1e-4*Double(alpha)*gd {
                for tile in tiles { grid.core = tile; try commit(vectors.solution,alpha:alpha,coarse:true) }
                stepDiagnostic?(.init(stage:"coarse",initialFeasibleStep:Double(initialAlpha),guardedFeasibleStep:Double(initialAlpha),constraintRounds:0,
                    acceptedStep:Double(alpha),directionalDerivative:gd,
                    pcgIterations:linear.iterations,pcgRelativeResidual:linear.relativeResidual,seconds:ProcessInfo.processInfo.systemUptime-started))
                return true
            }
            alpha *= 0.5
        }
        return false
    }
    func freezeNoiseScale() throws {
        guard scale == 1 else { throw F5Failure(.profileMismatch,"Noise scale must be frozen from a native image.") }
        for tile in tiles {
            try prepare(tile,tau:0)
            try device.run { command in
                try device.encode("f5_noise_from_events",count:Int(tile.z*tile.w),buffers:[scratch.events.metal,scratch.binCounts.metal,scratch.binEntries.metal,coefficients.metal,scratch.zero.metal,noise.metal],command:command) { value(grid,6,$0) }
            }
        }
    }
    func freezeColorAxis(adaptive: Bool = false, flatPriorBoost: Float = 1, protectFineDetail: Bool = false, harmonicPrior: Bool = false) throws {
        guard scale == 1 else { throw F5Failure(.profileMismatch,"Color guide must be frozen at native density.") }
        guard flatPriorBoost.isFinite,flatPriorBoost>=1,flatPriorBoost<=256 else {throw F5Failure(.profileMismatch,"Invalid flat-region prior multiplier.")}
        let columns=(width+7)/8+1,rows=(height+7)/8+1
        colorAxisShape=SIMD4(UInt32(columns),UInt32(rows),8,adaptive ? (harmonicPrior ? 3:2):1)
        let buffer=try device.allocate(columns*rows*32,label:"F5 frozen local RGB directions and noise confidence")
        let frame=frames[reference]
        try device.run {command in
            try device.encode("f5_initialize_color_axis",count:columns*rows,buffers:[coefficients.metal,buffer.metal],command:command) { e in
                value(grid,2,e);value(colorAxisShape,3,e);e.setBuffer(frame.raw.metal,offset:0,index:4)
                e.setBuffer(frame.table.metal,offset:0,index:5);value(frame.uniforms,6,e);value(flatPriorBoost,7,e);value(UInt32(protectFineDetail ? 1:0),8,e)
            }
        }
        colorAxis=buffer
    }
    func initializeCardinalReference(detailCorrection: Bool = false) throws -> Float {
        guard scale==1,tiles.count==1 else {throw F5Failure(.profileMismatch,"Cardinal initializer experiment needs a single native tile.")}
        try prepare(tiles[0],tau:0)
        let frame=frames[reference],n=width*height*3
        let temporary=try device.allocate(n*4,label:"F5 cardinal initializer temporary")
        let recurrence=try device.allocate(n*4,label:"F5 cardinal initializer recurrence")
        try device.run {command in
            try device.encode("f5_initialize_cardinal_samples",count:width*height,buffers:[frame.raw.metal,frame.table.metal,scratch.fine.solution.metal],command:command) {value(frame.uniforms,3,$0)}
            if detailCorrection {
                try device.encode("f5_initialize_detail_samples",count:width*height,buffers:[frame.raw.metal,frame.table.metal,scratch.fine.solution.metal],command:command) {value(frame.uniforms,3,$0)}
            }
            try device.encode("f5_spline_inverse",count:height*3,buffers:[scratch.fine.solution.metal,temporary.metal,recurrence.metal],command:command) {e in
                value(grid.core,3,e);value(grid.shape,4,e);value(UInt32(0),5,e)
            }
            try device.encode("f5_spline_inverse",count:width*3,buffers:[temporary.metal,scratch.fine.solution.metal,recurrence.metal],command:command) {e in
                value(grid.core,3,e);value(grid.shape,4,e);value(UInt32(1),5,e)
            }
            try device.encode("f5_initializer_direction",count:n,buffers:[scratch.fine.solution.metal,coefficients.metal],command:command) {value(UInt32(n),2,$0)}
        }
        let alpha=try positiveStep(scratch.fine.solution,coarse:false)
        try commit(scratch.fine.solution,alpha:alpha,coarse:false)
        return alpha
    }

    func encodeMotion(command: MTLCommandBuffer, direction: F5MetalBuffer, mode: Float, target: F5MetalBuffer) throws {
        guard let weights = motionEdgeWeights else { throw F5Failure(.profileMismatch,"Missing fixed guide edge weights.") }
        for f in frames.indices {
            var geometry = grid; geometry.options.w=UInt32(f);geometry.step=SIMD4(0,mode,0,0)
            if parallelMotion && mode==0 && f != reference {
                if motionPixelTerms==nil {
                    do {motionPixelTerms=try device.allocate(width*min(64,height)*16,label:"F5 bounded motion likelihood strip")}
                    catch let failure as F5Failure where failure.code == .memoryPressure {parallelMotion=false}
                }
                if let terms=motionPixelTerms {for row in 0..<meshRows {
                    let top=max(0,row*32-32),bottom=min(height,row*32+32)
                    let region=SIMD4<UInt32>(0,UInt32(top),UInt32(width),UInt32(bottom-top))
                    try device.encode("f5_motion_terms",count:width*(bottom-top),buffers:[frames[f].raw.metal,frames[f].table.metal,coefficients.metal,motion.metal,frames[f].eligibility.metal,terms.metal],command:command) {e in
                        value(frames[f].uniforms,6,e);value(geometry,7,e);value(likelihood.uniforms,8,e)
                        e.setBuffer(likelihood.table.metal,offset:0,index:9);e.setBuffer(scratch.zero.metal,offset:0,index:10);value(region,11,e)
                    }
                    try device.encode("f5_motion_gather_terms",count:meshColumns,buffers:[terms.metal,motion.metal,weights.metal,target.metal,scratch.motion.diagonal.metal,scratch.motionDataNormal.metal],command:command) {e in
                        value(geometry,6,e);value(region,7,e);value(UInt32(row),8,e)
                    }
                };continue}
            }
            try device.encode("f5_motion_normal",count:meshColumns*meshRows,
                buffers:[frames[f].raw.metal,frames[f].table.metal,coefficients.metal,motion.metal,direction.metal,weights.metal,frames[f].eligibility.metal,target.metal,scratch.motion.diagonal.metal],command:command) { e in
                value(frames[f].uniforms,9,e);value(geometry,10,e);value(likelihood.uniforms,11,e)
                e.setBuffer(likelihood.table.metal,offset:0,index:12);e.setBuffer(scratch.zero.metal,offset:0,index:13)
                e.setBuffer(scratch.motionDataNormal.metal,offset:0,index:14)
            }
        }
    }
    private func motionPenalty(alpha: Float = 0) -> Double {
        guard let weights = motionEdgeWeights else { return 0 }
        let count = meshColumns*meshRows
        let nodes = motion.metal.contents().bindMemory(to:SIMD2<Float>.self,capacity:count*5)
        let direction = motionDirection.metal.contents().bindMemory(to:SIMD2<Float>.self,capacity:count*5)
        let edge = weights.metal.contents().bindMemory(to:Float.self,capacity:count*5)
        func mirror(_ v: Int,_ n: Int)->Int { if v<0{return -v-1};if v>=n{return 2*n-v-1};return v }
        func at(_ x:Int,_ y:Int,_ f:Int)->SIMD2<Float> { let i=(f*meshRows+mirror(y,meshRows))*meshColumns+mirror(x,meshColumns);return nodes[i]+alpha*direction[i] }
        var sum=0.0
        for f in 0..<5 where f != reference { for y in 0..<meshRows { for x in 0..<meshColumns {
            let xx=at(x-1,y,f)-2*at(x,y,f)+at(x+1,y,f),yy=at(x,y-1,f)-2*at(x,y,f)+at(x,y+1,f)
            let xy=(at(x-1,y-1,f)-at(x+1,y-1,f)-at(x-1,y+1,f)+at(x+1,y+1,f))*Float(sqrt(2)/4)
            let norm=simd_length_squared(xx)+simd_length_squared(yy)+simd_length_squared(xy)
            sum += Double(edge[(f*meshRows+y)*meshColumns+x])*(sqrt(1+Double(norm))-1)
        } } }
        return Double(validEventCount)*policy.lambdaMotion*sum/Double(count*4)
    }
    private func measureMotionGradient(tau: Double) throws -> Double {
        try prepare(tiles[0],tau:tau)
        let vectors=scratch.motion,n=meshColumns*meshRows*10
        try device.run { try encodeMotion(command:$0,direction:scratch.zero,mode:0,target:vectors.gradient) }
        try device.run { command in try device.encode("f5_gradient_metric",count:n,buffers:[vectors.gradient.metal,vectors.diagonal.metal,scratch.eventValues.metal],command:command) { value(UInt32(n),3,$0) } }
        motionGradient=try reduce(scratch.eventValues,count:n,extreme:true)
        guard motionGradient.isFinite else { throw F5Failure(.nonfinite,"Invalid joint motion derivative.") }
        return motionGradient
    }
    @discardableResult func refineMotion(tau: Double, budgetExpired: () -> Bool) throws -> Bool {
        if budgetExpired() { return false }
        _ = try measureMotionGradient(tau:tau)
        let vectors=scratch.motion,n=meshColumns*meshRows*10
        if motionGradient < policy.standardizedGradientTolerance { return false }
        try pcg(vectors,n:n,budgetExpired:budgetExpired) { direction,target in
            try device.run { try encodeMotion(command:$0,direction:direction,mode:1,target:target) }
        }
        if budgetExpired() { return false }
        try device.run { command in try device.encode("f5_clip_motion",count:n/2,buffers:[vectors.solution.metal,motionDirection.metal],command:command) { value(UInt32(n/2),2,$0) } }
        let gd=try dot(vectors.gradient,motionDirection,n:n)
        if !(gd<0) { return false }
        let before=try globalObjective(tau:tau).0+motionPenalty()
        var alpha:Float=1
        defer { motionAlpha=0 }
        for _ in 0..<12 {
            motionAlpha=alpha
            let after=try globalObjective(tau:tau).0+motionPenalty(alpha:alpha)
            if after.isFinite,after<=before+1e-4*Double(alpha)*gd {
                try device.run { command in try device.encode("f5_commit_motion",count:n/2,buffers:[motion.metal,motionDirection.metal],command:command) { e in value(alpha,2,e);value(UInt32(n/2),3,e) } }
                let nodes=motion.metal.contents().bindMemory(to:SIMD2<Float>.self,capacity:n/2),count=meshColumns*meshRows
                for f in 0..<5 {
                    var minX=Float.infinity,minY=Float.infinity,maxX = -Float.infinity,maxY = -Float.infinity
                    for i in 0..<count { let p=nodes[f*count+i];minX=min(minX,p.x);minY=min(minY,p.y);maxX=max(maxX,p.x);maxY=max(maxY,p.y) }
                    motionBounds[f]=SIMD4(minX,minY,maxX,maxY)
                }
                return true
            }
            alpha *= 0.5
        }
        return false
    }
    func solve(epoch: Int, budgetExpired: () -> Bool, progress: (Double) -> Void) throws -> [F5QualityReport.Epoch] {
        var reports: [F5QualityReport.Epoch] = [], completed = 0
        for round in 0..<policy.maxGeometryRounds {
            let schedule = round == 0 ? [1e-4,1e-6,1e-8] : [1e-8]
            if !fixedGeometryControl && (!refineGeometryAfterImage || round>0) {
                _ = try refineMotion(tau:schedule[0],budgetExpired:budgetExpired)
            }
            for (barrierIndex,tau) in schedule.enumerated() {
                var report = F5QualityReport.Epoch(id:epoch*9+round*3+barrierIndex,validEventCount:validEventCount,
                    scale:scale,objectives:[],standardizedGradient:Double.greatestFiniteMagnitude,stopReason:"BUDGET_STOP",geometryRound:round)
                let earlyBarrier = tau > 1e-8
                let remaining = policy.maxCycles-completed
                guard remaining > 0 else { report.stopReason="CYCLE_LIMIT";reports.append(report);return reports }
                let cycles = earlyBarrier ? min(2,remaining) : max(1,remaining/(policy.maxGeometryRounds-round))
                var previous=Double.infinity, stable=0, imageStable=0, stalls=0
                for cycle in 0..<cycles {
                    if budgetExpired() { reports.append(report);return reports }
                    var changed=false
                    for (index,tile) in tiles.enumerated() {
                        if budgetExpired() { reports.append(report);return reports }
                        try prepare(tile,tau:tau)
                        changed = try fineStep(tau:tau,budgetExpired:budgetExpired) || changed
                        progress((Double(completed)+Double(index)/Double(max(1,tileCount)))/Double(policy.maxCycles))
                    }
                    if budgetExpired() { reports.append(report);return reports }
                    changed = try coarseStep(tau:tau,budgetExpired:budgetExpired) || changed
                    let (imageObjective,gradient) = try globalObjective(tau:tau)
                    let objective=imageObjective+motionPenalty()
                    guard objective.isFinite,gradient.isFinite else {throw F5Failure(.nonfinite,"The joint reconstruction objective is not finite (scale \(scale), round \(round), cycle \(completed), image \(imageObjective), motion \(motionPenalty()), gradient \(gradient)).")}
                    completed+=1;report.completedCycles+=1
                    let difference=previous.isFinite ? abs(previous-objective)/max(1,abs(previous)) : Double.infinity
                    let imageStationary=difference<policy.relativeObjectiveTolerance && gradient<policy.standardizedGradientTolerance
                    // The joint derivative is required before declaring any
                    // stationary iterate and at an epoch boundary. Repeating
                    // the full RAW pass while the image is far from stationary
                    // cannot change a stopping decision.
                    let geometryGradient = fixedGeometryControl ? 0 : imageStationary || cycle == cycles-1 || !changed ?
                        try measureMotionGradient(tau:tau) : Double.greatestFiniteMagnitude
                    report.objectives.append(objective);report.standardizedGradient=gradient;report.standardizedMotionGradient=geometryGradient
                    imageStable=imageStationary ? imageStable+1 : 0
                    stable=imageStationary && geometryGradient<policy.standardizedGradientTolerance ? stable+1 : 0
                    if stable>=2 && !earlyBarrier {report.stopReason=fixedGeometryControl ? "CONVERGED_FIXED_GEOMETRY" : "CONVERGED";reports.append(report);return reports}
                    if imageStable>=2 && !earlyBarrier {report.stopReason="GEOMETRY_PENDING";break}
                    stalls = !changed && gradient>=policy.standardizedGradientTolerance ? stalls+1 : 0
                    if stalls>=3 {report.stopReason="NUMERICAL_STALL";reports.append(report);return reports}
                    previous=objective
                }
                if earlyBarrier {report.stopReason="BARRIER_REDUCED"}
                else if report.stopReason=="BUDGET_STOP" {report.stopReason="CYCLE_LIMIT"}
                reports.append(report)
            }
        }
        return reports
    }
}
