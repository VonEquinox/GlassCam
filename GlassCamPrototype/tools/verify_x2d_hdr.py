"""Validate independent HDR tables and prepared-input colors against Phocus.

Original expected values are called afresh from hash-checked vendor libraries.
The three captured RAW examples remain outside the source tree. This audits
the HDR color stage; HighlightStrength/gamma/spatial/ICC are separate stages.
"""
import argparse
import ctypes as c
import json
from pathlib import Path
import subprocess

import numpy as np

from audit_x2d_identity import RawProbe, sha
from verify_x2d_color_gain import bind, stats


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root",type=Path,required=True)
    parser.add_argument("--raw-source",type=Path,required=True)
    parser.add_argument("--output-dir",type=Path,required=True)
    parser.add_argument("--crop-manifest",type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    out=args.output_dir.resolve();out.mkdir(parents=True,exist_ok=True)
    commands=[]
    for source,destination in [(root/"core/hncs.cpp",out/"core.dylib"),
                               (root/"tools/native_x2d_hdr_bridge.cpp",out/"bridge.dylib")]:
        command=["xcrun","clang++","-std=c++17","-O3","-fno-fast-math","-ffp-contract=off",
                 "-Wall","-Wextra","-Werror","-dynamiclib",str(source),"-o",str(destination)]
        subprocess.run(command,check=True);commands.append(command)
    n=RawProbe(args.reference_root.resolve(),args.raw_source.resolve()).n
    lib=c.CDLL(str(out/"core.dylib"));bridge=c.CDLL(str(out/"bridge.dylib"))
    create=bind(lib,"hncs_create_mode",[c.c_double,c.c_double,c.c_int,c.c_int],c.c_void_p)
    destroy=bind(lib,"hncs_destroy",[c.c_void_p],None)
    render=bind(lib,"hncs_render_x2d_hdr_color",[c.c_void_p,c.c_double,c.c_void_p,c.c_void_p,c.c_size_t])
    original=bind(bridge,"hdr_original_stages",[c.c_void_p,c.c_void_p,c.c_double]+[c.c_void_p]*4)
    candidate=bind(bridge,"hdr_candidate_stages",[c.c_double]+[c.c_void_p]*4,None)
    native_pixels=n.fn(n.raw,"_ZN14CVectorMethods24ColorNormalCorrectPixelsEP16CColorCorrectionPtS2_ib",
                       [c.c_void_p]*4+[c.c_int,c.c_bool])
    delete=n.fn(n.raw,"_ZN19CRawColorCorrectionD0Ev",[c.c_void_p])
    outer=n.correction(7523.,film=2,model=0,hdr=False,gain=1.,space=0)
    manager=c.c_void_p.from_address(outer+8).value
    gains=[.25,.5,1.,1.0653693159208844,3.897287580612024,4.101902750225289,
           4.643616364582644,16.,18.574465458330575,32.]
    curve_rows=[]
    for gain in gains+np.exp(np.random.default_rng(20261018).uniform(np.log(.25),np.log(32),30)).tolist():
        expected=[np.empty(65536,np.float32) for _ in range(3)]
        actual=[np.empty(65536,np.float32) for _ in range(3)]
        join,join2=c.c_int(),c.c_int()
        assert original(n.util._handle,manager,gain,*(x.ctypes.data for x in expected),c.byref(join))==0
        candidate(gain,*(x.ctypes.data for x in actual),c.byref(join2))
        row={"gain":gain,"join":join.value,"candidate_join":join2.value,"stages":[]}
        for label,ex,ac in zip(["gain","highlight_extension","final_hdr_film"],expected,actual):
            row["stages"].append({"name":label,"entries":65536,
                "different_float32":int(np.count_nonzero(ex.view(np.uint32)!=ac.view(np.uint32))),
                "max_absolute":float(np.abs(ex-ac).max())})
        curve_rows.append(row)
    delete(outer)
    grid=np.stack(np.meshgrid(*([np.linspace(0,65535,17,dtype=np.uint16)]*3),indexing="ij"),axis=-1).reshape(-1,3)
    source=np.ascontiguousarray(np.concatenate([np.repeat(np.arange(65536,dtype=np.uint16)[:,None],3,axis=1),grid,
                      np.random.default_rng(1842026).integers(0,65536,(8192,3),dtype=np.uint16)]))
    floating=source.astype(np.float64)/65535.;expected=np.empty_like(source);actual=np.empty_like(source)
    rows,goldens,golden_cases=[],{},[]
    chosen=np.r_[np.arange(0,65536,257),np.arange(len(source)-128,len(source))]
    for space in [0,1]:
        for cct in [2850.,5500.,7523.]:
            context=create(0.,cct,space,0);assert context
            try:
                for gain in gains:
                    vendor=n.correction(cct,film=2,model=0,hdr=True,gain=gain,space=space)
                    inner=c.c_void_p.from_address(vendor+0xb0).value
                    native_pixels(None,inner,expected.ctypes.data,source.ctypes.data,len(source),False)
                    delete(vendor)
                    assert render(context,gain,floating.ctypes.data,actual.ctypes.data,len(source))==0
                    rows.append({"space":space,"cct":cct,"gain":gain,**stats(actual,expected)})
                    if cct==7523. and gain in [.25,1.,4.643616364582644,18.574465458330575,32.]:
                        prefix=f"case_{len(golden_cases)}"
                        goldens[prefix+"_input"]=source[chosen].copy()
                        goldens[prefix+"_expected"]=expected[chosen].copy()
                        golden_cases.append({"prefix":prefix,"space":space,"cct":cct,"gain":gain})
                for invalid in [0.,.249,32.001,float("inf"),float("nan")]:
                    actual.fill(1973)
                    assert render(context,invalid,floating.ctypes.data,actual.ctypes.data,len(source))==-1
                    assert np.all(actual==1973)
            finally:destroy(context)
    crops=[]
    if args.crop_manifest:
        manifest=json.loads(args.crop_manifest.read_text())
        for case in manifest["hdr"]:
            before,after=Path(case["stages"]["input"]),Path(case["stages"]["color"])
            metadata=json.loads((after/"native-input.json").read_text())
            contract=metadata["color_contract"];params=metadata["parameters"]
            assert params["hdr"] and metadata["backend"]["requested"]=="cpu"
            pixels=np.load(before/"native-crop.npy");expected=np.load(after/"native-crop.npy")
            inp=np.ascontiguousarray(pixels.astype(np.float64)/65535.);actual=np.empty_like(expected)
            context=create(0.,contract["cct"],params["working_space"],params["color_model"]);assert context
            try:assert render(context,contract["outer_248"],inp.ctypes.data,actual.ctypes.data,pixels.size//3)==0
            finally:destroy(context)
            crops.append({"name":case["name"],"gain":contract["outer_248"],**stats(actual,expected),
                          "source_sha256":sha(before/"native-crop.npy"),"expected_sha256":sha(after/"native-crop.npy")})
    passed=(all(r["join"]==r["candidate_join"] and all(s["different_float32"]==0 for s in r["stages"]) for r in curve_rows)
            and all(r["maximum_uint16_error"]==0 for r in rows+crops))
    from native_config_probe import FRAMEWORK_HASHES,verified_framework
    sources=[Path(__file__),root/"core/hncs.cpp",root/"core/hncs_c.h",root/"core/hncs_phocus_hdr.hpp",root/"tools/native_x2d_hdr_bridge.cpp"]
    report={"status":"passed" if passed else "difference-found","curve_cases":curve_rows,"color_cases":rows,"real_crops":crops,
            "compile":commands,"source_sha256":{str(p.relative_to(root)):sha(p) for p in sources},
            "framework_sha256":{name:sha(verified_framework(name)) for name in FRAMEWORK_HASHES},
            "limits":["Prepared X2D HDR color stage only; no complete RAW/HDR/output equivalence claim.",
                      "Normal color model/standard film table, legacy and L* primaries, processing gain [0.25,32].",
                      "No Apple input, phone runtime, camera matching, or grain reverse engineering."]}
    np.savez_compressed(out/"goldens.npz",**goldens)
    (out/"goldens.json").write_text(json.dumps({"cases":golden_cases,"vectors_sha256":sha(out/"goldens.npz")},indent=2)+"\n")
    (out/"report.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps({"status":report["status"],"curve_cases":len(curve_rows),"curve_float32_entries":len(curve_rows)*3*65536,
                      "color_cases":len(rows),"color_channels":sum(r["channels"] for r in rows),"max_color_error":max(r["maximum_uint16_error"] for r in rows),
                      "curve_differences":[r for r in curve_rows if any(s["different_float32"] for s in r["stages"])],"real_crops":crops},indent=2))
    if not passed:raise SystemExit(1)


if __name__=="__main__":main()
