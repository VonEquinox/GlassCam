# ProRAW 拍摄优先级与 Speed 12MP

2026-10-26：相机增加拍摄优先级按钮，可选择 **Speed、Balanced、Quality**。默认 Quality；设置页也提供三档切换，选择保存到相机偏好。

| 档位 | ProRAW 请求 | HEIF 输出 |
|---|---|---|
| Speed | 明确选择当前照片格式支持的原生约 12MP 尺寸，`.speed` | 12MP |
| Balanced | 保留当前镜头的高分辨率源策略，`.balanced` | 原有 24／48MP 选择 |
| Quality | 保留当前镜头的高分辨率源策略，`.quality` | 原有 24／48MP 选择 |

Speed 不覆盖原来保存的 24／48MP 偏好。切回 Balanced／Quality 后恢复该选择；Speed 状态下分辨率显示 12MP，分辨率按钮固定，不会误显示成 48MP。

## 拍摄与恢复

- 优先级在快门时进入不可变 `CaptureSnapshot`，经权限等待、拍摄队列、源文件保存、编码和恢复一直保留。随后切换按钮不会改变已经提交的照片。
- 每次请求的 RAW 尺寸与返回验证使用同一个选择结果。Speed 不用请求 48MP 再接受系统降成 12MP；找不到对应 12MP 格式时明确失败。
- 普通照片会话仍在启动前准备 `.quality` 上限，允许每次请求使用三档中的任意一档。
- 现有额外两秒稳定等待用于保护高分辨率 RAW 交付。Speed 明确请求 12MP，因此只等待 AVFoundation 自身就绪信号，跳过该额外等待。真实端到端提速仍需真机计时。
- 旧照片记录没有优先级字段时按原来的 Quality 解码；旧的 24／48MP 选择和迁移规则继续适用。
- HNCS／FFCS／LUMIX 后处理保持各自实现。新增的是采集策略与 12MP 输出能力。

实现位置：`ExportSettings.swift` 的 `CaptureQuality` 与 12MP 输出策略；`CameraSettingsStore.swift` 的持久化；`CameraView.swift` 的按钮、分辨率和快门快照；`CameraController.swift` 的请求与尺寸验证；`CaptureWorkflow.swift` 的快照兼容与传递。

## 验证

生产 Swift 工作流检查覆盖三档源尺寸选择、缺失 12MP 拒绝、12MP 原生尺寸保留、优先级序列化、旧记录默认值、未知档位拒绝、24／48MP 偏好恢复及处理中修改设置不改变已拍照片。Python 217 项回归通过。

完整 Apple 图像检查中，新工作流检查及其余图像检查通过；旧 Nature 照片恢复用例仍报告 `Recovered old Nature capture adopted automatic WB or lost its frozen recipe`。该失败在本次改动前已有记录，见 `docs/TEST_STATUS.md` 的 2026-10-20 条目，不能将完整图像套件记为全部通过。

界面、签名构建及设备安装结果保存在 `validation/capture-priority-20261026/verification.json`。界面检查只在模拟器操作按钮，不触发真实拍照。

模拟器三档切换、12MP 显示与重启持久化通过；签名 Release 及包内资源检查通过，已覆盖安装到已配对的 iPhone。没有启动手机 App 或拍照，真实尺寸、画质和速度仍待使用验收。
