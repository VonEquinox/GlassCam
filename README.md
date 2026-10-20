# GlassCam

GlassCam 是使用 SwiftUI、AVFoundation 和 C++17 开发的 iPhone 相机，支持三摄接力变焦、Apple ProRAW、HNCS／FFCS 色彩处理，以及 10-bit HDR HEIF 保存与回看。最低系统为 **iOS 27.0**，构建使用 **Xcode 27**。

主分支为 `main`。应用源码、构建工具、测试和必要参考资源集中在 [GlassCamPrototype](GlassCamPrototype/README.md)。

## 功能

- 双指连续变焦、焦段快捷按钮和长按焦距标尺，由系统根据场景选择实际镜头。
- 固定居中的 4:3 成像区、自定义外围玻璃与独立设置页；可靠对齐时显示真实更广镜头的外围，失配时渐黑。此轮重写已构建并安装，运行效果待验收。
- HNCS／FFCS 预设、独立效果开关和设置记忆；HNCS 默认保留每张照片的白平衡，也可选择原始预设白平衡。
- 24MP／48MP 输出策略、全源图像处理和 10-bit BT.2020/PQ HDR HEIF。
- 拍摄后自动保存到系统相册，支持成片回看与分享。
- 单张待完成照片持久恢复，处理中断后可继续，保存失败可重试。

48MP 档按最终构图的有效像素选择 48MP 或 24MP 输出，需要时插值。详细规则见[首版功能与验收记录](GlassCamPrototype/docs/IPHONE_FIRST_USABLE_20261018.md)。

## 目录

| 路径 | 内容 |
|---|---|
| [GlassCamPrototype/ios](GlassCamPrototype/ios/README.md) | SwiftUI 相机、图像处理和 Xcode 工程 |
| [GlassCamPrototype/core](GlassCamPrototype/core/README.md) | HNCS／FFCS C++ 颜色与空间处理 |
| [GlassCamPrototype/tools](GlassCamPrototype/tools) | 构建、资源准备、数值验证和性能工具 |
| [GlassCamPrototype/tests](GlassCamPrototype/tests) | Python、Swift 与 C++ 回归检查 |
| [GlassCamPrototype/reference](GlassCamPrototype/reference/ORIGIN.md) | GlassCam 使用的 HNCS 参考代码、数值资产和测试向量 |
| [GlassCamPrototype/reference_ffcs](GlassCamPrototype/reference_ffcs/ORIGIN.md) | FFCS 固定版本资源和校验材料，构建时从 `source.zip` 准备资源 |
| [GlassCamPrototype/docs](GlassCamPrototype/docs) | 功能约定、设计和验证报告 |
| [GlassCamPrototype/validation](GlassCamPrototype/validation) | 已执行检查的数值结果与历史证据 |
| [GLOSSARY.md](GLOSSARY.md) | 项目术语 |

## 构建

在仓库根目录运行：

```sh
python3 GlassCamPrototype/tools/iphone_release.py --unsigned
```

构建产物默认位于 `~/Library/Developer/GlassCamRelease`。签名、设备安装和续签步骤见 [iPhone 构建与试用](GlassCamPrototype/ios/README.md)。

## 验证

在已安装 [Python 验证依赖](GlassCamPrototype/requirements.txt) 的 Python 3.12 环境中运行：

```sh
python3 GlassCamPrototype/tools/materialize_ffcs_reference.py
PYTHONPATH=GlassCamPrototype/tests python3 -B -m unittest discover -s GlassCamPrototype/tests -q
```

macOS 图像处理与恢复检查：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B GlassCamPrototype/tools/test_apple_images.py
```

## 当前状态

2026-10-19 最新：HNCS revision 12 保留浮点输出色域、让 HDR 高光参与锐化，并保留 HEIF/JPEG 拍摄元数据和相册拍摄时间。随后发现的元数据写入失败已修正：定向图像检查及失败照片的完整 48MP 重放在 Mac 上通过，18:05 已将签名 Release 覆盖安装到 iPhone。本轮未启动手机 App 或拍照，完整回归和手机保存结果仍待验收。见[revision 12 说明](GlassCamPrototype/docs/HNCS_REVISION12_20261019.md)及[处理失败的原因与修复](GlassCamPrototype/docs/METADATA_FAILURE_20261019.md)。

2026-10-19：取景与设置重写的代码已写入 `main` 工作区，包括真实多摄外围、10% 误差渐黑／8% 稳定恢复、自定义 Metal 玻璃、移除新拍摄 Square Crop 和中英文界面，已包含在本次构建及安装中。运行测试和真机验收仍等待新的许可。见[设计、代码交付和待验证项](GlassCamPrototype/docs/UI_REDESIGN_20261019.md)。

HNCS render revision 11 已修复 Nature 固定白平衡造成的额外偏绿。修复版已于 2026-10-18 安装到用户的 iPhone，安装后未启动或复测，剩余真机验收仍待继续。已有数值验证限于各自记录的输入与处理阶段，完整跨相机成片等价尚未证明。

- [项目功能与实现说明](GlassCamPrototype/README.md)
- [测试、性能与待验收项目](GlassCamPrototype/docs/TEST_STATUS.md)
- [Nature 白平衡处理与修复](GlassCamPrototype/docs/PHOCUS_NATURE_PIPELINE_20261018.md)
- [参考来源与分发说明](GlassCamPrototype/NOTICE.md)
