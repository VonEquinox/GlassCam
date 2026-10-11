# RAW 解码与配对标定

> 仓库交付范围：仅技术文档、代码和数值参数。文中涉及的照片、RAW、TIFF、DNG、预览和安装镜像均需在本地另行提供，未上传到此分支。历史照片核验结果为之前在本地执行的记录。


## 线性解码

`demosaic` 先核对相机型号、RGB Bayer 排列，再调用 rawpy。输出颜色空间为 raw，output_bps=16，gamma=(1,1)，user_wb=[1,1,1,1]，use_camera_wb/use_auto_wb 均 false；no_auto_bright=true，bright=1，adjust_maximum_thr=0；AHD 去马赛克，FBDD 关闭，median_filter_passes=0，user_flip=0。额外镜头校正未执行。

`linear_white=raw.white_level-max(raw.black_level_per_channel)`，作为 user_sat 传入。LibRaw 在扣黑后使用这个尺度；直接传未扣黑的白点会使 AHD 与 CFA 标定尺度不一致。对各 CFA 样本 c、对应黑点 b_k，采样使用 `(c-b_k)/(white-max(b))`。两处共同分母不是各通道分别 white−b_k，重写时不能擅自“修正”。

raw metadata 记录输入 SHA、制造商/型号、拍摄日期、可见尺寸、方向、CFA、black/white、camera_wb、linear_white 和 rawpy/LibRaw 版本。当前假设支持 RGB Bayer，并合并两种绿色索引；其他传感器阵列不在实现范围。

## 色卡定位与采样

色卡为 6 列×4 行，24 色块按行编号 1…24；前 18 为有彩块，19…24 为灰阶。配置 `chart_regions.json` 为两台相机分别保存四角归一化坐标，顺序 TL/TR/BR/BL，及对应 RAW SHA。单应变换把单位方形四角投到图像四角：解 8 元线性方程，最后一项 h33=1。

第 r 行、第 c 列的块中心为 `u=(c+0.5)/6, v=(r+0.5)/4`。采样宽度比例 fraction 默认 .48，则半宽 du=fraction/12、半高 dv=fraction/8；四个角经单应变换再乘可见图宽高。内部 mask 用点与四边叉积同号判定。坐标依据可见 CFA，不依据 EXIF 旋转后的 JPG。

按 raw.color_desc 把索引映成 R/G/B，两类绿色都参与 G 的统计。每通道至少 100 个样本，否则拒绝。通道中心是归一化样本的 median；噪声指标是 `1.4826×median(abs(sample−median))`；裁剪比例是 `mean(code >= white−1)`。标定要求各块各通道裁剪比例不大于 .001。输出带编号 ROI 图和逐块 JSON，供确认边框、反光、错位和脏块。

暖光训练与不同曝光验证沿用同场景归一化角点，但每张照片的 SHA 独立设置；它们是否适合新照片必须通过对应 ROI 图确认。新增场景不能仅修改 SHA 后照搬角点。

## WB 与曝光

四个中性控制块为零基索引 `[19,20,21,22]`，即块 20–23。WB 定义：`wR=median(G/R), wG=1, wB=median(G/B)`。灰阶曝光锚为索引 21，即块 22。

`normalisation(patches, gray_level)` 计算 `s=gray_level / mean(patch22×w)`，返回 `patches×w×s`。日光默认先求哈苏 WB，但最终把 target_scale 固定为 1，保留哈苏 RAW 自身响应；再把 Sony 调至相同块 22 亮度，因此 source_scale 约 1.4169209635。只有显式 `--gray-level` 才把目标中性块设到所选亮度，默认没有强制 0.18。

曝光不是 3×3 色彩矩阵的一部分。实际渲染用 `source_scale×2**EV`；模型光源插值过程中只归一化中性增益，继续使用日光基准尺度。暖光端点保存的 source_scale 用于训练与诊断，运行时没有按光源权重插值这两个曝光尺度。

## 精确保中性的矩阵拟合

设源块 x=(R,G,B)，目标块 t；矩阵每行和必须为 1。因此把第三个系数写成 `1−m1−m2`，只需拟合六个自由系数：

```text
D = [R−B, G−B]
Y = target−B
brightness = max(mean(target), .03)
w = brightness^(−weight_power)
X = D×w, Z = Y×w
Q = least_squares(X,Z)                    # 2×3
M = [Q.T 的两列, 1−sum(Q,axis=0)]         # 3×3
```

w 同时乘设计矩阵与目标，所以最小二乘中的有效权重是 w²。默认 weight_power=.5，相当于目标亮度倒数加权平方误差。无常量偏置。D 必须秩为 2，cond(D)≤100；M 必须 det(M)>0、cond(M)≤20。

若 ridge>0，令 `λ=ridge×sum(X²)/2`，并用 `Q=solve(X.T X+λI, X.T Z+λQidentity)`，其中 Qidentity=[[1,0,0],[0,1,0]]。这是朝单位映射收缩而不是朝零矩阵收缩。完整行和仍为 1。

只用前 18 块训练。逐一删除一个有彩块、用其余 17 块拟合并预测，计算颜色核心输出后的 Lab D50 ΔE00。中性 WB/尺度在每个子拟合之间共享，因此这不是包含 WB/曝光误差的独立留出。

日光 `.5/0`；暖光预声明候选为 `(.5,0),(0,0),(0,.01),(.5,.01),(1,0)`，按暖光有彩块平均留一 ΔE00 最小选择，保存结果为 `.5/.01`。暖光模型写出后才读取不同曝光验证 RAW。该验证后来用于默认模式选择，不能再称为最终盲测。

## 数据输入与重新建立模型

日光输入在根目录：`19990c35cf194481a0093de2b02ed818.arw` 与 `7fbb1471e0cf4b22858cd9a161fb83a8.3fr`。暖光训练在 `work/hncs-finalization/raw`：`b83908b171574fc5b33045dfca85daf6.arw` / `bd2ffdbfd1e441bc9a93c115117e5054.3fr`。不同曝光：`825b88ead50e440fbfed14437c27e470.arw` / `f3da42aac2944357bd87685f9ae2ec1e.3fr`。

顺序为核查角点→日光 calibrate→源 DCP 模型→暖光 fit→验证。保存模型前建议先另存原文件；新基准会改变 paired 指纹。ROI、采样值、训练参数和完整矩阵都在随包 JSON；可据此写出其他语言实现，无需重新访问在线来源。
