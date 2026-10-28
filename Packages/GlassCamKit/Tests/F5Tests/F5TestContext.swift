import Foundation
@testable import F5
import GlassCamTestSupport

struct F5TestContext {
    let work: TestDirectory
    let fixture: F5Fixtures.Fixture
    static var shader: URL {
        get throws {
            guard let url = Bundle.module.url(forResource: "F5Kernels", withExtension: "metal") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return url
        }
    }
    init(mapping: String = "native", width: Int = 8, height: Int = 6) throws {
        work = try TestDirectory()
        fixture = try F5Fixtures.make(directory: work.url, width: width, height: height,
            codeDivisor: mapping == "mapped" ? 4 : 1,
            additionalDNGTags: mapping == "gain" ? [F5Fixtures.stage2GainTag()] : [])
    }
}
