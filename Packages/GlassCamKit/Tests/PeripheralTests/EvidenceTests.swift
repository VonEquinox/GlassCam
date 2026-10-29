import Testing
@testable import Peripheral

struct PeripheralEvidenceTests {
    typealias F = PeripheralFixtures
    @Test func smallCompleteAmbiguousSet_remainsReliable() {
        var evidence = F.good(); evidence.status = .ambiguous; evidence.interval = 0.01...0.035
        #expect(evidence.reliable)
    }
    static func visibleEvidence() -> PeripheralEvidence {
        var evidence = PeripheralEvidence.unknown("physical-displacement-unobservable")
        evidence.visibleSeam = .init(compatible: true, coverage: 1, maximumObservableError: nil,
            reason: "native-visible-seam", nativeSupportChecked: true)
        return evidence
    }
    @Test func visibleEvidence_doesNotInventPhysicalGeometry() {
        let evidence = Self.visibleEvidence()
        #expect(evidence.interval == nil)
        #expect(!evidence.reliable)
    }
}
