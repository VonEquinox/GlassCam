# 04 RAW 双路径实现（0.2.0）

`is_raf()` 读取 `FUJIFILMCCD-RAW` 魔数。`load_raf()` 优先 rawpy，失败原因保存于 `decoder_fallback_reason`；无可解码传感器则提取面积最大而非压缩字节最多的 JPEG。JPEG 边界由解码器处理，避免 EXIF 内缩略图 EOI 截断外层流；每幅图先应用方向。

传感器路径读取 `raw_image_visible` 浮点原码，实际可见 CFA 相位由 `raw_colors_visible` 确认；缺 CFA 不凭机型编造。`color_desc` 的 RGBG 双绿保留站点 index；黑电平和白平衡按站点映射。相机 WB 无效时尝试 daylight WB，否则回退并记录原因。此解码步骤没有执行 rawpy.postprocess。

| 阶段 | 计算与域 |
|---|---|
| raw_input | 原始传感器数值，sensor-code；预览另除 white_level，不影响数值图 |
| black_level | `clamp((raw-black_site)/max(1,white-black_site))`，cfa-linear |
| bad_pixel_repair | 仅极端 `>=0.999` / `<=0.0001` 样本；同站点半径 max(CFA周期) 邻居至少 2 个、范围 <0.25、偏离均值 >0.25 才替换 |
| lens_shading | `r²=min(0.95,x²+y²)`；增益 `1+s*r²+0.1*s*r⁴` 后裁剪；s 来自暂定机型参数 |
| band_preprocess | 左右最近同站点水平样本，最多一个 CFA 横周期；两侧都存在才做 `0.25L+0.5C+0.25R` |
| white_balance | 站点 gain/绿色平均 gain，避免双绿元数据错用；有限正 gain，否则报错；乘积裁剪 |
| demosaic | 已测通道原样保留；缺色使用最近有该颜色的方形邻域逆距离平方平均，半径逐增至 max(CFA周期)；极小图确实无该颜色则填 0 |
| shadow_cleanup | `clamp(v+max(0,0.025-v)*0.25)`，linear |
| resize_lanczos | resize_factor 非 1 才缩放；每通道 Pillow F(float32) Lanczos 后裁剪，避免先做 8 位量化 |

同站点过滤使用 rawpy CFA index 区分两个绿站点；去马赛克按 RGB 颜色。公开 `demosaic_bayer()`、`demosaic_xtrans()` 共用同色逆距离插值；默认 X-Trans 示例相位有 20G/8R/8B，真实文件必须用解码相位。这是可检查插值，不宣称复现原生专有去马赛克算法。

开发后自动进入线性颜色链。无论 PipelineConfig 的线性开关默认为何，不再对传感器结果额外 sRGB 解码。机型标量参数/镜头径向增益/阴影函数均未以真实 RAF 配对标定；传感器元数据的 black、white、WB、CFA 优先。

内嵌预览是已显影 RGB：按其 ICC 归一化工作值后保留，黑电平、坏点、镜头阴影、带域、WB、去马赛克、阴影整理阶段只保存占位像素，`stage_status=not_applicable`。仅按明确 resize_factor 做缩放；不能通过占位阶段数量宣称 sensor RAW 已开发。

stage_pixels 保留原码/浮点，stage Images 是 8 位查看图。save_stages 的传感器阶段使用无 ICC float32 TIFF；CFA/原码比较只提供数值误差和 PSNR，不提供虚构的 ΔE。传感器 PSNR 验收需候选和参考两侧都记录 rawpy-sensor；预览回退为 unverified。

测试中模拟 rawpy 元数据、Bayer/X-Trans 饱和单色场与 sensor plane；这些独立夹具可揭示运算错误，不能替代真实 RAF 解码兼容性检查。此交付没有真实 RAF/原生 GUI 配对素材。

[源码](../implementation/ffcs/raw.py) · [颜色链](01_系统与完整Pipeline.md)
