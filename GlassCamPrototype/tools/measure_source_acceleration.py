"""Propagate matrix-backend errors through real HNCS curves and sharpness.

This is a bounded numerical corpus, not a camera accuracy test. Native M5 Metal
timestamps, Accelerate calls and optional Core ML predictions are recorded.
The approximation budget must already exist before this script is run.
"""
import argparse
import ctypes as c
import json
from pathlib import Path
import subprocess
import sys
import time

import numpy as np

from audit_ffcs_original import srgb_lab, summary
from audit_x2d_identity import sha
from verify_x2d_color_gain import bind


def encoded_srgb(linear):
    return np.where(linear<=.0031308,12.92*linear,1.055*np.maximum(linear,0)**(1/2.4)-.055)


def itp(linear):
    # Linear sRGB (D65), 203 nit diffuse white -> BT.2020 -> BT.2100 LMS/PQ.
    srgb_xyz=np.array([[.4124564,.3575761,.1804375],[.2126729,.7151522,.0721750],[.0193339,.1191920,.9503041]])
    bt2020_xyz=np.array([[.6369580483,.1446169036,.1688809752],[.262700212,.6779980715,.0593017165],[0.,.028072693,1.0609850577]])
    rgb=linear@np.linalg.solve(bt2020_xyz,srgb_xyz).T
    lms=rgb@(np.array([[1688,2146,262],[683,2951,462],[99,309,3688]])/4096.).T
    value=np.clip(lms*203./10000.,0,1)**(2610./16384.)
    pq=((3424./4096.+2413./128.*value)/(1.+2392./128.*value))**(2523./32.)
    ictcp=pq@(np.array([[2048,2048,0],[6610,-13613,7003],[17933,-17390,-543]])/4096.).T
    ictcp[...,1]*=.5
    return ictcp


def corpus():
    height,width=256,512
    rng=np.random.default_rng(20261018)
    image=rng.random((height,width,3),dtype=np.float32)
    gradient=np.linspace(0,1,width,dtype=np.float32)
    image[:32]=gradient[None,:,None]
    image[32:64]=np.linspace(0,.015,width,dtype=np.float32)[None,:,None]
    for channel in range(3):
        image[64+channel*24:88+channel*24]=0
        image[64+channel*24:88+channel*24,:,channel]=gradient
    for start,color in [(136,[.62,.36,.24]),(160,[.88,.63,.49])]:
        encoded=np.array(color,dtype=np.float32)
        linear=np.where(encoded<=.04045,encoded/12.92,((encoded+.055)/1.055)**2.4)
        image[start:start+24]=gradient[None,:,None]*linear
    image[184:200]=np.nextafter(np.float32(.5),np.float32(0.))
    image[200:216]=np.float32(.5)
    image[216:232]=np.nextafter(np.float32(.5),np.float32(1.))
    gains=np.ones((height,width),np.float32)
    gains[232:]=np.linspace(1,10000/203,width,dtype=np.float32)
    return image,gains


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root",type=Path,required=True)
    parser.add_argument("--budget",type=Path,required=True)
    parser.add_argument("--output-dir",type=Path,required=True)
    parser.add_argument("--collect-coreml",type=Path)
    args=parser.parse_args();root=Path(__file__).resolve().parents[1]
    out=args.output_dir.resolve();out.mkdir(parents=True,exist_ok=True)
    budget=json.loads(args.budget.read_text())
    sys.path.insert(0,str(args.reference_root.resolve()));import hncs_pipeline as h
    library=out/"source-study.dylib"
    command=["xcrun","clang++","-std=c++17","-O3","-fno-fast-math","-ffp-contract=off","-fobjc-arc","-dynamiclib",
             str(root/"tools/metal_hncs_source_bridge.mm"),str(root/"core/hncs_spatial.cpp"),str(root/"core/hncs_numpy_rng.cpp"),
             "-framework","Foundation","-framework","Metal","-framework","Accelerate","-o",str(library)]
    if not args.collect_coreml:subprocess.run(command,check=True)
    lib=c.CDLL(str(library))
    create=bind(lib,"hncs_create_preset",[c.c_double]*3+[c.c_int]*4+[c.c_char_p,c.c_int,c.c_void_p,c.c_void_p],c.c_void_p)
    destroy=bind(lib,"hncs_destroy",[c.c_void_p],None)
    matrix=bind(lib,"hncs_source_to_native_matrix",[c.c_void_p,c.c_void_p])
    signature=[c.c_void_p,c.c_void_p,c.c_void_p,c.c_size_t,c.c_uint]
    operations={"cpu_double":bind(lib,"hncs_cpu_process_phocus_work_float_parallel",signature),
                "metal_float32":bind(lib,"hncs_process_phocus_work_float_parallel",signature),
                "metal_color_float32":bind(lib,"hncs_study_metal_color_work",signature),
                "accelerate_double":bind(lib,"hncs_study_accelerate_work",signature)}
    finish_native=bind(lib,"hncs_study_finish_native_matrix",signature)
    sharp=bind(lib,"hncs_apply_spatial_native_sharpness",[c.c_void_p,c.c_size_t,c.c_size_t,c.c_char_p,c.c_int,c.c_int,c.c_double])
    finish=bind(lib,"hncs_finish_phocus_work_linear_parallel",signature)
    source,gains=corpus();height,width=source.shape[:2];count=height*width
    metadata={"library_sha256":sha(library),"compile":command,"budget_sha256":sha(args.budget),"source_sha256":sha(root/"tools/metal_hncs_source_bridge.mm"),
              "corpus":"Synthetic neutral/dark ramps, saturated primaries, two skin hue ramps, half-code neighbors, random colors and 1–49.26x HDR gains.","cases":[]}
    rows=[]
    if args.collect_coreml:
        previous=json.loads((out/"report.json").read_text())
        rows=[row for row in previous["results"] if not row["candidate"].startswith("coreml_")]
        model_report=json.loads((args.collect_coreml/"report.json").read_text())
    for preset in ["standard","nature"]:
        context=create(-.05,5500.,0.,1,0,4,2,preset.encode(),1,None,None);assert context
        matrix_values=np.empty((3,3),np.float64);assert matrix(context,matrix_values.ctypes.data)==0
        np.save(out/(preset+"-input.npy"),source)
        case={"name":preset,"height":height,"width":width,"input_file":str(out/(preset+"-input.npy")),
              "matrix":matrix_values.tolist(),"exposure_multiplier":2.**-.05}
        metadata["cases"].append(case)
        def complete(work):
            work=work.copy()
            assert sharp(work.ctypes.data,width,height,preset.encode(),0,1,1.5)==0
            rgba=np.empty((height,width,4),np.float32)
            assert finish(context,work.ctypes.data,rgba.ctypes.data,count,4)==0
            return rgba[...,:3].copy()
        try:
            if args.collect_coreml:
                baseline=np.load(out/(preset+"-baseline.npy"))
                candidates=[]
                for run in model_report["runs"]:
                    if run["case"]!=preset or run.get("status")!="predicted":continue
                    native=np.load(run["output"])[0].transpose(1,2,0).copy()
                    work=np.empty_like(source)
                    started=time.perf_counter()
                    assert finish_native(context,native.ctypes.data,work.ctypes.data,count,4)==0
                    run["cpu_point_tail_once_seconds"]=time.perf_counter()-started
                    candidates.append(("coreml_"+run["precision"]+"_"+run["compute_units"],complete(work),run["prediction_seconds"],run))
            else:
                candidates=[];baseline=None
                for name,operation in operations.items():
                    work=np.empty_like(source);timings=[]
                    for iteration in range(6):
                        started=time.perf_counter();assert operation(context,source.ctypes.data,work.ctypes.data,count,4)==0
                        elapsed=time.perf_counter()-started
                        if iteration:timings.append(elapsed)
                    rgb=complete(work)
                    if baseline is None:
                        baseline=rgb;np.save(out/(preset+"-baseline.npy"),baseline)
                        case["cpu_point_stage_seconds"]=timings
                    else:candidates.append((name,rgb,timings,None))
            for name,rgb,timings,model in candidates:
                delta=h.delta_e_2000(srgb_lab(encoded_srgb(baseline.reshape(-1,3).astype(np.float64))),srgb_lab(encoded_srgb(rgb.reshape(-1,3).astype(np.float64))))
                hdr_base=(baseline*gains[...,None]).astype(np.float32)
                hdr_actual=(rgb*gains[...,None]).astype(np.float32)
                delta_hdr=720*np.linalg.norm(itp(hdr_actual.reshape(-1,3))-itp(hdr_base.reshape(-1,3)),axis=1)
                sdr,hdr=summary(delta),summary(delta_hdr)
                additional_white=int(np.count_nonzero((rgb>=1)&(baseline<1)))
                additional_black=int(np.count_nonzero((rgb<=0)&(baseline>0)))
                neutral_base=np.diff(baseline[4,:,1]);neutral_actual=np.diff(rgb[4,:,1])
                reversals=int(np.count_nonzero((neutral_actual<0)&(neutral_base>=0)))
                relative_peak=abs(float(hdr_actual.max())-float(hdr_base.max()))/float(hdr_base.max())
                passed=(all(sdr[key]<=bound for key,bound in budget["candidate_SDR_deltaE00"].items()) and
                        all(hdr[key]<=bound for key,bound in budget["candidate_HDR_deltaEITP"].items()) and
                        additional_white==0 and additional_black==0 and reversals==0 and relative_peak<=budget["hdr_peak_relative_error_max"])
                row={"preset":preset,"candidate":name,"sdr_deltaE00":sdr,"hdr_deltaEITP":hdr,
                     "different_float32_channels":int(np.count_nonzero(rgb.view(np.uint32)!=baseline.view(np.uint32))),
                     "additional_white_channels":additional_white,"additional_black_channels":additional_black,
                     "neutral_gradient_extra_reversals":reversals,"hdr_peak_relative_error":relative_peak,
                     "matrix_plus_cpu_point_stage_seconds":timings,"median_seconds":float(np.median(timings)),
                     "screening_budget_passed":passed,
                     "worst_sdr_input":source.reshape(-1,3)[int(np.argmax(delta))].tolist(),
                     "worst_hdr_case":{"sequence_index":int(np.argmax(delta_hdr)),
                         "source_linear_rgb":source.reshape(-1,3)[int(np.argmax(delta_hdr))].tolist(),
                         "gain":float(gains.reshape(-1)[int(np.argmax(delta_hdr))]),
                         "reference_linear_rgb":hdr_base.reshape(-1,3)[int(np.argmax(delta_hdr))].tolist(),
                         "actual_linear_rgb":hdr_actual.reshape(-1,3)[int(np.argmax(delta_hdr))].tolist()},
                     "scope":"Native color/gradation and USM/finish are included in error propagation; input is synthetic prepared Apple-linear RGB, not a RAW decoder comparison."}
                if model:
                    row["coreml_placement_evidence"]=model["compute_plan"]
                    row["model_prediction_seconds"]=row.pop("matrix_plus_cpu_point_stage_seconds")
                    row["cpu_point_tail_once_seconds"]=model["cpu_point_tail_once_seconds"]
                    row["timing_scope"]="Prediction only; CPU tail measured separately, not a jointly timed full pipeline."
                rows.append(row)
        finally:destroy(context)
    if not args.collect_coreml:
        stats_fn=bind(lib,"metal_study_stats",[c.c_void_p,c.c_size_t]);values=np.empty(9,np.float64)
        assert stats_fn(values.ctypes.data,len(values))==0
        device=bind(lib,"metal_study_device",[],c.c_char_p)().decode()
        metadata["metal"]={"device":device,**dict(zip(["compile_seconds","copy_seconds","submit_wait_seconds","gpu_timestamp_seconds","cpu_tail_seconds","calls","uploaded_bytes","cached_buffer_bytes","unified_memory"],values.tolist()))}
        (out/"cases.json").write_text(json.dumps(metadata,indent=2)+"\n")
    report={"budget":budget,"results":rows,"metadata":metadata if not args.collect_coreml else previous["metadata"],
            "limits":["Point-stage times exclude spatial and output work; full production timing is required before adopting a candidate.",
                      "Core ML compute plans describe anticipated placement, not an Instruments trace proving every runtime operation.",
                      "No candidate replaces the default CPU path."]}
    (out/"report.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps([{k:r[k] for k in ["preset","candidate","sdr_deltaE00","hdr_deltaEITP","screening_budget_passed","median_seconds"]} for r in rows],indent=2))


if __name__=="__main__":main()
