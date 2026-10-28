import ImagingCore
import Foundation

/// A camera-owned payload whose format and lifecycle are supplied by a module.
public protocol CapturePayload: Sendable {
    var formatIdentifier: String { get }
}

public protocol CaptureProvenance: Encodable, Sendable {
    func resolutionDescription(width: Int, height: Int) -> String
}

public struct CaptureRenderResult {
    public init(file: TemporaryHEIFFile, snapshot: CaptureSnapshot) {
        self.file = file; self.snapshot = snapshot
    }
    public let file: TemporaryHEIFFile
    public let snapshot: CaptureSnapshot
}

/// Capture owns transaction sequencing; the format owns its files and codec.
public protocol CaptureFormat: Sendable {
    var identifier: String { get }
    var schemaVersion: Int { get }
    func decodeProvenance(from decoder: Decoder) throws -> any CaptureProvenance
    func source(in directory: URL) throws -> any CapturePayload
    func retain(_ payload: any CapturePayload, id: UUID, snapshot: CaptureSnapshot,
                directory: URL, recoversStaging: Bool) throws -> CaptureJournal.Record
    func validate(_ record: CaptureJournal.Record, directory: URL, recoversStaging: Bool) throws
    func finish(_ record: CaptureJournal.Record, directory: URL) throws
    func recoverPending(directory: URL) throws -> CaptureJournal.Record?
    func discardPending() throws
    func render(resources: ColorResources, _ payload: any CapturePayload, snapshot: CaptureSnapshot,
                progress: @escaping @Sendable (Double) -> Void,
                isCancelled: @escaping @Sendable () -> Bool) throws -> CaptureRenderResult
}

public struct CaptureFormats: Sendable {
    public let formats: [any CaptureFormat]
    public init(_ formats: [any CaptureFormat] = []) { self.formats = formats }

    public func format(identifier: String?) -> (any CaptureFormat)? {
        formats.first { $0.identifier == identifier }
    }
    func requireFormat(identifier: String) throws -> any CaptureFormat {
        guard let format = format(identifier: identifier) else { throw CaptureJournal.Failure.unsupportedVersion }
        return format
    }
    package func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[Self.decoderKey] = self
        return decoder
    }
    static let decoderKey = CodingUserInfoKey(rawValue: "GlassCam.CaptureFormats")!
}

public struct CapturedCameraPhoto: Sendable {
    public let data: Data
    public let framing: CaptureFraming
    public let burst: (any CapturePayload)?
    public init(data: Data, framing: CaptureFraming, burst: (any CapturePayload)? = nil) {
        self.data = data; self.framing = framing; self.burst = burst
    }
}

struct CaptureSourceFailure: LocalizedError {
    let source: any CapturePayload
    let detail: String
    var errorDescription: String? { "\(source.formatIdentifier.uppercased()) · DAMAGED_BUNDLE: \(detail)" }
}
