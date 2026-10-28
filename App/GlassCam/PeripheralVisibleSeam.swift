import Foundation
import CoreImage
import Metal
import simd

enum PeripheralTemporalAppearance {
    /// Same-camera native boundary comparison for the otherwise unobservable
    /// stationary/flat case. Includes chroma and every native pixel in the band.
    /// It authorizes visible temporal consistency, never a zero motion estimate.
    static func compatible(_ a:CVPixelBuffer,_ b:CVPixelBuffer,seams:PeripheralSeams) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(a)
        guard format == CVPixelBufferGetPixelFormatType(b),CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b),
              CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b),CVPixelBufferLockBaseAddress(a,.readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(a,.readOnly) }
        guard CVPixelBufferLockBaseAddress(b,.readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(b,.readOnly) }
        let planar = CVPixelBufferIsPlanar(a)
        let ten = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        guard planar || format == kCVPixelFormatType_32BGRA else { return false }
        var sum = 0.0, count = 0
        for p in 0..<(planar ? CVPixelBufferGetPlaneCount(a) : 1) {
            let width = planar ? CVPixelBufferGetWidthOfPlane(a,p) : CVPixelBufferGetWidth(a)
            let height = planar ? CVPixelBufferGetHeightOfPlane(a,p) : CVPixelBufferGetHeight(a)
            let strideA = planar ? CVPixelBufferGetBytesPerRowOfPlane(a,p) : CVPixelBufferGetBytesPerRow(a)
            let strideB = planar ? CVPixelBufferGetBytesPerRowOfPlane(b,p) : CVPixelBufferGetBytesPerRow(b)
            guard let baseA = planar ? CVPixelBufferGetBaseAddressOfPlane(a,p) : CVPixelBufferGetBaseAddress(a),
                  let baseB = planar ? CVPixelBufferGetBaseAddressOfPlane(b,p) : CVPixelBufferGetBaseAddress(b) else { return false }
            let channels = planar ? (p == 0 ? 1 : 2) : 4
            let bandX = max(1,Int(ceil(Double(width)*8/192))), bandY = min(height,bandX)
            for y in 0..<height {
                let horizontal = seams.contains(.horizontal) && (y < bandY || y >= height-bandY)
                let rowA = baseA+y*strideA, rowB = baseB+y*strideB
                for x in 0..<width where horizontal || (seams.contains(.vertical) && (x < bandX || x >= width-bandX)) {
                    for c in 0..<(planar ? channels : 3) {
                        let i = x*channels+c
                        let difference:Double
                        if ten {
                            difference = Double(abs(Int(rowA.assumingMemoryBound(to:UInt16.self)[i] >> 6)-Int(rowB.assumingMemoryBound(to:UInt16.self)[i] >> 6)))/1023
                        } else {
                            difference = Double(abs(Int(rowA.assumingMemoryBound(to:UInt8.self)[i])-Int(rowB.assumingMemoryBound(to:UInt8.self)[i])))/255
                        }
                        if difference > 0.06 { return false }
                        sum += difference; count += 1
                    }
                }
            }
        }
        return count > 0 && sum/Double(count) <= 0.015
    }
}

/// Legacy analyzed-frame transport retained for strict evidence regressions
/// and comparisons. The live renderer uses PeripheralLiveTextureStore; these
/// certificate gates no longer control whether fresh preview pixels upload.
final class PeripheralTextureStore {
    final class Bundle {
        let texture: MTLTexture
        let alignment: PeripheralAlignmentResult
        let pair: PeripheralFrameSource.Pair
        let revision: UInt64, command: UInt64, ticket: UInt64
        let centerRaster: PeripheralMotion.Raster?
        init(texture:MTLTexture,alignment:PeripheralAlignmentResult,pair:PeripheralFrameSource.Pair,
             revision:UInt64,command:UInt64,ticket:UInt64) {
            self.texture = texture; self.alignment = alignment; self.pair = pair
            self.revision = revision; self.command = command; self.ticket = ticket
            centerRaster = PeripheralMotion.raster(pair.center)
        }
    }
    private(set) var completed: Bundle?
    private(set) var displayable: Bundle?
    private var spare: MTLTexture?
    private var pending: Bundle?
    private var ticket: UInt64 = 0
    private var failures = 0
    private(set) var nextAttempt = 0.0
    private(set) var failureReason: String?
    func reset() {
        ticket &+= 1; completed = nil; displayable = nil; pending = nil; spare = nil; failures = 0; nextAttempt = 0; failureReason = nil
    }
    func prepare(alignment:PeripheralAlignmentResult,revision:UInt64,epoch:UInt64,commandID:UInt64,
                 at time:Double,device:MTLDevice,context:CIContext,command:MTLCommandBuffer,
                 colorSpace:CGColorSpace,samplingLegal:Bool) throws -> (Bundle,CIRenderTask)? {
        guard pending == nil, time >= nextAttempt, samplingLegal,
              let pair = alignment.inputPair, pair.epoch == epoch, alignment.epoch == epoch,
              pair.serial == alignment.pairID, time >= pair.observedAt, time-pair.observedAt <= 0.20,
              completed?.pair.serial != pair.serial || completed?.alignment.geometryID != alignment.geometryID ||
              completed?.alignment.photometryID != alignment.photometryID ||
              completed?.alignment.tolerance != alignment.tolerance ||
              completed?.alignment.visiblePhotometryID != alignment.visiblePhotometryID else { return nil }
        let width = CVPixelBufferGetWidth(pair.outer), height = CVPixelBufferGetHeight(pair.outer)
        if spare?.width != width || spare?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
            d.usage = [.shaderRead,.shaderWrite,.renderTarget]; spare = device.makeTexture(descriptor:d)
        }
        guard let texture = spare else { failed(at:time,reason:"texture-allocation-failed"); return nil }
        do {
            // CI render task carries its command buffer and original pixels.
            let destination = CIRenderDestination(mtlTexture:texture,commandBuffer:command)
            destination.colorSpace = colorSpace; destination.isFlipped = true
            guard let image = alignment.renderOuterImage() else { failed(at:time,reason:"refinement-kernel-unavailable"); return nil }
            let task = try context.startTask(toRender:image,to:destination)
            ticket &+= 1
            let value = Bundle(texture:texture,alignment:alignment,pair:pair,revision:revision,command:commandID,ticket:ticket)
            pending = value; spare = nil
            return (value,task)
        } catch { failed(at:time,reason:"ci-encode-failed"); throw error }
    }
    @discardableResult
    func complete(_ bundle:Bundle,success:Bool,revision:UInt64,epoch:UInt64,at time:Double) -> Bool {
        guard pending === bundle, bundle.ticket == ticket, bundle.revision == revision, bundle.pair.epoch == epoch else { return false }
        pending = nil
        if success {
            let previous = completed
            completed = bundle
            if bundle.alignment.permitsAnyDisplay { displayable = bundle }
            // Keep a still-valid good resource when a new UNKNOWN is prepared.
            // Its own absolute deadline is enforced by the draw caller.
            spare = previous !== displayable ? previous?.texture : nil
            failures = 0; failureReason = nil
        }
        else { spare = bundle.texture; failed(at:time,reason:"gpu-upload-failed") }
        return true
    }
    private func failed(at time:Double,reason:String) {
        failureReason = reason
        failures += 1; nextAttempt = time+(failures >= 3 ? 1.0 : 0.05)
        if failures >= 3 { failures = 0 }
    }
}

/// Bounded per-edge linear gains and sRGB affine models. Metal and the native
/// verifier apply the selected model in the same transfer-function domain;
/// the retained verification rasters contain the unadjusted input pixels.
struct PeripheralEdgeGains {
    var top = SIMD3<Float>(repeating: 1)
    var bottom = SIMD3<Float>(repeating: 1)
    var left = SIMD3<Float>(repeating: 1)
    var right = SIMD3<Float>(repeating: 1)
    var encodedSlope = [SIMD3<Float>](repeating:SIMD3(repeating:1),count:4)
    var encodedBias = [SIMD3<Float>](repeating:.zero,count:4)
    var usesEncodedAffine = false
    var encodedAffineEdges = [Bool](repeating:false,count:4)
    func affine(_ side:Int) -> Bool { usesEncodedAffine || encodedAffineEdges[side] }
    subscript(_ edge: Int) -> SIMD3<Float> {
        get { [top,bottom,left,right][edge] }
        set { switch edge { case 0: top = newValue; case 1: bottom = newValue; case 2: left = newValue; default: right = newValue } }
    }
}

struct PeripheralNativeSeam {
    struct Strip {
        let edge: Int
        let width: Int, height: Int
        let reference: [UInt8], outer: [UInt8]
        let nativeScale: Double
    }
    let strips: [Strip]
    let gains: PeripheralEdgeGains
    let evidence: PeripheralVisibleEvidence
    let diagnostics: [[String: Any]]

    static func linear(_ value: Float) -> Float {
        value <= 0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4)
    }
    static func encode(_ value: Float) -> Float {
        value <= 0.0031308 ? value*12.92 : 1.055*pow(value,1/2.4)-0.055
    }
    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }; let sorted = values.sorted(); return sorted[sorted.count/2]
    }

    /// Read ONLY native-resolution boundary strips. No downsampling can erase a
    /// one-native-pixel line or the outermost row. CI handles tagged YUV→sRGB;
    /// the projection has the independently tested, unchanged H convention.
    static func read(center: CIImage, outerImage: CIImage, ratio: Float, matrix: simd_float3x3,
                     analysisWidth: Int, analysisHeight: Int, seams: PeripheralSeams,
                     context: CIContext) -> [Strip] {
        let w = Int(center.extent.width), h = Int(center.extent.height)
        guard w > 0, h > 0, w <= 4096, h <= 4096 else { return [] }
        let scale = Double(w)/Double(analysisWidth)
        let sy = Double(h)/Double(analysisHeight)
        let s = simd_float3x3(SIMD3(Float(scale),0,0),SIMD3(0,Float(sy),0),SIMD3(0,0,1))
        // Scale BEFORE the perspective filter. Warping at 192px and enlarging
        // afterward would certify an artificially blurred image, not the
        // native texture the shader samples.
        let nativeFloating = outerImage.transformed(by:CGAffineTransform(
            a:Double(w)*Double(ratio)/outerImage.extent.width,b:0,c:0,
            d:Double(h)*Double(ratio)/outerImage.extent.height,
            tx:Double(w)*(1-Double(ratio))/2,ty:Double(h)*(1-Double(ratio))/2))
        guard let outer = PeripheralAlignmentWorker.warp(nativeFloating,by:s*matrix*s.inverse) else { return [] }
        let depth = max(3,Int(ceil(12*scale)))
        func bytes(_ image: CIImage,_ bounds: CGRect) -> [UInt8] {
            let width = Int(bounds.width), height = Int(bounds.height)
            var data = [UInt8](repeating:0,count:width*height*4)
            data.withUnsafeMutableBytes {
                context.render(image,toBitmap:$0.baseAddress!,rowBytes:width*4,bounds:bounds,
                    format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            }
            return data
        }
        var result: [Strip] = []
        for edge in 0..<4 {
            guard edge < 2 ? seams.contains(.horizontal) : seams.contains(.vertical) else { continue }
            let bounds: CGRect
            switch edge {
            case 0: bounds = CGRect(x:0,y:max(0,h-depth),width:w,height:min(depth,h))
            case 1: bounds = CGRect(x:0,y:0,width:w,height:min(depth,h))
            case 2: bounds = CGRect(x:0,y:0,width:min(depth,w),height:h)
            default: bounds = CGRect(x:max(0,w-depth),y:0,width:min(depth,w),height:h)
            }
            result.append(.init(edge:edge,width:Int(bounds.width),height:Int(bounds.height),
                reference:bytes(center,bounds),outer:bytes(outer,bounds),nativeScale:scale))
        }
        return result
    }

    /// Robust independent per-edge photometry, using many paired native tiles.
    /// Reject clipped/dark samples and strong local structural disagreement.
    /// No global tone offset is subtracted from the subsequent display check.
    static func estimate(_ strips: [Strip]) -> PeripheralEdgeGains {
        var gains = PeripheralEdgeGains()
        gains.usesEncodedAffine = true
        for strip in strips {
            var logs: [[Float]] = [[],[],[]]
            var pairs: [[SIMD2<Float>]] = [[],[],[]]
            for y in stride(from:1,to:strip.height-1,by:4) {
                for x in stride(from:1,to:strip.width-1,by:4) {
                    let i = (y*strip.width+x)*4
                    guard strip.reference[i+3] == 255, strip.outer[i+3] == 255 else { continue }
                    for c in 0..<3 {
                        let a = Float(strip.reference[i+c])/255, b = Float(strip.outer[i+c])/255
                        if a > 0.06 && b > 0.06 && a < 0.94 && b < 0.94 {
                            logs[c].append(log(linear(a)/linear(b)))
                            pairs[c].append(SIMD2(b,a))
                        }
                    }
                }
            }
            if logs.allSatisfy({ $0.count >= 32 }) {
                let gain = SIMD3(exp(median(logs[0])),exp(median(logs[1])),exp(median(logs[2])))
                if (0..<3).allSatisfy({ gain[$0].isFinite }) {
                    // Saturation of one channel must not discard the other two
                    // estimates and silently revert an entire edge to unity.
                    // The actually clamped result is verified below.
                    gains[strip.edge] = simd_clamp(gain,SIMD3(repeating:0.5),SIMD3(repeating:2))
                }
            }
            for c in 0..<3 where pairs[c].count >= 32 {
                let samples = pairs[c]
                var slope:Float = 1, bias:Float = median(samples.map { $0.y-$0.x })
                for _ in 0..<4 {
                    var weight:Double = 0, sx:Double = 0, sy:Double = 0, sxx:Double = 0, sxy:Double = 0
                    for sample in samples {
                        let residual = abs(sample.y-slope*sample.x-bias)
                        let w = Double(min(1,0.03/max(0.0001,residual)))
                        weight += w; sx += w*Double(sample.x); sy += w*Double(sample.y)
                        sxx += w*Double(sample.x*sample.x); sxy += w*Double(sample.x*sample.y)
                    }
                    let variance = sxx-sx*sx/max(1,weight)
                    if variance/weight > 0.0001 { slope = max(0.5,min(2,Float((sxy-sx*sy/weight)/variance))) }
                    bias = max(-0.12,min(0.12,Float((sy-Double(slope)*sx)/max(1,weight))))
                }
                gains.encodedSlope[strip.edge][c] = slope
                gains.encodedBias[strip.edge][c] = bias
            }
        }
        return gains
    }

    /// Complete native support is divided into fixed tiles. Bounded ambiguous
    /// sets count as geometric evidence; an edge normal counts ONLY as visible
    /// directional evidence. Flat qualification is checked in BOTH native strips
    /// with ranges, variance AND a raw adjacent-pixel line detector.
    static func evaluate(_ strips: [Strip], gains: PeripheralEdgeGains,
                         segments: [PeripheralAlignmentWorker.SegmentEvidence],
                         analysisWidth: Int,analysisHeight: Int,
                         geometryVerified: Bool, severe: Double?, tolerance requestedTolerance: Double = PeripheralTolerance.defaultValue) -> Self {
        let tolerance = PeripheralTolerance.normalized(requestedTolerance)
        let factor = Float(tolerance)
        let visibleDistanceScale=pow(tolerance,0.25)
        let minimumNCC = Float(max(0.5,1-0.10*tolerance))
        var diagnostics: [[String: Any]] = [], passed = 0, total = 0
        var observableUpper = 0.0
        for strip in strips {
            let horizontal = strip.edge < 2, length = horizontal ? strip.width : strip.height
            let tileSize = max(1,Int((16*strip.nativeScale).rounded()))
            let gain = gains[strip.edge]
            let corrected = (0..<3).map { c in (0..<256).map { value -> Float in
                if gains.affine(strip.edge) { return max(0,Float(value)/255*gains.encodedSlope[strip.edge][c]+gains.encodedBias[strip.edge][c]) }
                return encode(linear(Float(value)/255)*gain[c])
            } }
            let lumaA: [Float] = stride(from:0,to:strip.reference.count,by:4).map { i in
                (Float(strip.reference[i])*0.2126+Float(strip.reference[i+1])*0.7152+Float(strip.reference[i+2])*0.0722)/255
            }
            let rawLumaB: [Float] = stride(from:0,to:strip.outer.count,by:4).map { i in
                (Float(strip.outer[i])*0.2126+Float(strip.outer[i+1])*0.7152+Float(strip.outer[i+2])*0.0722)/255
            }
            let samplesA=stride(from:0,to:lumaA.count,by:16).map {lumaA[$0]}.sorted()
            let samplesB=stride(from:0,to:rawLumaB.count,by:16).map {rawLumaB[$0]}.sorted()
            let n=max(1,samplesA.count),low=n/5,high=min(n-1,n*4/5)
            let rangeA=samplesA[high]-samplesA[low],rangeB=samplesB[high]-samplesB[low]
            let grayGain:Float = min(rangeA,rangeB)>0.05 ? max(0.5,min(2,rangeA/rangeB)):1
            let grayBias=samplesA[n/2]-grayGain*samplesB[n/2]
            // Geometry has its OWN grayscale normalization. The display RGB
            // model cannot suppress a geometrical defect or change its proof.
            let lumaB=rawLumaB.map {max(0,min(1,$0*grayGain+grayBias))}
            func lineAverage(_ values: [Float], horizontal: Bool) -> [Float] {
                var result = values
                let lines = horizontal ? strip.height : strip.width
                let length = horizontal ? strip.width : strip.height
                for line in 0..<lines {
                    func index(_ p: Int) -> Int {
                        let q = max(0,min(length-1,p))
                        return horizontal ? line*strip.width+q : q*strip.width+line
                    }
                    var sum:Float = 0
                    for p in -4...4 { sum += values[index(p)] }
                    for p in 0..<length {
                        result[index(p)] = sum/9
                        sum += values[index(p+5)]-values[index(p-4)]
                    }
                }
                return result
            }
            let horizontalA = lineAverage(lumaA,horizontal:true), horizontalB = lineAverage(lumaB,horizontal:true)
            let verticalA = lineAverage(lumaA,horizontal:false), verticalB = lineAverage(lumaB,horizontal:false)
            func periodicProfile(_ values:[Float]) -> Bool {
                let depth = min(horizontal ? strip.height : strip.width,max(1,Int(8*strip.nativeScale)))
                var profile = [Float](repeating:0,count:length)
                for t in 0..<length { for d in 0..<depth {
                    let x = horizontal ? t : (strip.edge == 3 ? strip.width-1-d : d)
                    let y = horizontal ? (strip.edge == 1 ? strip.height-1-d : d) : t
                    profile[t] += values[y*strip.width+x]/Float(depth)
                } }
                let mean = profile.reduce(0,+)/Float(length), middle = Float(length-1)/2
                var slope:Float = 0, denominator:Float = 0
                for i in 0..<length { let x = Float(i)-middle; slope += x*(profile[i]-mean); denominator += x*x }
                slope /= max(1,denominator)
                for i in 0..<length { profile[i] -= mean+slope*(Float(i)-middle) }
                guard sqrt(profile.reduce(0) { $0+$1*$1 }/Float(length)) > 0.008 else { return false }
                func correlation(_ lag:Int) -> Float {
                    var ab:Float = 0, aa:Float = 0, bb:Float = 0
                    for i in 0..<length-lag { ab += profile[i]*profile[i+lag]; aa += profile[i]*profile[i]; bb += profile[i+lag]*profile[i+lag] }
                    return ab/sqrt(max(1e-12,aa*bb))
                }
                let first = 2, last = min(length/3,Int(30*strip.nativeScale))
                guard first <= last else { return false }
                let fine = min(last,max(2,Int(4*strip.nativeScale)))
                let lags = Array(first...fine)+Array(stride(from:fine+1,through:last,by:max(1,Int(strip.nativeScale))))
                for lag in lags {
                    if correlation(lag) > 0.95 && correlation(max(1,lag/2)) < 0.5 { return true }
                }
                return false
            }
            func periodicTexture(_ values:[Float]) -> Bool {
                let depth=min(horizontal ? strip.height:strip.width,max(1,Int(8*strip.nativeScale)))
                let step=max(1,Int(2*strip.nativeScale)+1), deepStep=max(1,Int(strip.nativeScale)+1)
                func value(_ t:Int,_ d:Int)->Float {
                    let x=horizontal ? t:(strip.edge == 3 ? strip.width-1-d:d)
                    let y=horizontal ? (strip.edge == 1 ? strip.height-1-d:d):t
                    return values[y*strip.width+x]
                }
                func correlation(_ lag:Int)->Float {
                    var n:Float=0,aa:Float=0,bb:Float=0,ab:Float=0,sa:Float=0,sb:Float=0
                    for d in stride(from:0,to:depth,by:deepStep) {
                        for t in stride(from:d%step,to:length-lag,by:step) {
                            let a=value(t,d),b=value(t+lag,d)
                            n += 1;sa += a;sb += b;aa += a*a;bb += b*b;ab += a*b
                        }
                    }
                    let va=aa-sa*sa/max(1,n),vb=bb-sb*sb/max(1,n)
                    guard min(va,vb)/max(1,n)>0.008*0.008 else { return 0 }
                    return (ab-sa*sb/max(1,n))/sqrt(max(1e-12,va*vb))
                }
                let last=min(length/3,Int(30*strip.nativeScale)),fine=min(last,max(2,Int(4*strip.nativeScale)))
                guard fine>=2 else { return false }
                for lag in Array(2...fine)+Array(stride(from:fine+1,through:last,by:max(1,Int(strip.nativeScale)))) {
                    if correlation(lag)>0.97 && correlation(max(1,lag/2))<0.6 { return true }
                }
                return false
            }
            let nativePeriodic = periodicProfile(lumaA) || periodicProfile(lumaB) || periodicTexture(lumaA) || periodicTexture(lumaB)
            let span = max(1,Int(strip.nativeScale.rounded()))
            func edgeMaps(_ horizontal: [Float],_ vertical: [Float],threshold:Float) -> ([Bool],[Bool]) {
                var xEdges = [Bool](repeating:false,count:horizontal.count), yEdges = xEdges
                for y in 0..<strip.height { for x in 0..<strip.width {
                    let x0 = max(0,x-span), x1 = min(strip.width-1,x+span)
                    let y0 = max(0,y-span), y1 = min(strip.height-1,y+span)
                    let i = y*strip.width+x
                    xEdges[i] = abs(vertical[y*strip.width+x1]-vertical[y*strip.width+x0]) > threshold
                    yEdges[i] = abs(horizontal[y1*strip.width+x]-horizontal[y0*strip.width+x]) > threshold
                } }
                return (xEdges,yEdges)
            }
            // Hysteresis: a salient line must find even a weak counterpart.
            // The two lenses have different MTF; equal derivative thresholds
            // would reject a sharp edge against its correctly aligned blur.
            let ea = edgeMaps(horizontalA,verticalA,threshold:0.06), eb = edgeMaps(horizontalB,verticalB,threshold:0.06)
            let weakA = edgeMaps(horizontalA,verticalA,threshold:0.015), weakB = edgeMaps(horizontalB,verticalB,threshold:0.015)
            func distance(_ edges: [Bool]) -> [Int] {
                let w = strip.width, h = strip.height
                var values = edges.map { $0 ? 0 : w+h }
                for y in 0..<h { for x in 0..<w {
                    let i = y*w+x
                    if x > 0 { values[i] = min(values[i],values[i-1]+1) }
                    if y > 0 { values[i] = min(values[i],values[i-w]+1) }
                } }
                for y in stride(from:h-1,through:0,by:-1) { for x in stride(from:w-1,through:0,by:-1) {
                    let i = y*w+x
                    if x+1 < w { values[i] = min(values[i],values[i+1]+1) }
                    if y+1 < h { values[i] = min(values[i],values[i+w]+1) }
                } }
                return values
            }
            let dax = distance(weakA.0), day = distance(weakA.1), dbx = distance(weakB.0), dby = distance(weakB.1)
            for start in stride(from:0,to:length,by:tileSize) {
                total += 1
                let end = min(length,start+tileSize)
                let point = horizontal ? SIMD2(Float(Double(start+end)/2/strip.nativeScale),strip.edge == 0 ? 10 : Float(analysisHeight-11)) :
                    SIMD2(strip.edge == 2 ? 10 : Float(analysisWidth-11),Float(Double(start+end)/2/strip.nativeScale))
                let segment = segments.min { simd_distance_squared($0.point,point) < simd_distance_squared($1.point,point) }
                var a: [Float] = [], b: [Float] = [], differences: [Float] = []
                var maxGradientA: Float = 0, maxGradientB: Float = 0, maxStructureDifference: Float = 0
                var noiseA: [Float] = [], noiseB: [Float] = []
                var invalid = false, maxBadRun = 0, run = 0
                var structureRun = 0, maxStructureRun = 0, unsupportedLine = false
                var maxObservableDistance = 0
                var observableDistances:[Int]=[]
                var missingExtent=0.0
                var nativeSupportA = 0, nativeSupportB = 0
                var nativeWeakSupportA = 0, nativeWeakSupportB = 0
                for t in start..<end {
                    var badAlong = 0, countAlong = 0, missingAlong = 0
                    var missingWeight=0.0
                    let depth = min(horizontal ? strip.height : strip.width,max(3,Int(ceil(8*strip.nativeScale))))
                    for d in 0..<depth {
                        let x = horizontal ? t : (strip.edge == 3 ? strip.width-1-d : d)
                        let y = horizontal ? (strip.edge == 1 ? strip.height-1-d : d) : t
                        let i = (y*strip.width+x)*4
                        guard strip.reference[i+3] == 255, strip.outer[i+3] == 255 else { invalid = true; continue }
                        var error: Float = 0
                        for c in 0..<3 {
                            let va = Float(strip.reference[i+c])/255
                            let vb = corrected[c][Int(strip.outer[i+c])]
                            error = max(error,abs(va-vb))
                        }
                        a.append(lumaA[i/4]); b.append(lumaB[i/4]); differences.append(error)
                        if error > 0.20*factor { badAlong += 1 }; countAlong += 1
                        let at = i/4
                        var observedDistance = 0
                        if ea.0[at] || ea.1[at] { nativeSupportA += 1 }
                        if eb.0[at] || eb.1[at] { nativeSupportB += 1 }
                        if weakA.0[at] || weakA.1[at] { nativeWeakSupportA += 1 }
                        if weakB.0[at] || weakB.1[at] { nativeWeakSupportB += 1 }
                        if ea.0[at] { observedDistance = max(observedDistance,dbx[at]) }
                        if ea.1[at] { observedDistance = max(observedDistance,dby[at]) }
                        if eb.0[at] { observedDistance = max(observedDistance,dax[at]) }
                        if eb.1[at] { observedDistance = max(observedDistance,day[at]) }
                        maxObservableDistance = max(maxObservableDistance,observedDistance)
                        if ea.0[at] || ea.1[at] || eb.0[at] || eb.1[at] {observableDistances.append(observedDistance)}
                        let visibleDistance=Double(observedDistance)/strip.nativeScale/Double(min(analysisWidth,analysisHeight))
                        let fraction=max(0,min(1,(visibleDistance-0.025*visibleDistanceScale)/(0.04*visibleDistanceScale)))
                        missingWeight += fraction*fraction*(3-2*fraction)
                        if Double(observedDistance) > 3*tolerance*strip.nativeScale { missingAlong += 1 }
                        if x > 0 && x+1 < strip.width && (x+y)%4 == 0 {
                            noiseA.append(abs(lumaA[at-1]-2*lumaA[at]+lumaA[at+1]))
                            noiseB.append(abs(lumaB[at-1]-2*lumaB[at]+lumaB[at+1]))
                        }
                        // Integrate along each possible line, never across it.
                        // A 1-native-pixel vertical OR horizontal line survives;
                        // uncorrelated high-ISO grain is not called an edge.
                        if x+1 < strip.width {
                            let da = verticalA[at+1]-verticalA[at], db = verticalB[at+1]-verticalB[at]
                            maxGradientA = max(maxGradientA,abs(da)); maxGradientB = max(maxGradientB,abs(db))
                            maxStructureDifference = max(maxStructureDifference,abs(da-db))
                        }
                        if y+1 < strip.height {
                            let da = horizontalA[at+strip.width]-horizontalA[at], db = horizontalB[at+strip.width]-horizontalB[at]
                            maxGradientA = max(maxGradientA,abs(da)); maxGradientB = max(maxGradientB,abs(db))
                            maxStructureDifference = max(maxStructureDifference,abs(da-db))
                        }
                    }
                    // Measure the actual extent along the seam, rather than
                    // counting an entire 16-pixel tile for a thin edge that
                    // crosses a tile boundary during a subpixel camera move.
                    missingExtent += min(1,missingWeight/max(1,3*strip.nativeScale))
                    if missingAlong > 0 { structureRun += 1; maxStructureRun = max(maxStructureRun,structureRun) } else { structureRun = 0 }
                    if missingAlong >= max(3,countAlong/3) { unsupportedLine = true }
                    if badAlong > max(1,countAlong/8) { run += 1; maxBadRun = max(maxBadRun,run) } else { run = 0 }
                }
                let sigmaA = median(noiseA)/1.652, sigmaB = median(noiseB)/1.652
                observableDistances.sort()
                let robustObservableDistance=observableDistances.isEmpty ? 0:
                    observableDistances[min(observableDistances.count-1,observableDistances.count*4/5)]
                func flat(_ values: [Float],_ gradient: Float,_ sigma: Float) -> Bool {
                    guard !values.isEmpty else { return false }
                    let mean = values.reduce(0,+)/Float(values.count)
                    let deviation = sqrt(values.reduce(0) { $0+($1-mean)*($1-mean) }/Float(values.count))
                    var histogram = [Int](repeating:0,count:512)
                    for value in values { histogram[max(0,min(511,Int(value*255)))] += 1 }
                    var count = 0, low = 0, high = 511
                    for i in histogram.indices {
                        count += histogram[i]
                        if count <= values.count/100 { low = i }
                        if count >= values.count*99/100 { high = i; break }
                    }
                    let range = Float(high-low)/255
                    let structuralDeviation = sqrt(max(0,deviation*deviation-sigma*sigma))
                    // Tolerance may allow a larger OFFSET; it must not turn
                    // real keyboard/text structure into a featureless wall.
                    return structuralDeviation <= 0.03 && range-4.65*sigma <= 0.10 && gradient <= max(0.04,1.5*sigma)
                }
                let isFlat = flat(a,maxGradientA,sigmaA) && flat(b,maxGradientB,sigmaB)
                let meanA = a.reduce(0,+)/Float(max(1,a.count)), meanB = b.reduce(0,+)/Float(max(1,b.count))
                var covariance:Float = 0, varianceA:Float = 0, varianceB:Float = 0
                for i in a.indices {
                    let x=a[i]-meanA,y=b[i]-meanB
                    covariance += x*y;varianceA += x*x;varianceB += y*y
                }
                let grayNCC = covariance/sqrt(max(1e-12,varianceA*varianceB))
                let grayVarianceA=varianceA/Float(max(1,a.count)),grayVarianceB=varianceB/Float(max(1,b.count))
                var errorHistogram = [Int](repeating:0,count:512)
                for value in differences { errorHistogram[max(0,min(511,Int(value*255)))] += 1 }
                func percentile(_ fraction:Float) -> Float {
                    guard !differences.isEmpty else { return .infinity }
                    var count = 0
                    for i in errorHistogram.indices {
                        count += errorHistogram[i]
                        if Float(count) >= Float(differences.count)*fraction { return Float(i)/255 }
                    }
                    return 2
                }
                let medianError = percentile(0.5), p90 = percentile(0.9)
                let structurePass = !unsupportedLine && maxStructureRun < max(2,Int(2*tolerance*strip.nativeScale))
                let colorPass = !invalid && structurePass && medianError <= 0.08*factor && p90 <= factor*min(0.24,0.16+2*max(sigmaA,sigmaB)) && maxBadRun < max(2,Int(2*tolerance*strip.nativeScale))
                let bounded = segment?.searchComplete == true && (segment?.interval?.upperBound ?? 1) < 0.08
                let normal = segment?.searchComplete == true && (segment?.normalInterval?.upperBound ?? 1) < 0.05
                // One lens may resolve a salient line while the other's MTF
                // leaves only its weak counterpart. Requiring strong support
                // in BOTH would undo the bidirectional hysteresis check above.
                // A strong line is still necessary on at least one side; its
                // counterpart distance and missing-support runs remain checked.
                let pairedNativeSupport = (nativeSupportA >= 3 && nativeWeakSupportB >= 3) ||
                    (nativeSupportB >= 3 && nativeWeakSupportA >= 3)
                let nativeNormalProof = pairedNativeSupport && structurePass && segment?.repeatedStructure != true
                let nativeDirectional = nativeNormalProof && !nativePeriodic && (geometryVerified || maxObservableDistance <= Int(3*tolerance*strip.nativeScale))
                // Geometry is determined by grayscale structure. A pixelwise
                // RGB difference near a correctly matched edge is not another
                // displacement/occlusion measurement. Flat, unobservable areas
                // still need the actual bounded display-color agreement.
                let currentGrayAgreement = min(grayVarianceA,grayVarianceB) > Float(0.25/(255*255)) &&
                    grayVarianceA > 4*sigmaA*sigmaA && grayVarianceB > 4*sigmaB*sigmaB && grayNCC >= minimumNCC && !nativePeriodic
                let qualified = (isFlat && !nativePeriodic && colorPass) || nativeDirectional ||
                    currentGrayAgreement || (geometryVerified && (bounded || normal))
                let good = qualified && !invalid && structurePass
                if good { passed += 1 }
                var tileObservableUpper = 0.0
                if nativeDirectional {
                    // Visible normal structure is measured here. Tangential
                    // alternatives from a separate 2D set are still recorded,
                    // but are not relabeled visible edge displacement.
                    tileObservableUpper = (Double(maxObservableDistance)/strip.nativeScale+1)/Double(min(analysisWidth,analysisHeight))
                } else if normal { tileObservableUpper = segment?.normalInterval?.upperBound ?? 0 }
                else if bounded { tileObservableUpper = segment?.interval?.upperBound ?? 0 }
                if good { observableUpper = max(observableUpper,tileObservableUpper) }
                diagnostics.append(["edge":strip.edge,"start":start,"end":end,"nativeScale":strip.nativeScale,
                    "flatBothNative":isFlat,"boundedCandidates":bounded,"normalBounded":normal,
                    "colorPass":colorPass,"passed":good,"medianRGBError":medianError,"p90RGBError":p90,
                    "maxBadRunNativePixels":maxBadRun,"maximumRawGradient":[maxGradientA,maxGradientB],
                    "nativeNoiseSigma":[sigmaA,sigmaB],"maxStructureDifference":maxStructureDifference,
                    "nativeDirectional":nativeDirectional,"nativeStructurePass":structurePass,
                    "maxUnsupportedStructureRun":maxStructureRun,"unsupportedLine":unsupportedLine,
                    "maxObservableDistanceNative":maxObservableDistance,
                    "robustObservableDistanceNative":robustObservableDistance,"nativeSampleCount":a.count,
                    "missingStructureExtentFraction":missingExtent/Double(max(1,end-start)),
                    "nativeEdgeSupport":[nativeSupportA,nativeSupportB],
                    "nativeWeakEdgeSupport":[nativeWeakSupportA,nativeWeakSupportB],
                    "visibleErrorUpper":tileObservableUpper,
                    "nativePeriodicProfile":nativePeriodic,
                    "currentNativeGrayNCC":grayNCC,"currentNativeGrayAgreement":currentGrayAgreement,
                    "currentNativeGrayVariance":[grayVarianceA,grayVarianceB],
                    "geometryGrayGain":grayGain,"geometryGrayBias":grayBias,
                    "segmentVisibleShiftLower":max(segment?.interval?.lowerBound ?? 0,segment?.normalInterval?.lowerBound ?? 0),
                    "segmentVisibleShiftUpper":(segment?.interval ?? segment?.normalInterval)?.upperBound ?? Double.nan,
                    "segmentSearchComplete":segment?.searchComplete ?? false,
                    "segmentStatus":segment?.status.rawValue ?? "unobservable",
                    "segmentNormalLower":segment?.normalInterval?.lowerBound ?? Double.nan,
                    "segmentNormalUpper":segment?.normalInterval?.upperBound ?? Double.nan,
                    "segmentPoint":segment.map {[$0.point.x,$0.point.y]} ?? [],
                    "segmentBestDisplacement":segment?.best.map {[$0.x,$0.y]} ?? [],
                    "segmentForwardBackward":segment?.forwardBackward ?? Float.nan,
                    "segmentDisplacementUncertainty":segment?.displacementUncertainty ?? Float.nan,
                    "segmentPeak":segment?.peak ?? Float.nan,
                    "segmentRepeated":segment?.repeatedStructure ?? false,
                    "tolerance":tolerance,"minimumGrayNCC":minimumNCC,
                    "maximumStructureDistanceAnalysisPixels":3*tolerance,
                    "segment":segment?.index ?? -1])
            }
        }
        let coverage = Double(passed)/Double(max(1,total))
        let good = total > 0 && passed == total && (severe ?? 0) <= PeripheralGlassPolicy.darkeningThreshold
        return .init(strips:strips,gains:gains,evidence:.init(compatible:good,coverage:coverage,
            maximumObservableError:observableUpper > 0 ? observableUpper : nil,
            reason:good ? "native-visible-seam" : "native-seam-unresolved-or-mismatch",
            nativeSupportChecked:total > 0),diagnostics:diagnostics)
    }

    /// Both candidates are bounded radiometric models, fitted on a fixed 1/16
    /// pixel grid. A separate holdout selects one; full native support then
    /// validates that model and the independent grayscale geometry. Select one model
    /// per WHOLE edge, never a convenient residual per pixel. Equal results keep
    /// the previous model; actual gains/bias travel with the immutable texture.
    static func selectPhotometry(_ strips:[Strip],candidate:PeripheralEdgeGains,preferred:PeripheralEdgeGains?,
        segments:[PeripheralAlignmentWorker.SegmentEvidence],analysisWidth:Int,analysisHeight:Int,
        geometryVerified:Bool,severe:Double?,tolerance:Double = PeripheralTolerance.defaultValue) -> Self {
        var linear = candidate; linear.usesEncodedAffine = false
        linear.encodedAffineEdges = [Bool](repeating:false,count:4)
        var selected=linear
        for strip in strips {
            let side=strip.edge
            let tables=(0..<2).map { model in (0..<3).map { c in (0..<256).map { code -> Float in
                let value=Float(code)/255
                return model == 0 ? encode(self.linear(value)*candidate[side][c]) :
                    max(0,value*candidate.encodedSlope[side][c]+candidate.encodedBias[side][c])
            } } }
            var scores=[Float](repeating:0,count:2),count:Float=0
            // Independent from the fit grid (offset 1, step 4): choose ONE
            // whole-edge model using offset 2, then validate ALL native pixels.
            for y in stride(from:2,to:strip.height,by:4) {for x in stride(from:2,to:strip.width,by:4) {
                let i=(y*strip.width+x)*4
                guard strip.reference[i+3] == 255,strip.outer[i+3] == 255 else {continue}
                for c in 0..<3 {for model in 0..<2 {
                    let error=abs(Float(strip.reference[i+c])/255-tables[model][c][Int(strip.outer[i+c])])
                    scores[model] += error<=0.05 ? error*error:0.1*error-0.0025
                }}
                count += 3
            }}
            let a=scores[0]/max(1,count),b=scores[1]/max(1,count)
            selected.encodedAffineEdges[side] = b<a*0.95-0.00001 ||
                (!(a<b*0.95-0.00001) && preferred?.affine(side) == true)
        }
        return evaluate(strips,gains:selected,segments:segments,analysisWidth:analysisWidth,analysisHeight:analysisHeight,
            geometryVerified:geometryVerified,severe:severe,tolerance:tolerance)
    }
}
