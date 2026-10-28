"""Persist F5 development comparisons and a local pixel-zoom review page."""
from pathlib import Path
import argparse
import json

import numpy as np

from f5_lucky_baseline import upsample
from f5_quality_benchmark import metrics
from f5_real_quality import dump, preview, sha


def read_rgb(report_path, key="native_rgb"):
    report=json.loads(report_path.read_text());d=report[key];path=report_path.parent/d['path']
    if sha(path)!=d['sha256']:raise ValueError('Rendered RGB changed')
    return report,np.fromfile(path,dtype='<f4').reshape(d['height'],d['width'],d['channels'])[...,:3]


def create(args):
    args.output.mkdir(parents=True,exist_ok=True)
    assets=args.output/'images';assets.mkdir(exist_ok=True)
    rows=[];view=[]
    for group,folder,run_name in [('development','synthetic',None),('changed_scene_parameters','independent-parameters','candidate-v2')]:
        for name in ['constant_color','chromatic_texture','shadow','color_edge']:
            base=args.work/folder/name
            path=(base/run_name if run_name else args.work/'candidate-v2'/name)/f'{name}-metal-report.json'
            report,image=read_rgb(path);truth=np.load(base/'truth.npy')
            competitors={p.stem:metrics(np.load(p),truth) for p in base.glob('lucky*.npy')}
            strongest=min(competitors,key=lambda k:competitors[k]['rmse'])
            current=metrics(image,truth)
            rows.append(dict(group=group,scene=name,report_sha256=sha(path),input_sha256=report['input_sha256'],
                shader_sha256=report['shader_sha256'],stop=report['native_stop'],seconds=report['seconds'],
                candidate=current,competitors=competitors,best_lucky_by_rmse=strongest,
                candidate_to_best_lucky_rmse=current['rmse']/competitors[strongest]['rmse'],
                converged=report['native_stop']=='CONVERGED',truth_sha256=sha(base/'truth.npy')))
            label=f'{group}-{name}'
            for suffix,a in [('truth',truth),('lucky',np.load(base/(strongest+'.npy'))),('f5',image)]:
                preview(a,np.eye(3),assets/f'{label}-{suffix}.png',maximum=128)
            view.append(dict(label=label,lucky=f'images/{label}-lucky.png',candidate=f'images/{label}-f5.png',
                             truth=f'images/{label}-truth.png',note=f"{report['native_stop']} · Lucky: {strongest}"))
    prep=json.loads(args.preparation.read_text());matrix=np.array(prep['matrix_camera_to_linear_srgb'])
    real=[]
    for roi in prep['rois']:
        name=roi['name'];path=args.work/'candidate-v2'/name/f'{name}-metal-report.json'
        report,image=read_rgb(path)
        lucky_path=args.preparation.parent/'lucky-bm3d'/f'{name}-lucky-bm3d-1-64.npy'
        lucky=upsample(np.load(lucky_path))
        for exposure,suffix in [(1,''),*([(8,'-shadow-lift')] if name=='flat_dark' else [])]:
            label=f'real-{name}{suffix}'
            preview(lucky,matrix,assets/f'{label}-lucky.png',maximum=128,exposure=exposure)
            preview(image,matrix,assets/f'{label}-f5.png',maximum=128,exposure=exposure)
            view.append(dict(label=label,lucky=f'images/{label}-lucky.png',candidate=f'images/{label}-f5.png',truth=None,
                note=f"{report['native_stop']} · identical exposure ×{exposure}; no independent ground truth"))
        real.append(dict(scene=name,report_sha256=sha(path),input_sha256=report['input_sha256'],
            native_rgb_sha256=report['native_rgb']['sha256'],lucky_sha256=sha(lucky_path),stop=report['native_stop'],
            seconds=report['seconds'],truth_available=False))
    report=dict(revision='f5-lightweight-review-v2',camera_used=False,JSR_networks_used=False,
        candidate_policy='lightweight-candidate-policy.json',evaluation_scope='development; no blind human judgments',
        synthetic_results=rows,real_results=real,goal_complete=False,
        limitations=['Small ROI experiments, not full-photo or phone timing.',
            'The parameter-varied set shares the analytic scene family and is not external validation.',
            'Native reconstruction with 2x interpolation; no proven high-resolution advantage.',
            'Some cases still lose to denoised Lucky and joint convergence is incomplete.'])
    dump(args.output/'comparison.json',report)
    data=json.dumps(view,ensure_ascii=False).replace('</','<\\/')
    page='''<!doctype html><html lang="zh"><meta charset="utf-8"><title>F5 放大画质对照</title>
<style>body{background:#16191e;color:#e5e8eb;font:15px system-ui;margin:24px}select,button{font:inherit;padding:6px;margin-right:10px}header{position:sticky;top:0;background:#16191e;padding:12px 0}#panels{display:flex;gap:20px;align-items:start}figure{margin:0}figcaption{margin:10px 0}img{image-rendering:pixelated;border:1px solid #535a65;max-width:none}.note{color:#aab4c0;max-width:950px}#state{color:#e7b972}</style>
<header><strong>F5 与处理后的 Lucky：开发中</strong><p class="note">按最终输出像素放大比较。图片使用相同曝光、颜色矩阵与显示曲线；这些 SDR 预览不代表 HDR 验收。部分结果仍有伪色、噪声或收敛问题。</p>
<select id="case"></select><select id="zoom"><option value="1">100%</option><option value="2">200%</option><option selected value="4">400%</option><option value="8">800%</option></select><button id="swap">交换左右</button><p id="state"></p></header>
<div id="panels"></div><script>const cases=DATA;let swapped=false;const c=document.querySelector('#case'),z=document.querySelector('#zoom');cases.forEach((v,i)=>{let o=document.createElement('option');o.value=i;o.textContent=v.label;c.append(o)});function draw(){const v=cases[+c.value];document.querySelector('#state').textContent=v.note;const p=document.querySelector('#panels');p.replaceChildren();let images=[['Lucky：BM3D／后处理',v.lucky],['F5 当前实验结果',v.candidate]];if(swapped)images.reverse();if(v.truth)images.push(['独立解析真值',v.truth]);for(const [label,url] of images){let f=document.createElement('figure'),t=document.createElement('figcaption'),i=document.createElement('img');t.textContent=label;i.src=url;i.onload=()=>{i.style.width=(i.naturalWidth*+z.value)+'px';i.style.height=(i.naturalHeight*+z.value)+'px'};f.append(t,i);p.append(f)}}c.onchange=z.onchange=draw;document.querySelector('#swap').onclick=()=>{swapped=!swapped;draw()};draw();</script></html>'''.replace('DATA',data)
    (args.output/'review.html').write_text(page)
    print(args.output/'review.html')
    if args.summary:
        dump(args.summary,report)
    for row in rows:
        print(row['group'],row['scene'],round(row['candidate_to_best_lucky_rmse'],3),row['stop'])


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--work',type=Path,required=True)
    p.add_argument('--preparation',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--summary',type=Path)
    create(p.parse_args())
