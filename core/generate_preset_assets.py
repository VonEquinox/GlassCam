#!/usr/bin/env python3
"""Losslessly compile revision-8 Phocus preset assets; does not replace base assets.

Run with --source-root pointing at the revision-8 HNCS source checkout. The
postcurve NPZ, all per-payload hashes, configured WB evidence, and original base
asset source are checked before the generated files replace their predecessors.
"""
from pathlib import Path
import argparse, hashlib, importlib.util, json, sys
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source-root', type=Path, default=ROOT/'vendor/hncs')
p.add_argument('--base-assets', type=Path, default=ROOT/'vendor/hncs/work/hncs-pipeline/assets/x2dii_phocus_422.npz')
a = p.parse_args()
spec = importlib.util.spec_from_file_location('revision8_phocus_presets', a.source_root/'phocus_presets.py')
s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)
catalog = s.catalog()
evidence = catalog['binary_evidence']['post_curves']
def require(condition, message):
    if not condition:
        raise ValueError(message)
require(evidence['schema'] == 1 and evidence['factory_configuration_loaded'] is True,
        'Postcurve evidence requires schema 1 and loaded factory configuration')
require(catalog['binary_evidence']['white_balance_presets']['factory_configuration_loaded'] is True,
        'White-balance evidence requires loaded factory configuration')
curves = s.post_curve_tables()  # Includes source SHA, shape, dtype and baseline validation.
require(len(curves) == 6, 'Expected all six native UInt16 postcurve tables')
for name, entry in evidence['source_files'].items():
    require(entry['xml_sha256'] == catalog['source_files'][name]['sha256'], 'XML evidence mismatch: '+name)
expected_base_sha = '3291628ef8787a20082eaebb7e50fccac0a89bbce14dc5619ecf1277d816c1b9'
if hashlib.sha256(a.base_assets.read_bytes()).hexdigest() != expected_base_sha:
    raise ValueError('Unexpected original base asset hash')
base = np.load(a.base_assets, allow_pickle=False)
keys = list(curves)
unique = {}
for key, file in s.FACTORY_SETTING_FILES.items():
    unique.setdefault(file, key)
canonical = list(unique.values())

def literal(x):
    if isinstance(x, bool): return 'true' if x else 'false'
    if isinstance(x, int): return str(x)
    return repr(float(x))
def ar(values): return '{'+','.join(literal(x) for x in values)+'}'
def jstr(value): return json.dumps(value,ensure_ascii=True)

def flags(cfg, mode):
    point = bool(cfg['native_wb_gains'] or cfg['saturation'] or cfg['apply_grayscale'] or mode['active'])
    sharp = bool(cfg['sharpness']['amount'])
    grain = bool(cfg['film_grain']['ApplyFilmGrain'] and cfg['film_grain']['FilmGrainAmount'])
    crop = cfg['crop_aspect_ratio'] == 1.
    sharp_only = sharp and not(point or crop or grain) and cfg['name'] != 'standard'
    return (1 if point else 0)|(2 if crop else 0)|(4 if grain else 0)|(8 if sharp_only else 0)|(16 if sharp else 0)|(32 if not(point or crop or grain or sharp_only) and cfg['name'] != 'standard' else 0)

def mode_of(cfg, record, tone):
    mode = record['modes']['tone' if tone else 'no_tone']; native = mode['native_settings']
    points = bool(tone and any(len(g.get('Points', []))>2 for g in cfg['gradations'] or []))
    gamma = abs(float(native['effective_gamma'])-1.)>1e-7
    contrast = bool(cfg['contrast'] or cfg['brightness'])
    luma = bool(tone and native['luma_point_count']>2)
    return dict(indices=[keys.index(mode['tables'][k]) for k in ('red','green','blue','contrast','luma')],active=points or gamma or contrast or luma,luma=luma,gamma=gamma,points=points,effective_gamma=native['effective_gamma'])

out = ['// Generated losslessly from Phocus render revision 8. Do not edit.',
       '// Postcurve NPZ SHA-256: '+evidence['curves_sha256'],
       '// Catalog SHA-256: '+hashlib.sha256((a.source_root/'work/hncs-pipeline/phocus_presets.json').read_bytes()).hexdigest(),
       'namespace preset_assets {']
for i,key in enumerate(keys):
    values=curves[key]
    require(hashlib.sha256(values.tobytes()).hexdigest()==key[2:], 'Curve content hash mismatch: '+key)
    out += ['// '+key, f'static constexpr uint16_t table_{i}[65536] = {{']
    out += [','.join(str(int(v)) for v in values[j:j+16])+',' for j in range(0,len(values),16)]
    out += ['};']
out += ['static constexpr const uint16_t *tables[6] = {'+','.join(f'table_{i}' for i in range(6))+'};']
out += ['static constexpr uint16_t original_gamma[65536] = {']
values=s.original_gamma_curve()
out += [','.join(str(int(v)) for v in values[j:j+16])+',' for j in range(0,len(values),16)]
out += ['};', 'static constexpr double factory_wb[9] = '+ar(base['factory_wb'].ravel().tolist())+';',
        'struct Mode { int table[5]; bool active, luma; double effective_gamma; };',
        'struct Preset { const char *key, *name, *json; unsigned flags; double cct, saturation; bool grayscale; double gray[3], wb[3]; Mode mode[2]; };']
records=[]
for key in canonical:
    cfg=s.settings(key); rel=s.FACTORY_SETTING_FILES[key]; rec=evidence['source_files'][rel]
    modes=[mode_of(cfg,rec,False),mode_of(cfg,rec,True)]
    f=flags(cfg,modes[1]); name=Path(rel).stem
    if '/' in rel: name=rel[:-4].replace('/',' · ')
    info=dict(cfg,source_file=rel,flags=f,pointwise_supported=not bool(f&12),spatial_implementation='reference portable grain and optional Gaussian USM require the frame-aware spatial API; proprietary Phocus spatial kernels are not recovered',post_curve_modes=modes)
    records.append(info)
    mode_text='{'+','.join('{'+ar(m['indices'])+','+literal(m['active'])+','+literal(m['luma'])+','+literal(m['effective_gamma'])+'}' for m in modes)+'}'
    out += ['static constexpr Preset preset_'+str(len(records)-1)+' = {'+','.join([jstr(key),jstr(name),jstr(json.dumps(info,ensure_ascii=False,separators=(',',':'))),str(f),literal(cfg['color_temperature'] or 0),literal(cfg['saturation'] or 0),literal(bool(cfg['apply_grayscale'])),ar((cfg['grayscale'] or [0,0,0,0])[1:4]),ar(cfg['native_wb_gains'] or [0,0,0]),mode_text])+'};']
out += ['static constexpr const Preset *catalog[] = {'+','.join('&preset_'+str(i) for i in range(len(records)))+'};',
        'struct Alias { const char *key; size_t index; };','static constexpr Alias aliases[] = {']
for key,rel in s.FACTORY_SETTING_FILES.items(): out+=['{'+jstr(key)+','+str(canonical.index(unique[rel]))+'},']
for key,dest in s.FACTORY_SETTING_ALIASES.items(): out+=['{'+jstr(key)+','+str(canonical.index(unique[s.FACTORY_SETTING_FILES[dest]]))+'},']
out += ['};','}']
(ROOT/'core/hncs_preset_assets.inc').write_text('\n'.join(out)+'\n')
(ROOT/'core/hncs_preset_catalog.json').write_text(json.dumps(dict(render_path_revision=8,source_sha256=hashlib.sha256((a.source_root/'phocus_presets.py').read_bytes()).hexdigest(),post_curves_sha256=evidence['curves_sha256'],presets=records),ensure_ascii=False,indent=2)+'\n')
print(f'Generated six exact 65536-entry UInt16 postcurves, original-gamma table, and {len(records)} canonical payload records.')
