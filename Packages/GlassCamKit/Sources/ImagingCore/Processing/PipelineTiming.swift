import Foundation
import CoreImage
import ImageIO

/// Opt-in wall-clock spans for the synchronous export queue. The caller reads
/// this object only after writeHEIF returns. Normal exports pass nil; timings
/// never insert renders, synchronize extra GPU work, or change pixel math.
public final class PipelineTiming: @unchecked Sendable {
    public init() {}
    public private(set) var seconds = [String: Double]()
    public private(set) var calls = [String: Int]()
    public private(set) var firstSeconds = [String: Double]()
    public private(set) var maximumSeconds = [String: Double]()
    public private(set) var thermalStates = Set<Int>()

    public func start() -> Double { ProcessInfo.processInfo.systemUptime }
    public func record(_ stage: String, since start: Double?) {
        guard let start else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        seconds[stage, default: 0] += elapsed
        calls[stage, default: 0] += 1
        if firstSeconds[stage] == nil { firstSeconds[stage] = elapsed }
        maximumSeconds[stage] = max(maximumSeconds[stage, default: 0], elapsed)
        if stage == "raw_render" { thermalStates.insert(ProcessInfo.processInfo.thermalState.rawValue) }
    }
}
