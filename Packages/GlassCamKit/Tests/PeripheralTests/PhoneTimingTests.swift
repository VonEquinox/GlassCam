import Testing
import Foundation
@testable import Peripheral
import GlassCamTestSupport

private struct PhoneTimingObservation {
    let warmedValid: Int, warmedClear: Int, invalidShown: Int
    let policy: PeripheralGlassPolicy
    let end: Double
    static let result = Result { try measure() }
    static func measure() throws -> PhoneTimingObservation {
  let data=try Data(contentsOf:TestResources.fixtures.appendingPathComponent("peripheral/phone-glass-timing-20261023.json"))
  let document=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  var policy=PeripheralGlassPolicy(),ready=PeripheralReadiness(),last:UInt64=0
  var visible=0,clear=0,invalid=0,invalidShown=0,warmedValid=0,warmedClear=0,qualities:[Double]=[],effects:[Double]=[]
  for row in document["rows"] as! [[String:Any]] {
   let t=row["time"] as! Double,epoch=(row["epoch"] as! NSNumber).uint64Value
   let source=row["sourceAvailable"] as! Bool,id=(row["frameID"] as! NSNumber).uint64Value
   policy.tick(at:t,sourceAvailable:source,epoch:epoch)
   if id != last {
    let e=row["evidence"] as! [String:Any]
    var evidence=PeripheralEvidence(status:PeripheralEvidence.Status(rawValue:e["status"] as? String ?? "unobservable") ?? .unobservable,
      interval:nil,appearance:PeripheralEvidence.Appearance(rawValue:e["appearance"] as? String ?? "unknown") ?? .unknown,
      reason:e["reason"] as? String ?? "missing",searchComplete:e["searchComplete"] as? Bool ?? false,coverage:e["coverage"] as? Double ?? 0)
    if let range=e["interval"] as? [Double],range.count==2 {evidence.interval=range[0]...range[1]}
    evidence.confirmedSevereLowerBound=e["confirmedSevereLowerBound"] as? Double
    if let v=e["visibleSeam"] as? [String:Any] {evidence.visibleSeam = .init(compatible:v["compatible"] as? Bool ?? false,
      coverage:v["coverage"] as? Double ?? 0,maximumObservableError:v["maximumObservableError"] as? Double,
      reason:v["reason"] as? String ?? "missing",nativeSupportChecked:v["nativeSupportChecked"] as? Bool ?? false)}
    let observed=row["observedAt"] as! Double,expires=row["expiresAt"] as! Double
    if observed<=t && expires>=t {policy.update(evidence:evidence,sampleID:id,sampleEpoch:epoch,observedAt:observed,
      expiresAt:expires,at:t,sourceAvailable:source,currentEpoch:epoch,expectedInterval:5/60)}
    last=id
   }
   let valid=row["textureValid"] as! Bool
   ready.update(ready:valid,at:t)
   let q=policy.opacity(at:t),effective=max(q,ready.opacity(at:t))
   qualities.append(q);effects.append(effective)
   if effective<0.999 {visible += 1};if effective<0.001 {clear += 1}
   if !valid {invalid += 1;if effective<0.999 {invalidShown += 1}}
   if t >= 1 && valid {warmedValid += 1;if effective<0.001 {warmedClear += 1}}
  }
        let end = (document["rows"] as! [[String: Any]]).last!["time"] as! Double
        return .init(warmedValid: warmedValid, warmedClear: warmedClear, invalidShown: invalidShown, policy: policy, end: end)
    }
}

struct PhoneTimingTests {
    @Test func recordedPhoneSchedule_doesNotStarveRecovery() throws {
        let result = try PhoneTimingObservation.result.get()
        #expect(result.warmedValid > 90)
        #expect(result.warmedClear == result.warmedValid)
    }
    @Test func invalidTexture_isNeverRevealed() throws {
        #expect(try PhoneTimingObservation.result.get().invalidShown == 0)
    }
    @Test func rememberedRecovery_doesNotExtendCertificate() throws {
        let result = try PhoneTimingObservation.result.get()
        var policy = result.policy
        let deadline = policy.certificateDeadline
        policy.tick(at: result.end + 0.3, sourceAvailable: true, epoch: 2)
        #expect(policy.latched)
        #expect(policy.opacity(at: result.end + 0.3) == 1)
        #expect(policy.certificateDeadline == deadline)
    }
    @Test func missingResource_masksImmediately() {
        var readiness = PeripheralReadiness()
        readiness.update(ready: true, at: 0); readiness.update(ready: false, at: 0.5)
        #expect(readiness.opacity(at: 0.5) == 1)
    }
    @Test func briefUploadGap_preservesReadiness() {
        var readiness = PeripheralReadiness()
        readiness.update(ready: true, at: 0); readiness.update(ready: false, at: 0.5)
        readiness.update(ready: true, at: 0.55)
        #expect(readiness.opacity(at: 0.55) == 0)
    }
    @Test func longResourceOutage_restartsReadiness() {
        var readiness = PeripheralReadiness()
        readiness.update(ready: true, at: 0); readiness.update(ready: false, at: 0.5)
        readiness.update(ready: true, at: 0.55); readiness.update(ready: false, at: 0.6)
        readiness.update(ready: true, at: 0.9)
        #expect(readiness.opacity(at: 0.9) == 1)
    }
}
