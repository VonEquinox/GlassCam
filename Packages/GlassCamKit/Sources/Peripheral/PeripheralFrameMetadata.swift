import ImagingCore
import Foundation
import AVFoundation
import CoreImage
import QuartzCore
import simd
import OSLog
import Accelerate
import CryptoKit

/// Frame timestamps remain in their original clock domain until explicitly
/// converted. K is copied into aligned SIMD storage, including its ABI padding.
public struct PeripheralFrameMetadata {
    public let id: UInt64
    public let pts: Double
    let hostCaptureTime: Double?
    public let width: Int, height: Int
    let frameInterval: Double
    public let pixelFormat: UInt32
    public let colorAttachments: [String:String]
    let intrinsic: simd_float3x3?
    public init(_ sample: CMSampleBuffer, id: UInt64, clock: CMClock?) {
        self.id = id
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        pts = CMTimeGetSeconds(time)
        let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
        frameInterval = duration.isFinite && duration >= 1.0/120 && duration <= 0.1 ? duration : 1.0/30
        if let clock {
            let converted = CMTimeGetSeconds(CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock()))
            hostCaptureTime = converted.isFinite ? converted : nil
        } else { hostCaptureTime = nil }
        let pixel = CMSampleBufferGetImageBuffer(sample)
        width = pixel.map(CVPixelBufferGetWidth) ?? 0; height = pixel.map(CVPixelBufferGetHeight) ?? 0
        pixelFormat = pixel.map(CVPixelBufferGetPixelFormatType) ?? 0
        var colors: [String:String] = [:]
        if let pixel {
            for (name,key) in [("primaries",kCVImageBufferColorPrimariesKey),
                              ("transferFunction",kCVImageBufferTransferFunctionKey),("ycbcrMatrix",kCVImageBufferYCbCrMatrixKey)] {
                if let value = CVBufferCopyAttachment(pixel,key,nil) { colors[name] = String(describing:value) }
            }
        }
        colorAttachments = colors
        var matrix = matrix_identity_float3x3
        if let data = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                      attachmentModeOut: nil) as? Data,
           data.count == MemoryLayout<simd_float3x3>.size {
            _ = withUnsafeMutableBytes(of: &matrix) { data.copyBytes(to: $0) }
            intrinsic = PeripheralAlignmentWorker.valid(matrix) && matrix[0][0] > 0 && matrix[1][1] > 0 &&
                abs(matrix[2][2]-1) < 0.001 ? matrix : nil
        } else { intrinsic = nil }
    }
}

public struct PeripheralCalibration {
    package init(identity: String, rotation: simd_float3x3, translation: SIMD3<Float>, outputRotation: Float) {
        self.identity = identity; self.rotation = rotation; self.translation = translation; self.outputRotation = outputRotation
    }
    public let identity: String
    let rotation: simd_float3x3
    public let translation: SIMD3<Float>
    public let outputRotation: Float
    /// GDC and other output warps require image validation before any narrow search.
    public static func decode(_ data: Data?, identity: String, outputRotation: Float) -> Self? {
        guard let data, data.count == MemoryLayout<simd_float4x3>.size else { return nil }
        var matrix = simd_float4x3()
        _ = withUnsafeMutableBytes(of: &matrix) { data.copyBytes(to: $0) }
        let r = simd_float3x3(matrix[0],matrix[1],matrix[2]), t = matrix[3]
        let orthogonal = r.transpose*r-matrix_identity_float3x3
        guard PeripheralAlignmentWorker.valid(r), t.x.isFinite, t.y.isFinite, t.z.isFinite,
              abs(simd_determinant(r)-1) < 0.01,
              (0..<3).allSatisfy({ simd_length(orthogonal[$0]) < 0.01 }),
              simd_length(t) > 0.1, simd_length(t) < 100 else { return nil }
        return .init(identity: identity,rotation: r,translation: t,outputRotation: outputRotation)
    }
    func fundamental(center: PeripheralFrameMetadata, outer: PeripheralFrameMetadata) -> simd_float3x3? {
        guard let kc = center.intrinsic, let ko = outer.intrinsic else { return nil }
        let angle = outputRotation * .pi/180, c = cos(angle), s = sin(angle)
        let q = simd_float3x3(SIMD3(c,s,0),SIMD3(-s,c,0),SIMD3(0,0,1))
        let r = q*rotation*q.transpose, t = q*translation
        let cross = simd_float3x3(SIMD3(0,t.z,-t.y),SIMD3(-t.z,0,t.x),SIMD3(t.y,-t.x,0))
        let f = ko.inverse.transpose*cross*r*kc.inverse
        return PeripheralAlignmentWorker.valid(f) ? f : nil
    }
}
