# 03 LUT 容器与全部数据资产（0.2.0）

FFCSLUT2 头部为小端结构 `<8sHHf9fB3xI`，共 60 字节。旧 FFCSLUT1 头为 56 字节，不含 flags。

| 偏移 | 字段 |
|---:|---|
| 0 | 8 字节 magic：FFCSLUT1 / FFCSLUT2 |
| 8 | uint16 N；uint16 channels（必须为 3） |
| 12 | float32 scale（有限、正数，当前为 20,000） |
| 16 | 9 个 float32 矩阵，按行；当前均为恒等 |
| 52 | V2 flags：bit0=1 表示 RGB 通道，0 表示 BGR；其余位须为 0 |
| 53 | V2 3 字节保留 |
| 56 | V2 uint32 压缩长度；V1 在偏移 52 |
| 60 | V2 zlib 载荷；V1 从 56 开始 |

载荷恰为 `N³*3*2` 字节 little-endian uint16。加载器校验 magic、头部、scale、矩阵、flags、压缩长度、zlib EOF/尾随内容和解压尺寸；按本机字节序转换。`PackedLUT` 用紧凑数组保存，节点除 scale；三线性每次只读八角，文件缓存只避免重复解压。

表轴 BGR（具体为输入 x=B、y=G、z=R，x 最快），通道 RGB；flags 管输出通道顺序。原生 BGR 接口与封装轴序转换见提取脚本。封装表已包含原生最终矩阵处理，运行时不重复施加。

选择规则：XH2S→xh2s，XA3→xa3，GFX100→gfx100；GFX100S→gfx100s 后 gfx100；GFX100II→gfx100ii 后 gfx100。专用新增表各 1 张；其余机型替代状态为 `unquantified`。找不到表使用解析预设，不制造原生测量证据。

每目录 manifest 保存表文件名、大小及 SHA-256。完整容器矩阵、量程、轴序和当前测量位于 [asset_inventory.json](../validation/asset_inventory.json)；`delivery_manifest.json` 仅保存交付文件路径、大小、hash，不包含矩阵字段。

| 文件 | 节点 | 字节 | 通道/轴 |
|---|---:|---:|---|
| [gfx100/acros.lutz](../implementation/ffcs/data/gfx100/acros.lutz) | 80³ | 1046567 | RGB/BGR |
| [gfx100/acros_g_filter.lutz](../implementation/ffcs/data/gfx100/acros_g_filter.lutz) | 80³ | 1057790 | RGB/BGR |
| [gfx100/acros_r_filter.lutz](../implementation/ffcs/data/gfx100/acros_r_filter.lutz) | 80³ | 831063 | RGB/BGR |
| [gfx100/acros_ye_filter.lutz](../implementation/ffcs/data/gfx100/acros_ye_filter.lutz) | 80³ | 934117 | RGB/BGR |
| [gfx100/astia.lutz](../implementation/ffcs/data/gfx100/astia.lutz) | 80³ | 2417426 | RGB/BGR |
| [gfx100/bleach_bypass.lutz](../implementation/ffcs/data/gfx100/bleach_bypass.lutz) | 80³ | 2805231 | RGB/BGR |
| [gfx100/bw.lutz](../implementation/ffcs/data/gfx100/bw.lutz) | 80³ | 1049740 | RGB/BGR |
| [gfx100/classic_chrome.lutz](../implementation/ffcs/data/gfx100/classic_chrome.lutz) | 80³ | 2592451 | RGB/BGR |
| [gfx100/classic_neg.lutz](../implementation/ffcs/data/gfx100/classic_neg.lutz) | 80³ | 2708700 | RGB/BGR |
| [gfx100/eterna.lutz](../implementation/ffcs/data/gfx100/eterna.lutz) | 80³ | 2638612 | RGB/BGR |
| [gfx100/mono_g_filter.lutz](../implementation/ffcs/data/gfx100/mono_g_filter.lutz) | 80³ | 1054704 | RGB/BGR |
| [gfx100/mono_r_filter.lutz](../implementation/ffcs/data/gfx100/mono_r_filter.lutz) | 80³ | 877547 | RGB/BGR |
| [gfx100/mono_ye_filter.lutz](../implementation/ffcs/data/gfx100/mono_ye_filter.lutz) | 80³ | 952748 | RGB/BGR |
| [gfx100/pro_neg_hi.lutz](../implementation/ffcs/data/gfx100/pro_neg_hi.lutz) | 80³ | 2468713 | RGB/BGR |
| [gfx100/pro_neg_std.lutz](../implementation/ffcs/data/gfx100/pro_neg_std.lutz) | 80³ | 2518186 | RGB/BGR |
| [gfx100/provia.lutz](../implementation/ffcs/data/gfx100/provia.lutz) | 80³ | 2443436 | RGB/BGR |
| [gfx100/sepia.lutz](../implementation/ffcs/data/gfx100/sepia.lutz) | 80³ | 2713249 | RGB/BGR |
| [gfx100/velvia.lutz](../implementation/ffcs/data/gfx100/velvia.lutz) | 80³ | 2333319 | RGB/BGR |
| [gfx100ii/reala_ace.lutz](../implementation/ffcs/data/gfx100ii/reala_ace.lutz) | 80³ | 2718056 | RGB/BGR |
| [gfx100s/nostalgic_neg.lutz](../implementation/ffcs/data/gfx100s/nostalgic_neg.lutz) | 80³ | 2738525 | RGB/BGR |
| [xa3/astia.lutz](../implementation/ffcs/data/xa3/astia.lutz) | 64³ | 1370590 | RGB/BGR |
| [xa3/bw.lutz](../implementation/ffcs/data/xa3/bw.lutz) | 64³ | 544401 | RGB/BGR |
| [xa3/classic_chrome.lutz](../implementation/ffcs/data/xa3/classic_chrome.lutz) | 64³ | 1354382 | RGB/BGR |
| [xa3/mono_g_filter.lutz](../implementation/ffcs/data/xa3/mono_g_filter.lutz) | 64³ | 538091 | RGB/BGR |
| [xa3/mono_r_filter.lutz](../implementation/ffcs/data/xa3/mono_r_filter.lutz) | 64³ | 503323 | RGB/BGR |
| [xa3/mono_ye_filter.lutz](../implementation/ffcs/data/xa3/mono_ye_filter.lutz) | 64³ | 518046 | RGB/BGR |
| [xa3/pro_neg_hi.lutz](../implementation/ffcs/data/xa3/pro_neg_hi.lutz) | 64³ | 1361092 | RGB/BGR |
| [xa3/pro_neg_std.lutz](../implementation/ffcs/data/xa3/pro_neg_std.lutz) | 64³ | 1366190 | RGB/BGR |
| [xa3/provia.lutz](../implementation/ffcs/data/xa3/provia.lutz) | 64³ | 1361185 | RGB/BGR |
| [xa3/sepia.lutz](../implementation/ffcs/data/xa3/sepia.lutz) | 64³ | 1321645 | RGB/BGR |
| [xa3/velvia.lutz](../implementation/ffcs/data/xa3/velvia.lutz) | 64³ | 1354838 | RGB/BGR |
| [xh2s/acros.lutz](../implementation/ffcs/data/xh2s/acros.lutz) | 80³ | 1050148 | RGB/BGR |
| [xh2s/acros_g_filter.lutz](../implementation/ffcs/data/xh2s/acros_g_filter.lutz) | 80³ | 1046412 | RGB/BGR |
| [xh2s/acros_r_filter.lutz](../implementation/ffcs/data/xh2s/acros_r_filter.lutz) | 80³ | 978026 | RGB/BGR |
| [xh2s/acros_ye_filter.lutz](../implementation/ffcs/data/xh2s/acros_ye_filter.lutz) | 80³ | 1003032 | RGB/BGR |
| [xh2s/astia.lutz](../implementation/ffcs/data/xh2s/astia.lutz) | 80³ | 2672062 | RGB/BGR |
| [xh2s/bleach_bypass.lutz](../implementation/ffcs/data/xh2s/bleach_bypass.lutz) | 80³ | 2805720 | RGB/BGR |
| [xh2s/bw.lutz](../implementation/ffcs/data/xh2s/bw.lutz) | 80³ | 1051932 | RGB/BGR |
| [xh2s/classic_chrome.lutz](../implementation/ffcs/data/xh2s/classic_chrome.lutz) | 80³ | 2744308 | RGB/BGR |
| [xh2s/classic_neg.lutz](../implementation/ffcs/data/xh2s/classic_neg.lutz) | 80³ | 2701193 | RGB/BGR |
| [xh2s/eterna.lutz](../implementation/ffcs/data/xh2s/eterna.lutz) | 80³ | 2776973 | RGB/BGR |
| [xh2s/mono_g_filter.lutz](../implementation/ffcs/data/xh2s/mono_g_filter.lutz) | 80³ | 1046029 | RGB/BGR |
| [xh2s/mono_r_filter.lutz](../implementation/ffcs/data/xh2s/mono_r_filter.lutz) | 80³ | 975771 | RGB/BGR |
| [xh2s/mono_ye_filter.lutz](../implementation/ffcs/data/xh2s/mono_ye_filter.lutz) | 80³ | 1005184 | RGB/BGR |
| [xh2s/nostalgic_neg.lutz](../implementation/ffcs/data/xh2s/nostalgic_neg.lutz) | 80³ | 2570732 | RGB/BGR |
| [xh2s/pro_neg_hi.lutz](../implementation/ffcs/data/xh2s/pro_neg_hi.lutz) | 80³ | 2686816 | RGB/BGR |
| [xh2s/pro_neg_std.lutz](../implementation/ffcs/data/xh2s/pro_neg_std.lutz) | 80³ | 2720232 | RGB/BGR |
| [xh2s/provia.lutz](../implementation/ffcs/data/xh2s/provia.lutz) | 80³ | 2688051 | RGB/BGR |
| [xh2s/sepia.lutz](../implementation/ffcs/data/xh2s/sepia.lutz) | 80³ | 2712985 | RGB/BGR |
| [xh2s/velvia.lutz](../implementation/ffcs/data/xh2s/velvia.lutz) | 80³ | 2605860 | RGB/BGR |

两个 ICC 位于 `implementation/ffcs/data/icc/`。运行时无需 vendor 二进制。每表原生核对结果在 [native_reference_validation.json](../validation/native_reference_validation.json)，包括 native/packed/library hash、Gamma、2,000 样本的平均/P95/最大误差。默认预设调整关闭；该证据仅用于 sigma=1 核心 LUT。

从原生库提取/验证的脚本位于 `implementation/tools/`。C++ 探针在 macOS 使用 `clang++ -std=c++17 -arch x86_64` 构建；提取程序显式解码输入 Gamma、调用原生三线性、编码输出 Gamma，采样 80³ 均匀编码网格。本次两张新表完整来源均在各自 manifest。

[源码](../implementation/ffcs/lutdata.py) · [指标](07_验证指标与复现边界.md)
