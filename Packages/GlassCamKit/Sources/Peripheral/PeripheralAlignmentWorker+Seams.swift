import ImagingCore
import Foundation
import AVFoundation
import CoreImage
import QuartzCore
import simd
import OSLog
import Accelerate
import CryptoKit

extension PeripheralAlignmentWorker {
    package struct SegmentEvidence {
        package let index: Int
        package let point: SIMD2<Float>
        package let status: PeripheralEvidence.Status
        package let interval: ClosedRange<Double>?
        package let best: SIMD2<Float>?
        package let forwardBackward: Float?
        package let searchComplete: Bool
        package let gradientEigenvalues: SIMD2<Float>
        package let observableNormal: SIMD2<Float>
        package let noiseScale: Float?
        package var normalInterval: ClosedRange<Double>? = nil
        package var peak: Float? = nil
        package var signalStandardDeviation: Float = 0
        package var repeatedStructure = false
        /// Maximum distance from the best candidate to another feasible 2D
        /// candidate, plus half-pixel quantization per axis. Not a covariance.
        package var displacementUncertainty:Float? = nil
    }
    package struct SeamMeasurement {
        /// Diagnostic only. Unknown is NaN, never a fabricated zero.
        package let residual: Double
        package let gain: SIMD3<Float>
        package let offsets: [Int: SIMD2<Float>]
        package let comparisons: Int
        package let uncertainAnchors: Set<Int>
        package let evidence: PeripheralEvidence
        package let segments: [SegmentEvidence]
        package let geometryVerified: Bool
        package let photometryVerified: Bool
        package let boundaryMismatch: Double
        package let epipolarVerified: Bool
        package var epipolarProbeDistances: [Float] = []
    }

    /// Complete declared candidate domains, full 17x17 support and explicit
    /// ambiguity. A hint never removes a candidate or certifies a global peak.
    /// Optional F is in the SAME CI analysis coordinates as these two images.
    package static func measureSeams(reference: [UInt8], warped: [UInt8], width: Int, height: Int,
                             warpedPadding: Int = 0, seams: PeripheralSeams = .all,
                             previousOffsets: [Int: SIMD2<Float>]? = nil, certifiedGeometry: Bool = false,
                             previousGain: SIMD3<Float>? = nil, allowPartial: Bool = false,
                             fundamental: simd_float3x3? = nil,epipolarCertified: Bool = false,
                             comparisonBudget: Int = 90_000_000, deadline: Double = .infinity, clock: () -> Double = CACurrentMediaTime,
                             anchorPoints: [SIMD2<Int>]? = nil) -> SeamMeasurement? {
        guard width >= 64, height >= 64, width <= 512, height <= 512, warpedPadding >= 0, warpedPadding <= max(width,height),
              reference.count == width*height*4, !seams.isEmpty else { return nil }
        let bw = width+2*warpedPadding, bh = height+2*warpedPadding
        guard warped.count == bw*bh*4 else { return nil }
        let radius = max(8,Int(Double(min(width,height))*0.16)), patch = 8, side = 17
        func luma(_ bytes: [UInt8], _ w: Int, _ h: Int) -> [Float] {
            var raw = [Float](repeating: 0,count: w*h)
            for i in raw.indices { raw[i] = (Float(bytes[i*4])*0.2126+Float(bytes[i*4+1])*0.7152+Float(bytes[i*4+2])*0.0722)/255 }
            var horizontal = raw, out = raw
            for y in 0..<h { for x in 1..<w-1 { let i = y*w+x; horizontal[i] = (raw[i-1]+2*raw[i]+raw[i+1])*0.25 } }
            for y in 1..<h-1 { for x in 0..<w { let i = y*w+x; out[i] = (horizontal[i-w]+2*horizontal[i]+horizontal[i+w])*0.25 } }
            return out
        }
        let a = luma(reference,width,height), b = luma(warped,bw,bh)
        struct Plane {
            let values: [Float], width: Int, height: Int
            let sum: [Double], squared: [Double], invalid: [Int]
            init(_ values: [Float], _ bytes: [UInt8], _ width: Int, _ height: Int) {
                self.values = values; self.width = width; self.height = height
                let stride = width+1
                var s = [Double](repeating: 0,count: stride*(height+1)), q = s
                var bad = [Int](repeating: 0,count: s.count)
                for y in 0..<height {
                    var row = 0.0, row2 = 0.0, missing = 0
                    for x in 0..<width {
                        let v = Double(values[y*width+x]); row += v; row2 += v*v
                        // Filter support is valid only if its original pixels are valid.
                        var valid = true
                        for yy in max(0,y-1)...min(height-1,y+1) { for xx in max(0,x-1)...min(width-1,x+1) {
                            if bytes[(yy*width+xx)*4+3] != 255 { valid = false }
                        } }
                        if !valid { missing += 1 }
                        let i = (y+1)*stride+x+1
                        s[i] = s[i-stride]+row; q[i] = q[i-stride]+row2; bad[i] = bad[i-stride]+missing
                    }
                }
                sum = s; squared = q; invalid = bad
            }
            func statistics(_ x: Int, _ y: Int) -> (mean: Float, variance: Float)? {
                guard x >= 8, y >= 8, x+8 < width, y+8 < height else { return nil }
                let stride = width+1, x0 = x-8, y0 = y-8, x1 = x+9, y1 = y+9
                let i = y1*stride+x1, j = y0*stride+x1, k = y1*stride+x0, l = y0*stride+x0
                guard invalid[i]-invalid[j]-invalid[k]+invalid[l] == 0 else { return nil }
                let total = sum[i]-sum[j]-sum[k]+sum[l]
                let variance = squared[i]-squared[j]-squared[k]+squared[l]-total*total/289
                return (Float(total/289),Float(max(0,variance)))
            }
        }
        let pa = Plane(a,reference,width,height), pb = Plane(b,warped,bw,bh)
        var comparisons = 0, exhausted = false
        struct Peak { let value: Float; let dx: Int; let dy: Int }
        func search(_ source: Plane, _ target: Plane, x: Int, y: Int, tx: Int, ty: Int,
                    line: SIMD3<Float>? = nil) -> (peaks: [Peak], complete: Bool) {
            guard let stats = source.statistics(x,y), stats.variance > 0.000001 else { return ([],true) }
            var centered = [Float](); centered.reserveCapacity(289)
            for v in -patch...patch { for u in -patch...patch { centered.append(source.values[(y+v)*source.width+x+u]-stats.mean) } }
            var peaks: [Peak] = [], complete = true
            for dy in -radius...radius {
                if clock() > deadline { exhausted = true; return (peaks,false) }
                let yy = ty+dy
                let lo = max(-radius,patch-tx), hi = min(radius,target.width-patch-1-tx)
                guard yy >= patch, yy+patch < target.height, lo <= hi else { complete = false; continue }
                if lo != -radius || hi != radius { complete = false }
                var dots = [Float](repeating: 0,count: hi-lo+1)
                // Complete 2D fallback uses vectorized row correlation. This
                // changes arithmetic cost, never which candidate may compete.
                if line == nil {
                    let cost = dots.count*289
                    guard comparisons+cost <= comparisonBudget else { exhausted = true; return (peaks,false) }
                    var row = dots
                    target.values.withUnsafeBufferPointer { values in
                        centered.withUnsafeBufferPointer { kernel in
                            dots.withUnsafeMutableBufferPointer { output in
                                row.withUnsafeMutableBufferPointer { scratch in
                                    for v in 0..<side {
                                        let start = (yy+v-patch)*target.width+tx+lo-patch
                                        vDSP_conv(values.baseAddress!+start,1,kernel.baseAddress!+v*side,1,
                                                  scratch.baseAddress!,1,vDSP_Length(output.count),vDSP_Length(side))
                                        vDSP_vadd(output.baseAddress!,1,scratch.baseAddress!,1,output.baseAddress!,1,vDSP_Length(output.count))
                                    }
                                }
                            }
                        }
                    }
                    comparisons += cost
                }
                for dx in lo...hi {
                    let xx = tx+dx
                    if let line {
                        let denominator = hypot(line.x,line.y)
                        if denominator < 0.000001 || abs(line.x*Float(xx)+line.y*Float(yy)+line.z)/denominator > 1.5 { continue }
                    }
                    guard let other = target.statistics(xx,yy) else { complete = false; continue }
                    guard other.variance > 0.000001 else { continue }
                    var dot = dots[dx-lo]
                    if line != nil {
                        guard comparisons+289 <= comparisonBudget else { exhausted = true; return (peaks,false) }
                        dot = 0; var index = 0
                        for v in -patch...patch {
                            let start = (yy+v)*target.width+xx-patch
                            for u in 0..<side { dot += centered[index]*target.values[start+u]; index += 1 }
                        }
                        comparisons += 289
                    }
                    let value = max(-1,min(1,dot/sqrt(stats.variance*other.variance)))
                    peaks.append(.init(value: value,dx: dx,dy: dy))
                }
            }
            return (peaks,complete)
        }
        var validatedF: simd_float3x3?
        var epipolarProbeDistances: [Float] = []
        if let fundamental, epipolarCertified { validatedF = fundamental }
        else if let fundamental {
            var checks = 0
            for fy: Float in [0.25,0.75] { for fx: Float in [0.25,0.50,0.75] {
                let x = Int(Float(width)*fx), y = Int(Float(height)*fy)
                let probe = search(pa,pb,x: x,y: y,tx: x+warpedPadding,ty: y+warpedPadding)
                guard probe.complete, let best = probe.peaks.max(by: { $0.value < $1.value }), best.value > 0.90,
                      !probe.peaks.contains(where: { $0.value >= best.value-0.04 && hypot(Float($0.dx-best.dx),Float($0.dy-best.dy)) > 2 }) else { epipolarProbeDistances.append(.nan); continue }
                let line = fundamental*SIMD3(Float(x)+0.5,Float(y)+0.5,1)
                let distance = abs(line.x*(Float(x+best.dx)+0.5)+line.y*(Float(y+best.dy)+0.5)+line.z)/max(1e-8,hypot(line.x,line.y))
                epipolarProbeDistances.append(distance)
                if distance < 1 { checks += 1 }
            } }
            if checks == 6 { validatedF = fundamental }
        }
        var anchors: [(Int,Int)] = []
        // Every segment is represented; a separate scan includes the real edge,
        // corners and gaps between these inward-supported geometry patches.
        func locations(_ length: Int) -> [Int] {
            stride(from: 0,to: length,by: 16).map { min(length-10,max(10,$0+8)) }
        }
        if seams.contains(.horizontal) { for y in [10,height-11] { for x in locations(width) { anchors.append((x,y)) } } }
        if seams.contains(.vertical) { for x in [10,width-11] { for y in locations(height) { anchors.append((x,y)) } } }
        if let anchorPoints { anchors = anchorPoints.map { ($0.x,$0.y) } }
        var segments: [SegmentEvidence] = [], offsets: [Int:SIMD2<Float>] = [:]
        var uncertain: Set<Int> = []
        var gainSamples: [[Float]] = [[],[],[]]
        var severe: [(point: SIMD2<Float>,displacement: SIMD2<Float>,lower: Double)] = []
        func linear(_ value: UInt8) -> Float {
            let v = Float(value)/255; return v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4)
        }
        func addGain(_ x: Int,_ y: Int,_ dx: Int,_ dy: Int) {
            var blocks: [[Float]] = [[],[],[]]
            for v in stride(from: -6,through: 6,by: 4) { for u in stride(from: -6,through: 6,by: 4) {
                let ia = ((y+v)*width+x+u)*4, ib = ((y+dy+v+warpedPadding)*bw+x+dx+u+warpedPadding)*4
                for c in 0..<3 where reference[ia+c] > 12 && reference[ia+c] < 243 && warped[ib+c] > 12 && warped[ib+c] < 243 {
                    blocks[c].append(log(linear(reference[ia+c])/linear(warped[ib+c])))
                }
            } }
            for c in 0..<3 where blocks[c].count >= 8 { let sorted = blocks[c].sorted(); gainSamples[c].append(sorted[sorted.count/2]) }
        }
        for (index,point) in anchors.enumerated() {
            let (x,y) = point
            var xx:Float = 0,xy:Float = 0,yy:Float = 0,noise: [Float] = []
            for v in -7...7 { for u in -7...7 {
                let i = (y+v)*width+x+u
                let gx = (a[i+1]-a[i-1])*0.5, gy = (a[i+width]-a[i-width])*0.5
                xx += gx*gx; xy += gx*gy; yy += gy*gy
                if gx*gx+gy*gy < 0.0001 {
                    let raw = (Float(reference[i*4])*0.2126+Float(reference[i*4+1])*0.7152+Float(reference[i*4+2])*0.0722)/255
                    noise.append(abs(raw-a[i]))
                }
            } }
            let delta = hypot(xx-yy,2*xy), angle = 0.5*atan2(2*xy,xx-yy)
            let information = SIMD2(max(0,(xx+yy-delta)/2),(xx+yy+delta)/2)
            // Diagnostic ISP-domain scale, not a sensor-noise variance or a
            // calibrated covariance. No probability is inferred from this MAD.
            let noiseScale: Float? = noise.count >= 32 ? noise.sorted()[noise.count/2]*1.4826 : nil
            let line = validatedF.map { $0 * SIMD3(Float(x)+0.5,Float(y)+0.5,1) }.map {
                SIMD3($0.x,$0.y,$0.z+($0.x+$0.y)*(0.5-Float(warpedPadding)))
            }
            let forward = search(pa,pb,x: x,y: y,tx: x+warpedPadding,ty: y+warpedPadding,line: line)
            var status: PeripheralEvidence.Status = exhausted ? .budgetExceeded : .unobservable
            var interval: ClosedRange<Double>?, bestOffset: SIMD2<Float>?, fb: Float?
            var normalInterval: ClosedRange<Double>?, peak: Float?
            var reverseOffset: SIMD2<Float>?
            var displacementUncertainty:Float?
            var repeatedStructure = false
            let signal = sqrt(max(0,pa.statistics(x,y)?.variance ?? 0)/289)
            peak = forward.peaks.max(by: { $0.value < $1.value })?.value
            if forward.complete, let best = forward.peaks.max(by: { $0.value < $1.value }), best.value >= 0.85 {
                peak = best.value
                let feasible = forward.peaks.filter { $0.value >= best.value-0.025 }
                if signal >= 2/255, information.y > 0.0001 {
                    let normal = SIMD2<Float>(cos(angle),sin(angle))
                    let projected = feasible.map { simd_dot(normal,SIMD2(Float($0.dx),Float($0.dy))) }.sorted()
                    let gap = zip(projected,projected.dropFirst()).map { $1-$0 }.max() ?? 0
                    repeatedStructure = gap > 4 && (projected.last ?? 0)-(projected.first ?? 0) > 8 && best.value > 0.90
                }
                // The reverse diagnostic searches its entire *physical* overlap
                // with the cropped central camera. Missing pixels are never padded.
                let reverse = search(pb,pa,x: x+warpedPadding+best.dx,y: y+warpedPadding+best.dy,tx: x+best.dx,ty: y+best.dy,
                    line: validatedF.map {
                        let line = $0.transpose*SIMD3(Float(x+best.dx)+0.5,Float(y+best.dy)+0.5,1)
                        return SIMD3(line.x,line.y,line.z+0.5*(line.x+line.y))
                    })
                if let back = reverse.peaks.max(by: { $0.value < $1.value }), back.value >= 0.85 {
                    // Test the independently selected reverse optimum, not the
                    // most convenient member of its ambiguous candidate set.
                    fb = hypot(Float(back.dx+best.dx),Float(back.dy+best.dy))
                    reverseOffset = SIMD2(Float(back.dx+best.dx),Float(back.dy+best.dy))
                }
                if !exhausted, let reverseOffset, best.value > 0.95, signal >= 2/255 {
                    let normal = SIMD2<Float>(cos(angle),sin(angle))
                    let projected = feasible.map { simd_dot(normal,SIMD2(Float($0.dx),Float($0.dy))) }
                    let minimum = projected.min() ?? 0, maximum = projected.max() ?? 0
                    let edge = information.y > 0.0001 && information.x/information.y < 0.10
                    let norm = SIMD2(Float(best.dx),Float(best.dy))
                    let normalBounded = edge && maximum-minimum <= 2 &&
                        max(abs(minimum),abs(maximum)) < Float(radius-1) && abs(simd_dot(normal,reverseOffset)) <= 1
                    if normalBounded {
                        let closest = minimum <= 0 && maximum >= 0 ? Float(0) : min(abs(minimum),abs(maximum))
                        let lower = max(0,Double(closest)-sqrt(0.5))/Double(min(width,height))
                        let upper = (Double(max(abs(minimum),abs(maximum)))+sqrt(0.5))/Double(min(width,height))
                        normalInterval = lower...upper
                    }
                    let unique2D = (fb ?? .infinity) <= 1 && !feasible.contains { hypot(Float($0.dx-best.dx),Float($0.dy-best.dy)) > 2 } &&
                        !feasible.contains { abs($0.dx) >= radius-1 || abs($0.dy) >= radius-1 }
                    if normalBounded || unique2D {
                        let observed = normalBounded ? normal*simd_dot(normal,norm) : norm
                        let lower = max(0,Double(simd_length(observed))-sqrt(0.5))/Double(min(width,height))
                        if lower > 0.10 { severe.append((SIMD2(Float(x),Float(y)),observed,lower)) }
                    }
                }
                if !exhausted, let fb, fb <= 1, signal >= 2/255,
                   !feasible.contains(where: { abs($0.dx) >= radius-1 || abs($0.dy) >= radius-1 }) {
                    let distances = feasible.map { hypot(Double($0.dx),Double($0.dy))/Double(min(width,height)) }
                    // Integer candidates do not specify a continuous exact
                    // displacement. Include half-pixel quantization per axis.
                    let quantization = sqrt(0.5)/Double(min(width,height))
                    interval = max(0,distances.min()!-quantization)...(distances.max()!+quantization)
                    let spread = feasible.map { hypot(Float($0.dx-best.dx),Float($0.dy-best.dy)) }.max() ?? 0
                    status = spread <= 2 ? .measured : .ambiguous
                    bestOffset = SIMD2(Float(best.dx),Float(best.dy))
                    if status == .measured {
                        displacementUncertainty=spread+sqrt(0.5)
                        offsets[index] = bestOffset!
                        addGain(x,y,best.dx,best.dy)
                    }
                }
            }
            if status != .measured { uncertain.insert(index) }
            segments.append(.init(index: index,point: SIMD2(Float(x),Float(y)),status: status,
                interval: interval,best: bestOffset,forwardBackward: fb,searchComplete: forward.complete && !exhausted,
                gradientEigenvalues: information,observableNormal: SIMD2(cos(angle),sin(angle)),noiseScale: noiseScale,
                normalInterval:normalInterval,peak:peak,signalStandardDeviation:signal,repeatedStructure:repeatedStructure,
                displacementUncertainty:displacementUncertainty))
        }
        // Independent correspondence validation, not just source-point spread.
        // These matched points have full-domain uniqueness and a reverse check.
        let inliers = segments.filter { $0.status == .measured && ($0.interval?.upperBound ?? 1) < 3/Double(min(width,height)) }
        let positions = inliers.map(\.point)
        let mean = positions.reduce(SIMD2<Float>(repeating:0),+)/Float(max(1,positions.count))
        var xx:Float = 0,xy:Float = 0,yy:Float = 0
        for p in positions {
            let d = (p-mean)/SIMD2(Float(width),Float(height))
            xx += d.x*d.x; xy += d.x*d.y; yy += d.y*d.y
        }
        let distributed = (xx*yy-xy*xy)/Float(max(1,positions.count*positions.count)) > 0.001
        let geometryVerified = distributed && positions.count >= 6 &&
            (positions.map(\.x).max() ?? 0)-(positions.map(\.x).min() ?? 0) > Float(width)*0.4 &&
            (positions.map(\.y).max() ?? 0)-(positions.map(\.y).min() ?? 0) > Float(height)*0.4
        var gain = previousGain ?? SIMD3<Float>(repeating: 1)
        var photometryVerified = gainSamples.allSatisfy { $0.count >= 6 }
        if photometryVerified {
            for c in 0..<3 { let values = gainSamples[c].sorted(); gain[c] = exp(values[values.count/2]) }
        }
        if !(0..<3).allSatisfy({ gain[$0].isFinite && (0.5...2).contains(gain[$0]) }) {
            gain = previousGain ?? SIMD3(repeating: 1); photometryVerified = false
        }
        func encode(_ c: Float) -> Float { c <= 0.0031308 ? c*12.92 : 1.055*pow(c,1/2.4)-0.055 }
        // Inspect every actual boundary pixel, including narrow salient defects.
        // A global robust offset is used only for STRUCTURE, never displacement.
        var pixels: [(Int,Int)] = []
        if seams.contains(.horizontal) { for y in Array(0..<4)+Array(height-4..<height) { for x in 0..<width { pixels.append((x,y)) } } }
        if seams.contains(.vertical) { for x in Array(0..<4)+Array(width-4..<width) { for y in 0..<height { pixels.append((x,y)) } } }
        var residuals: [SIMD3<Float>] = [], invalidBoundary = false
        for (x,y) in pixels {
            let nearest = segments.min { simd_distance_squared($0.point,SIMD2(Float(x),Float(y))) < simd_distance_squared($1.point,SIMD2(Float(x),Float(y))) }
            let offset = nearest?.status == .measured ? nearest?.best ?? .zero : .zero
            let xx = x+warpedPadding+Int(offset.x.rounded()), yy = y+warpedPadding+Int(offset.y.rounded())
            guard xx >= 0, yy >= 0, xx < bw, yy < bh else { invalidBoundary = true; continue }
            let ia = (y*width+x)*4, ib = (yy*bw+xx)*4
            guard reference[ia+3] == 255, warped[ib+3] == 255 else { invalidBoundary = true; continue }
            var d = SIMD3<Float>(repeating: 0)
            for c in 0..<3 { d[c] = Float(reference[ia+c])/255-encode(linear(warped[ib+c])*gain[c]) }
            residuals.append(d)
        }
        var common = SIMD3<Float>(repeating: 0)
        if !residuals.isEmpty { for c in 0..<3 { let sorted = residuals.map { $0[c] }.sorted(); common[c] = sorted[sorted.count/2] } }
        let brightness = (common.x+common.y+common.z)/3
        let chroma = max(abs(common.x-brightness),max(abs(common.y-brightness),abs(common.z-brightness)))
        let mismatch = residuals.filter { simd_length($0-SIMD3(repeating: brightness)) > 0.25 }.count
        let boundaryMismatch = Double(mismatch)/Double(max(1,residuals.count))
        // Small geometry residuals can still move an edge. Do not relabel that
        // as occlusion; scan disagreements prevent unobserved regions being certified.
        let appearance: PeripheralEvidence.Appearance = invalidBoundary || chroma > 0.06 || abs(brightness) > 0.08 || boundaryMismatch > 0.04 ? .mismatch : .compatible
        let measured = segments.compactMap { $0.searchComplete ? $0.interval : nil }
        let allMeasured = measured.count == segments.count && !segments.isEmpty
        let lower = measured.map(\.lowerBound).max(), upper = measured.map(\.upperBound).max()
        let status: PeripheralEvidence.Status = exhausted ? .budgetExceeded :
            (segments.contains { $0.status == .ambiguous } ? .ambiguous : (allMeasured ? .measured : .unobservable))
        var evidence = PeripheralEvidence(status: status,interval: allMeasured ? lower!...upper! : nil,
            appearance: appearance,reason: exhausted ? "comparison-budget" : (allMeasured ? "full-support-matches" : "unresolved-segments"),
            searchComplete: segments.allSatisfy(\.searchComplete),coverage: Double(measured.count)/Double(max(1,segments.count)))
        // Corroborate a severe local structure across distinct supported
        // segments. An isolated low-confidence maximum cannot use this path.
        for i in severe.indices { for j in severe.indices where j > i {
            if simd_distance(severe[i].point,severe[j].point) >= 12 &&
                simd_distance(severe[i].displacement,severe[j].displacement) <= 2 {
                evidence.confirmedSevereLowerBound = max(evidence.confirmedSevereLowerBound ?? 0,
                    min(severe[i].lower,severe[j].lower))
            }
        } }
        if evidence.confirmedSevereLowerBound != nil { evidence.reason = "corroborated-local-displacement" }
        // Strict callers may still use nil, but no successful value can represent
        // unobservable geometry as a reliable zero. Production requests all states.
        if !allowPartial && (!evidence.reliable || (!certifiedGeometry && !geometryVerified) || appearance == .mismatch) { return nil }
        return .init(residual: evidence.reliable ? offsets.values.map { Double(simd_length($0))/Double(min(width,height)) }.max() ?? .nan : .nan,gain: gain,offsets: offsets,
            comparisons: comparisons,uncertainAnchors: uncertain,evidence: evidence,segments: segments,
            geometryVerified: geometryVerified,photometryVerified: photometryVerified,boundaryMismatch: boundaryMismatch,
            epipolarVerified: validatedF != nil,epipolarProbeDistances:epipolarProbeDistances)
    }
}
