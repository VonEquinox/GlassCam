# RAW 双路径实现

## 1. 识别与解码

`is_raf` 读取前 16 字节，检测前缀 FUJIFILMCCD-RAW；读取失败才退到扩展名 .raf。一个存在但没有对应头部的 .raf 文件会被当普通图像处理。`load_raf` 先解析 CameraProfile，再尝试 rawpy 和 NumPy，导入或读取出现任意异常均返回 None，随后尝试 JPEG 预览。此回退不区分缺依赖、解码失败或其他内部异常。

传感器读取 `raw.raw_image_visible.astype('float32').tolist()`。CFA 来自 raw_pattern，缺失时 [[0,1],[1,2]]，索引经 color_desc 映射为字符 RGB。black_level_per_channel 取前三个，缺少则填 0；camera_whitebalance 取前三个，缺少则填 1；white_level 优先 raw 元信息，否则模型值。黑电平/WB 按 RGB 字符下标使用，而不是保留原四通道色点的独立绿色通道索引。这一映射不能假定对所有 RAW 标定都正确。

传感器路径的 demosaic_algorithm 元信息为 bilinear-cfa，raw_chain 为 sensor-plane。预览路径为 embedded-jpeg-preview 和 embedded-preview-preserved。调用者需将 decoder 保存到复现记录中。

## 2. 九个前置阶段及传感器公式

### raw_input

保留原 plane 供后续黑电平计算，但 stage_pixels 是将每个原始 sample **clip 到 [0,1] 后复制到 RGB**。因传感器原码常远大于 1，此阶段导出会大量变成白色，不能据此恢复原始传感器码。完整运行需保留输入 RAF；本交付没有真实 RAF 测试样本。

### black_level

对像素 (x,y)，按循环 CFA 字符取得通道 c，黑电平 b=black_levels[c]；非 RGB 字符使用三个黑电平均值。归一化 `clip((sample-b)/max(1,white_level-b))`，之后是二维标量 plane。

### bad_pixel_repair

基于上一阶段输入读四连通邻居（上、下、左、右），不会把已修复值回写参与同阶段其他像素。sample>=0.999 或 <=0.0001，且存在邻居且 max(neigh)-min(neigh)<0.25 时替换为邻居均值，否则保留。邻居没有按同色 CFA 分类。

### lens_shading

机身 shading<=0 时透传。`xx=2*x/(w-1)-1`、`yy=2*y/(h-1)-1`，单像素维度用 0；`r2=min(0.95,xx²+yy²)`；gain=`1+shading*r2+0.10*shading*r2²`；输出 clip(sample*gain)。这是明确的多项式增益，不是完整镜头光学模型。

### band_preprocess

每行内部像素使用 `0.25*left+0.5*center+0.25*right`，首尾列不变；不混合上下行、不按 CFA 分类。读原 plane、写新 plane。没有额外频段分析或校准参数。

### white_balance

gains=wb/max(wb)，由 CFA RGB 字符选择增益，非 RGB 字符用 1。输出 clip(sample*gain)。此处归一化使最大通道增益为 1，不是绿色归一化的增益。wb 全零会出现除零，直接构造 RawSensor 时需提供合法值。

### demosaic

实际 developer 调用 `demosaic_cfa(plane,sensor.pattern)`，所有机身共享这一函数。对目标点读取截断的 3×3 邻域，按每个邻点周期 CFA 字符分别收集 R/G/B，输出各通道均值；某通道无邻居则用目标点 sample 作为默认值，最后 clip。边缘不镜像、不环绕。当前算法连原已知通道也按同色邻居平均，而不是总保留中心色点。

单独导出的 demosaic_bayer 使用 4 字符 2×2 模式，仍是同样邻域均值；demosaic_xtrans 使用代码内的固定 6×6 模式，**不是传感器 developer 的调用路径**，固定模式本身也不能当作所有机身的实测 CFA。其字面矩阵如下，跨语言复制应遵照源码而非名称推断：

```text
G R G G R G
B G B B G B
G B G G B G
G G B G G B
B G B B G B
G B G G B G
```

### shadow_cleanup

每个 RGB 通道 `clip(v+max(0,0.025-v)*0.25)`。v=0 输出 0.00625，v>=0.025 保持不变。本阶段没有另外执行孤立点检测；不要从旧阶段描述中推断存在额外算法。

### resize_lanczos

默认机身 resize_factor 全为 1，复制最终图和浮点像素，不真正缩放。自定义比例时尺寸为 `max(1,round(original_size*factor))`，每个通道先 clip 后打包为 float32，创建 Pillow F 图，使用 Resampling.LANCZOS，读回再 clip。该调用的具体边界、核采样与 float32 舍入由固定 Pillow 版本定义；逐像素匹配应使用同版本实现，其他库的 Lanczos 不一定等价。

## 3. JPEG 预览路径完整公式

读取整个 RAF，扫描 FF D8 FF 到其后第一个 FF D9 的候选流；按**压缩字节长度**从大到小尝试 Pillow 解码，返回第一个可用的图，而不是实际枚举后比较像素面积。执行 EXIF 转向并转 RGB。没有可用候选则 ValueError。

raw_input 是预览 RGB8 除以 255；接着依次运行：

| 阶段 | 预览路径实现 |
|---|---|
| black_level | denom=max(camera.white_level,camera.black_level+1)，offset=black_level/denom；clip((v-offset)/max(1e-9,1-offset)) |
| bad_pixel_repair | 若通道极差>0.98 且最大值>0.999，用四连通 RGB 邻居均值替换 |
| lens_shading | 与标量路径相同增益，对 RGB 每通道处理 |
| band_preprocess | 与标量路径相同水平三点滤波，RGB 各通道独立 |
| white_balance | 使用 camera.wb/max(camera.wb)，逐 RGB 通道乘 gain |
| demosaic | 恒等操作，因为预览已经是 RGB |
| shadow_cleanup | 与传感器路径相同暗部公式 |
| resize_lanczos | 与传感器路径相同浮点缩放 |

预览数据已编码，black_level 直接在其数值上处理，没有先解码为线性；不能按该函数注释推断有隐式 Gamma。预览也不会完全保留原 JPEG，因为其他前置阶段会改变像素。

## 4. 与颜色链的衔接

apply_path 用 resize_lanczos 的浮点数据输入 FFCS.apply，阶段预览仅辅助显示。传感器 decoder 的 RAW stage_domains 全标 linear，预览 decoder 全标 encoded；raw_input 的夹取原码依然沿用此总体标签，不能将其视为精确传感器归一化图。

默认 input_is_linear=False；传感器结果进入 gamma_pre 时仍执行一次 sRGB 解码。此行为已列入颜色规格。项目没有真实 RAF/匹配参考阶段验证，不能将预览路径 18 阶段测试称为传感器 RAW 质量测试。

## 5. 可独立重建的要求

真实 RAW 复现必须共享输入文件、rawpy/NumPy/LibRaw 版本、解码的可见区、CFA pattern、三通道黑电平与 WB、白电平、CameraProfile、input_is_linear，以及 Pillow 缩放版本。若外部解码器提供相同 RawSensor，可独立调用标量函数和 demosaic_cfa；但开发接口目前没有直接接收 RawSensor 的整链公共方法，需按以上顺序组合。
