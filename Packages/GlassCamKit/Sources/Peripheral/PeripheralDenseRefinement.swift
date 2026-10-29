import Foundation
import simd

/// Preserved field data for saved analysis and render records.
/// The live pipeline produces fixed-FOV frames with no refinement.
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
}
