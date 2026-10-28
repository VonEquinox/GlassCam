import Foundation
import CoreImage
import Testing
@testable import ImagingCore

struct ShareConcurrencyTests {
    func request(_ storage: ShareRepresentationStorage, compatibility: Bool = true) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = storage.requestFile(compatibility: compatibility) { continuation.resume(with: $0) }
        }
    }
    @Test func simultaneousJPEGRequests_encodeOnceAndReuseSameFile() async throws {
        let (original,_,_) = try ShareTests().encodedFile(hdr: false)
        var encodes = 0
        let storage = ShareRepresentationStorage(original: original,encodeJPEG: { context,image,url,space,options in
            encodes += 1
            try ShareRepresentationStorage.writeJPEG(context,image,url,space,options)
        })

        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<4 { group.addTask { try await request(storage) } }
            var results: [URL] = []
            for try await url in group { results.append(url) }
            return results
        }

        #expect(encodes == 1)
        #expect(Set(urls).count == 1)
        #expect(urls.count == 4)
    }
    @Test func cancellationBeforeWork_doesNotEncodeOrDeliverJPEG() async throws {
        let (original,_,_) = try ShareTests().encodedFile(hdr: false)
        let queue = DispatchQueue(label: "ShareTests.before")
        var encodes = 0
        let storage = ShareRepresentationStorage(original: original,queue: queue,encodeJPEG: { context,image,url,space,options in
            encodes += 1; try ShareRepresentationStorage.writeJPEG(context,image,url,space,options)
        })
        queue.suspend()
        let result: Result<URL,Error> = await withCheckedContinuation { continuation in
            let progress = storage.requestFile(compatibility: true) { continuation.resume(returning: $0) }
            progress.cancel(); queue.resume()
        }
        #expect(throws: CocoaError(.userCancelled)) { try result.get() }
        #expect(encodes == 0)
    }
    @Test func cancellationAfterEncoding_discardsPartialFileAndAllowsFreshRetry() async throws {
        let (original,_,_) = try ShareTests().encodedFile(hdr: false)
        let queue = DispatchQueue(label: "ShareTests.after")
        var encodes = 0
        var firstProgress: Progress?
        var paths: [URL] = []
        let storage = ShareRepresentationStorage(original: original,queue: queue,encodeJPEG: { context,image,url,space,options in
            encodes += 1; paths.append(url)
            try ShareRepresentationStorage.writeJPEG(context,image,url,space,options)
            if encodes == 1 { firstProgress?.cancel() }
        })
        queue.suspend()
        let cancelled: Result<URL,Error> = await withCheckedContinuation { continuation in
            firstProgress = storage.requestFile(compatibility: true) { continuation.resume(returning: $0) }
            queue.resume()
        }
        let retry = try await request(storage)

        #expect(throws: CocoaError(.userCancelled)) { try cancelled.get() }
        #expect(encodes == 2)
        #expect(!FileManager.default.fileExists(atPath: try #require(paths.first).path))
        #expect(retry == paths.last)
    }
    @Test func failedEncoding_isNotCachedAndOriginalRemainsReadable() async throws {
        let (original,_,_) = try ShareTests().encodedFile(hdr: false)
        let bytes = try Data(contentsOf: original.url)
        var encodes = 0
        let storage = ShareRepresentationStorage(original: original,encodeJPEG: { context,image,url,space,options in
            encodes += 1
            if encodes == 1 { throw CocoaError(.fileWriteUnknown) }
            try ShareRepresentationStorage.writeJPEG(context,image,url,space,options)
        })
        await #expect(throws: CocoaError(.fileWriteUnknown)) { try await request(storage) }
        _ = try await request(storage)
        #expect(encodes == 2)
        #expect(try Data(contentsOf: original.url) == bytes)
    }
    @Test func pendingCallback_ownsOriginalAfterProviderRelease() async throws {
        let queue = DispatchQueue(label: "ShareTests.ownership")
        var storage: ShareRepresentationStorage? = try {
            let file = TemporaryHEIFFile(); try Data([1,2,3]).write(to: file.url)
            return ShareRepresentationStorage(original: file,queue: queue)
        }()
        queue.suspend()
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            _ = storage?.requestFile(compatibility: false) { result in
                continuation.resume(with: result.flatMap { url in Result { try Data(contentsOf: url) } })
            }
            storage = nil
            queue.resume()
        }
        #expect(bytes == Data([1,2,3]))
    }
}
