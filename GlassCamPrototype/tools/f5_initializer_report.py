"""Persist initializer, texture-protection and independent-content comparisons."""
from pathlib import Path
import argparse
import json

import numpy as np
from PIL import Image, ImageDraw

from f5_lucky_baseline import upsample
from f5_quality_benchmark import metrics
from f5_quality_report import read_rgb
from f5_real_quality import dump, preview, sha


def create(args):
    args.output.mkdir(parents=True,exist_ok=True);assets=args.output/'images';assets.mkdir(exist_ok=True)
    rows=[];views=[];real=[]
    candidate_root=args.candidate_root or args.work/'detail-protection'
    groups={'synthetic':['constant_color','chromatic_texture','shadow','color_edge'],
        'independent-parameters':['constant_color','chromatic_texture','shadow','color_edge'],
        'natural':['portrait','fur','brick','dark_fur']}
    def save(label,variant,image,matrix,exposure=1):
        path=assets/f'{label}-{variant}.png';preview(image,matrix,path,maximum=image.shape[0],exposure=exposure)
        return 'images/'+path.name
    for group,names in groups.items():
        for name in names:
            base=(args.work/'natural'/name) if group=='natural' else args.work/'quality'/group/name
            original=base/'detail-init'/f'{name}-metal-report.json'
            protected=candidate_root/group/name/f'{name}-metal-report.json'
            d,native=read_rgb(protected);_,filtered=read_rgb(protected,'denoised_native_rgb');_,initial=read_rgb(protected,'initial_rgb')
            original_report,unprotected=read_rgb(original,'denoised_native_rgb');truth=np.load(base/'truth.npy')
            competitors={p.stem:metrics(np.load(p),truth) for p in sorted(base.glob('lucky*.npy'))}
            best=min(competitors,key=lambda k:competitors[k]['rmse']);best_error=competitors[best]['rmse']
            row=dict(group=group,scene=name,input_sha256=d['input_sha256'],report_sha256=sha(protected),
                shader_sha256=d['shader_sha256'],executable_sha256=d['executable_sha256'],truth_sha256=sha(base/'truth.npy'),
                initial=metrics(initial,truth),native=metrics(native,truth),filtered=metrics(filtered,truth),
                unprotected=metrics(unprotected,truth),competitors=competitors,best_lucky_by_rmse=best,
                native_to_best_lucky_rmse=metrics(native,truth)['rmse']/best_error,
                filtered_to_best_lucky_rmse=metrics(filtered,truth)['rmse']/best_error,
                unprotected_to_best_lucky_rmse=metrics(unprotected,truth)['rmse']/best_error,
                stop=d['native_stop'],seconds=d['seconds'],initializer_fraction=d['cardinal_initialization_fraction'],
                negative_components=int(np.count_nonzero(filtered<0)))
            fixed=args.work/'fixed-geometry/natural'/name/f'{name}-metal-report.json'
            if group=='natural' and fixed.exists():
                q,a=read_rgb(fixed,'denoised_native_rgb');row['known_geometry_control']=dict(metrics=metrics(a,truth),stop=q['native_stop'],seconds=q['seconds'])
            rows.append(row);label=group+'-'+name
            previous=(args.previous_root or args.work/'detail-protection')/group/name/f'{name}-metal-report.json'
            if args.candidate_root and previous.exists():
                q,b=read_rgb(previous,'denoised_native_rgb')
                row['previous_candidate']=dict(metrics=metrics(b,truth),rmse_ratio=metrics(b,truth)['rmse']/best_error,stop=q['native_stop'],seconds=q['seconds'],report_sha256=sha(previous))
            variants={p.stem:save(label,p.stem,np.load(p),np.eye(3)) for p in sorted(base.glob('lucky*.npy'))}
            views.append(dict(label=label,lucky=variants,default_lucky=best,native=save(label,'native',native,np.eye(3)),
                filtered=save(label,'filtered',filtered,np.eye(3)),truth=save(label,'truth',truth,np.eye(3)),
                note=f"{d['native_stop']} · 合成 RAW；自然内容组也不是实拍 RAW 真值 · RMSE/Lucky={row['filtered_to_best_lucky_rmse']:.3f}"))
    if args.extra_base:
        if not args.extra_candidate or not args.extra_previous:
            raise ValueError('Additional natural cases require both candidate and previous render roots')
        manifest=json.loads((args.extra_base/'manifest.json').read_text())
        for case in manifest['cases']:
            name=case['name'];base=args.extra_base/name;path=args.extra_candidate/name/f'{name}-metal-report.json'
            previous=args.extra_previous/name/f'{name}-metal-report.json'
            d,native=read_rgb(path);_,filtered=read_rgb(path,'denoised_native_rgb');q,old=read_rgb(previous,'denoised_native_rgb')
            truth=np.load(base/'truth.npy');competitors={p.stem:metrics(np.load(p),truth) for p in sorted(base.glob('lucky*.npy'))}
            best=min(competitors,key=lambda k:competitors[k]['rmse']);best_error=competitors[best]['rmse']
            row=dict(group='extended-natural',scene=name,input_sha256=d['input_sha256'],report_sha256=sha(path),
                shader_sha256=d['shader_sha256'],executable_sha256=d['executable_sha256'],truth_sha256=sha(base/'truth.npy'),
                native=metrics(native,truth),filtered=metrics(filtered,truth),competitors=competitors,best_lucky_by_rmse=best,
                native_to_best_lucky_rmse=metrics(native,truth)['rmse']/best_error,
                filtered_to_best_lucky_rmse=metrics(filtered,truth)['rmse']/best_error,stop=d['native_stop'],seconds=d['seconds'],
                negative_components=int(np.count_nonzero(filtered<0)),previous_candidate=dict(metrics=metrics(old,truth),
                    rmse_ratio=metrics(old,truth)['rmse']/best_error,stop=q['native_stop'],seconds=q['seconds'],report_sha256=sha(previous)))
            rows.append(row);label='extended-natural-'+name
            views.append(dict(label=label,lucky={p.stem:save(label,p.stem,np.load(p),np.eye(3)) for p in sorted(base.glob('lucky*.npy'))},
                default_lucky=best,native=save(label,'native',native,np.eye(3)),filtered=save(label,'filtered',filtered,np.eye(3)),
                truth=save(label,'truth',truth,np.eye(3)),note=f"{d['native_stop']} · 固定参数后的新增内容，模拟 RAW · RMSE/Lucky={row['filtered_to_best_lucky_rmse']:.3f}"))
    prep=json.loads(args.preparation.read_text());matrix=np.array(prep['matrix_camera_to_linear_srgb'])
    for roi in prep['rois']:
        name=roi['name'];path=candidate_root/'real'/name/f'{name}-metal-report.json'
        d,native=read_rgb(path);_,filtered=read_rgb(path,'denoised_native_rgb')
        paths=sorted((args.preparation.parent/'lucky-bm3d').glob(f'{name}-lucky-bm3d*.npy'))
        real.append(dict(scene=name,report_sha256=sha(path),input_sha256=d['input_sha256'],stop=d['native_stop'],seconds=d['seconds'],
            truth_available=False,native_rgb_sha256=d['native_rgb']['sha256'],filtered_rgb_sha256=d['denoised_native_rgb']['sha256'],
            lucky_sha256={p.stem:sha(p) for p in paths},negative_components=int(np.count_nonzero(filtered<0))))
        for exposure in ([1,8] if name=='flat_dark' else [1]):
            label=f'real-{name}-exposure-{exposure}'
            views.append(dict(label=label,lucky={p.stem:save(label,p.stem,upsample(np.load(p)),matrix,exposure) for p in paths},
                default_lucky=f'{name}-lucky-bm3d-1-64',native=save(label,'native',native,matrix,exposure),
                filtered=save(label,'filtered',filtered,matrix,exposure),truth=None,note=f"{d['native_stop']} · 实拍裁切，相同曝光 ×{exposure}；无独立真值"))
    controls={}
    for label in ['linear','cfa','cfa-spectrum','rgb-spectrum','natural-rgb-spectrum','natural-cfa-spectrum']:
        path=args.work/label/'comparison.json'
        if path.exists():controls[label]=json.loads(path.read_text())
    report=dict(revision='f5-lightweight-candidate-review-v5' if args.candidate_root else 'f5-detail-initialization-review-v1',camera_used=False,qualification='UNQUALIFIED_DIAGNOSTIC',goal_complete=False,
        policy=args.policy,synthetic_results=rows,real_results=real,linear_controls=controls,
        limitations=['Fixed 5x5 initializer and raw-green texture gate are development options, not product defaults.',
            'Natural photographs are simulated into RAW with known geometry, not external real-RAW validation.',
            'Linear fusion controls lack occlusion certification and do not replace F5.',
            'Native results are sampled with common 2x interpolation; no accepted super-resolution advantage.',
            'Joint convergence, blind review, broad real coverage and full-pipeline phone performance remain incomplete.'])
    dump(args.output/'comparison.json',report)
    if args.summary:dump(args.summary,report)
    data=json.dumps(views,ensure_ascii=False).replace('</','<\\/')
    page='''<!doctype html><html lang="zh"><meta charset="utf-8"><title>F5 画质对照</title><style>body{background:#171b20;color:#e8edf2;font:15px system-ui;margin:24px}header{position:sticky;top:0;background:#171b20;padding:12px 0}select,button{font:inherit;padding:7px;margin:4px}#panels{display:flex;gap:18px;align-items:start}figure{margin:0}figcaption{margin:10px 0}img{image-rendering:pixelated;max-width:none;border:1px solid #535c68}p{max-width:1000px;line-height:1.6}.note{color:#a9b7c8}#status{color:#e8bb76}</style>
<header><strong>F5 画质对照</strong><p class="note">相同输出尺寸、曝光和显示曲线，按像素放大。可切换全部六种 Lucky 后处理。尚未完成实拍画质、完整超分或手机性能验收。</p><label>场景 <select id="case"></select></label><label>Lucky <select id="lucky"></select></label><label>放大 <select id="zoom"><option value="1">100%</option><option value="2">200%</option><option selected value="4">400%</option><option value="8">800%</option></select></label><button id="swap">交换左右</button><p id="status"></p></header><div id="panels"></div>
<script>const cases=DATA;let swapped=false;const c=document.querySelector('#case'),b=document.querySelector('#lucky'),z=document.querySelector('#zoom');cases.forEach((v,i)=>{const o=document.createElement('option');o.value=i;o.textContent=v.label;c.append(o)});function draw(){const v=cases[+c.value],p=document.querySelector('#panels');p.replaceChildren();document.querySelector('#status').textContent=v.note;let images=[['Lucky：所选后处理',v.lucky[b.value]],['F5：原生融合',v.native],['F5：附加频域降噪',v.filtered]];if(swapped)images.reverse();if(v.truth)images.push(['独立模拟真值',v.truth]);for(const [label,url] of images){const f=document.createElement('figure'),t=document.createElement('figcaption'),i=document.createElement('img');t.textContent=label;i.src=url;i.onload=()=>{i.style.width=i.naturalWidth*+z.value+'px';i.style.height=i.naturalHeight*+z.value+'px'};f.append(t,i);p.append(f)}}function choose(){const v=cases[+c.value];b.replaceChildren();for(const key of Object.keys(v.lucky)){const o=document.createElement('option');o.value=key;o.textContent=key;b.append(o)}b.value=v.default_lucky;draw()}c.onchange=choose;b.onchange=z.onchange=draw;document.querySelector('#swap').onclick=()=>{swapped=!swapped;draw()};choose();</script></html>'''.replace('DATA',data)
    (args.output/'review.html').write_text(page)
    natural=[v for v in views if v['label'].startswith('natural-')]
    sheet=Image.new('RGB',(1104,300*len(natural)),(24,28,34));draw=ImageDraw.Draw(sheet)
    for row,v in enumerate(natural):
        for col,(label,path) in enumerate([('Truth',v['truth']),('Lucky',v['lucky'][v['default_lucky']]),('F5 native',v['native']),('F5 filtered',v['filtered'])]):
            im=Image.open(args.output/path).resize((256,256),Image.Resampling.NEAREST);sheet.paste(im,(col*276+8,row*300+24));draw.text((col*276+8,row*300+5),label,fill='white')
        draw.text((8,row*300+282),v['label'],fill='white')
    sheet.save(args.output/'natural-contact.png')
    for r in rows:print(r['group'],r['scene'],round(r['filtered_to_best_lucky_rmse'],4),r['stop'])
    print(args.output/'review.html')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--work',type=Path,required=True)
    p.add_argument('--preparation',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--candidate-root',type=Path);p.add_argument('--policy',default='detail-initialization-candidate-policy.json')
    p.add_argument('--previous-root',type=Path)
    p.add_argument('--extra-base',type=Path);p.add_argument('--extra-candidate',type=Path);p.add_argument('--extra-previous',type=Path)
    p.add_argument('--summary',type=Path);create(p.parse_args())
