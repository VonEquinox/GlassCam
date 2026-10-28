# 直接拼接、透明尺度与 Apple 多摄接口 · 2026-10-25

本文件覆盖此前同日 v4“未知默认透明＋单应／光流矫正”的显示策略。用户明确要求：外围不追加矫正，直接拼接；原始接缝错位小则透明，大则不透明。继续优先让多数普通场景可用，但不能为追求透明率放过已确认的坏场景。

## 最新现场反例

15:30:35 保存的 `record-1792913435797-F96EE7D0` 已从手机复制到 Mac，44 个文件逐一校验通过。容差 4.00，180 条历史状态全部提交零遮罩。实际显示记录包含非单位单应矩阵及强度 1.00 的局部光流，证明外围确实被矫正；另有最高约 2 倍线性颜色增益。

原始两路画面是近距离笔记本电脑。主摄和超广角在接缝处看见的键盘、屏幕及桌面位置明显不同。旧诊断已给出约 14.15% 短边的局部错位下界，但 v4 把缺少对应纹理的区域丢出误差统计，且容差 4 把平坦阈值放大，把真实结构当作低纹理。这次明确标记为必须遮黑的用户反例，不能当作“普通场景都透明”的成功样本。

原始目录：`~/Library/Developer/GlassCamDiagnostics/transparency-review-20261025/latest-feedback-record-1792913435797-F96EE7D0/`。

## 实施

- 实际显示只读相机交付的超广角／较广镜头帧，按真实视场比例等比缩放、居中采样。单应拟合、旋转／透视拉伸、局部光流和额外 RGB 补偿都不再进入显示。相机 ISP 已交付的预览处理不是 Bayer 原始采样；本改动移除的是应用追加的场景自适应矫正。
- 生产分析器也只检查同一固定视场映射，停止发起单应配准与密集光流任务。不能先矫正图像，再用矫正后的低残差作为原始拼接能透明的理由。
- 允许在灰度分析图中寻找对应纹理，测出位移；该位移只决定遮罩，不用于移动任何显示像素。
- 一个普通 3–5 分析像素的平移会让零位移 NCC 很低，因此有完整局部对应时按位移判断，不能再直接把低 NCC 当作大错位。
- 一路有明显结构、另一路附近没有对应结构时，作为缺失结构累计。容差只扩大允许位移，不能扩大平坦分类阈值、把键盘／文字变成“无纹理”。真实低纹理天空的模糊相关峰也不能当作严重位移。
- 遮罩按边统计；用户随后要求上下统一跟随较黑的一块，因此最终上、下遮罩取两者较大值，渐暗与恢复过程也保持一致。默认容差 1 的可见错位渐暗范围为短边约 4%–10%；容差 4 为约 5.66%–14.14%。明显结构缺失独立保护，不能被容差取消。这是显示经验阈值，不是镜头的光学畸变百分比或标定误差。
- 尚未完成首个原始接缝判断时保持遮罩；GPU 继续上传新鲜像素。已有坏判断不会因分析暂时没更新而变透明，超过 0.65 s 没有新判断会渐暗。短暂几十毫秒的匹配／上传间隙不重启整套恢复。
- 新记录保存每边可见误差、对应比例、缺失结构比例、局部大位移下界和原始判断时间，区分“错误”与“还没检查”。

历史 `PeripheralDenseRefinement` 仅留作原有原始数据重建与旧回归工具；生产 `analyze` 不再启动它，实时 `image()` 也不调用它。测试专门向分析结果塞入非单位矩阵、光流和颜色增益，验证实际显示仍是固定视场与原始像素。

## Apple 有什么专用接口

| 目的 | 公开接口 | 本项目中的含义 |
|---|---|---|
| 两颗摄像头同时取流 | `AVCaptureMultiCamSession`、两个 `AVCaptureVideoDataOutput` | 可以直接得到主摄＋超广角、长焦＋主摄的独立视频帧；设备组合和格式必须查询实际支持。 |
| 虚拟多摄协同 | `.builtInDualWideCamera`、`.builtInDualCamera`、`.builtInTripleCamera` | 分别对应超广＋主、主＋长、三摄；系统可以根据变焦、曝光和对焦条件切主镜头。 |
| 从虚拟多摄分别取得子镜头流 | `AVCaptureDeviceInput.ports(for:sourceDeviceType:sourceDevicePosition:)` | 取出物理子镜头的视频端口，各接一个输出。普通 `input.ports` 中不包含这些子端口，不能把同一普通视频流复制两份当双摄。 |
| 检查资源与组合 | `supportedMultiCamDeviceSets`、`isMultiCamSupported`、`hardwareCost`、`systemPressureCost` | 本轮为当前独立物理输入路径加了组合预检查，避免对不支持的镜头组合反复重建会话。 |
| 时间对应 | `AVCaptureDataOutputSynchronizer`、原始 PTS／时钟 | 用于组织和核对同时间的输出；不自动消除视差、不负责 UI 拼接。 |
| 照片／ProRAW | `AVCapturePhotoOutput`、`isAppleProRAWSupported`、`availableRawPhotoPixelFormatTypes`、`supportedMaxPhotoDimensions` | 必须在实际连接和格式下查询，不能仅按手机型号推断当前会话一定能拍最高规格。 |

Apple 的 [MultiCam 介绍与示例](https://developer.apple.com/videos/play/wwdc2019/249/) 说明多输入／多输出与显式连接，由应用自己合成画面；[子镜头端口文档](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/ports(for:sourcedevicetype:sourcedeviceposition:)) 明确给出了主摄、长焦分流的例子。当前可查的公开接口没有自动实现本项目这种“原始外围直接拼接并判断透明度”的完整 UI 功能。

[Dual Wide](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtindualwidecamera)、[Dual Camera](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtindualcamera) 与 [Triple Camera](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtintriplecamera) 的系统自动切镜、部分融合／深度能力也不等于外围画面自动拼接。支持的双摄可由图像视差生成深度，这不是必然调用 LiDAR；但该能力依赖格式，并不直接提供我们要显示的原始接缝误差。本轮不增加深度／雷达依赖。

## 双摄预览，单摄成像，再恢复双摄

这是合理的工程选择，当前 `CameraController` 已经这样工作：

1. `promotePreview` 为当前成片镜头选择更广的外围镜头：主摄优先超广角；长焦优先主摄。配置支持的双摄格式和两路独立输出。
2. `capture` 保留最后预览，停止多摄图，使用被选中的物理镜头建立普通 `AVCaptureSession` 的照片图，启用实际支持的 ProRAW 与最高目标尺寸。
3. `finishPhoto` 等照片回调结束，恢复单摄预览后重新提升为双摄，等待新帧并替换预览资源。

这不是 Apple 强制所有 App 都必须这样做。[MultiCam](https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession/) 本身允许照片输出，也允许动态关闭单个输入而不停止其他输入；普通 JPEG／HEIF 或特定受支持格式可以评估在同一多摄会话拍照。我们的切单摄路径服务于目前的全分辨率 ProRAW／画质要求，不能从“MultiCam 能拍照”推断所有组合都能同时提供相同最高规格。

[ProRAW 官方指南](https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats) 要求在实际会话连接后检查支持；[最高画质优先级](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxphotoqualityprioritization) 文档说明 MultiCam 默认偏向速度，运行中改最高画质会重建管线、打断预览。Apple [WWDC26 相机工程师答疑](https://developer.apple.com/videos/play/wwdc2026/8018/) 继续强调：会话重配置应在后台串行队列中用 begin/commitConfiguration 合并处理。当前代码遵循该线程模型。

本机 iOS SDK 的 `AVCaptureSession.h` 还注明，iOS 26 起当 MultiCam 只有单个输入时，不再一律强制使用 MultiCam 格式。因此以后可以评估在同一个会话对象内移除外围输入、切照片格式、拍完再恢复，减少重建。但“只禁用外围连接”是否足以获得当前最高 ProRAW 配置，须在目标手机查询验证，不能凭接口名称保证；本轮没有未经真机验证改掉已有成片流程。

## 验证及边界

- 用户指定的近距离电脑反例：Tolerance 4 时上、下外围均判为 100% 遮罩。
- 新 10 组原始场景：Tolerance 4 时均达到近乎完全打开（最大遮罩小于 0.1%）；Tolerance 1 时 7 组完全打开，其余有适量局部渐暗，所有外围区域仍可见。
- 旧 12 组原始场景分别在容差 1 和 4 重放；数值见验证 JSON。保留实际渐暗的近景／重复结构，不再把“全部透明”当成唯一验收指标。
- 同时加入真实近距离电脑负例与远景小位移正例，避免在“全黑”和“全透明”之间来回调阈值。
- 验证未检查的初始帧不放行、持续更新已检查帧不黑闪、已知错误不因测量缺席而自动消失、原生 CPU／CI／Metal、AddressSanitizer、原始数据与 ZIP 以及 Python 回归。

只读取了用户要求的最新记录，没有拍新照片。新安装包尚未安装，本轮的图像与计时验证均在 Mac；主摄／超广角真实静态记录不冒充长焦／主摄的真机结果。

完整结果和签名包指纹：`validation/direct-stitch-20261025/verification.json`。对照图 `comparison/comparison.png` 左侧是根据记录的源帧与模型重建的旧矫正图，中间是仅用于比较的强制可见直接拼接图，右侧是新版实际遮罩决策；三者都不是手机截图，不含系统 Liquid Glass。
