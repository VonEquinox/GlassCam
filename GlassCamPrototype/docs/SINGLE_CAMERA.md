# 单主摄黑边版本

> 2026-10-15 后续更新：相机现为永久主界面，设置独立全屏，拍后自动保存到相册；本文旧编辑入口描述已由[自动保存流程](AUTOMATIC_CAPTURE.md)替代。

本版本位于 `codex/single-camera-hard-black`。原分支和原工作目录保留原有 Liquid Glass / 多摄版本及其未提交修改。

- 启动直接进入相机，无需先经过编辑页点击打开。
- 仅使用物理主摄 1×；一颗相机、一个普通 `.photo` 会话，同时提供预览和 ProRAW 拍摄。
- 成片框保持最大等比显示；原玻璃外围改为不透明纯黑色，硬边、无模糊、无外围视频。
- 删除 MultiCam 配对、外围视频输出、FOV 覆盖门控及拍照时的会话切换。相机设置只保留主摄预览分辨率。
- HNCS/FFCS、快门时的配方快照、原始 RAW 保留、编辑、保存与分享入口继续使用现有处理链。拍摄成功后进入编辑器，缩略图可打开编辑/导入。
- 冷启动保留 2 秒最短拍照准备期；最高源分辨率、实际 ProRAW 类型和返回尺寸仍需严格校验。降低后处理输出尺寸不降低 RAW 请求。

2026-10-15 验证：Xcode 27.0 真机 Release 构建与签名通过；生产相机控制器的单摄自动测试收到 8064×6048 RAW 和 37,101,840 字节 DNG。114 项相机布局、生命周期、预约、配方和效果相关检查，以及 28 项导出、保存、分享和高精度显示检查通过。完整 App 已安装，随后实际拍摄返回编辑页并保留约 48MB 原始文件；编辑页显示 DNG / Apple RAW 解码信息。相机旋转、后台恢复、持续拍摄、导出及性能未在此版本重新全面验收。

便携检查命令（从 GlassCamPrototype 目录运行）：

```sh
PYTHONPATH=tests python3.14 -B -m unittest test_camera_source test_camera_geometry test_single_camera_capture_source test_live_proxy_source test_hncs_revision8_capture_admission test_hncs_revision8_capture_recipe test_camera_chrome_source test_effect_toggle_source test_hncs_revision8_source -q
```
