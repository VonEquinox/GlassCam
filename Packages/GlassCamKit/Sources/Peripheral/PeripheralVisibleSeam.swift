import ImagingCore
import Foundation
import CoreImage
import simd

/// Bounded per-edge linear gains and sRGB affine models. Metal and the native
/// verifier apply the selected model in the same transfer-function domain.
public struct PeripheralEdgeGains {
    public var top = SIMD3<Float>(repeating: 1)
    public var bottom = SIMD3<Float>(repeating: 1)
    public var left = SIMD3<Float>(repeating: 1)
    public var right = SIMD3<Float>(repeating: 1)
    public var encodedSlope = [SIMD3<Float>](repeating:SIMD3(repeating:1),count:4)
    public var encodedBias = [SIMD3<Float>](repeating:.zero,count:4)
    var usesEncodedAffine = false
    var encodedAffineEdges = [Bool](repeating:false,count:4)
    public func affine(_ side:Int) -> Bool { usesEncodedAffine || encodedAffineEdges[side] }
    package subscript(_ edge: Int) -> SIMD3<Float> {
        get { [top,bottom,left,right][edge] }
        set { switch edge { case 0: top = newValue; case 1: bottom = newValue; case 2: left = newValue; default: right = newValue } }
    }
}

package struct PeripheralNativeSeam {
    package struct Strip {
        package let edge: Int
        package let width: Int, height: Int
        package let reference: [UInt8], outer: [UInt8]
        package let nativeScale: Double
    }
    package struct TileDiagnostic {
        package var edge: Int
        package var start: Int
        package var passed: Bool
        package var nativeEdgeSupport: SIMD2<Int>
        package var nativeWeakEdgeSupport: SIMD2<Int>
        package var currentNativeGrayVariance: SIMD2<Double>
        package var nativeNoiseSigma: SIMD2<Double>
        package var currentNativeGrayNCC: Double
        package var segmentVisibleShiftUpper: Double?
        package var segmentVisibleShiftLower: Double
        package var segmentNormalUpper: Double?
        package var segmentNormalLower: Double
        package var segmentStatus: String?
        package var segmentSearchComplete: Bool
        package var segmentRepeated: Bool
        package var segmentPeak: Double
        package var observableDistanceNative: Double
        package var nativeScale: Double
        package var nativeSampleCount: Double
        package var flatBothNative: Bool
        package var segmentForwardBackward: Double?
        package var segmentPoint: SIMD2<Double>?
        package var segmentBestDisplacement: SIMD2<Double>?
        package var segment: Int
        package var segmentDisplacementUncertainty: Double?
        package var missingStructureExtentFraction: Double?

        init(dictionary row: [String: Any]) {
            edge = row["edge"] as? Int ?? 0
            start = row["start"] as? Int ?? 0
            passed = row["passed"] as? Bool ?? false
            let support = row["nativeEdgeSupport"] as? [Int] ?? []
            nativeEdgeSupport = support.count == 2 ? SIMD2(support[0], support[1]) : SIMD2(-1, -1)
            let weak = row["nativeWeakEdgeSupport"] as? [Int] ?? []
            nativeWeakEdgeSupport = weak.count == 2 ? SIMD2(weak[0], weak[1]) : SIMD2(-1, -1)
            let variances = (row["currentNativeGrayVariance"] as? [NSNumber])?.map(\.doubleValue) ?? []
            currentNativeGrayVariance = variances.count == 2 ? SIMD2(variances[0], variances[1]) : SIMD2(-1, -1)
            let noise = (row["nativeNoiseSigma"] as? [NSNumber])?.map(\.doubleValue) ?? []
            nativeNoiseSigma = noise.count == 2 ? SIMD2(noise[0], noise[1]) : SIMD2(-1, -1)
            currentNativeGrayNCC = (row["currentNativeGrayNCC"] as? NSNumber)?.doubleValue ?? 0
            segmentVisibleShiftUpper = (row["segmentVisibleShiftUpper"] as? NSNumber)?.doubleValue
            segmentVisibleShiftLower = (row["segmentVisibleShiftLower"] as? NSNumber)?.doubleValue ?? 0
            segmentNormalUpper = (row["segmentNormalUpper"] as? NSNumber)?.doubleValue
            segmentNormalLower = (row["segmentNormalLower"] as? NSNumber)?.doubleValue ?? 0
            segmentStatus = row["segmentStatus"] as? String
            segmentSearchComplete = row["segmentSearchComplete"] as? Bool ?? false
            segmentRepeated = row["segmentRepeated"] as? Bool ?? false
            segmentPeak = (row["segmentPeak"] as? NSNumber)?.doubleValue ?? .nan
            observableDistanceNative = (row["robustObservableDistanceNative"] as? NSNumber)?.doubleValue ??
                (row["maxObservableDistanceNative"] as? NSNumber)?.doubleValue ?? 0
            nativeScale = (row["nativeScale"] as? NSNumber)?.doubleValue ?? 1
            nativeSampleCount = (row["nativeSampleCount"] as? NSNumber)?.doubleValue ?? 0
            flatBothNative = row["flatBothNative"] as? Bool ?? false
            segmentForwardBackward = (row["segmentForwardBackward"] as? NSNumber)?.doubleValue
            if let point = (row["segmentPoint"] as? [NSNumber])?.map(\.doubleValue), point.count == 2 {
                segmentPoint = SIMD2(point[0], point[1])
            } else { segmentPoint = nil }
            if let offset = (row["segmentBestDisplacement"] as? [NSNumber])?.map(\.doubleValue), offset.count == 2 {
                segmentBestDisplacement = SIMD2(offset[0], offset[1])
            } else { segmentBestDisplacement = nil }
            segment = row["segment"] as? Int ?? -1
            segmentDisplacementUncertainty = (row["segmentDisplacementUncertainty"] as? NSNumber)?.doubleValue
            missingStructureExtentFraction = (row["missingStructureExtentFraction"] as? NSNumber)?.doubleValue
        }

        init(edge: Int, start: Int, passed: Bool, nativeEdgeSupport: SIMD2<Int>, nativeWeakEdgeSupport: SIMD2<Int>,
             currentNativeGrayVariance: SIMD2<Double>, nativeNoiseSigma: SIMD2<Double>, currentNativeGrayNCC: Double,
             segmentVisibleShiftUpper: Double?, segmentVisibleShiftLower: Double, segmentNormalUpper: Double?,
             segmentNormalLower: Double, segmentStatus: String?, segmentSearchComplete: Bool, segmentRepeated: Bool,
             segmentPeak: Double, observableDistanceNative: Double, nativeScale: Double, nativeSampleCount: Double,
             flatBothNative: Bool, segmentForwardBackward: Double?, segmentPoint: SIMD2<Double>?,
             segmentBestDisplacement: SIMD2<Double>?, segment: Int, segmentDisplacementUncertainty: Double?,
             missingStructureExtentFraction: Double?) {
            self.edge = edge; self.start = start; self.passed = passed
            self.nativeEdgeSupport = nativeEdgeSupport; self.nativeWeakEdgeSupport = nativeWeakEdgeSupport
            self.currentNativeGrayVariance = currentNativeGrayVariance; self.nativeNoiseSigma = nativeNoiseSigma
            self.currentNativeGrayNCC = currentNativeGrayNCC
            self.segmentVisibleShiftUpper = segmentVisibleShiftUpper; self.segmentVisibleShiftLower = segmentVisibleShiftLower
            self.segmentNormalUpper = segmentNormalUpper; self.segmentNormalLower = segmentNormalLower
            self.segmentStatus = segmentStatus; self.segmentSearchComplete = segmentSearchComplete
            self.segmentRepeated = segmentRepeated; self.segmentPeak = segmentPeak
            self.observableDistanceNative = observableDistanceNative; self.nativeScale = nativeScale
            self.nativeSampleCount = nativeSampleCount; self.flatBothNative = flatBothNative
            self.segmentForwardBackward = segmentForwardBackward; self.segmentPoint = segmentPoint
            self.segmentBestDisplacement = segmentBestDisplacement; self.segment = segment
            self.segmentDisplacementUncertainty = segmentDisplacementUncertainty
            self.missingStructureExtentFraction = missingStructureExtentFraction
        }
    }
    package let gains: PeripheralEdgeGains
    package let evidence: PeripheralVisibleEvidence
    package let tiles: [TileDiagnostic]
    package let diagnostics: [[String: Any]]

    package init(gains: PeripheralEdgeGains, evidence: PeripheralVisibleEvidence, diagnostics: [[String: Any]]) {
        self.gains = gains
        self.evidence = evidence
        self.diagnostics = diagnostics
        self.tiles = diagnostics.map(TileDiagnostic.init(dictionary:))
    }

    package init(gains: PeripheralEdgeGains, evidence: PeripheralVisibleEvidence, tiles: [TileDiagnostic]) {
        self.gains = gains
        self.evidence = evidence
        self.tiles = tiles
        self.diagnostics = []
    }

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

    /// Complete native support is divided into fixed tiles. Bounded ambiguous
    /// sets count as geometric evidence; an edge normal counts ONLY as visible
    /// directional evidence. Flat qualification is checked in BOTH native strips
    /// with ranges, variance AND a raw adjacent-pixel line detector.
    static func evaluate(_ strips: [Strip], gains: PeripheralEdgeGains,
                         segments: [PeripheralAlignmentWorker.SegmentEvidence],
                         analysisWidth: Int,analysisHeight: Int,
                         geometryVerified: Bool, severe: Double?, tolerance requestedTolerance: Double = PeripheralAlignmentWorker.matchingTolerance) -> Self {
        let tolerance = requestedTolerance.isFinite && requestedTolerance > 0 ? requestedTolerance : PeripheralAlignmentWorker.matchingTolerance
        let factor = Float(tolerance)
        let visibleDistanceScale=pow(tolerance,0.25)
        let minimumNCC = Float(max(0.5,1-0.10*tolerance))
        var tiles: [TileDiagnostic] = [], passed = 0, total = 0
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
                tiles.append(TileDiagnostic(
                    edge: strip.edge,
                    start: start,
                    passed: good,
                    nativeEdgeSupport: SIMD2(nativeSupportA, nativeSupportB),
                    nativeWeakEdgeSupport: SIMD2(nativeWeakSupportA, nativeWeakSupportB),
                    currentNativeGrayVariance: SIMD2(Double(grayVarianceA), Double(grayVarianceB)),
                    nativeNoiseSigma: SIMD2(Double(sigmaA), Double(sigmaB)),
                    currentNativeGrayNCC: Double(grayNCC),
                    segmentVisibleShiftUpper: (segment?.interval ?? segment?.normalInterval)?.upperBound ?? Double.nan,
                    segmentVisibleShiftLower: max(segment?.interval?.lowerBound ?? 0, segment?.normalInterval?.lowerBound ?? 0),
                    segmentNormalUpper: segment?.normalInterval?.upperBound ?? Double.nan,
                    segmentNormalLower: segment?.normalInterval?.lowerBound ?? Double.nan,
                    segmentStatus: segment?.status.rawValue ?? "unobservable",
                    segmentSearchComplete: segment?.searchComplete ?? false,
                    segmentRepeated: segment?.repeatedStructure ?? false,
                    segmentPeak: Double(segment?.peak ?? Float.nan),
                    observableDistanceNative: Double(robustObservableDistance),
                    nativeScale: strip.nativeScale,
                    nativeSampleCount: Double(a.count),
                    flatBothNative: isFlat,
                    segmentForwardBackward: Double(segment?.forwardBackward ?? Float.nan),
                    segmentPoint: segment.map { SIMD2(Double($0.point.x), Double($0.point.y)) },
                    segmentBestDisplacement: segment?.best.map { SIMD2(Double($0.x), Double($0.y)) },
                    segment: segment?.index ?? -1,
                    segmentDisplacementUncertainty: Double(segment?.displacementUncertainty ?? Float.nan),
                    missingStructureExtentFraction: missingExtent / Double(max(1, end - start))
                ))
            }
        }
        let coverage = Double(passed)/Double(max(1,total))
        let good = total > 0 && passed == total && (severe ?? 0) <= PeripheralEvidence.displayErrorThreshold
        return .init(gains:gains,evidence:.init(compatible:good,coverage:coverage,
            maximumObservableError:observableUpper > 0 ? observableUpper : nil,
            reason:good ? "native-visible-seam" : "native-seam-unresolved-or-mismatch",
            nativeSupportChecked:total > 0),tiles:tiles)
    }

}
