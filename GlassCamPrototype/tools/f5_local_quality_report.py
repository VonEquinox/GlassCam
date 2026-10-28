"""Compare fixed local-registration/frequency candidates with all Lucky variants."""
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
    args.output.mkdir(parents=True, exist_ok=True)
    assets=args.output/'images';assets.mkdir(exist_ok=True)
    cases=[];synthetic=[];real=[]

    def asset(label, name, image, matrix, exposure=1):
        path=assets/f'{label}-{name}.png'
        preview(image,matrix,path,maximum=image.shape[0],exposure=exposure)
        return 'images/'+path.name

    for group in ['synthetic','independent-parameters']:
        for name in ['constant_color','chromatic_texture','shadow','color_edge']:
            folder=args.work/'candidate-v3'/group/name
            path=folder/'candidate-v3'/f'{name}-metal-report.json'
            report,native=read_rgb(path);_,filtered=read_rgb(path,'denoised_native_rgb')
            truth=np.load(folder/'truth.npy')
            competitors={p.stem:metrics(np.load(p),truth) for p in sorted(folder.glob('lucky*.npy'))}
            strongest=min(competitors,key=lambda k:competitors[k]['rmse'])
            before=metrics(native,truth);after=metrics(filtered,truth)
            synthetic.append(dict(group=group,scene=name,input_sha256=report['input_sha256'],report_sha256=sha(path),
                shader_sha256=report['shader_sha256'],executable_sha256=report['executable_sha256'],
                native=before,filtered=after,competitors=competitors,best_lucky_by_rmse=strongest,
                native_to_best_lucky_rmse=before['rmse']/competitors[strongest]['rmse'],
                filtered_to_best_lucky_rmse=after['rmse']/competitors[strongest]['rmse'],
                negative_components=int(np.count_nonzero(filtered<0)),stop=report['native_stop'],
                converged=report['native_stop']=='CONVERGED',seconds=report['seconds'],
                filter_seconds=report['denoised_native_rgb']['seconds'],truth_sha256=sha(folder/'truth.npy')))
            label=group+'-'+name
            variants={k:asset(label,k,np.load(folder/(k+'.npy')),np.eye(3)) for k in competitors}
            cases.append(dict(label=label,lucky=variants,default_lucky=strongest,
                native=asset(label,'native',native,np.eye(3)),filtered=asset(label,'filtered',filtered,np.eye(3)),
                truth=asset(label,'truth',truth,np.eye(3)),previous=None,
                note=f"{report['native_stop']} · 解析开发场景 · 所有场景使用同一候选参数"))

    prep=json.loads(args.preparation.read_text());matrix=np.array(prep['matrix_camera_to_linear_srgb'])
    for roi in prep['rois']:
        name=roi['name'];path=args.work/'candidate-v3/real'/name/f'{name}-metal-report.json'
        report,native=read_rgb(path);_,filtered=read_rgb(path,'denoised_native_rgb')
        old_path=args.previous_work/'candidate-v2'/name/f'{name}-metal-report.json';old,previous=read_rgb(old_path)
        lucky_paths=sorted((args.preparation.parent/'lucky-bm3d').glob(f'{name}-lucky-bm3d*.npy'))
        real.append(dict(scene=name,input_sha256=report['input_sha256'],report_sha256=sha(path),
            previous_report_sha256=sha(old_path),shader_sha256=report['shader_sha256'],
            native_rgb_sha256=report['native_rgb']['sha256'],filtered_rgb_sha256=report['denoised_native_rgb']['sha256'],
            lucky_sha256={p.stem:sha(p) for p in lucky_paths},truth_available=False,
            negative_components=int(np.count_nonzero(filtered<0)),stop=report['native_stop'],seconds=report['seconds'],
            filter_seconds=report['denoised_native_rgb']['seconds']))
        for exposure in ([1,8] if name=='flat_dark' else [1]):
            label=f'real-{name}-exposure-{exposure}'
            variants={p.stem:asset(label,p.stem,upsample(np.load(p)),matrix,exposure) for p in lucky_paths}
            cases.append(dict(label=label,lucky=variants,default_lucky=f'{name}-lucky-bm3d-1-64',
                native=asset(label,'native',native,matrix,exposure),filtered=asset(label,'filtered',filtered,matrix,exposure),
                previous=asset(label,'previous',previous,matrix,exposure),truth=None,
                note=f"{report['native_stop']} · 实拍局部 · 相同曝光 ×{exposure} · 无独立真值"))

    report=dict(revision='f5-local-frequency-review-v3',camera_used=False,JSR_networks_used=False,
        policy='local-frequency-candidate-policy.json',synthetic_results=synthetic,real_results=real,
        goal_complete=False,qualification='UNQUALIFIED_DIAGNOSTIC',
        limitations=['The two analytic sets belong to the same scene family and are development data.',
            'Real results are selected crops from one retained burst; no blind human preference evidence.',
            'The variance approximation does not propagate reconstruction covariance.',
            'The final image is a native reconstruction with common 2x interpolation, not accepted super-resolution.',
            'Joint convergence and full-pipeline phone performance remain unaccepted.'])
    dump(args.output/'comparison.json',report)
    if args.summary:dump(args.summary,report)
    data=json.dumps(cases,ensure_ascii=False).replace('</','<\\/')
    page='''<!doctype html><html lang="zh"><meta charset="utf-8"><title>F5 轻量算法放大对照</title>
<style>body{font:15px system-ui;background:#171b20;color:#e8edf2;margin:24px}header{position:sticky;top:0;background:#171b20;padding:12px 0;z-index:1}select,button{font:inherit;padding:7px;margin:4px}#panels{display:flex;gap:18px;align-items:start}figure{margin:0}figcaption{margin:10px 0}img{image-rendering:pixelated;max-width:none;border:1px solid #535c68}p{max-width:1050px;line-height:1.6}.note{color:#a9b7c8}#status{color:#e8bb76}</style>
<header><strong>F5：局部配准与轻量频域降噪</strong><p class="note">按输出像素放大查看，所有图片使用相同曝光、色彩矩阵与显示曲线。可切换全部六种 Lucky 对照。当前结果用于算法开发，尚未证明完整超分、所有场景画质或手机性能通过。</p>
<label>场景 <select id="case"></select></label><label>Lucky <select id="lucky"></select></label><label>放大 <select id="zoom"><option value="1">100%</option><option value="2">200%</option><option selected value="4">400%</option><option value="8">800%</option></select></label><button id="swap">交换左右</button><p id="status"></p></header><div id="panels"></div>
<script>const cases=DATA;let swapped=false;const c=document.querySelector('#case'),b=document.querySelector('#lucky'),z=document.querySelector('#zoom');cases.forEach((v,i)=>{const o=document.createElement('option');o.value=i;o.textContent=v.label;c.append(o)});function draw(){const v=cases[+c.value],p=document.querySelector('#panels');p.replaceChildren();document.querySelector('#status').textContent=v.note;let images=[['Lucky：所选后处理',v.lucky[b.value]],['F5：局部配准＋频域降噪',v.filtered],['F5：频域降噪之前',v.native]];if(swapped)images.reverse();if(v.previous)images.push(['F5：上一版全局配准',v.previous]);if(v.truth)images.push(['独立解析真值',v.truth]);for(const [label,url] of images){const f=document.createElement('figure'),t=document.createElement('figcaption'),i=document.createElement('img');t.textContent=label;i.src=url;i.onload=()=>{i.style.width=i.naturalWidth*+z.value+'px';i.style.height=i.naturalHeight*+z.value+'px'};f.append(t,i);p.append(f)}}function choose(){const v=cases[+c.value];b.replaceChildren();for(const key of Object.keys(v.lucky)){const o=document.createElement('option');o.value=key;o.textContent=key;b.append(o)}b.value=v.default_lucky;draw()}c.onchange=choose;b.onchange=z.onchange=draw;document.querySelector('#swap').onclick=()=>{swapped=!swapped;draw()};choose();</script></html>'''.replace('DATA',data)
    (args.output/'review.html').write_text(page)
    # A compact artifact permits direct visual inspection without browser state.
    picked=[v for v in cases if v['previous'] and not v['label'].endswith('exposure-1') or v['label'] in ['real-texture_left-exposure-1','real-texture_right-exposure-1','real-moving_subject-exposure-1']]
    sheet=Image.new('RGB',(4*276,len(picked)*300),(24,28,34));draw=ImageDraw.Draw(sheet)
    for row,v in enumerate(picked):
        for col,(label,path) in enumerate([('Lucky',v['lucky'][v['default_lucky']]),('Previous F5',v['previous']),('Local geometry',v['native']),('Local geometry + DCT',v['filtered'])]):
            im=Image.open(args.output/path).resize((256,256),Image.Resampling.NEAREST)
            draw.text((col*276+8,row*300+5),label,fill='white');sheet.paste(im,(col*276+8,row*300+24))
        draw.text((8,row*300+282),v['label'],fill='white')
    sheet.save(args.output/'real-contact.png')
    for r in synthetic:print(r['group'],r['scene'],round(r['filtered_to_best_lucky_rmse'],4),r['stop'])
    print(args.output/'review.html')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--work',type=Path,required=True);p.add_argument('--previous-work',type=Path,required=True)
    p.add_argument('--preparation',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--summary',type=Path)
    create(p.parse_args())
