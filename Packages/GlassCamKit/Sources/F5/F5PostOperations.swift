import Foundation

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
