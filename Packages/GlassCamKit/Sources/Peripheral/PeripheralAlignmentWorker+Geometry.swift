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
    static func intrinsicDrift(_ k: simd_float3x3,from previous: simd_float3x3,width: Int,height: Int) -> Float {
        let delta = k*previous.inverse
        return [SIMD2<Float>(0,0),SIMD2(Float(width),0),SIMD2(0,Float(height)),SIMD2(Float(width),Float(height))].map { p in
            guard let mapped = project(p,using:delta) else { return Float.infinity }
            return simd_distance(p,mapped)*192/Float(max(1,width))
        }.max() ?? .infinity
    }
    static func bufferToCI(width: Int,height: Int,bufferWidth: Int,bufferHeight: Int,ratio: Float) -> simd_float3x3 {
        let w = Float(width), h = Float(height)
        return simd_float3x3(SIMD3(w*ratio/Float(bufferWidth),0,0),SIMD3(0,-h*ratio/Float(bufferHeight),0),
                            SIMD3(w*(1-ratio)/2,h*(1+ratio)/2,1))
    }
    static func analysisFundamental(_ pair: PeripheralFrameSource.Pair,homography: simd_float3x3,width: Int,height: Int) -> simd_float3x3? {
        guard let c = pair.centerMetadata, let o = pair.outerMetadata,
              let f = pair.calibration?.fundamental(center: c,outer: o) else { return nil }
        let a = Self.bufferToCI(width: width,height: height,bufferWidth: c.width,bufferHeight: c.height,ratio: 1)
        let b = homography*Self.bufferToCI(width: width,height: height,bufferWidth: o.width,bufferHeight: o.height,ratio: pair.ratio)
        let value = b.inverse.transpose*f*a.inverse
        // CI uses lower-left coordinates, while render(toBitmap:) rows are
        // top-to-bottom (verified by a nonsymmetric CV buffer + nonzero extent).
        let flip = simd_float3x3(SIMD3(1,0,0),SIMD3(0,-1,0),SIMD3(0,Float(height),1))
        let bitmapF = flip.transpose*value*flip
        return Self.valid(bitmapF) ? bitmapF : nil
    }
    static func samplingTransform(homography: simd_float3x3, width: Int, height: Int, ratio: Float) -> simd_float3x3 {
        let w = Float(width), h = Float(height)
        let tx = w * (1-ratio) / 2, ty = h * (1-ratio) / 2
        let toCI = simd_float3x3(SIMD3(w, 0, 0), SIMD3(0, -h, 0), SIMD3(0, h, 1))
        let fromFloating = simd_float3x3(SIMD3(1 / (w * ratio), 0, 0),
            SIMD3(0, -1 / (h * ratio), 0),
            SIMD3(-tx / (w * ratio), 1 + ty / (h * ratio), 1))
        return fromFloating * homography.inverse * toCI
    }

    public func bitmap(_ image: CIImage, bounds: CGRect, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { pointer in
            context.render(image, toBitmap: pointer.baseAddress!, rowBytes: width * 4, bounds: bounds,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return bytes
    }
    static func grayBoundaryScore(_ a:[UInt8],_ b:[UInt8],width:Int,height:Int,padding:Int,seams:PeripheralSeams)->Double {
        var score=0.0,correlationSum=0.0,count=0
        func luma(_ pixels:[UInt8],_ i:Int)->Double {
            (Double(pixels[i])*0.2126+Double(pixels[i+1])*0.7152+Double(pixels[i+2])*0.0722)/255
        }
        for side in 0..<4 {
            guard side<2 ? seams.contains(.horizontal):seams.contains(.vertical) else {continue}
            let length=side<2 ? width:height
            for start in stride(from:0,to:length,by:16) {
                var n=0.0,sa=0.0,sb=0.0,aa=0.0,bb=0.0,ab=0.0
                for t in start..<min(length,start+16) {for d in 0..<8 {
                    let x=side<2 ? t:(side==2 ? d:width-1-d)
                    let y=side<2 ? (side==0 ? d:height-1-d):t
                    let u=luma(a,(y*width+x)*4),v=luma(b,((y+padding)*(width+2*padding)+x+padding)*4)
                    n += 1;sa += u;sb += v;aa += u*u;bb += v*v;ab += u*v
                }}
                let va=max(0,aa-sa*sa/n),vb=max(0,bb-sb*sb/n)
                let value:Double
                if max(va,vb)/n < 4/(255*255) {value=1}
                else if min(va,vb)/n < 0.25/(255*255) {value=0}
                else {value=max(0,min(1,(ab-sa*sb/n)/sqrt(max(1e-12,va*vb))))}
                if value>=0.8 {score += 1}
                correlationSum += value;count += 1
            }
        }
        return score+0.25*correlationSum/Double(max(1,count))
    }
    public static func valid(_ matrix: simd_float3x3) -> Bool {
        (0..<3).allSatisfy { i in (0..<3).allSatisfy { matrix[i][$0].isFinite } }
    }
    static func project(_ point: SIMD2<Float>, using matrix: simd_float3x3) -> SIMD2<Float>? {
        let v = matrix * SIMD3(point.x, point.y, 1)
        guard v.x.isFinite, v.y.isFinite, v.z.isFinite, v.z > 0.00001 else { return nil }
        return SIMD2(v.x / v.z, v.y / v.z)
    }
    package static func warp(_ image: CIImage, by matrix: simd_float3x3) -> CIImage? {
        let e = image.extent
        let points = [CGPoint(x: e.minX, y: e.maxY), CGPoint(x: e.maxX, y: e.maxY),
                      CGPoint(x: e.maxX, y: e.minY), CGPoint(x: e.minX, y: e.minY)]
        let values = points.compactMap { project(SIMD2(Float($0.x), Float($0.y)), using: matrix) }
        guard values.count == 4 else { return nil }
        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(x: CGFloat(values[0].x), y: CGFloat(values[0].y)),
            "inputTopRight": CIVector(x: CGFloat(values[1].x), y: CGFloat(values[1].y)),
            "inputBottomRight": CIVector(x: CGFloat(values[2].x), y: CGFloat(values[2].y)),
            "inputBottomLeft": CIVector(x: CGFloat(values[3].x), y: CGFloat(values[3].y))])
    }
}
