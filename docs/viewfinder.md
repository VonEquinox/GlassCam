# 取景与成片回看

取景界面以完整窗口确定照片区，再把控制项安排到剩余空间。系统取景、实验实时色彩和成片回看各有显示入口；照片处理与导出由图像管线负责。

## 工作方式

### 照片区与控制区

`CameraFraming` 按相机照片宽高比，在完整窗口中求最大的居中等比矩形；安全区、控件数量和动态字号都不参与照片区计算。几何尚不可用时，竖向窗口采用 3:4，横向窗口采用 4:3。上、下、左、右四块互不重叠的矩形构成窗口扣除照片区后的外围，面积为零的块被省略。

`CameraChromeLayout` 使用外围与安全区的交集，并根据实际剩余空间选择上下布局、左右布局或紧凑布局。空间不足或使用辅助功能字号时，控制项进入独立操作面板；面板关闭后可点按取景画面重新打开。首次自动展示面板要等待相机几何可用，并避开设置、回看、拍摄和冻结状态。

相机不可用时，照片区内的状态提示和恢复操作按纵向顺序排列；大字号或横向窗口容纳不下时可滚动查看。

照片区有边界角标和可关闭的三分网格。网格、快门、风格、焦距、输出规格、缩略图及状态入口都属于界面层。设置与回看使用独立全屏页面；详细拍摄状态、风格和焦距操作使用面板。

系统取景由 `CameraFrameDelivery` 校验缓冲区尺寸与格式后交给 `AVSampleBufferDisplayLayer`，通过 `resizeAspect` 显示。只有有效帧实际入队后，相机才报告取景就绪；冻结会撤销旧代次的入队和刷新，保留已经显示的系统画面。

有配对取景来源时，`PeripheralGlassView` 在同一次 Metal 提交中呈现中心与外围；单路系统取景仍保留作回退。外围缺帧不阻塞中心帧交付，玻璃和外围遮暗限定在照片区外。独立外围取景按能力尝试 60、30、15 Hz；单摄格式支持时使用 60 Hz，否则保留系统默认帧率。

### 实验实时色彩

`experimentalLiveColor` 默认关闭。打开后，仅中心取景使用近似的逐点色彩映射，拍摄服务和最终导出继续按完整处理配方处理源照片。

`LiveColorRecipe` 放行的组合为 FFCS、XH2S 表族、PROVIA 或 ACROS、曝光 0 EV、关闭参考调整、锐化半径 1，且所选原生资源必须可用。不支持的处理配方会立即撤销旧立方体的呈现，继续显示系统取景并给出原因。

`LiveColorCubeStore` 从原生 `ffcs_process_linear_rgb_color_only` 生成 65³ 色彩立方体：

- 网格按 sRGB 曲线分布，先把节点坐标还原为线性 sRGB，再交给原生逐点内核。
- 数据为 Float32 RGBA，R 变化最快，其次 G，最后 B，alpha 恒为 1；输出为 display-linear sRGB。
- 立方体只包含逐点颜色，颗粒、锐化和几何裁切由成片管线处理；这些效果开关仍参与完整缓存身份。
- 生成端只有一个后台任务和一个可替换请求，按蓝色切片检查取消，最多缓存两个立方体；旧请求的完成回调不能替换新配方。

实际视频保留原始颜色附件，由 Core Image 完成 YCbCr 与工作色域转换。代理将线性 sRGB 分量限制到 `[0,1]`，用 `CILinearToSRGBToneCurve` 生成查表坐标，再应用 `CIColorCube`；立方体输出已经是线性显示值。单路代理使用 Float 工作格式、`.rgba16Float` 显示纹理和扩展线性 sRGB 标签，关闭 EDR，输出 SDR 画面。

单路模式由 `LiveColorProxy` 覆盖系统取景；配对模式由 `PairedLiveColorProcessor` 处理当前帧对的中心图像，交回同一次配对呈现，不另建中心帧队列。

### 帧来源与呈现有效期

`LiveCameraFrame` 持有原始 `CVPixelBuffer`、格式描述、clean aperture、捕获 PTS、单调接收时间和 `generation`。捕获 PTS 用于保留相机时间，单调接收时间只用于检查时龄；相机连接已经施加方向，显示阶段按 clean aperture 居中等比放置。

`LiveSourceValidation` 只接受带一致元数据的双平面 8 位 NV12。色彩原色限 Rec.709 或 P3 D65，传递函数限 Rec.709 或 sRGB，YCbCr 矩阵限 Rec.709 或 Rec.601；同时检查色度位置、方形像素和图像范围内的有效 clean aperture。

单路实时代理的 `LiveCameraFrameSource` 是单槽邮箱，新帧替换尚未消费的帧，取出即消费。捕获回调不等待 GPU；渲染器只允许一个 GPU 任务在途，取得新鲜帧后才请求 drawable。帧、立方体和 Core Image 渲染任务一直持有到 GPU 完成。

单路实时代理帧的接收时龄上限为 0.5 秒。取帧后、取得 drawable 后以及 GPU 完成时都会检查时龄；已显示帧过期也会隐藏。只有相机 `generation`、配方 revision 和呈现 revision 均有效，且 GPU 成功完成，代理才记录原始 PTS 并显现。

各类失效有不同边界：

| 事件 | 呈现与来源处理 |
|---|---|
| 视图离窗、暂停、停止 | 隐藏旧效果，通过 `setEnabled(false)` 清空待处理来源 |
| 配方改变、相机未就绪或代理失败 | 撤销旧 revision，隐藏旧效果，清空并按可用条件重新启用来源 |
| 相机方向改变 | 重设帧尺寸与 `generation`，清空旧代次来源，等待新方向的有效帧 |
| drawable 尺寸改变 | 只递增呈现 revision 并隐藏旧效果，保留来源邮箱 |

状态通知按值去重，通过主队列异步发布；执行回调前再次核对当前状态，已被替代的通知不会覆盖新状态。

### 浮点回看与对照合成

`PreviewRaster` 拥有不可变的 Float32 线性 sRGB RGBA 数据，记录尺寸与 HDR headroom，只接收有限像素值。`CaptureReview` 和缩略图通过 `PrecisionPreview` 显示这些数据；回看支持缩放、平移和分享成片文件。

`PrecisionPreview` 使用 Float 工作格式，在扩展线性 BT.2020 中合成，输出 `.rgba16Float` drawable。`PreviewDisplay` 根据当前可见图像设置显示层的 headroom；屏幕适配由 Core Animation 完成，源浮点像素保持原值。渲染目标通过 `PreviewRendering` 对齐 Metal 顶部首行，源位图不重复施加方向变换。Metal 初始化或渲染失败时，界面显示错误。

底层组件可同时持有源图和处理结果：`comparisonFraction` 控制左侧结果图的比例，`nil` 显示完整结果，0 显示源图，1 显示结果。改变比例只裁切、合成已有图像并请求重绘；尺寸不一致的处理结果被忽略。显示期间的像素所有者和渲染任务保留至 GPU 完成。

## 不变量

1. 照片区是完整窗口内保持照片比例的最大居中矩形。— `PeripheralTests/CameraFramingTests.photograph_isMaximalCenteredAspectFit`
2. 外围各块互不重叠，且恰好覆盖窗口减去照片区的区域。— `PeripheralTests/CameraFramingTests.perimeter_exactlyPartitionsWindowOutsidePhotograph`
3. 普通控制区位于照片区外，辅助功能字号使用独立面板且保持照片区不变。— `GlassCamTests/CameraControlsTests.controls_stayWithinSafePeriphery`、`accessibilityText_usesSeparatePanelWithoutChangingPhoto`
4. 三分网格的线段只位于照片区的三等分位置。— `GlassCamTests/CameraControlsTests.grid_usesThirdsInsidePhotoBounds`
5. 独立面板只在安全展示条件满足时自动出现，关闭后不会立即自动重开。— `GlassCamTests/CameraControlsTests.compactPanel_waitsUntilPresentationIsSafe`、`compactPanel_dismissalDoesNotImmediatelyReopen`
6. 取景就绪等待有效帧实际入队，冻结撤销旧的入队和排队刷新。— `GlassCamTests/FrameDeliveryTests.readiness_waitsForActualEnqueue`、`freeze_revokesQueuedEnqueueAndFlush`
7. 外围缺帧不阻塞中心帧交付，外围变黑不会延迟、变暗或翻转中心画面。— `GlassCamTests/FrameDeliveryTests.missingPeripheralSample_doesNotBlockCenterSubmission`；`PeripheralTests/PairedPresentationTests.peripheralBlackness_doesNotDelayDarkenOrFlipCenter`
8. 外围取景帧率按 60、30、15 Hz 顺序选择，取景尺寸上限不改变照片源尺寸。— `GlassCamTests/CameraLifecycleTests.previewCadence_prefers60Then30Then15`、`previewSize_doesNotChangeSourceDimensions`
9. 实验实时色彩默认关闭，只有受支持的 FFCS 配方通过准入检查。— `GlassCamTests/LiveColorTests.defaultSettings_disableExperimentalPreview`、`measuredFFCSRecipe_isAvailable`、`unmeasuredRecipe_usesSystemPreview`
10. 立方体节点与原生逐点色彩输出一致，RGB 轴序固定且 alpha 恒为 1。— `GlassCamTests/LiveColorTests.cubeNodes_matchNativeColorOnlyRGBOrderAndAlpha`
11. 效果开关改变立方体缓存身份，相同配方复用同一所有者，替换请求后只完成新请求。— `GlassCamTests/LiveColorTests.effectChange_invalidatesCubeIdentity`、`repeatedRecipe_reusesCubeOwner`、`replacedBake_onlyCompletesNewestRequest`
12. 实时帧邮箱默认禁用、只保留可消费一次的新帧，禁用或代次失效后不能取出旧帧。— `PeripheralTests/LiveFrameMailboxTests.defaultDisabledMailbox_doesNotAcceptFrames`、`enabledMailbox_replacesPendingFrameAndConsumesOnce`、`unavailableGeneration_cannotDeliverPendingFrame`
13. 缺失或冲突的颜色元数据、错误缓冲格式、非方形像素及无效 clean aperture 均被拒绝。— `GlassCamTests/LiveColorTests.invalidFrameMetadata_rejectsProcessing`、`invalidCleanAperture_isRejected`
14. 按 clean aperture 居中等比显示时保持方向，捕获 PTS 保持原值。— `GlassCamTests/LiveColorTests.apertureFit_keepsOrientationAndCentersWithoutStretching`、`validTaggedNV12_preservesOriginalCaptureTimestamp`
15. 只有当前且新鲜的帧在 GPU 成功完成后可显示，过期、失败或失效标识的完成结果保持隐藏。— `GlassCamTests/LivePresentationTests.successfulGPUCompletion_revealsFrameWithCapturePTS`、`staleOrFailedGPUCompletion_staysHidden`
16. 停止、离窗、尺寸变化、暂停、相机失败及不支持的配方都会撤销已呈现的效果帧。— `GlassCamTests/LivePresentationTests.lifecycleChange_revokesPresentedFrame`
17. 状态通知异步发布，并丢弃已被替代的状态。— `GlassCamTests/LivePresentationTests.statusPublication_isDeferredAndDropsSupersededStatus`
18. 浮点回看保留图像方向和超白值，显示配置不改变拥有的浮点像素。— `ImagingCoreTests/ImagePipelineTests.metalPreview_preservesQuadrantsAndHDRValues`；`ImagingCoreTests/PreviewDisplayTests.configuringDisplay_doesNotChangeOwnedFloatPixels`
19. 显示 headroom 由当前可见输入决定，更换照片时同步更新显示层范围。— `ImagingCoreTests/PreviewDisplayTests.comparisonHeadroom_usesOnlyVisibleInputs`、`replacingHDRPhoto_updatesLayerRangeAndToneMapping`
20. 对照比例合成既有浮点图像，尺寸不一致的结果不会扭曲源图。— `GlassCamTests/PrecisionPreviewTests.comparisonFraction_compositesExistingFloatRasters`、`mismatchedResult_keepsUndistortedSource`
21. 相机不可用且使用辅助功能字号时，操作面板可打开、关闭后再打开。— `GlassCamUITests/CaptureWorkflowUITests.testCompactControlsCanReopenAfterDismissalOnSimulator`

## 数据与版本

取景偏好保存在 `CameraSettingsStore` 的既有 UserDefaults 键中：

| 键 | 默认值与含义 |
|---|---|
| `camera.grid.visible` | `true`，显示三分网格 |
| `camera.liveColor.enabled` | `false`，启用实验实时色彩 |
| `camera.preview.center.longEdge` | 1920，中心取景长边上限；可选 1280、1920、2560、3840、4096 |

`LiveColorRecipe.contract` 的版本前缀为 `v7`，完整字符串标识资源、引擎、输入域、网格和显示约定。缓存身份包含运行时资源、颜色模式、全部配方字段和效果开关；立方体、帧代次和呈现 revision 仅保存在内存中。照片处理配方不保存运行时资源路径。

`CameraFraming` 保留旧正方形构图的显示能力：源图保持原比例、中心与物理视场比例，由正方形照片区裁切显示。新相机偏好与已保存照片的配方迁移分别处理，已保存照片继续使用原构图。

## 已知限制

- 实时色彩是视频源上的插值近似，省略颗粒、锐化及其他空间处理，不能替代源照片的完整处理结果。
- 实时色彩使用 8 位 NV12 输入，并把线性 sRGB 限制到 `[0,1]`，扩展色域分量和高光信息会被裁剪。
- 相机实际色彩观感、显示插值误差、持续帧率、功耗和热稳态需要设备验证。
- 回看界面只展示成片，底层对照分割能力没有独立的编辑入口。
- 回看的 HDR 呈现受屏幕当前可用动态范围影响。

## 代码入口

- [CameraView](../App/GlassCam/UI/CameraView.swift)、[CameraChromeLayout](../App/GlassCam/UI/CameraChromeLayout.swift)、[PhotoFrameGuide](../App/GlassCam/UI/PhotoFrameGuide.swift)：界面组成、控制区选择与网格。
- [CameraFraming](../Packages/GlassCamKit/Sources/Peripheral/CameraFraming.swift)：照片区、源图与外围几何。
- [CameraFrameDelivery](../App/GlassCam/Camera/CameraFrameDelivery.swift)、[CameraBackend+Orientation](../App/GlassCam/Camera/CameraBackend+Orientation.swift)：有效帧交付、冻结和方向代次。
- [LiveCameraFrame](../Packages/GlassCamKit/Sources/Peripheral/LiveCameraFrame.swift)：保留原始帧元数据与单槽来源。
- [LiveColorRecipe](../App/GlassCam/Camera/LiveColorRecipe.swift)、[LiveColorCubeStore](../App/GlassCam/Camera/LiveColorCubeStore.swift)：实时配方准入与原生立方体生成。
- [LiveSourceValidation](../App/GlassCam/Camera/LiveSourceValidation.swift)、[LiveColorProxy](../App/GlassCam/Camera/LiveColorProxy.swift)：源校验、单路呈现、时龄与 GPU 生命周期。
- [PairedLiveColorProcessor](../App/GlassCam/Camera/PairedLiveColorProcessor.swift)、[PeripheralGlassView](../App/GlassCam/UI/PeripheralGlassView.swift)：配对帧中心色彩与统一呈现。
- [PreviewRaster](../Packages/GlassCamKit/Sources/ImagingCore/Processing/PreviewRaster.swift)、[PrecisionPreview](../App/GlassCam/UI/PrecisionPreview.swift)、[CaptureReview](../App/GlassCam/UI/CaptureReview.swift)：浮点所有权、HDR 显示、对照合成与回看。
- [CameraSettingsStore](../Packages/GlassCamKit/Sources/Capture/CameraSettingsStore.swift)：取景偏好与兼容读取。
- [取景边界测试](../App/GlassCamTests/LiveColorTests.swift)、[控制区测试](../App/GlassCamTests/DeliveryAndControlsTests.swift)、[浮点合成测试](../App/GlassCamTests/PrecisionPreviewTests.swift)：App 层显示行为。
- [几何测试](../Packages/GlassCamKit/Tests/PeripheralTests/CameraFramingTests.swift)、[邮箱测试](../Packages/GlassCamKit/Tests/PeripheralTests/MailboxTests.swift)、[显示范围测试](../Packages/GlassCamKit/Tests/ImagingCoreTests/PreviewDisplayTests.swift)：Package 层显示约定。
