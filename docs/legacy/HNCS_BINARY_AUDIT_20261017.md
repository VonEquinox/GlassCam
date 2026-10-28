# Phocus 二进制核查与原版曲线修正

2026-10-17，`codex/single-camera-hard-black`。本轮直接加载 Phocus 4.2.2 的 arm64 程序库，用数值向量调用原始函数，再与当前 GlassCam C++ 比较。发现并修复了参考实现中的一个真实差异；不以照片观感或 TIFF 像素拟合作为判断依据。

完整结果见 [二进制报告](/Users/vonequinox/.codex/visualizations/2026/10/17/01a1494a-d01c-7dd1-ada5-f601e033d61e/binary-audit/report.json)、[函数反汇编索引](/Users/vonequinox/.codex/visualizations/2026/10/17/01a1494a-d01c-7dd1-ada5-f601e033d61e/binary-audit/selected-functions.json)及[交付验证](../validation/hncs-binary-audit-20261017.json)。

## 原始证据与比较范围

使用挂载的 `/Volumes/Phocus/Phocus.app`，校验 HBUtil、HBRawCorrections、HBImageProcessing、HBStorage 的 SHA-256。完整哈希和源代码摘要写入报告。原厂 Standard、Nature 及其余 41 个不同 XML 配置直接从应用资源读取并核对摘要。

X2D II 工厂配置沿用此前从原程序资源恢复的 plist，SHA-256 为 `c2b3d08e0d489eb852610c12a9b985e9d0340a4dd544f5b0b5b7a6a4f3427e95`。本轮由原生 `CXMLLut` 解析它并构造颜色对象，没有把 GlassCam 生成的矩阵或 LUT 注入原生对象。对象和配置缓存只属于独立诊断进程。

每例输入为全部 65,536 个中性灰码、33³ RGB 网格和 32,768 个固定种子的随机 RGB16，共 134,241 像素。输入位于已白平衡、归一化的 native RGB 域，未使用 Apple RAW 像素。

| 检查 | 案例数 | 通道比较数 | 最大 UInt16 差 |
|---|---:|---:|---:|
| 原生 `ColorNormalCorrectPixels` 与 GlassCam 颜色核 | 36 | 14,498,028 | 0 |
| 43 套原始配置，曲线开／关 | 86 | 34,634,178 | 0 |
| Standard／Nature：颜色核接原生曲线 | 24 | 9,665,352 | 0 |
| 合计 | 146 | 58,797,558 | 0 |

覆盖 legacy／L*RGB、Standard／Reproduction、多个色温和 film curve；色温越界输入也覆盖 1000K、11000K。另有 10 组捕获／目标白平衡检查，色温全部相同，增益最大误差 `1.3322676295501878e-15`；80 组暗部色度权重检查误差 0，60 组原生 film 选择检查全部一致。这是所列输入与配置下的数值证据，不是穷举全部 RGB16 三元组。

## 修正：无曲线调整不等于可以跳过原生滤镜

原版 `CCameraImage::AddPostViewerRGBFilters` 在 `0xfa510` 加入 `CGradationFilter`。`UpdateProcessParams` 的 `0xfde44` 将 ExposureToolVersion 传入处理参数，随后 `0xfa4f0` 的比较决定是否恢复色相。两套工厂配置的原生版本均为 4，因此启用 RecoverHue。

`CGradationFilter` 构造函数 `0x474a0` 仅在没有曲线对象时禁用自身；原生实例中 Standard／Nature、曲线开／关四例的启用标志均为真。它没有使用“用户曲线是否调整过”作为旁路条件。即使 Standard 没有调整，原版三张通道表各有 88 个码值比恒等映射低 1；后续 RecoverHue 也有浮点舍入。

交付的 revision-8 Python 和 C++ 都曾以 `mode.active == false` 跳过这一步。初始 64 例比较中有 1,432,354 个通道不同，最大差 2/65535；原颜色核和开启曲线的 Nature 已经一致。修正后同组比较为 0 差，再扩展到上表的全部配置。保留[修正前报告](/Users/vonequinox/.codex/visualizations/2026/10/17/01a1494a-d01c-7dd1-ada5-f601e033d61e/binary-audit/report-before.json)和修改前源文件快照。

GlassCam 的 preset 路径现在始终执行原版 gradation；裸 `hncs_create`／`hncs_render_native` 颜色核保持原有合同。工厂矩阵、LUT、曲线资产及 `reference/` 均未改写。独立数值回归使用显式的 `tools/phocus_binary_reference.py` 修正参考旁路，并且对所有保留的原生黄金向量严格比较，不再排除无调整情形。

应用 render revision 升为 9，旧 revision-8 设置自动保留选项并迁移，未知版本继续拒绝；缓存身份同步更新。HNCS 仍采用系统取景，未放行新的近似实时 cube。

## 对明暗、白平衡和曝光的判断

- `CalculateGrayWeight`（`0x30e58`）在 Standard 的低亮度区生成 0.877 至 1 的色度权重。`ColorNormalCorrectPixels` 将它乘到映射后的色度项上，随后保留 Y 作为重建基线，再经过 film curve。因此**这个暗部环节是降低饱和度，不是提亮暗部**。这不意味着曝光、film curve 和后曲线不会改变明暗。
- 原厂 Nature 固定为 5500K、Tint `-0.003333333333333333`；Standard 保留捕获白平衡。二者 XML 中的 `EV=1` 是倍率 1，即额外 0EV，不是 +1EV。
- Nature 的原始 Points 为 `(0,0),(71,31),(184,223),(255,255)`；经原生滤镜后，灰码 16384→13521、32768→32672、49152→51865。它不是统一抬高暗部的曲线。这些是工作域码值，不能直接当成场景线性曝光倍率。
- `CRawImageFileData::GetIsoGain` 的反汇编显示，它会读取黑／白电平以及 DNG BaselineExposure／Offset；其代码值归一化系数不能再次直接乘到已经由 Apple 归一化的 RGB 上。这个函数本身也不能证明整条 RAW 曝光链的等价性。

## 验证、成本与边界

- 77 项相关便携检查通过，包含实际 C++ 颜色／空间交接、效果开关和并行分块一致性。
- 数值回归比较了 20,134,896 个逐点通道；原有 52 组颜色核黄金向量和 892,080 个附加边界通道仍为 0 差。另以 949,256 个密集／随机输入检查源域桥和输出，Float32 对修正后的 double 参考最大误差 `2.980231861293703e-8`。
- 密集回归同时修复了旧诊断工具的输入布局错误：转置生成的网格原为列优先，C ABI 需要连续 RGB 三元组；现已显式转换为连续内存。
- Apple 实际 Swift／Core Image／Metal／HEIF 回归通过，包括旧设置迁移、未知版本拒绝、14 组 SDR／HDR 输出、直接／预览后导出、取消及分享。这里的空间回归验证 GlassCam 代码一致性，不是原版 Phocus 空间核一致性。
- iPhone Release 构建、签名验证和安装完成；安装前后应用设置按值一致。本轮未重新拍照、保存相册或测量手机整张导出时间。
- Mac 的 1,048,576 像素、四线程、交替七轮颜色处理测试：Standard 中位数从 7.913 ms 变为 21.108 ms，Nature 从 20.601 ms 变为 20.593 ms。Standard 补回了真实处理，因此有额外成本；这些不是 iPhone 端到端数字。以前的 2.77 秒结果属于修正前版本。

这次最多 2 个 16 位码值的修正很小，不能用它解释或解决明显的整体观感差异。**跨相机色彩接近尚未完成**：Apple 显影与输入曝光约定、虚拟 native 源域适配仍需要单独验证；Phocus 的 RAW 去马赛克、镜头／局部处理、HDR 和空间锐化也没有被上表覆盖。工厂 Standard／Nature 均有 `ApplyUSM=true`，强度／半径分别为 100/10、180/8；GlassCam 的 Standard 空间旁路及其余预设的便携 Gaussian USM 不等于原版专有锐化。这些边界应继续通过原生调用和输入约定核查，不以经验抬暗部或添加未经验证的 iPhone 矩阵替代。

此前用户导出的四张 TIFF 已验证为 16 位 Adobe RGB (1998)，保留在[原版导出证据](/Users/vonequinox/.codex/visualizations/2026/10/17/01a1494a-d01c-7dd1-ada5-f601e033d61e/phocus-reference/analysis.json)。它们没有参与本轮二进制数值 oracle。

复现原始程序对比（需要本机 Phocus 4.2.2 挂载和原 HNCS 目录）：

```sh
DYLD_FRAMEWORK_PATH=/Volumes/Phocus/Phocus.app/Contents/Frameworks \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Users/vonequinox/.cache/uv/environments-v2/hncs-pipeline-a8288b4213c44ef4/bin/python \
  -B tools/audit_phocus_binaries.py \
  --reference-root /Users/vonequinox/Program/ProgramDev/HNCS \
  --output-dir /tmp/glasscam-phocus-binary-audit --all-presets
```

便携数值回归运行 `tools/verify_hncs_revision8.py`（保留旧工具名，输出 `validation/hncs_revision9.json`）和 `tools/verify_hncs_revision8_live.py`（输出 `validation/hncs_binary_gradation_dense.json`）。Apple 运行时回归使用 `tools/test_apple_images.py`。
