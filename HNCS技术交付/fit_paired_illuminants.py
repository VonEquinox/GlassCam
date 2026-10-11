"""Fit a second direct Sony/X2D response from the public Lowlight RAW pair.

Default paths belong to work/hncs-finalization. It reads CFA samples, produces
annotated ROIs, fits a constrained matrix, and compares against prior models.
"""
import json
import argparse
from pathlib import Path
import numpy as np
import hncs_pipeline as h
import hncs_dual_illuminant as d

CASE=h.ROOT/"work/hncs-finalization"
PAIRED_MODEL=CASE/"paired_illuminants.json"
SOURCE_PROFILE=CASE/"sony_dcp_source_model.json"
S_WARM="b83908b171574fc5b33045dfca85daf6.arw"
H_WARM="bd2ffdbfd1e441bc9a93c115117e5054.3fr"
S_CHECK="825b88ead50e440fbfed14437c27e470.arw"
H_CHECK="f3da42aac2944357bd87685f9ae2ec1e.3fr"


def sample(name,side):
    path=CASE/"raw"/name
    chart=json.loads(h.CHART.read_text())
    region=dict(chart[side]);region["sha256"]=h.digest(path)
    values,quality,meta=h.extract_patches(path,region,"ILCE-7RM5" if side=="sony" else "X2D II 100C",
                                         CASE/"evidence"/(name+".roi.jpg"))
    if max(max(q["clipped_fraction"]) for q in quality)>.001:
        raise ValueError(f"Clipped CFA chart samples in {name}")
    h.save_json(CASE/"evidence"/(name+".patches.json"),
                {"values":values.tolist(),"quality":quality,"metadata":meta,"region":region})
    return values,meta


def normalized_pair(source,target):
    _,target_wb,target_scale=h.normalisation(target,.18)
    gray=.18/target_scale
    target_rgb=target*target_wb
    source_rgb,source_wb,source_scale=h.normalisation(source,gray)
    return source_rgb,target_rgb,source_wb,target_wb,source_scale


def endpoint(source,target,meta_source,meta_target,assets,base,fit_options=None):
    fit_options=fit_options or {"weight_power":.5,"ridge":0.}
    src,tgt,swb,twb,scale=normalized_pair(source,target)
    matrix=h.fit_matrix(src[:18],tgt[:18],**fit_options)
    cct,tint=h.estimate_cct(twb,assets)
    held=[]
    for i in range(18):
        indices=[j for j in range(18) if j!=i]
        held.append(src[i]@h.fit_matrix(src[indices],tgt[indices],**fit_options).T)
    target_lab=h.output_lab(tgt,cct,assets,working_space=base["working_space"])
    cv=h.delta_e_2000(h.output_lab(np.array(held),cct,assets,working_space=base["working_space"]),target_lab[:18])
    fitted=h.delta_e_2000(h.output_lab(src@matrix.T,cct,assets,working_space=base["working_space"]),target_lab)
    source_temp,_,_,_=d.source_illuminant(swb,d.load_model(SOURCE_PROFILE)["sony"],assets)
    return {"source_wb":swb.tolist(),"target_wb":twb.tolist(),"source_scale":scale,"target_scale":1.,
        "matrix":matrix.tolist(),"fit_parameters":fit_options,"target_cct":cct,"target_tint":tint,"source_estimated_cct":source_temp,
        "source":meta_source,"target":meta_target,"raw_response":(matrix*swb[None,:]/twb[:,None]).tolist(),
        "metrics":{"chromatic_patch_loocv":h.summary(cv),"all_patch_training":h.summary(fitted)},
        "source_native_patches":source.tolist(),"target_native_patches":target.tolist()}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fit-only",action="store_true",help="Fit training endpoints without opening held-out RAWs")
    args=parser.parse_args()
    assets=h.load_assets();base=json.loads(h.PROFILE.read_text())
    source,sm=sample(S_WARM,"sony");target,tm=sample(H_WARM,"hasselblad")
    variants=[]
    for power,ridge in ((.5,0.),(0.,0.),(0.,.01),(.5,.01),(1.,0.)):
        variants.append(endpoint(source,target,sm,tm,assets,base,{"weight_power":power,"ridge":ridge}))
    warm=min(variants,key=lambda x:x["metrics"]["chromatic_patch_loocv"]["mean"])
    h.save_json(CASE/"evidence/warm-fit-selection.json",{
        "selection":"Five predeclared simple matrix variants; select by warm chromatic-patch LOOCV before reading the separate-exposure validation pair. LOOCV shares neutral normalization; held-out exposure results are reported separately.",
        "selected":warm["fit_parameters"],"variants":[{"fit_parameters":v["fit_parameters"],"metrics":v["metrics"]} for v in variants]})
    source_day=np.array([p["source_native"] for p in base["patches"]])
    target_day=np.array([p["target_native"] for p in base["patches"]])
    day=endpoint(source_day,target_day,base["source"],base["target"],assets,base,base.get("fit_parameters"))
    # This existing direct fit is the accepted, trusted daylight endpoint.
    np.testing.assert_allclose(day["matrix"],base["matrix"],atol=1e-14,rtol=0)
    import hncs_paired_illuminants as paired
    model={"schema":1,"status":"paired_chart_model","source_model_path":str(SOURCE_PROFILE.relative_to(h.ROOT)),
        "source_model_sha256":h.digest(SOURCE_PROFILE),"base_profile_sha256":h.digest(h.PROFILE),
        "base_calibration_fingerprint":paired.profile_fingerprint(base),
        "endpoints":[warm,day],"input_acceptance":base.get("calibration_input_assumption"),
        "interpolation":"Inverse estimated source CCT; interpolate unbalanced response matrices, then rebuild target WB and normalize neutral gain. CCT labels are rendering estimates, not measured illuminant spectra.",
        "scope":"Direct ColorChecker CFA fit for each nominal DPReview lighting class. Exact physical illuminant spectra are not measured. Patch CV shares neutral WB/exposure calibration. Separate exposure captures are reserved for validation."}
    h.save_json(PAIRED_MODEL,model)
    print("Warm direct matrix:",np.array(warm["matrix"]),flush=True)
    print("Warm CCT:",warm["source_estimated_cct"],"source /",warm["target_cct"],"HNCS",flush=True)
    print("Warm metrics:",warm["metrics"],flush=True)
    if args.fit_only:return
    # Import after writing the model so the renderer can use its final contents.
    evaluation=[]
    for label,sname,hname in (("training_warm",S_WARM,H_WARM),("held_out_exposure_warm",S_CHECK,H_CHECK)):
        if label=="training_warm":s,t=source,target
        else:s,_=sample(sname,"sony");t,_=sample(hname,"hasselblad")
        src,tgt,swb,twb,scale=normalized_pair(s,t)
        true_cct,_=h.estimate_cct(twb,assets)
        reference=h.output_lab(tgt,true_cct,assets,working_space=base["working_space"])
        modes={}
        for mode in ("calibration","adaptive","dual","paired"):
            if mode=="paired":params=paired.colour_parameters(base,assets,swb,"camera")
            else:params=h.render_colour_parameters(base,assets,swb,"camera",mode)
            prediction=src@np.array(params["matrix"]).T
            lab=h.output_lab(prediction,params["cct"],assets,working_space=base["working_space"])
            de=h.delta_e_2000(lab,reference)
            modes[mode]={"factory_cct":params["cct"],"delta_e00":h.summary(de),"per_patch":de.tolist(),
                         "source_to_target_scale_aligned_with_neutral_blocks":scale}
        evaluation.append({"dataset":label,"source":sname,"target":hname,"reference_factory_cct":true_cct,
            "metrics_scope":"Actual CFA chart responses; independent exposure captures for held_out label; WB/exposure aligned by neutral blocks in each pair. Not an independent scene or Phocus complete RAW comparison.","modes":modes})
        print(label,{k:round(v["delta_e00"]["mean"],5) for k,v in modes.items()},flush=True)
    h.save_json(CASE/"evidence/paired_chart_evaluation.json",{"evaluation":evaluation})


if __name__=="__main__":main()
