import ImagingCore
import Capture
import Foundation

struct F5CaptureProvenance: Codable, CaptureProvenance {
    func resolutionDescription(width: Int, height: Int) -> String {
        String(format: "%@ · %d RAW · Output %.1f MP", frameSHA256.count == 1 ? "Speed" : "Balanced", frameSHA256.count, Double(width * height) / 1_000_000)
    }
    let decodeRevision: String, colorBridgeRevision: String, profileSHA256: String, referenceFrameID: String
    let inputWidth: Int, inputHeight: Int, frameSHA256: [String], actualExposures: [Double]
    let whiteBalanceOwner: String, transformSHA256: String
    let qualityClassCounts: [String: Int], flags: [F5Code], solveStatus: String
}
