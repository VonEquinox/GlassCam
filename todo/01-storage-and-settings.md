# 01 · 存储治理与设置逻辑（已完成）

聚焦消除隐形磁盘暴涨、理顺日常拍摄设置与工程采样工具的分层，并补齐设置页交互漏洞。

---

## [B1] 治理日常 `Balanced` 快门的 ~570MB/张隐形归档（已完成）

- `CameraSettingsStore` 新增 `archiveBalancedPreColorRAW`（`camera.balanced.keepPreColorRAW`，默认 `false`）。
- `CameraView` 日常快门仅在 `settings.captureQuality == .balanced && settings.archiveBalancedPreColorRAW` 时生成 `rawArchiveID`；`Record scene · Balanced` 保持始终归档调色前原片。
- `CaptureRAWStore` 新增 `storageUsage(roots:)` 与 `clearArchives(roots:)`，并在高级设置的「RAW & Diagnostics」卡片提供已归档 RAW 占用统计与二次确认清理。

---

## [B2] 修复 `Reset effect adjustments` 对 FFCS 与 LUMIX 失效（已完成）

- `CameraSettingsStore.resetCurrentEffectAdjustments()` 统一重置 `exposure = 0` 与当前色彩引擎的微调参数（HNCS 胶片曲线／工作色域／渲染意图／色调曲线／工厂色温覆盖、FFCS 参考调整开关与锐化半径、LUMIX 对比度与饱和度），保留已选预设／模拟风格、相机表族、白平衡策略及颗粒与锐化开关。

---

## [B3] 将研发采样卡片 `F5SettingsCard` 下沉至 `Advanced`（已完成）

- 一级设置页仅保留「Photo output」「Photo style」「Viewfinder」与进入「Advanced」的入口；`F5SettingsCard`（整合为「RAW & Diagnostics」）移至 `advancedCards`，并更新 `CaptureWorkflowUITests`。

---

## [B4] 厘清「效果曝光」与「相机前期曝光补偿」（设置页部分已完成，取景器前期 EV 见 03）

- 设置页中的线性曝光调整已明确为 **Tone / Post exposure（色调／后期曝光）**，并附带不改变相机快门或 ISO 的说明；传感器前期曝光补偿保留在 [03-camera-controls-and-haptics.md](03-camera-controls-and-haptics.md) 的 `[A1]` 推进。
