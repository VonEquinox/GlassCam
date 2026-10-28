import ImagingCore
import Foundation
import AVFoundation
import CoreImage
import QuartzCore
import simd
import OSLog
import Accelerate
import CryptoKit

/// Only boundaries adjoining a real peripheral pane need seam verification.
/// Horizontal means the two image rows; their order is immaterial across CI's
/// bottom-left and the display's top-left coordinate systems.
public struct PeripheralSeams: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public init(photo: CGRect, window: CGSize) {
        self = []
        if photo.minY > 0.5 || window.height-photo.maxY > 0.5 { insert(.horizontal) }
        if photo.minX > 0.5 || window.width-photo.maxX > 0.5 { insert(.vertical) }
    }
    public static let horizontal = Self(rawValue: 1)
    public static let vertical = Self(rawValue: 2)
    public static let all: Self = [.horizontal, .vertical]
}

public struct PeripheralAlignmentResult {
    public let epoch: UInt64
    public let receipt: Double
    public let photoAspectRatio: Double
    public let photoToOuter: simd_float3x3
    package let residual: Double
    public let gain: SIMD3<Float>
    public let seams: PeripheralSeams
    package let expiresAt: Double
    package var evidence = PeripheralEvidence.unknown("legacy-result")
    package var pairID: UInt64 = 0
    package var geometryID: UInt64 = 0
    package var photometryID: UInt64 = 0
    package var completedAt = 0.0
    package var geometryExpiresAt = 0.0
    package var photometryExpiresAt = 0.0
    package var centerPTS: Double?
    public var outerPTS: Double?
    package var motionDistance = 0.0
    package var motionGeneration: UInt64 = 0
    package var inputPair: PeripheralFrameSource.Pair?
    public var edgeGains = PeripheralEdgeGains()
    public var gateReasons: [String] = []
    package var nativeSeam: PeripheralNativeSeam?
    package var visiblePhotometryID: UInt64 = 0
    public var refinement: PeripheralDenseRefinement?
    public var tolerance = PeripheralTolerance.defaultValue
    public var directStitch = false
    package func evidence(forEdge edge:Int) -> PeripheralEvidence {
        guard let nativeSeam else { return evidence }
        if evidence.reliable && (evidence.interval?.upperBound ?? 1) > PeripheralGlassPolicy.darkeningThreshold {
            return .unknown("physical-candidate-set-crosses-darkening-threshold")
        }
        guard !gateReasons.contains("capture-skew-outside-pair-domain") else { return .unknown("capture-skew-outside-pair-domain") }
        let rows = nativeSeam.diagnostics.filter { $0["edge"] as? Int == edge }
        guard !rows.isEmpty else { return .unknown("no-peripheral-pane-on-this-edge") }
        let passed = rows.filter { $0["passed"] as? Bool == true }.count
        var result = PeripheralEvidence.unknown("current-native-grayscale-edge")
        result.confirmedSevereLowerBound = evidence.confirmedSevereLowerBound
        result.visibleSeam = .init(compatible:passed == rows.count,coverage:Double(passed)/Double(rows.count),
            maximumObservableError:rows.compactMap { $0["visibleErrorUpper"] as? Double }.max(),
            reason:"current-native-grayscale-edge",nativeSupportChecked:true)
        return result
    }
    package var permitsAnyDisplay:Bool { evidence.permitsDisplay || (0..<4).contains { evidence(forEdge:$0).permitsDisplay } }
    package func renderOuterImage() -> CIImage? {
        guard let pair = inputPair else { return nil }
        let raw = CIImage(cvPixelBuffer:pair.outer)
        guard let refinement else { return raw }
        return refinement.outerImage(raw,centerSize:CGSize(width:CVPixelBufferGetWidth(pair.center),
            height:CVPixelBufferGetHeight(pair.center)),ratio:pair.ratio)
    }
    public func isFresh(for epoch: UInt64, at time: Double) -> Bool {
        self.epoch == epoch && time.isFinite && time >= receipt && time <= expiresAt
    }
}

/// Pure coverage contract shared by candidate selection and the final renderer.
/// Corners suffice for a finite, nonsingular homography with positive denominator.
public enum PeripheralProjection {
    public static func margin(_ matrix: simd_float3x3, window: CGRect, width: Int, height: Int) -> Float? {
        guard width > 0, height > 0, window.width > 0, window.height > 0,
              PeripheralAlignmentWorker.valid(matrix), abs(matrix[2][2]) > 0.00001 else { return nil }
        let normalized = matrix * (1/matrix[2][2])
        guard abs(simd_determinant(normalized)) > 1e-8 else { return nil }
        let norm = (0..<3).reduce(Float(0)) { $0+simd_length_squared(normalized[$1]) }
        let inverse = normalized.inverse
        let invNorm = (0..<3).reduce(Float(0)) { $0+simd_length_squared(inverse[$1]) }
        guard norm*invNorm < 1e6 else { return nil }
        var margin = Float.infinity
        for (x,y) in [(window.minX,window.minY),(window.maxX,window.minY),
                      (window.minX,window.maxY),(window.maxX,window.maxY)] {
            let p = SIMD2(Float(x),Float(y))
            guard let uv = PeripheralAlignmentWorker.project(p,using: normalized),
                  let dx = PeripheralAlignmentWorker.project(p+SIMD2(0.001,0),using: normalized),
                  let dy = PeripheralAlignmentWorker.project(p+SIMD2(0,0.001),using: normalized) else { return nil }
            let a = (dx-uv)*1000, b = (dy-uv)*1000
            let determinant = a.x*b.y-a.y*b.x
            guard determinant > 0.00001, simd_length(a) < 8, simd_length(b) < 8 else { return nil }
            margin = min(margin,min(min(uv.x,1-uv.x)*Float(width),min(uv.y,1-uv.y)*Float(height)))
        }
        return margin
    }
}
