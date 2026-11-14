# 取景与成片回看

取景界面以完整窗口确定照片区，再把控制项安排到剩余空间。系统取景、实验实时色彩和成片回看各有显示入口；照片处理与导出由图像管线负责。

## 工作方式

### 照片区与控制区

`CameraFraming` 按相机照片宽高比，在完整窗口中求最大的居中等比矩形；安全区、控件数量和动态字号都不参与照片区计算。几何尚不可用时，竖向窗口采用 3:4，横向窗口采用 4:3。上、下、左、右四块互不重叠的矩形构成窗口扣除照片区后的外围，面积为零的块被省略。

外层布局先读取系统安全区，内层取景才延伸到完整窗口。`CameraChromeLayout` 使用外围与安全区的交集，选择上下、左右或紧凑布局；竖屏拨盘占高 72pt，快门随外围剩余空间调整。空间不足或使用辅助功能字号时，控制项进入独立面板；关闭后可点按取景重新打开。首次自动展示须等几何可用，并避开设置、回看和拍摄状态。

相机不可用时，照片区内的状态提示和恢复操作按纵向顺序排列；大字号或横向窗口容纳不下时可滚动查看。

照片区有外扩 0.5pt 的光学倒角切边（拍摄采集中泛起呼吸高光）和可关闭的三分网格。网格、透镜快门、光学滤镜拨盘、采集优先级、只读光学铭文（`1× · 24 MP`）、缩略图及状态入口都属于界面层，默认采用去胶囊的激光蚀刻字标，激活或展开时浮起半透玻璃高光。当前拍摄固定物理主摄原生视角与 24MP 输出，不再陈列禁用的变焦条或假按钮。竖向取景在外围玻璃底部直接展开横向光学滤镜拨盘（含三引擎切换、光学色标微圆点与特性短签），不遮挡中央 4:3 照片区；横向、紧凑或辅助功能布局使用半透玻璃面板。设置采用不断流的半透玻璃浮层（底层相机会话保持预览透射），成片回看使用独立全屏页面。

系统取景由 `CameraFrameDelivery` 校验缓冲区尺寸与格式后交给 `AVSampleBufferDisplayLayer`，通过 `resizeAspect` 显示。只有有效帧实际入队后，相机才报告取景就绪；冻结会撤销旧代次的入队和刷新，保留已经显示的系统画面。

有配对取景来源时，`PeripheralGlassView` 在同一次 Metal 提交中呈现中心与外围；单路系统取景仍保留作回退。外围缺帧不阻塞中心帧交付，玻璃和外围遮暗限定在照片区外。独立外围取景按能力尝试 60、30、15 Hz；单摄格式支持时使用 60 Hz，否则保留系统默认帧率。

### 对焦、测光与快门反馈

普通布局轻点照片区设置焦点与测光点；独立面板布局的轻点用于重开控制面板，长按仍可锁定。长按 0.5 秒请求 AE/AF 锁定，双击或点按 AE/AF 标记恢复连续测光并保留相机曝光补偿。对焦环按调整状态收敛，太阳滑杆以 0.1 EV 步进调节，范围为硬件与 `−2…+2 EV` 的交集。显示点按方向映射到 Home 键右侧横屏的传感器坐标，转屏保留同一传感器目标。

屏幕与 `.onCameraCaptureEvent` 的 `.ended` 事件共用快门入口。模态页、相机未就绪或队列不能采集时关闭硬件事件接管。预约成功触发轻触觉；真正曝光完成触发刚性触觉，Speed 做 80ms 微暗开合，Balanced 的持稳高光随曝光结束收起；异常触发警示触觉。

UI 布局遵循系统界面方向，照片采用预约时冻结的重力方向，支持竖屏锁定下横拍。测光继承、重力迟滞和两槽准入规则见[拍摄与恢复](capture-and-recovery.md)。

### 实验实时色彩

`experimentalLiveColor` 默认关闭。打开后，仅中心取景使用近似的逐点色彩映射，拍摄服务和最终导出继续按完整处理配方处理源照片。

`LiveColorRecipe` 放行的组合为 FFCS、XH2S 表族、PROVIA 或 ACROS、曝光 0 EV、关闭参考调整、锐化半径 1，且配方有效、所选原生资源可用。设置开关下即时显示当前准入结果和原因，光学滤镜拨盘仅为完整配方通过准入的风格点亮 `LIVE`。不支持的配方立即撤销旧效果，继续显示系统取景。

`LiveColorCubeStore` 从原生 `ffcs_process_linear_rgb_color_only` 生成 65³ 色彩立方体：

- 网格按 sRGB 曲线分布，先把节点坐标还原为线性 sRGB，再交给原生逐点内核。
- 数据为 Float32 RGBA，R 变化最快，其次 G，最后 B，alpha 恒为 1；输出为 display-linear sRGB。
- 立方体只包含逐点颜色，颗粒、锐化和几何裁切由成片管线处理；这些效果开关仍参与完整缓存身份。
- 生成端只有一个后台任务和一个可替换请求，按蓝色切片检查取消，最多缓存两个立方体；旧请求的完成回调不能替换新配方。

实际视频保留原始颜色附件，由 Core Image 完成 YCbCr 与工作色域转换。代理将线性 sRGB 分量限制到 `[0,1]`，用 `CILinearToSRGBToneCurve` 生成查表坐标，再应用 `CIColorCube`；立方体输出已经是线性显示值。单路代理使用 Float 工作格式、`.rgba16Float` 显示纹理和扩展线性 sRGB 标签，关闭 EDR，输出 SDR 画面。

单路模式由 `LiveColorProxy` 覆盖系统取景；配对模式由 `PairedLiveColorProcessor` 处理当前帧对的中心图像，交回同一次配对呈现，不另建中心帧队列。配方、开关或相机就绪状态变化会撤销配对纹理并隐藏旧效果；新立方体就绪也更新呈现身份。拍摄期间通过同一 `isCapturing` 状态暂停实时处理，系统取景保留冻结画面。

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

### 浮点成片回看

`PreviewRaster` 直接拥有不可变的 Float32 线性 sRGB RGBA 数据，C++／NEON 扫描校验有限值并统计 RGB headroom，alpha 不参与峰值。相机缩略图长边上限 384px；进入 `CaptureReview` 后按需异步解码至 4096px，以 0.15 秒淡入替换。两者均通过 `PrecisionPreview` 显示，回看支持 1×–5× 缩放与边界内平移。

回看使用暗调玻璃背景、悬浮关闭／分享控件与底部拍摄铭文，从缩略图缩放展开。1× 时下拉关闭，放大时拖动平移；双击在 1×／2× 间切换。铭文显示引擎、风格、Speed／Balanced、RAW 帧数，以及可用的焦距、光圈、快门与 ISO；展开查看像素、白平衡和来源分辨率。高清解码失败提供重试入口。

最近确认成片通过 `LatestReviewStore` 跨启动恢复；缓存格式、确认时间排序和文件所有权见[拍摄与恢复](capture-and-recovery.md)。用户错误使用简短本地化文案，底层相机、色彩及恢复诊断写入日志。

`PrecisionPreview` 使用 Float 工作格式，在扩展线性 BT.2020 中合成，输出 `.rgba16Float` drawable。`PreviewDisplay` 根据当前可见图像设置显示层的 headroom；屏幕适配由 Core Animation 完成，源浮点像素保持原值。渲染目标通过 `PreviewRendering` 对齐 Metal 顶部首行，源位图不重复施加方向变换。Metal 初始化或渲染失败时，界面显示错误；组件内部保留的 `comparisonFraction` 双图分割合成仅服务于测试，回看页只展示成片。显示期间的像素所有者和渲染任务保留至 GPU 完成。

## 不变量

1. 照片区是完整窗口内保持照片比例的最大居中矩形。— `PeripheralTests/CameraFramingTests.photograph_isMaximalCenteredAspectFit`
2. 外围各块互不重叠，且恰好覆盖窗口减去照片区的区域。— `PeripheralTests/CameraFramingTests.perimeter_exactlyPartitionsWindowOutsidePhotograph`
3. 普通控制区位于照片区外，辅助功能字号使用独立面板且保持照片区不变。— `GlassCamTests/CameraControlsTests.controls_stayWithinSafePeriphery`、`accessibilityText_usesSeparatePanelWithoutChangingPhoto`
4. 三分网格的线段只位于照片区的三等分位置，整板玻璃镂空与光学倒角切边严格位于照片区外。— `GlassCamTests/CameraControlsTests.grid_usesThirdsInsidePhotoBounds`、`apertureCutout_excludesInteriorPhotographAndCoversPeriphery`
5. 光学滤镜目录完整覆盖三套色彩引擎的全部可用预设，并保持选择同步。— `GlassCamTests/CameraControlsTests.opticalLookCatalog_coversAllBundledLooksAndUpdatesSelection`
6. 独立面板只在安全展示条件满足时自动出现，关闭后不会立即自动重开。— `GlassCamTests/CameraControlsTests.compactPanel_waitsUntilPresentationIsSafe`、`compactPanel_dismissalDoesNotImmediatelyReopen`
7. 取景就绪等待有效帧实际入队，冻结撤销旧的入队和排队刷新。— `GlassCamTests/FrameDeliveryTests.readiness_waitsForActualEnqueue`、`freeze_revokesQueuedEnqueueAndFlush`
8. 外围缺帧不阻塞中心帧交付，外围变黑不会延迟、变暗或翻转中心画面。— `GlassCamTests/FrameDeliveryTests.missingPeripheralSample_doesNotBlockCenterSubmission`；`PeripheralTests/PairedPresentationTests.peripheralBlackness_doesNotDelayDarkenOrFlipCenter`
9. 外围取景帧率按 60、30、15 Hz 顺序选择，取景尺寸上限不改变照片源尺寸。— `GlassCamTests/CameraLifecycleTests.previewCadence_prefers60Then30Then15`、`previewSize_doesNotChangeSourceDimensions`
10. 实验实时色彩默认关闭，只有受支持的 FFCS 配方通过准入检查。— `GlassCamTests/LiveColorTests.defaultSettings_disableExperimentalPreview`、`measuredFFCSRecipe_isAvailable`、`unmeasuredRecipe_usesSystemPreview`
11. 立方体节点与原生逐点色彩输出一致，RGB 轴序固定且 alpha 恒为 1。— `GlassCamTests/LiveColorTests.cubeNodes_matchNativeColorOnlyRGBOrderAndAlpha`
12. 效果开关改变立方体缓存身份，相同配方复用同一所有者，替换请求后只完成新请求。— `GlassCamTests/LiveColorTests.effectChange_invalidatesCubeIdentity`、`repeatedRecipe_reusesCubeOwner`、`replacedBake_onlyCompletesNewestRequest`
13. 实时帧邮箱默认禁用、只保留可消费一次的新帧，禁用或代次失效后不能取出旧帧。— `PeripheralTests/LiveFrameMailboxTests.defaultDisabledMailbox_doesNotAcceptFrames`、`enabledMailbox_replacesPendingFrameAndConsumesOnce`、`unavailableGeneration_cannotDeliverPendingFrame`
14. 缺失或冲突的颜色元数据、错误缓冲格式、非方形像素及无效 clean aperture 均被拒绝。— `GlassCamTests/LiveColorTests.invalidFrameMetadata_rejectsProcessing`、`invalidCleanAperture_isRejected`
15. 按 clean aperture 居中等比显示时保持方向，捕获 PTS 保持原值。— `GlassCamTests/LiveColorTests.apertureFit_keepsOrientationAndCentersWithoutStretching`、`validTaggedNV12_preservesOriginalCaptureTimestamp`
16. 只有当前且新鲜的帧在 GPU 成功完成后可显示，过期、失败或失效标识的完成结果保持隐藏。— `GlassCamTests/LivePresentationTests.successfulGPUCompletion_revealsFrameWithCapturePTS`、`staleOrFailedGPUCompletion_staysHidden`
17. 单路代理在停止、离窗、尺寸变化、暂停、相机失败及不支持的配方出现时撤销效果帧；配对代理更换色彩选择时撤销完成纹理。— `GlassCamTests/LivePresentationTests.lifecycleChange_revokesPresentedFrame`、`PairedRendererTests.colorSelectionChange_revokesCompletedPixels`
18. 状态通知异步发布，并丢弃已被替代的状态。— `GlassCamTests/LivePresentationTests.statusPublication_isDeferredAndDropsSupersededStatus`
19. 浮点回看保留图像方向和超白值，显示配置不改变拥有的浮点像素。— `ImagingCoreTests/ImagePipelineTests.metalPreview_preservesQuadrantsAndHDRValues`；`ImagingCoreTests/PreviewDisplayTests.configuringDisplay_doesNotChangeOwnedFloatPixels`
20. 显示 headroom 由当前可见输入决定，更换照片时同步更新显示层范围。— `ImagingCoreTests/PreviewDisplayTests.comparisonHeadroom_usesOnlyVisibleInputs`、`replacingHDRPhoto_updatesLayerRangeAndToneMapping`
21. 对照比例合成既有浮点图像，尺寸不一致的结果不会扭曲源图。— `GlassCamTests/PrecisionPreviewTests.comparisonFraction_compositesExistingFloatRasters`、`mismatchedResult_keepsUndistortedSource`
22. 相机不可用且使用辅助功能字号时，操作面板可打开、关闭后再打开。— `GlassCamUITests/CaptureWorkflowUITests.testCompactControlsCanReopenAfterDismissalOnSimulator`
23. 竖屏安全区保留可操作的外围滤镜拨盘，引擎可切换并关闭。— `GlassCamTests/CameraControlsTests.portraitSafeArea_keepsFilterDialInThePeriphery`、`GlassCamUITests/CaptureWorkflowUITests.testPortraitFilterDialCanSwitchEngineAndCloseOnSimulator`
24. 显示方向变化保持同一传感器焦点，曝光偏置不越过硬件与界面范围。— `GlassCamTests/CameraMeteringTests.displayedPoint_mapsToNativeSensorAxes`、`rotatingDisplay_keepsTargetAtTheSameSensorPoint`、`exposureBias_respectsCameraAndUserBounds`
25. 平放、对角和异常加速度不改变物理方向，稳定方向需要连续样本。— `GlassCamTests/CameraGravityTests.stableGravity_selectsPhysicalOrientation`、`flatDiagonalOrUnreliableMotion_preservesOrientation`、`interruptedCandidate_doesNotRotateOnTwoTransientSamples`
26. 回看仅在未放大且向下拖动时关闭，平移范围依据实际图像而非留黑区域。— `GlassCamTests/CaptureReviewTests.onlyDownwardUnzoomedDrag_dismisses`、`landscapePhotoInPortrait_limitsPanToScaledImageInsteadOfLetterbox`
27. 回看像素直接持有原数据、排除 alpha 峰值，并拒绝非有限分量。— `ImagingCoreTests/PreviewDisplayTests.dataBackedPreview_ownsItsPixelsAndExcludesAlphaFromHeadroom`、`nonfiniteComponent_rejectsDataBackedPreview`
28. 拍摄铭文保留有效 EXIF 参数，省略无效数值。— `CaptureTests/PhotoCaptureInfoTests.deliveredEXIF_preservesPhysicalCaptureSettings`、`invalidCaptureValues_areOmitted`

## 数据与版本

取景偏好保存在 `CameraSettingsStore` 的既有 UserDefaults 键中：

| 键 | 默认值与含义 |
|---|---|
| `camera.grid.visible` | `true`，显示三分网格 |
| `camera.liveColor.enabled` | `false`，启用实验实时色彩 |
| `camera.preview.center.longEdge` | 1920，中心取景长边上限；可选 1280、1920、2560、3840、4096 |

`LiveColorRecipe.contract` 的版本前缀为 `v7`，完整字符串标识资源、引擎、输入域、网格和显示约定。缓存身份包含运行时资源、颜色模式、全部配方字段和效果开关；立方体、帧代次和呈现 revision 仅保存在内存中。照片处理配方不保存运行时资源路径。

## 已知限制

- 实时色彩是视频源上的插值近似，省略颗粒、锐化及其他空间处理，不能替代源照片的完整处理结果。
- 实时色彩使用 8 位 NV12 输入，并把线性 sRGB 限制到 `[0,1]`，扩展色域分量和高光信息会被裁剪。
- 相机实际色彩观感、显示插值误差、持续帧率、功耗和热稳态需要设备验证。
- 回看的 HDR 呈现受屏幕当前可用动态范围影响。

## 代码入口

- [CameraView](../App/GlassCam/UI/CameraView.swift)、[CameraChromeLayout](../App/GlassCam/UI/CameraChromeLayout.swift)、[PhotoFrameGuide](../App/GlassCam/UI/PhotoFrameGuide.swift)：界面组成、控制区选择与网格。
- [CameraFocusControl](../App/GlassCam/UI/CameraFocusControl.swift)、[CameraMetering](../App/GlassCam/Camera/CameraMetering.swift)、[CameraMotion](../App/GlassCam/Camera/CameraMotion.swift)：焦点手势、EV、触觉及物理方向。
- [CameraFraming](../Packages/GlassCamKit/Sources/Peripheral/CameraFraming.swift)：照片区、源图与外围几何。
- [CameraFrameDelivery](../App/GlassCam/Camera/CameraFrameDelivery.swift)、[CameraBackend+Orientation](../App/GlassCam/Camera/CameraBackend+Orientation.swift)：有效帧交付、冻结和方向代次。
- [LiveCameraFrame](../Packages/GlassCamKit/Sources/Peripheral/LiveCameraFrame.swift)：保留原始帧元数据与单槽来源。
- [LiveColorRecipe](../App/GlassCam/Camera/LiveColorRecipe.swift)、[LiveColorCubeStore](../App/GlassCam/Camera/LiveColorCubeStore.swift)：实时配方准入与原生立方体生成。
- [LiveSourceValidation](../App/GlassCam/Camera/LiveSourceValidation.swift)、[LiveColorProxy](../App/GlassCam/Camera/LiveColorProxy.swift)：源校验、单路呈现、时龄与 GPU 生命周期。
- [PairedLiveColorProcessor](../App/GlassCam/Camera/PairedLiveColorProcessor.swift)、[PeripheralGlassView](../App/GlassCam/UI/PeripheralGlassView.swift)：配对帧中心色彩与统一呈现。
- [PreviewRaster](../Packages/GlassCamKit/Sources/ImagingCore/Processing/PreviewRaster.swift)、[PrecisionPreview](../App/GlassCam/UI/PrecisionPreview.swift)、[CaptureReview](../App/GlassCam/UI/CaptureReview.swift)：浮点所有权、HDR 显示、对照合成与回看。
- [SavedCapture](../Packages/GlassCamKit/Sources/Capture/SavedCapture.swift)、[CaptureReviewGeometry](../App/GlassCam/UI/CaptureReviewGeometry.swift)：按需高清解码、拍摄参数及回看手势几何。
- [CameraSettingsStore](../Packages/GlassCamKit/Sources/Capture/CameraSettingsStore.swift)：取景偏好与兼容读取。
- [取景边界测试](../App/GlassCamTests/LiveColorTests.swift)、[控制区测试](../App/GlassCamTests/DeliveryAndControlsTests.swift)、[浮点合成测试](../App/GlassCamTests/PrecisionPreviewTests.swift)：App 层显示行为。
- [几何测试](../Packages/GlassCamKit/Tests/PeripheralTests/CameraFramingTests.swift)、[邮箱测试](../Packages/GlassCamKit/Tests/PeripheralTests/MailboxTests.swift)、[显示范围测试](../Packages/GlassCamKit/Tests/ImagingCoreTests/PreviewDisplayTests.swift)：Package 层显示约定。
