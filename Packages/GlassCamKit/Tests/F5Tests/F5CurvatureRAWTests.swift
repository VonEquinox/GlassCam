import Testing
import Foundation
import GlassCamTestSupport
@testable import F5

@Suite(.serialized)
struct F5CurvatureRAWTests {
    @Test func declaredBadPixel_isRepairedFromSameCFANeighborsAndKeepsMask() throws {
        let work = try TestDirectory(), width = 8, height = 6
        var samples = [UInt16](repeating: 16000,count: width * height)
        let defect = 2 * width + 2
        samples[defect] = 12345
        var payload = Data()
        F5DecoderTests.be(UInt32(12345),&payload); F5DecoderTests.be(UInt32(0),&payload)
        let fixture = try F5Fixtures.make(directory: work.url,inputFrames: [samples],
            additionalDNGTags: [F5DecoderTests.opcode(4,0,payload,list: 51008)],quality: .speed)
        let device = try F5MetalDevice(maximumBytes: 8 * 1024 * 1024,shaderURL: F5TestContext.shader,isCancelled: { false })
        let frames = try fixture.canonical.map { try F5MetalFrame.upload($0,to: device) }

        let result = try F5CurvatureRAW(frames: frames,device: device)

        let values = result.values, kinds = result.kinds
        defer { withExtendedLifetime(values) {}; withExtendedLifetime(kinds) {} }
        let expected = Float((16000.0 - 512) / 65023)
        #expect(abs(values.metal.contents().assumingMemoryBound(to: Float.self)[defect] - expected) < 2e-6)
        #expect(kinds.metal.contents().assumingMemoryBound(to: UInt8.self)[defect] == 3)
        #expect(fixture.canonical[0].event(x: 2,y: 2).code == 12345)
    }
    @Test(arguments: ["native", "mapped", "gain"])
    func integerRAWDecode_matchesCanonicalEventsIncludingExposureAndGain(mapping: String) throws {
        let context = try F5TestContext(mapping: mapping), fixture = context.fixture
        let device = try F5MetalDevice(maximumBytes: 8 * 1024 * 1024, shaderURL: F5TestContext.shader, isCancelled: { false })
        let uploaded = try fixture.canonical.map { try F5MetalFrame.upload($0, to: device) }

        let decoded = try F5CurvatureRAW(frames: uploaded, device: device)
        defer { withExtendedLifetime(decoded) {} }

        let values = decoded.values.metal.contents().assumingMemoryBound(to: Float.self)
        let kinds = decoded.kinds.metal.contents().assumingMemoryBound(to: UInt8.self)
        var maximum = 0.0, mismatches = 0
        for f in 0..<5 { for y in 0..<6 { for x in 0..<8 {
            let event = fixture.canonical[f].event(x: x, y: y)
            let expected = (event.lower + event.upper) / (2 * event.exposure * event.eta)
            maximum = max(maximum, abs(Double(values[(f * 6 + y) * 8 + x]) - expected))
            if kinds[(f * 6 + y) * 8 + x] != UInt8(event.kind.rawValue) { mismatches += 1 }
        }}}
        let linearTolerance = 2e-6 // One FP32 canonicalization, including short-frame scaling.
        #expect(maximum < linearTolerance)
        #expect(mismatches == 0)
    }

    @Test(arguments: [1, 4])
    func censoredCodes_keepDeliveredCentersAndCensorKinds(divisor: Int) throws {
        let directory = try TestDirectory(), width = 8, height = 6
        let maximum: UInt16 = divisor == 4 ? 16383 : 65535
        let codes = (0..<width * height).map { $0 % 2 == 0 ? UInt16(0) : maximum }
        let fixture = try F5Fixtures.make(directory: directory.url, width: width, height: height,
                                         inputFrames: Array(repeating: codes, count: 5), codeDivisor: divisor)
        let device = try F5MetalDevice(maximumBytes: 8 * 1024 * 1024, shaderURL: F5TestContext.shader, isCancelled: { false })
        let uploaded = try fixture.canonical.map { try F5MetalFrame.upload($0, to: device) }

        let decoded = try F5CurvatureRAW(frames: uploaded, device: device)
        defer { withExtendedLifetime(decoded) {} }

        let values = decoded.values.metal.contents().assumingMemoryBound(to: Float.self)
        let kinds = decoded.kinds.metal.contents().assumingMemoryBound(to: UInt8.self)
        var maximumError = 0.0, mismatches = 0
        for f in 0..<5 { for i in 0..<width * height {
            let x = i % width, y = i / width, frame = fixture.canonical[f]
            let expected = (Double(codes[i]) / Double(divisor) - frame.record.metadata.black(x: x, y: y)) / fixture.profile.whiteScale / frame.exposure
            maximumError = max(maximumError, abs(Double(values[f * width * height + i]) - expected))
            let expectedKind: UInt8 = i % 2 == 0 ? 2 : 1
            if kinds[f * width * height + i] != expectedKind { mismatches += 1 }
        }}
        let linearTolerance = 2e-6 // Delivered centers retain signed shadows and HDR short-frame radiance.
        #expect(maximumError < linearTolerance)
        #expect(mismatches == 0)
    }

    @Test func borrowedValues_retainNativeAllocationUntilReleased() throws {
        let context = try F5TestContext(), device = try F5MetalDevice(maximumBytes: 8 * 1024 * 1024, shaderURL: F5TestContext.shader, isCancelled: { false })
        let frames = try context.fixture.canonical.map { try F5MetalFrame.upload($0, to: device) }
        let original = withExtendedLifetime(frames) { device.allocatedBytes }
        var decoded: F5CurvatureRAW? = try F5CurvatureRAW(frames: frames, device: device)
        var pixels: F5MetalBuffer? = decoded?.values
        decoded = nil
        let retained = withExtendedLifetime(pixels) { device.allocatedBytes }

        pixels = nil

        #expect(retained > original)
        #expect(device.allocatedBytes == original)
        withExtendedLifetime(frames) {}
    }
}
