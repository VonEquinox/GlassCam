import ImagingCore
import Capture
import Foundation
import Metal

struct F5GPUOutput {
    let shape: SIMD4<UInt32>, crop: SIMD4<Float>, options: SIMD4<UInt32>
}

enum F5PostGeometry {
    static func record(_ opcode: F5DNGMetadata.Opcode, metadata: F5DNGMetadata) throws -> [SIMD4<Float>] {
            guard opcode.list == 3, opcode.id == 1 else { throw F5Failure(.unsupportedOpcode,"Invalid post-reconstruction geometry operation.") }
            let data=F5Bytes(opcode.parameters,little:false),count=Int(try data.u32(0))
            guard count==1 || count==3, data.data.count==4+count*48+16 else {throw F5Failure(.unsupportedOpcode,"Invalid rectilinear warp layout.")}
            var radial:[SIMD4<Float>]=[],tangential:[SIMD4<Float>]=[]
            for c in 0..<3 {
                let offset=4+min(c,count-1)*48,values=try (0..<6).map{try data.f64(offset+$0*8)}
                guard values.allSatisfy(\.isFinite) else {throw F5Failure(.unsupportedOpcode,"Non-finite lens warp.")}
                // Sufficient monotonicity bound for the supported rectilinear
                // domain. More general maps require a new audited decoder.
                func minimum(_ a:Double,_ b:Double,_ c:Double,_ d:Double)->Double {
                    var positions=[0.0,1.0]
                    if abs(d)>1e-14 {
                        let discriminant=4*c*c-12*d*b
                        if discriminant>=0 {positions += [(-2*c-sqrt(discriminant))/(6*d),(-2*c+sqrt(discriminant))/(6*d)].filter{(0...1).contains($0)}}
                    } else if abs(c)>1e-14 {let p = -b/(2*c);if (0...1).contains(p){positions.append(p)}}
                    return positions.map{a+$0*(b+$0*(c+$0*d))}.min()!
                }
                let smallest=min(minimum(values[0],values[1],values[2],values[3]),minimum(values[0],3*values[1],5*values[2],7*values[3]))
                guard smallest>8*(abs(values[4])+abs(values[5])) else {throw F5Failure(.unsupportedOpcode,"The rectilinear warp is outside the certified invertible domain.")}
                radial.append(SIMD4(Float(values[0]),Float(values[1]),Float(values[2]),Float(values[3])))
                tangential.append(SIMD4(Float(values[4]),Float(values[5]),0,0))
            }
            let cx=try data.f64(4+count*48),cy=try data.f64(12+count*48)
            guard cx.isFinite,cy.isFinite,(0...1).contains(cx),(0...1).contains(cy) else {throw F5Failure(.unsupportedOpcode,"Invalid lens-warp center.")}
            return radial+tangential+[SIMD4(Float(cx),Float(cy),Float(metadata.activeArea.width),Float(metadata.activeArea.height)),SIMD4(Float(bitPattern:1),0,0,0)]
    }
}

enum F5PostOperations {
    struct Table {
        let data: [SIMD4<Float>], ids: [UInt32]
        var warpCount: Int { ids.filter { $0 == 1 }.count }
        var gainCount: Int { ids.filter { $0 == 9 }.count }
    }
    static func records(_ metadata: F5DNGMetadata) throws -> Table {
        try metadata.auditOpcodes()
        let operations = metadata.opcodes.filter { $0.list == 3 && $0.action != "optional_skipped" }
        guard operations.count <= 8 else { throw F5Failure(.unsupportedOpcode,"Excessive post-reconstruction operations.") }
        var data = [SIMD4<Float>](repeating: .zero, count: operations.count * 8)
        for (index, opcode) in operations.enumerated() {
            let record: [SIMD4<Float>]
            if opcode.id == 1 { record = try F5PostGeometry.record(opcode, metadata: metadata) }
            else if opcode.id == 9 {
                let g = try F5DNGGainMap(opcode, width: metadata.activeArea.width, height: metadata.activeArea.height, imagePlanes: 3)
                let offset = UInt32(data.count * 4)
                for start in stride(from: 0, to: g.values.count, by: 4) {
                    var values = SIMD4<Float>(repeating: 0)
                    for lane in 0..<min(4, g.values.count - start) { values[lane] = Float(g.values[start + lane]) }
                    data.append(values)
                }
                record = [SIMD4(Float(g.area.left),Float(g.area.top),Float(g.area.right),Float(g.area.bottom)),
                    SIMD4(Float(g.firstPlane),Float(g.planes),Float(g.mapPlanes),Float(g.rows)),
                    SIMD4(Float(g.columns),Float(g.width),Float(g.height),0),
                    SIMD4(Float(g.originX),Float(g.originY),Float(g.spacingX),Float(g.spacingY)),
                    SIMD4(Float(bitPattern:offset),0,0,0),.zero,.zero,SIMD4(Float(bitPattern:9),0,0,0)]
            } else { throw F5Failure(.unsupportedOpcode,"Unimplemented post-reconstruction operation.") }
            data.replaceSubrange(index*8..<(index+1)*8, with: record)
        }
        return .init(data: data, ids: operations.map(\.id))
    }
}

extension F5MetalLevel {
    struct LinearOutput {let file:ExportRasterFile,width:Int,height:Int}
    func writeLinearOutput(native:F5MetalLevel,reference:F5FrameRecord,color:F5ColorTransformRecord,
                           quality:[F5QualityReport.Tile],directory:URL) throws -> LinearOutput {
        let metadata=reference.metadata
        let outputWidth=Int(floor(metadata.cropSize[0]*2)),outputHeight=Int(floor(metadata.cropSize[1]*2))
        guard outputWidth>0,outputHeight>0,outputWidth<=32768,outputHeight<=32768 else {throw F5Failure(.nonfinite,"Invalid F5 output dimensions.")}
        let capacity=try directory.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        let required=Int64(outputWidth)*Int64(outputHeight)*32+128*1024*1024
        if let capacity,capacity<required {throw CocoaError(.fileWriteOutOfSpace)}
        let classes=quality.map{tile->UInt32 in
            switch tile.support {case .fullSR:return 0;case .nativeFusion:return 1;case .referenceOnly:return 2;case .highlightMissing:return 3;case .invalid:return 4}
        }
        let map=try device.upload(classes,label:"F5 final support map"),post=try F5PostOperations.records(metadata)
        let warps=try device.upload(post.data.isEmpty ? [.zero] : post.data,label:"F5 ordered post-reconstruction operations")
        let rows=64,strip=try device.allocate(outputWidth*rows*16,label:"F5 bounded output strip")
        let raster=try ExportRasterFile()
        let pending=directory.appendingPathComponent("linear-camera-writing-\(UUID().uuidString).f32")
        guard FileManager.default.createFile(atPath:pending.path,contents:nil,attributes:ImageFileProtection.attributes) else {throw CocoaError(.fileWriteUnknown)}
        let cameraFile=try FileHandle(forWritingTo:pending)
        defer {try? cameraFile.close()}
        let matrix=color.cameraToLinearSRGB.values
        let colorRows=[SIMD4<Float>(Float(matrix[0]),Float(matrix[1]),Float(matrix[2]),0),SIMD4(Float(matrix[3]),Float(matrix[4]),Float(matrix[5]),0),SIMD4(Float(matrix[6]),Float(matrix[7]),Float(matrix[8]),0)]
        var g=uniforms;g.step = .zero
        for y in stride(from:0,to:outputHeight,by:rows) {
            let count=min(rows,outputHeight-y),pixels=outputWidth*count
            let output=F5GPUOutput(shape:SIMD4(UInt32(outputWidth),UInt32(outputHeight),UInt32(y),UInt32(count)),
                crop:SIMD4(Float(metadata.cropOrigin[0]),Float(metadata.cropOrigin[1]),Float(metadata.cropSize[0]),Float(metadata.cropSize[1])),
                options:SIMD4(UInt32(post.ids.count),2,0,0))
            try device.run { command in
                try device.clear(scratch.failure.metal,command:command)
                try device.encode("f5_output_strip",count:pixels,buffers:[coefficients.metal,native.coefficients.metal,map.metal,warps.metal,strip.metal,scratch.failure.metal],command:command) { e in
                    F5MetalDevice.value(g,at:6,encoder:e);F5MetalDevice.value(output,at:7,encoder:e)
                }
            }
            guard scratch.failure.metal.contents().load(as:UInt32.self)==0 else {
                throw F5Failure(.nonfinite,"Final camera RGB or post-warp support failed validation. Inputs and the partial linear raster were retained.")
            }
            // Persist the actual scene-linear camera image before color/WB.
            try cameraFile.write(contentsOf:Data(bytesNoCopy:strip.metal.contents(),count:pixels*16,deallocator:.none))
            try device.run { command in
                try device.encode("f5_color_transform",count:pixels,buffers:[strip.metal],command:command) { e in
                    colorRows.withUnsafeBytes{e.setBytes($0.baseAddress!,length:$0.count,index:1)}
                    F5MetalDevice.value(UInt32(pixels),at:2,encoder:e);e.setBuffer(scratch.failure.metal,offset:0,index:3)
                }
            }
            guard scratch.failure.metal.contents().load(as:UInt32.self)==0 else {throw F5Failure(.colorTransformInvalid,"Non-finite camera-to-sRGB result.")}
            try raster.handle.write(contentsOf:Data(bytesNoCopy:strip.metal.contents(),count:pixels*16,deallocator:.none))
        }
        try cameraFile.synchronize()
        let final=directory.appendingPathComponent("linear-camera.f32")
        if FileManager.default.fileExists(atPath:final.path) {_ = try FileManager.default.replaceItemAt(final,withItemAt:pending)}
        else {try FileManager.default.moveItem(at:pending,to:final)}
        let descriptor:[String:Any] = ["revision":F5Version.decoder,"semantics":"camera_linear_no_wb","width":outputWidth,"height":outputHeight,
            "channels":4,"alpha":1,"layout":"interleaved_top_to_bottom","component":"float32","byte_order":"little",
            "row_bytes":outputWidth*16,"orientation":reference.raster.orientation,"reference_frame_id":reference.id,
            "profile_sha256":color.profileSHA256,"white_scale":color.inputScale,"sha256":try F5Hash.file(final),
            "post_reconstruction_warp_count":post.warpCount,"post_reconstruction_gain_map_count":post.gainCount,
            "post_opcode_ids":post.ids.map(Int.init),"opcode_range_policy":F5Version.opcodeRangePolicy,
            "default_crop_origin":metadata.cropOrigin,"output_scale":2]
        try CaptureJournal.writeProtected(JSONSerialization.data(withJSONObject:descriptor,options:[.sortedKeys]),to:directory.appendingPathComponent("linear-camera.json"))
        return .init(file:raster,width:outputWidth,height:outputHeight)
    }
}
