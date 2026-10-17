"""Build and measure old/new production pipelines on this Mac only.

The baseline is an explicit saved ffcs.cpp; all other source and build flags
are identical. Runs are serialized to avoid competing measurements. Full
output bytes and first full Float32 decodes must match before speed is used.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

import numpy as np

from audit_x2d_identity import sha


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-source",type=Path,required=True)
    parser.add_argument("--baseline-ffcs",type=Path,required=True)
    parser.add_argument("--output-dir",type=Path,required=True)
    parser.add_argument("--rounds",type=int,default=3,choices=range(1,7))
    parser.add_argument("--build-only",action="store_true")
    parser.add_argument("--collect-only",action="store_true")
    parser.add_argument("--configurations",nargs="+",default=["hncs-standard","hncs-nature","ffcs-provia","ffcs-acros"],
                        choices=["hncs-standard","hncs-nature","ffcs-provia","ffcs-acros"])
    args=parser.parse_args();root=Path(__file__).resolve().parents[1]
    out=args.output_dir.resolve();build=out/"build";build.mkdir(parents=True,exist_ok=True)
    scratch=out/"scratch";scratch.mkdir(exist_ok=True)
    run_environment={**os.environ,"TMPDIR":str(scratch)+"/"}
    swift_names=["ExportSettings.swift","SourceImageStore.swift","PhotoWhiteBalance.swift","HNCSEngine.swift",
                 "FFCSEngine.swift","ImagePipeline.swift","PreviewRaster.swift","CaptureWorkflow.swift"]
    sources=[root/"ios/GlassCam"/name for name in swift_names]
    shared=[root/"core"/name for name in ["hncs.cpp","hncs_spatial.cpp","hncs_numpy_rng.cpp"]]
    manifest={"scope":"Mac only; no camera/phone/Photos calls", "raw_sha256":sha(args.raw_source),"baseline_ffcs_sha256":sha(args.baseline_ffcs),
              "source_sha256":{str(p.relative_to(root)):sha(p) for p in [*sources,*shared,root/"core/ffcs.cpp",Path(__file__),root/"tools/apple_color_performance.swift",
                                  *sorted((root/"core").glob("*.hpp")),*sorted((root/"core").glob("*.h")),*sorted((root/"core").glob("*.inc"))]},"builds":[]}
    if not args.collect_only:
        for variant,ffcs in [("baseline",args.baseline_ffcs.resolve()),("candidate",root/"core/ffcs.cpp")]:
            commands=[["xcrun","clang++","-std=c++17","-O3","-fno-fast-math","-ffp-contract=off","-dynamiclib","-I",str(root/"core"),
                       *map(str,shared),str(ffcs),"-lz","-pthread","-o",str(build/("lib"+variant+".dylib"))],
                      ["xcrun","swiftc","-swift-version","5","-O","-module-cache-path",str(build/"modules"),"-I",str(root/"core"),
                       "-import-objc-header",str(root/"ios/GlassCam/GlassCam-Bridging-Header.h"),*map(str,sources),
                       str(root/"tools/apple_color_performance.swift"),"-L",str(build),"-l"+variant,"-Xlinker","-rpath","-Xlinker",str(build),"-o",str(build/variant)]]
            start=time.perf_counter()
            with (build/(variant+"-build.log")).open("w") as log:
                for command in commands:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
            manifest["builds"].append({"variant":variant,"commands":commands,"seconds":time.perf_counter()-start})
        with (build/"resources.log").open("w") as log:
            subprocess.run(["bash",str(root/"tools/prepare_ffcs_resources.sh"),str(root/"reference_ffcs/source.zip"),str(build/"FFCS")],stdout=log,stderr=subprocess.STDOUT,check=True)
        (out/"build-manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
        if args.build_only:return
        for index,config in enumerate(args.configurations):
            order=["baseline","candidate"] if index%2==0 else ["candidate","baseline"]
            for variant in order:
                print("Measuring "+config+" "+variant,flush=True)
                directory=out/config/variant
                if (directory/"report.json").exists():raise FileExistsError("Refusing to replace prior measurements")
                subprocess.run([str(build/variant),str(args.raw_source.resolve()),str(directory),config,variant,str(args.rounds)],check=True,timeout=900,env=run_environment)
    rows=[]
    for config in args.configurations:
        data={variant:json.loads((out/config/variant/"report.json").read_text()) for variant in ["baseline","candidate"]}
        assert all(d["status"]=="complete" for d in data.values())
        for megapixels in [24,48]:
            samples={key:[r for r in d["captures"] if r["megapixels"]==megapixels] for key,d in data.items()}
            hashes={r["encoded_sha256"] for group in samples.values() for r in group}
            decoded={r["decoded"]["rgba_float32_sha256"] for group in samples.values() for r in group if "decoded" in r}
            if len(hashes)!=1 or len(decoded)!=1:raise AssertionError(f"Output differs: {config}/{megapixels}")
            row={"configuration":config,"megapixels":megapixels,"all_encoded_files_identical":True,"first_full_decodes_identical":True,"variants":{}}
            for variant,group in samples.items():
                timings=[r["total_seconds"] for r in group if not r["cold_or_warmup"]]
                export=[r["seconds"]["full_export"] for r in group if not r["cold_or_warmup"]]
                row["variants"][variant]={"samples":timings,"median":float(np.median(timings)),"minimum":min(timings),"maximum":max(timings),
                                          "full_export_median":float(np.median(export)),"cold":group[0],
                                          "process_peak_rss_bytes":data[variant]["process_peak_rss_bytes_including_verification"]}
            row["speedup"]=row["variants"]["baseline"]["median"]/row["variants"]["candidate"]["median"]
            rows.append(row)
    report={"status":"passed-output-equivalence","rows":rows,
            "limits":["Mac M5 measurements, not iPhone performance; repeated exports of one retained RAW.",
                      "Source rows combine lazy RAW decode, CPU color, transfers and file writes; progress markers are not isolated kernel timers.",
                      "RSS is process high-water including verification; context cache adds a separately bounded 512 KiB.",
                      "Three warm repetitions establish observed medians/ranges, not a latency guarantee."]}
    (out/"summary.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps([{k:r[k] for k in ["configuration","megapixels","speedup","all_encoded_files_identical"]} for r in rows],indent=2))


if __name__=="__main__":main()
