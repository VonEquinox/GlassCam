"""Retain the Apple documentation used for device/precision decisions."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import urllib.request

PATHS=["accelerate","accelerate/vdsp","accelerate/vimage","accelerate/bnns","accelerate/bnns-library",
       "metal","metalperformanceshaders","metal/mtlstoragemode/shared",
       "coreml/mlcomputeunits","coreml/mlcomputeunits/cpuandneuralengine",
       "coreml/mlcomputeplan-1w21n","coreml/mlcomputeplan-85vdw",
       "coreml/mlcomputeplandeviceusage","coreml/mlneuralenginecomputedevice",
       "coreml/mlmodelstructure-swift.enum","coreml/mltensor"]


def plain(value):
    if isinstance(value,dict):
        return value.get("text","")+" "+" ".join(plain(v) for k,v in value.items() if k not in ["text","identifier","url"])
    if isinstance(value,list):return " ".join(map(plain,value))
    return ""


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--output-dir",type=Path,required=True);args=parser.parse_args()
    out=args.output_dir.resolve();out.mkdir(parents=True,exist_ok=True)
    def read(path):
        url="https://developer.apple.com/tutorials/data/documentation/"+path+".json"
        try:
            with urllib.request.urlopen(url,timeout=30) as response:data=response.read()
            target=out/(path.replace("/","-")+".json");target.write_bytes(data);document=json.loads(data)
            return {"url":"https://developer.apple.com/documentation/"+path,"data_url":url,
                    "title":document.get("metadata",{}).get("title"),"platforms":document.get("metadata",{}).get("platforms"),
                    "abstract":plain(document.get("abstract",[])).strip(),"discussion":plain(document.get("primaryContentSections",[])).strip(),
                    "sha256":hashlib.sha256(data).hexdigest()}
        except Exception as error:return {"data_url":url,"error":str(error)}
    with ThreadPoolExecutor(max_workers=4) as pool:rows=list(pool.map(read,PATHS))
    (out/"index.json").write_text(json.dumps(rows,indent=2)+"\n")
    print(json.dumps([{"title":r.get("title"),"url":r.get("url"),"error":r.get("error")} for r in rows],indent=2))


if __name__=="__main__":main()
