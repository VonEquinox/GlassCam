# RAW 输入、ProRAW 控制边界与拍摄延迟调研

日期：2026-10-26。依据 Apple 官方文档、WWDC21／WWDC26、当前 Xcode iOS SDK 公开头文件，以及 GlassCam 当前源码。没有进行本轮真机拍照计时。

## 结论

- 静态照片除了 ProRAW，还可以请求传统 **Bayer RAW**。两者都可存为 DNG，但前者已经过 Apple 去马赛克与部分计算摄影处理，后者保留传感器马赛克样本。
- 可以自行拍一组 RAW，为每张指定快门和 ISO；公开 API 没有提供 ProRAW 内部融合底片的逐张参数数组、底片数量或融合权重，也没有接受自选 RAW 序列并调用 Photonic Engine／Deep Fusion 合成的入口。
- 较新的 Pro 机型另有 **ProRes RAW 视频**入口。这是独立的视频 RAW 工作流，不能直接等同于高分辨率 ProRAW 照片。
- 不能仅根据“ProRAW 是计算摄影格式”推定它始终使用固定数量的底片；格式、传感器、场景、分辨率和质量优先级都会影响实际拍摄路径。公开接口允许表达优先级，不允许指定其内部算法明细。

## 三种输入的差别

| 输入 | Apple 提供的内容 | 控制和接入意义 |
|---|---|---|
| Apple ProRAW | 去马赛克、部分处理后的场景参考 RGB，通常存为 Linear DNG | 保留 Apple 的计算摄影能力；内部合成不开放逐帧控制 |
| Bayer RAW 照片 | 最少处理的传感器马赛克数据，可存为 DNG | 适合手动单帧和自行组织多帧；可继续用 CIRAWFilter 解码后接现有色彩后端 |
| ProRes RAW 视频 | 支持机型的 RAW 视频／对应采样数据 | 可研究连续 RAW 输入；需单独处理视频格式、时间戳、RAW 解码和元数据，性能及可用镜头需实查 |

照片格式通过 `availableRawPhotoPixelFormatTypes` 查询，并用 `isBayerRAWPixelFormat`／`isAppleProRAWPixelFormat` 区分。不能因为文件扩展名都是 `.dng` 就把内容视为相同。

Quad Bayer 的原生 Bayer RAW 通常为像素合并后的输出；不能把“48MP ProRAW 可用”推导成“48MP Bayer RAW 可用”。具体尺寸、镜头、缩放限制必须逐项查询。当前 SDK 的 Bayer RAW 拍摄规则还要求 `.speed`，且设备缩放和输出连接缩放均为 1.0。

普通 HEIF／JPEG、常见 YUV／BGRA 视频帧以及 Apple Log 均不能当作传感器 Bayer RAW；ProRes RAW 是这里需要单独区分的视频 RAW 格式。

来源：

- [Apple：Capturing photos in RAW and Apple ProRAW formats](https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats)
- [Apple：isAppleProRAWEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isappleprorawenabled)
- [WWDC26 Camera and Photo Technologies Group Lab，29:55](https://developer.apple.com/videos/play/wwdc2026/8018/?time=1795)
- [Apple：Record ProRes video with your iPhone camera](https://support.apple.com/guide/iphone/record-prores-video-iphde02c478d/ios)

## 手动曝光与 Apple 多帧的取舍

`setExposureModeCustom(duration:iso:completionHandler:)` 可以请求快门和 ISO，但需要搭配 `.speed` 才能依赖这些锁定值。`.balanced`／`.quality` 允许系统为融合改变实际曝光；读取设备当前的 ISO 并不等于预先知道最终照片或每张内部底片的曝光。

| 请求 | 公开接口能够保证或表达的内容 |
|---|---|
| ProRAW + `.quality` | 画质优先；内部曝光／融合由系统决定 |
| ProRAW + `.balanced` | 速度与画质折中；仍不保证严格遵守手动曝光 |
| ProRAW + `.speed` | 速度优先，可使用受支持的手动曝光；应验证实际尺寸和画质变化 |
| 指定 ProRAW 的内部 N 张底片及每张 ISO／快门 | 没有公开接口 |
| 自行拍 Bayer RAW 包围序列 | 可以用手动包围曝光为各张指定 ISO／快门，逐张接收结果 |
| 把自选序列交给 Apple 的 ProRAW 合成器 | 没有公开入口；需要自行完成融合 |

`.speed` 是质量／速度优先级，不能当成跨设备恒定的“关闭全部处理”或“指定合成帧数为 1”的保证。

Apple 的高分辨率说明还区分优先级：12MP 可以使用三档，48MP 使用 balanced／quality，24MP 的融合成片需要 quality。因此“48MP、精确手动曝光、完整 Apple 多帧质量”不能作为一个保证全部同时满足的配置。

来源：

- [Apple：setExposureModeCustom](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))，并核对本机 `AVCaptureDevice.h` 的公开 API 注释。
- [WWDC26 Group Lab，13:47 手动曝光回答](https://developer.apple.com/videos/play/wwdc2026/8018/?time=827)
- [WWDC21：Capture high-quality photos using video formats](https://developer.apple.com/videos/play/wwdc2021/10247/)
- [WWDC26：Implement high resolution photo capture](https://developer.apple.com/videos/play/wwdc2026/304/)

## 如果需要逐张控制

可用 `AVCapturePhotoBracketSettings` 和 `AVCaptureManualExposureBracketedStillImageSettings` 组织传统 RAW 包围拍摄。例如在支持的范围内请求：

| 张数 | 快门 | ISO | 用途举例 |
|---|---|---|---|
| 1 | 1/500 秒 | 100 | 保留高光 |
| 2 | 1/125 秒 | 100 | 基准曝光 |
| 3 | 1/30 秒 | 100 | 补充暗部 |

这会得到自行管理的多张图像，不是控制了一次 ProRAW 内部的三个曝光。包围数量要检查 `maxBracketedCapturePhotoCount`，曝光参数也要满足当前格式范围。这里不推定 ProRAW 与包围拍摄的任意组合均受支持，确定的方案是传统 Bayer RAW 包围路径。

这些 DNG 可分别经 Apple CIRAWFilter 读取，再自行对齐、融合，最后送入 HNCS／FFCS／LUMIX。可以复用 Apple 的 RAW 解码能力；融合算法需要由应用实现。现有色彩后端可作为后续阶段复用，Bayer 输入的曝光基准、白点和高光策略仍需数值及实拍验证。

来源：[Apple：AVCapturePhotoBracketSettings](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings)、[手动包围参数](https://developer.apple.com/documentation/avfoundation/avcapturemanualexposurebracketedstillimagesettings)。

## ProRes RAW 视频入口的适用范围

Apple 官方说明 iPhone 17 Pro／18 Pro 系列支持通过 Final Cut Camera 等应用记录 ProRes RAW。当前 SDK 公开了 `AVVideoCodecType.proResRAW`／`.proResRAWHQ`，以及 `AVCaptureVideoDataOutput` 的 RAW 录像推荐设置和元数据接口；Core Video 定义 `kCVPixelFormatType_96VersatileBayerPacked12`，其 Bayer 排列及 RAW 转换信息通过附件传递。

这条路径有研究连续 RAW 缓冲、选帧或自行多帧处理的价值。但目前 GlassCam 尚未接入；不能根据格式存在就保证当前镜头、视频尺寸、逐帧曝光切换或去马赛克方案已可用。它同样不提供 Apple ProRAW 内部合成器的控制权。

公开接口：[RAW 视频元数据](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/recommendedmoviemetadata(forvideocodectype:assetwriteroutputfiletype:))、[ProRes RAW codec](https://developer.apple.com/documentation/avfoundation/avvideocodectype/proresraw)、[RAW buffer 格式](https://developer.apple.com/documentation/corevideo/kcvpixelformattype_96versatilebayerpacked12)。

## GlassCam 当前状态与验证顺序

以下保留调研时的源码状态。后续已增加 Speed 12MP／Balanced／Quality 切换，见 [实现说明](CAPTURE_PRIORITY_20261026.md)。

当前 `CameraController.swift`：

- 只选择 ProRAW 格式，回调也只接受 ProRAW。
- `photoQualityPrioritization` 固定 `.quality`。
- 原始拍摄优先选择当前镜头最大可用的 12MP／48MP 尺寸。24MP 是后续成片输出策略，不等于拍摄原生 24MP RAW。
- 双摄取景时，会释放原会话、建立单摄 `.photo` 会话、等待就绪、拍摄，随后恢复取景。

因此现有等待时间可能同时包括会话切换、曝光／Apple 处理、DNG 序列化、完整 RAW 解码、色彩计算、HEIF 编码与相册保存；没有实测前不能把全部延迟归因于 ProRAW 融合。

前面讨论的 `CIRAWFilter` scene-linear、锐化及色调设置发生在 **ProRAW 已经生成之后**，不会减少拍摄阶段的内部合成帧数。

建议先按同一镜头和场景比较以下候选配置，并记录真实尺寸、EXIF、快门延迟、再次可拍时间和最终出片时间：

1. 48MP ProRAW：quality 与 balanced。
2. 12MP ProRAW：speed，验证手动快门／ISO。
3. 当前镜头实际支持的 Bayer RAW：speed。

以此决定是否新增“高画质 ProRAW／快速 RAW”采集选项。色彩模式继续保持 HNCS／FFCS／LUMIX 三选一，与采集格式分开保存。ProRes RAW 连续输入可作为后续独立实验，先验证公开 API 在当前设备上的格式与缓冲能力。
