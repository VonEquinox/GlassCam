import Foundation
@main struct PeripheralPhoneTimingChecks {
 static func main() throws {
  let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
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
  precondition(warmedValid>90 && warmedClear==warmedValid,"Real phone observations passed, but recovery still starved")
  precondition(invalidShown==0,"Recovery revealed an invalid or expired GPU resource")
  let deadline=policy.certificateDeadline
  let end=(document["rows"] as! [[String:Any]]).last!["time"] as! Double
  policy.tick(at:end+0.3,sourceAvailable:true,epoch:2)
  precondition(policy.latched && policy.opacity(at:end+0.3)==1 && policy.certificateDeadline==deadline,
      "Remembering recovery extended an old certificate")
  var transient=PeripheralReadiness()
  transient.update(ready:true,at:0);transient.update(ready:false,at:0.5)
  precondition(transient.opacity(at:0.5)==1,"A missing resource was not masked immediately")
  transient.update(ready:true,at:0.55)
  precondition(transient.opacity(at:0.55)==0,"One brief upload gap restarted the whole readiness fade")
  transient.update(ready:false,at:0.6);transient.update(ready:true,at:0.9)
  precondition(transient.opacity(at:0.9)==1,"A long resource outage retained startup readiness")
  let output:[String:Any] = ["frames":effects.count,"warmedValidFrames":warmedValid,"warmedClearFrames":warmedClear,"visibleFrames":visible,"fullyClearFrames":clear,"invalidResourceFrames":invalid,
   "invalidResourcesShown":invalidShown,"lastQualityOpacity":qualities.last!,"lastEffectiveOpacity":effects.last!,
   "qualityOpacities":qualities,"effectiveOpacities":effects]
  let result=try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys])
  if CommandLine.arguments.count>2 {try result.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))}
  print("frames=\(effects.count) visible=\(visible) clear=\(clear) invalidShown=\(invalidShown) final=\(effects.last!)")
 }
}
