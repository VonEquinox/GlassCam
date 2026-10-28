import Testing
import Foundation
@testable import F5

struct F5DecoderTests {
    static func dng(_ tags: [F5Fixtures.Tag] = [], big: Bool = false) throws -> F5DNGMetadata {
        try F5DNGMetadata.read(F5Fixtures.makeDNG(width: 10, height: 8,
            active: .init(top: 1, left: 1, bottom: 7, right: 9), pixels: Array(repeating: 16000, count: 80),
            exposure: 0.008, overrides: tags, bigEndian: big))
    }
    static func be<T: FixedWidthInteger>(_ value: T, _ data: inout Data) {
        var value = value.bigEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    static func opcode(_ id: UInt32, _ flags: UInt32, _ parameters: Data, list: Int) -> F5Fixtures.Tag {
        var bytes = Data()
        for word: UInt32 in [1, id, 0x01030000, flags, UInt32(parameters.count)] { be(word, &bytes) }
        bytes.append(parameters)
        return .init(id: UInt16(list), type: 7, count: UInt32(bytes.count), bytes: bytes)
    }
    @Test func tiffEndianness_preservesMetadataInterpretation() throws {
        let little = try Self.dng(), big = try Self.dng(big: true)
        #expect(little.cfa == big.cfa)
        #expect(little.exposureTime == big.exposureTime)
        #expect(little.blackLevel == big.blackLevel)
        #expect(little.colorMatrix1 == big.colorMatrix1)
    }
    @Test(arguments: [[F5Fixtures.shorts(339, [3])], [F5Fixtures.shorts(50713, [0, 2])]])
    func malformedRAWMetadata_isRejected(tags: [F5Fixtures.Tag]) {
        let error = #expect(throws: F5Failure.self) { try Self.dng(tags) }
        #expect(error?.code == .unsupportedRAW)
    }
    @Test func unknownOptionalOpcode_canBeSkipped() throws {
        try Self.dng([Self.opcode(999, 1, Data(), list: 51008)]).auditOpcodes()
    }
    @Test func unknownMandatoryOpcode_isRejected() throws {
        let metadata = try Self.dng([Self.opcode(999, 0, Data(), list: 51008)])
        let error = #expect(throws: F5Failure.self) { try metadata.auditOpcodes() }
        #expect(error?.code == .unsupportedOpcode)
    }
    @Test func constantStage2Gain_isOwnedByPrediction() throws {
        var gain = Data()
        for value: UInt32 in [0, 0, 6, 8, 0, 1, 1, 1, 1, 1] { Self.be(value, &gain) }
        for value: Double in [1, 1, 0, 0] { Self.be(value.bitPattern, &gain) }
        Self.be(UInt32(1), &gain); Self.be(Float(2).bitPattern, &gain)
        let corrections = try F5RAWCorrections(metadata: Self.dng([Self.opcode(9, 0, gain, list: 51009)]))
        #expect(corrections.response(x: 3, y: 3) == 0.5)
    }
    static let gainCases: [(Int, Int, Double)] = [(1, 1, 1 / (1 + 2 * 0.5 / 8 + 0.5 / 6)), (8, 6, 1 / (1 + 2 * 7.5 / 8 + 5.5 / 6))]
    @Test(arguments: gainCases)
    func spatialGain_usesActiveAreaCoordinates(input: (Int, Int, Double)) throws {
        let corrections = try F5RAWCorrections(metadata: Self.dng([F5Fixtures.stage2GainTag()]))
        #expect(abs(corrections.response(x: input.0, y: input.1) - input.2) < 1e-12)
    }
    @Test(arguments: [(UInt16(5), true), (UInt16(6), false)])
    func badSensorCode_isExcludedWithoutRepair(input: (UInt16, Bool)) throws {
        var bytes = Data(); Self.be(UInt32(5), &bytes); Self.be(UInt32(0), &bytes)
        let corrections = try F5RAWCorrections(metadata: Self.dng([Self.opcode(4, 0, bytes, list: 51008)]))
        #expect(corrections.isBad(x: 3, y: 3, code: input.0) == input.1)
    }
    @Test func nonlinearQuantization_preservesBlackDeltasAndIntervals() throws {
        let metadata = try Self.dng([F5Fixtures.shorts(50712, (0..<16).map { UInt16($0 * $0) }),
            F5Fixtures.rationals(50714, [1, 2, 3, 4]), F5Fixtures.rationals(50715, Array(repeating: 0.2, count: 8)),
            F5Fixtures.rationals(50716, Array(repeating: 0.3, count: 6))])
        #expect(abs(metadata.black(x: 0, y: 0) - 1.5) < 1e-12)
        #expect(metadata.linearized(4.5) == 20.5)
        #expect(metadata.linearized(5.5) == 30.5)
    }
}
