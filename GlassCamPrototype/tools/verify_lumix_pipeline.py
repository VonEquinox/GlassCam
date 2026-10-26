"""Compare the complete portable SDR VE stage with native FilteringLine.

Requires the separately supplied pinned source for generating new oracle data.
Fixtures contain complete 16-bit ramps, random RGB, black and clipping edges.
"""
from pathlib import Path
import argparse
import concurrent.futures
import ctypes as C
import json
import os
import subprocess
import tempfile
import zipfile
import zlib

import numpy as np
from extract_lumix_assets import ROOT, PINNED, sha
from prepare_lumix_resources import prepare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--analysis-root", type=Path, default=ROOT.parent.parent / "LumixAnalyze")
    parser.add_argument("--work", type=Path, default=Path.home() / "Library/Developer/GlassCamDiagnostics/lumix-full-proraw-20261026")
    args = parser.parse_args()
    fw = args.analysis_root / "work/pkg/Installer.pkg/Payload/SILKYPIX Developer Studio 8 SE.app/Contents/Frameworks/SILKYPIX8.framework/Versions/A/SILKYPIX8"
    assert sha(fw.read_bytes()) == PINNED
    work = args.work.resolve(); work.mkdir(parents=True, exist_ok=True)
    report = ROOT / "validation/lumix-full-proraw-20261026"
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    def run(*params): return subprocess.check_output(list(map(str, params)), env=env, text=True)
    run("xcrun", "clang++", "-arch", "x86_64", "-std=c++17", "-O2", ROOT / "tools/probe_lumix_pipeline.cpp", "-o", work / "probe")
    run("xcrun", "clang++", "-std=c++17", "-O2", "-fno-fast-math", "-ffp-contract=off", "-dynamiclib", ROOT / "core/lumix.cpp", "-lz", "-o", work / "liblumix.dylib")
    assets = work / "LUMIX"
    for name in ("source.zip", "pipeline.zip"):
        prepare(ROOT / "reference_lumix" / name, assets)
    manifest = json.loads((assets / "pipeline-manifest.json").read_text())
    for row in manifest["looks"]:
        for key in ("first", "second"):
            asset = row[key]
            raw = work / (asset + ".rgb16")
            if not raw.exists(): raw.write_bytes(zlib.decompress((assets / (asset + ".lmx")).read_bytes()[32:]))
    lib = C.CDLL(str(work / "liblumix.dylib"))
    lib.lumix_create_pipeline.argtypes = [C.c_char_p,C.c_size_t,C.c_double,C.c_int,C.c_int,C.c_int,C.c_char_p,C.c_size_t]
    lib.lumix_create_pipeline.restype = C.c_void_p
    lib.lumix_destroy.argtypes = [C.c_void_p]
    lib.lumix_process_rgb16.argtypes = [C.c_void_p,C.c_void_p,C.c_size_t,C.c_double,C.c_double,C.c_int,C.c_void_p,C.c_char_p,C.c_size_t]
    def render(ctx, values, white, ev, space):
        error = C.create_string_buffer(1024)
        pixels = np.ascontiguousarray(values, dtype=np.uint16); result=np.empty_like(pixels)
        assert lib.lumix_process_rgb16(ctx,pixels.ctypes.data,len(pixels),white,ev,space,result.ctypes.data,error,len(error)),error.value
        return result
    results=[]; worst=0; golden_count=0
    with zipfile.ZipFile(report / "native-full-vectors.zip", "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for look,row in enumerate(manifest["looks"]):
            style=row["photoStyle"]
            # Both native table endpoints plus an interior node mixture. Vary
            # curves, low-ISO corrections, chroma, white scaling, input space, EV.
            cases=[(3000,10,10,100,65535,0,0),(6500,10,10,100,65535,0,0),
                (4000,13,6,[50,64,80][look%3],65535,0,0)]
            if look in (0,3):
                cases += [(4000,0,20,80,16383,0,1),(3000,20,0,64,4095,0,0),
                          (6500,7,15,100,65535,0.5,0),(4000,10,10,50,65535,-1,0)]
            for kelvin,contrast,saturation,iso,white,ev,space in cases:
                name=f"{style}-{kelvin}-{contrast}-{saturation}-{iso}-{white}-{ev}-{space}"
                output=work/(name+".rgb16")
                cube=row["first"] if kelvin>=5000 else row["second"]
                if kelvin==4000: cube=row["first"]
                params=[work/"probe",fw,"line",work/(cube+".rgb16"),output,style,contrast,saturation,iso,white,ev,space]
                if kelvin==4000: params += [work/(row["second"]+".rgb16"),128]
                metadata=json.loads(run(*params));data=output.read_bytes()
                archive.writestr(name+".rgb16",data)
                archive.writestr(name+".json",json.dumps(metadata))
                values=np.frombuffer(data,dtype="<u2").reshape(-1,6)
                error=C.create_string_buffer(1024)
                ctx=lib.lumix_create_pipeline(str(assets).encode(),look,kelvin,contrast,saturation,iso,error,len(error))
                assert ctx,error.value
                actual=render(ctx,values[:,:3],white,ev,space)
                delta=actual.astype(np.int64)-values[:,3:]
                maximum=int(np.max(np.abs(delta)));mismatched=int(np.count_nonzero(np.any(delta,axis=1)))
                if look==0 and kelvin==3000:
                    # Immutable per-context polylines cannot mutate a cached
                    # native segment index; workers must produce identical data.
                    with concurrent.futures.ThreadPoolExecutor(4) as executor:
                        pieces=list(executor.map(lambda p: render(ctx,p,white,ev,space),np.array_split(values[:,:3],4)))
                    assert np.array_equal(np.concatenate(pieces),actual)
                lib.lumix_destroy(ctx)
                result=dict(case=name,nativePixels=len(values),mismatchedPixels=mismatched,maxRGB16Error=maximum)
                results.append(result);golden_count+=len(values);worst=max(worst,maximum)
                print(json.dumps(result),flush=True)
        # Independent original Set3DLUT dispatch verifies the source resources,
        # integer mixture and ISO register choice, outside the FilteringLine port.
        selection=[]
        for selector in (256,384,512):
            output=work/f"set-{selector}.rgb16"
            metadata=json.loads(run(work/"probe",fw,"set",fw.parent/"Resources",output,1,50,selector))
            first=np.fromfile(work/"L00801.rgb16",dtype="<u2").reshape(129,129,129,3)
            second=np.fromfile(work/"L00802.rgb16",dtype="<u2").reshape(129,129,129,3)
            mixed=(first.astype(np.uint32)*(selector-256)+second.astype(np.uint32)*(512-selector))//256
            # Native output is B-fast RGB; extracted cubes are R-fast RGB.
            native=np.fromfile(output,dtype="<u2").reshape(129,129,129,3)
            assert np.array_equal(native,mixed.transpose(2,1,0,3)),f"Set3DLUT mixture {selector}"
            pre=(report/"evidence/low-iso.bin").read_bytes()[196:392]
            assert Path(str(output)+".low-iso").read_bytes()==pre
            selection.append(dict(selector=selector,metadata=metadata,allCubeNodesExact=True,lowISORegistersExact=True))
    error=C.create_string_buffer(1024)
    invalid=[(16,6500,10,10,100),(0,float("nan"),10,10,100),(0,1999,10,10,100),
             (0,6500,21,10,100),(0,6500,10,-1,100),(0,6500,10,10,0)]
    for params in invalid:
        assert not lib.lumix_create_pipeline(str(assets).encode(),*params,error,len(error))
    with tempfile.TemporaryDirectory(prefix="glasscam-lumix-corrupt-") as directory:
        path=Path(directory)/"pipeline.lmp";data=bytearray((assets/"pipeline.lmp").read_bytes())
        data[-100]^=1;path.write_bytes(data)
        assert not lib.lumix_create_pipeline(directory.encode(),0,6500,10,10,100,error,len(error))
        path.unlink()
        assert not lib.lumix_create_pipeline(directory.encode(),0,6500,10,10,100,error,len(error))
    summary=dict(schemaVersion=2,nativeSourceSHA256=PINNED,pixels=golden_count,maxRGB16Error=worst,
        cases=results,selection=selection,concurrentStripsExact=True,invalidSettingsRejected=True,
        corruptAndMissingRegistersRejected=True,vectorsSHA256=sha((report/"native-full-vectors.zip").read_bytes()))
    (report/"native-verification.json").write_text(json.dumps(summary,indent=2)+"\n")
    assert worst==0,f"Complete pipeline maximum RGB16 error {worst}"


if __name__=="__main__":main()
