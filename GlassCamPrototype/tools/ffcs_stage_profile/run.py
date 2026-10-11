#!/usr/bin/env python3
"""Compile and run diagnostic-only C++ stage profiling; never edits production."""
import pathlib, subprocess, hashlib, json, platform, statistics
root = pathlib.Path(__file__).resolve().parents[2]
work = root / 'validation/ffcs_stage_profile'
work.mkdir(exist_ok=True)
src = (root/'core/ffcs.cpp').read_text()
start = src.index('void render(')
end = src.index('// Mobile render', start)
render = src[start:end].replace('void render(', 'void profileRender(')
render = render.replace('transform([&](RGB v){for(auto &x:v)x=encode(x);return mapLUT(ctx,v);});put("lut_3d");', 'transform([&](RGB v){for(auto &x:v)x=encode(x);return v;});put("lut_input_encode");transform([&](RGB v){return mapLUT(ctx,v);});put("lut_sample");')
render = render.replace('transform([&](RGB v){return ucs(lab(v,ctx.look));});put("lab_ucs");', 'transform([&](RGB v){return lab(v,ctx.look);});put("lab");transform([&](RGB v){return ucs(v);});put("ucs");')
render = render.replace('std::vector<double> out(p.size());double strength=', 'std::vector<double> out(p.size());put("sharpen_allocation");double strength=')
assert 'put("lut_input_encode")' in render and 'put("ucs")' in render and 'put("sharpen_allocation")' in render, 'Production stage layout changed; review diagnostic extraction'
(work/'render_instrumented.inc').write_text(render)
flags=['-std=c++17','-O3','-fno-fast-math','-ffp-contract=off','-pthread']
subprocess.run(['g++',*flags,str(root/'tools/ffcs_stage_profile/profile.cpp'),'-o',str(work/'profile'),'-lz'],check=True)
with (work/'raw.jsonl').open('w') as out:
 subprocess.run([str(work/'profile'),str(root/'ios/GlassCam/Resources/FFCS/xh2s')],stdout=out,check=True)
rows=[json.loads(s) for s in (work/'raw.jsonl').read_text().splitlines()]
groups={}
for row in rows:
 key=(row['look'],row['width'],row['height'],row['mode'])
 groups.setdefault(key,[]).append(row)
summary=[]
for key,rs in groups.items():
 stagekeys=rs[0]['stages_ms'].keys()
 summary.append(dict(look=key[0],width=key[1],height=key[2],mode=key[3],runs=len(rs),wall_p50_ms=statistics.median(r['wall_ms'] for r in rs),cpu_p50_ms=statistics.median(r['cpu_ms'] for r in rs),stages_p50_ms={k:statistics.median(r['stages_ms'][k] for r in rs) for k in stagekeys},max_float_error=max(r['max_float_error'] for r in rs),rgba_mismatches=max(r['rgba_mismatches'] for r in rs),common_stages_double_byte_exact=all(r['common_stages_double_byte_exact'] for r in rs)))
env={'cpu':next(x.split(':',1)[1].strip() for x in pathlib.Path('/proc/cpuinfo').read_text().splitlines() if x.startswith('model name')),'platform':platform.platform(),'compiler':subprocess.check_output(['g++','--version'],text=True).splitlines()[0],'flags':flags,'source_sha256':hashlib.sha256(src.encode()).hexdigest(),'warmups':1,'measured_runs':3,'seed':37,'ev':0,'input':'Deterministic linear RGB gradient mixed with hash noise, includes exact zero/one; no IO/RAW decode in timed region','summaries':summary}
(work/'summary.json').write_text(json.dumps(env,indent=2)+'\n')
print(json.dumps(env,indent=2))
