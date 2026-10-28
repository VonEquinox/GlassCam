import Peripheral
import Foundation

/// Production display policy driven at camera-analysis cadence. These are
/// controlled evidence changes, not captured phone motion or optical truth.
@main
struct PeripheralTransitionReplay {
    static func main() throws {
        let clear=PeripheralPaneAssessment(error:0,supportFraction:1,reason:"checked-small-displacement")
        let bad=PeripheralPaneAssessment(error:0.14,supportFraction:1,reason:"checked-large-displacement")
        let partial=PeripheralPaneAssessment(error:0.06,supportFraction:1,reason:"persistent-medium-displacement")
        let unknown=PeripheralPaneAssessment()
        var output:[[String:Any]]=[]
        for name in ["sustained-bad","one-spike","alternating-after-bad","bad-unknown","recovery","partial-recovery"] {
            var policy=PeripheralPreviewPolicy(),trace:[[String:Any]]=[]
            for frame in 0...480 {
                let time=Double(frame)/60
                let input:PeripheralPaneAssessment
                if time<2 {input=clear}
                else {
                    switch name {
                    case "sustained-bad":input=bad
                    case "one-spike":input=frame<125 ? bad:clear
                    case "alternating-after-bad":input=time<3 ? bad:((frame/5)%2==0 ? clear:bad)
                    case "bad-unknown":input=time<3 || (frame/5)%2==0 ? bad:unknown
                    case "recovery":input=time<4 ? bad:clear
                    default:input=time<4 ? partial:clear
                    }
                }
                if frame%5==0 {policy.observe([input,input,clear,clear],at:time,tolerance:1)}
                let opacity=policy.update(at:time,ready:true,tolerance:1)
                trace.append(["time":time,"opacity":Array(opacity.prefix(2)),"input":input.reason])
            }
            let afterBad=trace.filter {($0["time"] as! Double)>=2}
            let firstBlack=afterBad.first {($0["opacity"] as! [Double])[0]>=0.95}?["time"] as? Double
            let afterRecovery=trace.filter {($0["time"] as! Double)>=4}
            let firstClear=afterRecovery.first {($0["opacity"] as! [Double])[0]<=0.05}?["time"] as? Double
            let fluctuating=trace.filter {($0["time"] as! Double)>=3.5}.map {($0["opacity"] as! [Double])[0]}
            let row:[String:Any]=["scenario":name,"firstBadTo95PercentSeconds":firstBlack.map {$0-2} ?? -1,
                "recoveryTo5PercentSeconds":firstClear.map {$0-4} ?? -1,
                "after3_5SecondsOpacityRange":[fluctuating.min()!,fluctuating.max()!],"trace":trace]
            output.append(row)
            print(name,"badTo95",firstBlack.map {$0-2} ?? -1,"clearTo5",firstClear.map {$0-4} ?? -1,
                "lateRange",fluctuating.min()!,fluctuating.max()!)
        }
        try PeripheralRecordJSON.data(["scope":"Synthetic evidence transitions through the actual Swift policy at 12 Hz analysis and 60 Hz drawing", "scenarios":output])
            .write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    }
}
