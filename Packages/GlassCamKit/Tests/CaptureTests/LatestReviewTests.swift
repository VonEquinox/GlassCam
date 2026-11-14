import Foundation
import CoreImage
import ImageIO
import Testing
import GlassCamTestSupport
@testable import Capture
@testable import ImagingCore

struct LatestReviewTests {
    private func capture(red: CGFloat = 0.25) throws -> SavedCapture {
        let file = TemporaryHEIFFile()
        let image = CIImage(color: CIColor(red: red, green: 0.5, blue: 0.75))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let data = try #require(CIContext().pngRepresentation(of: image, format: .RGBA16,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        try data.write(to: file.url)
        return try CaptureWorkflow.Services.review(file, snapshot: .init(recipe: .standard, output: .camera24()),
                                                    control: CaptureProcessingControl())
    }

    @Test func newStore_reopensConfirmedBytesAndFrozenRecipe() throws {
        let work = try TestDirectory()
        let saved = try capture()
        try LatestReviewStore(directory: work.url).save(saved)

        let reopened = try #require(try LatestReviewStore(directory: work.url).load())

        #expect(reopened.id == saved.id)
        #expect(try Data(contentsOf: reopened.file.url) == Data(contentsOf: saved.file.url))
        #expect(reopened.snapshot.recipe == saved.snapshot.recipe)
    }

    @Test func replacement_keepsOneGenerationAndExistingShareOwner() throws {
        let work = try TestDirectory()
        let store = LatestReviewStore(directory: work.url)
        let first = try capture(), second = try capture(red: 0.75)
        try store.save(first)
        let firstBytes = try Data(contentsOf: first.file.url)

        try store.save(second)

        #expect(try store.load()?.id == second.id)
        #expect(try Data(contentsOf: first.file.url) == firstBytes)
        let generations = try FileManager.default.contentsOfDirectory(at: work.url, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        #expect(generations.count == 1)
    }

    @Test func recoveringOlderReceipt_doesNotReplaceMoreRecentlyConfirmedPhoto() throws {
        let work = try TestDirectory(), store = LatestReviewStore(directory: work.url)
        let earlierDate = Date(timeIntervalSince1970: 1_700_000_000)
        let laterDate = earlierDate.addingTimeInterval(10)
        let earlier = try capture().confirming(at: earlierDate)
        let later = try capture(red: 0.75).confirming(at: laterDate)
        try store.save(later)

        try store.save(earlier)

        let restored = try #require(try store.load())
        #expect(restored.id == later.id)
        #expect(restored.confirmedAt == laterDate)
    }

    @Test func retryingReceipt_keepsOriginalConfirmationTime() throws {
        let work = try TestDirectory(), saved = try capture()
        let journal = CaptureJournal(directory: work.url.appendingPathComponent("pending"))
        let id = UUID(), attempt = UUID()
        _ = try journal.retain(Data(contentsOf: saved.file.url), id: id, snapshot: saved.snapshot)
        _ = try journal.storeEncoded(saved, id: id)
        _ = try journal.beginSave(id: id, attemptID: attempt)
        let confirmation = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try journal.confirmSaved(id: id, attemptID: attempt, confirmedAt: confirmation)

        let retried = try journal.confirmSaved(id: id, attemptID: attempt,
                                               confirmedAt: confirmation.addingTimeInterval(60))

        #expect(retried?.confirmedAt == confirmation)
    }

    @Test func incompleteReplacement_keepsLastPublishedPhoto() throws {
        let work = try TestDirectory()
        let store = LatestReviewStore(directory: work.url), saved = try capture()
        try store.save(saved)
        let interrupted = work.url.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: false)
        try Data([0, 1, 2]).write(to: interrupted.appendingPathComponent("photo.heic"))

        let restored = try store.load()

        #expect(restored?.id == saved.id)
        #expect(!FileManager.default.fileExists(atPath: interrupted.path))
    }

    @Test func changedStoredBytes_areRejectedWithoutChangingOriginal() throws {
        let work = try TestDirectory()
        let store = LatestReviewStore(directory: work.url), saved = try capture()
        try store.save(saved)
        let original = try Data(contentsOf: saved.file.url)
        let generation = try #require(FileManager.default.contentsOfDirectory(at: work.url, includingPropertiesForKeys: nil)
            .first { UUID(uuidString: $0.lastPathComponent) != nil })
        var corrupted = original; corrupted[0] ^= 1
        try corrupted.write(to: generation.appendingPathComponent("photo.heic"))

        #expect(throws: CaptureJournal.Failure.damaged) { try store.load() }

        #expect(try Data(contentsOf: saved.file.url) == original)
    }

    @Test func reviewDirectory_isExcludedFromBackup() throws {
        let work = try TestDirectory(), saved = try capture()
        let directory = work.url.appendingPathComponent("review")

        try LatestReviewStore(directory: directory).save(saved)

        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
}

struct PhotoCaptureInfoTests {
    @Test func deliveredEXIF_preservesPhysicalCaptureSettings() {
        let metadata = PhotoMetadata(properties: [kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifExposureTime as String: 1.0 / 120,
            kCGImagePropertyExifISOSpeedRatings as String: [80],
            kCGImagePropertyExifFNumber as String: 1.78,
            kCGImagePropertyExifFocalLength as String: 6.765,
            kCGImagePropertyExifFocalLenIn35mmFilm as String: 24
        ]])

        let info = metadata.captureInfo

        #expect(info == PhotoCaptureInfo(exposureTime: 1.0 / 120, iso: 80, aperture: 1.78,
                                         focalLength: 6.765, equivalentFocalLength: 24))
    }

    @Test(arguments: [Double.nan, .infinity, -1, 0])
    func invalidCaptureValues_areOmitted(value: Double) {
        let info = PhotoCaptureInfo(exposureTime: value, iso: value, aperture: value)

        #expect(info == PhotoCaptureInfo())
    }
}
