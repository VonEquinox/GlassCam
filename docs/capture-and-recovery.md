# 拍摄与恢复

GlassCam 在快门时冻结处理配方，取得源照片后自动生成 HDR HEIF，并保存到系统照片图库。`CaptureQueue` 管理两个持久槽位，每槽由独立 `CaptureWorkflow` 负责处理、重试和恢复；Camera 层负责相机会话与交付，色彩计算由 ImagingCore 与注册的拍摄格式实现。

## 工作方式

### 快门与相机交付

根视图持有 `CameraSettingsStore` 和 `CaptureQueue`，打开设置或回看保持任务所有权。快门先向 `CameraController` 预约物理拍摄方向，再创建 `CaptureSnapshot`，冻结配方、输出、质量和 RAW 归档选择；队列分配槽位后请求 Photos 的 `.addOnly` 授权。恢复检查结束、存在空闲槽位、相机取景就绪且没有另一张正在授权／采集／保留源照片时，接纳新快门。

授权成功后，相机按快照执行 Speed 单帧或 Balanced 七帧拍摄，默认 Balanced。后台相机串行队列保留取景画面、释放原会话，再建立物理主摄原生视角的 `.photo` Bayer RAW 会话。`F5CaptureDriver` 继承点选焦点、相机曝光补偿与显式 AE/AF 锁定；未锁定时等待测光稳定，再锁定曝光、ISO、焦点与白平衡。逐组确认 DNG、整数缓冲及终结回调后交付，取景恢复失败仍保留已完成的源照片。

UI 布局方向与物理拍摄方向独立。`CameraMotion` 以 20 Hz 采样加速度，连续三个可靠方向样本后切换；平放、对角握持与加速度异常保持原方向。预约冻结物理方向，捕获期间的 UI 方向请求合并到恢复后执行。当前拍摄固定主摄原生视角；旧会话、旧请求和重复回调按身份与阶段隔离。取景就绪要求有效帧实际入队，冻结撤销旧代次投递与刷新。自动会话恢复在 30 秒窗口内最多接纳两次。

点按与长按目标按显示方向转换为传感器坐标，相机曝光补偿限制在硬件范围与 `−2…+2 EV` 的交集。未显式锁定的点选测光可在主体区域变化后恢复连续测光，双击也可恢复；显式锁定保留实际镜头位置、曝光时间和 ISO。虚拟取景固定主摄，恢复显式锁定时使用可维持这些参数的独立物理输入。

屏幕与硬件按键共用快门预约入口，设置、回看或不可采集时关闭硬件事件接管。预约成功后给出按下触觉；最后一组 `didFinishCapture` 确认后发布曝光完成触觉与视觉反馈，后台重建和相册保存另行显示进度。

### 保留、处理与保存

每槽前台流程为 `idle → authorizing → capturing → retaining → processing → saving → idle`。失败进入 `failed`，后台或受保护数据不可读时暂停处理；恢复检查和相册结果未知分别使用 `restoring`、`saveOutcomeUnknown`。两槽共享串行处理许可，重建、颜色、编码与常驻缩略图生成依次完成；已经保留源照片的另一槽等待许可。

收到源照片后，工作流在后台把源数据和快照写入 `CaptureJournal`，同时取得已校验的格式载荷，再执行完整源图处理；主线程只接收结果和发布状态。照片自身的白平衡、解码尺寸与拍摄几何在处理时绑定到本张快照，后续界面设置不参与这张照片的重试。成片回看从已编码 HEIF 解码，编码文件及其尺寸、校验值和最终快照持久化后才提交相册。

Photos 保存复制原始 HEIF 文件，保留原文件名与拍摄时间，并持有文件直至完成回调。成功后先持久化 `savedConfirmed` 和首次确认时间 `confirmedAt`，发布成片并更新 `LatestReviewStore`，再清理该槽位。缓存或清理失败时保留成功回执，重试补齐收尾，首次确认时间不变。HEIF 与兼容分享见[图像管线](image-pipeline.md)。

最近成片缓存先写不可变 UUID 代次，再原子发布 `latest.json`，随后清理旧代次。缓存按首次确认时间排序，恢复旧已保存事务不覆盖更近的照片；加载时验证大小与 SHA-256，并复制到独立回看文件，已有分享所有者继续持有自己的文件。缓存排除系统备份，重启异步恢复 384px 缩略图。

### 磁盘阶段与重启恢复

| 记录阶段 | 已持久化内容 | 恢复动作 |
|---|---|---|
| `rawReady` | 源照片、冻结快照和源校验值 | 校验源文件，使用原快照重新处理 |
| `encodedReady` | 上述内容及 `result.heic`、成片尺寸和校验值 | 重载成片，重新检查权限后保存，复用编码文件 |
| `savePending` | 上述内容及本次保存的 `attemptID` | 保留成片，进入 `saveOutcomeUnknown`，等待用户核对相册 |
| `savedConfirmed` | 已确认保存的回执与 `confirmedAt` | 补齐最近回看缓存并清理该槽，不调用 Photos |

重启后的 `savePending` 有两种用户操作：确认已保存会写入回执并收尾；明确再次保存会先退回 `encodedReady`，再提交新尝试。普通重试、切回前台和重复点击不会自动解决未知结果；该槽保持占用，其他空闲槽位仍可拍摄。

当前进程仍在途的 Photos 事务持续等待原回调，进入后台不会取消或判定该事务失败。如果只写入保存意图、尚未调用 Photos 就进入后台，工作流将记录恢复为 `encodedReady`，回前台再继续。

### 重试与清理

处理失败保留源照片和冻结快照，重试处理同一输入。源持久化失败时，当前任务仍持有输入，重试先完成保留。已有编码结果时，保存失败重试复用该文件；相册明确失败会回到 `encodedReady`。编码记录、回执或清理步骤失败，重试只补齐尚未完成的记录步骤，不重复成功的处理或相册事务。

Journal 在接纳外部文件和重启恢复时检查字节数与 SHA-256，并把已校验载荷交给后续处理。损坏文件、未知版本或暂时不可读的记录进入失败状态并保留文件。普通快门已提交后的失败都需要明确确认放弃，即使只有部分 RAW 交付、无法重试，也不使用普通“OK”删除素材。

成功收尾只接受 `savedConfirmed`，按冻结选择完成归档后退役活动记录。明确放弃直接退役该槽受控目录和暂存范围，不解析损坏 intent，也不执行失败的归档；其他槽位继续处理。目录先改名，再递归删除，后续启动可继续清理。回看与分享文件独立于活动记录。

### 输出尺寸

Speed 与 Balanced 成片固定约 24MP，不提供分辨率选项。Speed 的单帧重建低于 24MP 时放大，Balanced 的双密度重建高于 24MP 时缩小；均先完成配方裁剪、色彩与空间处理，再在线性光中使用 Lanczos 调整尺寸。4:3 成片为 5656×4242，竖拍交换宽高，其他构图保持比例并将像素总数调整到约 2400 万。取景分辨率只影响取景缓冲。

内部图像 API 仍可使用原生尺寸和显式宽高，详见 [图像管线与成片导出](image-pipeline.md)。

### 调色前文件与已归档空间

日常 Balanced 快门的调色前原片归档默认关闭；仅当高级设置开启 `archiveBalancedPreColorRAW` 时，快门才为照片冻结 `rawArchiveID`。携带 `rawArchiveID` 时，处理入口在品牌调色前将浮点相机 DNG、线性 sRGB TIFF 交给 `CaptureRAWStore`，保存到 Documents 的 `RAWCaptures/<ID>/balanced/`；归档失败阻止调色，原有输入留在恢复记录中，重试验证并复用已发布文件，确认保存后的 Journal 清理不删除调色前归档。未携带 `rawArchiveID` 时跳过相机浮点文件持久化与调色前落盘。

高级设置的「RAW 与诊断」卡片提供十一张等曝光 Bayer 记录、当前场景 Balanced 合成原片记录，只在两槽完全空闲时开放。卡片统计 `RAWCaptures`、`F5Archives`、`F5Samples` 的占用组数与字节数，支持二次确认清理已完成归档。场景记录始终生成 `rawArchiveID`，直接归档；输入事务在成功前保留于同组 `bayer-inputs` 目录，失败保留原片。

高级设置的重置效果调整按当前所选色彩引擎恢复后期曝光增益及引擎微调参数（HNCS 曲线／工作色域／渲染意图／工厂色温覆盖、FFCS 参考调整开关与锐化半径、LUMIX 对比度与饱和度），保留当前所选风格预设、表族、白平衡策略及颗粒与锐化开关。

### 格式注册与 F5 边界

`CaptureFormats` 是不可变注册表，`GlassCamApp` 创建含 `F5CaptureFormat` 的实例，并注入工作流服务和 Journal。Capture 定义 `CapturePayload`、`CaptureProvenance`、`CaptureFormat` 及通用事务顺序，并统一创建受保护且排除备份的活动目录。格式实现负责载荷编解码、输入校验与保留、暂存恢复、归档和渲染；保留和恢复返回记录与对应载荷。

Speed／Balanced 使用独立 Bayer RAW 驱动，分别采集一帧／七帧，输出由 F5 曲率重建策略决定，快照固定 24MP 成片目标。完整暂存 burst 可以接入同一个 Journal；未完成 burst 保留诊断文件并要求明确放弃。开启 RAW 归档时，确认保存后的清理先调用格式的归档实现。具体输入限制与重建方式见 [F5](f5.md)。

## 不变量

1. 设置变化不改变已冻结照片的处理及重试配方，方向在相册授权前预约。— `CaptureTests/WorkflowTests.settingsMutation_doesNotRetargetFrozenCaptureOrRetry`、`GlassCamTests/CameraLifecycleTests.reservation_freezesOrientationBeforeAuthorization`
2. 相册授权失败不提交快门或处理，放弃失败任务后释放准入。— `CaptureTests/WorkflowTests.permissionDenied_neverSubmitsShutterOrProcessing`、`CaptureTests/WorkflowTests.permissionFailure_discardReleasesAdmission`
3. 同一槽位拒绝重复快门与回调，相册事务在途时禁止重试、放弃或复用该槽。— `CaptureTests/WorkflowTests.pendingCapture_rejectsSecondShutterAndDuplicateCallback`、`CaptureTests/WorkflowTests.inFlightSave_rejectsDiscardRetryAndNewCapture`
4. 无效配方不提交拍摄。— `CaptureTests/WorkflowTests.invalidRecipe_neverSubmitsShutter`
5. 处理失败重试读取同一源字节和快照，保存失败重试复用已编码文件。— `CaptureTests/WorkflowTests.processingFailure_retryKeepsOriginalBytesAndSnapshot`、`CaptureTests/WorkflowTests.saveFailure_duplicateRetryReusesEncodedFile`
6. `rawReady` 恢复沿用冻结配方，成功清理不删除回看文件，`encodedReady` 恢复不重复处理。— `CaptureTests/RecoveryTests.borrowedRaw_releasePreservesJournalAndRecovery`、`CaptureTests/RecoveryTests.encodedReady_reloadsWithoutProcessing`
7. 保存结果未知必须显式解决，持久成功回执阻止重启后再次保存。— `CaptureTests/RecoveryTests.unknownSave_requiresExplicitResolution`、`CaptureTests/RecoveryTests.durableReceipt_restartDoesNotSaveAgain`
8. 记账与原子写后故障的重试不重复已完成处理或成功的相册事务。— `CaptureTests/RecoveryTests.bookkeepingFailure_retryDoesNotRepeatCompletedWork`、`CaptureTests/RecoveryTests.afterAtomicWriteFailure_retryUsesActualDiskState`
9. 后台处理保留 RAW，尚未提交的保存意图暂停，已在途相册事务不会因前后台切换重复提交。— `CaptureTests/RecoveryTests.backgroundedProcessing_retainsRawForForeground`、`CaptureTests/RecoveryTests.backgroundedSaveIntent_pausesBeforePhotos`、`CaptureTests/RecoveryTests.activePhotosTransaction_foregroundChangesDoNotDuplicateSave`
10. 损坏 RAW 不保存且不静默删除，退出活动区后的清理不重复保存。— `CaptureTests/RecoveryTests.damagedRaw_isPreservedWithoutSaving`、`CaptureTests/RecoveryTests.retiredCleanup_restartDoesNotRepeatSave`
11. 已提交照片不因界面停止或取景恢复失败而丢失，捕获期间的方向变化合并到恢复后执行。— `GlassCamTests/CameraLifecycleTests.committedPhoto_survivesStoppedViewOrPreviewFailure`、`GlassCamTests/CameraLifecycleTests.capture_defersAndCoalescesOrientationUntilRestoration`
12. 取景就绪等待真实入队帧，冻结后排队投递与刷新不能覆盖画面。— `GlassCamTests/FrameDeliveryTests.readiness_waitsForActualEnqueue`、`GlassCamTests/FrameDeliveryTests.freeze_revokesQueuedEnqueueAndFlush`
13. 内部源尺寸检查只接受比例匹配的显式变焦 RAW；变焦元数据不改变固定 24MP 输出。— `CaptureTests/OutputPolicyTests.explicitlyZoomedRAW_acceptsSmallerMatchingAspectOnly`、`CaptureTests/OutputPolicyTests.digitalZoom_keeps24MPOutput`
14. 两种模式固定 24MP，保持构图比例；恢复快照也固定 24MP。— `CaptureTests/OutputPolicyTests.cameraModes_share24MPDimensions`、`adaptiveOutput_preservesCompositionAt24MP`、`restoredSnapshot_normalizesOtherResolutionTo24MP`
15. Photos 仅申请添加权限，导入保留原始 HEIF 字节、文件名、日期和文件所有权。— `GlassCamTests/PhotoDeliveryTests.authorization_requestsAddOnly`、`GlassCamTests/PhotoDeliveryTests.photoImport_keepsOriginalHEIFBytesNameAndOwnership`、`GlassCamTests/PhotoDeliveryTests.photoImport_preservesFilenameDateAndPhotoResourceType`
16. 当前 F5 和 Speed 记录往返保持固定字节，Speed 恢复采用 24MP。— `F5Tests/currentJournal_decodeEncodePreservesBytes`、`F5Tests/legacySpeed_decodeRetainsModeAndUses24MP`
17. F5 保留重试复用原记录与五帧，损坏 burst 保留文件与格式错误，确认保存后按快照归档源文件。— `F5Tests/retainedBurst_retryKeepsOriginalRecordAndFiveFrames`、`F5Tests/corruptBurst_loadRetainsFilesAndOriginalFailure`、`F5Tests/confirmedBurst_clearArchivesOriginals`
18. 自动会话恢复受预算约束，旧代次或取消的会话不重启。— `CaptureTests/SessionRecoveryTests.recoveryBudget_boundsAutomaticRebuildsAndRejectsBackwardsTime`、`CaptureTests/SessionRecoveryTests.staleOrCancelledSession_doesNotRestart`

19. 部分 RAW 交付后的失败要求明确放弃；损坏、缺失或多份暂存记录，以及归档失败，不阻止明确放弃。— `F5Tests/partialBayerFailure_requiresExplicitDiscardOfDeliveredRAW`、`unrecoverableStaging_explicitDiscardRemovesIt`、`savedBurst_archiveFailureDoesNotBlockExplicitDiscard`
20. Bayer 保留目录排除系统备份。— `F5Tests/retainedBayer_pendingDirectoryIsExcludedFromBackup`
21. 日常调色前归档默认关闭；未设置 `rawArchiveID` 时跳过调色前原片写出，已归档目录统计与清理不影响活动恢复目录。— `CaptureTests/SettingsTests.newSettings_liveColorIsDisabled`、`F5Tests/F5FloatArchiveTests.balancedRenderWithoutArchiveID_skipsPreColorFilesAndCameraPersistence`、`CaptureTests/RAWArchiveTests.storageUsageAndClear_removesArchivedRootsWithoutTouchingUnlistedDirectories`
22. 重置效果调整恢复后期曝光与当前色彩引擎的微调项，保留已选风格与效果开关。— `CaptureTests/SettingsTests.resetCurrentEffectAdjustments_resetsActiveEngineTuningAndKeepsStyleAndGates`
23. 源照片保留后可采集第二张，第三张被拒绝，大图处理始终串行。— `CaptureTests/CaptureQueueTests.retainedFirstPhoto_admitsSecondAndBoundsProcessingAndCapacity`
24. 放弃失败槽位保留另一槽，后台暂停不启动等候的大图，重启恢复两槽冻结输入。— `CaptureTests/CaptureQueueTests.discardingFailedPhoto_keepsOtherSlotProcessing`、`backgroundingBothSlots_pausesQueuedWorkWithoutStartingAnotherRender`、`restartingQueue_recoversBothFrozenSlotsSerially`
25. 最近回看跨启动保留成片字节和配方，缓存替换不删除已有分享文件，旧回执不覆盖新照片。— `CaptureTests/LatestReviewTests.newStore_reopensConfirmedBytesAndFrozenRecipe`、`replacement_keepsOneGenerationAndExistingShareOwner`、`recoveringOlderReceipt_doesNotReplaceMoreRecentlyConfirmedPhoto`
26. 保存回执重试保留首次确认时间，中断的缓存代次不替换已发布照片。— `CaptureTests/LatestReviewTests.retryingReceipt_keepsOriginalConfirmationTime`、`incompleteReplacement_keepsLastPublishedPhoto`
27. 预约冻结物理方向并拒绝迟到测光变更，曝光结束先于取景恢复。— `GlassCamTests/CameraCaptureControlTests.reservedCapture_freezesPhysicalOrientationWhileInterfaceRemainsPortrait`、`reservedCapture_rejectsLateMeteringChanges`、`exposureCompletion_stopsHoldSteadyBeforeViewfinderRestoration`

## 数据与版本

活动记录位于应用支持目录的 `GlassCam/PendingCaptures/slot-0` 与 `slot-1`，对应 `GlassCam/F5Staging/slot-0` 与 `slot-1` 暂存范围。相机拍摄使用 F5 记录格式（`schemaVersion: 2`、`sourceKind: "f5"`、`burst/` 与 `result.heic`）；内部单文件入口保留 schema 1（`source.dng`）。记录字段包括身份、创建时间、快照、阶段、源／成片校验值、尺寸、`attemptID`、`lastError` 与 `confirmedAt`。

记录以排序 JSON 键原子写入并同步文件；iOS 文件使用完整文件保护，活动目录排除备份。`CaptureSnapshot` 保留 `recipe`、`output`、`quality`、`f5`、`archiveF5RAW`、`rawArchiveID` 与 `recoverySlot`。F5 来源通过注册格式解码，槽位通过 `CaptureFormats.forSlot` 隔离；决策见 [ADR 0018](adr/0018-bounded-capture-queue.md)。

`GlassCam/LatestReview/latest.json` 使用 schema 1，记录缓存代次、成片 ID、`confirmedAt`、尺寸、冻结快照及文件校验值，对应代次内的 `photo.heic`。回看只保留最近一张已确认照片。

快照缺少 `quality` 时采用 Balanced，Quality 及未知质量值拒绝解码；缺少 `archiveF5RAW` 时采用 `false`，输出策略统一规范化为 24MP；固定样例见 [journal fixtures](../tests/fixtures/journal/README.md)。相机设置恢复时将历史 `f5` 偏好转为 `balanced`、`speed` 保留为单帧 RAW，`square-crop` 预设迁为 `standard`，缺省白平衡策略采用 `photo`；设置迁移不改写待完成照片的已冻结快照（对应 `CaptureTests/SettingsTests`、`RecipeMigrationTests`、`RecoveryTests`）。

| UserDefaults 键 | 内容 |
|---|---|
| `editor.processingRecipe.revision8.v1` | 经过验证的完整相机处理配方 |
| `camera.capture.quality.v1` | Speed 或 Balanced 拍摄质量，默认 Balanced |
| `camera.balanced.keepPreColorRAW` | 日常 Balanced 快门是否归档调色前浮点原片，默认 `false` |
| `camera.f5.keepRaw` | Speed／Balanced 输入 Bayer RAW 归档选择，默认 `false` |
| `camera.grid.visible` | 构图网格开关 |
| `camera.liveColor.enabled` | 实验实时色彩开关 |
| `camera.preview.center.longEdge` | 中心取景长边限制 |

## 已知限制

- 队列容量固定为两张，最近回看缓存只保留一张成片。
- Photos 与本地 Journal 之间没有跨系统原子事务，进程在相册保存成功与回执落盘之间结束会留下需用户判断的未知结果。
- 源文件未成功持久化时，进程内保留的输入无法保证在进程结束后恢复。
- 处理在前台且受保护数据可用时继续，Apple 同步解码或编码调用只能在返回后的取消检查点停止。
- 有效像素是依据解码尺寸与变焦证据的估计，插值输出不增加独立拍摄细节。
- 相机与取景的光学构图对应、实际 RAW 能力、回调时序和设备中断行为需要真机检查。

## 代码入口

- [CaptureWorkflow.swift](../Packages/GlassCamKit/Sources/Capture/CaptureWorkflow.swift)：快照、单张准入、重试、后台暂停与阶段恢复。
- [CaptureQueue.swift](../Packages/GlassCamKit/Sources/Capture/CaptureQueue.swift)、[LatestReviewStore.swift](../Packages/GlassCamKit/Sources/Capture/LatestReviewStore.swift)：两槽准入、串行许可与最近确认成片。
- [CaptureJournal.swift](../Packages/GlassCamKit/Sources/Capture/CaptureJournal.swift)：记录格式、校验、原子写入、回执与清理。
- [CaptureFormats.swift](../Packages/GlassCamKit/Sources/Capture/CaptureFormats.swift)：格式注册、载荷和来源协议。
- [CameraSettingsStore.swift](../Packages/GlassCamKit/Sources/Capture/CameraSettingsStore.swift)：相机偏好与旧设置迁移。
- [ExportSettings.swift](../Packages/GlassCamKit/Sources/ImagingCore/Model/ExportSettings.swift)、[CaptureGeometry.swift](../Packages/GlassCamKit/Sources/ImagingCore/Model/CaptureGeometry.swift)：源尺寸、输出策略和有效像素估计。
- [CameraController.swift](../App/GlassCam/Camera/CameraController.swift)、[CameraBackend+Capture.swift](../App/GlassCam/Camera/CameraBackend+Capture.swift)、[F5CaptureDriver.swift](../App/GlassCam/Camera/F5CaptureDriver.swift)：拍摄预约、会话切换与终结交付。
- [CameraBackend+Orientation.swift](../App/GlassCam/Camera/CameraBackend+Orientation.swift)、[CameraFrameDelivery.swift](../App/GlassCam/Camera/CameraFrameDelivery.swift)、[CameraSessionRecovery.swift](../Packages/GlassCamKit/Sources/Capture/CameraSessionRecovery.swift)：方向、取景冻结和会话恢复策略。
- [CameraMetering.swift](../App/GlassCam/Camera/CameraMetering.swift)、[CameraBackend+Metering.swift](../App/GlassCam/Camera/CameraBackend+Metering.swift)、[CameraMotion.swift](../App/GlassCam/Camera/CameraMotion.swift)：传感器测光坐标、参数继承与物理方向。
- [F5CaptureFormat.swift](../Packages/GlassCamKit/Sources/F5/F5CaptureFormat.swift)、[GlassCamApp.swift](../App/GlassCam/UI/GlassCamApp.swift)：F5 格式实现与应用注册。
- [HEIFSaveDelivery.swift](../App/GlassCam/UI/HEIFSaveDelivery.swift)：Photos 原文件保存和 Files 复制导出。
- [CaptureTests](../Packages/GlassCamKit/Tests/CaptureTests)、[JournalCompatibilityTests.swift](../Packages/GlassCamKit/Tests/F5Tests/JournalCompatibilityTests.swift)、[CameraCaptureTests.swift](../App/GlassCamTests/CameraCaptureTests.swift)、[DeliveryAndControlsTests.swift](../App/GlassCamTests/DeliveryAndControlsTests.swift)：拍摄、恢复、持久兼容和 App 边界测试。
