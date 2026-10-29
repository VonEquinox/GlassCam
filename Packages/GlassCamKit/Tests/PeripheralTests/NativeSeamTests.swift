import Testing
import Foundation
import simd
@testable import Peripheral

struct NativeSeamTests {
    static let width = 192, height = 20
    static var flat: [UInt8] { (0..<width * height).flatMap { _ -> [UInt8] in [128, 128, 128, 255] } }
    static func line(x: Int) -> [UInt8] {
        var pixels = flat
        for y in 0..<height { for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 0 } }
        return pixels
    }
    static func blurredLine(x: Int) -> [UInt8] {
        var pixels = flat
        let kernel = (-5...5).map { exp(-Double($0 * $0) / 12.5) }, weight = kernel.reduce(0, +)
        for y in 0..<height { for dx in -5...5 { for channel in 0..<3 {
            pixels[(y * width + x + dx) * 4 + channel] = UInt8((128 - 128 * kernel[dx + 5] / weight).rounded())
        } } }
        return pixels
    }
    static func measure(_ reference: [UInt8], _ outer: [UInt8], geometry: Bool = true,
        segments: [PeripheralAlignmentWorker.SegmentEvidence] = [], tolerance: Double = 1) -> PeripheralNativeSeam {
        PeripheralNativeSeam.evaluate([.init(edge: 0, width: width, height: height, reference: reference, outer: outer, nativeScale: 1)],
            gains: PeripheralEdgeGains(), segments: segments, analysisWidth: 192, analysisHeight: 256,
            geometryVerified: geometry, severe: nil, tolerance: tolerance)
    }
    @Test func flatNativeSupport_canEstablishVisibleEvidence() {
        #expect(Self.measure(Self.flat, Self.flat, geometry: false).evidence.compatible)
    }
    @Test(arguments: [("outer-row", true), ("one-pixel-line", true),
                      ("absent-counterpart", false), ("uncovered-counterpart", false)])
    func missingNativeStructure_isRejected(kind: String, geometry: Bool) {
        var reference = Self.line(x: 70), outer = Self.flat
        var tolerance = 1.0
        switch kind {
        case "outer-row": reference = Self.flat; for x in 50..<76 { for channel in 0..<3 { reference[x * 4 + channel] = 0 } }
        case "absent-counterpart": tolerance = 4
        case "uncovered-counterpart": outer = Self.line(x: 77); outer[3] = 0; tolerance = 4
        default: break
        }
        let measured = Self.measure(reference, outer, geometry: geometry, tolerance: tolerance)
        #expect(!measured.evidence.compatible)
    }
    @Test(arguments: [(70, true), (86, false)])
    func weakBlurredCounterpart_requiresMatchingLocation(input: (Int, Bool)) {
        let result = Self.measure(Self.line(x: 70), Self.blurredLine(x: input.0), geometry: false)
        #expect(result.evidence.compatible == input.1)
    }
    @Test(arguments: [(0.25, false), (1.0, false), (4.0, true)])
    func tolerance_changesAcceptanceOfKnownSmallShift(input: (Double, Bool)) {
        let result = Self.measure(Self.line(x: 70), Self.line(x: 77), geometry: false, tolerance: input.0)
        #expect(result.evidence.compatible == input.1)
    }
    @Test func periodicStructure_cannotBeCertifiedFlat() {
        let pixels = (0..<Self.width * Self.height).flatMap { index -> [UInt8] in
            let value: UInt8 = index % Self.width % 24 < 12 ? 40 : 220; return [value, value, value, 255]
        }
        let segment = PeripheralAlignmentWorker.SegmentEvidence(index: 0, point: SIMD2(10, 10), status: .ambiguous,
            interval: nil, best: nil, forwardBackward: 0, searchComplete: true, gradientEigenvalues: SIMD2(0, 1),
            observableNormal: SIMD2(1, 0), noiseScale: 0, repeatedStructure: true)
        #expect(!Self.measure(pixels, pixels, segments: [segment]).evidence.compatible)
    }
    @Test func periodicTwoDimensionalTexture_cannotEscapeByMeanCancellation() {
        let pixels = (0..<Self.width * Self.height).flatMap { index -> [UInt8] in
            let value: UInt8 = ((index % Self.width) / 4 + (index / Self.width) / 4) % 2 == 0 ? 40 : 220
            return [value, value, value, 255]
        }
        #expect(!Self.measure(pixels, pixels, geometry: false).evidence.compatible)
    }
    @Test func isolatedMissingLine_doesNotBlackenWholePane() {
        let native = Self.measure(Self.line(x: 70), Self.flat, geometry: false)
        var alignment = PeripheralAlignmentResult(epoch: 1, receipt: 0, photoAspectRatio: 0.75,
            photoToOuter: matrix_identity_float3x3, residual: .nan, gain: SIMD3(repeating: 1), seams: .horizontal, expiresAt: 0.2)
        alignment.nativeSeam = native
        #expect(!native.evidence.compatible)
        #expect(PeripheralPaneAssessment.measure(alignment, edge: 0).darkness(tolerance: 1) == 0)
    }
    @Test func tolerance_persistsAtDisplayedPrecisionAndRejectsNaN() throws {
        let suite = "GlassCamToleranceTests.\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tolerance = PeripheralTolerance(defaults: defaults)
        #expect(tolerance.value == 1)
        tolerance.value = 2.13
        #expect(abs(PeripheralTolerance(defaults: defaults).value - 2.15) < 0.00001)
        tolerance.value = .nan
        #expect(tolerance.value == 1)
    }
}
