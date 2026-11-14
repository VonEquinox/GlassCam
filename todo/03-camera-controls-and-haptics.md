# 03 · 相机核心操控、方向感知与触觉反馈

补齐真实手持拍摄不可或缺的对焦/测光控制、物理按键快门、方向锁定兼容与触觉节拍。

---

## [A1] 点按对焦 / 测光与前期相机曝光补偿（EV）

### 现状问题
- `CameraView.swift:122-135` 在常规竖屏和横屏下点击照片区没有任何反应。
- 全工程未设置 `focusPointOfInterest`、`exposurePointOfInterest` 或实时 `setExposureTargetBias`。
- `F5CaptureDriver.swift:86-91` 在按下快门后无条件把相机重置为 `continuousAutoExposure` / `continuousAutoFocus` 并等待稳定，导致即使未来加了对焦也会在按快门瞬间被抹掉。

### 打算怎么做
1. **取景器点按对焦与测光**：
   - 将取景区屏幕坐标转换为物理主摄传感器归一化坐标 `(0...1, 0...1)`（严格考虑当前 `videoOrientation` 与 4:3 画幅关系）。
   - 在 `CameraBackend` 串行队列对当前物理主摄设置 `focusPointOfInterest`（`.autoFocus`）与 `exposurePointOfInterest`（`.autoExpose`）；长按取景框支持 **AE/AF 锁定**；画面移动超过阈值或再次轻点空白处恢复连续自动对焦。
   - **玻璃感对焦环 UI**：点按位置浮现一枚精细的半透玻璃十字圆环，合焦收敛时微缩提亮，右侧附带小巧的上下滑动前期曝光小太阳滑杆（调整 `exposureTargetBias`，范围限制在硬件支持的 `±2.0 EV` 内）。
2. **打通 `F5CaptureDriver` 快门继承**：
   - 单摄 `.photo` Bayer 会话建立在同一颗物理主摄上时，继承用户在取景阶段选定的焦点坐标、AE/AF 锁定状态与 `exposureTargetBias`：
     - 若用户已点选焦点或锁定 AE/AF，不再强制重置回中心 `continuousAutoFocus` / `continuousAutoExposure`，而是保持目标对焦点与曝光偏置并在稳定后锁定四帧曝光；
     - 未点选时保持原有自动测光稳定流程。

---

## [A2] 快门与四帧采集的触觉（Haptics）+ 视觉节拍

### 现状问题
- 默认 `Balanced` 模式从按下快门到会话切换、测光稳定、拍完 4 帧并恢复取景耗时明显，全程无任何震动或快门提示，用户极易在曝光结束前放下手机导致多帧配准失败或画面模糊。

### 打算怎么做
1. **三段式精密触觉反馈**：
   - **快门按下瞬间**：触发轻快紧致的机械按下触感（`UIImpactFeedbackGenerator(style: .light)`）；
   - **四帧传感器曝光真正完成瞬间**（`F5CaptureDriver` 最后一组 `didFinishCapture` 返回、用户可以安全移动手机时）：触发一次清脆明确的完成触感（`style: .rigid`）；
   - **异常中断需关注时**：触发 `UINotificationFeedbackGenerator` `.warning`。
2. **取景框瞬时快门呼吸反馈**：
   - `Speed` 单帧：取景框做一次 80ms 的清脆微暗开合，明确告知已抓拍；
   - `Balanced` 四帧：采集期间取景框光学切边保持微亮提示，四帧接收完毕立即收光，让用户形成「微光熄灭即可动手机」的肌肉记忆。

---

## [A3] 接入物理音量键与侧边相机控制键（Camera Control）快门

### 现状问题
- 未接入 `AVCaptureEventInteraction`，横屏双手握持时无法使用音量加减键或 iPhone 相机控制键触发快门。

### 打算怎么做
1. 在相机预览宿主视图上挂载 `AVCaptureEventInteraction`（仅在取景激活、未打开模态页且 `canCapture` 时响应 `.ended` 事件），与屏幕快门按钮共用同一套预约与拍摄入口。
2. 确保在设置页或回看页展示期间停用该交互，恢复系统正常的音量调节功能。

---

## [A4] 竖屏方向锁定（Orientation Lock）下的横拍方向修正

### 现状问题
- `CameraOrientationView.swift:13` 仅读取 `windowScene?.interfaceOrientation`。当用户开启 iOS 控制中心的「竖屏方向锁定」并横握手机拍照时，UI 界面不旋转，`interfaceOrientation` 恒为 `.portrait`，导致拍出的横向照片在相册里竖着歪倒 90°。

### 打算怎么做
1. **分离「UI 布局方向」与「物理拍摄方向」**：
   - UI 控件区布局继续跟随 `windowScene?.interfaceOrientation`（尊重用户的屏幕旋转锁定，但外围图标如网格、风格图标可随重力做平滑的 90° 原地旋转动画，和原生相机一致）；
   - 引入轻量 `CMMotionManager` 加速度计方向判定（带迟滞防抖阈值，避免平放桌面时乱跳），得到真实的物理握持方向（Portrait / LandscapeLeft / LandscapeRight / PortraitUpsideDown）。
2. **绑定快门照片方向**：
   - 按下快门预约时，将真实的物理握持方向传入单摄 `.photo` Bayer 连接与 DNG 方向元数据，确保无论系统是否开启竖屏锁定，成片写入系统相册的方向永远与人眼地平线一致。

---

## [A5] （可选进阶）评估放宽单张阻塞式快门，支持连续抓拍

### 现状问题
- 遵循 [ADR 0001](../docs/adr/0001-durable-single-capture.md)，`CaptureWorkflow` 必须等上一张照片完成 GPU 重建、编码和相册保存（回到 `.idle`）才允许按第二次快门。

### 打算怎么做（需你确认是否纳入）
- **轻量方案（不改单张 Journal 架构）**：实施 `[B1]` 关闭日常 ~570MB 调色前文件写出后，`Balanced` 处理耗时会大幅缩短，可先真机体验提速后的单张间隔是否已够用。
- **进阶方案（采集与处理解耦，需新 ADR）**：将 `PendingCapture` 扩展为有界小队列（例如最多 2–3 个待处理槽位）：一旦相机硬件完成 1 帧或 4 帧 Bayer 采集并恢复取景（约 0.6–0.8 秒），快门立即解锁允许拍下一张，后台串行完成曲率重建与 HEIF 写入相册。
