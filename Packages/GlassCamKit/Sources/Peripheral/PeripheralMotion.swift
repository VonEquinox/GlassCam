import ImagingCore
import Foundation
import AVFoundation
import CoreImage
import QuartzCore
import simd
import OSLog
import Accelerate
import CryptoKit

/// Low resolution temporal sentinel. This is an empirical image-motion estimate,
/// not an IMU/rolling-shutter correction or a statistical bound. Failed matching
/// breaks the reuse generation instead of inventing zero motion.
package enum PeripheralMotion {
    package struct Raster { package let values: [Float]; package let width: Int; package let height: Int }
    package static func raster(_ buffer: CVPixelBuffer) -> Raster? {
        let width = 48, height = max(32,min(80,48*CVPixelBufferGetHeight(buffer)/max(1,CVPixelBufferGetWidth(buffer))))
        guard CVPixelBufferLockBaseAddress(buffer,.readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer,0) : CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer,0) : CVPixelBufferGetBytesPerRow(buffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        guard planar || format == kCVPixelFormatType_32BGRA else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(buffer), sourceHeight = CVPixelBufferGetHeight(buffer)
        func sample(_ x:Int,_ y:Int) -> Float {
            let xx = max(0,min(sourceWidth-1,x)), yy = max(0,min(sourceHeight-1,y))
            let row = base.advanced(by:yy*stride)
            if tenBit { return Float(row.assumingMemoryBound(to:UInt16.self)[xx] >> 6)/1023 }
            if planar { return Float(row.assumingMemoryBound(to:UInt8.self)[xx])/255 }
            let p = row.assumingMemoryBound(to:UInt8.self)+xx*4
            return (Float(p[2])*0.2126+Float(p[1])*0.7152+Float(p[0])*0.0722)/255
        }
        var out = [Float](repeating:0,count:width*height)
        for y in 0..<height { for x in 0..<width {
            let yy = (2*y+1)*sourceHeight/(2*height), xx = (2*x+1)*sourceWidth/(2*width)
            var value: Float = 0
            for v in -1...1 { for u in -1...1 {
                value += sample(xx+u*sourceWidth/(3*width),yy+v*sourceHeight/(3*height))
            } }
            out[y*width+x] = value/9
        } }
        return .init(values:out,width:width,height:height)
    }
    package static func displacement(_ a: Raster,_ b: Raster, minimumMatches: Int = 6) -> Double? {
        guard a.width == b.width, a.height == b.height else { return nil }
        var distances: [Double] = []
        for fy in [0.25,0.5,0.75] { for fx in [0.25,0.5,0.75] {
            let x = Int(Double(a.width)*fx), y = Int(Double(a.height)*fy)
            var sample: [Float] = []
            for v in -3...3 { for u in -3...3 { sample.append(a.values[(y+v)*a.width+x+u]) } }
            let mean = sample.reduce(0,+)/49
            let variance = sample.reduce(Float(0)) { $0+($1-mean)*($1-mean) }
            guard variance > 0.001 else { continue }
            var scores: [(Float,Int,Int)] = []
            for dy in -3...3 { for dx in -3...3 {
                var total: Float = 0, squared: Float = 0, dot: Float = 0, i = 0
                for v in -3...3 { for u in -3...3 {
                    let value = b.values[(y+dy+v)*b.width+x+dx+u]
                    total += value; squared += value*value; dot += (sample[i]-mean)*value; i += 1
                } }
                let vb = squared-total*total/49
                scores.append((vb > 0.001 ? dot/sqrt(variance*vb) : -2,dx,dy))
            } }
            guard let best = scores.max(by: { $0.0 < $1.0 }), best.0 > 0.85,
                  abs(best.1) < 3, abs(best.2) < 3,
                  !scores.contains(where: { $0.0 > best.0-0.04 && hypot(Float($0.1-best.1),Float($0.2-best.2)) > 1.5 }) else { continue }
            // Fractional fits are used only to shorten reuse, never to certify
            // a stereo displacement. Quantization allowance is explicit.
            func refine(_ before:Float,_ after:Float) -> Double {
                let curvature = before-2*best.0+after
                guard curvature < -0.001 else { return 0 }
                return Double(max(-0.5,min(0.5,0.5*(before-after)/curvature)))
            }
            func score(_ dx:Int,_ dy:Int) -> Float { scores.first { $0.1 == dx && $0.2 == dy }?.0 ?? -2 }
            let dx = Double(best.1)+refine(score(best.1-1,best.2),score(best.1+1,best.2))
            let dy = Double(best.2)+refine(score(best.1,best.2-1),score(best.1,best.2+1))
            distances.append((hypot(dx,dy)+0.05)*192/Double(a.width))
        } }
        return distances.count >= minimumMatches ? distances.max() : nil
    }
}
