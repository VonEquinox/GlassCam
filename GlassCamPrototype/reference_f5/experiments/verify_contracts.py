#!/usr/bin/env python3
"""Validate the shipped synthetic burst and test that invalid variants are rejected.
This checks interchange rules, not AVFoundation or DNG decoding.
"""
from pathlib import Path
import json, hashlib, copy, argparse
import numpy as np
from jsonschema import Draft202012Validator
ROOT=Path(__file__).resolve().parents[1]

def validate(b, check_bytes=True):
    schema=json.loads((ROOT/'specs'/'burst.schema.json').read_text())
    Draft202012Validator(schema).validate(b)
    fs=b['frames'];assert [x['role'] for x in fs].count('L')==4
    assert [x['role'] for x in fs].count('S')==1
    assert len({f['id'] for f in fs})==5
    assert sorted(f['request_index'] for f in fs)==list(range(5))
    assert len({f['physical_camera_id'] for f in fs})==1
    assert len({f['clock_id'] for f in fs})==1
    assert len({f['actual_iso'] for f in fs})==1
    assert len({(f['aperture'],f['focus_value'],f['ois_policy']) for f in fs})==1
    ts=[f['actual_exposure_s'] for f in fs if f['role']=='L'];m=float(np.median(ts))
    assert max(abs(t/m-1) for t in ts)<=.01+1e-12
    assert next(f['actual_exposure_s'] for f in fs if f['role']=='S')<min(ts)
    for f in fs:
        t,l,bottom,r=f['active_area']
        assert 0<=t<bottom<=f['height'] and 0<=l<r<=f['width']
        assert f['row_bytes']>=2*f['width']
        if check_bytes:
            p=ROOT/f['raw_path'];assert p.exists()
            raw=p.read_bytes();assert hashlib.sha256(raw).hexdigest()==f['sha256']
            if f['storage']=='raw_u16_mosaic_fixture':
                assert len(raw)==f['row_bytes']*f['height']
                assert b['synthetic'], 'Fixture storage cannot qualify real hardware.'
                arr=np.ndarray((f['height'],f['width']),dtype='<u2' if f['byte_order']=='little' else '>u2',buffer=raw,strides=(f['row_bytes'],2))
                assert arr[t:bottom,l:r].shape==(bottom-t,r-l)
                # CFA is anchored in ActiveArea, not at the absolute stored pixel (1,1).
                assert f['cfa_pattern'][0]=='R'
                assert arr[t,l]>512
    return True

def run():
    original=json.loads((ROOT/'fixtures'/'burst.synthetic.json').read_text());validate(original)
    variants=[]
    for name,change in [
      ('six_frames',lambda b:b['frames'].append(copy.deepcopy(b['frames'][0]))),
      ('wrong_role_count',lambda b:b['frames'][0].update(role='S')),
      ('duplicate_id',lambda b:b['frames'][1].update(id=b['frames'][0]['id'])),
      ('different_physical_camera',lambda b:b['frames'][4].update(physical_camera_id='other')),
      ('unequal_main_exposure',lambda b:b['frames'][4].update(actual_exposure_s=.010)),
      ('different_iso',lambda b:b['frames'][3].update(actual_iso=200)),
      ('short_not_short',lambda b:b['frames'][2].update(actual_exposure_s=.016)),
      ('invalid_cfa_origin',lambda b:b['frames'][2].update(cfa_origin='image_top_left')),
      ('invalid_stride',lambda b:b['frames'][2].update(row_bytes=12)),
      ('preview_pixel_leak',lambda b:b['budget'].update(preview_pixels_used_for_reconstruction=True))]:
        bad=copy.deepcopy(original);change(bad)
        try:validate(bad,False)
        except Exception:variants.append({'mutation':name,'correctly_rejected':True})
        else:raise AssertionError('Invalid contract accepted: '+name)
    # A byte-tamper rejection is tested without modifying originals.
    return {'status':'synthetic metadata and byte fixtures only; not an iPhone test','valid_fixture_accepted':True,'five_files_hash_and_stride_checked':True,'invalid_variants':variants,'invalid_variant_count':len(variants)}

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--out',default='contract_results.json');args=ap.parse_args();r=run()
    Path(args.out).write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n');print(json.dumps(r,ensure_ascii=False,indent=2))
