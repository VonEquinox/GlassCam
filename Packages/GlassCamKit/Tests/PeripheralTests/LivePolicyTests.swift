import Testing
import Foundation
import simd
@testable import Peripheral

struct LivePolicyTests {
    static let compatible = PeripheralPaneAssessment(reason: "checked-flat-agreement")
    static let moderate = PeripheralPaneAssessment(error: 0.03, mismatchFraction: 0, supportFraction: 1, reason: "known-displacement")
    static let large = PeripheralPaneAssessment(error: 0.3, mismatchFraction: 0.8, supportFraction: 1, reason: "known-large-displacement")
    @Test func absentVisibleStructure_staysBlackAtMaximumTolerance() {
        let missing = PeripheralPaneAssessment(error: nil, mismatchFraction: 0.5, supportFraction: 0, missingStructureFraction: 0.5, reason: "occluded-boundary")
        var policy = PeripheralPreviewPolicy(), values: [Double] = []
        for index in 0...60 {
            let time = Double(index) / 60
            policy.observe([missing, missing, .init(), .init()], at: time)
            values.append(policy.update(at: time, ready: true, tolerance: 4)[0])
        }
        #expect(missing.darkness(tolerance: 4) == 1)
        #expect(Set(values) == [1])
        #expect(policy.update(at: 2, ready: true, tolerance: 4)[0] == 1)
    }
    @Test func uncheckedStartup_doesNotAssumeTransparency() {
        var policy = PeripheralPreviewPolicy()
        #expect(policy.update(at: -0.01, ready: true, tolerance: 4) == [1, 1, 1, 1])
    }
    @Test func checkedStartup_finishesBoundedOpening() throws {
        var policy = PeripheralPreviewPolicy(), warmed: [Double] = []
        for index in 0...60 {
            let time = Double(index) / 60
            policy.observe(Array(repeating: Self.compatible, count: 4), at: time)
            let alpha = policy.update(at: time, ready: true, tolerance: 1)
            if index >= 40 { warmed += alpha }
        }
        #expect(try #require(warmed.max()) < 0.001)
    }
    @Test func tolerance_expandsAcceptedDisplacement() {
        #expect(Self.moderate.darkness(tolerance: 1) > 0.01)
        #expect(Self.moderate.darkness(tolerance: 4) == 0)
    }
    static func worseningThenRecovery() -> (trace: [[Double]], noPixels: [Double]) {
        var policy = PeripheralPreviewPolicy(), trace: [[Double]] = []
        for frame in 0...240 {
            let time = Double(frame) / 60
            if frame <= 60 || frame >= 127 { policy.observe(Array(repeating: compatible, count: 4), at: time) }
            else if frame >= 73 || frame % 5 == 0 { policy.observe([large, compatible, compatible, compatible], at: time) }
            trace.append(policy.update(at: time, ready: true, tolerance: 1))
        }
        return (trace, policy.update(at: 5, ready: false, tolerance: 4))
    }
    @Test func worseningAndRecovery_keepTopAndBottomLinked() {
        let result = Self.worseningThenRecovery()
        #expect(result.trace.map { $0[0] } == result.trace.map { $0[1] })
    }
    @Test func topDistortion_shadesHorizontalPanesWithoutAffectingSides() {
        let alpha = Self.worseningThenRecovery().trace[126]
        #expect(alpha[0] > 0.99)
        #expect(alpha[2] == 0)
        #expect(alpha[3] == 0)
    }
    @Test func checkedRecovery_clearsOldShadeButMissingPixelsStayBlack() throws {
        let result = Self.worseningThenRecovery()
        #expect(try #require(result.trace[240].max()) < 0.001)
        #expect(result.noPixels == [1, 1, 1, 1])
    }
    @Test func horizontalShade_usesDarkerPaneWithoutMixingSidePanes() throws {
        var policy = PeripheralPreviewPolicy(), values: [[Double]] = [], targets: [[Double]] = [], allValues: [[Double]] = []
        let half = PeripheralPaneAssessment(error: 0.045, supportFraction: 1, reason: "moderate-visible-shift")
        for frame in 0...120 {
            let time = Double(frame) / 60
            policy.observe(frame < 60 ? [Self.moderate, half, Self.compatible, Self.large] : [half, Self.moderate, Self.compatible, Self.large], at: time)
            let alpha = policy.update(at: time, ready: true, tolerance: 1)
            allValues.append(alpha)
            if frame >= 40 { values.append(alpha); targets.append(policy.targets) }
        }
        #expect(allValues.map { $0[0] } == allValues.map { $0[1] })
        #expect(try #require(values.map { abs($0[0] - 0.5) }.max()) < 0.000001)
        #expect(Set(values.map { $0[2] }) == [0])
        #expect(Set(values.map { $0[3] }) == [1])
        let targetErrors = targets.flatMap { [abs($0[0] - 0.5), abs($0[1] - 0.5)] }
        #expect(try #require(targetErrors.max()) < 0.000001)
    }
    @Test func subpixelQuantization_doesNotOscillateGlass() throws {
        var policy = PeripheralPreviewPolicy(), values: [Double] = []
        for frame in 0..<240 {
            let time = Double(frame) / 60, noise = frame < 60 ? 0 : ((frame / 5) % 2 == 0 ? 0.004 : -0.004)
            let reading = PeripheralPaneAssessment(error: 0.045 + noise, supportFraction: 1, reason: "quantized-correspondence")
            if frame % 5 == 0 { policy.observe([reading, reading, Self.compatible, Self.compatible], at: time) }
            let alpha = policy.update(at: time, ready: true, tolerance: 1)
            if frame >= 60 { values.append(alpha[0]) }
        }
        let maximum = try #require(values.max()), minimum = try #require(values.min())
        #expect(maximum - minimum < 0.001)
    }
    @Test func ambiguousCorrespondence_doesNotInventZeroVisibleError() {
        var result = PeripheralAlignmentResult(epoch: 1, receipt: 0, photoAspectRatio: 0.75,
            photoToOuter: matrix_identity_float3x3, residual: .nan, gain: SIMD3(repeating: 1), seams: .horizontal, expiresAt: 1)
        result.nativeSeam = PeripheralNativeSeam(gains: .init(), evidence: .init(compatible: false, coverage: 0,
            maximumObservableError: nil, reason: "ambiguous", nativeSupportChecked: true), diagnostics: [
                ["edge": 0, "flatBothNative": false, "nativeEdgeSupport": [0, 0], "nativeWeakEdgeSupport": [0, 0],
                 "nativePeriodicProfile": true, "segmentSearchComplete": false]])
        #expect(PeripheralPaneAssessment.measure(result, edge: 0).reason == "unobserved")
    }
}
