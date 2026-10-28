import Testing
import Foundation
import GlassCamTestSupport

@Test(.enabled(if: ProcessInfo.processInfo.environment["GLASSCAM_GENERATE_JOURNAL_FIXTURES"] != nil,
    "Set GLASSCAM_GENERATE_JOURNAL_FIXTURES to a new directory outside the repository to generate a review candidate"))
func generateJournalFixtureCandidate() throws {
    let destination = try #require(TestResources.environmentURL("GLASSCAM_GENERATE_JOURNAL_FIXTURES")).standardizedFileURL
    let repository = TestResources.fixtures.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
    guard !FileManager.default.fileExists(atPath: destination.path),
          destination.path != repository.path, !destination.path.hasPrefix(repository.path + "/") else {
        throw CocoaError(.fileWriteFileExists)
    }
    let work = try TestDirectory()
    try JournalFixtures.generate(at: destination, work: work.url)
    print("Generated journal fixture candidate: \(destination.path)")
}
