"""Reproducible bounded current CPU profile; no Apple/HEIF/device claims.

python tools/bench/benchmark_current_pipeline.py [--collect-only]
Separate-pass HNCS stages change cache/memory behavior: do not sum them or
subtract them to claim exact percentages of fused runtime. FFCS callbacks time
original reference-order passes; optimized row-ring stages are fused instead.
"""
import argparse
import datetime
import hashlib
import json
import os
import platform
import statistics
import subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
FLAGS=['-std=c++17','-O3','-ffp-contract=off','-fno-fast-math','-pthread']
def read_optional(path):
    try:return Path(path).read_text().strip()
    except OSError:return 'unavailable in this execution environment'
def summarize(wall,cpu):
    return dict(wall_ms=wall,cpu_ms=cpu,wall_median_ms=statistics.median(wall),wall_min_ms=min(wall),wall_max_ms=max(wall),cpu_median_ms=statistics.median(cpu),samples=len(wall))
def main():
    output = Path.home() / "Library/Developer/GlassCamDiagnostics/bench"
    output.mkdir(parents=True, exist_ok=True)
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--collect-only',action='store_true');args=parser.parse_args()
    commands=[]
    for kind in ['hncs','ffcs']:
        command=['g++',*FLAGS,str(ROOT/f'tools/bench/profile_{kind}.cpp'),*(['-lz'] if kind=='ffcs' else []),'-o',str(output/f'profile_{kind}')];commands.append(command)
        if not args.collect_only:subprocess.run(command,check=True)
    runs=[('hncs_1mp',[str(output/'profile_hncs'),'1048576']),('hncs_12mp',[str(output/'profile_hncs'),'12000000']),('ffcs_1mp',[str(output/'profile_ffcs'),'vendor/ffcs/implementation/ffcs/data/xh2s'])]
    data={}
    for label,command in runs:
        path=output/f'profile_{label}.jsonl'
        if not args.collect_only:
            with path.open('w') as f:subprocess.run(command,cwd=ROOT,stdout=f,check=True)
        lines=[json.loads(line) for line in path.read_text().splitlines()]
        if label.startswith('hncs'):
            data[label]={'timings':[{**row,**summarize(row['wall_ms'],row['cpu_ms'])} for row in lines if 'name' in row],'checks':[row for row in lines if 'name' not in row]}
        else:
            groups={};checks=[]
            for row in lines:
                if 'verification' in row:checks.append(row);continue
                key=row.get('stage') or f"{row['api']}_{row['workers']}_{row['outputs']}"
                groups.setdefault(key,[]).append(row)
            data[label]={'timings':{key:summarize([r['wall_ms'] for r in rows],[r['cpu_ms'] for r in rows]) for key,rows in groups.items()},'checks':checks}
    paths=['core/hncs.cpp','core/hncs_assets.inc','core/ffcs.cpp','tools/bench/profile_hncs.cpp','tools/bench/profile_ffcs.cpp']
    report={'status':'passed','collected_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'environment':{'platform':platform.platform(),'compiler':subprocess.check_output(['g++','--version'],text=True).splitlines()[0],'cpu':next(line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),'affinity_logical_cpus':sorted(os.sched_getaffinity(0)),'cgroup_membership':read_optional('/proc/self/cgroup'),'cpu_quota':read_optional('/sys/fs/cgroup/cpu.max'),'cpu_throttling':read_optional('/sys/fs/cgroup/cpu.stat'),'memory_limit':read_optional('/sys/fs/cgroup/memory.max'),'build_commands':commands},'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths},'method':{'samples':5,'warmups':1,'input':'Deterministic LCG seed 928, uniform [0,1) linear-sRGB RGB Float32; HNCS EV 0 / 5500 K / legacy standard; FFCS PROVIA EV 0 seed 0. Synthetic pixels, not a photographic performance corpus.','timing':'steady_clock wall time; std::clock process CPU time includes worker threads; allocations and context excluded except context_create_destroy; FFCS baseline internal scratch allocations included. Full-mode tests run in fixed order, not randomized.','hncs_stages':'Separate passes with preallocated double intermediate buffers at 1,048,576 pixels only. Final exact and fast byte results validated against production. Isolated stages have different memory/cache/compiler behavior from fused APIs and are NOT an additive decomposition.','ffcs_stages':'Native callbacks bracket existing reference-order render passes on 1,048,576 linear-input pixels. Matrix stage after gamma_pre; lut_3d includes sRGB OETF. display_decode_float converts encoded results to float linear output. Baseline source conversion/copy and final preview quantization excluded from stage timings.','not_measured':['Apple compilation','iPhone execution','48 MP runtime','decode/RAW demosaic','Swift/Core Image copies','HEIF compression, writing or Photos save','peak RSS','energy or thermal behavior'],'limitations':['Shared CPU host with large CPU and wall-time variation; five samples do not establish stable p95 or a latency guarantee.','Nine visible logical CPUs do not prove nine dedicated cores; cgroup quota/statistics are unavailable.','No timing extrapolation to 48 MP, phone silicon, GPU or ANE.']},'results':data}
    out=output/'current-color-performance.json';out.write_text(json.dumps(report,indent=2)+'\n');print(out)
if __name__=='__main__':main()
