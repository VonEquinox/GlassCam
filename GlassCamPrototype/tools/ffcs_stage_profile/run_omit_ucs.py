#!/usr/bin/env python3
"""Optional separate diagnostic. Call after other CPU benchmarks finish."""
import pathlib, subprocess
root=pathlib.Path(__file__).resolve().parents[2]
work=root/'validation/ffcs_stage_profile'
src=(root/'core/ffcs.cpp').read_text();start=src.index('void render(');end=src.index('// Mobile render',start)
r=src[start:end].replace('void render(','void renderOmitUCS(').replace('return ucs(lab(v,ctx.look));','return lab(v,ctx.look);')
(work/'render_omit_ucs.inc').write_text(r)
subprocess.run(['g++','-std=c++17','-O3','-fno-fast-math','-ffp-contract=off','-pthread',str(root/'tools/ffcs_stage_profile/omit_ucs.cpp'),'-o',str(work/'omit_ucs'),'-lz'],check=True)
with (work/'omit_ucs.jsonl').open('w') as out:subprocess.run([str(work/'omit_ucs'),str(root/'ios/GlassCam/Resources/FFCS/xh2s')],stdout=out,check=True)
