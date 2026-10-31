# 拍摄与恢复

GlassCam 在快门时冻结处理配方，取得源照片后自动生成 HDR HEIF，并保存到系统照片图库。`CaptureWorkflow` 管理一张待完成照片的处理、重试和恢复；App 的 Camera 层负责相机会话、硬件回调和取景恢复，具体色彩计算由 ImagingCore 与注册的拍摄格式实现。

## 工作方式

### 快门与相机交付

根视图持有 `CameraSettingsStore` 和 `CaptureWorkflow`，打开设置或回看不会转移任务所有权。快门先向 `CameraController` 预约当前取景方向，再创建 `CaptureSnapshot`，冻结配方、输出选择、拍摄质量和 F5 RAW 归档选择，随后请求 Photos 的 `.addOnly` 授权。工作流空闲、恢复检查完成且应用可处理照片时，才接纳新快门。

授权成功后，相机按快照执行 Speed 单帧或 Balanced 四帧拍摄，默认 Balanced。相机配置、拍摄和恢复由后台串行队列管理；先保留取景画面并释放原会话，再建立物理主摄原生视角的 `.photo` Bayer RAW 会话。`F5CaptureDriver` 等待测光稳定并锁定曝光、ISO、焦点与白平衡，逐组确认原始 DNG、整数缓冲及终结回调后交付。取景恢复失败仍保留已完成的源照片。

拍摄预约及捕获期间推迟方向与变焦变更，恢复后应用最后一次请求。旧会话、旧请求和重复回调通过身份与阶段检查隔离。取景就绪要求有效帧已实际入队，冻结会撤销旧代次待投递帧及排队刷新。会话自动恢复在 30 秒窗口内最多接纳两次，过期或取消的会话不能自行重建。

### 保留、处理与保存

常规前台流程是 `idle → authorizing → capturing → retaining → processing → saving → idle`。失败进入 `failed`，后台或受保护数据不可读时暂停处理；恢复检查和相册结果未知分别使用 `restoring`、`saveOutcomeUnknown`。

收到源照片后，工作流先把源数据和快照写入 `CaptureJournal`，再执行完整源图处理。照片自身的白平衡、解码尺寸与拍摄几何在处理时绑定到本张快照，后续界面设置不参与这张照片的重试。成片回看从已编码 HEIF 解码，编码文件及其尺寸、校验值和最终快照持久化后才提交相册。

Photos 保存复制原始 HEIF 文件，保留原文件名与拍摄时间，并持有文件直至完成回调。保存成功回调到达后，先持久化 `savedConfirmed` 回执，再清理活动记录，最后发布回看成片并释放单张准入。保存完成后仍留在相机，缩略图打开成片；分享继续使用该文件。HEIF 元数据、HDR 编码及兼容分享见[RAW 解码与导出](raw-decode-and-export.md)。

### 磁盘阶段与重启恢复

| 记录阶段 | 已持久化内容 | 恢复动作 |
|---|---|---|
| `rawReady` | 源照片、冻结快照和源校验值 | 校验源文件，使用原快照重新处理 |
| `encodedReady` | 上述内容及 `result.heic`、成片尺寸和校验值 | 重载成片，重新检查权限后保存，复用编码文件 |
| `savePending` | 上述内容及本次保存的 `attemptID` | 保留成片，进入 `saveOutcomeUnknown`，等待用户核对相册 |
| `savedConfirmed` | 已确认保存的持久回执 | 只完成清理，不再次处理或调用 Photos |

重启后的 `savePending` 有两种用户操作：确认已保存会写入回执并清理；明确再次保存会先把记录退回 `encodedReady`，再提交一个新保存尝试。普通重试、切回前台和重复点击不会自动解决未知结果，也不会接纳第二张照片。

当前进程仍在途的 Photos 事务持续等待原回调，进入后台不会取消或判定该事务失败。如果只写入保存意图、尚未调用 Photos 就进入后台，工作流将记录恢复为 `encodedReady`，回前台再继续。

### 重试与清理

处理失败保留源照片和冻结快照，重试处理同一输入。源持久化失败时，当前任务仍持有输入，重试先完成保留。已有编码结果时，保存失败重试复用该文件；相册明确失败会回到 `encodedReady`。编码记录、回执或清理步骤失败，重试只补齐尚未完成的记录步骤，不重复成功的处理或相册事务。

Journal 检查文件字节数和 SHA-256；损坏文件、未知版本或暂时不可读的记录进入失败状态并保留文件，由用户重试或明确放弃。清理先将活动目录改名为 `FinishedCapture-<UUID>`，再递归删除；后续启动可继续清理这些退出活动区的目录。工作流已持有的回看与分享文件独立于活动记录。

### 输出尺寸

Speed 保留名义 12MP 原生尺寸；Balanced 采用横纵各 2 倍的曲率重建栅格。两种模式均使用 `ExportSettings.native`，完成配方裁剪后保存，不提供额外的 24MP／48MP 选择。取景分辨率只影响取景缓冲。

导入文件 API 仍可使用显式宽高和像素档位，详见 [RAW 解码与导出](raw-decode-and-export.md)。

### 调色前文件

Balanced 快门为照片冻结 `rawArchiveID`。处理入口在品牌调色前将浮点相机 DNG、线性 sRGB TIFF 交给 `CaptureRAWStore`，保存到 Documents 的 `RAWCaptures/<ID>/balanced/`。归档失败阻止调色，原有输入留在恢复记录中；重试验证并复用已发布文件，确认保存后的 Journal 清理不删除调色前归档。

设置页的两个测试入口分别记录十一张等曝光 Bayer 素材，或记录当前场景的 Balanced 合成原片。场景记录不进入普通工作流的调色、HEIF 编码与相册保存。输入事务在归档成功前保持在同组 `bayer-inputs` 目录，失败保留已录制文件。

### 格式注册与 F5 边界

`CaptureFormats` 是不可变注册表，`GlassCamApp` 创建含 `F5CaptureFormat` 的实例，并注入工作流服务和 Journal。Capture 定义 `CapturePayload`、`CaptureProvenance`、`CaptureFormat` 及通用事务顺序；格式实现负责载荷编解码、文件校验与保留、暂存恢复、归档和渲染。

Speed／Balanced 使用独立 Bayer RAW 驱动，分别采集一帧／四帧，输出由 F5 曲率重建策略决定，快照不套用普通相机的 24MP／48MP 目标。完整暂存 burst 可以接入同一个 Journal；未完成 burst 保留诊断文件并要求明确放弃。开启 RAW 归档时，确认保存后的清理先调用格式的归档实现。具体输入限制与重建方式见 [F5](f5.md)。

## 不变量

1. 设置变化不改变已冻结照片的处理及重试配方，方向在相册授权前预约。— `CaptureTests/WorkflowTests.settingsMutation_doesNotRetargetFrozenCaptureOrRetry`、`GlassCamTests/CameraLifecycleTests.reservation_freezesOrientationBeforeAuthorization`
2. 相册授权失败不提交快门或处理，放弃失败任务后释放准入。— `CaptureTests/WorkflowTests.permissionDenied_neverSubmitsShutterOrProcessing`、`CaptureTests/WorkflowTests.permissionFailure_discardReleasesAdmission`
3. 拍摄在途时拒绝第二次快门和重复回调，相册事务在途时拒绝放弃、重试和新拍摄。— `CaptureTests/WorkflowTests.pendingCapture_rejectsSecondShutterAndDuplicateCallback`、`CaptureTests/WorkflowTests.inFlightSave_rejectsDiscardRetryAndNewCapture`
4. 无效配方不提交拍摄。— `CaptureTests/WorkflowTests.invalidRecipe_neverSubmitsShutter`
5. 处理失败重试读取同一源字节和快照，保存失败重试复用已编码文件。— `CaptureTests/WorkflowTests.processingFailure_retryKeepsOriginalBytesAndSnapshot`、`CaptureTests/WorkflowTests.saveFailure_duplicateRetryReusesEncodedFile`
6. `rawReady` 恢复沿用冻结配方，成功清理不删除回看文件，`encodedReady` 恢复不重复处理。— `CaptureTests/RecoveryTests.borrowedRaw_releasePreservesJournalAndRecovery`、`CaptureTests/RecoveryTests.encodedReady_reloadsWithoutProcessing`
7. 保存结果未知必须显式解决，持久成功回执阻止重启后再次保存。— `CaptureTests/RecoveryTests.unknownSave_requiresExplicitResolution`、`CaptureTests/RecoveryTests.durableReceipt_restartDoesNotSaveAgain`
8. 记账与原子写后故障的重试不重复已完成处理或成功的相册事务。— `CaptureTests/RecoveryTests.bookkeepingFailure_retryDoesNotRepeatCompletedWork`、`CaptureTests/RecoveryTests.afterAtomicWriteFailure_retryUsesActualDiskState`
9. 后台处理保留 RAW，尚未提交的保存意图暂停，已在途相册事务不会因前后台切换重复提交。— `CaptureTests/RecoveryTests.backgroundedProcessing_retainsRawForForeground`、`CaptureTests/RecoveryTests.backgroundedSaveIntent_pausesBeforePhotos`、`CaptureTests/RecoveryTests.activePhotosTransaction_foregroundChangesDoNotDuplicateSave`
10. 损坏 RAW 不保存且不静默删除，退出活动区后的清理不重复保存。— `CaptureTests/RecoveryTests.damagedRaw_isPreservedWithoutSaving`、`CaptureTests/RecoveryTests.retiredCleanup_restartDoesNotRepeatSave`
11. 已提交照片不因界面停止或取景恢复失败而丢失，捕获期间的方向变化合并到恢复后执行。— `GlassCamTests/CameraLifecycleTests.committedPhoto_survivesStoppedViewOrPreviewFailure`、`GlassCamTests/CameraLifecycleTests.capture_defersAndCoalescesOrientationUntilRestoration`
12. 取景就绪等待真实入队帧，冻结后排队投递与刷新不能覆盖画面。— `GlassCamTests/FrameDeliveryTests.readiness_waitsForActualEnqueue`、`GlassCamTests/FrameDeliveryTests.freeze_revokesQueuedEnqueueAndFlush`
13. 数字变焦允许满足比例校验的较小 RAW，并约束有效像素估计。— `CaptureTests/OutputPolicyTests.explicitlyZoomedRAW_acceptsSmallerMatchingAspectOnly`、`CaptureTests/OutputPolicyTests.digitalZoom_limitsEstimatedNativePixels`
14. 24／48MP 按 24MP 有效像素阈值选档并保持构图比例，显式旧尺寸不放大。— `CaptureTests/OutputPolicyTests.sourcePixelThreshold_selects24Or48MP`、`CaptureTests/OutputPolicyTests.adaptiveOutput_preservesCompositionAt24MP`、`CaptureTests/OutputPolicyTests.invalidOrExplicitUpscaledOutput_isRejected`
15. Photos 仅申请添加权限，导入保留原始 HEIF 字节、文件名、日期和文件所有权。— `GlassCamTests/PhotoDeliveryTests.authorization_requestsAddOnly`、`GlassCamTests/PhotoDeliveryTests.photoImport_keepsOriginalHEIFBytesNameAndOwnership`、`GlassCamTests/PhotoDeliveryTests.photoImport_preservesFilenameDateAndPhotoResourceType`
16. F5 和规范化 Speed 记录往返保持固定字节，旧 Speed 保留质量与 12MP 输出并沿用既有规范化。— `F5Tests/currentJournal_decodeEncodePreservesBytes`、`F5Tests/legacySpeed_decodeRetainsQualityAndExistingNormalization`
17. F5 保留重试复用原记录与五帧，损坏 burst 保留文件与格式错误，确认保存后按快照归档源文件。— `F5Tests/retainedBurst_retryKeepsOriginalRecordAndFiveFrames`、`F5Tests/corruptBurst_loadRetainsFilesAndOriginalFailure`、`F5Tests/confirmedBurst_clearArchivesOriginals`
18. 自动会话恢复受预算约束，旧代次或取消的会话不重启。— `CaptureTests/SessionRecoveryTests.recoveryBudget_boundsAutomaticRebuildsAndRejectsBackwardsTime`、`CaptureTests/SessionRecoveryTests.staleOrCancelledSession_doesNotRestart`

## 数据与版本

活动记录位于应用支持目录的 `GlassCam/PendingCapture`。单张记录沿用 `schemaVersion: 1`、`capture.json`、`source.dng` 和 `result.heic`；F5 记录使用 `schemaVersion: 2`、`sourceKind: "f5"` 和 `burst/` 载荷。记录字段继续包括 `id`、`createdAt`、`snapshot`、`stage`、`raw`、`encoded`、`width`、`height`、`attemptID`、`lastError`，文件描述保留 `bytes` 与 `sha256`。

记录以排序 JSON 键原子写入并同步文件；iOS 文件使用完整文件保护，活动目录排除备份。`CaptureSnapshot` 保留 `recipe`、`output`、`quality`、`f5`、`archiveF5RAW` 与 `rawArchiveID` 键。包含 `f5` 来源信息的记录必须通过已注册格式的解码器读取，来源类型由 F5 提供。单张持久恢复的决定见 [ADR 0001](adr/0001-durable-single-capture.md)。

快照缺少 `quality` 时采用 Balanced，Quality 及未知质量值拒绝解码；缺少 `archiveF5RAW` 时采用 `false`。旧 Speed 照片仍按 `speed` 和 12MP 读取，再编码时补齐 `archiveF5RAW: false` 是既有规范化行为；固定样例见 [journal fixtures](../tests/fixtures/journal/README.md)。冻结照片配方按自身兼容规则恢复，旧 Nature 白平衡与 square-crop 构图保留。

未来相机设置采用独立迁移：保存的 F5 偏好转为 Balanced，Speed 偏好保留为单帧 RAW，square-crop 相机预设迁到 standard，缺少白平衡策略的旧相机设置采用照片白平衡。设置迁移不改写待完成照片的快照。对应行为由 `CaptureTests/SettingsTests.speedPreference_preservesSingleRAWMode`、`CaptureTests/RecipeMigrationTests.savedSquareCameraPreference_migratesAndPersistsStandard`、`CaptureTests/RecoveryTests.legacyNature_recoveryKeepsFrozenWhiteBalance` 覆盖。

| UserDefaults 键 | 内容 |
|---|---|
| `editor.processingRecipe.revision8.v1` | 经过验证的完整相机处理配方 |
| `camera.capture.quality.v1` | Speed 或 Balanced 拍摄质量，默认 Balanced |
| `camera.f5.keepRaw` | Speed／Balanced RAW 归档选择 |
| `camera.grid.visible` | 构图网格开关 |
| `camera.liveColor.enabled` | 实验实时色彩开关 |
| `camera.preview.center.longEdge` | 中心取景长边限制 |

## 已知限制

- Journal 只保留一张待完成照片，最近成片回看也不是跨启动的应用内图库。
- Photos 与本地 Journal 之间没有跨系统原子事务，进程在相册保存成功与回执落盘之间结束会留下需用户判断的未知结果。
- 源文件未成功持久化时，进程内保留的输入无法保证在进程结束后恢复。
- 处理在前台且受保护数据可用时继续，Apple 同步解码或编码调用只能在返回后的取消检查点停止。
- 有效像素是依据解码尺寸与变焦证据的估计，插值输出不增加独立拍摄细节。
- 相机与取景的光学构图对应、实际 RAW 能力、回调时序和设备中断行为需要真机检查。

## 代码入口

- [CaptureWorkflow.swift](../Packages/GlassCamKit/Sources/Capture/CaptureWorkflow.swift)：快照、单张准入、重试、后台暂停与阶段恢复。
- [CaptureJournal.swift](../Packages/GlassCamKit/Sources/Capture/CaptureJournal.swift)：记录格式、校验、原子写入、回执与清理。
- [CaptureFormats.swift](../Packages/GlassCamKit/Sources/Capture/CaptureFormats.swift)：格式注册、载荷和来源协议。
- [CameraSettingsStore.swift](../Packages/GlassCamKit/Sources/Capture/CameraSettingsStore.swift)：相机偏好与旧设置迁移。
- [ExportSettings.swift](../Packages/GlassCamKit/Sources/ImagingCore/Model/ExportSettings.swift)、[CaptureGeometry.swift](../Packages/GlassCamKit/Sources/ImagingCore/Model/CaptureGeometry.swift)：源尺寸、输出策略和有效像素估计。
- [CameraController.swift](../App/GlassCam/Camera/CameraController.swift)、[CameraBackend+Capture.swift](../App/GlassCam/Camera/CameraBackend+Capture.swift)、[F5CaptureDriver.swift](../App/GlassCam/Camera/F5CaptureDriver.swift)：拍摄预约、会话切换与终结交付。
- [CameraBackend+Orientation.swift](../App/GlassCam/Camera/CameraBackend+Orientation.swift)、[CameraFrameDelivery.swift](../App/GlassCam/Camera/CameraFrameDelivery.swift)、[CameraSessionRecovery.swift](../Packages/GlassCamKit/Sources/Capture/CameraSessionRecovery.swift)：方向、取景冻结和会话恢复策略。
- [F5CaptureFormat.swift](../Packages/GlassCamKit/Sources/F5/F5CaptureFormat.swift)、[GlassCamApp.swift](../App/GlassCam/UI/GlassCamApp.swift)：F5 格式实现与应用注册。
- [HEIFSaveDelivery.swift](../App/GlassCam/UI/HEIFSaveDelivery.swift)：Photos 原文件保存和 Files 复制导出。
- [CaptureTests](../Packages/GlassCamKit/Tests/CaptureTests)、[JournalCompatibilityTests.swift](../Packages/GlassCamKit/Tests/F5Tests/JournalCompatibilityTests.swift)、[CameraCaptureTests.swift](../App/GlassCamTests/CameraCaptureTests.swift)、[DeliveryAndControlsTests.swift](../App/GlassCamTests/DeliveryAndControlsTests.swift)：拍摄、恢复、持久兼容和 App 边界测试。
