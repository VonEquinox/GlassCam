import Foundation

/// DNG characterization for the current sensor delivery. A metadata-derived
/// model does not claim the independent qualification of an imported profile.
enum F5BayerModel {
    static func highlightGreenWhite(_ metadata: F5DNGMetadata, relativeExposure: Double) -> Float {
        guard let black = metadata.blackLevel.first, metadata.blackLevel.allSatisfy({ $0 == black }),
              metadata.blackDeltaH.isEmpty, metadata.blackDeltaV.isEmpty, metadata.linearization.isEmpty,
              !metadata.opcodes.contains(where: { $0.list == 2 && $0.id == 9 }) else { return 0 }
        return Float(1 / relativeExposure)
    }

    static func make(_ frame: F5FrameRecord, hardware: String, os: String) throws -> F5DeviceProfile {
        let m = frame.metadata
        try F5BayerLayout.validate(fourCC: frame.rawFourCC, metadata: m)
        guard let white = m.whiteLevel.first, white.isFinite, white > 0, m.whiteLevel.allSatisfy({ $0 == white }),
              [2,6].contains(m.noiseProfile.count), m.noiseProfile.allSatisfy(\.isFinite) else {
            throw F5Failure(.unsupportedRAW, "The Bayer DNG requires a white level and a valid NoiseProfile.")
        }
        // The supported CV formats carry right-aligned 14-bit codes in UInt16.
        // DNG WhiteLevel identifies the file's code precision, including a
        // 16-bit TIFF container holding a 12-bit DNG code domain.
        let codeBits = Int(ceil(log2(white + 1)))
        guard (8...14).contains(codeBits), abs(white / Double((1 << codeBits) - 1) - 1) <= 0.02 else {
            throw F5Failure(.unsupportedRAW, "The native Bayer / DNG code scale is unsupported.")
        }
        let divisor = 1 << (14 - codeBits)
        let black = (m.blackLevel.max() ?? 0) + (m.blackDeltaH.max() ?? 0) + (m.blackDeltaV.max() ?? 0)
        let scale = white - black
        guard scale.isFinite, scale > 0 else { throw F5Failure(.unsupportedRAW, "Invalid DNG black-to-white scale.") }
        let noise = try F5Phase.allCases.map { phase -> F5NoisePhase in
            let index = m.noiseProfile.count == 2 ? 0 : phase.color * 2
            let alpha = m.noiseProfile[index], beta = m.noiseProfile[index + 1]
            guard alpha >= 0, beta > 0 else { throw F5Failure(.unsupportedRAW, "Invalid DNG noise coefficients.") }
            return .init(kappa: max(alpha,1e-12), readSigma: sqrt(beta), lowerThreshold: -black / scale,
                         upperThreshold: 1, lowerCensorCode: 0, upperCensorCode: min(16383,Int((white * Double(divisor)).rounded())), gain: 1)
        }
        let mapping = try F5Hash.json(["fourCC":frame.rawFourCC,"nativeBits":14,"dngCodeBits":UInt32(codeBits),"divisor":UInt32(divisor)])
        return F5DeviceProfile(version: "1.0", id: "dng-bayer-characterization", hardwareModel: hardware, osBuild: os,
            physicalCameraID: frame.physicalCameraID, physicalCameraType: "main", formatSignature: frame.formatSignature,
            rawFourCC: frame.rawFourCC, width: frame.raster.width, height: frame.raster.height, cfa: frame.raster.cfa,
            isoRange: [frame.actualISO,frame.actualISO], focusRange: [frame.focus,frame.focus], aperture: frame.aperture,
            oisPolicy: frame.oisPolicy, decoderRevision: F5Version.decoder, buildRevision: F5Version.build,
            qualification: .unqualified, gateEvidence: [:], calibrationManifestSHA256: m.sourceSHA256,
            colorValidationSHA256: m.sourceSHA256, whiteScale: scale, noise: noise, blackResidualByPhase: [0,0,0,0],
            handheldMaxExposure: nil, likelihood: .init(revision: "f5-pg-v1", table: nil, nllMaximumError: 0,
                standardizedScoreMaximumError: 0, gaussianMinimumElectrons: nil, exactMaximumElectrons: 2000),
            policy: F5Policy(), rawCodeRange: [0,16383], targetDeviceName: nil,
            bufferCodeMapping: .init(divisor: divisor, dngStage1Rounding: "floor", evidenceSHA256: F5Hash.data(mapping)))
    }
}
