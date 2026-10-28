import Foundation
import Metal
import simd

struct F5MetalFrame {
    let raw, table, eligibility: F5MetalBuffer
    let uniforms: F5GPUFrame
    static func upload(_ frame: F5CanonicalFrame, to device: F5MetalDevice) throws -> F5MetalFrame {
        let m = frame.record.metadata, descriptor = frame.record.raster, profile = frame.profile, correction = frame.corrections
        func float4(_ v: [Double]) -> SIMD4<Float> { SIMD4(Float(v[0]), Float(v[1]), Float(v[2]), Float(v[3])) }
        func uint4(_ v: [Int]) -> SIMD4<UInt32> { SIMD4(UInt32(v[0]), UInt32(v[1]), UInt32(v[2]), UInt32(v[3])) }
        var table: [Float] = []
        func add(_ values: [Double]) -> UInt32 { let offset = UInt32(table.count); table += values.map(Float.init); return offset }
        func addBits(_ values: [Int]) -> UInt32 { let offset = UInt32(table.count); table += values.map { Float(bitPattern: UInt32($0)) }; return offset }
        let black = add(m.blackLevel), dh = m.blackDeltaH.isEmpty ? UInt32.max : add(m.blackDeltaH)
        let dv = m.blackDeltaV.isEmpty ? UInt32.max : add(m.blackDeltaV), linearization = add(m.linearization)
        let gainRecords = UInt32(table.count); table += [Float](repeating: 0, count: correction.gains.count * 16)
        for (i, gain) in correction.gains.enumerated() {
            let values = add(gain.values), start = Int(gainRecords) + i * 16
            let record: [Float] = [Float(gain.area.top), Float(gain.area.left), Float(gain.area.bottom), Float(gain.area.right),
                Float(gain.rowPitch), Float(gain.colPitch), Float(gain.rows), Float(gain.columns),
                Float(gain.originX), Float(gain.originY), Float(gain.spacingX), Float(gain.spacingY), Float(bitPattern: values), 0, 0, 0]
            table.replaceSubrange(start..<(start + 16), with: record)
        }
        let badCodes = addBits(correction.badCodes.sorted().map(Int.init)), badPoints = addBits(correction.badPoints.sorted())
        let badAreas = add(correction.badAreas.flatMap { [Double($0.top), Double($0.left), Double($0.bottom), Double($0.right)] })
        let range = profile.rawCodeRange ?? [0, (1 << descriptor.bitsPerSample) - 1]
        let f = F5GPUFrame(shape: SIMD4(UInt32(descriptor.width), UInt32(descriptor.height), UInt32(descriptor.rowBytes/2), UInt32(descriptor.bitsPerSample)),
            active: SIMD4(UInt32(descriptor.activeArea.left), UInt32(descriptor.activeArea.top), UInt32(descriptor.activeArea.width), UInt32(descriptor.activeArea.height)),
            cfa: uint4(descriptor.cfa.map(\.rawValue)), scale: SIMD4(Float(frame.exposure), Float(profile.whiteScale), Float(range[0]), Float(range[1])),
            kappa: float4(profile.noise.map(\.kappa)), readSigma: float4(profile.noise.map(\.readSigma)),
            low: float4(profile.noise.map(\.lowerThreshold)), high: float4(profile.noise.map(\.upperThreshold)),
            gain: float4(profile.noise.map(\.gain)), blackResidual: float4(profile.blackResidualByPhase),
            censorLow: uint4(profile.noise.map(\.lowerCensorCode)), censorHigh: uint4(profile.noise.map(\.upperCensorCode)),
            black: SIMD4(UInt32(m.blackRepeat[0]), UInt32(m.blackRepeat[1]), black, dh),
            tables: SIMD4(dv, linearization, UInt32(m.linearization.count), UInt32(correction.gains.count)),
            extras: SIMD4(gainRecords, badCodes, UInt32(correction.badCodes.count), badPoints),
            extra2: SIMD4(UInt32(correction.badPoints.count), badAreas, UInt32(correction.badAreas.count), UInt32(frame.codeDivisor)))
        var codes = frame.codes
        if descriptor.byteOrder == .big {
            codes.withUnsafeMutableBytes { raw in
                let values = raw.bindMemory(to: UInt16.self)
                for i in values.indices { values[i] = values[i].byteSwapped }
            }
        }
        let rawBuffer = try device.upload(codes, label: "F5 original integer RAW")
        let tableBuffer = try device.upload(table, label: "F5 metadata tables")
        let eligibilityBuffer = try device.upload([UInt32](repeating: .max,
            count: (descriptor.activeArea.width * descriptor.activeArea.height + 31)/32), label: "F5 frozen eligibility")
        return F5MetalFrame(raw: rawBuffer, table: tableBuffer, eligibility: eligibilityBuffer, uniforms: f)
    }
}

struct F5LikelihoodTableHeader: Codable {
    let revision: String, lambdaCount: Int, zCount: Int
    let logLambdaMinimum: Float, logLambdaStep: Float, zMinimum: Float, zStep: Float
    let intervalWidths: [Float]
    let nllError: Double, scoreError: Double
    let generatorSHA256: String
    let noiseKappa: [Float]?, noiseReadSigma: [Float]?
}
struct F5MetalLikelihood {
    let uniforms: F5GPULUT, table: F5MetalBuffer
    static func load(profile: F5DeviceProfile, directory: URL, device: F5MetalDevice) throws -> F5MetalLikelihood {
        var layout = SIMD4<UInt32>(repeating: 0), domain = SIMD4<Float>(0,1,-16,1), widths = SIMD4<Float>(repeating: 0)
        var payload = Data(count: 16)
        if let blob = profile.likelihood.table {
            try blob.verify(in: directory)
            let data = try Data(contentsOf: blob.url(in: directory), options: .mappedIfSafe), reader = F5Bytes(data, little: true)
            let length = Int(try reader.u32(0))
            guard length > 0, length <= 65536 else { throw F5Failure(.profileMismatch, "Invalid likelihood table header.") }
            let header = try JSONDecoder().decode(F5LikelihoodTableHeader.self, from: reader.slice(4, length))
            guard header.revision == "f5-pg-grid-v1", (2...8192).contains(header.lambdaCount), (2...8192).contains(header.zCount),
                  header.intervalWidths.count == 4, header.intervalWidths.allSatisfy({ $0.isFinite && $0 > 0 }),
                  header.logLambdaStep.isFinite, header.logLambdaStep > 0, header.zStep.isFinite, header.zStep > 0,
                  header.logLambdaMinimum.isFinite,header.zMinimum.isFinite,
                  header.nllError.isFinite,header.nllError>=0,header.nllError < 1e-4,
                  header.scoreError.isFinite,header.scoreError>=0,header.scoreError < 1e-3,
                  header.noiseKappa==profile.noise.map({Float($0.kappa)}),header.noiseReadSigma==profile.noise.map({Float($0.readSigma)}),
                  F5Hash.isSHA256(header.generatorSHA256) else {
                throw F5Failure(.profileMismatch, "Unverified likelihood lookup grid.")
            }
            let phaseStride = header.lambdaCount * header.zCount * 3
            guard phaseStride <= Int.max/64, data.count == 4 + length + phaseStride*4*16 else { throw F5Failure(.damagedBundle, "Likelihood table byte length is incorrect.") }
            payload = try reader.slice(4 + length, phaseStride*4*16)
            let finite=payload.withUnsafeBytes { raw in raw.bindMemory(to:Float.self).enumerated().allSatisfy { index,value in
                value.isFinite && (index%4 != 2 || value>=0) && (index%4 != 3 || (value>=0 && value<=1))
            }}
            guard finite else {throw F5Failure(.damagedBundle,"Invalid likelihood table values.")}
            layout = SIMD4(UInt32(header.lambdaCount), UInt32(header.zCount), UInt32(phaseStride), 1)
            domain = SIMD4(header.logLambdaMinimum, header.logLambdaStep, header.zMinimum, header.zStep)
            widths = SIMD4(header.intervalWidths[0], header.intervalWidths[1], header.intervalWidths[2], header.intervalWidths[3])
        }
        let uniforms = F5GPULUT(layout: layout, domain: domain, width: widths,
            limits: SIMD4(Float(profile.likelihood.exactMaximumElectrons), Float(profile.likelihood.gaussianMinimumElectrons ?? 0), 0, 0))
        return try .init(uniforms: uniforms, table: device.upload(payload, label: "F5 certified event likelihood lookup"))
    }
}
