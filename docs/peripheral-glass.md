# 外围玻璃

外围玻璃在照片区外显示较广物理镜头的取景画面，并依据两路原始接缝的可见差异调整遮黑。实时显示采用固定视场缩放和居中采样；状态记录保存当时的相机输入、分析证据、纹理来源与提交状态。

## 工作方式

### 采样、配对与时钟

[CameraBackend](../App/GlassCam/Camera/CameraBackend+Preview.swift) 从当前物理镜头向更广镜头选择外围来源，主摄通常配超广角，长焦优先配主摄。双摄取景按 60、30、15 Hz 尝试支持的组合；原生焦段在同一帧率下先请求虚拟多摄的物理子镜头端口，再尝试独立物理输入。数字变焦使用独立输入，外围保留较广视场。照片源能力与取景格式分别选择，拍摄会话切换见[拍摄与恢复](capture-and-recovery.md)。

视场比例由当前格式的半视场角正切与实际变焦倍率计算，并使用启用几何畸变校正后的有效视场。输出镜头、视场比例、标定身份或采集模式改变时，`PeripheralFrameSource` 增加 `epoch` 并清空配对。可用标定包含内参 K、外参 R/t 和输出角度；极线搜索须经过当前图像对应验证。

`PeripheralFrameSynchronizer` 先把有效中心帧交给中心取景，再把中心和外围样本送入配对器。配对器优先使用同一同步集合，每路最多暂存三个样本、保留 50 ms；分离回调留出 8 ms 的最近邻窗口，接受的双路 PTS 差最多为 1/60 秒。已消费的样本和旧 `epoch` 回调被丢弃。

帧元数据保存原始 PTS、尺寸、格式、色彩标签、帧间隔与内参；有会话时钟时另存转换后的主机捕获时间。`observedAt` 在两路均有主机时间时取两者和接收时间的最早值，否则采用接收时间。像素年龄、分析截止和恢复历时使用此时间基准，原始 PTS 保留用于双路曝光时差及显示提交差的记录。

### 固定视场与可见接缝

当前数据流为：相机帧对 → 固定视场外围纹理 → 同帧中心与外围合成 → 按边遮黑 → 外围 Liquid Glass。`CameraFraming` 的外围区域恰好覆盖窗口减照片区，`PeripheralSeams` 只选择与实际外围相邻的接缝。

`PeripheralLivePipeline` 按视场比例构造固定映射，直接读取当前外围 `CVPixelBuffer`。其显示模型使用单位光度增益、空稠密修正和零修正强度；分析中的位移用于计算遮黑。当前窗口须完全落在外围纹理内，并保留至少两个源像素的采样余量。

`PeripheralAlignmentWorker` 使用单工作队列，最多每 1/12 秒接纳一次分析；每次分析从观测时间起有 0.20 秒发布期限。分析图宽为 192 像素，按中心画面比例计算高度，以固定视场映射建立带搜索余量的外围图。两路归一化灰度匹配输出位移区间、对应状态、反向检查、覆盖率和搜索完整性。

原生接缝检查另读取相机分辨率的窄条，保存未调整的 RGBA 输入，检查细线、平坦区域、周期结构、对应位置和缺失结构。`PeripheralPaneAssessment` 从每边的原生分块汇总可见距离、匹配支持、结构缺失、局部一致位移与相对形变；受支持的局部严重错位有独立分支，平坦多数区域不会稀释该分支。

### 遮黑与恢复

实时遮黑由 `PeripheralPreviewPolicy` 控制。每条边记录原始观测和经时序确认的观测，上、下两边在时序处理前采用较黑的一边，最终透明度也保持相同；左、右两边独立计算。尚无首次有效接缝观测时保持遮黑，新的相机像素仍继续准备和上传。

| 参数 | 当前实时路径 |
|---|---|
| 容差 | 默认 1.00，范围 0.25–4.00，步长 0.05 |
| 位移渐暗区间 | 画面短边的 0.025–0.065，乘以容差的四次方根 |
| 结构缺失渐暗区间 | 受影响比例 0.08–0.22 |
| 广泛失配渐暗区间 | 受影响比例 0.18–0.45 |
| 相对形变渐暗区间 | 0.10–0.30，乘以容差的四次方根 |
| 全范围加深 / 渐开 | 0.14 秒 / 0.60 秒 |
| 连续改善证据 | 至少 0.65 秒，覆盖率至少 0.65，样本间隔至多 0.26 秒 |
| 观测过期 | 超过 0.45 秒后遮黑，返回时重新积累连续证据 |
| 当前像素寿命 | 0.20 秒 |

恶化通常由两个新观测确认；多处相符的大位移、大面积结构缺失或受影响区域足够广时可直接确认。孤立峰和小幅量化噪声有独立抑制。恢复需要持续改善，稀疏好结果和好坏交替维持遮黑；资源不可用时立即遮黑。

### 纹理身份与提交

`PeripheralLiveTextureStore` 各保留一个待上传束、完成束和备用纹理。纹理束持有实际像素帧对、分析帧编号与观测时间、视场映射、容差、源 revision 和上传 ticket，像素来源与分析来源分别记录。

[PeripheralGlassView](../App/GlassCam/UI/PeripheralGlassView.swift) 取得 drawable 后再读取当前帧对，将中心与外围的 Core Image 上传排在同一个 Metal command 的绘制之前，当前 command 直接使用正在上传的纹理束。`pairedPreviewFragment` 在照片区采样同一帧对的中心纹理，在外围使用各边遮黑；中心取景独立投递仍能处理缺少外围样本的情况。

GPU 完成只有在待处理束、ticket、源 revision 和 `epoch` 一致时才更新完成资源。源停止、镜头代次变化、窗口覆盖不足或像素过期使资源失效。GPU 完成事件和 drawable 呈现事件分别记录，提交状态保存 `renderedCenterPTS`、`renderedOuterPTS`、`cameraExposureSkew` 与 `applicationAddedFrameSkew`。

## 不变量

以下方法位于 [PeripheralTests](../Packages/GlassCamKit/Tests/PeripheralTests)；外围缺帧时的中心投递方法位于 [App FrameDeliveryTests](../App/GlassCamTests/FrameDeliveryTests.swift)。

1. 缺少外围样本时，有效中心帧仍能完成中心取景提交。— `GlassCamTests/FrameDeliveryTests.missingPeripheralSample_doesNotBlockCenterSubmission`
2. 已配对样本保留原始 PTS 且不能再次消费，重置后旧代次回调不能建立新配对。— `PeripheralTests/PeripheralMailboxTests.pairedSamples_keepOriginalPTSAndCannotBeReused`、`PeripheralTests/PeripheralMailboxTests.reset_rejectsOldEpochCallbacks`
3. 分离回调先等待最近邻窗口，再选择时间更接近的两路样本。— `PeripheralTests/PeripheralMailboxTests.splitCallbacks_waitForNearestNeighborWindow`
4. 外围区域完整划分窗口减照片区，外围遮黑不延迟、压暗或翻转中心像素。— `PeripheralTests/CameraFramingTests.perimeter_exactlyPartitionsWindowOutsidePhotograph`、`PeripheralTests/PairedPresentationTests.peripheralBlackness_doesNotDelayDarkenOrFlipCenter`、`PeripheralTests/GlassShaderTests.glassOpacity_neverWritesPhotograph`
5. 实时外围保留固定视场映射与相机像素，旧拟合几何、光流和光度模型不进入显示。— `PeripheralTests/WorkerTests.directStitch_doesNotApplySceneFittedCorrection`、`PeripheralTests/LiveGPUFrameTests.directPreview_ignoresLegacyFittedGeometryAndPhotometry`
6. 未检查的启动状态保持遮黑，原始已知位移按可见差异决定遮黑。— `PeripheralTests/LivePolicyTests.uncheckedStartup_doesNotAssumeTransparency`、`PeripheralTests/ControlledDisparityTests.knownRawPixelShift_controlsGlassWithoutWarping`
7. 缺失可见结构在最大容差下仍遮黑，局部物体错位不被平坦多数区域抵消。— `PeripheralTests/LivePolicyTests.absentVisibleStructure_staysBlackAtMaximumTolerance`、`PeripheralTests/ControlledDisparityTests.localObjectDisplacement_cannotBeOutvotedByFlatMajority`
8. 上、下遮黑始终采用较暗一边并保持联动，左、右保留独立状态。— `PeripheralTests/LivePolicyTests.horizontalShade_usesDarkerPaneWithoutMixingSidePanes`
9. 孤立坏观测不产生黑闪，间歇或稀疏好证据不能重开坏接缝，持续好证据经过稳定期后恢复。— `PeripheralTests/TemporalShadeTests.isolatedBadObservation_doesNotFlashBlack`、`PeripheralTests/TemporalShadeTests.intermittentOrSparseGoodEvidence_cannotReopenBadSeam`、`PeripheralTests/TemporalShadeTests.sustainedGoodEvidence_waitsForStabilityThenRecovers`
10. 分析过期后恢复需要连续返回的覆盖证据。— `PeripheralTests/TemporalShadeTests.overdueAnalysis_requiresContinuousReturningCoverage`
11. 当前帧可在同一 command 完成上传和绘制，纹理保存实际像素与分析的独立身份。— `PeripheralTests/PairedPresentationTests.currentFrame_uploadsAndRendersBeforePublication`、`PeripheralTests/LiveGPUFrameTests.completedUpload_keepsActualPixelAndAnalysisIdentities`
12. 分析暂缺时当前像素继续刷新，重置后的晚到 GPU 完成不能恢复旧资源。— `PeripheralTests/LiveGPUFrameTests.currentPixels_continueRefreshingWithoutAnalysis`、`PeripheralTests/LiveGPUFrameTests.lateGPUCompletion_cannotResurrectResetSource`
13. 视场不足和窗口改变不能复用覆盖无效的纹理。— `PeripheralTests/LiveGPUFrameTests.insufficientFieldOfViewAndResize_cannotReuseTexture`
14. 逐边线性与仿射光度接口按各自传递函数域作用于外围。— `PeripheralTests/GlassShaderTests.independentEdgeGains_applyVerifiedLinearPhotometry`、`PeripheralTests/GlassShaderTests.affinePhotometry_appliesTransferFunctionOnce`
15. 录制保留各角色的真实来源、PTS、内参和每个像素平面的全部字节，包括行尾填充。— `PeripheralTests/RecordingTests.distinctSources_preserveTheirRolesAndTolerance`、`PeripheralTests/RecordingTests.originalMetadata_preservesCapturePTSAndIntrinsics`、`PeripheralTests/RecordingTests.originalPlanes_preserveEveryByteIncludingPadding`
16. 停止相机和只有未配对帧时仍可记录；重启后可导出且保留原件，空间不足报告失败并清理未完成目录。— `PeripheralTests/RecordingTests.stoppedCameraRecord_preservesEmptyPairAndNonfiniteValue`、`PeripheralTests/RecordingTests.unmatchedOriginal_isVisibleAndCanBeRecorded`、`PeripheralTests/RecordingTests.restartedRecorder_exportsWithoutRemovingOriginals`、`PeripheralTests/RecordingTests.storageLimit_reportsFailureWithoutPartialDirectory`

## 数据与版本

容差沿用 UserDefaults 键 `peripheralMatchingTolerance`，输入被限制到有效范围并按步长取整，非有限值恢复默认值。实时改变容差会更新遮黑判断；相机、分析、提交状态和纹理各自保存实际使用值。

“记录状态”在按钮触发时固定缓冲区所有权和状态快照，后台保存完整内容；保存与导出共用单事务准入。记录放在应用文稿目录的 `GlassCamStateRecords/record-<毫秒时间>-<标识>/`，清单名为 `manifest.json`，`schemaVersion` 为 1。当前实现标识为 `manual-native-recording-20261025`，直接接缝分析标识为 `fixed-field-of-view-direct-stitch-v5`。

| 清单内容 | 含义 |
|---|---|
| `roles` / `pairs` | `tapPair`、`renderCandidatePair`、`texturePair`、`analysisPair`、`renderModelPair` 分别关联帧对，重复帧对共用文件 |
| `unpairedInputs` | 尚未配成对的中心或外围原始输入 |
| 像素平面文件 | 相机交付格式、平面尺寸、行跨度、完整字节、色彩附件及 SHA-256 |
| `analysis` | 完成分析或拒绝原因、192 宽分析图、原生边界窄条及可用的修正字段 |
| `renderModel` | 真实显示映射、光度、容差，以及模型来源和当前像素来源 |
| `renderer` / `renderHistory` / `gpuEvents` | 当前提交、最多 180 条渲染状态和 90 条 GPU 事件 |

JSON 将非有限数值保存为 `NaN`、`+Infinity`、`-Infinity` 字符串。分析和实际显示的稠密字段分别使用 `dense-refinement.rgba32f` 与 `render-refinement.rgba32f`；已有角色、文件名、拟合矩阵、逐边光度及稠密字段保持兼容；`PeripheralDenseRefinement` 只保存字段数据，实时显示继续使用单位增益与空修正。

单次记录估算必须小于 256 MiB，总保存预算默认 512 MiB。所有文件先写入 `.pending-<记录标识>`，清单与容量检查完成后才重命名为正式记录；写入失败清理该临时目录，已有记录保留。重启通过正式目录中的清单发现记录，导出全部记录生成保留文件字节的 ZIP。

可选诊断环由 `GLASSCAM_PERIPHERAL_FRAME_RING=1` 开启，保存分析输入与事件到缓存目录 `GlassCamPeripheralEvents`；`GLASSCAM_PERIPHERAL_TRACE=1` 开启运行日志。手动状态记录与该诊断环分别管理。

## 已知限制

- 近景视差、遮挡、重复纹理和缺乏可见结构可能使外围持续遮黑。
- 容差和经验位移区间表达显示接受范围，未经过设备留出集的概率覆盖率标定。
- 同一帧对和同一 command 的呈现仍保留两路原始曝光时差与滚动快门差异。
- 状态记录保存相机交付的视频像素，最终 Liquid Glass 合成效果、真机帧率、功耗和运动稳定性需要设备端验收。

## 代码入口

- [CameraBackend+Preview.swift](../App/GlassCam/Camera/CameraBackend+Preview.swift)：双摄取景组合、帧率、有效视场和标定。
- [PeripheralFrameSource.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralFrameSource.swift)、[PeripheralFrameSynchronizer.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralFrameSynchronizer.swift)、[PeripheralFrameMetadata.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralFrameMetadata.swift)：配对、代次与原始时钟。
- [PeripheralAlignmentWorker.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralAlignmentWorker.swift)、[PeripheralAlignmentWorker+Seams.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralAlignmentWorker+Seams.swift)：固定视场分析、可观测位移与发布期限。
- [PeripheralVisibleSeam.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralVisibleSeam.swift)：原生接缝验证与逐边光度数据。
- [PeripheralLiveDisplay.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralLiveDisplay.swift)：实时观测汇总、遮黑恢复、当前帧和纹理身份。
- [PeripheralTolerance.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralTolerance.swift)、[PeripheralEvidence.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralEvidence.swift)：容差持久化与分析证据。
- [PeripheralDenseRefinement.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralDenseRefinement.swift)：已保存记录使用的稠密字段数据。
- [PeripheralGlassShader.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralGlassShader.swift)、[PeripheralGlassView.swift](../App/GlassCam/UI/PeripheralGlassView.swift)：中心与外围合成、GPU 提交及外围 Liquid Glass。
- [PeripheralStateRecording.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralStateRecording.swift)、[PeripheralRecordingControls.swift](../App/GlassCam/UI/PeripheralRecordingControls.swift)：状态快照、持久化、列表与 ZIP 分享。
- [PeripheralDiagnosticRecorder.swift](../Packages/GlassCamKit/Sources/Peripheral/PeripheralDiagnosticRecorder.swift)：可选有界诊断环。
