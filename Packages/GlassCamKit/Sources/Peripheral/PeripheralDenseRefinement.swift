import ImagingCore
import Foundation
import CoreImage
import Vision
import QuartzCore
import simd

/// A spatial proposal, never a certificate. The fast worker checks the CURRENT
/// native boundary after applying this proposal to the current original pair.
public struct PeripheralDenseRefinement {
    public let id: UInt64
    let epoch: UInt64
    let sourcePairID: UInt64
    let homography: simd_float3x3
    let width: Int, height: Int
    /// Top-to-bottom Vision pixels, converted to CI vectors (dx, -dy).
    let rgba: [Float]
    let consistentFraction: Double
    var elapsedMS: Double
    let maximumOffset: Float
    var algorithm = "synthetic-or-unspecified"
    var candidateScores: [String:Double] = [:]

    private static let kernel: CIKernel? = {
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        [[stitchable]] float4 refinePeripheral(coreimage::sampler image,
            coreimage::sampler field, float2 size, float2 scale,
            coreimage::destination destination) {
            float2 p = destination.coord();
            float2 q = clamp(p, float2(0.5), size-float2(0.5));
            float2 delta = field.sample(field.transform(q)).rg*scale;
            return image.sample(image.transform(p+delta));
        }
        """
        return try? CIKernel.kernels(withMetalString:source).first
    }()

    func outerImage(_ outer: CIImage, centerSize: CGSize, ratio: Float, strength: Float = 1) -> CIImage? {
        guard let kernel = Self.kernel else { return nil }
        let w = centerSize.width, h = centerSize.height
        let affine = CGAffineTransform(a:w*Double(ratio)/outer.extent.width,b:0,c:0,
            d:h*Double(ratio)/outer.extent.height,tx:w*(1-Double(ratio))/2,ty:h*(1-Double(ratio))/2)
        let s = simd_float3x3(SIMD3(Float(w/192),0,0),SIMD3(0,Float(w/192),0),SIMD3(0,0,1))
        let nativeH = s*homography*s.inverse
        guard let aligned = PeripheralAlignmentWorker.warp(outer.transformed(by:affine),by:nativeH) else { return nil }
        let field = rgba.withUnsafeBytes {
            CIImage(bitmapData:Data($0),bytesPerRow:width*16,size:CGSize(width:width,height:height),
                format:.RGBAf,colorSpace:nil)
        }.transformed(by:CGAffineTransform(scaleX:w/Double(width),y:h/Double(height)))
        let extra = CGFloat(maximumOffset)*max(w,h)+4
        guard let corrected = kernel.apply(extent:aligned.extent,roiCallback:{ i,r in
            i == 0 ? r.insetBy(dx:-extra,dy:-extra) : CGRect(x:0,y:0,width:w,height:h)
        },arguments:[aligned,field,CIVector(x:w,y:h),CIVector(x:w/Double(width)*Double(strength),y:h/Double(height)*Double(strength))]),
              let back = PeripheralAlignmentWorker.warp(corrected,by:nativeH.inverse) else { return nil }
        return back.transformed(by:affine.inverted()).cropped(to:outer.extent)
    }
}

/// Heavy bidirectional optical flow runs independently of 60 Hz drawing and
/// the fast observation worker. A heavy solve cannot extend the 200 ms age of
/// any displayed pixels; every reused proposal needs current native validation.
final class PeripheralDenseSolver {
    private let queue = DispatchQueue(label:"dev.glasscam.peripheral.dense",qos:.userInitiated)
    private let lock = NSLock()
    private var epoch: UInt64 = .max
    private var generation: UInt64 = 0
    private var busy = false
    private var lastRequest = -Double.infinity
    private var proposal: PeripheralDenseRefinement?
    private var status = "not-requested"
    private var elapsed = 0.0
    func reset(epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.epoch = epoch; generation &+= 1; proposal = nil; lastRequest = -.infinity; status = "not-requested"
    }
    func latest(epoch: UInt64) -> PeripheralDenseRefinement? {
        lock.lock(); defer { lock.unlock() }
        return self.epoch == epoch ? proposal : nil
    }
    func diagnostic() -> [String:Any] {
        lock.lock(); defer { lock.unlock() }
        return ["status":status,"busy":busy,"elapsedMS":elapsed,"proposalID":proposal?.id ?? 0,
            "sourcePairID":proposal?.sourcePairID ?? 0,"consistentFraction":proposal?.consistentFraction ?? 0]
    }
    @discardableResult
    func request(_ pair:PeripheralFrameSource.Pair, homography:simd_float3x3,seams:PeripheralSeams = .all) -> Bool {
        lock.lock()
        let time = CACurrentMediaTime()
        guard epoch == pair.epoch, !busy, time-lastRequest >= max(0.30,elapsed/1000*2) else { lock.unlock(); return false }
        busy = true; lastRequest = time; status = "computing-grayscale-bidirectional-flow"
        let token = generation; lock.unlock()
        queue.async { [self,pair] in
            let start = CACurrentMediaTime()
            var value: PeripheralDenseRefinement?, errorText: String?
            autoreleasepool {
                do { value = try Self.compute(pair,homography:homography,id:UInt64(start*1_000_000),seams:seams) }
                catch { errorText = error.localizedDescription }
            }
            lock.lock(); defer { lock.unlock() }
            busy = false
            guard generation == token, epoch == pair.epoch else { return }
            elapsed = (CACurrentMediaTime()-start)*1000
            if let value { proposal = value; status = "proposal-awaiting-current-native-validation" }
            else { status = errorText ?? "no-consistent-flow-proposal" }
        }
        return true
    }

    static func compute(_ pair:PeripheralFrameSource.Pair,homography:simd_float3x3,id:UInt64,seams:PeripheralSeams = .all) throws -> PeripheralDenseRefinement? {
        let start = CACurrentMediaTime(), w = 384
        let center = CIImage(cvPixelBuffer:pair.center), raw = CIImage(cvPixelBuffer:pair.outer)
        let h = Int((Double(w)*center.extent.height/center.extent.width).rounded())
        let pad=32,pw=w+2*pad,ph=h+2*pad
        let bounds = CGRect(x:-pad,y:-pad,width:pw,height:ph)
        let a = center.transformed(by:CGAffineTransform(scaleX:Double(w)/center.extent.width,y:Double(h)/center.extent.height))
        let floating = raw.transformed(by:CGAffineTransform(a:Double(w)*Double(pair.ratio)/raw.extent.width,b:0,c:0,
            d:Double(h)*Double(pair.ratio)/raw.extent.height,tx:Double(w)*(1-Double(pair.ratio))/2,ty:Double(h)*(1-Double(pair.ratio))/2))
        let s = simd_float3x3(SIMD3(Float(w)/192,0,0),SIMD3(0,Float(w)/192,0),SIMD3(0,0,1))
        guard let b = PeripheralAlignmentWorker.warp(floating,by:s*homography*s.inverse) else { return nil }
        let context = CIContext(options:[.cacheIntermediates:false])
        func gray(_ image:CIImage) -> (image:CIImage,pixels:[UInt8]) {
            let source = image.clampedToExtent().cropped(to:bounds).applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0])
            var pixels = [UInt8](repeating:0,count:pw*ph*4)
            pixels.withUnsafeMutableBytes { context.render(source,toBitmap:$0.baseAddress!,rowBytes:pw*4,bounds:bounds,
                format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) }
            var histogram = [Int](repeating:0,count:256)
            for y in stride(from:pad,to:pad+h,by:4) {for x in stride(from:pad,to:pad+w,by:4) {
                histogram[Int(pixels[(y*pw+x)*4])] += 1
            }}
            let count = histogram.reduce(0,+)
            func percentile(_ f:Double)->Double { var n=0; for i in 0..<256 { n += histogram[i];if Double(n) >= Double(count)*f { return Double(i)/255 } };return 1 }
            let low=percentile(0.1), high=percentile(0.9), gain=min(4,0.70/max(0.05,high-low)), bias=0.15-gain*low
            // This normalization is ONLY for matching. The rendered texture is
            // the original color source with separately estimated photometry.
            // Estimate and apply in the SAME encoded grayscale domain. A CI
            // color matrix could instead operate in the linear working space.
            for i in stride(from:0,to:pixels.count,by:4) {
                let value = UInt8(max(0,min(255,Int((Double(pixels[i])*gain+255*bias).rounded()))))
                pixels[i]=value;pixels[i+1]=value;pixels[i+2]=value;pixels[i+3]=255
            }
            return (CIImage(bitmapData:Data(pixels),bytesPerRow:pw*4,size:CGSize(width:pw,height:ph),
                format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!),pixels)
        }
        let first = gray(a), second = gray(b)
        func flow(_ from:CIImage,_ to:CIImage,revision:Int) throws -> [SIMD2<Float>] {
            try autoreleasepool {
                let request = VNGenerateOpticalFlowRequest(targetedCIImage:to,orientation:.up)
                request.revision = revision
                request.preferBackgroundProcessing = true
                request.computationAccuracy = .veryHigh
                request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
                try VNImageRequestHandler(ciImage:from,orientation:.up).perform([request])
                guard let buffer = request.results?.first?.pixelBuffer,
                      CVPixelBufferGetWidth(buffer) == pw,CVPixelBufferGetHeight(buffer) == ph,
                      CVPixelBufferLockBaseAddress(buffer,.readOnly) == kCVReturnSuccess else { return [] }
                defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
                let stride = CVPixelBufferGetBytesPerRow(buffer)/4
                guard let p = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to:Float.self) else { return [] }
                var values = [SIMD2<Float>](repeating:.zero,count:pw*ph)
                for y in 0..<ph { for x in 0..<pw { values[y*pw+x] = SIMD2(p[y*stride+2*x],p[y*stride+2*x+1]) } }
                return values
            }
        }
        var chosen:PeripheralDenseRefinement?,bestScore = -Double.infinity,scores:[String:Double]=[:]
        let tileCount=(seams.contains(.horizontal) ? 2*((w+15)/16):0)+(seams.contains(.vertical) ? 2*((h+15)/16):0)
        for revision in [VNGenerateOpticalFlowRequestRevision1,VNGenerateOpticalFlowRequestRevision2] {
        let f = try flow(first.image,second.image,revision:revision), r = try flow(second.image,first.image,revision:revision)
        guard f.count == pw*ph,r.count == pw*ph else { continue }
        var data = [Float](repeating:0,count:w*h*4), consistent = 0, observed = 0
        var reference=[UInt8](repeating:255,count:w*h*4),predicted=reference
        var maximum:Float = 0
        let limit = Float(min(w,h))*0.08
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x,v = f[(y+pad)*pw+x+pad]
            let finite = v.x.isFinite && v.y.isFinite
            let q = SIMD2(Float(x+pad),Float(y+pad))+v
            var valid = false
            if finite, simd_length(v) <= limit,q.x >= 1,q.y >= 1,q.x < Float(pw-2),q.y < Float(ph-2) {
                let x0=Int(q.x),y0=Int(q.y),u=q.x-Float(x0),t=q.y-Float(y0)
                let back = (r[y0*pw+x0]*(1-u)+r[y0*pw+x0+1]*u)*(1-t)+(r[(y0+1)*pw+x0]*(1-u)+r[(y0+1)*pw+x0+1]*u)*t
                valid = simd_length(v+back) <= 1.5+0.03*simd_length(v)
            }
            if min(x,w-1-x) < 20 || min(y,h-1-y) < 20 { observed += 1;if valid { consistent += 1 } }
            // Invalid flow is only a zero-offset PROPOSAL. Current native
            // support remains mandatory and can reject it; it is not zero error.
            if valid {
                data[i*4]=v.x;data[i*4+1] = -v.y;data[i*4+2]=1
                maximum=max(maximum,max(abs(v.x)/Float(w),abs(v.y)/Float(h)))
            }
            data[i*4+3]=1
            let sample = valid ? q:SIMD2(Float(x+pad),Float(y+pad))
            let qx=max(0,min(pw-2,Int(sample.x))),qy=max(0,min(ph-2,Int(sample.y)))
            let u=max(0,min(1,sample.x-Float(qx))),t=max(0,min(1,sample.y-Float(qy)))
            func pixel(_ xx:Int,_ yy:Int)->Float {Float(second.pixels[(yy*pw+xx)*4])}
            let gray=(pixel(qx,qy)*(1-u)+pixel(qx+1,qy)*u)*(1-t)+(pixel(qx,qy+1)*(1-u)+pixel(qx+1,qy+1)*u)*t
            for c in 0..<3 {
                reference[i*4+c]=first.pixels[((y+pad)*pw+x+pad)*4+c]
                predicted[i*4+c]=UInt8(max(0,min(255,Int(gray.rounded()))))
            }
        } }
        guard consistent > observed/2 else { continue }
        let score=PeripheralAlignmentWorker.grayBoundaryScore(reference,predicted,width:w,height:h,padding:0,seams:seams)
        let algorithm="Vision-r\(revision)-veryHigh-grayscale-bidirectional-real-outer-halo32"
        scores[algorithm]=score
        if score>bestScore+0.01 {
            bestScore=score
            chosen = .init(id:id,epoch:pair.epoch,sourcePairID:pair.serial,homography:homography,width:w,height:h,
            rgba:data,consistentFraction:Double(consistent)/Double(max(1,observed)),elapsedMS:(CACurrentMediaTime()-start)*1000,
            maximumOffset:maximum,algorithm:algorithm)
        }
        // The score selects a proposal, never a display certificate.
        if score>=Double(tileCount) && Double(consistent)/Double(max(1,observed))>=0.85 {break}
        }
        chosen?.elapsedMS=(CACurrentMediaTime()-start)*1000
        chosen?.candidateScores=scores
        return chosen
    }
}
