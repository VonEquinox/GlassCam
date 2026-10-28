"""Native-pixel viewer for the three fixed diagnostic scenes."""
from pathlib import Path
import argparse
import json
import numpy as np

from f5_real_quality import preview


def run(args):
    args.output.mkdir(parents=True,exist_ok=True);assets=args.output/'images';assets.mkdir(exist_ok=True);views=[]
    evidence=json.loads((args.work/'family-comparison/results.json').read_text())
    for row in evidence['results']:
        name=row['name'];folder=args.work/'family-comparison'/name;truth=np.load(folder/'truth-native.npy');data=np.load(folder/'evaluation.npz')
        def save(label,image):
            p=assets/(name+'-'+label+'.png');preview(image,np.eye(3),p,maximum=16);return 'images/'+p.name
        truth_path=save('truth',truth);samples=[]
        for i in range(-1,len(data['f5'])):
            item={'label':'16 次评价的平均输出' if i<0 else f'第 {i+1} 次评价','images':{}}
            for key in data.files:item['images'][key]=save(key+'-'+str(i),data[key].mean(axis=0) if i<0 else data[key][i])
            samples.append(item)
        views.append(dict(name=name,truth=truth_path,samples=samples,scores=row['scores']))
    text=json.dumps(views,ensure_ascii=False).replace('</','<\\/')
    html='''<!doctype html><html lang="zh"><meta charset="utf-8"><title>F5 设计复审：原生对照</title>
<style>body{margin:24px;background:#181c22;color:#edf1f6;font:15px system-ui}header{position:sticky;top:0;background:#181c22;padding:12px 0}p{max-width:1100px;line-height:1.6}select{font:inherit;padding:6px;margin:4px}#panels{display:flex;gap:16px}figure{margin:0}figcaption{margin:10px 0}img{image-rendering:pixelated;border:1px solid #657384}table{border-collapse:collapse;margin:20px 0}td,th{text-align:left;padding:7px 18px;border-bottom:1px solid #454d59}.note{color:#b7c1cd}</style>
<header><strong>F5 设计复审：原生像素对照</strong><p class="note">四张主帧在相同位置独立曝光；固定几何与 v5 先验。每个场景用 16 次校准噪声估计各自噪声谱，另用 16 次评价噪声比较。同族降噪强度固定。这里是三块 16×16 开发裁切，指标使用中间 8×8；不能当成实拍或盲测结果。</p>
<label>内容 <select id="scene"></select></label><label>输出 <select id="sample"></select></label><label>处理 <select id="filter"><option value="">原生估计</option><option value="_bm3d">同族 BM3D 后</option></select></label><label>像素放大 <select id="zoom"><option value="4">400%</option><option value="8">800%</option><option value="16" selected>1600%</option><option value="32">3200%</option></select></label></header>
<div id="panels"></div><div id="metrics"></div><p class="note">显示曲线相同；像素放大不加入锐化或插值。指标按未截断的线性原生数值计算。噪声谱采用全局平稳近似，完整方差分布及配对区间保存在证据文件中。</p>
<script>const data=DATA;const labels={portrait:'人像',color_edge:'色彩边缘',chromatic_texture:'彩色纹理'};const c=document.querySelector('#scene'),s=document.querySelector('#sample'),f=document.querySelector('#filter'),z=document.querySelector('#zoom');data.forEach((v,i)=>{const o=document.createElement('option');o.value=i;o.textContent=labels[v.name];c.append(o)});function draw(){const v=data[+c.value],sample=v.samples[+s.value],panel=document.querySelector('#panels');panel.replaceChildren();for(const [title,path] of [['模拟真值',v.truth],['固定参考单帧',sample.images['single'+f.value]],['简单四帧均值',sample.images['mean4'+f.value]],['F5 驻点解',sample.images['f5'+f.value]],['固定 RAW BM3D Lucky',sample.images.lucky_fixed_raw_bm3d_1]]){const fig=document.createElement('figure'),cap=document.createElement('figcaption'),im=document.createElement('img');cap.textContent=title;im.src=path;im.width=16*+z.value;im.height=16*+z.value;fig.append(cap,im);panel.append(fig)}const box=document.querySelector('#metrics');box.replaceChildren();const table=document.createElement('table');for(const [name,a,b] of [['平均 MSE 开方（16 次评价）','无附加降噪','同族 BM3D 后'],['固定单帧','single','single_bm3d'],['四帧均值','mean4','mean4_bm3d'],['F5 驻点解','f5','f5_bm3d']]){const tr=document.createElement('tr');[name,v.scores[a]?v.scores[a].root_mean_mse.toFixed(6):a,v.scores[b]?v.scores[b].root_mean_mse.toFixed(6):b].forEach(x=>{const td=document.createElement('td');td.textContent=x;tr.append(td)});table.append(tr)}box.append(table)}function choose(){s.replaceChildren();data[+c.value].samples.forEach((v,i)=>{const o=document.createElement('option');o.value=i;o.textContent=v.label;s.append(o)});draw()}c.onchange=choose;s.onchange=f.onchange=z.onchange=draw;choose();</script></html>'''.replace('DATA',text)
    (args.output/'review.html').write_text(html);print(args.output/'review.html')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--work',type=Path,required=True);p.add_argument('--output',type=Path,required=True);run(p.parse_args())
