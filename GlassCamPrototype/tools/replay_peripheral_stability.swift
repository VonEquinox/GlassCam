import Foundation
import CoreImage
import CoreVideo
import QuartzCore

/// Controlled common camera motion on recorded inputs, not a phone video.
/// Both images move by the same amount in the fixed-FOV display coordinates.
@main
struct PeripheralStabilityReplay {
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let output=URL(fileURLWithPath:CommandLine.arguments[2])
        let tolerance=Double(CommandLine.arguments[3]) ?? 1
        let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil)!
        var folders:[URL]=[]
        for case let url as URL in files where url.lastPathComponent=="manifest.json" { folders.append(url.deletingLastPathComponent()) }
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let context=CIContext(options:[.cacheIntermediates:false])
        func moved(_ source:CVPixelBuffer,dx:Double,dy:Double,angle:Double,ratio:Double)->CVPixelBuffer {
            let w=CVPixelBufferGetWidth(source),h=CVPixelBufferGetHeight(source)
            var pixel:CVPixelBuffer?
            precondition(CVPixelBufferCreate(kCFAllocatorDefault,w,h,kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixel)==kCVReturnSuccess)
            let affine=CGAffineTransform(translationX:-Double(w)/2,y:-Double(h)/2)
                .concatenating(CGAffineTransform(rotationAngle:angle * .pi/180))
                .concatenating(CGAffineTransform(translationX:Double(w)/2+dx*Double(w)/192/ratio,
                    y:Double(h)/2+dy*Double(w)/192/ratio))
            let bounds=CGRect(x:0,y:0,width:w,height:h)
            let image=CIImage(cvPixelBuffer:source).clampedToExtent().transformed(by:affine).cropped(to:bounds)
            context.render(image,to:pixel!,bounds:bounds,colorSpace:space)
            return pixel!
        }
        var scenes:[[String:Any]]=[]
        let motions:[(Double,Double,Double)]=[(0,0,0),(-0.5,0,0),(0.5,0,0),(-1,0,0),(1,0,0),
            (0,-0.5,0),(0,0.5,0),(0,-1,0),(0,1,0),(0,0,-0.15),(0,0,0.15),(0,0,-0.3),(0,0,0.3)]
        for folder in folders.sorted(by:{$0.path<$1.path}) {
            try autoreleasepool {
                let record=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("manifest.json"))) as! [String:Any]
                let roles=record["roles"] as! [String:String],pairs=record["pairs"] as! [String:[String:Any]]
                let input=pairs[roles["analysisPair"] ?? roles["tapPair"]!]!
                let center=try NativeFieldReplay.buffer(input["center"] as! [String:Any],root:folder)
                let outer=try NativeFieldReplay.buffer(input["outer"] as! [String:Any],root:folder)
                let ratio=(input["ratio"] as! NSNumber).floatValue
                let config=PeripheralFrameSource.Configuration(outputIndex:1,fieldOfViewRatio:ratio,epoch:1)
                let renderer=record["renderer"] as! [String:Any],photo=renderer["photoRect"] as! [Double],window=renderer["windowSize"] as! [Double]
                let bounds=CGRect(x:-photo[0]/photo[2],y:-photo[1]/photo[3],width:window[0]/photo[2],height:window[1]/photo[3])
                let seams=PeripheralSeams(photo:CGRect(x:photo[0],y:photo[1],width:photo[2],height:photo[3]),window:CGSize(width:window[0],height:window[1]))
                let worker=PeripheralAlignmentWorker()
                var rows:[[String:Any]]=[]
                var observations:[[PeripheralPaneAssessment]]=[]
                for (i,m) in motions.enumerated() {
                    let time=100+Double(i)/10
                    let c=moved(center,dx:m.0,dy:m.1,angle:m.2,ratio:1)
                    let o=moved(outer,dx:m.0,dy:m.1,angle:m.2,ratio:Double(ratio))
                    let pair=PeripheralFrameSource.Pair(center:c,outer:o,receipt:time,configuration:config,serial:UInt64(i+1),measuredFrameInterval:1/60)
                    guard let result=worker.analyze(pair,seams:seams,window:bounds,now:{time+0.01},tolerance:tolerance) else {fatalError("Controlled replay failed")}
                    let assessments=(0..<4).map {PeripheralPaneAssessment.measure(result,edge:$0)}
                    observations.append(assessments)
                    rows.append(["analysisPixelTranslation":[m.0,m.1],"rotationDegrees":m.2,
                        "shade":assessments.map {$0.darkness(tolerance:tolerance)},
                        "assessment":assessments.map { ["error":$0.error ?? -1,"support":$0.supportFraction,
                            "mismatch":$0.mismatchFraction,"missing":$0.missingStructureFraction,
                            "localizedError":$0.localizedError ?? -1,"deformation":$0.deformation ?? -1,"reason":$0.reason] },
                        "nativeTiles":result.nativeSeam?.diagnostics ?? []])
                }
                var policy=PeripheralPreviewPolicy(),trace:[[String:Any]]=[]
                for frame in 0..<60*12 {
                    let time=Double(frame)/60
                    // Warm the first pose, then hold each tiny pose for half
                    // a second: these are real changes in no underlying depth.
                    let pose=frame<120 ? 0:((frame-120)/30)%observations.count
                    if frame%5==0 {policy.observe(observations[pose],at:time,tolerance:tolerance)}
                    let alpha=policy.update(at:time,ready:true,tolerance:tolerance)
                    if frame>=120 {trace.append(["time":time,"pose":pose,"opacity":Array(alpha.prefix(2))])}
                }
                let opacities=trace.flatMap {$0["opacity"] as! [Double]}
                scenes.append(["id":folder.lastPathComponent,"cases":rows,"temporalTrace":trace,
                    "warmedOpacityRange":[opacities.min()!,opacities.max()!]])
            }
        }
        let report:[String:Any]=["scope":"Mac synthetic common-motion perturbations of original saved pixels; no phone motion or optical ground truth", "tolerance":tolerance,"scenes":scenes]
        try PeripheralRecordJSON.data(report).write(to:output)
        for scene in scenes {
            let rows=scene["cases"] as! [[String:Any]]
            print(scene["id"]!,rows.map {($0["shade"] as! [Double]).prefix(2).map {String(format:"%.3f",$0)}.joined(separator:",")}.joined(separator:" | "))
        }
    }
}
