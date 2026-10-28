import Foundation
import ImagingCore

package enum TestResources {
    package static var colors: ColorResources {
        ColorResources(resourceDirectory: environmentURL("GLASSCAM_TEST_RESOURCES"))
    }
    package static var fixtures: URL {
        environmentURL("GLASSCAM_TEST_FIXTURES") ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tests/fixtures")
    }
    package static func environmentURL(_ key: String) -> URL? {
        ProcessInfo.processInfo.environment[key].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

package final class TestDirectory: @unchecked Sendable {
    package let url: URL
    package init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("glasscam-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

import CoreImage
import CoreGraphics

package enum ImageFixture {
    package static func pngData() throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.75)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let data = CIContext().pngRepresentation(of: image, format: .RGBA16, colorSpace: space) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
