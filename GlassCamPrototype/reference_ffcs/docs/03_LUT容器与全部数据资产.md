# LUT 容器与全部数据资产

## 1. 必须随实现交付的颜色数据

内置表是完整的离散颜色函数。外观名称、几个参数或插值公式不能推导出这 48 个表的每个节点，因此本交付包含实际二进制数据及 SHA-256，而不是仅提供说明。XH2S 19 张、GFX100 18 张、XA3 11 张。XH2S/GFX100 的 N=80；XA3 的 N=64。GFX100S 选择 GFX100；X-T5、X100V、GENERIC 和未知机身没有内置相机家族。

## 2. FFCSLUT2 字节布局

所有多字节标量是小端序。偏移从 0 开始。

| 偏移 | 字节数 | 类型 | 含义 |
|---|---|---|---|
| 0 | 8 | ASCII | FFCSLUT2 |
| 8 | 2 | uint16 | N，每轴节点数，>=2 |
| 10 | 2 | uint16 | 通道数，必须 3 |
| 12 | 4 | float32 | scale，必须 >0 |
| 16 | 36 | 9×float32 | 行主序 3×3 模型矩阵 |
| 52 | 1 | uint8 | flags，bit0 决定输出通道顺序 |
| 53 | 3 | 保留 | 当前读取器不解释 |
| 56 | 4 | uint32 | zlib 压缩数据的字节数 |
| 60 | payload_len | 字节流 | zlib payload |

FFCSLUT1 同样从 16 存放矩阵，但没有 flags/保留区：payload_len 在 52、压缩内容在 56；默认输出通道 BGR。当前交付数据为版本 2。

解压后长度必须恰好 `N*N*N*3*2` 字节。使用小端无符号 uint16，节点 i 的分量为 `values[3*i+c]/scale`。大端机器读 array('H') 后 byteswap。scale 是节点解码除数，不能再次乘进像素。FilmSimulation.lut_scale 是元参数；实际除法发生于 PackedLUT.__getitem__。

当前读取器检验 magic、N、channels、scale 和解压长度，但没有完整的文件截断、NaN、尾随数据及所有 flags 合法性验证。SHA-256 提供了交付文件的完整性验证。

## 3. 索引约定与使用顺序

PackedLUT.axis_order 恒为 BGR。插值前输入 (R,G,B) 改为 (B,G,R)，平坦地址仍用 z*N²+y*N+x。flags&1 为真时 channel_order=RGB，否则 BGR。BGR 输出需在插值后将首尾通道交换。

各相机表使用 encoded 输入域：颜色链先 sRGB 解码、应用头矩阵、sRGB 编码，然后访问此表。不要对 encoded 表输出再做 E 编码。三线性插值结果逐通道夹取 [0,1]，即使 uint16/scale 表节点本身可能超出 1。

读取内置数据后，Pipeline 替换 simulation 的 lut/size/matrix/domain/scale/source；**没有清零 contrast、saturation、hue、grain、sharpness**。这些后处理仍然执行，完整输出会与单纯查表不同。

## 4. 相机和名称选择

相机名称去非字母数字并大写：X-H2S、XH2S 命中相同家族；GFX100S 映射 gfx100。模拟名称先由 models 解析，CC 是 CLASSIC CHROME，NC 是 CLASSIC NEG.。内置文件键映射：CLASSICCHROME→classic_chrome、CLASSICNEG→classic_neg、NOSTALGICNEG→nostalgic_neg、ETERNABLEACHBYPASS→bleach_bypass、PRONEGHI/STD→pro_neg_hi/std、MONOCHROME→bw。滤镜单独映射到 acros_g/r/ye_filter 和 mono_g/r/ye_filter。

REALA ACE 没有交付 LUT；XA3 没有 ACROS、ETERNA、CLASSIC NEG.、NOSTALGIC NEG. 等文件，GFX100 没有 NOSTALGIC NEG.。缺表返回 None 并使用解析模型；不会自动借其他相机的表（GFX100S 规则除外）。缓存键是完整路径，保存 (lut,matrix)；修改同路径文件后应重启进程才能重载。

## 5. 外部 cube 文件支持范围

按 UTF-8 文本逐行读取；跳过空行、以 # 开始的注释、TITLE、DOMAIN_MIN、DOMAIN_MAX、LUT_1D_SIZE。读取 LUT_3D_SIZE，后续可解析的三数行夹取后存为平坦表。要求 N>=2 且数量=N³。红色坐标最快、绿色其次、蓝色最慢。

DOMAIN_MIN/MAX 被忽略，所以输入范围只能按 [0,1] 使用。1D shaper 声明被忽略，但其数值行可能仍被计入并导致节点数量错误；不支持组合 1D+3D LUT。没有 HDR 节点保留。标准大小为 2 的 identity cube 示例由 examples/reproduce.py 生成。

CLI `--lut-domain encoded` 使 encoded 分支生效；默认是模型的 linear。encoded 外部 cube 也跳过 camera.matrix，因此 identity cube 在 XH2S 上与 linear identity cube 不等价。matrix_fused_into_lut 元信息对外部表为 False。

## 6. 全部 LUT 资产

完整 SHA-256 与矩阵数据同时保存在 `validation/asset_inventory.json` 和 `delivery_manifest.json`。

| 文件 | 节点 | scale | 输出通道 | flags | 字节数 |
|---|---|---|---|---|---|
| `gfx100/acros.lutz` | 80³ | 20000 | RGB | 1 | 1046567 |
| `gfx100/acros_g_filter.lutz` | 80³ | 20000 | RGB | 1 | 1057790 |
| `gfx100/acros_r_filter.lutz` | 80³ | 20000 | RGB | 1 | 831063 |
| `gfx100/acros_ye_filter.lutz` | 80³ | 20000 | RGB | 1 | 934117 |
| `gfx100/astia.lutz` | 80³ | 20000 | RGB | 1 | 2417426 |
| `gfx100/bleach_bypass.lutz` | 80³ | 20000 | RGB | 1 | 2805231 |
| `gfx100/bw.lutz` | 80³ | 20000 | RGB | 1 | 1049740 |
| `gfx100/classic_chrome.lutz` | 80³ | 20000 | RGB | 1 | 2592451 |
| `gfx100/classic_neg.lutz` | 80³ | 20000 | RGB | 1 | 2708700 |
| `gfx100/eterna.lutz` | 80³ | 20000 | RGB | 1 | 2638612 |
| `gfx100/mono_g_filter.lutz` | 80³ | 20000 | RGB | 1 | 1054704 |
| `gfx100/mono_r_filter.lutz` | 80³ | 20000 | RGB | 1 | 877547 |
| `gfx100/mono_ye_filter.lutz` | 80³ | 20000 | RGB | 1 | 952748 |
| `gfx100/pro_neg_hi.lutz` | 80³ | 20000 | RGB | 1 | 2468713 |
| `gfx100/pro_neg_std.lutz` | 80³ | 20000 | RGB | 1 | 2518186 |
| `gfx100/provia.lutz` | 80³ | 20000 | RGB | 1 | 2443436 |
| `gfx100/sepia.lutz` | 80³ | 20000 | RGB | 1 | 2713249 |
| `gfx100/velvia.lutz` | 80³ | 20000 | RGB | 1 | 2333319 |
| `xa3/astia.lutz` | 64³ | 20000 | RGB | 1 | 1370590 |
| `xa3/bw.lutz` | 64³ | 20000 | RGB | 1 | 544401 |
| `xa3/classic_chrome.lutz` | 64³ | 20000 | RGB | 1 | 1354382 |
| `xa3/mono_g_filter.lutz` | 64³ | 20000 | RGB | 1 | 538091 |
| `xa3/mono_r_filter.lutz` | 64³ | 20000 | RGB | 1 | 503323 |
| `xa3/mono_ye_filter.lutz` | 64³ | 20000 | RGB | 1 | 518046 |
| `xa3/pro_neg_hi.lutz` | 64³ | 20000 | RGB | 1 | 1361092 |
| `xa3/pro_neg_std.lutz` | 64³ | 20000 | RGB | 1 | 1366190 |
| `xa3/provia.lutz` | 64³ | 20000 | RGB | 1 | 1361185 |
| `xa3/sepia.lutz` | 64³ | 20000 | RGB | 1 | 1321645 |
| `xa3/velvia.lutz` | 64³ | 20000 | RGB | 1 | 1354838 |
| `xh2s/acros.lutz` | 80³ | 20000 | RGB | 1 | 1050148 |
| `xh2s/acros_g_filter.lutz` | 80³ | 20000 | RGB | 1 | 1046412 |
| `xh2s/acros_r_filter.lutz` | 80³ | 20000 | RGB | 1 | 978026 |
| `xh2s/acros_ye_filter.lutz` | 80³ | 20000 | RGB | 1 | 1003032 |
| `xh2s/astia.lutz` | 80³ | 20000 | RGB | 1 | 2672062 |
| `xh2s/bleach_bypass.lutz` | 80³ | 20000 | RGB | 1 | 2805720 |
| `xh2s/bw.lutz` | 80³ | 20000 | RGB | 1 | 1051932 |
| `xh2s/classic_chrome.lutz` | 80³ | 20000 | RGB | 1 | 2744308 |
| `xh2s/classic_neg.lutz` | 80³ | 20000 | RGB | 1 | 2701193 |
| `xh2s/eterna.lutz` | 80³ | 20000 | RGB | 1 | 2776973 |
| `xh2s/mono_g_filter.lutz` | 80³ | 20000 | RGB | 1 | 1046029 |
| `xh2s/mono_r_filter.lutz` | 80³ | 20000 | RGB | 1 | 975771 |
| `xh2s/mono_ye_filter.lutz` | 80³ | 20000 | RGB | 1 | 1005184 |
| `xh2s/nostalgic_neg.lutz` | 80³ | 20000 | RGB | 1 | 2570732 |
| `xh2s/pro_neg_hi.lutz` | 80³ | 20000 | RGB | 1 | 2686816 |
| `xh2s/pro_neg_std.lutz` | 80³ | 20000 | RGB | 1 | 2720232 |
| `xh2s/provia.lutz` | 80³ | 20000 | RGB | 1 | 2688051 |
| `xh2s/sepia.lutz` | 80³ | 20000 | RGB | 1 | 2712985 |
| `xh2s/velvia.lutz` | 80³ | 20000 | RGB | 1 | 2605860 |

## 7. 每张表的头部矩阵

以下按行主序列出九个元素；不得用相机模型矩阵替代。

- `gfx100/acros.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/acros_g_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/acros_r_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/acros_ye_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/astia.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/bleach_bypass.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/bw.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/classic_chrome.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/classic_neg.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/eterna.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/mono_g_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/mono_r_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/mono_ye_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/pro_neg_hi.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/pro_neg_std.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/provia.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/sepia.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `gfx100/velvia.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xa3/astia.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xa3/bw.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xa3/classic_chrome.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xa3/mono_g_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xa3/mono_r_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xa3/mono_ye_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xa3/pro_neg_hi.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xa3/pro_neg_std.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xa3/provia.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xa3/sepia.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xa3/velvia.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/acros.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/acros_g_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/acros_r_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/acros_ye_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/astia.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/bleach_bypass.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/bw.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/classic_chrome.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/classic_neg.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/eterna.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/mono_g_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/mono_r_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/mono_ye_filter.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/nostalgic_neg.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/pro_neg_hi.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/pro_neg_std.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/provia.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/sepia.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`
- `xh2s/velvia.lutz`：`[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]`

## 8. ICC 数据

`ISL-sRGB.icc` 和 `ISL-ARGB1998.icc` 原样交付。输出优先使用这里的字节，其次系统 ColorSync 配置，再尝试 Pillow ImageCms 创建 profile；失败则没有标签。完整像素转换由 color.py 执行，不由这些文件隐式承担。DMG 材料不参与运行期表读取，独立交付无需该材料即可计算。
