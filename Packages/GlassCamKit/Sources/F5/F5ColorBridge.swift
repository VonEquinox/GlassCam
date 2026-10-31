import ImagingCore
import Capture
import Foundation
import CoreImage

struct F5Matrix3: Codable, Equatable, Sendable {
    let values: [Double] // row-major; signed out-of-gamut values are preserved
    init(_ values: [Double]) throws {
        guard values.count == 9, values.allSatisfy(\.isFinite) else { throw F5Failure(.colorTransformInvalid, "Expected a finite 3×3 color matrix.") }
        self.values = values
    }
    static let identity = try! F5Matrix3([1,0,0, 0,1,0, 0,0,1])
    func apply(_ v: [Double]) -> [Double] {
        (0..<3).map { row in values[row*3]*v[0] + values[row*3+1]*v[1] + values[row*3+2]*v[2] }
    }
    func times(_ b: F5Matrix3) throws -> F5Matrix3 {
        var result = [Double](repeating: 0, count: 9)
        for r in 0..<3 { for c in 0..<3 { for k in 0..<3 { result[r*3+c] += values[r*3+k] * b.values[k*3+c] } } }
        return try F5Matrix3(result)
    }
    func inverse() throws -> F5Matrix3 {
        let a = values
        let cofactors = [a[4]*a[8]-a[5]*a[7], a[2]*a[7]-a[1]*a[8], a[1]*a[5]-a[2]*a[4],
                         a[5]*a[6]-a[3]*a[8], a[0]*a[8]-a[2]*a[6], a[2]*a[3]-a[0]*a[5],
                         a[3]*a[7]-a[4]*a[6], a[1]*a[6]-a[0]*a[7], a[0]*a[4]-a[1]*a[3]]
        let det = a[0]*cofactors[0] + a[1]*cofactors[3] + a[2]*cofactors[6]
        guard det.isFinite, abs(det) > 1e-12 else { throw F5Failure(.colorTransformInvalid, "Singular camera color matrix.") }
        return try F5Matrix3(cofactors.map { $0 / det })
    }
    func scaled(_ value: Double) throws -> F5Matrix3 { try F5Matrix3(values.map { $0 * value }) }
    static func diagonal(_ v: [Double]) throws -> F5Matrix3 {
        guard v.count == 3 else { throw F5Failure(.colorTransformInvalid, "Invalid channel scaling.") }
        return try .init([v[0],0,0, 0,v[1],0, 0,0,v[2]])
    }
    static func interpolate(_ a: F5Matrix3, _ b: F5Matrix3, firstWeight: Double) throws -> F5Matrix3 {
        try .init(zip(a.values, b.values).map { firstWeight * $0 + (1 - firstWeight) * $1 })
    }
}

struct F5ColorTransformRecord: Codable, Sendable {
    let cameraToXYZD50: F5Matrix3, cameraToLinearSRGB: F5Matrix3
    let inputScale: Double, whiteX: Double, whiteY: Double, temperature: Double
    let whiteBalanceOwner: String, sourceDNGSHA256: String, profileSHA256: String
    let decodeRevision: String, colorBridgeRevision: String
    let ledger: [String]
    var hash: String { (try? F5Hash.data(F5Hash.json(self))) ?? "" }
    var whiteBalance: PhotoWhiteBalance {
        .init(origin: .f5Matrix, temperature: temperature, tint: 0, x: whiteX, y: whiteY)
    }
}

enum F5ColorBridge {
    /// BaselineExposure belongs to RAW rendering, independently of relative
    /// burst exposure normalization and the user's later exposure adjustment.
    static func rendering(metadata: F5DNGMetadata, profile: F5DeviceProfile) throws -> F5ColorTransformRecord {
        let base = try make(metadata: metadata, profile: profile)
        let ev = metadata.baselineExposure ?? 0
        guard ev.isFinite, abs(ev) <= 16 else { throw F5Failure(.colorTransformInvalid, "Invalid DNG baseline exposure.") }
        return try .init(cameraToXYZD50: base.cameraToXYZD50.scaled(exp2(ev)),
            cameraToLinearSRGB: base.cameraToLinearSRGB.scaled(exp2(ev)), inputScale: base.inputScale,
            whiteX: base.whiteX, whiteY: base.whiteY, temperature: base.temperature,
            whiteBalanceOwner: base.whiteBalanceOwner, sourceDNGSHA256: base.sourceDNGSHA256,
            profileSHA256: base.profileSHA256, decodeRevision: base.decodeRevision, colorBridgeRevision: F5Version.renderingColorBridge,
            ledger: Array(base.ledger.dropLast()) + ["DNG_baseline_exposure_once_\(ev)_EV", "no_look_table_no_tone_curve"])
    }
    // Independently implemented from DNG 1.7.1 pp. 100–103. The reference oracle
    // is the SDK's linear CameraToPCS branch (no look tables or tone curves).
    static let d50 = [0.3457, 0.3585], d65 = [0.3127, 0.3290]
    static func xyz(_ xy: [Double]) throws -> [Double] {
        guard xy.count == 2, xy.allSatisfy(\.isFinite), xy[0] > 0, xy[1] > 0, xy[0] + xy[1] < 1 else {
            throw F5Failure(.colorTransformInvalid, "Invalid illuminant chromaticity.")
        }
        return [xy[0]/xy[1], 1, (1-xy[0]-xy[1])/xy[1]]
    }
    static func chromaticity(_ xyz: [Double]) throws -> [Double] {
        let sum = xyz.reduce(0, +)
        guard xyz.count == 3, xyz.allSatisfy(\.isFinite), sum > 0 else { throw F5Failure(.colorTransformInvalid, "Invalid neutral tristimulus values.") }
        let xy = [xyz[0]/sum, xyz[1]/sum]; _ = try self.xyz(xy); return xy
    }
    static func kelvin(_ xy: [Double]) throws -> Double {
        _ = try xyz(xy)
        // Robertson isotemperature lines (Wyszecki & Stiles, p. 228), using
        // continuous reciprocal temperature. HNCS's rounded/clamped factory
        // CCT would change dual-illuminant DNG interpolation and is not used.
        let table: [[Double]] = [
            [0,0.18006,0.26352,-0.24341],[10,0.18066,0.26589,-0.25479],[20,0.18133,0.26846,-0.26876],
            [30,0.18208,0.27119,-0.28539],[40,0.18293,0.27407,-0.30470],[50,0.18388,0.27709,-0.32675],
            [60,0.18494,0.28021,-0.35156],[70,0.18611,0.28342,-0.37915],[80,0.18740,0.28668,-0.40955],
            [90,0.18880,0.28997,-0.44278],[100,0.19032,0.29326,-0.47888],[125,0.19462,0.30141,-0.58204],
            [150,0.19962,0.30921,-0.70471],[175,0.20525,0.31647,-0.84901],[200,0.21142,0.32312,-1.0182],
            [225,0.21807,0.32909,-1.2168],[250,0.22511,0.33439,-1.4512],[275,0.23247,0.33904,-1.7298],
            [300,0.24010,0.34308,-2.0637],[325,0.24702,0.34655,-2.4681],[350,0.25591,0.34951,-2.9641],
            [375,0.26400,0.35200,-3.5814],[400,0.27218,0.35407,-4.3633],[425,0.28039,0.35577,-5.3762],
            [450,0.28863,0.35714,-6.7262],[475,0.29685,0.35823,-8.5955],[500,0.30505,0.35907,-11.324],
            [525,0.31320,0.35968,-15.628],[550,0.32129,0.36011,-23.325],[575,0.32931,0.36038,-40.770],
            [600,0.33724,0.36051,-116.45]]
        let denominator = 1.5 - xy[0] + 6 * xy[1], u = 2 * xy[0] / denominator, v = 3 * xy[1] / denominator
        var previous = 0.0
        for i in 1..<table.count {
            let line = table[i], distance = (v - line[2] - (u - line[1]) * line[3]) / sqrt(1 + line[3] * line[3])
            if distance <= 0 || i == table.count - 1 {
                let d = -min(0, distance), weight = i == 1 ? 0 : d / (previous + d)
                let reciprocal = table[i-1][0] * weight + line[0] * (1 - weight)
                guard reciprocal > 0, reciprocal.isFinite else { throw F5Failure(.colorTransformInvalid, "Invalid reciprocal color temperature.") }
                return 1e6 / reciprocal
            }
            previous = distance
        }
        throw F5Failure(.colorTransformInvalid, "Cannot determine the DNG interpolation white point.")
    }
    static func adaptation(from: [Double], to: [Double]) throws -> F5Matrix3 {
        let bradford = try F5Matrix3([0.8951,0.2664,-0.1614, -0.7502,1.7135,0.0367, 0.0389,-0.0685,1.0296])
        let a = try bradford.apply(xyz(from)), b = try bradford.apply(xyz(to))
        guard a.allSatisfy({ $0 > 0 }), b.allSatisfy({ $0 > 0 }) else { throw F5Failure(.colorTransformInvalid, "Nonphysical Bradford white point.") }
        let scale = zip(a, b).map { min(10, max(0.1, $1 / $0)) }
        return try bradford.inverse().times(.diagonal(scale)).times(bradford)
    }
    private static func illuminantTemperature(_ code: Int) throws -> Double {
        switch code {
        case 17: return 2850
        case 18: return 5500
        case 19: return 6500
        case 20: return 5500
        case 21: return 6500
        case 22: return 7500
        case 23: return 5000
        case 24: return 3200
        case 1, 4, 9: return 5500
        case 3: return 2850
        case 10: return 6500
        case 11: return 7500
        default: throw F5Failure(.colorTransformInvalid, "Unsupported DNG calibration illuminant \(code).")
        }
    }
    static func make(metadata m: F5DNGMetadata, profile: F5DeviceProfile) throws -> F5ColorTransformRecord {
        guard m.colorMatrix1.count == 9, m.asShotNeutral.isEmpty || (m.asShotNeutral.count == 3 && m.asShotNeutral.allSatisfy({ $0 > 0 })),
              m.asShotNeutral.isEmpty != m.asShotWhiteXY.isEmpty else {
            throw F5Failure(.colorTransformInvalid, "A camera matrix and exactly one as-shot white specification are required.")
        }
        let ab = try F5Matrix3.diagonal(m.analogBalance.isEmpty ? [1,1,1] : m.analogBalance)
        let useCalibration = m.calibrationSignature == m.profileSignature
        let cc1 = try useCalibration && !m.cameraCalibration1.isEmpty ? F5Matrix3(m.cameraCalibration1) : .identity
        let cc2 = try useCalibration && !m.cameraCalibration2.isEmpty ? F5Matrix3(m.cameraCalibration2) : .identity
        func sdkColorMatrix(_ values:[Double]) throws -> F5Matrix3 {
            let matrix=try F5Matrix3(values),maximum=try matrix.apply(xyz(d50)).max() ?? 0
            let scale=maximum>0 && (maximum<0.99 || maximum>1.01) ? 1/maximum : 1
            // Adobe's profile ingestion normalizes each illuminant separately
            // and rounds to four decimals before dual-illuminant interpolation.
            return try F5Matrix3(values.map { ($0*scale*10000).rounded()/10000 })
        }
        let cm1 = try ab.times(cc1).times(sdkColorMatrix(m.colorMatrix1))
        let hasTwo = m.colorMatrix2.count == 9 && m.illuminant2 != 0
        let cm2 = try hasTwo ? ab.times(cc2).times(sdkColorMatrix(m.colorMatrix2)) : cm1
        let t1 = try illuminantTemperature(m.illuminant1), t2 = try hasTwo ? illuminantTemperature(m.illuminant2) : t1
        func weight(_ xy: [Double]) throws -> Double {
            if !hasTwo || t1 == t2 { return 1 }
            let t = try kelvin(xy)
            return min(1, max(0, (1/t - 1/t2) / (1/t1 - 1/t2)))
        }
        var white = m.asShotWhiteXY.isEmpty ? d50 : m.asShotWhiteXY
        if !m.asShotNeutral.isEmpty {
            var settled = false
            for _ in 0..<30 {
                let cm = try F5Matrix3.interpolate(cm1, cm2, firstWeight: weight(white))
                let next = try chromaticity(cm.inverse().apply(m.asShotNeutral))
                let delta = abs(next[0] - white[0]) + abs(next[1] - white[1]); white = next
                if delta < 1e-7 { settled = true; break }
            }
            guard settled else { throw F5Failure(.colorTransformInvalid, "DNG neutral interpolation did not converge.") }
        }
        let w = try weight(white), cm = try F5Matrix3.interpolate(cm1, cm2, firstWeight: w)
        let calibration = try F5Matrix3.interpolate(cc1, hasTwo ? cc2 : cc1, firstWeight: w)
        let cameraWhite = try cm.apply(xyz(white)), maximum = cameraWhite.max() ?? 0
        guard maximum > 0, cameraWhite.allSatisfy({ $0 > 0 }) else { throw F5Failure(.colorTransformInvalid, "Nonpositive camera white.") }
        let neutral = cameraWhite.map { min(1, max(0.001, $0 / maximum)) }
        func normalizedForward(_ values: [Double]) throws -> F5Matrix3? {
            if values.isEmpty { return nil }
            let fm = try F5Matrix3(values.map{($0*10000).rounded()/10000}), sums = fm.apply([1,1,1]), target = try xyz(d50)
            guard sums.allSatisfy({ $0 > 0 }) else { throw F5Failure(.colorTransformInvalid, "Invalid forward-matrix white.") }
            return try F5Matrix3.diagonal(zip(target, sums).map { $0 / $1 }).times(fm)
        }
        let forward1 = try normalizedForward(m.forwardMatrix1)
        let forward2 = try hasTwo ? normalizedForward(m.forwardMatrix2) : forward1
        let forward: F5Matrix3?
        if let a = forward1, let b = forward2 { forward = try .interpolate(a, b, firstWeight: w) }
        else { forward = forward1 ?? forward2 }
        let cameraToPCS: F5Matrix3
        if let forward {
            let toReference = try ab.times(calibration).inverse(), referenceNeutral = toReference.apply(neutral)
            guard referenceNeutral.allSatisfy({ $0 > 0 }) else { throw F5Failure(.colorTransformInvalid, "Invalid reference-camera neutral.") }
            cameraToPCS = try forward.times(.diagonal(referenceNeutral.map { 1 / $0 })).times(toReference)
        } else {
            let pcsToCamera = try cm.times(adaptation(from: d50, to: white))
            let scale = try pcsToCamera.apply(xyz(d50)).max() ?? 0
            guard scale > 0 else { throw F5Failure(.colorTransformInvalid, "Invalid PCS normalization.") }
            cameraToPCS = try pcsToCamera.scaled(1 / scale).inverse()
        }
        // The matrix's input must use our single W0, not silently inherit the
        // DNG renderer's per-plane white/max-black rescaling.
        let maximumBlack = (m.blackLevel.max() ?? 0) + (m.blackDeltaH.max() ?? 0) + (m.blackDeltaV.max() ?? 0)
        guard let whiteCode = m.whiteLevel.first, whiteCode > maximumBlack else { throw F5Failure(.colorTransformInvalid, "Invalid DNG reference scale.") }
        let toXYZ = try cameraToPCS.scaled(profile.whiteScale / (whiteCode - maximumBlack))
        let xyzToSRGB = try F5Matrix3([3.2409699419,-1.5373831776,-0.4986107603, -0.9692436363,1.8759675015,0.0415550574, 0.0556300797,-0.2039769589,1.0569715142])
        let toSRGB = try xyzToSRGB.times(adaptation(from: d50, to: d65)).times(toXYZ)
        return try .init(cameraToXYZD50: toXYZ, cameraToLinearSRGB: toSRGB, inputScale: profile.whiteScale,
            whiteX: white[0], whiteY: white[1], temperature: kelvin(white), whiteBalanceOwner: "matrix",
            sourceDNGSHA256: m.sourceSHA256, profileSHA256: profile.hash, decodeRevision: F5Version.decoder,
            colorBridgeRevision: F5Version.colorBridge, ledger: ["single_W0_to_DNG_reference_scale",
                "SDK_profile_matrix_normalization_and_precision",useCalibration ? "matching_camera_calibration" : "unmatched_calibration_identity", "analog_balance_in_matrix",
                "as_shot_white_balance_in_matrix_once", forward != nil ? "normalized_forward_matrix_to_D50" : "Bradford_to_D50",
                "Bradford_D50_to_D65", "signed_extended_linear_sRGB", "no_look_table_no_tone_curve_no_baseline_exposure"])
    }
}
