# SILKYPIX Developer Studio 8 SE 8.0.31.1
# 松下 RAW 处理管线 — 逆向分析报告

分析对象：`SILKYPIX_DS8_SE.8.0.31.1.dmg`（1,578,194,550 字节）
分析主机：macOS（arm64 宿主，目标为 x86_64 二进制）
分析基准：`SILKYPIX8` 32,343,344 B，SHA-256 `63738fb40fc09a340bceaae351fc41a699601c50d22a9b4a990bd34ed22b826b`

---

## 0. 本报告的证据规则（请先读）

用户要求「不要猜任何细节，通通要给出证据」。因此本报告对**每一条结论**标注证据等级：

| 等级 | 含义 | 反证/复核方式 |
|---|---|---|
| **A** | 直接来自二进制中的符号名、字符串、数据表、函数调用序列。可用附录命令复现 | 附录 A 命令 |
| **B** | 来自 A 级证据的解读（如「SetRBFact ⇒ 这是倍率类校正」），语义结论有唯一合理解释，但未逐条验证像素级行为 | 需补 A 级证据 |
| **C** | 结构/顺序已定位，但语义未定 | 已在正文标注「待证」 |

**本报告不使用 C 级内容填充流程描述。**凡未证实的环节，正文明确写「未定位」。

---

## 1. 摘要（先给结论）

1. **目标程序符号表完全未剥离**：`SILKYPIX8` 框架导出/保留 **187,637 条**符号，其中已定义符号 **84,476** 条，C++ 符号 **63,972** 条（`nm -nm` 中含 ` __Z` 的行；按唯一 mangled 名去重为 63,032），Objective-C 方法 **3,154** 条。
2. **二进制内嵌了完整源码路径**（`__FILE__` 宏残留）：**244 条**，根目录为
   `/Volumes/storage/Project_git/ds8-se-src/`。
   → 可以把每个函数精确映射到源文件，这是本报告全部结构结论的基础。
3. 引擎是**滤镜链（IS Chain）架构**：每个处理步骤是一个 `IslEISFilter*` / `IslEISDevelop*` 对象，
   通过 `SetSrc()` 串成链。链的装配函数是 `IslEDevelopISManager::Modify2`（109,438 字节）。
4. **松下拥有独立专属色彩子引擎**：`IslVE*` 命名空间（VE = 松下向处理管线），
   共 10 个滤镜类，由 `IslVEConnectISFilter::Connect` 装配；通用链中还存在条件性的
   `IslEISFilter3DCM`/LAB/UCS 等色彩节点，不能只按品牌把它们排除在 Panasonic 路径之外。
5. **S1M2 在同一程序内被显式支持**，且有按型号命名的 **ISO 档位预 LUT**：
   `preLUT_S1M2_ISO50` / `preLUT_S1M2_ISO64` / `preLUT_S1M2_ISO80`。
   （注意：`preLUT_GH6_ISO*`、`preLUT_S5M2_ISO*` 同构，共 9 张，并非 S1M2 独有。）
6. 每台相机的差异**不是靠配置文件**，而是**编译进二进制的标定数据表** + **从 RW2 MakerNote 读出的机内参数**，
   由 `IslEISInputBayerPanaRAW::MakeUpVEParam` 汇总成 `IslVEConnectISFilter::Parameters`。
7. `GetOpticalBlack`、`GetSamplingMaxValue`、`GetDigitalGain`、`GetWhiteBalanceGain2` 和 4/12 轴读取函数会直接解析对应 MakerNote 字段；
   但这些字段进入具体 S1M2 像素滤镜的先后、缩放和启用条件仍未全部闭合，不能把读取证据等同于完整像素算术。
8. **VE 的 3D LUT 不是固定串在 ToneCurve/矩阵链末尾**：`Connect` 根据两个参数字段选择“ToneCurve→矩阵/轴校正→MixYC”或独立的 3DLUT 分支。

---

## 2. 目标程序清单（A 级）

### 2.1 容器层

| 文件 | 大小（字节） |
|---|---|
| `SILKYPIX_DS8_SE.8.0.31.1.dmg` | 1,578,194,550 |
| `SILKYPIX Developer Studio 8 SE Installer.pkg`（dmg 内唯一文件） | 1,577,103,879 |
| `.app` bundle | 1,600,000,000 量级（`du -sh` = 1.6G） |

`pkgutil --expand-full` 展开后，真正的代码全部在 `Contents/Frameworks/`。

### 2.2 可执行体

| 路径 | 大小（字节） | 架构 | SHA-256 |
|---|---|---|---|
| `Contents/MacOS/SILKYPIX Developer Studio 8 SE` | 52,560 | x86_64 | `9979e2d2475b4b60b71fc3b6fe85bc5ca7f1a5ac0d3469838fbb43e27ca65056` |
| `Contents/Frameworks/SILKYPIX8.framework/Versions/A/SILKYPIX8` | **32,343,344** | x86_64 | `63738fb40fc09a340bceaae351fc41a699601c50d22a9b4a990bd34ed22b826b` |
| `Contents/Frameworks/IslEPIPEC.framework/Versions/A/IslEPIPEC` | 73,760 | x86_64 | `37ab2f7ab362b630c923155ff5f639f264bd35f93c0935bbb3b2917f462d1917` |
| `SILKYPIX8.framework/Versions/A/Frameworks/libTMCNLLDec_OSX.dylib` | 104 KB 级 | x86_64 + i386 | — |

- 主程序只有 52 KB，是**壳**：`otool -L` 显示它只链接 `SILKYPIX8.framework` 等系统框架。
  真正的引擎是 `SILKYPIX8`（31 MB）。
- 主程序、`SILKYPIX8`、`IslEPIPEC` 均为 **x86_64 单架构**（`lipo -archs` 只输出 `x86_64`），
  在 Apple Silicon 上走 Rosetta 2；唯一例外是 `libTMCNLLDec_OSX.dylib`（x86_64 + i386）。
- `IslEPIPEC.framework` 只依赖 `libc++` / `libSystem`，导出 C 接口：
  `IslEPIPEC_Init`、`IslEPIPEC_CalcGainMap`、`IslEPIPEC_End`，
  源文件名 `IslEPIPixelExposureControl.cpp`。

### 2.3 身份与签名

```
CFBundleIdentifier      jp.co.isl.SILKYPIX8SE
CFBundleShortVersionString  8.0.31.1
CFBundleVersion         8.0.31.1
Authority               Developer ID Application: TECHNO HORIZON CO., LTD. (QYVS2B46JA)
Authority               Developer ID Certification Authority
Authority               Apple Root CA
Format                  app bundle with Mach-O thin (x86_64)
```

（`jp.co.isl.*` = 市川ソフトラボラトリー / ICHIKAWA SOFT LABORATORY；`TECHNO HORIZON` 为其 macOS 发行主体。）

### 2.4 资源体积分布

| 资源 | 大小 |
|---|---|
| `Resources/ColorModeDataBin`（330 个 `.s3d`） | **1.5 GB** |
| `Resources/res` | 31 MB |
| `Resources/DefaultParameters.spd` | 7.5 MB |
| `Resources/ColorModeData`（8 个 `.s3d` + `Index.ini`） | 3.9 MB |
| `Resources/DefaultDevelopPresets`（`.spq`） | 3.7 MB |
| `Resources/ChildProcess/MessageProc.app` | 3.3 MB |

→ 整个安装包 ~1.7 GB，其中 **约 90–91% 是色彩 3D LUT 数据**（`1,584,986,093 B / 1,735,225,055 B ≈ 91.3%`）。这本身就是结论：
松下的色彩风格是「预烘焙 3D LUT」而非实时公式。

---

## 3. 为什么可以做到「不猜」（A 级）

### 3.1 符号表未剥离

```
$ nm -a SILKYPIX8 | wc -l
187637
$ nm SILKYPIX8 | grep -E "^[0-9a-f]+ [TtDdBbSsGg]" | wc -l
84476
$ nm -nm SILKYPIX8 | grep -c " __Z"      # 已定义 C++ 符号（行计；去重 63,032）
63972
$ nm -a SILKYPIX8 | grep -cE "^[0-9a-f]+ [A-Za-z] [-+]\["   # 已定义 ObjC 方法
3154
$ nm -nmS SILKYPIX8 | c++filt > 全量带地址符号表（85,340 行）
```

### 3.2 源码路径内嵌（244 条）

二进制 `__cstring` 段保留了编译期 `__FILE__` 字符串，例如：

```
/Volumes/storage/Project_git/ds8-se-src/ds/BasicLibs4DS/IslE/IslEDevelopISManager.cpp
/Volumes/storage/Project_git/ds8-se-src/ds/BasicLibs4DS/IslE/IslEISDevelopOBSubtracter.cpp
/Volumes/storage/Project_git/ds8-se-src/ds/BasicLibs4DS/IslE/IslEISInputBayerPanaRAW.cpp
/Volumes/storage/Project_git/ds8-se-src/ds/BasicLibs4DS/IslVE/IslVEISFilter3DLUT.cpp
/Volumes/storage/Project_git/ds8-se-src/ds/BasicLibs4DS/IslVE/IslVEISFilter4AxisLuminanceMatrix.cpp
/Volumes/storage/Project_git/ds8-se-src/ds/BasicLibs4DS/IslVE/IslVEISFilterToneCurve.cpp
/Volumes/storage/Project_git/ds8-se-src/ds/BasicLibs4DS/IslG/IslGDevelopParam.cpp
/Volumes/storage/Project_git/ds8-se-src/ds/DSLib/NKDGUIWhiteBalance.cpp
/Volumes/storage/Project_git/ds8-se-src/ds/PrmCtrlDataLib/PrmCtrlDataPresetWB.cpp
...
```

目录分布（完整 244 条见 `work/srcpaths.txt`）：

| 目录 | 条数 |
|---|---|
| `ds/BasicLibs4DS` | 188 |
| `ds/DSLib` | 30 |
| `ds/mac` | 15 |
| `ds/DSCommon` | 6 |
| `ds/PrmCtrlDataLib` | 3 |
| `ds/DSLib4Silky` | 2 |

### 3.3 附带证据：断言里带源码行号

函数内联的 `IslZSemaphoreX` 锁会写入 `__FILE__` 指针 + 行号，例如
`IslEDevelopISManager::SetDevelopParam4PIPECScan` 写入
`行号 0x134d (4941)` + `IslEDevelopISManager.cpp`。

---

*（第 1 部分结束，下一部分：模块分层与 RAW 输入层）*

## 4. 模块分层（A 级）

命名空间计数会随统计口径剧烈变化（以 `IslZ` 为例：`nm -a` 含该串 36,807 行、
`nm -nm` 含该串 28,277 行、按 mangled 首段只有 12,511 条），因此本节只给分层关系。
全文引用的硬数字仅限：187,637 / 84,476 / 63,972 / 3,154 / 244（均可复现）。

| 命名空间 | 对应源码根 | 职责 |
|---|---|---|
| `IslZ*` | `BasicLibs4DS/IslBasicLibs/IslZ` | 基础库：容器、位图、缓存、TIFF/EXIF、色彩数学、字符串、线程 |
| `IslE*` | `BasicLibs4DS/IslE` | **IS 处理引擎**（滤镜链、各品牌 RAW 解码、反马赛克、降噪、锐化） |
| `IslG*` | `BasicLibs4DS/IslG` | 开发参数模型 `IslGDevelopParam`、文件数据 `IslGFileData` |
| `DS6*` | `DSLib` / `DSLib4Silky` | 应用层数据模型（`DS6FileData`、`DS6DevelopParamElm_DS`） |
| `IslY*` | `BasicLibs4DS/IslBasicLibs/IslY` | 平台抽象（路径、存储、计时、性能剖析） |
| `DevStudio*` | `mac/DSExecuter` | macOS UI 层 |
| `IslB*` | `IslBTiffMono16BitRead` | `IslBRawReadParam`（RAW 读取参数总入口） |
| `IslBH*` | `BasicLibs4DS/cam3/IslBH` | 哈苏 3FR/FFF 专用解码（JPEG 无损、DIB 读取） |
| `PrmCtrlData*` | `PrmCtrlDataLib` | 参数控件数据（直方图、WB 预设、导出） |
| `IslK*` | `BasicLibs4DS/IslK` | 自动白平衡估算（`IslKAWB`） |
| `IslX*` | `BasicLibs4DS/IslX2` | 调试/断言 |
| **`IslVE*`** | `BasicLibs4DS/IslVE` | **松下专属色彩引擎（VE = 松下向）** |
| `NKD*` | `DSLib` | 应用主干（`NKDMain`、`NKDPreview`、`NKDGUIWhiteBalance`） |
| `IslM*` | `mac/IslM` | 多线程池 `IslMPPBase` |

**关键判断**：`IslVE*` 只有 414 条符号（`nm -nmS SILKYPIX8 | c++filt | grep -c IslVE` 可复现）却能对应 1.5 GB 的 3D LUT 数据，
说明 VE 是「**小型代码 + 巨型数据**」的色彩引擎——这与第 1 节「预烘焙 3D LUT」结论一致。

---

## 5. IS 处理链的架构（A 级）

### 5.1 链式模型

核心类（全部在 `IslEImageServer*` 家族）：

```
IslEImageServer                     图像服务器（对外接口）
 ├─ IslEImageServerInput            输入侧基类
 │   ├─ IslEImageServerInputPanaRAW      ← 松下
 │   ├─ IslEImageServerInputNEF / ARW / CR / CRW / ORF / RAF / PEF / …
 │   └─ IslEImageServerInputJpeg / TiffBase / PSD / Storage
 └─ IslEImageServerFilter*          滤镜侧
     ├─ IslEImageServerFilterFrontEnd   链头
     ├─ IslEImageServerFilterBackEnd    链尾
     ├─ IslEImageServerFilterBuffer     行缓冲/降采样
     ├─ IslEImageServerFilterCache      中间结果缓存
     ├─ IslEImageServerFilterTccb       分块图像（Tiled Color Channel Buffer）
     ├─ IslEImageServerFilterF          函数式滤镜包装
     └─ IslEImageServerFilterRotateMirror
```

单个处理步骤的基类是 **`IslEImageServerFilter`**，其接口由符号证实：

| 方法 | 证据地址 | 语义（B） |
|---|---|---|
| `SetSrc` / `SetSrcISContainer` / `GetSrc` | 有符号 | 建立/读取上游 |
| `OpenSequentialRead` / `CloseSequentialRead` | 有符号 | 顺序读取生命周期 |
| `GetLine` | 有符号 | **逐行拉取**（pull 模型，非整图 push） |
| `SetAccessRegion` / `SetAccessRegionInflate` / `SetAccessRegionToSrc` | 有符号 | 按矩形区域访问，向上游传播所需范围 |
| `GetFilteringRect` / `GetImageRect` / `GetImageValidRect` | 有符号 | 坐标映射 |
| `GetCacheManKey` / `GetCacheManKeyFromSrc` | 有符号 | 缓存键（增量重算） |
| `DebugTraceISChain` | `0xad783e`（`IslEImageServer`） | 沿 Src 反向遍历链，打印 `ClassName:%s`（`IslEImageServerFilter::DebugTraceISChain` @0xade266 只是转发到基类） |

`DebugTraceISChain` 的反编译片段（A 级原文）：

```c
iVar5 = (**(*arg1 + 0xa0))(arg1);          // 取 ClassName
if (iVar5 == 0) Format(&str, "ClassName:Unknown");
else            Format(&str, "ClassName:%s", iVar5);
```

→ 证明每个滤镜实例能自报类名，且链是**沿 `Src` 单向可回溯**的。

### 5.2 链的装配点

| 函数 | 地址 | 大小 | 作用 |
|---|---|---|---|
| `IslEDevelopISManager::Modify` | `0x6c90f6` | 43 B | 薄封装，把 4 个 bool 折成掩码后尾调用 `Modify2` |
| **`IslEDevelopISManager::Modify2`** | **`0x6e0d14`** | **109,438 B** | **真正的链装配 + 参数下发 + 缓存控制** |
| `IslEDevelopISManager::Open` | `0x6ccd58` | 小 | 打开文件 → `OpenISManagerInternal` |
| `IslEDevelopISManager::OpenWithStorage` | `0x6ce046` | 小 | 同上，走 `IslZStorage` |
| `IslE::CreateOpenISForInput` | `0x89b428` | 大 | 由文件创建整条 ImageServer 链 |
| `IslE::Read` | `0x899f06` | 大 | 读图（支持子图、区域、方向） |

`Modify2` 的 109 KB 全部是「if 参数变了 → 换/加/删某个滤镜 → 重新接线」的逻辑。
它的函数级静态变量名直接暴露了缓存检查点（A 级，来自符号表）：

```
IslEDevelopISManager::Modify2(...)::m_GlobalCacheMan4BayerInput
IslEDevelopISManager::Modify2(...)::m_GlobalCacheMan4AfterDemosaic1 / 2 / 4
IslEDevelopISManager::Modify2(...)::m_GlobalCacheMan4AfterTMC
IslEDevelopISManager::Modify2(...)::m_GlobalCacheMan4AfterZoom
IslEDevelopISManager::Modify2(...)::m_GlobalCacheMan4CopyPen1 / 2 / 4
IslEDevelopISManager::Modify2(...)::m_GlobalCacheMan4PCParam
IslEDevelopISManager::Modify2(...)::m_GlobalCacheMan4PIPEC
IslEDevelopISManager::Modify2(...)::m_GlobalCacheMan4ScanMax
IslEDevelopISManager::Modify2(...)::m_CacheMan4Tone
IslEDevelopISManager::Modify2(...)::m_CacheMan4ToneL
IslEDevelopISManager::Modify2(...)::m_CacheMan4UToneL
IslEDevelopISManager::Modify2(...)::m_CacheMan4ContrastCurve4UCSToneModeRGB
IslEDevelopISManager::Modify2(...)::m_CacheMan4ContrastCurve4UCSToneModeRGB_0
```

→ **A 级结论**：引擎把「Bayer 输入 → 反马赛克 → TMC → 变焦 → CopyPen → PIPEC」
这些位置作为可缓存锚点，参数未变时直接从缓存取，不重算上游。这解释了 SILKYPIX 的交互性能来源。

对应的控制枚举也已证实存在：
`IslEDevelopISManager::_CACHE_CONTROL`、`_GAIN_CONTROL`、`_SHADING_CONTROL`、
`_AE_METHOD`、`_THREAD_POSITION`、`_THREAD_PARALLEL_POSITION`、`ISLEISMAN_DIFFMODE`。

---

## 6. RAW 输入层（A 级）

### 6.1 品牌/格式解码器清单

`IslEISInputBayer*` 家族共 **28 个**已定义类（符号表全量列出；其中 `Base`/`Filter`/`NEFGetWB` 为辅助类，纯解码器 25 个）：

```
IslEISInputBayer3FR      IslEISInputBayerARW       IslEISInputBayerBase
IslEISInputBayerCR2      IslEISInputBayerCRW       IslEISInputBayerCanonRawTiff
IslEISInputBayerDCR      IslEISInputBayerDNG       IslEISInputBayerERF
IslEISInputBayerFFF      IslEISInputBayerFilter    IslEISInputBayerGP
IslEISInputBayerKDC      IslEISInputBayerMEF       IslEISInputBayerMOS
IslEISInputBayerMRW      IslEISInputBayerNEF       IslEISInputBayerNEFGetWB
IslEISInputBayerORF      IslEISInputBayerPanaRAW   IslEISInputBayerPanaRW2
IslEISInputBayerPEF      IslEISInputBayerPhaseOne  IslEISInputBayerRAF
IslEISInputBayerSILKYPIXRAW  IslEISInputBayerSR2   IslEISInputBayerSRW
IslEISInputBayerX3F
```

对应 `IslEImageServerInput*` 包装层（`…InputPanaRAW`、`…InputNEF`、`…InputORF` 等），
以及 `IslEISFilterBayer`、`IslEISFilterBayerEffect`、`IslEISFilterBayer2RGB`（Bayer→RGB 出口）。

### 6.2 格式识别机制

`IslEISInputBayerPanaRAW` 上有一组 `Fukkatsu*`（復活 = 插件注册/复活）方法，符号表原文：

```
IslEISInputBayerPanaRAW::FukkatsuNewInstanceSelf
IslEISInputBayerPanaRAW::FukkatsuPreCheckSelf
IslEISInputBayerPanaRAW::FukkatsuGetFileExtSelf
IslEISInputBayerPanaRAW::FukkatsuGetPreCheckBytesSelf
IslEISInputBayerPanaRAW::FukkatsuCheckSelf
IslEISInputBayerPanaRAW::NewMySelf
IslEISInputBayerPanaRAW::Cast
```

→ **A 级接口证据**：二进制保留了「文件扩展名」和「文件头预检」相关接口（`FukkatsuGetFileExtSelf` /
`FukkatsuGetPreCheckBytesSelf` / `FukkatsuPreCheckSelf`）。具体判定优先级和注册表调用路径仍需读调用者，
因此不能仅凭方法名把完整识别算法标成 A 级。
**B 级解读**：`FukkatsuNewInstanceSelf` / `NewMySelf` 的命名符合「每个解码器自注册插件」模型，
但注册表本体未定位。
`Cast()` 把通用 ImageServer 向下转型为松下专用实例，供 `Modify2` 调用 `MakeUpVEParam`（见第 8 节）——这一条是 A 级（调用点 0x6f46e5）。

### 6.3 松下 RW2 解码器能力（接口/方法名证据，像素语义需逐函数确认）

```
IslEISInputBayerPanaRAW::DecodeStrip          条带解码
IslEISInputBayerPanaRAW::Decode1Line          逐行解码
IslEISInputBayerPanaRAW::OpenInternal / CloseInternal
IslEISInputBayerPanaRAW::IsNeedRemoveBlack    是否需要去黑电平
IslEISInputBayerPanaRAW::GetWhiteBalance2     取机内白平衡（第二代）
IslEISInputBayerPanaRAW::GetPhotoStyleFromExifPhotoStyle   机内 Photo Style → 内部枚举
IslEISInputBayerPanaRAW::GetPixelMaxValueStatus           饱和值判定
IslEISInputBayerPanaRAW::CreateDistortion4Panasonic       松下镜头畸变数据
IslEISInputBayerPanaRAW::CreateDistortion4PanasonicFLT64
IslEISInputBayerPanaRAW::Get3DLUTFileName                 3D LUT 文件名
IslEISInputBayerPanaRAW::IsValid3DLUT / Set3DLUT / ReadLUTFromFile
IslEISInputBayerPanaRAW::ReadVEParamFile / ReadVEParamFileInternal
IslEISInputBayerPanaRAW::MakeUpVEParam                    VE 参数总汇
IslEISInputBayerPanaRAW::m_bLeicaExt                      徕卡扩展标志（Leica 版 RW2）
```

另外有松下专用 pass：`IslEISPanaRemoveBlack`（`StartDemosaic` / `DemosaicLine` / `EndDemosaic`），
它的基类是 `IslEISDevelopDemosaicBaseT<unsigned short,17,unsigned short,17>` ——
即目前只能标成**零值/坏点邻域修复 pass**；不能据此证明这里完成了 `OpticalBlackR/G/B` 黑电平减法。
`DemosaicLine` 遇到 0 值时调用 `CorrectPixel` 做邻域插值，`StartDemosaic` 只设置边界，`EndDemosaic` 直接返回。
证据：`work/ev/review_20261023/R12_PanaRemoveBlack_DemosaicLine_pdg.c`、`R16_CorrectPixel_pdg.c`、`R15_PanaRemoveBlack_Start_pdg.c`、`R17_PanaRemoveBlack_End_pdg.c`。

### 6.4 CF2 RAW 解码的已确认调用链（A 级结构，部分公式已确认）

`OpenInternal` 会把 Panasonic MakerNote 中的 CF2 参数逐项读入解码配置：`GammaSlope`、`GammaPoint`、`GammaClipVal`、
四组 Huffman 初值、Huffman 表、ShiftDown、水平/垂直 strip 数量、strip 字节偏移、行偏移、数据尺寸、宽度和高度；
同时读取 `SamplingMaxValue`、Photo Style、Contrast/Saturation shift、`CorrectionInfo` 和 `GetWhiteBalance2`。
调用序列原件见 `work/ev/review_20261023/R31_Pana_OpenInternal_calls.txt`。

两条逐行解码分支为：

```
Decode1Line
  ├─ Decode1Page       8/12-bit 变长字段，4 组 × 3 通道，预测/差分重建
  └─ Decode1Page14     10/14-bit 变长字段，3 组 × 3 通道，预测/差分重建

DecodeStrip
  → IslZISInputBayerPanaRAWPack8::Dec
      → DecRead → DecHuff → Gamma
```

`DecHuff` 已确认会从 bitstream 读取编码数据和动态 bit depth，按配置做符号/差分重建，调用 `AddPreDec` 写入预测平面，
并在需要时调用 `ErrRangeCheck`。`Gamma` 对每个解码样本调用 `GammaCore`；`GammaCore` 做符号扩展、加配置偏移、
0…65535 截断、按多个阈值选择 gamma 段、移位/舍入并应用最大值限制。`Decode1Page`/`Decode1Page14` 还保留了每组
通道的 bit-depth 标志、预测值和末尾 `-0xf` 偏移处理。

这已经证明“CF2 参数被实际消费”和“解码不是简单读裸 16-bit”两点，但 Bayer 平面排列、每个 CF2 配置字段的物理含义、
`ErrRangeCheck` 的全部边界规则以及解码输出到后续黑电平/反马赛克之间的精确数值关系仍需样张或更细的路径跟踪。

---

*（第 2 部分结束，下一部分：松下 RW2 MakerNote 标签表与每相机标定数据）*

## 7. 松下 RW2 MakerNote 标签表（A 级，69 条记录 / 68 个唯一 tag + 1 条终止）

### 7.1 定位方式

二进制 `__DATA.__const` 中有一个符号化静态表：

```
00000000013fd250 (__DATA,__const) external s_TagStringTbl
```

结构为 16 字节/条：`{ uint64 tag; const char* name; }`，共 **69 条记录（68 个唯一 tag，`0x0036` 重复两次）+ 1 条 tag=0 终止记录**。
字符串本体主要在 `__cstring` 的 `0xea0309`–`0xea06bc` 区段；但 `ColorMatrix`（0xe86293）与
`CameraType`（0xe7fa38）复用了区段外的既有字符串。

### 7.2 完整表（原件见 `work/ev/E1_panasonic_tagtable.txt`）

> 注：二进制共 70 条记录 = 69 条记录（68 个唯一 tag）+ 1 条 `tag=0` 终止记录；
> 其中 `0x0036 ExTeleConvAreaEndH` 在表中**重复出现两次**（0x2c0/0x2d0），
> 下面只列一次，完整原始顺序见 `E1_panasonic_tagtable.txt`。

```
tag    dec  名称                        影响阶段
0x0001   1  RawVersion                  RAW 解码
0x0002   2  RawWidth                    RAW 解码
0x0003   3  RawHeight                   RAW 解码
0x0004   4  RawStartPos V               RAW 解码（有效区）
0x0005   5  RawStartPos H               RAW 解码（有效区）
0x0006   6  RawEndPos V                 RAW 解码（有效区）
0x0007   7  RawEndPos H                 RAW 解码（有效区）
0x0008   8  ColorFilter                 CF A 布局
0x0009   9  BayerPattern                CF A 布局
0x000a  10  RawSize                      RAW 解码
0x000b  11  RawPackType                  RAW 解包（压缩格式）
0x000d  13  DarkEnable                   黑电平
0x000e  14  SamplingMaxR                 饱和值
0x000f  15  SamplingMaxG                 饱和值
0x0010  16  SamplingMaxB                 饱和值
0x0011  17  GainR                        ★ 机内白平衡 R 增益
0x0012  18  GainB                        ★ 机内白平衡 B 增益
0x0013  19  PresetWB                     ★ 白平衡预置档位
0x0014  20  ColortempWBGain              ★ 色温→增益映射
0x0015  21  ColorMatrix                  ★ 相机色彩矩阵
0x0016  22  ToneCurveGamma               ★ 机内 gamma
0x0017  23  ISOSpeed                     噪点/增益分级
0x0018  24  DigitalGainR                 数字增益
0x0019  25  DigitalGainG                 数字增益
0x001a  26  DigitalGainB                 数字增益
0x001b  27  Noize                        噪点模型
0x001c  28  OpticalBlackR                ★ 黑电平 R
0x001d  29  OpticalBlackG                ★ 黑电平 G
0x001e  30  OpticalBlackB                ★ 黑电平 B
0x001f  31  DefectPixels                 坏点表
0x0024  36  GainR#2                      双增益传感器（第二通道）
0x0025  37  GainG#2                      双增益传感器
0x0026  38  GainB#2                      双增益传感器
0x0027  39  PresetWB#2                   双增益传感器
0x0028  40  ColortempWBGain#2            双增益传感器
0x002d  45  RawPackDetail                解包细节
0x002e  46  Screennail                   内嵌缩略图
0x002f  47  RecAreaStartV                记录区域
0x0030  48  RecAreaStartH                记录区域
0x0031  49  RecAreaEndV                  记录区域
0x0032  50  RecAreaEndH                  记录区域
0x0033  51  ExTeleConvAreaStartV         扩展长焦区域
0x0034  52  ExTeleConvAreaStartH         扩展长焦区域
0x0035  53  ExTeleConvAreaEndV           扩展长焦区域
0x0036  54  ExTeleConvAreaEndH           扩展长焦区域
0x0039  57  CF2_GammaSlope               CF2 解压
0x003a  58  CF2_GammaPoint               CF2 解压
0x003b  59  CF2_GammaClipVal             CF2 解压
0x003c  60  CF2_HuffmanInitVal0           CF2 解压
0x003d  61  CF2_HuffmanInitVal1           CF2 解压
0x003e  62  CF2_HuffmanInitVal2           CF2 解压
0x003f  63  CF2_HuffmanInitVal3           CF2 解压
0x0040  64  CF2_HuffmanTable              CF2 解压
0x0041  65  CF2_HuffmanShiftDown          CF2 解压
0x0042  66  CF2_NumberOfStripH           CF2 解压
0x0043  67  CF2_NumberOfStripV           CF2 解压
0x0044  68  CF2_StripByteOffsets         CF2 解压
0x0045  69  CF2_StripLineOffsets         CF2 解压
0x0046  70  CF2_StripDataSize            CF2 解压
0x0047  71  CF2_StripWidth               CF2 解压
0x0048  72  CF2_StripHeight              CF2 解压
0x0118 280  StripOffsets2                条带偏移
0x0119 281  ImageCorrection              机内校正开关
0x011a 282  CameraType                   相机型号
0x011b 283  AbberationCorrection         机内色差校正
0x011c 284  CTempInfoForColorCorrection  ★ 色温相关色彩校正
0x011d 285  12AxisColorCorrectionInfo    ★ 12 轴色彩校正（机内 Photo Style）
0x011e 286  4AxisColorCorrectionInfo     ★ 4 轴色彩校正（机内 Photo Style）
```

### 7.3 由该表得到的结论（A 级为主，含 1 条 B 级推断）

1. **黑电平有独立三通道值**（`OpticalBlackR/G/B`），不是单一偏移；
   另有 `DarkEnable` 开关与 `IsNeedRemoveBlack()` 判定；但当前证据还不能把该判断直接对应到黑电平减法或 `IslEISPanaRemoveBlack` 的具体像素操作。
2. **白平衡是「R 增益 + B 增益 + 色温映射表」三元组**，G 增益恒为 1
   （对比第 10 节 `CalcWB` 只返回两个 double，互相印证）。
3. **存在第二套 WB/增益数据**（`GainR/G/B#2` / `PresetWB#2` / `ColortempWBGain#2`）——A 级（标签名）。
   是否为「双增益传感器」的第二套读出，属于 B 级推断，未证。
4. **色彩校正数据有两档**：`4AxisColorCorrectionInfo` 与 `12AxisColorCorrectionInfo`，
   与第 8 节的 `Set4AxisColorMatrix` / `Set12AxisColorCorrection` 一一对应。
5. **压缩格式是松下 CF2 变体**，需要 Huffman 表 + gamma 斜率 + 条带表才能解压，
   解释了为什么通用 RAW 库（如 dcraw）对部分机型支持不全。

### 7.4 标签到读取函数的直接证据

补充反编译确认以下标签并非只存在于字符串表，而是有专门读取函数：

| 读取函数 | 直接读取的 tag | 写入结果 |
|---|---|---|
| `GetOpticalBlack` @ `0x9d3392` | `0x1c/0x1d/0x1e` | 四元素缓冲：R、G、G、B |
| `GetSamplingMaxValue` @ `0x9d662e` | `0x0e/0x0f/0x10` | R/G/B 饱和值 |
| `GetDigitalGain` @ `0x9d650c` | `0x18/0x19/0x1a` | R/G/B 数字增益 |
| `GetWhiteBalanceGain2` @ `0x9d6750` | `0x24/0x25/0x26` | 第二套 R/G/B 增益 |
| `GetAxis12ColorCorrectionInfo` @ `0x9d46ba` | `0x11d` | 12 轴数组，按 MakerNote endian 转成 16-bit 值 |
| `GetAxis4ColorCorrectionInfo` @ `0x9d4a26` | `0x11e` | 4 轴数组，按 MakerNote endian 转成 16-bit 值 |

因此可以把“这些字段会被解析”升级为 A 级；但它们进入具体像素滤镜的先后、缩放和是否在某个相机分支启用，仍需继续追 `OpenInternal`、`MakeUpVEParam` 和运行时链。
证据文件：`work/ev/review_20261023/R39_GetOpticalBlack_pdg.c`、`R40_GetSamplingMaxValue_pdg.c`、`R41_GetWhiteBalanceGain2_pdg.c`、`R42_GetDigitalGain_pdg.c`、`R44_GetAxis12_pdg.c`、`R45_GetAxis4_pdg.c`。

---

## 8. 每相机差异处理：`IslEISInputBayerPanaRAW` 标定函数族（A 级）

这是回答「S1M2 和其他相机有什么不同处理」的核心。

### 8.1 函数签名（符号表原文，保持原样含拼写错误 `Lumimance`）

```cpp
Set3DLUT(CAMERA_ID, int, _PANA_PHOTOSTYLE, u16×6, int, int,
         IslVEISFilter3DLUT::Pana_LUT&, IslVEISFilter3DLUT::LUTContrast&,
         unsigned char&, IslVEISFilter3DLUT::RegDigitalEffectBW&,
         IslVEISFilter3DLUT::LowISOCorrectLUT&, unsigned short&,
         IslVEISFilter3DLUT::Pana_LUT&, PHOTO_STYLE, double&)

Set4x4LinearMatrix(CAMERA_ID, int, u16×6,
         IslVEISFilter4x4LinearMatrix::Reg4x4LMatrix&,
         IslVEISFilter4x4LinearMatrix::Reg4x4LMatrix*&, _PANA_PHOTOSTYLE)

Set4AxisColorMatrix(CAMERA_ID, int, int, _PANA_PHOTOSTYLE, u16×6, int, int,
         _COLORSPACE, IslVEISFilter4AxisColorMatrix::Reg4AxisCMatrix&)

Set4AxisLuminanceMatrix(CAMERA_ID, int, int, _PANA_PHOTOSTYLE, u16×6,
         IslVEISFilter4AxisLuminanceMatrix::Reg4AxisLMatrix&)

Set4AxisLumimanceCorrect(...)            // 拼写同原文
SetSkinSkyCorrect(CAMERA_ID, int, int, _PANA_PHOTOSTYLE,
         IslVEISFilter4AxisLuminanceMatrix::RegSkinSkyColorCorrection&)

Set12AxisColorCorrection(int, int,
         IslVEISFilter12AxisColorCorrection::Reg12AxisColorCorrection&, u16×6)
Set16AxisColorCorrection(...)
Blend16AxisColorCorrection(...) / Blend16AxisColorCorrectionElem(...)

SetGammaColor(CAMERA_ID, int, int, int, int, _PANA_PHOTOSTYLE,
         IslVEISFilterToneCurve::Registers&, IslVEISFilterToneCurve::Registers*&,
         IslVEISFilterToneCurve::Registers&, int)

SetGammaLuminance(CAMERA_ID, int, int, int, int,
         Registers&, Registers*&, Registers&, unsigned char&, _PANA_PHOTOSTYLE,
         unsigned char&, Registers&, Registers*&, int&, double&, int, int)

SetDigitalEffectBW(CAMERA_ID, int, _PANA_PHOTOSTYLE, int, int,
         IslVEISFilterMixYC::RegDigitalEffectBW&)

SetNRSettingModel(IslERawInfo*, IslZTiffExif const*)
```

**A 级结论**：绝大多数标定函数的**第一个参数是 `IslZTiffExifPanasonic::CAMERA_ID`**
→ 处理参数按「相机型号」分派，是**编译进代码的 switch/查表**，不是外部配置文件。
**例外**：`Set12AxisColorCorrection(int, int, Reg12AxisColorCorrection&, u16×6)` 没有 CAMERA_ID
（前两参为 int）；`Blend16AxisColorCorrection` 亦需单独核对。

`u16×6` 这 6 个 `unsigned short` 在多个函数中重复出现，位置固定。
其具体语义（推测为机内 Photo Style 的 6 个子参数）**未逐位验证，记为 C 级，正文不采信**。

### 8.2 每相机静态标定表清单（A 级）

符号表中此类静态数据表共 **214 个**，命名规律：

```
RawRegs<模块><C|Y>_<相机型号>[ISO<档位>]
  C = 一条曲线    Y = 另一条曲线
```

分类统计：

| 类别 | 表数量 |
|---|---|
| `RawRegsToneCurve*` | **147** |
| `RawRegs4AxisLumimanceCorrect*` | 17 |
| `RawRegs4AxisLumimanceMatrix*` | 15 |
| `RawRegs16AxisColorCorrectionParamFile*` | 11 |
| `RawRegsSkinSkyCorrect*` | 9 |
| `preLUT_*` | 9 |
| `RawRegs12AxisColorCorrectionParamFile*` | 2 |
| `RawRegs4x4LinearMatrix*` | 2 |
| `RawRegs4AxisColorMatrix` / `RawRegs4AxisLuminanceMatrix` | 各 1 |

按相机型号出现次数（在表名中）：

```
GH5M2 26   S5 24   S1R 24   G100 18   FZ1000M2 16   GH5 14   GX80 11
S1 8   GX8 7   GH4 7   GH5S 6   TZ200 5   TZ100 5   TZ95 3
S5M2 3   S1M2 3   S1H 3   GX9 3   GH6 3   GF8 3   G9 3
FZ1000 2   TZ90 1   TZ80 1   FZH1 1   FZ80 1
```

> 口径说明：按型号计数合计为 **201**，与总数 214 相差的 **13 张表不带相机型号前缀**（如 `RawRegsToneCurveY`、`RawRegs4AxisColorMatrix`、`RawRegsSkinSkyCorrect`、`RawRegs12AxisColorCorrectionParamFile{H,L}Sat` 等）。
> 214 = 201（带型号）+ 13（无型号）。

### 8.3 Photo Style 覆盖范围（从表名后缀提取，A 级）

```
CINELIKED  / CINELIKED2 / CINELIKEV / CINELIKEV2
FLAT       / LCLASSICNEO / LMONO（含 D/S/Y 三个变体）
VLOG（含 VLOGC / VLOGLC / VLOGLY）/ 709L / 709LY
CTZ60 / CTZ70 / C（默认）/ Y（默认）
```

即：**Photo Style × 相机型号 × ISO 档位** 三维标定，全部硬编码。

### 8.4 S1M2 的专属条目（重点）

S1M2 在符号表中的**全部**标定表条目（穷举，共 3 条，均为 3D LUT 预表）：

```
IslEISInputBayerPanaRAW::Set3DLUT(...)::preLUT_S1M2_ISO50   @0xf3bc90
IslEISInputBayerPanaRAW::Set3DLUT(...)::preLUT_S1M2_ISO64   @0xf3cd70
IslEISInputBayerPanaRAW::Set3DLUT(...)::preLUT_S1M2_ISO80   @0xf3de50
```

对比：`preLUT_GH6_ISO50/64/80`、`preLUT_S5M2_ISO50/64/80` 同构（共 9 张），
所以 preLUT 不是 S1M2 独有，只是命名不同。S1R / S1 / S5 没有 preLUT，
走 `RawRegsToneCurve*_S1RISO50/64/80` 这类曲线表；注意「147」是全部机型的 ToneCurve 表总数，
不是 S1R/S1/S5 单机型的表数。

**A 级事实**：`preLUT_*` 只出现在 `Set3DLUT` 函数内部，紧随 `IslVEISFilter3DLUT::Pana_LUT` 参数之后，
且只对 ISO 50/64/80 三个低档位提供。
**B 级解读**：这是低 ISO 下的「高光肩部预映射表」，先做一次 LUT 预变换再进主 3D LUT，
用于复现机内低 ISO 扩展档的高光滚降。
**C 级（未证）**：S1M2 是否还有未以 `S1M2` 命名的标定数据（例如按 `CAMERA_ID` 走数组下标而非命名表）。

### 8.5 相机型号名池（A 级）

`__cstring @0xea000f`–`0xea02a4`，连续 NUL 分隔字符串 **76 条**（原件见 `work/ev/E2_panasonic_modelnames.txt`）：

```
 0  LEICA                20  DMC-G1               40  DMC-GF5
 1  LEICA CAMERA AG      21  D-LUX 4              41  V-LUX 3
 2  DMC-LC1              22  DMC-GH1              42  DMC-G5
 3  DMC-LX1              23  DMC-FZ38             43  DMC-LX7
 4  DMC-FZ30             24  DMC-FZ35             44  DMC-FZ200
 ...                     ...                      ...
58  DC-GH5S              71  DC-S5D               72  DC-S1M2ES
59  DC-GF10              73  DC-S1RM2             74  DC-S1M2
60  DC-GF90              75  DC-S1M2NT
```

末三条 `DC-S1M2ES` / `DC-S1M2` / `DC-S1M2NT` 与 `DC-S1RM2` 位于**表尾（最新加入）**，
与「按加入时间顺序追加」的维护习惯一致。
另：整包中 `DC-` 前缀型号共 **81 个**，`DC-S1M2*` 系列 3 个。

---

*（第 3 部分结束，下一部分：松下 VE 专属色彩链的确切顺序）*

## 9. 松下专属色彩链 `IslVE*`（A 级）

### 9.1 滤镜家族（10 个类，符号表穷举）

| # | 类 | 证据：该类的方法 |
|---|---|---|
| 1 | `IslVEISFilterToneCurve` | `SetRegs` / `SetRegsLinearMatrix` / `SetRegsGammaContrastSeparate` / `SetVlogLOffset` / `MakeUpCnv` / `MakeUpCnv2` / `MakeUpCnv3` / `MakeUpCnvExtC` |
| 2 | `IslVEISFilter2x3ColorMatrix` | `SetRegs(Reg3x3CMatrix, RegNewYMatrix)` |
| 3 | `IslVEISFilter12AxisColorCorrection` | `SetRegs(Reg12AxisColorCorrection)` / `Reg12AxisColorCorrectionParamFile` |
| 4 | `IslVEISFilter4AxisColorMatrix` | `SetRegs(Reg4AxisCMatrix, uchar)` |
| 5 | `IslVEISFilter4AxisLuminanceMatrix` | `SetRegs(Reg4AxisLMatrix, RegSkinSkyColorCorrection)` |
| 6 | `IslVEISFilterMixYC` | `SetRegs(Reg4AxisLCorrection, RegDigitalEffectBW)` |
| 7 | `IslVEISFilter16AxisColorCorrectionPreProcessH` | 仅构造/析构 |
| 8 | `IslVEISFilter16AxisColorCorrectionPreProcessV` | 仅构造/析构 |
| 9 | `IslVEISFilter16AxisColorCorrection` | `SetRegs(Reg16AxisColorCorrection)` |
| 10 | `IslVEISFilter3DLUT` | `SetRegs(Pana_LUT, LUTContrast, u16, RegDigitalEffectBW, LowISOCorrectLUT, u16, Pana_LUT, double, _COLORSPACE)` / `MakeUpCnv` / `MakeUpCnvPreLUT` |

另有 `IslVEISFilter4x4LinearMatrix`（只在签名中出现，无独立处理函数，
其矩阵通过 `IslVEISFilterToneCurve::SetRegsLinearMatrix` 下发给 ToneCurve）。**A 级**：
`SetRegsLinearMatrix(IslVEISFilter4x4LinearMatrix::Reg4x4LMatrix const&)` 在 `0xa7dc6c`。

### 9.2 链的装配函数与「三步模式」

装配器：

```
IslVEConnectISFilter::Connect(IslZObjContainer<IslEImageServer>*, unsigned char*,
                              IslVEConnectISFilter::Parameters const*, int,
                              IslEThread::_MULTI_THREAD_DIV_ALGOLITHM)   @0x77d278
```

反编译显示，每个阶段的**基本模式**是三步（原文节选，`arg1` = this，`arg2` = IS 容器，`arg4` = Parameters）。
注意：并非所有阶段都严格三步——`16AxisPreProcessH/V` 没有 `SetRegs`，`3DLUT` 走独立分支（见 9.3）：

```c
// ① 写入寄存器
iVar5 = IslVEISFilterToneCurve::SetRegs(*(arg1 + 0x898), arg4+2, arg4+0x48,
                                        *(arg4+0x90), 0, *(arg4+0x94), 0);
// ② 挂入容器（虚表槽 +0x68 = AdditionalSetting<ToneCurve>）
iVar5 = (**(*arg1 + 0x68))(arg1, arg1 + 0x818, var_30h, var_2ch);
// ③ 链尾前移
if (*(arg2 + 0x80) != *(arg1 + 0x898)) {
    IslZObjContainerBase::ReleaseAndSet(arg2, arg1 + 0x818);
}
```

`*(arg2 + 0x80)` 是 `IslEImageServerFilter::m_Src`（容器偏移 0x80，见第 5 节 `SetSrc`）。
`ReleaseAndSet(arg2, …)` 把 `arg2` 指向的新容器替换为当前滤镜
→ **每个阶段把链尾向前推进一格**，因此链序 = `ReleaseAndSet` 的**控制流顺序**。
注意：链序不是函数体地址顺序——编译器会重排基本块，必须按跳转读（见 9.3）。

### 9.3 确切顺序（按 `ReleaseAndSet` 控制流读出）

按 `ReleaseAndSet(arg2, container)` 的真实控制流读 `Connect`（0x77d278），得到：

| 实际序 | 滤镜 | `SetRegs` 地址 | `AdditionalSetting` 槽 | 条件 | 证据（ReleaseAndSet） |
|---|---|---|---|---|---|
| 1 | `IslVEISFilterToneCurve` | `0xa7dbc0` | `+0x68` | 必选 | `0x77d984 ReleaseAndSet(0x818)` |
| 2 | `IslVEISFilter2x3ColorMatrix` | `0x43473a` | `+0x70` | 必选 | `0x77dae7 ReleaseAndSet(0x8a0)` |
| 3 | `IslVEISFilter12AxisColorCorrection` | `0x660aee` | `+0x78` | `arg4+0x1c1 == 0` 时 | `0x77ddce ReleaseAndSet(0x928)` |
| 4 | `IslVEISFilter4AxisColorMatrix` | `0x7444da` | `+0x80` | 必选 | `0x77dd46 ReleaseAndSet(0x9b0)` |
| 5 | `IslVEISFilter16AxisColorCorrectionPreProcessH` | — | `+0x98` | `0x1c1 != 0 && 0x34c != 0` | `0x77debe ReleaseAndSet(0xb48)` |
| 6 | `IslVEISFilter16AxisColorCorrectionPreProcessV` | — | `+0xa0` | 同上 | `0x77dfd7 ReleaseAndSet(0xbd0)` |
| 7 | `IslVEISFilter16AxisColorCorrection` | `0xaa42d0` | `+0xa8` | `0x1c1 != 0` | `0x77e11d ReleaseAndSet(0xc58)` |
| 8 | `IslVEISFilter4AxisLuminanceMatrix` | `0x6633a6` | `+0x88` | 必选 | `0x77e26a ReleaseAndSet(0xa38)` |
| 9 | `IslVEISFilterMixYC` | `0x445534` | `+0x90` | 必选 | `0x77e40b ReleaseAndSet(0xac0)` |
| 10 | `IslVEISFilter3DLUT` | `0x82e2f6` | `+0xb0` | 独立分支（两个参数字段的最小值 ≥ 1） | `0x77d79e ReleaseAndSet(0xce0)` |

关键反证（可直接用 `extract.py` 复现）：

```
0x77dd4f  cmpb $0x0,(arg4+0x1c1) ; je 0x77e122   # 0x77e122 = 4AxisLM 的 NewFunc（callq *0x38）
0x77dd58  cmpb $0x0,0x34c(arg4) ; je 0x77dfdc    # 0x77dfdc = 16Axis 的 NewFunc（callq *0x58）
0x77dd66  leaq 0xb48(%r12),%rbx                  # 否则先做 PreH
0x77e11d  ReleaseAndSet(0xc58)                   # 16Axis
0x77e122  leaq 0xa38(%r12),%rbx                  # 16Axis 之后才回到 4AxisLM
```

→ 16 轴组（PreH/PreV/16Axis）**插在 4AxisCM 与 4AxisLM 之间**，且分三种条件路径
（无 16 轴 / 仅 16Axis / PreH+PreV+16Axis）；**12Axis 与 16Axis 互斥**：`0x1c1 == 0` 时走 12Axis，
`0x1c1 != 0` 时跳过 12Axis、走 16 轴。

**3DLUT 是另一条互斥路径。** `Connect` 在进入上述滤镜建链前计算两个参数字段的最小值：
小于 1 时才进入 ToneCurve→2x3→12/16Axis→4AxisLuminance→MixYC；大于等于 1 时直接构造并接入
`IslVEISFilter3DLUT`，不会在同一次 `Connect` 中再经过前面这组 VE 滤镜。完整控制流证据见
`work/ev/review_20261023/R1_VEConnect_pdg.c`。

> 注：表中 `0x77dd46`（4AxisCM）地址小于 `0x77ddce`（12Axis），但 12Axis 块尾执行
> `goto 0x77daf5` 跳回 4AxisCM，所以**执行序是 12Axis → 4AxisCM**；不能按地址排序。

**说明**：`0x1302100 = vtable(0x13020d8)+0x28`，`0x1302150 = vtable+0x78`——两者是**同一张 vtable 的两段**
（NewFunc 段与 AdditionalSetting 段），顺序由同一份类声明决定，**不能用来证明运行时链序**。
该表只用于「类清单 / 槽位」核对。

### 9.4 每个分支做什么（B 级，依据 SetRegs 和 FilteringLine）

当两个分支字段的最小值小于 1 时，VE 建立以下链：

```
ToneCurve
  → 2x3ColorMatrix
  → [12AxisColorCorrection | 4AxisColorMatrix → 16AxisPreH/V → 16AxisColorCorrection]
  → 4AxisLuminanceMatrix
  → MixYC
```

其中 ToneCurve 可下发 4x4 线性矩阵、VLog 偏移和独立 gamma/contrast；2x3 节点接收 3x3 色彩矩阵与 Y 矩阵；
12Axis 与 16Axis 是互斥条件组；4AxisLuminanceMatrix 还接收肤色/天空校正；MixYC 接收 Y/C 校正与单色效果参数。
这些仍是基于寄存器类型和调用位置的 B 级语义，不能代替逐像素公式。

当分支字段的最小值大于等于 1 时，VE 只建立：

```
IslVEISFilter3DLUT
  Pana_LUT + LUTContrast + LowISOCorrectLUT + preLUT + RegDigitalEffectBW + _COLORSPACE
```

`R9_VE3DLUTFilteringLine_pdg.c` 显示这条路径还做输入通道归一化、可选预处理、增益换算、线性组合、`floor`、
0…65535 裁剪和写回；`R21_PanaLUT_GetValue_pdg.c` 显示 `Pana_LUT::GetValue` 对相邻网格的 8 个角点做三线性插值。

### 9.5 `Parameters` 结构：整套松下数据的容器

`IslVEConnectISFilter::Parameters::Set(...)` 的参数表（符号表原文，30 个参数）
就是**当前已定位的松下 VE 参数字段清单**；它不能证明所有上游 RAW 或下游输出参数都已覆盖：

```cpp
Parameters::Set(
  IslVEISFilterToneCurve::Registers&,                       // 伽马/对比度
  IslVEISFilterToneCurve::Registers&,                       // 第二条曲线
  int, unsigned char,
  IslVEISFilter2x3ColorMatrix::Reg3x3CMatrix&,              // 3x3 矩阵
  IslVEISFilter2x3ColorMatrix::RegNewYMatrix&,              // 亮度矩阵
  IslVEISFilter12AxisColorCorrection::Reg12AxisColorCorrection&,
  IslVEISFilter4AxisColorMatrix::Reg4AxisCMatrix&,
  IslVEISFilter4AxisLuminanceMatrix::Reg4AxisLMatrix&,
  IslVEISFilter4AxisLuminanceMatrix::RegSkinSkyColorCorrection&,
  IslVEISFilterMixYC::Reg4AxisLCorrection&,
  IslVEISFilterMixYC::RegDigitalEffectBW&,
  IslVEISFilterToneCurve::Registers*,                       // VLog
  unsigned char,
  IslVEISFilter4x4LinearMatrix::Reg4x4LMatrix*,             // 线性矩阵
  IslVEISFilter16AxisColorCorrection::Reg16AxisColorCorrection*,
  IslVEISFilterToneCurve::Registers*,
  unsigned char, IslVEISFilterToneCurve::Registers const*,
  int, double,
  IslVEISFilter3DLUT::Pana_LUT*,                            // 主 3D LUT
  IslVEISFilter3DLUT::LUTContrast*,                         // 对比度 LUT
  unsigned short,
  IslVEISFilter3DLUT::RegDigitalEffectBW*,
  IslVEISFilter3DLUT::LowISOCorrectLUT*,                    // 低 ISO 修正
  unsigned short*,
  IslVEISFilter3DLUT::Pana_LUT*,                            // preLUT（S1M2 走这里）
  double,
  IslEImageTypeDefine::_COLORSPACE)                         // 目标色彩空间
```

`Parameters` 的实例化/销毁符号存在（`0x70783a` / `0x707a8e`）。
**尺寸判断**：`Parameters::Set` 最高写到 `+0x770`，ctor 也只初始化到 `+0x770`，
所以 `Parameters` 至少 **0x774 ≈ 1.9 KB**。
（`0x77d1a8` 那个 `memset` 是 `IslVEConnectISFilter::Init()`，尺寸 `0x3c20`、`0x2fb8` 等
属于 ConnectISFilter 的成员/缓冲，不是 `Parameters`。）

### 9.6 VE 链的插入位置（A 级）

`Modify2` 中的调用点（地址连续，同一基本块）：

```
0x6f45e5  IslBRawReadParam::GetOF(_ISLZMATRIX3*)          // 取输出矩阵
0x6f4601  IslZMatrix3::IsSame / Rev / Mul ×3              // 矩阵运算
0x6f46cb  IslVEConnectISFilter::Parameters::Parameters()   // 构造参数容器
0x6f46e5  IslEISInputBayerPanaRAW::Cast(IslEImageServer*)  // 判定「这是松下 RAW」
0x6f4737  IslEISInputBayerPanaRAW::MakeUpVEParam(...)      // 汇总全部标定数据
0x6f4763  IslVEConnectISFilter::Connect(...)               // 插入 VE 链
0x6f4780  IslVEConnectISFilter::Parameters::~Parameters()
```

全二进制只有 **2 个** `Connect` 调用点：`0x6f4763`（带 `Parameters`，建链）与
`0x6f49ec`（`arg2=NULL`、`arg4=NULL`、`r8=1`、`r9=0xa`，条件为栈上 `-0x52b0 == -2`）。
后者走 `Connect` 顶部的 `arg2==NULL` 分支：若 `arg1+0x898 != NULL` 则置 `*arg3=1`，
再调 `Init()` 复位，属于**拆链/复位路径**，不是第二次建链。

→ **A 级结论**：VE 链不是独立管线，而是被**插入到通用 IS 链的中段**，
插入前必须通过 `Cast()` 成功向下转型（即当前输入源确实是松下解码器）。
非松下 RAW 不会进入 VE 链，也不会加载 `ColorModeDataBin` 的 LUT；
但通用链里另有 `IslEISFilter3DCM`（`ColorModeData`，8 个 `.s3d`）的 3D 映射，
所以不能推广成「非松下不加载任何 3D LUT」。

---

*（第 4 部分结束，下一部分：通用 IS 处理链的分阶段清单）*

## 10. 通用 IS 处理链（所有品牌共用）

### 10.1 顺序的证据说明（重要）

`Modify2` 是一个 109 KB 的超大函数，**不适合整体反编译**（Ghidra 会膨胀到不可用）。
本报告采用的取证方法是：

1. 用 `objdump -d` 生成**一次性**全量反汇编（6 秒，178 MB 文本，已缓存）；
2. 在反汇编里按地址顺序抽取全部 `Connect*` / `ModifyIS*` 调用及其**实参构造的类**；
3. 用 `ReleaseAndSet(IslZObjContainerBase const&)` 的存在证明**每个 Connect\* 都是原地推进链尾**
   （已验证 `ConnectShading`@`0x6d585a`、`ConnectSpatialGain`@`0x6d7600`、
   `ConnectOBSubtracter`@`0x6d2c2c`、`IslVEConnectISFilter::Connect`@`0x77d278` 均如此）。

**因此**：同一基本块内 Connect 调用的先后 = 链中的先后。

**但必须交代一个限制（A 级诚实边界）**：
下表是按**函数内代码布局顺序**排列的。`Modify2` 含大量分支与共享尾块，
布局顺序与「某一次具体调用的执行顺序」在**局部**可能不同（例如 VE 链的插入块 `0x6f4763`
在布局上落在 `ModifyISDistortion`(0x6efe41) 与 `ModifyISRotate`(0x6f4d2d) 之间，
但它是条件分支内的块，不表示 VE 一定在畸变校正之后）。
→ **单阶段语义为 A 级；全局严格先后顺序为 B 级**，要升级为 A 级需做运行时跟踪（见第 16 节第 6 项）。

原件：`work/ev/E3_modify2_stage_order.txt`、`work/ev/E6_connect_to_class.txt`。

### 10.2 阶段清单（41 个装配函数 / 127 次调用；表内为 33 行主路径，含 VE 行）

| 序 | 装配函数 | 首次地址 | 次数 | 实际构造的类 | 语义 |
|---|---|---|---|---|---|
| 1 | `ConnectThreadIS` | `0x6e2ef1` | 39 | `IslEISThread` | 多线程切分包装（A: 类名） |
| 2 | `ConnectH2S` | `0x6e321b` | 1 | `IslEISFilterH2S45` | **C 未定位**（源文件 `IslEISFilterH2S45.cpp`） |
| 3 | `ConnectMultiplexer4PIPEC` | `0x6e3808` | 1 | `IslEISFilterMultiplexer` | PIPEC 旁路合流 |
| 4 | `ConnectOBSubtracter` | `0x6e3a95` | 1 | `IslEISDevelopOBSubtracter` | **黑电平减法** |
| 5 | `ConnectNRForQuattroHighlightPixels` | `0x6e47fb` | 1 | `IslEISFilterNRForQuattroHighlightPixels` | 适马 Quattro 高光像素降噪 |
| 6 | `ConnectInterpolationForQuattro` | `0x6e4833` | 1 | `MedianForQuattro` / `InterpolationForQuattro` / `MatrixTransformationForQuattro` | 适马 Quattro 专用插值 |
| 7 | `ConnectSR2Bayer` | `0x6e4e32` | 2 | `IslEISDevelopSR2Bayer` | 超解像 → Bayer |
| 8 | `ConnectNonlinear` | `0x6e5c23` | 2 | `IslEISDevelopNonlinear` | 非线性（线性化 / 色调） |
| 9 | `ConnectRB` | `0x6e5d49` | 2 | `IslEISFilterRB` | R/B 相对倍率校正（倍率色差族，见 10.4） |
| 10 | `ConnectShading` | `0x6e5e45` | 2 | `IslEISFilterShading` | 阴影（镜头暗角）校正 |
| 11 | `ConnectSpatialGain` | `0x6e689f` | 14 | `IslEISFilterSpatialGain` | **白平衡空间增益（多区域 WB）** |
| 12 | `ConnectS2S` | `0x6e7037` | 3 | `IslEISFilterS452S`(+Second/BackEnd) | C 未定位 |
| 13 | `ConnectNR2` | `0x6e70b2` | 5 | `IslEISDevelopNR2` | 降噪（第二代） |
| 14 | `ConnectNR` | `0x6e77ea` | 3 | `IslEISDevelopNR` | 降噪 |
| 15 | `ConnectNonlinearAfter` | `0x6e89a2` | 8 | `IslEISDevelopNonlinear` | 非线性（后半段） |
| 16 | `ModifyISPIPEC` | `0x6ec425` | 1 | `IslEISFilterPIPEC` | 外部 PIPEC 引擎（像素曝光控制） |
| 17 | `ConnectBandNR` | `0x6eccd6` | 1 | `BandNR` + `BandNRFirst` + `BandNRSecond` | 频带降噪 |
| 18 | `ConnectRandomNR` | `0x6ecd28` | 1 | `BandNR` + `BandNRFirst` + `BandNRSecond` | **与 17 构造同一批类**（A 级事实） |
| 19 | `ConnectS2S_EXR` | `0x6ed3f5` | 1 | `IslEISFilterS2S` + `S2SBackEnd` | C 未定位 |
| 20 | `ModifyISSharp` | `0x6ed94c` | 1 | `SmartSharp3` + `First`/`Second`/`After`/`After4PENTAX` + `FilterCache` | 锐化（含宾得专用变体） |
| 21 | `Connect2xV` | `0x6edbd6` | 1 | `IslEISFilter2xV` | 2 倍放大（垂直方向） |
| 22 | `ConnectZoom4BaseImage` | `0x6edebf` | 1 | `IslEISFilterFZoom` | 缩放 |
| 23 | `ModifyISDistortion` | `0x6efe41` | 1 | `IslEISFilterDistortion` + `FillRegion` | 镜头畸变校正 + 补边 |
| 24 | **VE 链插入块** | `0x6f4763` | 2（1 建链 + 1 复位） | `IslVEConnectISFilter::Connect` | **松下色彩链**（第 2 次 @0x6f49ec，`arg2=NULL` 复位；见第 9 节） |
| 25 | `ModifyISRotate` | `0x6f4d2d` | 1 | `IslEImageServerFilterRotateMirror` | 旋转 / 镜像 |
| 26 | `ConnectLayerIS` | `0x6f4d5c` | 1 | `IslEISFilterLayerComposite` | 图层合成（HDR / 多张合成） |
| 27 | `ModifyISJPEG` | `0x6f4d82` | 1 | `IslEISFilterJPEG` | JPEG 输入处理 |
| 28 | `ModifyISWarning` | `0x6f4da4` | 1 | `IslEISFilterWarning` | 过曝/欠曝警告 |
| 29 | `ModifyISFocusDetectWarning` | `0x6f4dc6` | 1 | `IslEISFilterFocusDetect` | 合焦检测 |
| 30 | `ModifyISCmsTransform` | `0x6f4def` | 1 | `IslEISFilterCmsTransform` | **ICC 色彩空间转换** |
| 31 | `ModifyISFullsize` | `0x6f4e17` | 1 | `IslEISFilterFullSize` | 全尺寸输出 |
| 32 | `ModifyISNop` | `0x6f4e39` | 1 | `IslEISFilterNop` | 空操作（占位） |
| 33 | `ConnectUSMAfter` | `0x6f6ebd` | 1 | `IslEISFilterGaussian` + `GaussianPreprocess` | USM 锐化（后端） |

**表外补充**：上表只是主路径，`Modify2` 还装配以下 8 类：

- `IslEConnectISFilterCNR<...>::ConnectCNR` ×12（CromaNRPreprocess / CromaNRV / CromaNRH 三套模板）
- `IslEConnectISFilterDC<...>::ConnectDC` ×2
- `IslEConnectISFilterNR5::ConnectSILKYPIX` ×4
- `IslEConnectISFilterHDR::ConnectSILKYPIX` ×1
- `IslEConnectISFilterDehaze::ConnectSILKYPIX` ×1
- `IslEConnectISMultiAreaWB::Connect` ×1
- `IslEConnectISFilterMultiBlend::Connect` ×1
- `IslEConnectISFilterAddNoise::Connect` ×1

把上述 8 类加上，`Modify2` 内共 **41 个装配函数 / 127 次调用**（逐条见 `work/ev/E3_modify2_stage_order.txt`）。
其中 127 = 表内 33 行合计 **104 次**（含第 24 行 VE 的 2 次：1 建链 + 1 复位）+ 表外 8 类 **23 次**。
所以“主链”实际为 104 − 2(VE) = **102 次**，VE 不在主链内。

另有 `ConnectPixelExposure`（`0x6d1efa`）构造 `IslEISFilter2xH` / `2xV` / `Pyramid` / `PixelExposure`
—— 高像素位移/手持超解像路径。
`ConnectUSM`（`0x6d8436`）、`ConnectGaussian`（`0x6d805e`）、
`ConnectMacroDetail`（`0x6d8e2a`，构造 5 个 `MacroDetail*` 类）在 `Modify2` 主路径中未被调用，
说明由其它入口（局部调整 / 蒙版）装配。
`ConnectMultiplexerIS`（`0x6d1d3c`）同理。
上表的 `ConnectMultiplexer4PIPEC` 才是 `Modify2` 内的同名分派点（`0x6e3808`），两者不要混淆。

**直接构造但未被上述 `Connect*` 统计覆盖的条件色彩节点**：`Modify2` 在 `0x6f1f66` 构造
`IslEISFilter3DCM`，随后调用 `SetMatrix`、`Set3DMapping`、`SetColorLimit`、`SetMustTransform`、
`SetStandardDeviation` 和 `SetTransformMode`，再将其接入图像链。相同函数的其它分支还构造或准备
`IslEISFilterLAB`、`IslEISFilterLABTransform`、`IslEISFilterUCS`、`IslEISFilterUCS2`、
`IslEISFilterGrayAxis` 和 `IslZColorProfile`。这些节点不是每条输入路径都必经，但它们会直接改变 RGB，
应与 `Connect*` 表分开列出。`IslEISFilter3DCM::FilteringLine` 还显示通道增益、3×3 矩阵乘法、色相保护/裁剪和
`IslZColor3DMapping::TransForm` 调用。`R11_Modify2_color_setup_asm.txt` 和 `R28_3DCM_FilteringLine_pdg.c` 是对应证据。

### 10.3 反马赛克实现族（A 级：`Modify2` 直接构造）

`Modify2` 内部直接 `new` 的**主**反马赛克实现共 **12 个**：

```
IslEISDevelopDemosaic0      IslEISDevelopDemosaic43A
IslEISDevelopDemosaicBL     IslEISDevelopDemosaicNN
IslEISDevelopDemosaicHalfBL IslEISDevelopDemosaicSP18SR
IslEISDevelopDemosaicSP10   IslEISDevelopDemosaicSP15
IslEISDevelopDemosaicSP16   IslEISDevelopDemosaicSP17
IslEISDevelopDemosaicSP18   IslEISDevelopDemosaicSP20
```

另有同样在 `Modify2` 内直接构造的 F66 家族（`First`/`First2`/`Second`/`Third` 及 `V1` 变体、
`GDiffH`/`GDiffV`/`Preprocess`）与 `RemoveIsolated` / `RemoveIsolatedSR`。
因此 `Modify2` 直接构造的反马赛克相关类合计 **20+ 个**。

**A 级结论**：反马赛克**不是单一算法**，而是一族按机型/精度选择的实现；
选择逻辑在 `Modify2` 内。用户可见开关为 `IslGDevelopParamUI::SetDemosaicPrecision` /
`GetDemosaicPrecision`（`0x8ef186`），默认值来自
`DS6DevelopParamElm_DS::GetDemosaicPrecisionDefault`（`0xd3a64c`）。

`IslEISDevelopDemosaicSP18::DemosaicLine` 的方法名暴露算法结构（A 级）：
`CalcG0Near` / `CalcG1Near` / `CalcG0viaG` / `CalcG1viaG` /
`CalcRB0Near` / `CalcRBviaG` / `CalcSimpleGG0` / `CalcSimpleGG1` / `CalcSimpleRB1`
—— 即「G 平面两相位先重建，再由 G 引导重建 R/B」的经典方向自适应插值结构。
`SP16Preprocess`/`SP17Preprocess` 另有 `DemosaicLine_SSE2`（`__SSE2` 向量化路径，A 级）。

### 10.4 关于 `IslEISFilterRB` 的语义（B 级，依据实参）

```
ConnectRB(IslZObjContainer<IslEImageServer>*, IslERawInfo const*, IslBRawReadParam const*, unsigned char*, int)
  从 IslBRawReadParam::GetRBMustBe(unsigned char*)     取「是否强制」
  从 IslBRawReadParam::GetRBAberration(double*,double*,polyline*,…, double*×4)  取色差参数
  从 IslELensMustBe::GetRBData(IslZCnvPolyLine*, IslZCnvPolyLine*)              取镜头数据
  构造 IslEISFilterRB
    → SetCenterFact(double, double)
    → SetRBFact / SetLinear / SetZoomQuality
    → CalcRBPolyLine / MakeUpDistortionCnv
```

**B 级结论**：这是「R/B 通道相对图像的径向倍率/位移修正」，即**倍率色差（lateral CA）校正**，
参数来源包含镜头档案与用户手动值。若要升级为 A 级，需读 `CalcRBPolyLine` 的数学实现。

### 10.5 参数模型 `IslGDP*`（A 级）

用户可调参数按模块划分。符号表中 `IslGDP*` 标识符共 **32 个**（含 `IslGDPBase`/`IslGDPBasicFunctions`/`IslGDPStringTable`/`IslGDPTypeDefine` 等非模块项，真正的参数模块约 28 个）：

```
IslGDPWB                 白平衡          IslGDPTone / IslGDPUserTone / IslGDPTmc   色调/TMC
IslGDPCShad              对比度/暗部      IslGDPSat                 饱和度
IslGDPCM                 色彩模式        IslGDPCL                  色彩层级
IslGDPSharp              锐化            IslGDPUSM                  USM
IslGDPNonLinear          非线性          IslGDPBrightness           亮度/曝光补偿
IslGDPRB                 倍率色差        IslGDPShad                 阴影（暗角）
IslGDPDC / IslGDPDist    畸变            IslGDPRotAffine            旋转/仿射
IslGDPLensProfile / IslGDPLensInfo       镜头档案
IslGDPFineColorControl / IslGDPColorConversionTool   精细色彩控制 / 色彩转换工具
IslGDPLuminanceEqualizer 亮度均衡器      IslGDPHotPixel              热像素
IslGDPMarine             水下（Marine）   IslGDPIncidental            附带参数
IslGDPMonochromeInfo4UI  单色信息        IslGDPDA / IslGDPOF         差分/输出矩阵
```

每个模块都有 `IslGDPSet<模块>` 包装类（如 `IslGDPSetWB`、`IslGDPSetTone`）。

---

*（第 5 部分结束，下一部分：白平衡与黑电平的求解逻辑）*

## 11. 白平衡（A 级主体，含 1 处 C 级边界）

### 11.1 求解入口：`IslEDevelopISManager::CalcWB`

```
地址 0x6d0e00    函数 < 1 KB，已完整反编译（work/ev/E5_CalcWB_pseudocode.c）
签名 int CalcWB(double* outR, double* outB, IslBRawReadParam const* param, IslERawInfo const* raw)
```

**A 级结论 1**：白平衡只输出**两个增益**（R、B），G 增益恒为 1。
这与第 7 节 MakerNote 只有 `GainR` / `GainB` 两个标签**互相印证**。

**A 级结论 2**：函数体是一个 30 分支的 `switch`（`cmpl $0x1d; ja` → 30 个 case），分派键为
`IslBRawReadParam::GetWhiteBalance(double*, double*, double*, double*)` 的返回值。
各分支的共同动作是把 `IslERawInfo` 某一档的 `{R增益, B增益}` 乘到基值上（或先重置为 (1,1)）；
但 **0/2 不乘法**：0 强制 (1,1)，2 保持 `GetWhiteBalance`；
1/4/10/…/28 先重置为 (1,1) 再 fall-through 到下一个 case 的条件乘法；
奇数模式 5/11/…/29 直接在基值上乘（见下表）。
**关键：函数有两个返回出口**——成功（`0x6d117f`，返回 0）与失败（`0x6d118f`，返回 -1）；
预置无效时走哪个出口**取决于分支体**：模式 1/3 走成功出口，偶数模式 4/10/…/28 走失败出口。

各分支读取的 `IslERawInfo` 偏移（原件见 `work/ev/E5_CalcWB.txt`）：

| WB 模式 | 有效标志偏移 | 乘入偏移（R / B） | 有效时 | 预置无效时 |
|---|---|---|---|---|
| 0 | — | — | 强制 (1.0, 1.0) | 成功（返回 0） |
| 1 | `+0xc98` | `+0xca0` / `+0xca8` | 先置 (1,1) 再乘预设（fall-through 到 3） | **成功（返回 0），输出保留 (1,1)** |
| 2 | — | — | 保持 `GetWhiteBalance` 返回值 | 成功（返回 0） |
| 3 | `+0xc98` | `+0xca0` / `+0xca8` | 在基值上乘预设（不重置） | **成功（返回 0），输出保留 GetWhiteBalance 基值** |
| 4 | `+0xe80` | `+0xe88` / `+0xe90` | 先置 (1,1) 再乘预设（fall-through 到 5） | **返回 -1**（(1,1) 被丢弃，不输出） |
| 5 | `+0xe80` | `+0xe88` / `+0xe90` | 在基值上乘预设 | 返回 -1 |
| 10 | `+0xcc0` | `+0xcc8` / `+0xcd0` | 先置 (1,1) 再乘预设（→11） | **返回 -1** |
| 11 | `+0xcc0` | `+0xcc8` / `+0xcd0` | 在基值上乘预设 | 返回 -1 |
| 12 | `+0xcf8` | `+0xd00` / `+0xd08` | 先置 (1,1) 再乘预设（→13） | **返回 -1** |
| 13 | `+0xcf8` | `+0xd00` / `+0xd08` | 在基值上乘预设 | 返回 -1 |
| 14 | `+0xd30` | `+0xd38` / `+0xd40` | 先置 (1,1) 再乘预设（→15） | **返回 -1** |
| 15 | `+0xd30` | `+0xd38` / `+0xd40` | 在基值上乘预设 | 返回 -1 |
| 16 | `+0xd68` | `+0xd70` / `+0xd78` | 先置 (1,1) 再乘预设（→17） | **返回 -1** |
| 17 | `+0xd68` | `+0xd70` / `+0xd78` | 在基值上乘预设 | 返回 -1 |
| 18 | `+0xda0` | `+0xda8` / `+0xdb0` | 先置 (1,1) 再乘预设（→19） | **返回 -1** |
| 19 | `+0xda0` | `+0xda8` / `+0xdb0` | 在基值上乘预设 | 返回 -1 |
| 20 | `+0xdd8` | `+0xde0` / `+0xde8` | 先置 (1,1) 再乘预设（→21） | **返回 -1** |
| 21 | `+0xdd8` | `+0xde0` / `+0xde8` | 在基值上乘预设 | 返回 -1 |
| 22 | `+0xe10` | `+0xe18` / `+0xe20` | 先置 (1,1) 再乘预设（→23） | **返回 -1** |
| 23 | `+0xe10` | `+0xe18` / `+0xe20` | 在基值上乘预设 | 返回 -1 |
| 24 | `+0xe48` | `+0xe50` / `+0xe58` | 先置 (1,1) 再乘预设（→25） | **返回 -1** |
| 25 | `+0xe48` | `+0xe50` / `+0xe58` | 在基值上乘预设 | 返回 -1 |
| 26 | `+0xeb8` | `+0xec0` / `+0xec8` | 先置 (1,1) 再乘预设（→27） | **返回 -1** |
| 27 | `+0xeb8` | `+0xec0` / `+0xec8` | 在基值上乘预设 | 返回 -1 |
| 28 | `+0xef0` | `+0xef8` / `+0xf00` | 先置 (1,1) 再乘预设（→29） | **返回 -1** |
| 29 | `+0xef0` | `+0xef8` / `+0xf00` | 在基值上乘预设 | 返回 -1 |
| 6,7,8,9 | — | — | — | 返回 -1（失败） |
| 其它（>29） | — | — | — | 返回 -1（`cmpl $0x1d; ja 0x6d118f`） |

> 说明（**两种返回出口**，见 `work/ev/E5_CalcWB.txt` 与 `E5_CalcWB_pseudocode.c`）：
> 成功出口 `0x6d117f` 写完 `*arg1/*arg2` 后返回 **0**；失败出口 `0x6d118f` 返回 **-1**（不写输出）。
>
> 「先置 (1,1) 再 fall-through 乘预设」描述的是**有效路径**；但**无效路径**随分支体而异：
> - **模式 1/3 的分支体**在标志无效时跳到成功出口 `0x6d117f`：模式 1 输出 (1,1)，模式 3 输出 GetWhiteBalance 基值；
> - **模式 4/10/…/28 的分支体**在标志无效时跳到失败出口 `0x6d118f` 返回 **-1**，那对 (1,1) **不会被输出**。
> 只有模式 0 是纯强制 (1,1)，模式 2 是保持 `GetWhiteBalance` 返回值。

**C 级边界**：上表左侧「WB 模式」的**枚举名字**尚未定位。
二进制内存在 `IslZIniFileIOSection::SearchEnumTable<T>` / `SearchEnum<T>` 模板用于读 ini 枚举表，
若能找到 `IslBRawReadParam::_WB_MODE` 的枚举表，可补全名字。
在此之前**本文不给出「模式 3 = 阴天」这类猜测**。

### 11.2 每档预置项的记录结构（A 级）

由偏移差值反推：

```
+0x00  unsigned char 有效标志       (与 CalcWB 的 flag 偏移一致)
+0x08  double        R 增益
+0x10  double        B 增益
…（按 0x38 步长计，余下约 32 字节为其它字段，未逐字段验证）
```

实测偏移序列：`0xc98, 0xcc0, 0xcf8, 0xd30, 0xd68, 0xda0, 0xdd8, 0xe10, 0xe48, 0xe80, 0xeb8, 0xef0`。
**除首段 `0xc98→0xcc0 = 0x28` 外，其余步长均为 `0x38 = 56` 字节。**
（首段 0x28 之后统一为 0x38 步长。）

### 11.3 自动白平衡（A 级：类与方法名）

| 类 | 方法（部分） | 作用 |
|---|---|---|
| `IslEAutoWBCalc` | `Calc0`… | AWB 主计算 |
| `IslEAutoWBCalcK` | `CaAdjust0` / `CaAdjust0R` / `CaAdjust0_CalcKelvin` / `CaAdjust0_Calcuv` / `ApplyValidRegion` | 色温域 AWB 调整 |
| `IslEAutoWBCalcUW` | — | 另一路 AWB（UW 变体） |
| `IslEWBTargetCalc` | `CalcsRGB2uv` / `Calcuv2sRGB` / `ScansRGBLen2GainTbl` / `Getuv` / `GetColor` / `MakeUpDisplayTccb` | 色度坐标 ↔ 增益换算、取色器 |
| `IslKAWB` | `Calc` / `Calc0` / `Calc1` / `ApplyValidRegion` | 底层 AWB 估算核 |
| `IslKAWBEstimateElement` | — | 估算输入单元（`IslZBuffer<IslKAWBEstimateElement>` 见符号表） |
| `IslEDevelopISManager::CalcAutoWhiteBalance` / `CalcAutoWhiteBalanceK` | — | 引擎侧 AWB 入口 |
| `IslEDevelopISManager::SetAutoWBDefaultGain` / `SetAutoWBDefaultKelvin` / `SetAWBEstimate` | — | 回退与估算注入 |

**A 级结论**：AWB 输出可以落到「增益」或「色温（Kelvin）」两种表示，
且存在 `ScansRGBLen2GainTbl`——即把 sRGB 色度距离预先展开成增益查找表。

### 11.4 白平衡的实际执行位置（B 级）：`IslEISFilterSpatialGain`

白平衡的最终施加**涉及** `IslEISFilterSpatialGain`（A 级：方法名；是否唯一施加点未证，故不写「而是」）。证据：

```
IslEISFilterSpatialGain::Set4MultiAreaWB          ← 4 区域白平衡
IslEISFilterSpatialGain::SetMultiAreaAWBScan
IslEISFilterSpatialGain::MultiAreaWB2SpatialGain  ← 把多区域 WB 转成空间增益图
IslEISFilterSpatialGain::SetBlendFact             ← 与基础 WB 的混合系数
IslEISFilterSpatialGain::MakeUpInternalSpatialGain
IslEISFilterSpatialGain::MakeLine4SpatialGain
IslEISFilterSpatialGain::ApplySpatialGain
IslEISFilterSpatialGain::SearchScanMax
```

对应滤镜侧搜索器 `IslEImageServerFilter::SearchFilterUCS`、`SearchScanMax`、`SearchInputStorage`。

**B 级解读**：SILKYPIX 的 WB 是一张**空间变化的增益图**（gain map），
由「全局 R/B 增益」+「多区域 AWB 偏移」+「混合系数」合成，
`IslEISFilterGrayAxis::SetSpatialGain` 表明灰轴也复用了同一张增益图。
`ConnectSpatialGain` 在 `Modify2` 中被调用 **14 次**（少于 `ConnectThreadIS` 的 39 次、多于
`ConnectCNR` 的 12 次），说明它按不同区域/预览/输出多次插接（B 级推断）。

### 11.5 UI 层（A 级）

```
ds/DSLib/NKDGUIWhiteBalance.cpp
ds/PrmCtrlDataLib/PrmCtrlDataPresetWB.cpp
@"OWhiteBalanceCtrl"
```
即参数对话框 → `NKDGUIWhiteBalance` → `PrmCtrlDataPresetWB` → `IslGDevelopParam`(`IslGDPWB`) → `IslBRawReadParam`。

### 11.6 松下 `GetWhiteBalance2` 的实际补偿

`IslEISInputBayerPanaRAW::GetWhiteBalance2` @ `0x5c17ba` 不是简单把三个标签复制到结构体：

1. 读取 MakerNote `GainR#2/GainG#2/GainB#2`（`0x24/0x25/0x26`）；
2. 对较新版本继续读取 `DigitalGainR/G/B`，按 `(gain × digitalGain + 255) >> 8` 合并；
3. 将 R/B 写入 `IslERawInfo` 的 `+0xca0/+0xca8`，把有效标志写入 `+0xc98`；
4. 按 `CAMERA_ID` 做约 67 个分支，并结合 ISO/曝光相关值选择相机专用修正系数，再经 `Cnv_Ev2Gain` 转成倍率。

这说明“WB 是两个输出增益”仍然成立，但实际倍率已经包含版本、数字增益、相机和 ISO 条件；仅凭 `CalcWB` 的 30 档 switch 不能代表完整的 Panasonic WB 求解。证据：`work/ev/review_20261023/R48_GetWhiteBalance2_pdg.c`。

---

## 12. 黑电平（结构 A 级，公式 B/C 级）

### 12.1 两个实现

| 类 | 地址 | 方法（A 级） |
|---|---|---|
| `IslEISDevelopOBSubtracter` | 构造 `0x8e16d0` / `0x8e1940` | `CalcCorrectionLUT`(`0x8dfcfa`) / `MakeUpLUT`(`0x8e12e8`) / `FilteringLine` / `SearchScanMax`(`0x8e167e`) / `SumElement` / `SumElementRGB` / `LookUpTable` / `m_CacheMan` |
| `IslEISPanaRemoveBlack` | — | `StartDemosaic` / `DemosaicLine` / `EndDemosaic` / `GetCacheManKey` |

### 12.2 当前可证结论

1. 通用 `IslEISDevelopOBSubtracter` 会先建 `LookUpTable`：
   `SumElement` / `SumElementRGB` 逐行累加 → `CalcCorrectionLUT` → `MakeUpLUT` → `FilteringLine` 逐行套用。
   `m_CacheMan` 证明存在缓存，但缓存键和“同一相机+ISO”规则仍未展开。
2. `IslEISPanaRemoveBlack` 不能再标成黑电平减法。它的 `DemosaicLine` 在 0 值处调用 `CorrectPixel`，
   做邻域插值；`StartDemosaic`/`EndDemosaic` 没有黑电平算术。
3. `IsNeedRemoveBlack()` 与 `DarkEnable`/`OpticalBlackR/G/B` 的对应关系仍需沿 RAW 字段消费者确认，
   不能只凭类名和标签名下结论。
4. `IslEISDevelopOBSubtracter::EndFiltering` / `FilteringAfterGetLineSrc` 说明它兼有流式与二遍模式。

### 12.3 黑电平 LUT 公式状态

`CalcCorrectionLUT` 的签名为：

```cpp
CalcCorrectionLUT(IslZVectorN*, double, double, int, double*, double*, double*, IslZVectorN*, IslZVectorN*)
```

目前已从反编译看到 `IslZMath::NormalDistribution`、向量/矩阵构造和 `Make_LUT` 调用；这否定了“仅凭签名
推测为 RGB 独立偏移/斜率”的写法。完整统计量、矩阵含义、边界和最终 LUT 数值仍待解出，等级保持 B/C。

---

*（第 6 部分结束，下一部分：3D LUT 色彩数据文件与输出侧）*

## 13. 色彩数据文件：两套 `.s3d`（A 级）

### 13.1 两套完全不同的格式，共用同一扩展名

| 目录 | 文件数 | 首 4 字节 | 格式 |
|---|---|---|---|
| `Resources/ColorModeDataBin/` | **330** | `ISL_PANA_3DMAP` | 松下 3D 映射表（新版） |
| `Resources/ColorModeData/` | 8 + `Index.ini` | `ISL Multi purpose file format.` | 旧版 ISL 通用容器（胶片模拟） |

`ColorModeData/Index.ini` 全文（A 级，原文）：

```ini
[3DMAP_00000]
BASENAME=FC2_ISLRGB
ID=d2
[3DMAP_00001]
BASENAME=FilmMode(A)_ISLRGB
ID=e8
[3DMAP_00002]
BASENAME=FilmMode(K)_ISLRGB
ID=e9
[3DMAP_00003]
BASENAME=FilmMode(P)_ISLRGB
ID=e7
[3DMAP_00004]
BASENAME=FilmMode(V1)_ISLRGB
ID=e6
[3DMAP_00005]
BASENAME=FilmMode(V2)_ISLRGB
ID=ea
[3DMAP_00006]
BASENAME=SK2_ISLRGB
ID=dc
[3DMAP_00007]
BASENAME=SKFC1_ISLRGB
ID=dd
```

→ 这 8 个是 SILKYPIX 自有的「色彩模式」（FC2 / FilmMode A·K·P·V1·V2 / SK2 / SKFC1），
每项有一个十六进制 ID（`0xdc`–`0xea`）。它们是**与相机无关的通用色彩风格**。

### 13.2 `ColorModeDataBin` 结构（A 级）

按文件名前缀分组（`L{组}{序号}.s3d`）：

| 组 | 文件数 | 大小范围（字节） | 组合计 |
|---|---|---|---|
| `L001xx` | 32 | 12,076 – 30,010,484 | 160.3 MB |
| `L002xx` | 32 | 13,138 – 29,572,087 | 159.4 MB |
| `L003xx` | 34 | 13,234 – 31,786,350 | 167.5 MB |
| `L004xx` | 34 | 13,234 – 31,786,350 | 167.5 MB |
| `L005xx` | 34 | 13,141 – 29,576,148 | 164.0 MB |
| `L006xx` | 40 | 13,141 – 29,576,148 | 186.7 MB |
| `L007xx` | 40 | 12,387 – 30,393,290 | 188.7 MB |
| `L008xx` | 40 | 12,805 – 29,280,653 | 186.8 MB |
| `L009xx` | 44 | 12,812 – 30,605,414 | 204.2 MB |
| **合计** | **330** | | **1.58 GB** |

**注意**：逐文件读 0x18（n³）与 0x42/44/46（三轴）后，330 个文件的网格分布是：
**294 个 129³ + 18 个 257³ + 18 个 17³**。~12–13 KB 的小文件正是 **17³** 网格
（0x18=4,913=17³，三轴 17/17/17），仍含完整 3D LUT，只是分辨率低（很可能是预览/低精度变体）；
257³ 的 18 个文件约 28.8–31.8 MB；129³ 的约 2.3–4.4 MB（实测 2,311,618–4,443,591 B）。

### 13.3 文件头结构（A 级，逐字段验证）

以 `ColorModeDataBin/L00101.s3d`（3,933,516 字节）为例：

| 偏移 | 宽度 | 值 | 含义 |
|---|---|---|---|
| `0x00` | 16 B | `"ISL_PANA_3DMAP\0\0"` | magic |
| `0x10` | u32 | `1` | — |
| `0x14` | u32 | `6` | — |
| `0x18` | u32 | `0x0020C181` = **2,146,689** | **= 129³，网格点数** |
| `0x1C` | u32 | `0x34` = **52** | 扩展头起始偏移 |
| `0x34` | 13 B | `"ISL_3DMAP_V2\0"` | 版本 magic |
| `0x42` | u16 | **129** | 网格 X |
| `0x44` | u16 | **129** | 网格 Y |
| `0x46` | u16 | **129** | 网格 Z |
| `0x48` | u32 | 1024 | 子块偏移/长度 |
| `0x4C` | u32 | 256 | 子块偏移/长度 |
| `0x50` | u32 | 1024 | 子块偏移/长度 |
| `0x60` | u32 | 1024 | 子块偏移/长度 |
| `0x70` | u32 | 1024 | 子块偏移/长度 |

`0x18 = 129³` 与 `0x42/0x44/0x46 = 129,129,129` 对 **L00101 这一个文件**互相印证。
但这不是全体：330 个文件里 129³ 有 294 个、257³ 有 18 个、17³ 有 18 个（见 13.2），
所以只能写「**L00101 是 129³**」，不能写「主 3D LUT 一律 129³」。

**载荷格式（A 级）**：文件总长 ÷ n³ ≈ 1.83 的非整数，是**因为载荷是 Huffman 压缩的**，不是裸 `n³×6`：

（下文统一用 **n = 文件头里的三轴真值**，例如 L00101 的 n=129）

```
IslZColor3DLut::ReadMappingData  @0x7ab5b8
  → IslZHuffman::UncompressHuffman（表 ID 0x12e / 0x130 / 0x131，依次尝试直到成功）
  → IslZColor3DLut::ReadDlt  @0x7ac158
      校验流长 ≥ 2·n³+0xc；校验流的三个维数 == n；按 arg4=0/1/2 三种排布读 int16
IslZColor3DLut ctor @0x7a2840：+0xc8 = n−2（=127）；按 n³ 分配 _ISLZPIXEL48
ReadMappingHeaderV2 @0x7ab172：读 0x68 字节，比对 0xd 字节魔数，取 n = header_u16(0x42)；再令 +0xc8 = n−2
```

（注：`ReadDlt` 实际计算的是 `2·(0xc8+2)³+0xc = 2·n³+0xc`，`(0xc8+2)` 即 n；
易错点：不要把 `+0xc8`（=n−2=127）与 n（=129）混为同一个「grid」。）

这也解释了压缩比：129³×6=12.9 MB → 约 3.9 MB；257³×6=101.8 MB → 约 29 MB；17³×6=29.5 KB → 约 12 KB（约 3.3×）。
`0x48/0x4C/0x50/0x60/0x70` 的 u32 值（1024/256/1024…）仍未逐字段确认，保留为 C 级。

### 13.4 文件名生成逻辑（A 级）

`IslEISInputBayerPanaRAW::Get3DLUTFileName(...)`（`0x5b48c0`），签名：

```cpp
Get3DLUTFileName(CAMERA_ID, _PANA_PHOTOSTYLE, unsigned char*,
                 IslZString*, IslZString*, IslZString*, IslZString*, int*, int*) const
```

反编译显示函数体内含 **10 张跳转表**：

```
0x5ba218  11 分支（CAMERA_ID−0x62 ≤ 0xa，即 CAMERA_ID 98–108）
0x5ba244 / 0x5ba2a8 / 0x5ba304 / 0x5ba360 / 0x5ba3bc
0x5ba40c / 0x5ba45c / 0x5ba4ac
0x5ba4fc  19 分支（PHOTO_STYLE−1 ≤ 0x12，即 Photo Style 1–19）
```

- **硬编码字面量文件名**，形如 `"L00101.bin"`、`"L00102.bin"` … `"L00944.bin"`

反编译输出节选（只显示其中两张表）：

```
switch table (11 cases) at 0x5ba218
switch table (19 cases) at 0x5ba4fc
IslZString::IslZString(&var_5d0h, "L00101.bin", 0x7fffffff, 0xfffffffd);
IslZString::IslZString(&var_5d0h, "L00102.bin", 0x7fffffff, 0xfffffffd);
...
```

符号表中此类硬编码基名共 **324 个**（`L00101.bin` … `L00944.bin`），
分组数量：`L001`=30、`L002`=32、`L003`=32、`L004`=32、`L005`=34、
`L006`=40、`L007`=40、`L008`=40、`L009`=44。

**孤儿文件**：资源目录是 330 个文件，分组为 `L001`=32、`L003`=34、`L004`=34（其余与上表一致）。
差集是 **6 个孤儿文件**：`L00129/130`、`L00329/330`、`L00429/430`——它们都是 129³、约 2.4 MB，
但二进制里没有对应硬编码名，因此 `Get3DLUTFileName` 永远不会选中它们。
这也解释了「324 名 vs 330 文件」的 6 个差额。

**A 级结论**：
1. 基名在代码里**写死**（不是运行时拼数字），因此「相机 → LUT 文件」的映射是
   `CAMERA_ID`（11 分支，98–108）+ `_PANA_PHOTOSTYLE`（19 分支，1–19）→ 硬编码字符串的多层查表
   （函数内共 10 张跳转表，不止 2 张）。
2. 代码里写的是 `.bin`，实际资源是 `.s3d` —— 二进制中的 `"%s.s3d"`（`0xe91331`）负责替换扩展名；
   目录名来自字符串 `"ColorModeDataBin"`（`0xe9218b`）与 `"ColorModeData"`（`0xe9217d`）。
3. 函数返回 **4 个 `IslZString`** 与 **2 个 `int`** —— 说明一次会解析出
   多个候选路径（可能是主 LUT / 备选 LUT / preLUT / 参数文件）与两个数值参数。

### 13.5 外部 `VEParam` 文件与硬编码表的优先级（A 级）

`IslEISInputBayerPanaRAW::MakeUpVEParam`（`0x5bbf94`）内部在 **`0x5bc2f5`** 调用了：

```
IslEISInputBayerPanaRAW::ReadVEParamFile(IslYPathSpecA const&,
      Registers&, Registers&,
      Reg12AxisColorCorrection&,
      Reg4AxisLMatrix&,
      Reg4AxisCMatrix&,
      RegSkinSkyColorCorrection&,
      Reg4AxisLCorrection&)
```

`ReadVEParamFile` 又调用 `ReadVEParamFileInternal`，后者按固定字节数 `memcpy`：

```c
memcpy(arg1, &var_150h, 0x46);   // 0x46 = 70 字节 —— 一组 tone curve 寄存器
memcpy(arg2, &var_108h, 0x46);   // 第二组
// 12 轴 / 4 轴矩阵按 16 位有符号、23 位限制截断：
*arg5 = (var_38h << 0x17) >> 0x17;                    // 符号扩展 23 位
*(arg5 + 2) = ((var_38h >> 0x10) << 0x17) >> 0x17;
RegSkinSkyColorCorrection::SetWithSignExtension(...)
```

**A 级结论**：`MakeUpVEParam` 的执行顺序是：

```
① GetOpenPath() + SetKindString(".bin")
② ReadVEParamFile(...)          // 0x5bc2f5，先读外部 sidecar
   成功 → goto 0x5bd18f（Parameters::Set），跳过全部内建 Set*
   失败 → ③ 用内建 Set* 表逐项填参数
③ SetGammaLuminance / SetGammaColor / Set12AxisColorCorrection /
   Set4AxisColorMatrix / Set4AxisLuminanceMatrix / SetSkinSkyCorrect /
   Set4AxisLumimanceCorrect / SetDigitalEffectBW / Set4x4LinearMatrix /
   Set16AxisColorCorrection / Set3DLUT
④ Parameters::Set
```

即外部 `.bin` **优先且完全取代**内建表，而不是「先内建、再被外部覆盖」。
**A 级**：文件扩展名是 `".bin"`（字符串 @0xe921a3，`SetKindString(".bin")`），
路径是 `IslEImageServerInput::GetOpenPath()` 给出的 RAW 同目录 sidecar。
（`0xfa7c13` 的 `saveParam` 是 `ORenameFilesSettingDialog` 的 ObjC selector，与本通道无关。）

### 13.6 为什么 1.5 GB 的 LUT 无法用公式替代（结论）

- VE 链的 10 个滤镜中，前 9 个都是**小矩阵/多项式/曲线**（每个寄存器组几百字节）；
- 唯一体量大的是第 10 个 `IslVEISFilter3DLUT`，而它加载的 `.s3d` 单文件可达 30 MB；
- `IslVEISFilter3DLUT` 的方法表明 LUT 在运行时被**预编译成转换器**：
  `MakeUpCnv` / `MakeUpCnvPreLUT`，并用 `IslZCacheManKey` 做缓存键。

→ **A 级（资源/装配层）**：每个「相机型号 × Photo Style × 变体」存在预烘焙 3D LUT 资源，
网格为 129³/257³/17³ 三种之一，载荷经 Huffman 压缩；VE 参数还包含 4/12/16 轴寄存器、tone curve、preLUT 和低 ISO 校正。

→ **B/C 级（像素层）**：3DLUT 分支是否被选中取决于 `Connect` 的条件字段；选中后还会执行输入归一化、8 点三线性插值、
增益/对比度/低 ISO 处理、裁剪和 16-bit 写回。仅凭资源体积不能把它概括成“所有路径都由一张 LUT + 前 9 个滤镜串行合成”。

---

*（第 7 部分结束，下一部分：输出侧、待证清单与复现附录）*

## 14. 输出侧（结构 A 级，像素转换 B/C 级）

### 14.1 输出类

```
IslEImageOutput                 输出基类
 ├─ IslEImageOutputTiff
 ├─ IslEImageOutputJpeg
 ├─ IslEImageOutputDNG
 └─ IslEImageOutputStorage
IslGFileData::WriteDevelopedImage(IslYPathSpecA const&, IslGEnvironment const&,
        IslZObjContainer<IslEDevelopISManager>*, IslZProgress*, IslZSize*,
        unsigned char, IslGDPUSM const*, IslGEnvironmentBase::FMT_INFO_TYPE,
        IslELayer4Composition*, IslZTiffExifTypeDefine::_WRITE_BASELINEMPF_TYPE, unsigned char)
```

`WriteDevelopedImage` 的形参说明：写图时**还要传入 `IslGDPUSM`**（输出锐化独立于显示）、
`FMT_INFO_TYPE`（格式信息）、`_WRITE_BASELINEMPF_TYPE`（基线 MPF，即多图文件）。

### 14.2 色彩管理

```
IslEICCProfile            ICC 档案读写
IslZcmsProfile            CMS 档案模型（含 IslZcmsElementFixed16Array / Curve / Measurement 等元素）
IslEISFilterCmsTransform  ICC 变换滤镜（ModifyISCmsTransform 构造，@0x6e086c）
IslEImageServerFilterFrontEnd::SetProfile / SetAutoProfileBySrc / GetAutoProfileBySrc
IslEGeneralParam / IslGEnvironmentBase::FMT_INFO_TYPE
ds/DSLib/NKDColorManagement.cpp
```

**A 级结论（入口/对象）**：存在 `IslEISFilterCmsTransform`，并且 `ModifyISCmsTransform` 会创建或清除 CMS 转换对象。
`SetCmsTransformFromTargetICCColor` 先调用 `IslBRawReadParam::GetColorSpace`，再按返回值选择 `GetCmsTransform` 参数，
所以当前证据支持“存在条件选择的 CMS 工作空间/目标变换”，不支持把内部工作空间写成一个已经确定的固定值。

`IslEISFilterCmsTransform::GetLine` 至少有两条位深路径：32→32 直接调用转换对象，48→32 调用
`IslZcmsTransform::TranslateVia48`。后者会把 32-bit 输入左移 8 位放入 16-bit 中间缓冲，并在非特殊参数时加入 4×4 抖动表，
然后调用 CMS 转换。完整色域映射、裁剪、舍入和 alpha/附加通道规则仍为 B/C 级。

JPEG 还会经过 `MakeUpJpegData`、`DupForJPEG`、`SetICCProfile`、`StoreJpeg2`；TIFF/DNG 则有独立的 bits-per-sample、ICC 写入和 DNG 参数分支。
这些输出格式不能合并成一条已证明相同的色彩路径。证据见 `work/ev/review_20261023/R3_ModifyISCmsTransform_pdg.c`、
`R5_CmsGetLine_pdg.c`、`R24_CmsTranslateVia48_pdg.c`、`R26_SetCmsTransformFromTargetICCColor_pdg.c` 和 `R8_JpegDoOutput_pdg.c`。

**B 级边界**：这不能推出 `.s3d` 按目标色彩空间分别准备；`_COLORSPACE` 会传入 VE 3DLUT 的 `SetRegs`，但其枚举值和具体作用仍未完全解析。

### 14.3 空间/尺寸相关

```
IslEISFilterLanczosHorizon / IslEISFilterLanczosVertical   高质量缩放
IslEISFilterResizeBase / ResizeHorizon / ResizeVertical
IslEISFilterFZoom                                          自由缩放
IslEISFilter2xH / 2xV / Pyramid                            2 倍放大与金字塔
IslEImageServerFilterRotateMirror                          旋转/镜像
IslEISFilterFullSize / IslEImageServerFilterBuffer::CalcReductionFilterObject  预览降采样
```

---

## 15. 全流程总图

> **顺序说明**：VE 链（第 9 节）的链序是 **A 级**（按 `ReleaseAndSet` 控制流读出）。
> 通用链（第 10 节）的**阶段集合**是 A 级，**全局先后**是 **B 级**
> （依据 `Modify2` 内调用点布局 + 原地推进链尾，未做运行时跟踪）。

```
                       ┌─────────────────────────────────────────────┐
 RAW 文件 (.RW2) ─────► │ ① 格式识别                                  │ A
                       │   FukkatsuGetFileExtSelf / PreCheckBytes    │
                       └──────────────────┬──────────────────────────┘
                                          ▼
                       ┌─────────────────────────────────────────────┐
                       │ ② 条带解码 DecodeStrip / Decode1Line        │ A
                       │   PackType / CF2 Huffman / GammaSlope       │
                       └──────────────────┬──────────────────────────┘
                                          ▼
                       ┌─────────────────────────────────────────────┐
                       │ ③ MakerNote → IslERawInfo                    │ A
                       │   GainR/B, PresetWB, ColorMatrix,           │
                       │   OpticalBlackR/G/B, SamplingMaxR/G/B,      │
                       │   4Axis/12AxisColorCorrectionInfo,          │
                       │   PhotoStyle, ISOSpeed, DigitalGainR/G/B    │
                       └──────────────────┬──────────────────────────┘
                                          ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │ ④ 通用 IS 链（IslEDevelopISManager::Modify2 @0x6e0d14）              │
   │                                                                      │
   │  Bayer 输入 ─► 反马赛克(主实现 12 种 + F66 家族) ─► OBSubtracter     │ A/B
   │      ─► Nonlinear ─► RB ─► Shading ─► SpatialGain(=WB)              │
   │      ─► NR2/NR ─► NonlinearAfter                                    │
   │      ─► PIPEC ─► BandNR/RandomNR ─► SmartSharp3                     │
   │      ─► 2xV / Zoom4 / Distortion                                    │
   │                                                                      │
   │      ┌──── 松下分支：Cast() 成功才进入（相对位置仍需运行时确认）───────┐
   │      │ ⑤ VE Connect @0x77d278                                      │
   │      │   条件 A：ToneCurve → 2x3 → [12Axis 或 16Axis]               │
   │      │             → 4AxisLuminance → MixYC                        │
   │      │   条件 B：3DLUT(Pana_LUT + preLUT + LUTContrast + LowISO)     │
   │      │          A/B 由 Parameters 的两个分支字段互斥选择             │
   │      └────────────────────────────────────────────────────────────┘
   │      [条件] 3DCM / LAB / LABTransform / UCS / UCS2 / GrayAxis       │
   │      ─► Rotate/LayerComposite/Warning ─► CMS(条件位深路径)           │
   │      ─► FullSize ─► USMAfter                                        │
   └──────────────────────────────┬───────────────────────────────────────┘
                                  ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │ ⑥ 输出：TIFF / JPEG / DNG / Storage                                  │ A
   └──────────────────────────────────────────────────────────────────────┘

   缓存锚点（A 级，来自 Modify2 静态变量名）：
   BayerInput → AfterDemosaic1/2/4 → AfterTMC → AfterZoom → CopyPen1/2/4 → PIPEC
```

---

## 16. 待证清单（把 B/C 级升级为 A 级的明确步骤）

| # | 待证项 | 现状 | 升级所需 |
|---|---|---|---|
| 1 | `IslBRawReadParam::_WB_MODE` 枚举名 | C | 定位 `IslZIniFileIOSection::SearchEnumTable<IslBRawReadParam::_WB_MODE>` 的枚举表 |
| 2 | `_PANA_PHOTOSTYLE` 的 19 个枚举名 | C | 同上，找 `SearchEnumTable<_PANA_PHOTOSTYLE>` |
| 3 | `IslZTiffExifPanasonic::CAMERA_ID` 的 11 组 → 具体机型映射 | **C（部分解决）**：已确认是 `CAMERA_ID−0x62 ≤ 0xa`（98–108），函数内共 10 张跳转表 | 仍需逐分支读 `L00xxx.bin` 字面量与机型名池的对应关系 |
| 4 | `.s3d` 文件内数据布局 | **A（已解决）**：`ReadMappingData`（0x7ab5b8）→ `UncompressHuffman`（表 0x12e/0x130/0x131）→ `ReadDlt`（0x7ac158）；载荷是 Huffman 压缩的 int16 | 仅剩 0x48/0x4C/0x50/0x60/0x70 子块字段未逐一定义 |
| 5 | `ConnectH2S`/`ConnectS2S`/`ConnectS2S_EXR` 语义 | C | 反编译 `IslEISFilterH2S45::FilteringLine`、`IslEISFilterS2S::FilteringLine` |
| 6 | 通用链严格执行顺序 | B | 运行时跟踪：`DYLD_INSERT_LIBRARIES` + `frida-trace` 挂 `IslVEConnectISFilter::Connect` 与各 `Connect*`，记录调用序列 |
| 7 | `u16×6` 参数语义 | C | 反编译 `Set4AxisLuminanceMatrix` 的 6 个形参使用位置 |
| 8 | `CalcCorrectionLUT` 的像素级公式 | B | 反编译 `MakeUpLUT`（`0x8e12e8`） |
| 9 | 外部 `VEParam` 文件路径规则 | **A（已解决）**：`GetOpenPath()` + `SetKindString(".bin")`，即 RAW 同目录 sidecar；`ReadVEParamFile` 成功时完全取代内建表 | — |
| 10 | 每个 `preLUT_S1M2_ISO*` 的数值内容 | B | 按 `IslVEISFilter3DLUT::LowISOCorrectLUT` / `Pana_LUT` 结构体布局解码静态数据（`0xf3bc90` 起） |
| 11 | `IslEISPanaRemoveBlack` 的真实语义 | **已修正**：当前反编译显示 0 值/坏点邻域插值，不证明黑电平减法 | 继续追 `OpticalBlack*` 字段消费者 |
| 12 | `IslEISFilter3DCM`/LAB/UCS/GrayAxis 条件节点 | **已定位，语义/路径未闭合** | 沿 `Modify2` 的条件块和 `ReleaseAndSet` 做路径敏感追踪 |
| 13 | `Pana_LUT::GetValue` | **A（局部）**：8 点三线性插值、floor、0…65535 裁剪已确认 | 解出网格坐标缩放、preLUT 和后续增益的完整组合 |
| 14 | CMS 位深/抖动和 JPEG/TIFF/DNG 输出 | **B/C**：32→32 与 48→32 分支已定位 | 逐格式追踪 profile、量化、采样、ICC 写入和 DNG 参数 |
| 15 | RAW 标签到消费者、CF2 解码、demosaic 选择 | **CF2 结构已部分升级为 A**：OpenInternal 读取字段，Decode1Page/Pack8/ Gamma 链已定位；B/C 仍在 Bayer 排列、边界和样张路径 | 继续追 `Read`/`OpenInternal` 消费者，并用 RW2 样张验证中间缓冲 |
| 16 | Panasonic `GetWhiteBalance2` 的 67 个相机/ISO 修正分支 | **已定位入口和输出字段，公式 B 级** | 逐分支映射 `CAMERA_ID`、ISO 值和 `Cnv_Ev2Gain` 参数 |

**方法学提醒**：第 6 项指的是**通用链的全局顺序**——它仍为 B 级；VE 链的单函数内顺序已可由
`ReleaseAndSet` 控制流升到 A 级（§9.3），不需要运行时。要把通用链也升到 A 级，需要：
安装该 app → 一张 S1M2 的 RW2 样张 → `frida-trace -m "-IslVEConnectISFilter::Connect"` 与各 `Connect*`。
本次分析只有安装包、无样张、且未安装运行，因此**未做**。

---

## 17. 附录 A：复现命令

```bash
WORK=~/Program/ProgramDev/LumixAnalyze/work
cd $WORK

# A1 挂载与展开
hdiutil attach -nobrowse -readonly SILKYPIX_DS8_SE.8.0.31.1.dmg
pkgutil --expand-full "/Volumes/SILKYPIX_DS8_SE 1/SILKYPIX Developer Studio 8 SE Installer.pkg" pkg

# A2 符号表（全量 / 已定义 / 带地址 / 带地址+反混淆）
B="pkg/Installer.pkg/Payload/SILKYPIX Developer Studio 8 SE.app/Contents/Frameworks/SILKYPIX8.framework/Versions/A/SILKYPIX8"
nm -a  "$B" > sym/all.txt                       # 187,637 行
nm     "$B" > sym/def.txt                       # 84,476 行
nm -nm "$B" | c++filt > sym/demangled.txt       # 带地址 + 反混淆
nm -nmS "$B" | c++filt > sym/sized.txt          # 带地址 + 尺寸
shasum -a 256 "$B"

# A3 内嵌源码路径（244 条）
strings -a "$B" | grep -oE "/Volumes/storage/Project_git/[A-Za-z0-9_/.-]+" | sort -u

# A4 一次生成全量反汇编（约 6 秒 / 178 MB，之后所有查询都基于此）
objdump -d --no-show-raw-insn "$B" > /tmp/sk8.dis

# A5 抽取单个函数的调用序列
python3 tools/extract.py 6e0d14 --calls            # Modify2 的 3224 条调用（注意：不要带 0x 前缀）
python3 tools/extract.py 77d278 --calls            # VE Connect

# A6 抽取松下 MakerNote 标签表（69 有效 + 1 条 tag=0 终止）
python3 -c "
import struct
d=open('$B','rb').read()
def s(o):
    e=d.find(b'\0',o); return d[o:e].decode()
for j in range(0x13fd250,0x13fd6b0,16):
    t,p=struct.unpack_from('<QQ',d,j)
    if 0xe40000<p<0xec0000: print(hex(t),t,s(p))
"

# A7 抽取相机型号名池（76 条）
python3 -c "
d=open('$B','rb').read()
print([x.decode() for x in d[0xea000f:0xea02a4].split(b'\0') if x])
"

# A8 抽取全部每相机标定表名（214 条）
nm -nm "$B" | c++filt | grep -oE "RawRegs[A-Za-z0-9_]*|preLUT_[A-Za-z0-9_]*" | sort -u

# A9 硬编码 3D LUT 基名（324 条）
strings -a "$B" | grep -E "^L[0-9]{5}\.bin$" | sort -u

# A10 小函数反编译（务必加 timeout；不要对 Modify2 这类 100 KB 函数使用）
timeout 120 r2 -q -e bin.relocs.apply=true -e scr.color=0 \
  -c "s 0x6d0e00; af; pdg" "$B"      # CalcWB
timeout 120 r2 -q -e bin.relocs.apply=true -e scr.color=0 \
  -c "s 0x77d278; af; pdg" "$B"      # IslVEConnectISFilter::Connect
timeout 300 r2 -q -e bin.relocs.apply=true -e scr.color=0 \
  -c "s 0x5b48c0; af; pdg" "$B"      # Get3DLUTFileName
```

**工具环境**：`radare2 6.2.4` + `r2ghidra` 插件（提供 `pdg`）、`c++filt`（Xcode CLT）、`python3`。

## 18. 附录 B：证据原文件清单（`work/ev/`）

| 文件 | 内容 | 对应章节 |
|---|---|---|
| `E1_panasonic_tagtable.txt` | 松下 RW2 MakerNote 标签表（69 有效 + 1 终止；0x0036 重复两次） | §7 |
| `E2_panasonic_modelnames.txt` | 相机型号名池 76 条（含字符串地址） | §8.5 |
| `E3_modify2_stage_order.txt` | `Modify2` 中 **41 个装配函数 / 127 次调用**的完整地址顺序（含 CNR×12、DC×2、NR5×4、HDR/Dehaze/MultiAreaWB/MultiBlend/AddNoise 与 VE×2） | §10 |
| `E4_ve_chain_order.txt` | 按 `ReleaseAndSet` 控制流读出的 VE 顺序（含 12Axis/16Axis 互斥条件、ReleaseAndSet 地址与汇编反证） | §9.3 |
| `E5_CalcWB.txt` | 白平衡模式 → `IslERawInfo` 偏移对照表（含 fall-through 行为；首段步长 0x28、其余 0x38） | §11.1 |
| `E5_CalcWB_pseudocode.c` | `CalcWB` 的完整反编译（132 行） | §11.1 |
| `E6_connect_to_class.txt` | 每个装配点实际构造的滤镜类（含 NR5/HDR/Dehaze/AddNoise/MultiBlend/DC/CNR/MultiAreaWB 与 F66 家族） | §10.2 |
| `review_20261023/R1_VEConnect_pdg.c` | VE Connect 的互斥分支、滤镜接入和 3DLUT 分支 | §9.3/§9.4 |
| `review_20261023/R9_VE3DLUTFilteringLine_pdg.c` / `R21_PanaLUT_GetValue_pdg.c` | 3DLUT 运行时处理、8 点三线性插值和裁剪 | §9.4/§13.6 |
| `review_20261023/R12_PanaRemoveBlack_DemosaicLine_pdg.c` / `R16_CorrectPixel_pdg.c` | 松下 RemoveBlack 的零值/坏点插值实现 | §6.3/§12 |
| `review_20261023/R24_CmsTranslateVia48_pdg.c` / `R26_SetCmsTransformFromTargetICCColor_pdg.c` | CMS 位深、抖动和色彩空间选择入口 | §14.2 |
| `review_20261023/R11_Modify2_color_setup_asm.txt` / `R28_3DCM_FilteringLine_pdg.c` | 直接构造的 3DCM 和通用色彩节点证据 | §10.2 |
| `review_20261023/R31_Pana_OpenInternal_calls.txt` | OpenInternal 实际读取的 Panasonic/CF2 参数调用序列 | §6.4 |
| `review_20261023/R32_Decode1Page_pdg.c` / `R33_Decode1Page14_pdg.c` | 8/12-bit 与 10/14-bit 逐行字段、预测和差分重建 | §6.4 |
| `review_20261023/R34_Pack8_Dec_pdg.c` / `R35_Pack8_DecHuff_pdg.c` / `R36_Pack8_Gamma_pdg.c` / `R37_Pack8_GammaCore_pdg.c` | Pack8 Huffman、预测、Gamma 和裁剪链 | §6.4 |
| `review_20261023/R39_GetOpticalBlack_pdg.c` / `R40_GetSamplingMaxValue_pdg.c` / `R41_GetWhiteBalanceGain2_pdg.c` / `R42_GetDigitalGain_pdg.c` | MakerNote 黑电平、饱和值、第二套 WB 增益和数字增益的直接读取 | §7.4 |
| `review_20261023/R44_GetAxis12_pdg.c` / `R45_GetAxis4_pdg.c` | MakerNote 12/4 轴校正数组的直接读取 | §7.4 |
| `review_20261023/R48_GetWhiteBalance2_pdg.c` | Panasonic WB2：第二套增益、数字增益合并及相机/ISO 分支 | §11.6 |
| `../srcpaths.txt` | 内嵌源码路径 244 条 | §3.2 |

## 19. 结论一句话

> SILKYPIX DS8 SE 的松下 RAW 处理 =
>
> **「MakerNote 每相机标定数据」**
> **+「编译进二进制的 214 张每机型标定表」**
> **+「330 个预烘焙 3D LUT（294 个 129³ + 18 个 257³ + 18 个 17³，Huffman 压缩）」**
> **由 `IslVEConnectISFilter::Connect` 按条件选择两条 VE 路径：**
> **A：ToneCurve → 2×3 → [12 轴或 16 轴] → 4 轴亮度 → Y/C；**
> **B：独立 3DLUT（Pana_LUT + preLUT + LUTContrast + LowISO）。**
> **两条路径的运行时数学仍有 B/C 级未决项；外层还存在通用 IS 的条件色彩节点、黑电平 LUT、ICC 位深/抖动和格式输出分支。**
>
> S1M2 与其它机型的差异来自三处：
> ① 型号名池中的 `DC-S1M2 / DC-S1M2ES / DC-S1M2NT` 三个条目；
> ② 按型号命名的 `preLUT_S1M2_ISO50/64/80` 三张低 ISO 预映射表
>   （`GH6`、`S5M2` 也有同构的 3 张，共 9 张，并非 S1M2 独有）；
> ③ 由 `CAMERA_ID`（98–108，11 组）决定的 3D LUT 文件选择分支。

---

## 20. 复核基准与关键校验点

本报告所有 A 级数字均在下列基准上逐条验证：

```
SILKYPIX8  32,343,344 B
SHA-256    63738fb40fc09a340bceaae351fc41a699601c50d22a9b4a990bd34ed22b826b
```

以下是**最容易被误读**的关键点，均已按二进制实测或直接调用点复核，可直接复现：

| 位置 | 实测结论 |
|---|---|
| §9.3 | VE 链序按 `ReleaseAndSet` 控制流读出：`16 轴组` 位于 4AxisCM 与 4AxisLM 之间，3DLUT 为独立分支 |
| §13.2/§13.3 | 330 个 `.s3d` 的网格是 294×129³ + 18×257³ + 18×17³，不是「一律 129³」 |
| §13.5 | `ReadVEParamFile` 先执行；成功则跳过全部内建 `Set*`，外部 `.bin` 完全取代内建表 |
| §11.1 | WB 模式 1/4/10/…/28 是「先置 (1,1) 再 fall-through 乘预设」，不是强制 (1,1) |
| §11.2 | 预置项步长首段 0x28、其余 0x38 |
| §9.5 | `Parameters` 约 1.9 KB（≥0x774）；`0x77d1a8` 是 `ConnectISFilter::Init()` |
| §13.4 | `Get3DLUTFileName` 内共 10 张跳转表；另发现 6 个未被引用的孤儿 `.s3d` |
| §9.3/§9.4 | 3DLUT 与 ToneCurve/矩阵/MixYC 是互斥分支，不是固定串行阶段 |
| §6.3/§12 | `IslEISPanaRemoveBlack` 当前证据是零值/坏点插值，不是已证实的黑电平减法 |
| §14.2 | CMS 有 32→32 与 48→32 位深路径，后者含 16-bit 中间值和抖动表 |
| §6.4 | CF2 参数读取、逐行变长字段、Pack8 Huffman/预测/Gamma 调用链已由直接调用点确认 |

以下为**当前仍为 B/C 级**的项，正文已如实标注，不做推测性填充：

- 通用 IS 链的全局先后顺序（B 级，需运行时跟踪）
- `u16×6` 参数逐位语义（C 级）
- `_WB_MODE` / `_PANA_PHOTOSTYLE` 枚举名（C 级）
- `CAMERA_ID`（98–108）逐分支到机型的映射（C 级）
- `preLUT_*` 的数值语义（B 级）
- 直接构造的 3DCM/LAB/UCS/GrayAxis 节点在 Panasonic 具体路径上的触发条件和先后（B/C 级）
- CMS `TranslateVia48` 的完整色域映射/舍入及 JPEG/TIFF/DNG 编码细节（B/C 级）
- Panasonic `GetWhiteBalance2` 的相机/ISO 修正系数逐分支语义（B 级）

---

*报告完*
