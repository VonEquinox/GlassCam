import Foundation
import Metal

/// Bounded local-transform experiment. Its supplied variance must describe the
/// input image; this class does not certify a variance model or a device profile.
enum F5LocalDenoise {
    struct Grid {
        var image: SIMD4<UInt32> // width, height, patch size, stride
        var tile: SIMD4<UInt32>
        var patches: SIMD4<UInt32> // columns, rows, padding, reserved
        var settings: SIMD4<Float> // threshold in sigma units
    }
    struct Tile {
        let x:Int,y:Int,width:Int,height:Int,padding:Int
        var inputWidth:Int {width+2*padding}
        var inputHeight:Int {height+2*padding}
    }
    /// The supplier fills a reflected halo around this tile. Only the consumer
    /// owns the resulting pixels; both buffers are reused on the next tile.
    /// This permits generating input from a spline or reading a raster on disk
    /// without retaining full-sized input, variance, and output RGB buffers.
    static func applyTiles(width:Int,height:Int,device:F5MetalDevice,tileSize:Int=256,threshold:Float=2.7,
                           supply:(Tile,F5MetalBuffer,F5MetalBuffer,MTLCommandBuffer)throws->Void,
                           consume:(Tile,F5MetalBuffer)throws->Void) throws {
        let patch=32,stride=8
        guard width>1,height>1,width<=32768,height<=32768,
              tileSize>=32,tileSize<=256,tileSize%stride==0,threshold.isFinite,threshold>=0 else {
            throw F5Failure(.profileMismatch,"Invalid local-transform image or tile shape.")
        }
        var basis=[Float](repeating:0,count:patch*patch)
        for k in 0..<patch {for x in 0..<patch {
            basis[k*patch+x]=Float(sqrt((k==0 ? 1.0:2.0)/Double(patch))*cos(Double.pi*Double(2*x+1)*Double(k)/Double(2*patch)))
        }}
        let transform=try device.upload(basis,label:"F5 fixed orthogonal cosine basis")
        let maxWidth=min(tileSize,width),maxHeight=min(tileSize,height)
        let maxColumns=(maxWidth+patch)/stride+1,maxRows=(maxHeight+patch)/stride+1
        let first=try device.allocate(maxColumns*maxRows*patch*patch*16,label:"F5 local frequency rows")
        let second=try device.allocate(first.metal.length,label:"F5 local frequency columns")
        let noise=try device.allocate(maxColumns*maxRows*16,label:"F5 patch noise variance")
        let image=try device.allocate((maxWidth+2*patch)*(maxHeight+2*patch)*16,label:"F5 local input with halo")
        let variance=try device.allocate(image.metal.length,label:"F5 local variance with halo")
        let output=try device.allocate(maxWidth*maxHeight*16,label:"F5 local output tile")
        for y in Swift.stride(from:0,to:height,by:tileSize) {for x in Swift.stride(from:0,to:width,by:tileSize) {try autoreleasepool {
            let tile=Tile(x:x,y:y,width:min(tileSize,width-x),height:min(tileSize,height-y),padding:patch)
            let columns=(tile.width+patch)/stride+1,rows=(tile.height+patch)/stride+1
            let g=Grid(image:SIMD4(UInt32(tile.inputWidth),UInt32(tile.inputHeight),UInt32(patch),UInt32(stride)),
                tile:SIMD4(UInt32(patch),UInt32(patch),UInt32(tile.width),UInt32(tile.height)),
                patches:SIMD4(UInt32(columns),UInt32(rows),UInt32(patch),0),settings:SIMD4(threshold,1,0,0))
            let count=columns*rows*patch*patch
            try device.run {command in
                try supply(tile,image,variance,command)
                try device.encode("f5_dct_noise",count:columns*rows,buffers:[variance.metal,noise.metal],command:command) {F5MetalDevice.value(g,at:2,encoder:$0)}
                try device.encode("f5_dct_forward_rows",count:count,buffers:[image.metal,transform.metal,first.metal],command:command) {F5MetalDevice.value(g,at:3,encoder:$0)}
                try device.encode("f5_dct_forward_columns",count:count,buffers:[first.metal,transform.metal,noise.metal,second.metal],command:command) {F5MetalDevice.value(g,at:4,encoder:$0)}
                try device.encode("f5_dct_inverse_columns",count:count,buffers:[second.metal,transform.metal,first.metal],command:command) {F5MetalDevice.value(g,at:3,encoder:$0)}
                try device.encode("f5_dct_inverse_rows",count:count,buffers:[first.metal,transform.metal,second.metal],command:command) {F5MetalDevice.value(g,at:3,encoder:$0)}
                try device.encode("f5_dct_aggregate",count:tile.width*tile.height,buffers:[second.metal,output.metal],command:command) {F5MetalDevice.value(g,at:2,encoder:$0)}
            }
            try consume(tile,output)
        }}}
    }
    static func apply(image: F5MetalBuffer, variance: F5MetalBuffer, width: Int, height: Int,
                      device: F5MetalDevice, tileSize: Int = 256, threshold: Float = 2.7) throws -> F5MetalBuffer {
        guard width>1,height>1,width<=32768,height<=32768,
              image.metal.length>=width*height*16,variance.metal.length>=width*height*16 else {
            throw F5Failure(.profileMismatch,"Invalid local-transform image buffers.")
        }
        let output=try device.allocate(width*height*16,label:"F5 frequency-filtered camera RGB")
        try applyTiles(width:width,height:height,device:device,tileSize:tileSize,threshold:threshold,supply:{tile,localImage,localVariance,command in
            let shape=SIMD4<UInt32>(UInt32(width),UInt32(height),UInt32(tile.inputWidth),UInt32(tile.inputHeight))
            let origin=SIMD2<Int32>(Int32(tile.x-tile.padding),Int32(tile.y-tile.padding))
            try device.encode("f5_dct_load_tile",count:tile.inputWidth*tile.inputHeight,
                buffers:[image.metal,variance.metal,localImage.metal,localVariance.metal],command:command) {e in
                F5MetalDevice.value(shape,at:4,encoder:e);F5MetalDevice.value(origin,at:5,encoder:e)
            }
        },consume:{tile,localOutput in
            let shape=SIMD4<UInt32>(UInt32(width),UInt32(height),UInt32(tile.width),UInt32(tile.height))
            let origin=SIMD2<UInt32>(UInt32(tile.x),UInt32(tile.y))
            try device.run {command in
                try device.encode("f5_dct_store_tile",count:tile.width*tile.height,buffers:[localOutput.metal,output.metal],command:command) {e in
                    F5MetalDevice.value(shape,at:2,encoder:e);F5MetalDevice.value(origin,at:3,encoder:e)
                }
            }
        })
        return output
    }
}
