"""Run exact-structure source matrices through Core ML FP32/FP16 models.

Weights come from the current HNCS context, not training or a color fit. Device
plans are anticipated placement, explicitly distinct from a runtime trace.
No model replaces production code. Run in an isolated coremltools environment.
"""
import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.models.compute_plan import MLComputePlan


def device_name(value):
    return type(value).__name__ if value is not None else None


def plan_rows(plan):
    result=[]
    structure=plan.model_structure
    if structure.program is None:return [{"model_structure":"not-mlprogram"}]
    def visit(block):
        for operation in block.operations:
            usage=plan.get_compute_device_usage_for_mlprogram_operation(operation)
            cost=plan.get_estimated_cost_for_mlprogram_operation(operation)
            result.append({"operation":operation.operator_name,
                           "outputs":[v.name for v in operation.outputs],
                           "preferred":device_name(usage.preferred_compute_device) if usage else None,
                           "supported":[device_name(v) for v in usage.supported_compute_devices] if usage else [],
                           "estimated_cost_weight":float(cost.weight) if cost else None})
            for nested in operation.blocks:visit(nested)
    for function in structure.program.functions.values():visit(function.block)
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases",type=Path,required=True)
    parser.add_argument("--output-dir",type=Path,required=True)
    args=parser.parse_args();out=args.output_dir.resolve();out.mkdir(parents=True,exist_ok=True)
    cases=json.loads(args.cases.read_text())["cases"]
    report={"coremltools":ct.__version__,"available_devices":[device_name(d) for d in ct.models.MLModel.get_available_compute_devices()],
            "source_sha256":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),"runs":[],
            "scope":"Same source-matrix computation at FP32/FP16; one 256x512 synthetic image. No training, fit, LUT replacement or phone call.",
            "placement_limit":"Compute plans predict preferred/supported devices; they are not an Instruments runtime trace."}
    settings=[("cpu_only",ct.ComputeUnit.CPU_ONLY),("cpu_and_gpu",ct.ComputeUnit.CPU_AND_GPU),
              ("cpu_and_neural_engine",ct.ComputeUnit.CPU_AND_NE),("all",ct.ComputeUnit.ALL)]
    for case in cases:
        source=np.load(case["input_file"])
        start=time.perf_counter();planar=np.ascontiguousarray(source.transpose(2,0,1)[None,...]);layout_seconds=time.perf_counter()-start
        matrix=np.asarray(case["matrix"],np.float32)
        for precision,value in [("fp32",ct.precision.FLOAT32),("fp16",ct.precision.FLOAT16)]:
            @mb.program(input_specs=[mb.TensorSpec(shape=planar.shape)],opset_version=ct.target.iOS18)
            def program(source):
                scaled=mb.mul(x=source,y=np.float32(case["exposure_multiplier"]))
                return mb.conv(x=scaled,weight=matrix[:,:,None,None],name="native")
            package=out/(case["name"]+"-"+precision+".mlpackage")
            start=time.perf_counter()
            converted=ct.convert(program,convert_to="mlprogram",minimum_deployment_target=ct.target.iOS18,
                                 compute_precision=value,skip_model_load=True)
            converted.save(str(package));conversion_seconds=time.perf_counter()-start
            for name,units in settings:
                row={"case":case["name"],"precision":precision,"compute_units":name,"package":str(package),
                     "conversion_seconds":conversion_seconds,"layout_conversion_seconds":layout_seconds,
                     "input_bytes":planar.nbytes}
                try:
                    start=time.perf_counter();model=ct.models.MLModel(str(package),compute_units=units)
                    row["load_compile_seconds"]=time.perf_counter()-start
                    start=time.perf_counter()
                    result=model.predict({"source":planar})
                    row["first_prediction_seconds"]=time.perf_counter()-start
                    timings=[]
                    for _ in range(5):
                        start=time.perf_counter();result=model.predict({"source":planar});timings.append(time.perf_counter()-start)
                    key=model.get_spec().description.output[0].name
                    output=out/(case["name"]+"-"+precision+"-"+name+".npy")
                    np.save(output,result[key]);row["output"]=str(output);row["prediction_seconds"]=timings
                    row["output_dtype"]=str(result[key].dtype);row["output_sha256"]=hashlib.sha256(output.read_bytes()).hexdigest()
                    try:
                        plan=MLComputePlan.load_from_path(model.get_compiled_model_path(),compute_units=units)
                        row["compute_plan"]=plan_rows(plan)
                    except Exception as error:row["compute_plan"]=[{"unavailable":str(error)}]
                    row["status"]="predicted"
                except Exception as error:
                    row["status"]="unavailable";row["error"]=str(error)
                report["runs"].append(row)
                (out/"report.json").write_text(json.dumps(report,indent=2)+"\n")
                print(case["name"],precision,name,row["status"],flush=True)


if __name__=="__main__":main()
