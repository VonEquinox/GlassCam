import Foundation
import simd

/// Mac-only replay of the exact saved analysis rasters. No camera and no source edits.
/// Uses the complete 2D search; never reuses the phone's cached F/geometry/gain certificate.
@main
struct RecordedSeamReplay {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manifests = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("-manifest.json") }.sorted { $0.path < $1.path }
        var rows: [[String: Any]] = []
        for (index, url) in manifests.enumerated() {
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let analysis = record["analysis"] as! [String: Any]
            let prefix = String(format: "%02d-", index + 1)
            var row: [String: Any] = ["scene": index + 1, "id": record["id"]!,
                "recordedEvidence": analysis["evidence"] ?? [:]]
            guard let referenceName = analysis["referenceFile"] as? String,
                  let warpedName = analysis["warpedFile"] as? String,
                  let width = analysis["width"] as? Int, let height = analysis["height"] as? Int,
                  let padding = analysis["padding"] as? Int else {
                row["skipped"] = "No complete analysis rasters were saved"; rows.append(row); continue
            }
            let reference = [UInt8](try Data(contentsOf: root.appendingPathComponent(prefix + referenceName)))
            let warped = [UInt8](try Data(contentsOf: root.appendingPathComponent(prefix + warpedName)))
            let result = analysis["result"] as? [String: Any]
            let gainValues = result?["gain"] as? [Double] ?? [1,1,1]
            let gain = SIMD3(Float(gainValues[0]),Float(gainValues[1]),Float(gainValues[2]))
            let seams = PeripheralSeams(rawValue: analysis["seams"] as? Int ?? 3)
            guard let measured = PeripheralAlignmentWorker.measureSeams(reference: reference,warped: warped,
                width: width,height: height,warpedPadding: padding,seams: seams,
                certifiedGeometry: false,previousGain: gain,allowPartial: true,comparisonBudget: 120_000_000) else {
                row["skipped"] = "Invalid saved raster contract"; rows.append(row); continue
            }
            row["replayedEvidence"] = PeripheralRecordJSON.evidence(measured.evidence)
            row["geometryVerified"] = measured.geometryVerified
            row["photometryVerified"] = measured.photometryVerified
            row["gain"] = [measured.gain.x,measured.gain.y,measured.gain.z]
            row["boundaryMismatch"] = measured.boundaryMismatch
            row["comparisons"] = measured.comparisons
            row["segments"] = measured.segments.map { segment -> [String: Any] in
                var value: [String: Any] = ["index": segment.index,"status": segment.status.rawValue,
                    "point": [segment.point.x,segment.point.y],"searchComplete": segment.searchComplete]
                if let range = segment.interval { value["interval"] = [range.lowerBound,range.upperBound] }
                if let best = segment.best { value["bestDisplacement"] = [best.x,best.y] }
                return value
            }
            rows.append(row)
        }
        try PeripheralRecordJSON.data(["mode": "actual-production-full-2D-no-temporal-cache",
            "records": rows]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        print("Replayed \(rows.count) recorded scenes with the production matcher")
    }
}
