"""Bounded CPU exact-Float benchmark; --collect-only summarizes existing raw JSONL."""
import argparse, datetime, hashlib, json, os, platform, statistics, subprocess
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from native_build import build_command, build_product, binary_directory
ROOT=Path(__file__).resolve().parents[2]
def read(path):
    try:return Path(path).read_text().strip()
    except OSError:return 'unavailable'
def main():
    output = Path.home() / "Library/Developer/GlassCamDiagnostics/bench"
    output.mkdir(parents=True, exist_ok=True)
    p=argparse.ArgumentParser();p.add_argument('--collect-only',action='store_true');a=p.parse_args()
    command=build_command('benchmark_lowres_color')
    raw=output/'lowres-color-raw.jsonl'
    if not a.collect_only:
        build_product('benchmark_lowres_color')
        with raw.open('w') as f:subprocess.run([str(binary_directory()/'benchmark_lowres_color'),'vendor/ffcs/implementation/ffcs/data/xh2s'],cwd=ROOT,stdout=f,check=True)
    rows=[json.loads(x) for x in raw.read_text().splitlines()];assert len(rows)==225, len(rows)
    groups={}
    for row in rows:groups.setdefault((row['pipeline'],row['width'],row['height'],row['requested_workers']),[]).append(row)
    assert len(groups)==45
    results=[]
    for (pipeline,w,h,workers),samples in groups.items():
        assert len(samples)==5 and {s['sample'] for s in samples}==set(range(5)) and all(s['oracle_equal'] for s in samples)
        assert len({s['fnv1a64'] for s in samples})==1
        wall=[s['wall_seconds'] for s in samples];cpu=[s['cpu_seconds'] for s in samples]
        wm=statistics.median(wall);cm=statistics.median(cpu)
        results.append(dict(pipeline=pipeline,width=w,height=h,requested_workers=workers,effective_workers=samples[0]['effective_workers'],samples=5,wall_p50_ms=wm*1000,wall_min_ms=min(wall)*1000,wall_max_ms=max(wall)*1000,cpu_p50_ms=cm*1000,cpu_min_ms=min(cpu)*1000,cpu_max_ms=max(cpu)*1000,kernel_only_fps_p50=1/wm,kernel_only_fps_slowest_sample=1/max(wall),cpu_core_percent_at_15fps=cm*15*100,cpu_core_percent_at_30fps=cm*30*100,wall_p50_meets_60fps=wm<=1/60,wall_p50_meets_30fps=wm<=1/30,wall_p50_meets_15fps=wm<=1/15,hash=samples[0]['fnv1a64']))
    for pipeline in ('HNCS_exact_float','FFCS_PROVIA_full','FFCS_ACROS_full'):
        for w in (128,256,512,1280,1920):assert len({r['hash'] for r in results if r['pipeline']==pipeline and r['width']==w})==1
    paths=['Packages/GlassCamKit/Sources/CHNCS/hncs.cpp','Packages/GlassCamKit/Sources/CHNCS/generated/hncs_assets.inc','Packages/GlassCamKit/Sources/CFFCS/ffcs.cpp','Packages/GlassCamKit/NativeTools/benchmark_lowres_color/benchmark_lowres_color.cpp']
    report=dict(status='passed',collected_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),environment=dict(platform=platform.platform(),compiler=subprocess.check_output(['swift','--version'],text=True).splitlines()[0],cpu=next(x.split(':',1)[1].strip() for x in Path('/proc/cpuinfo').read_text().splitlines() if x.startswith('model name')),affinity_logical_cpus=sorted(os.sched_getaffinity(0)),cpu_quota=read('/sys/fs/cgroup/cpu.max'),cpu_throttling=read('/sys/fs/cgroup/cpu.stat'),cgroup=read('/proc/self/cgroup'),build_command=command),source_sha256={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths},method=dict(warmup_calls_per_configuration=1,samples=5,order='Recorded run sizes: 256x144, 512x288, 1280x720, 1920x1080; then a separate 128x72 supplement. For each size: oracle, one warmup per configuration, then five rounds rotating all nine pipeline/worker configurations by two positions per round. A fresh default reproduction includes all five sizes starting with 128x72.',input='LCG seed 928 uniform [0,1) Float32 linear sRGB; EV 0; HNCS 5500 K legacy/standard; FFCS seed 0. Synthetic test, not photographic corpus.',output='HNCS display-linear RGBA Float32; FFCS display-linear RGB Float32, no optional RGBA8 output.',timing='steady_clock wall seconds plus CLOCK_PROCESS_CPUTIME_ID CPU seconds including all worker threads. Timing includes production API validation, per-call thread creation/join and internal scratch allocation; excludes contexts, input/output allocation, hashes and oracle.',correctness='Every warmup and measured result FNV-1a 64-bit matches its same-size serial production oracle; hashes equal across 1/2/4 workers. Hash checks are not an independent algorithm proof.',cpu_percent='CPU seconds per frame × requested fps × 100; 100%=one fully occupied CPU core. Hypothetical demand at a requested cadence, not actual achievable cadence; wall time independently limits admission.',limitations=['Shared cloud host is variable; five samples do not establish p95 or steady-state sustained cadence.','Logical CPU affinity is not dedicated cores; CPU quota/throttling unavailable.','No iPhone runtime, device CPU percentage, power or thermal inference.','Camera/RAW decode, demosaic, resizing, Swift/Core Image copies, Metal upload/render and display synchronization are excluded.','No measured 12MP/48MP or extrapolated value in this run.','Actual default PROVIA and ACROS both include grain and sharpening; tone shoulder/toe is not a separately implemented DR100/200/400 mode.']),results=sorted(results,key=lambda r:(r['width'],r['pipeline'],r['requested_workers'])))
    out=output/'lowres-color-performance.json';out.write_text(json.dumps(report,indent=2)+'\n');print(out)
if __name__=='__main__':main()
