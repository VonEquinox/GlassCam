"""Independent native SILKYPIX mapping audit and current FFCS error statistics.

Default library dispatch and explicit gamma-aware trilinear use different
numeric domains. They are compared with independent fixed-point calculations
separately. FFCS sampled assets are compared as an approximation, not bit exact
Fujifilm camera rendering. No vendor expected file is modified.
"""
import argparse
import ctypes as c
import json
from pathlib import Path
import struct
import subprocess
import sys

import numpy as np

from audit_x2d_identity import sha
from decompile_ffcs_stages import LIBRARY_SHA256
from verify_x2d_color_gain import bind, stats


def interpolate_fixed(lut,coordinates,gamma_path):
    lo=coordinates>>8;fraction=coordinates&255
    b,g,r=lo.T;fb,fg,fr=(fraction[:,i,None].astype(np.uint64) for i in range(3))
    slabs=[]
    for dr in [0,1]:
        low=lut[r+dr,g,b].astype(np.uint64)*(256-fb)+lut[r+dr,g,b+1].astype(np.uint64)*fb
        high=lut[r+dr,g+1,b].astype(np.uint64)*(256-fb)+lut[r+dr,g+1,b+1].astype(np.uint64)*fb
        slabs.append((low*(256-fg)+high*fg)>>(8 if gamma_path else 16))
    return ((slabs[0]*(256-fr)+slabs[1]*fr)>>(16 if gamma_path else 8)).astype(np.uint32)


def srgb_lab(rgb):
    linear=np.where(rgb<=.04045,rgb/12.92,((rgb+.055)/1.055)**2.4)
    xyz=linear@np.array([[.4124564,.3575761,.1804375],[.2126729,.7151522,.0721750],[.0193339,.1191920,.9503041]]).T
    t=xyz/np.array([.95047,1.,1.08883]);delta=6./29.
    f=np.where(t>delta**3,np.cbrt(t),t/(3*delta**2)+4./29.)
    return np.stack([116*f[:,1]-16,500*(f[:,0]-f[:,1]),200*(f[:,1]-f[:,2])],axis=-1)


def summary(values):
    return {"count":int(values.size),"mean":float(values.mean()),"p95":float(np.quantile(values,.95)),
            "p99":float(np.quantile(values,.99)),"maximum":float(values.max())}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library",type=Path,required=True)
    parser.add_argument("--reference-root",type=Path,required=True,help="HNCS reference for independent vectorized CIEDE2000")
    parser.add_argument("--output-dir",type=Path,required=True)
    parser.add_argument("--tables",nargs="*",help="Optional family/look selectors")
    args=parser.parse_args()
    library=args.library.resolve()
    if sha(library)!=LIBRARY_SHA256:raise ValueError("Unrecognized original SILKYPIX library")
    root=Path(__file__).resolve().parents[1];out=args.output_dir.resolve();out.mkdir(parents=True,exist_ok=True)
    source=root/"tools/native_ffcs_audit.cpp";probe=out/"native-audit"
    command=["xcrun","clang++","-std=c++17","-O2","-arch","x86_64",str(source),"-o",str(probe)]
    subprocess.run(command,check=True)
    core=out/"ffcs.dylib"
    core_command=["xcrun","clang++","-std=c++17","-O3","-fno-fast-math","-ffp-contract=off","-dynamiclib",str(root/"core/ffcs.cpp"),"-lz","-o",str(core)]
    subprocess.run(core_command,check=True)
    lib=c.CDLL(str(core));create=bind(lib,"ffcs_create",[c.c_char_p,c.c_size_t,c.c_void_p,c.c_size_t],c.c_void_p)
    destroy=bind(lib,"ffcs_destroy",[c.c_void_p],None)
    render=bind(lib,"ffcs_process_encoded_double",[c.c_void_p,c.c_void_p,c.c_size_t,c.c_size_t,c.c_size_t,c.c_uint32,c.c_void_p,c.c_size_t,c.c_void_p,c.c_void_p,c.c_void_p,c.c_size_t])
    sim_count=bind(lib,"ffcs_simulation_count",[],c.c_size_t)
    sim_asset=bind(lib,"ffcs_simulation_asset",[c.c_size_t],c.c_char_p)
    indices={sim_asset(i).decode():i for i in range(sim_count())}
    sys.path.insert(0,str(args.reference_root.resolve()));import hncs_pipeline as h
    grid=np.stack(np.meshgrid(*([np.linspace(0,20000,17,dtype=np.uint16)]*3),indexing="ij"),axis=-1).reshape(-1,3)
    source_codes=np.ascontiguousarray(np.concatenate([np.repeat(np.arange(20001,dtype=np.uint16)[:,None],3,axis=1),grid,
                                np.random.default_rng(20261018).integers(0,20001,(4096,3),dtype=np.uint16)]))
    input_file=out/"input-bgr16.bin";source_codes.tofile(input_file)
    encoded_rgb=np.ascontiguousarray(source_codes[:,::-1].astype(np.float64)/20000.)
    assets=root/"reference_ffcs/implementation/ffcs/data"
    prefixes={"xh2s":"CAM_FUJI_XH2S_","xa3":"CAM_FUJI_XA3_","gfx100":"CAM_GFX_100_","gfx100s":"CAM_GFX100S_","gfx100ii":"CAM_GFX100_II_"}
    report={"status":"running","source_sha256":{str(p.relative_to(root)):sha(p) for p in [Path(__file__),source,root/"core/ffcs.cpp",root/"core/ffcs_c.h"]},
            "native_library_sha256":LIBRARY_SHA256,"compile":[command,core_command],"input_sha256":sha(input_file),
            "samples_per_table":len(source_codes),"tables":[],
            "metric_domain":"Both encoded mapping outputs interpreted as sRGB, D65 XYZ/Lab, CIEDE2000; not vendor ICC or camera accuracy.",
            "limits":["Independent fixed-point mapping and header/gamma audit; original decoder supplies decompressed LUT data.",
                      "Library-default dispatch flag is observed in a fresh process; GUI preferences may select another branch.",
                      "Header matrix and per-image RAW/WB/exposure/output ICC are not established by this mapping-only comparison."]}
    goldens={};golden_cases=[]
    for path in sorted(assets.glob("*/*.lutz")):
        selector=str(path.relative_to(assets).with_suffix(""))
        if args.tables and selector not in args.tables:continue
        original_file=library.parent/"Resources/ColorModeData"/(prefixes[path.parent.name]+path.stem.upper()+"_ISLRGB.s3d")
        directory=out/path.parent.name/path.stem;directory.mkdir(parents=True,exist_ok=True);prefix=directory/"native"
        native_command=[str(probe),str(library),str(original_file),str(input_file),str(prefix)]
        result=subprocess.run(native_command,text=True,capture_output=True,timeout=120)
        (directory/"stdout.txt").write_text(result.stdout);(directory/"stderr.txt").write_text(result.stderr)
        if result.returncode:raise RuntimeError(selector+": "+result.stderr)
        native=json.loads(result.stdout)
        if native["default_normal_flag"]!=0 or native["dispatch_status"]!=0:raise ValueError("Unexpected original dispatch branch")
        nodes,gamma=native["nodes"],native["gamma"]
        lut=np.fromfile(str(prefix)+".lut","<u2").reshape(nodes,nodes,nodes,3)
        gamma_in=np.fromfile(str(prefix)+".gamma-in","<u4");gamma_out=np.fromfile(str(prefix)+".gamma-out","<u2")
        codes=np.arange(20001,dtype=np.float64)/20000.
        independently_in=np.floor(np.power(codes,1/gamma)*(nodes-2)*256+.5).astype(np.uint32)
        independently_out=np.floor(np.power(codes,gamma)*20000+.5).astype(np.uint16)
        tri=gamma_out[np.minimum(interpolate_fixed(lut,gamma_in[source_codes],True),20000)]
        dispatch=interpolate_fixed(lut,source_codes.astype(np.uint32)*(nodes-2)*256//20000,False).astype(np.uint16)
        original_tri=np.fromfile(str(prefix)+".trilinear","<u2").reshape(-1,3)
        original_dispatch=np.fromfile(str(prefix)+".dispatch","<u2").reshape(-1,3)
        error=c.create_string_buffer(1024);context=create(str(path.parent).encode(),indices[path.name],error,len(error))
        if not context:raise RuntimeError(error.value.decode())
        portable=np.empty_like(encoded_rgb)
        try:
            if not render(context,encoded_rgb.ctypes.data,encoded_rgb.size,len(source_codes),1,0,portable.ctypes.data,portable.size,None,None,error,len(error)):
                raise RuntimeError(error.value.decode())
        finally:destroy(context)
        native_rgb=original_dispatch[:,::-1].astype(np.float64)/20000.
        de=h.delta_e_2000(srgb_lab(native_rgb),srgb_lab(portable));worst=int(np.argmax(de))
        sigma_rows=[]
        for i,sigma in enumerate([.5,1.,2.]):
            if native["normal_status"][i]==0:
                values=np.fromfile(str(prefix)+f".normal-{i}","<u2").reshape(-1,3)
                sigma_rows.append({"sigma":sigma,**stats(values,original_tri)})
        data=original_file.read_bytes()
        parsed_gamma=struct.unpack_from("<i",data,20)[0]/1024 if data.startswith(b"ISL_3DMAP_V2") else struct.unpack_from("<H",data,16)[0]/100
        matrix=np.fromfile(str(prefix)+".matrix","<f8").reshape(3,3).T
        row={"asset":selector,"native":native,"native_file":str(original_file),"native_sha256":sha(original_file),"packed_sha256":sha(path),
             "parsed_header_gamma":parsed_gamma,"matrix_rows":matrix.tolist(),
             "gamma_in_different":int(np.count_nonzero(gamma_in!=independently_in)),"gamma_out_different":int(np.count_nonzero(gamma_out!=independently_out)),
             "trilinear_fixed_point":stats(tri,original_tri),"default_encoded_fixed_point":stats(dispatch,original_dispatch),
             "matrix_mutation_changes_trilinear":int(np.count_nonzero(np.fromfile(str(prefix)+".matrix-identity","<u2").reshape(-1,3)!=original_tri)),
             "matrix_mutation_changes_dispatch":int(np.count_nonzero(np.fromfile(str(prefix)+".matrix-identity-dispatch","<u2").reshape(-1,3)!=original_dispatch)),
             "sampled_asset_vs_encoded_dispatch_deltaE00":summary(de),"max_encoded_channel_error":float(np.max(np.abs(portable-native_rgb))),
             "worst_case":{"bgr16_input":source_codes[worst].tolist(),"native_rgb":native_rgb[worst].tolist(),"current_rgb":portable[worst].tolist()},
             "native_normal_distribution_vs_trilinear":sigma_rows,"command":native_command}
        report["tables"].append(row)
        if selector in ["xh2s/provia","xa3/provia","gfx100ii/reala_ace"]:
            key=f"case_{len(golden_cases)}";chosen=np.r_[np.arange(0,20001,97),np.arange(len(source_codes)-64,len(source_codes))]
            goldens[key+"_input"]=source_codes[chosen];goldens[key+"_expected"]=original_dispatch[chosen]
            golden_cases.append({"prefix":key,"asset":selector,"gamma":gamma})
        (out/"report.json").write_text(json.dumps(report,indent=2)+"\n")
        print(f"{len(report['tables'])} {selector}: fixed {row['trilinear_fixed_point']['maximum_uint16_error']}/{row['default_encoded_fixed_point']['maximum_uint16_error']}, gamma {row['gamma_in_different']}/{row['gamma_out_different']}, sampled max DE00 {de.max():.6g}",flush=True)
    report["status"]="passed-exact-stages-with-measured-approximation" if all(
        r["trilinear_fixed_point"]["maximum_uint16_error"]==0 and r["default_encoded_fixed_point"]["maximum_uint16_error"]==0
        and r["gamma_in_different"]==0 and r["gamma_out_different"]==0 and r["native"]["gamma"]==r["parsed_header_gamma"]
        for r in report["tables"]) else "difference-found"
    np.savez_compressed(out/"goldens.npz",**goldens)
    (out/"goldens.json").write_text(json.dumps({"cases":golden_cases,"vectors_sha256":sha(out/"goldens.npz")},indent=2)+"\n")
    (out/"report.json").write_text(json.dumps(report,indent=2)+"\n")
    if report["status"]=="difference-found":raise SystemExit(1)


if __name__=="__main__":main()
