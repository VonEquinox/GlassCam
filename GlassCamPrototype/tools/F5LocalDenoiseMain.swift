import Foundation

@main struct F5LocalDenoiseMain {
    static func readHalo(_ file:FileHandle,into buffer:F5MetalBuffer,tile:F5LocalDenoise.Tile,width:Int,height:Int) throws {
        func mirror(_ i:Int,_ length:Int)->Int {let p=2*(length-1),r=((i%p)+p)%p;return r<length ? r:p-r}
        let xs=(0..<tile.inputWidth).map{mirror(tile.x-tile.padding+$0,width)}
        let first=xs.min()!,last=xs.max()!,bytes=(last-first+1)*16
        for row in 0..<tile.inputHeight {
            let y=mirror(tile.y-tile.padding+row,height)
            try file.seek(toOffset:UInt64((y*width+first)*16))
            guard let data=try file.read(upToCount:bytes),data.count==bytes else {throw F5Failure(.damagedBundle,"Truncated local-filter input.")}
            data.withUnsafeBytes {source in
                for x in xs.indices {buffer.metal.contents().advanced(by:(row*tile.inputWidth+x)*16).copyMemory(from:source.baseAddress!.advanced(by:(xs[x]-first)*16),byteCount:16)}
            }
        }
    }
    static func main() throws {
        let args=CommandLine.arguments
        guard (args.count==8 || args.count==9 && args[8]=="stream"),let width=Int(args[1]),let height=Int(args[2]),let tile=Int(args[6]),
              width>1,height>1,width<=32768,height<=32768 else {
            throw F5Failure(.damagedBundle,"Usage: f5-local-denoise width height rgba.f32 variance.f32 output.f32 tileSize shader.metal [stream]")
        }
        let streaming=args.count==9
        let device=try F5MetalDevice(maximumBytes:streaming ? 64*1024*1024:1_288_490_188,shaderURL:URL(fileURLWithPath:args[7]),isCancelled:{false})
        let start=ProcessInfo.processInfo.systemUptime
        if streaming {
            let image=try FileHandle(forReadingFrom:URL(fileURLWithPath:args[3])),variance=try FileHandle(forReadingFrom:URL(fileURLWithPath:args[4]))
            defer {try? image.close();try? variance.close()}
            guard FileManager.default.createFile(atPath:args[5],contents:nil) else {throw CocoaError(.fileWriteUnknown)}
            let output=try FileHandle(forWritingTo:URL(fileURLWithPath:args[5]));defer {try? output.close()}
            try output.truncate(atOffset:UInt64(width*height*16))
            try F5LocalDenoise.applyTiles(width:width,height:height,device:device,tileSize:tile,supply:{region,localImage,localVariance,_ in
                try readHalo(image,into:localImage,tile:region,width:width,height:height)
                try readHalo(variance,into:localVariance,tile:region,width:width,height:height)
            },consume:{region,localOutput in
                for row in 0..<region.height {
                    try output.seek(toOffset:UInt64(((region.y+row)*width+region.x)*16))
                    try output.write(contentsOf:Data(bytesNoCopy:localOutput.metal.contents().advanced(by:row*region.width*16),count:region.width*16,deallocator:.none))
                }
            })
            try output.synchronize()
        } else {
            let image=try device.upload(Data(contentsOf:URL(fileURLWithPath:args[3])),label:"Diagnostic native RGB")
            let variance=try device.upload(Data(contentsOf:URL(fileURLWithPath:args[4])),label:"Declared diagnostic noise variance")
            let output=try F5LocalDenoise.apply(image:image,variance:variance,width:width,height:height,device:device,tileSize:tile)
            try Data(bytes:output.metal.contents(),count:width*height*16).write(to:URL(fileURLWithPath:args[5]),options:.atomic)
        }
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        let report:[String:Any]=["seconds":elapsed,"peak_allocated_bytes":device.peakBytes,"width":width,"height":height,
            "tile":tile,"streaming":streaming,"timing_includes_file_io":true,"camera_used":false,"qualified":false]
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),encoding:.utf8)!)
    }
}
