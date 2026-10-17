# 设置前置与自动保存

更新：2026-10-15。当前分支 `codex/single-camera-hard-black`。

启动即相机。齿轮进入独立全屏设置页，返回相机后按快门，App 自动应用快门时的完整配方并保存到系统相册。成功后仍停留在相机页；缩略图查看最近一次成功成片，支持 HDR、双击/捏合缩放和分享。不再提供编辑器或导入入口，不新增 App 内图库。

## 设置与输出

`CameraSettingsStore` 统一持有 HNCS/FFCS、曝光、预设、颗粒/锐化/额外裁切、网格、取景分辨率与实验实时颜色开关。沿用旧配方的 UserDefaults 键与兼容解码，设置修改即持久化。取景开关原本只存在于页面 State，现在也会保留。

白平衡由每张 RAW 的 Apple 解码器自动读取（色温、Tint 和 xy 白点），不再保存或恢复旧的手动捕获色温；其余旧设置保留。完整白点随本张配方冻结，预览与导出一致，成片页显示实际读值。详见 [自动白平衡](AUTOMATIC_WHITE_BALANCE.md)。

输出仍按物理相机记录，只提供 24MP/48MP；旧 12MP 迁移到 24MP，未选择时也默认 24MP，原有效 48MP 选择保留。设备不支持所选输出时明确提示并禁用快门，不降为 12MP，不上采样。

两档都从严格校验的完整 RAW 开始，完整应用效果后才进行输出缩小。当前 iPhone 的完整尺寸为 8064×6048；24MP 等比输出 5656×4242。方向可交换宽高。方形预设按相同像素比例裁切，设置页显示实际尺寸和裁后 MP，不能把裁后面积称为完整 24/48MP。

## 所有权与重试

根视图持有 `CaptureWorkflow`，相机、设置和成片页不拥有处理任务。

2026-10-17：自动拍摄改为读取 RAW 白平衡元数据后直接做全源导出，省去不会展示的 RAW 效果预览。最终预览仍从 HEIF 解码；真机速度、像素一致性及线程调度验证见 [HNCS 核查与提速](HNCS_AUDIT_AND_SPEED_20261017.md)。

- 流程为 `idle → authorizing → capturing → retaining → processing → saving → idle`；失败进入 `failed`。
- 快门先创建不可变 `CaptureSnapshot`，再等待 Photos 仅添加权限。拒绝权限不拍摄，提供系统设置入口。
- 一个任务从授权持有到相册真实完成回调。在此期间禁止第二次快门；旧/重复回调通过任务 ID 与阶段校验拒收。界面打开设置及后续参数变化不能改变本张快照。
- 成功 RAW 先保留至受保护文件；磁盘保留失败时只保留这一份内存 DNG。处理失败可用同一快照重试。
- 编码成功后持有经过校验的 HDR HEIF。Photos 失败时保留它；重试重新确认权限并直接提交同一文件，不重拍、不重处理、不重编码。
- Photos 事务在途时不能重试或放弃；收到真实结果后才改变状态。失败照片的放弃需要确认，成功照片只在回调后更新缩略图。
- 最终预览从已编码成片解码，分享同一个 HEIF 文件，避免用缩小预览重建导出。分享 provider 继续保留 HDR HEIF 优先和 JPEG 色调映射兼容表示。

受保护源文件和重试结果是本次进程拥有的临时数据，不是跨崩溃恢复图库。后台会停止相机，已完成 RAW 的处理任务由根对象继续持有；设备锁定导致文件不可读等错误会保留任务并允许回前台重试。

## 验证方法

- `tools/test_apple_images.py` 编译并运行生产 `CaptureWorkflow` 和设置存储，注入授权、保留、处理、相册服务，验证权限拒绝、重复快门/回调、旧回调、处理重试、内存保留、原文件保存重试、Photos 在途保护及设置重建后的迁移/持久化；同时运行真实 Core Image/Metal/HDR HEIF 回归。
- `GlassCamCaptureTests` 是显式运行的真机 UI 验收 scheme，**会自动拍摄并保存两张真实照片到相册**。依次在设置页选择 24MP/48MP，返回拍摄，等待真实保存完成状态，检查仍在相机，再检查成片查看和重启后的输出选择。它不属于普通构建的自动运行步骤。
- 示例：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ios/GlassCam.xcodeproj -scheme GlassCamCaptureTests -configuration Release -destination 'id=DEVICE_UDID' -allowProvisioningUpdates test`。

此验收不等于长时间连拍压力、所有设备、后台被系统强制终止或所有分享接收端均已验证。
