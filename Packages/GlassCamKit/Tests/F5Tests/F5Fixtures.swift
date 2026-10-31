@testable import F5
@testable import Capture
@testable import ImagingCore
import Foundation

enum F5Fixtures {
    struct Fixture {let source:F5BurstSource, profile:F5DeviceProfile, canonical:[F5CanonicalFrame]; let duplicateAppendResults: [Bool]; let repeatedSource: F5BurstSource}
    static func make(directory:URL,width:Int=8,height:Int=6,inputFrames:[[UInt16]]?=nil,policyOverride:F5Policy?=nil,
                     codeDivisor:Int=1,deliveredISOs:[UInt16]?=nil,additionalDNGTags:[Tag]=[],quality:CaptureQuality = .f5,purpose:String = "synthetic-test") throws -> Fixture {
        let frameCount = purpose == "probe" ? 11 : (quality.bayerFrameCount ?? 5)
        var policy=F5Policy();policy.blockSize=8;policy.maxCycles=5;policy.maxGeometryRounds=1
        policy.maximumProcessingSeconds=120;policy.standardizedGradientTolerance=0.03
        policy.minimumModeInformation=0.01;policy.maximumWarpJacobianDeviation=0.02
        if let policyOverride {policy=policyOverride}
        if let inputFrames {
            guard inputFrames.count==frameCount,inputFrames.allSatisfy({$0.count==width*height}) else {throw F5Failure(.damagedBundle,"Synthetic integer fixture dimensions disagree.")}
        }
        guard [1,4].contains(codeDivisor), deliveredISOs == nil || deliveredISOs?.count == frameCount else {
            throw F5Failure(.damagedBundle,"Invalid synthetic capture parameters.")
        }
        let nativeBlack = codeDivisor == 4 ? 2112.0 : 512.0
        let whiteScale = codeDivisor == 4 ? 3567.0 : 65023.0
        let nativeMaximum = codeDivisor == 4 ? 16383 : 65535
        let nativeWhite = codeDivisor == 4 ? 16380 : 65535
        let profile=F5DeviceProfile(version:"1.0",id:"SYNTHETIC_UNIT_TEST_ONLY",hardwareModel:"SYNTHETIC_NOT_IPHONE",osBuild:"not-applicable",
            physicalCameraID:"SYNTHETIC_CAMERA_NOT_IPHONE",physicalCameraType:"main",formatSignature:"synthetic-format-v1",rawFourCC:0x62676734,
            width:width+2,height:height+2,cfa:[.r,.g1,.g2,.b],isoRange:[100,100],focusRange:[0.5,0.5],aperture:1.6,oisPolicy:"unavailable",
            decoderRevision:F5Version.decoder,buildRevision:F5Version.build,qualification:.synthetic,gateEvidence:[:],
            calibrationManifestSHA256:String(repeating:"0",count:64),colorValidationSHA256:String(repeating:"0",count:64),
            whiteScale:whiteScale,noise:Array(repeating:.init(kappa:0.01,readSigma:0.015,lowerThreshold:-nativeBlack/Double(codeDivisor)/whiteScale,upperThreshold:1,
                lowerCensorCode:0,upperCensorCode:nativeWhite,gain:1),count:4),blackResidualByPhase:[0,0,0,0],handheldMaxExposure:nil,
            likelihood:.init(revision:"f5-pg-v1",table:nil,nllMaximumError:0,standardizedScoreMaximumError:0,gaussianMinimumElectrons:nil,exactMaximumElectrons:2000),policy:policy,
            rawCodeRange:[0,nativeMaximum],targetDeviceName:"SYNTHETIC_NOT_IPHONE",
            bufferCodeMapping:.init(divisor:codeDivisor,dngStage1Rounding:"floor",evidenceSHA256:F5Hash.data(Data("synthetic-fixture-only".utf8))))
        let snapshot=CaptureSnapshot(recipe:.standard,output:.camera(48),quality:quality)
        let transaction=try F5BurstTransaction(snapshot:snapshot,purpose:purpose,root:directory)
        let groups = try F5ExposurePlan.groups(maxBracketCount: 3,frameCount: frameCount)
        for (i,group) in groups.enumerated() { try transaction.register(requestID: Int64(101+i),indices: group) }
        let descriptor=F5RasterDescriptor(width:width+2,height:height+2,rowBytes:(width+2)*2+4,byteOrder:.little,
            activeArea:.init(top:1,left:1,bottom:height+1,right:width+1),cfa:[.r,.g1,.g2,.b],orientation:6,bitsPerSample:16)
        var records:[F5FrameRecord]=[],raws:[Data]=[]
        var duplicateAppendResults = [Bool]()
        for frame in 0..<frameCount {
            let exposure=frameCount == 5 && frame==2 ? 0.001 : 0.008,ratio=exposure/0.008
            var dense:[UInt16]=[],mosaic=Data()
            for y in 0..<descriptor.height {
                for x in 0..<descriptor.width {
                    let color=descriptor.phase(x:x-1,y:y-1).color
                    let signal=0.22+0.025*Double(color)+0.018*sin(Double(x)*0.27+Double(y)*0.33+Double(color))
                    let code=inputFrames?[frame][min(height-1,max(0,y-1))*width+min(width-1,max(0,x-1))] ?? UInt16(max(0,min(nativeMaximum,Int((nativeBlack+Double(codeDivisor)*whiteScale*ratio*signal).rounded()))))
                    dense.append(code/UInt16(codeDivisor));append(code,to:&mosaic)
                }
                mosaic.append(contentsOf:[0xAB,0xCD,0xEF,0x12])
            }
            let dng=try makeDNG(width:descriptor.width,height:descriptor.height,active:descriptor.activeArea,pixels:dense,exposure:exposure,
                overrides:[rationals(50714,Array(repeating:nativeBlack/Double(codeDivisor),count:4)),longs(50717,[UInt32(nativeWhite/codeDivisor)])]+additionalDNGTags,iso:deliveredISOs?[frame] ?? 100)
            let metadata=try F5DNGMetadata.read(dng)
            let record=F5FrameRecord(id:"synthetic-\(frame)",requestID:Int64(101+frame/3),burstIndex:frame,sequenceCount:frame%3+1,
                role:frameCount == 5 && frame==2 ? .short : .main,physicalCameraID:profile.physicalCameraID,formatSignature:profile.formatSignature,rawFourCC:profile.rawFourCC,
                dng:.init(path:"frame-\(frame).dng",sha256:F5Hash.data(dng),bytes:dng.count),mosaic:.init(path:"frame-\(frame).raw",sha256:F5Hash.data(mosaic),bytes:mosaic.count),raster:descriptor,
                requestedExposure:exposure,actualExposure:metadata.exposureTime!,actualISO:metadata.iso!,aperture:metadata.aperture!,focus:0.5,oisPolicy:"unavailable",
                timestamp:Double(frame)*0.035,callbackUptime:Double(frame)*0.035+0.2,clockID:"SYNTHETIC_CLOCK",rollingShutterLineTime:nil,metadata:metadata,requestedISO:100)
            try transaction.append(record,dng:dng,mosaic:mosaic)
            if frame==1 { duplicateAppendResults.append(try transaction.append(record,dng:dng,mosaic:mosaic)) }
            if groups[frame/3].last == frame {try transaction.finishRequest(Int64(101+frame/3),error:nil)}
            records.append(record);raws.append(mosaic)
        }
        let framing=CaptureFraming(cameraID:profile.physicalCameraID,lensName:"Main",nativePixelCount:width*height,deliveredWidth:width,deliveredHeight:height)
        let source=try transaction.commit(hardware:profile.hardwareModel,osBuild:profile.osBuild,synthetic:true,flags:[],profile:profile,framing:framing)
        let repeated=try transaction.commit(hardware:profile.hardwareModel,osBuild:profile.osBuild,synthetic:true,flags:[],profile:profile,framing:framing)
        let canonical=try zip(records,raws).map{try F5CanonicalFrame(record:$0,codes:$1,profile:profile,mainExposure:0.008)}
        return .init(source:source,profile:profile,canonical:canonical,duplicateAppendResults:duplicateAppendResults,repeatedSource:repeated)
    }
    struct Tag {var id:UInt16,type:UInt16,count:UInt32,bytes:Data}
    static func append<T:FixedWidthInteger>(_ value:T,to data:inout Data) {
        var value=value.littleEndian;withUnsafeBytes(of:&value){data.append(contentsOf:$0)}
    }
    static func shorts(_ id:Int,_ values:[UInt16])->Tag {var d=Data();values.forEach{append($0,to:&d)};return .init(id:UInt16(id),type:3,count:UInt32(values.count),bytes:d)}
    static func longs(_ id:Int,_ values:[UInt32])->Tag {var d=Data();values.forEach{append($0,to:&d)};return .init(id:UInt16(id),type:4,count:UInt32(values.count),bytes:d)}
    static func bytes(_ id:Int,_ values:[UInt8])->Tag {.init(id:UInt16(id),type:1,count:UInt32(values.count),bytes:Data(values))}
    static func text(_ id:Int,_ value:String)->Tag {let d=Data((value+"\0").utf8);return .init(id:UInt16(id),type:2,count:UInt32(d.count),bytes:d)}
    static func rationals(_ id:Int,_ values:[Double],signed:Bool=false)->Tag {
        var d=Data();for value in values {append(Int32((value*1_000_000).rounded()),to:&d);append(Int32(1_000_000),to:&d)}
        return .init(id:UInt16(id),type:signed ? 10 : 5,count:UInt32(values.count),bytes:d)
    }
    static func makeDNG(width:Int,height:Int,active:F5Area,pixels:[UInt16],exposure:Double,overrides:[Tag]=[],bigEndian:Bool=false,iso:UInt16=100) throws -> Data {
        func put<T:FixedWidthInteger>(_ value:T,to data:inout Data) {var v=bigEndian ? value.bigEndian:value.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        var raw=Data();pixels.forEach{put($0,to:&raw)}
        var tags:[Tag]=[longs(254,[0]),longs(256,[UInt32(width)]),longs(257,[UInt32(height)]),shorts(258,[16]),shorts(259,[1]),shorts(262,[32803]),
            text(271,"GlassCam synthetic"),text(272,"F5 test fixture"),longs(273,[0]),shorts(274,[6]),shorts(277,[1]),longs(278,[UInt32(height)]),longs(279,[UInt32(raw.count)]),shorts(284,[1]),
            text(306,"2026:10:27 10:00:00"),shorts(33421,[2,2]),bytes(33422,[0,1,1,2]),longs(34665,[0]),bytes(50706,[1,4,0,0]),bytes(50707,[1,3,0,0]),
            text(50708,"SYNTHETIC_NOT_IPHONE"),bytes(50710,[0,1,2]),shorts(50711,[1]),shorts(50713,[2,2]),rationals(50714,[512,512,512,512]),longs(50717,[65535]),
            longs(50719,[0,0]),longs(50720,[UInt32(active.width),UInt32(active.height)]),rationals(50721,[1,0,0,0,1,0,0,0,1],signed:true),
            rationals(50728,[0.3457/0.3585,1,(1-0.3457-0.3585)/0.3585]),shorts(50778,[23]),longs(50829,[UInt32(active.top),UInt32(active.left),UInt32(active.bottom),UInt32(active.right)])]
        if overrides.contains(where:{$0.id==50729}) {tags.removeAll{$0.id==50728}}
        for tag in overrides {tags.removeAll{$0.id==tag.id};tags.append(tag)}
        let exif:[Tag]=[rationals(33434,[exposure]),rationals(33437,[1.6]),shorts(34855,[iso]),text(36867,"2026:10:27 10:00:00"),text(36881,"+08:00")]
        let exifOffset=8+2+tags.count*12+4,extraOffset=exifOffset+2+exif.count*12+4
        let extras=(tags+exif).reduce(0){$0+($1.bytes.count>4 ? ($1.bytes.count+1)/2*2 : 0)},pixelOffset=extraOffset+extras
        tags[tags.firstIndex{$0.id==273}!]=longs(273,[UInt32(pixelOffset)])
        tags[tags.firstIndex{$0.id==34665}!]=longs(34665,[UInt32(exifOffset)])
        var data=Data(bigEndian ? [77,77,0,42,0,0,0,8]:[73,73,42,0,8,0,0,0]),extra=Data()
        func emit(_ values:[Tag]) {
            put(UInt16(values.count),to:&data)
            for value in values.sorted(by:{$0.id<$1.id}) {
                var payload=[UInt8](value.bytes)
                let unit=(value.type==3 || value.type==8) ? 2 : ([4,5,9,10,11,13].contains(value.type) ? 4 : (value.type==12 ? 8:1))
                if bigEndian && unit>1 {for start in stride(from:0,to:payload.count,by:unit) {for k in 0..<unit/2 {payload.swapAt(start+k,start+unit-1-k)}}}
                put(value.id,to:&data);put(value.type,to:&data);put(value.count,to:&data)
                if payload.count<=4 {data.append(contentsOf:payload);data.append(Data(count:4-payload.count))}
                else {put(UInt32(extraOffset+extra.count),to:&data);extra.append(contentsOf:payload);if extra.count%2 != 0 {extra.append(0)}}
            }
            put(UInt32(0),to:&data)
        }
        emit(tags);emit(exif);data.append(extra);data.append(raw)
        return data
    }
    static func colorFixtures() throws -> [(String,Data)] {
        let cm1=[0.65,-0.05,-0.10, -0.30,1.15,0.18, -0.08,0.16,0.56]
        let cm2=[0.72,-0.18,-0.04, -0.24,1.10,0.12, -0.01,0.10,0.65]
        let dual=[rationals(50721,cm1,signed:true),rationals(50722,cm2,signed:true),shorts(50778,[17]),shorts(50779,[21]),rationals(50728,[0.52,1,0.68])]
        let forward=[rationals(50964,[0.50,0.30,0.1642, 0.22,0.72,0.06, 0.01,0.10,0.7152],signed:true),
                     rationals(50965,[0.53,0.27,0.1642, 0.20,0.74,0.06, 0.02,0.08,0.7252],signed:true)]
        let cc=[rationals(50723,[1.02,0.01,0, 0,0.99,0.01, 0,-0.02,1.03],signed:true),
                rationals(50724,[0.98,0.01,0, 0,1.01,0.01, 0,-0.01,1.04],signed:true),
                rationals(50727,[1.1,1,0.95]),text(50931,"F5Fixture"),text(50932,"F5Fixture")]
        let cases:[(String,[Tag])]=[("single_d50",[]),("single_d65_xy",[rationals(50721,cm2,signed:true),shorts(50778,[21]),rationals(50729,[0.3127,0.3290])]),
            ("dual_neutral",dual),("dual_forward",dual+forward),("dual_calibrated_forward",dual+forward+cc),
            ("signature_mismatch",dual+forward+cc+[text(50932,"DifferentProfile")]),
            ("dual_warm",dual+[rationals(50728,[0.9,1,0.35])]),("dual_cool",dual+[rationals(50728,[0.45,1,1.05])])]
        return try cases.map{($0.0,try makeDNG(width:10,height:8,active:.init(top:1,left:1,bottom:7,right:9),pixels:Array(repeating:16000,count:80),exposure:0.008,overrides:$0.1))}
    }
    static func stage2GainTag(width:Int=8,height:Int=6) -> Tag {
        func be<T:FixedWidthInteger>(_ value:T,_ data:inout Data) {var value=value.bigEndian;withUnsafeBytes(of:&value){data.append(contentsOf:$0)}}
        var parameters=Data()
        for value:UInt32 in [0,0,UInt32(height),UInt32(width),0,1,1,1,2,2] {be(value,&parameters)}
        for value:Double in [1,1,0,0] {be(value.bitPattern,&parameters)}
        be(UInt32(1),&parameters)
        for value:Float in [1,3,2,4] {be(value.bitPattern,&parameters)}
        var data=Data();for value:UInt32 in [1,9,0x01030000,0,UInt32(parameters.count)] {be(value,&data)};data.append(parameters)
        return .init(id:51009,type:7,count:UInt32(data.count),bytes:data)
    }
    static func postOpcodeFixtures() throws -> [(String,Data)] {
        func be<T:FixedWidthInteger>(_ value:T,_ data:inout Data) { var value=value.bigEndian;withUnsafeBytes(of:&value){data.append(contentsOf:$0)} }
        func gain(first:Int=0,planes:Int=3,mapPlanes:Int=3,partial:Bool=false,constant:Float?=nil)->Data {
            var data=Data()
            let area: [UInt32] = partial ? [8,16,40,56] : [0,0,48,64]
            for value in area + [UInt32(first),UInt32(planes),1,1,2,2] { be(value,&data) }
            for value:Double in [1,1,0,0] {be(value.bitPattern,&data)}
            be(UInt32(mapPlanes),&data)
            for base:Float in [1,3,2,4] {for plane in 0..<mapPlanes {be((constant ?? (base*Float(plane+1))).bitPattern,&data)}}
            return data
        }
        var warp=Data();be(UInt32(1),&warp)
        // Integer/half-pixel phases make SDK raster resampling and a continuous
        // linear field directly comparable, without a resampling-kernel bias.
        for value:Double in [0.5,0,0,0,0,0,0.5,0.5] {be(value.bitPattern,&warp)}
        let g=gain(),w=warp
        let cases:[(String,[(UInt32,Data)])]=[
            ("gain_rgb",[(9,g)]),("gain_before_warp",[(9,g),(1,w)]),
            ("gain_after_warp",[(1,w),(9,g)]),("gain_warp_gain",[(9,g),(1,w),(9,gain(constant:1.1))]),
            ("partial_planes_broadcast",[(9,gain(first:1,planes:2,mapPlanes:2,partial:true))]),
            ("hdr_extension",[(9,gain(constant:100))])]
        return try cases.map { name,operations in
            var bytes=Data();be(UInt32(operations.count),&bytes)
            for (id,parameters) in operations {
                for word:UInt32 in [id,0x01030000,0,UInt32(parameters.count)] {be(word,&bytes)}
                bytes.append(parameters)
            }
            let tag=Tag(id:51022,type:7,count:UInt32(bytes.count),bytes:bytes)
            return (name,try makeDNG(width:66,height:50,active:.init(top:1,left:1,bottom:49,right:65),
                pixels:Array(repeating:2000,count:3300),exposure:0.008,overrides:[tag]))
        }
    }
}
