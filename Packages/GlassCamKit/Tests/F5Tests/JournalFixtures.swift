import Capture
import Foundation

/// Fixed identities and the production Codable encoder used by journal examples.
enum JournalFixtures {
    static let captureID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let burstID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    static let createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func encode(_ record: CaptureJournal.Record) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

}
