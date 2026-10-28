import Foundation
import Testing
@testable import ImagingCore

struct WorkFileTests {
    @Test(arguments: [(-1,1),(0,0),(3,2),(0,5)])
    func invalidRowRange_isRejected(range: (Int,Int)) throws {
        let file = try HNCSPresetWorkFile(width: 2,height: 4)
        #expect(throws: PipelineError.rendering) { try file.readTopDownRows(originY: range.0, rows: range.1) }
        #expect(throws: PipelineError.rendering) { try file.writeTopDownRows([],originY: range.0,rows: range.1) }
    }
    @Test func incompleteRows_failReadAndSpatialPreparation() throws {
        let file = try HNCSPresetWorkFile(width: 2,height: 4)
        try file.writeTopDownRows([Float](repeating: 1,count: 6),originY: 0,rows: 1)
        #expect(throws: PipelineError.rendering) { try file.readTopDownRows(originY: 0,rows: 4) }
        #expect(throws: PipelineError.rendering) { try file.prepareForSpatialPass() }
    }
    @Test(arguments: [0,5,7])
    func incorrectChannelCount_isRejected(count: Int) throws {
        let file = try HNCSPresetWorkFile(width: 2,height: 4)
        #expect(throws: PipelineError.rendering) {
            try file.writeTopDownRows([Float](repeating: 0,count: count),originY: 0,rows: 1)
        }
    }
    @Test(arguments: [false,true])
    func releasingOwner_removesCompleteOrPartialScratch(complete: Bool) throws {
        var file: HNCSPresetWorkFile? = try HNCSPresetWorkFile(width: 2,height: 4)
        let url = try #require(file?.url)
        try file?.writeTopDownRows([Float](repeating: 1,count: complete ? 24 : 6),originY: 0,rows: complete ? 4 : 1)
        file = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
