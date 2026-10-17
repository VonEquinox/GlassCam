"""Compare CPU and study-only Metal color using one Mac production executable."""
import argparse
import json
from pathlib import Path
import subprocess
import time

import numpy as np
from audit_x2d_identity import sha


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-source",type=Path,required=True)
    parser.add_argument("--output-dir",type=Path,required=True)
    parser.add_argument("--budget",type=Path,required=True)
    parser.add_argument("--rounds",type=int,default=3,choices=range(1,7))
    parser.add_argument("--collect-only",action="store_true")
    args=parser.parse_args();root=Path(__file__).resolve().parents[1]
    out=args.output_dir.resolve();build=out/"build";build.mkdir(parents=True,exist_ok=True)
    swift=[root/"ios/GlassCam"/name for name in ["ExportSettings.swift","SourceImageStore.swift","PhotoWhiteBalance.swift","HNCSEngine.swift",
                "FFCSEngine.swift","ImagePipeline.swift","PreviewRaster.swift","CaptureWorkflow.swift"]]
    cpp=[root/"tools/metal_hncs_source_bridge.mm",*[root/"core"/name for name in ["hncs_spatial.cpp","hncs_numpy_rng.cpp","ffcs.cpp"]]]
    if not args.collect_only:
        commands=[
            ["xcrun","clang++","-std=c++17","-O3","-fno-fast-math","-ffp-contract=off","-fobjc-arc","-dynamiclib",*map(str,cpp),
             "-framework","Foundation","-framework","Metal","-framework","Accelerate","-lz","-o",str(build/"libstudy.dylib")],
            ["xcrun","swiftc","-swift-version","5","-O","-module-cache-path",str(build/"modules"),"-I",str(root/"core"),
             "-import-objc-header",str(root/"ios/GlassCam/GlassCam-Bridging-Header.h"),*map(str,swift),str(root/"tools/apple_color_performance.swift"),
             "-L",str(build),"-lstudy","-Xlinker","-rpath","-Xlinker",str(build),"-o",str(build/"study")],
            ["xcrun","clang++","-std=c++17","-O3","-fno-fast-math","-ffp-contract=off","-dynamiclib",str(root/"tools/hdr_image_metrics.cpp"),"-o",str(build/"libmetrics.dylib")],
            ["xcrun","swiftc","-O","-parse-as-library","-module-cache-path",str(build/"modules"),"-import-objc-header",str(root/"tools/hdr_image_metrics.h"),
             str(root/"tools/compare_hdr_images.swift"),"-L",str(build),"-lmetrics","-Xlinker","-rpath","-Xlinker",str(build),"-o",str(build/"compare-hdr")]]
        started=time.perf_counter()
        with (build/"build.log").open("w") as log:
            for command in commands:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
        paths=[*swift,*cpp,root/"core/hncs.cpp",root/"tools/apple_color_performance.swift",root/"tools/compare_hdr_images.swift",root/"tools/hdr_image_metrics.cpp",root/"tools/hdr_image_metrics.h",Path(__file__),
               *sorted((root/"core").glob("*.hpp")),*sorted((root/"core").glob("*.h")),*sorted((root/"core").glob("*.inc"))]
        manifest={"build_seconds":time.perf_counter()-started,"commands":commands,"source_sha256":{str(p.relative_to(root)):sha(p) for p in paths},
                  "raw_sha256":sha(args.raw_source),"budget_sha256":sha(args.budget),
                  "scope":"Same executable and flags; selector chooses CPU Double or GPU Float32 native color, CPU gradation/USM/display and common RAW/HEIF."}
        (out/"build-manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
        for index,config in enumerate(["hncs-standard","hncs-nature"]):
            for variant in (["baseline","metal-color"] if index==0 else ["metal-color","baseline"]):
                directory=out/config/variant
                if (directory/"report.json").exists():raise FileExistsError("Refusing to replace prior performance results")
                subprocess.run([str(build/"study"),str(args.raw_source.resolve()),str(directory),config,variant,str(args.rounds)],check=True,timeout=900)
    budget=json.loads(args.budget.read_text());rows=[]
    for config in ["hncs-standard","hncs-nature"]:
        reports={v:json.loads((out/config/v/"report.json").read_text()) for v in ["baseline","metal-color"]}
        assert all(r["status"]=="complete" for r in reports.values())
        assert reports["metal-color"]["metal_study"]["color_calls"]>0
        for megapixels in [24,48]:
            samples={v:[r for r in d["captures"] if r["megapixels"]==megapixels] for v,d in reports.items()}
            a=Path(samples["baseline"][0]["file"]);b=Path(samples["metal-color"][0]["file"])
            metric=out/config/f"hdr-{megapixels}mp.json"
            if not metric.exists():subprocess.run([str(build/"compare-hdr"),str(a),str(b),str(metric)],check=True,timeout=900)
            error=json.loads(metric.read_text())
            peak_error=abs(error["actual_peak_rgb_nits"]-error["reference_peak_rgb_nits"])/error["reference_peak_rgb_nits"]
            accepted=all(error[key+"_deltaEITP"]<=value for key,value in budget["candidate_HDR_deltaEITP"].items())
            accepted=accepted and peak_error<=budget["hdr_peak_relative_error_max"] and error["additional_black_channels"]==0 and error["additional_white_channels"]==0
            row={"configuration":config,"megapixels":megapixels,"hdr":error,"hdr_budget_passed":accepted,"peak_relative_error":peak_error,"variants":{}}
            for variant,group in samples.items():
                values=[r["total_seconds"] for r in group if not r["cold_or_warmup"]]
                row["variants"][variant]={"seconds":values,"median":float(np.median(values)),"minimum":min(values),"maximum":max(values),
                                          "cold":group[0],"peak_rss_bytes":reports[variant]["process_peak_rss_bytes_including_verification"]}
            row["speedup"]=row["variants"]["baseline"]["median"]/row["variants"]["metal-color"]["median"]
            rows.append(row)
    (out/"summary.json").write_text(json.dumps({"rows":rows,"budget":budget,"status":"measured-candidate-not-deployed"},indent=2)+"\n")
    print(json.dumps([{k:r[k] for k in ["configuration","megapixels","speedup","hdr_budget_passed"]} for r in rows],indent=2))


if __name__=="__main__":main()
