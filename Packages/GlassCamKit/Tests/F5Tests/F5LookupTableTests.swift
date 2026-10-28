import Testing
import Foundation
import CF5
@testable import F5
import GlassCamTestSupport

struct F5LookupTableTests {
    static var available: Bool {
        guard let directory = TestResources.environmentURL("F5_TEST_LUT_PACKAGE") else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("likelihood-descriptor.json").path)
    }
    @Test(.enabled(if: available, "Set F5_TEST_LUT_PACKAGE to a prepared likelihood table"))
    func heldOutLikelihoodEvents_preserveIndependentFP64Certificate() throws {
        let context = try F5TestContext(), fixture = context.fixture, shader = try F5TestContext.shader
        let directory = try #require(TestResources.environmentURL("F5_TEST_LUT_PACKAGE"))
        var object=try JSONSerialization.jsonObject(with:F5Hash.json(fixture.profile)) as! [String:Any]
        object["likelihood"]=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("likelihood-descriptor.json")))
        let profile=try JSONDecoder().decode(F5DeviceProfile.self,from:JSONSerialization.data(withJSONObject:object))
        try profile.validate(synthetic:true)
        let device=try F5MetalDevice(maximumBytes:32*1024*1024,shaderURL:shader,isCancelled:{false})
        let table=try F5MetalLikelihood.load(profile:profile,directory:directory,device:device)
        var events:[F5GPUEvent]=[],means:[Float]=[]
        for phase:UInt32 in 0..<4 {for kind:UInt32 in 0..<3 {for electrons:Float in [0.008,0.073,0.183] {
            let k=Float(profile.noise[Int(phase)].kappa),s=Float(profile.noise[Int(phase)].readSigma),mean=k*electrons
            let width=1/Float(profile.whiteScale),center=mean+0.317*sqrt(k*mean+s*s)
            events.append(.init(at:.init(0,0,1,width),interval:.init(kind==0 ? center-width/2:center,kind==0 ? center+width/2:center,k,s),
                score:.zero,info:.init(0,phase,0,kind),source:.init(1/65536,0,0,0)));means.append(mean)
        }}}
        let eb=try device.upload(events,label:"LUT held-out events"),mb=try device.upload(means,label:"LUT held-out means"),out=try device.allocate(events.count*16,label:"LUT probe")
        try device.run {command in try device.encode("f5_probe_likelihood",count:events.count,buffers:[eb.metal,mb.metal,out.metal],command:command) {e in
            F5MetalDevice.value(table.uniforms,at:3,encoder:e);e.setBuffer(table.table.metal,offset:0,index:4);F5MetalDevice.value(UInt32(events.count),at:5,encoder:e)
        }}
        let values=out.metal.contents().assumingMemoryBound(to:SIMD4<Float>.self)
        var nll=0.0,score=0.0, statuses: [Int32] = []
        for i in events.indices {
            let e=events[i],center=Double((e.interval.x+e.interval.y)/2)
            var literal=F5LikelihoodValue()
            let status=f5_pg_event(.init(lower:e.info.w==0 ? center-Double(e.at.w)/2:Double(e.interval.x),upper:e.info.w==0 ? center+Double(e.at.w)/2:Double(e.interval.y),
                kappa:Double(e.interval.z),read_sigma:Double(e.interval.w),uniform_probability:1/65536,kind:e.info.w),Double(means[i]),&literal)
            statuses.append(status)
            nll=max(nll,abs(Double(values[i].x)-literal.nll));score=max(score,abs(Double(values[i].y)-literal.score)*sqrt(Double(e.interval.z*means[i]+e.interval.w*e.interval.w)))
        }
        #expect(Set(statuses) == [0])
        #expect(nll < 1e-4)
        #expect(score < 1e-3)
        print("F5 actual Metal LUT NLL error",nll,"standardized score error",score)
    }
}
