// Apple-host executable diagnostic: swift tests/apple_ci_strip_roundtrip.swift
// Tests the exact render-toBitmap / top-down strip / CIImage(bitmapData:)
// contract used by full-resolution export. No camera, photo access or encoding.
import Foundation
import CoreImage
import CoreGraphics
let width = 7, height = 131
let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let context = CIContext(options: [.workingColorSpace: space,
                                  .workingFormat: CIFormat.RGBAf.rawValue])
var marker = [Float](repeating: 1, count: width * height * 4)
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        marker[i] = Float(y) / Float(height - 1)
        marker[i + 1] = Float(x) / Float(width - 1)
        marker[i + 2] = y < 64 ? 0.125 : y < 128 ? 0.5 : 0.875
    }
}
let bytes = marker.withUnsafeBytes { Data($0) }
let source = CIImage(bitmapData: bytes, bytesPerRow: width * 16,
                     size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: .RGBAf, colorSpace: space)
func render(_ image: CIImage, y: Int, rows: Int) -> [Float] {
    var result = [Float](repeating: 0, count: width * rows * 4)
    result.withUnsafeMutableBytes { pointer in
        context.render(image, toBitmap: pointer.baseAddress!, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: CGFloat(rows)),
                       format: .RGBAf, colorSpace: space)
    }
    return result
}
let full = render(source, y: 0, rows: height)
var concatenated = [Float]()
for start in stride(from: 0, to: height, by: 64) {
    let rows = min(64, height - start)
    concatenated.append(contentsOf: render(source, y: height - start - rows, rows: rows))
}
precondition(full == marker, "The decoded bitmap must preserve the top-down marker coordinates")
precondition(full == concatenated, "Top-down bitmap strips differ from one full bitmap: row orientation mismatch")
let rebuiltData = concatenated.withUnsafeBytes { Data($0) }
let rebuilt = CIImage(bitmapData: rebuiltData, bytesPerRow: width * 16,
                      size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: .RGBAf, colorSpace: space)
let roundtrip = render(rebuilt, y: 0, rows: height)
let maximumError = zip(full, roundtrip).map { abs($0 - $1) }.max()!
precondition(maximumError <= 1e-6, "RGBAf reconstruction flipped or changed pixels")
print("PASS: asymmetric 7x131 markers, 64/64/3-row strip ordering and RGBAf reconstruction. Maximum error \(maximumError)")
