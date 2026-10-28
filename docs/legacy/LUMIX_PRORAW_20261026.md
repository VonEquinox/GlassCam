# LUMIX revision 2：iPhone ProRAW 成片

本页为 revision 2 的历史实现记录。2026-10-28 的新照片采用统一 camera-neutral 输入和 LUMIX revision 4 有界浮点适配，修复暗部反差和通道回绕，停止对 iPhone 应用松下传感器低 ISO 补偿。原生 RGB48 oracle 和旧照片入口保留。详见[原因与验证](COLOR_INPUT_REPAIR_20261028.md)。

按用户确认的输入范围处理 iPhone ProRAW，并参考现有 HNCS／FFCS 的快照、解码、条带导出、HDR、资源打包和失败重试实现。此版本将 revision 1 的单 LUT 适配扩展为 SILKYPIX 8 SE 中 **DC-S1M2 的完整 SDR 3D-LUT VE 像素分支**。它不是松下传感器／RW2 整机管线的完整复刻。

## 实际路径

1. CIRAWFilter 解码保留的 ProRAW，固定解码器版本、源白点和 BaselineSharpness。新 LUMIX 配方采用 Apple 官方 scene-linear 设置：baselineExposure、shadowBias、boostAmount、localToneMapAmount 为零，关闭 gamut mapping，EDR amount 为零。Apple 解码与细节默认值仍由输入解码器提供。
2. 在扩展线性 sRGB 中沿用 GlassCam 的高光幅度分离，并施加用户曝光。转为白值 65535 的 RGB48，进入经过独立原程序验证的 VE 分支。
3. 根据每张照片的色温选择两张完整 129³ 原始表。色温到选择量的原生折线为 `(3000,256)、(5000,512)、(6500,618)、(7500,725)`；256 以下选择第二张表，512 以上选择第一张表，中间使用原始整数节点混合。**先混合节点，再插值**，没有降低网格。
4. 由照片的 ISO 选择原生 S1M2 ISO 50／64／80 亮度预曲线；其他 ISO 保持原生空预曲线。iPhone 没有松下 PhotoStyle MakerNote，明确采用原生 source-style=0 分支。照片 ISO 的数值映射不构成跨传感器低 ISO 标定。
5. 执行源白值归一化、原生 RGB12 三线性采样、白值反归一化、Y/C 饱和度、黑白有符号色度、原始对比度折线、逐阶段 UInt16 截断／舍入／写回。
6. 原生 SDR 输出按 sRGB EOTF 转回 Float32，恢复 GlassCam HDR 幅度，经现有 10-bit BT.2020/PQ HEIF 路径编码。源元数据、尺寸与 Photos 保存路径沿用已有实现。

原程序还提供 alternate color-space 的分段输入转换；C++ 端也已复刻并与原程序对照。产品输入已由 Core Image 转为线性 sRGB，因此正常成片使用 sRGB 分支。没有为该输入重复串接其他相机型号的 VE 矩阵／色轴分支。

## 参数与恢复

保留原有 16 种 SDR Photo Style，增加原生范围 -5…+5、半级步进的对比度与饱和度。相机设置保存用户选择；照片配方另外冻结源 ISO、白点、色温和渲染版本，重试不会采用随后改变的相机设置。

LUMIX revision 1 照片仍使用原来的第一张 LUT 与 Apple-rendered 输入。新照片及相机偏好迁移到 revision 2。HNCS 和 FFCS 的数值实现及 RAW 输入默认值保持各自原有规则。LUMIX 从先前 HNCS 输入切换时会重新按自身策略解码，不继承 HNCS 的 decoder sharpening=0。

运行时只保留一个不可变色彩上下文；在途条带持有自己的上下文。折线查找不保存原程序可变的上一段索引，保证并发渲染安全。构建期验证两个自包含资源归档，运行期验证压缩表和参数表的长度、格式及 CRC；失败明确报错，不切换颜色引擎。

## 独立验证

原框架 SHA-256 为 `63738fb40fc09a340bceaae351fc41a699601c50d22a9b4a990bd34ed22b826b`。它仅用于电脑离线提取和对照，不进入 iOS 应用。

- 调用原始 `IslVEISFilter3DLUT::FilteringLine`，覆盖 16 种风格、两端与中间色温、全部 65536 级灰阶、随机 RGB、黑与裁剪边界、原始对比度／饱和度、ISO 50／64／80、不同源白值、内部曝光以及两种输入色彩分支。**56 组共 5,506,816 个 RGB48 像素，三个通道逐值一致，最大误差 0**。
- 独立调用原始 `Set3DLUT`，验证温度选择量 256、384、512 的全部 129³ 节点与低 ISO 寄存器，逐值一致。
- 并发分条与整段处理逐位一致。原程序 Ghidra 反编译会重排浮点加法；移植按 SSE 指令的实际运算顺序实现，未用容差掩盖取整误差。
- `tools/test_lumix_images.py` 使用生产 Swift／Core Image／HEIF 路径验证风格预览、完整源图条带、HDR、参数冻结、旧版本与 HNCS／FFCS 兼容。可用 `--proraw` 读取既有 DNG 验证真实完整源图，不触发手机拍照。

结构化数值记录位于 `validation/lumix-full-proraw-20261026/native-verification.json`；本轮构建、真实 DNG 与安装状态记录在该目录的最终 `verification.json`。

生产 Swift 检查通过全部 16 种风格、HDR 条带与整图相同、直接导出与预览后导出相同、参数持久化及旧配方兼容。既有 ISO 400 ProRAW 成功导出 5416×7222 的完整解码尺寸 HEIF；217 项 Python 回归通过。签名 Release 和包内 33 个数据文件校验通过，已覆盖安装到 iPhone；首次安装服务连接中断后重试成功，未启动应用或拍照。真机新拍摄的视觉效果及性能仍需实际使用验收。

## 复刻边界

ProRAW 已包含 Apple 的解码、去马赛克及计算摄影结果，无法把它还原成松下 Bayer 原始采样。松下专用黑电平、坏点、传感器噪声模型、镜头标定、去马赛克与 SmartSharp3 等空间处理没有在这里复刻；输入的解码、降噪／细节处理仍来自 Apple ProRAW。V-Log／HLG 的专用 257³／17³ 分支不作为这 16 种普通显示风格的一部分。

上述零误差证明给定 RGB 输入和参数时 **SDR VE 分支**与原程序一致；不证明 iPhone 成片与松下机内 JPEG／SILKYPIX RW2 成片等价。GlassCam 的跨传感器 sRGB 适配、HDR 幅度恢复和 HEIF 编码是明确的应用输出策略，不能计作原松下 RAW 管线已全部复刻。

ProRAW 输入依据：[Apple WWDC21 — Capture and process ProRAW images](https://developer.apple.com/videos/play/wwdc2021/10160/)。旧版接入记录见 [revision 1](LUMIX_COLOR_20261026.md)。
