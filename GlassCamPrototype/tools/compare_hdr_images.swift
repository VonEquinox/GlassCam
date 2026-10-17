import Foundation
import CoreImage
import ImageIO

@main enum CompareHDRImages {
    static func main() throws {
        let args=CommandLine.arguments
        guard args.count==4,
              let a=CIImage(contentsOf:URL(fileURLWithPath:args[1]),options:[.applyOrientationProperty:true]),
              let b=CIImage(contentsOf:URL(fileURLWithPath:args[2]),options:[.applyOrientationProperty:true]),
              a.extent==b.extent,
              let pq=CGColorSpace(name:CGColorSpace.itur_2100_PQ),
              let linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB),
              let state=hdr_metric_create() else { throw NSError(domain:"HDRMetric",code:1) }
        defer { hdr_metric_destroy(state) }
        let width=Int(a.extent.width),height=Int(a.extent.height)
        let context=CIContext(options:[.workingColorSpace:linear,.workingFormat:CIFormat.RGBAf.rawValue])
        for y in stride(from:0,to:height,by:64) {
            let rows=min(64,height-y),bounds=CGRect(x:0,y:y,width:width,height:rows)
            var first=[Float](repeating:0,count:width*rows*4),second=first
            first.withUnsafeMutableBytes { context.render(a,toBitmap:$0.baseAddress!,rowBytes:width*16,bounds:bounds,format:.RGBAf,colorSpace:pq) }
            second.withUnsafeMutableBytes { context.render(b,toBitmap:$0.baseAddress!,rowBytes:width*16,bounds:bounds,format:.RGBAf,colorSpace:pq) }
            let result=first.withUnsafeBufferPointer { x in second.withUnsafeBufferPointer { z in hdr_metric_add(state,x.baseAddress,z.baseAddress,width*rows) } }
            guard result==0 else { throw NSError(domain:"HDRMetric",code:2) }
        }
        var values=[Double](repeating:0,count:12)
        let result=values.withUnsafeMutableBufferPointer { hdr_metric_finish(state,$0.baseAddress,$0.count) }
        guard result==0 else { throw NSError(domain:"HDRMetric",code:3) }
        var report:[String:Any]=Dictionary(uniqueKeysWithValues:zip(
            ["pixels","different_rgb_pixels","mean_deltaEITP","p95_deltaEITP","p99_deltaEITP","maximum_deltaEITP",
             "reference_peak_rgb_nits","actual_peak_rgb_nits","additional_black_channels","additional_white_channels","worst_sequence_index","outside_pq_channels"],values))
        report["reference"]=args[1];report["actual"]=args[2];report["width"]=width;report["height"]=height
        report["metric_domain"]="Both files decoded through the same Core Image context into BT.2020/PQ RGB; PQ EOTF -> BT.2100 LMS -> PQ -> ITP, ITU-R BT.2124 scale 720. Exact percentiles include unchanged pixels."
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[3]),options:.atomic)
        print("HDR-METRIC \(width)x\(height) mean=\(values[2]) p99=\(values[4]) max=\(values[5])")
    }
}
