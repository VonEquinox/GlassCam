# GlassCam

新增 **LUMIX** 色彩选项：ProRAW 线性输入、16 种 S1M2 SDR Photo Style、原生双表色温混合、低 ISO、饱和度与对比度处理，以及 HDR HEIF 导出。5,506,816 个原程序 RGB48 样本逐值一致。实现与复刻边界见 [LUMIX ProRAW 说明](docs/legacy/LUMIX_PRORAW_20261026.md)。

GlassCam 是使用 SwiftUI、AVFoundation 和 C++17 开发的 iPhone 相机，支持三摄接力变焦、Apple ProRAW、Speed 12MP／Balanced／Quality 切换、HNCS／FFCS／LUMIX 色彩处理，以及 10-bit HDR HEIF 保存与回看。最低系统为 **iOS 27.0**，构建使用 **Xcode 27**。

主分支为 `main`。应用源码、构建工具、测试和必要参考资源分别位于 `App/`、`scripts/`、`tests/` 和 `vendor/`。

## 功能

- 双指连续变焦、焦段快捷按钮和长按焦距标尺，由系统根据场景选择实际镜头。
- 固定居中的 4:3 成像区、系统 Liquid Glass 外围与独立设置页；根据双摄几何及独立可见接缝证据显示真实更广镜头的外围，失配时渐黑。已修复全遮罩的显示链阻塞并加入原生边界与颜色检查；最新修复仅离线验证、未安装，12 组实拍重放仍只有第 10 组完全透明，见[实现与限制](docs/legacy/FIELD_REPAIR_IMPLEMENTATION_20261023.md)。
- HNCS／FFCS 预设、独立效果开关和设置记忆；HNCS 默认保留每张照片的白平衡，也可选择原始预设白平衡。
- 24MP／48MP 输出策略、全源图像处理和 10-bit BT.2020/PQ HDR HEIF。
- 拍摄后自动保存到系统相册，支持成片回看与分享。
- 单张待完成照片持久恢复，处理中断后可继续，保存失败可重试。

48MP 档按最终构图的有效像素选择 48MP 或 24MP 输出，需要时插值。详细规则见[首版功能与验收记录](docs/legacy/IPHONE_FIRST_USABLE_20261018.md)。

## 目录

| 路径 | 内容 |
|---|---|
| [App](docs/legacy/ios-README.md) | SwiftUI 相机、图像处理和 Xcode 工程 |
| [core](docs/legacy/core-README.md) | HNCS／FFCS C++ 颜色与空间处理 |
| [scripts](scripts) | 构建、资源准备、数值验证和性能工具 |
| [tests](tests) | Python、Swift 与 C++ 回归检查 |
| [vendor/hncs](vendor/hncs/ORIGIN.md) | GlassCam 使用的 HNCS 参考代码、数值资产和测试向量 |
| [vendor/ffcs](vendor/ffcs/ORIGIN.md) | FFCS 固定版本资源和校验材料，构建时从 `source.zip` 准备资源 |
| [docs](docs) | 文档规则、决策与旧主题素材 |
| [tests/fixtures](tests/fixtures) | 固定数值 golden 与回归夹具 |
| [GLOSSARY.md](GLOSSARY.md) | 项目术语 |

## 构建

在仓库根目录运行：

```sh
python3 scripts/iphone_release.py --unsigned
```

构建产物默认位于 `~/Library/Developer/GlassCamRelease`。签名、设备安装和续签步骤见 [iPhone 构建与试用](docs/legacy/ios-README.md)。

## 验证

在已安装 [Python 验证依赖](tests/numeric/requirements.txt) 的 Python 3.12 环境中运行：

```sh
python3 scripts/materialize_ffcs_reference.py
python3 -B -m pytest tests/numeric
```

macOS 图像处理与恢复检查：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B scripts/test_apple_images.py
```

## 当前状态

2026-10-23 最新：根据两份故障分析修复证据聚合、纹理准备、质量恢复和 GPU 资源身份，并加入完整原生可见边界与每边光度模型。217 项回归、生产 Swift／Metal、AddressSanitizer、原始记录导出及签名 Release 检查通过；12 组实拍重放仍有 11 组未通过，未安装或连接手机。代码、逐组证据和限制见[本轮说明](docs/legacy/FIELD_REPAIR_IMPLEMENTATION_20261023.md)。

2026-10-22 最新：用户反馈上一版轻微转动仍反复黑化。离线零位移夹具复现出相关峰被误当成大位移，已修正当前位置一致性判断；160 个运动残差样本、217 项回归、外围组件、AddressSanitizer 及签名 Release 检查通过。用户禁止手机调试后未再访问手机，此新版本未安装。见[运动不稳定诊断](docs/legacy/MOTION_INSTABILITY_20261022.md)。此前双摄及切镜头修复、安装记录见[本轮说明](docs/legacy/PERIPHERAL_STABILITY_20261022.md)，方法来源见[论文调研](docs/legacy/PERIPHERAL_MATCHING_RESEARCH_20261022.md)。

2026-10-20 最新：取景外围改用系统 Liquid Glass，按接缝畸变连续变暗至不透明黑玻璃，取景目标 60 Hz。Mac 离线回归通过，2026-10-22 已续签并覆盖安装到 iPhone（签名有效至 2026-10-29），未启动 App 或拍照；Apple 图像检查中一项旧照片白平衡恢复失败在改动前已存在。见[测试状态](docs/legacy/TEST_STATUS.md)。

2026-10-19 最新：HNCS revision 12 保留浮点输出色域、让 HDR 高光参与锐化，并保留 HEIF/JPEG 拍摄元数据和相册拍摄时间。随后发现的元数据写入失败已修正：定向图像检查及失败照片的完整 48MP 重放在 Mac 上通过，18:05 已将签名 Release 覆盖安装到 iPhone。本轮未启动手机 App 或拍照，完整回归和手机保存结果仍待验收。见[revision 12 说明](docs/legacy/HNCS_REVISION12_20261019.md)及[处理失败的原因与修复](docs/legacy/METADATA_FAILURE_20261019.md)。

2026-10-19：取景与设置重写的代码已写入 `main` 工作区，包括真实多摄外围、10% 误差渐黑／8% 稳定恢复、自定义 Metal 玻璃、移除新拍摄 Square Crop 和中英文界面，已包含在本次构建及安装中。运行测试和真机验收仍等待新的许可。见[设计、代码交付和待验证项](docs/legacy/UI_REDESIGN_20261019.md)。

HNCS render revision 11 已修复 Nature 固定白平衡造成的额外偏绿。修复版已于 2026-10-18 安装到用户的 iPhone，安装后未启动或复测，剩余真机验收仍待继续。已有数值验证限于各自记录的输入与处理阶段，完整跨相机成片等价尚未证明。

- [项目功能与实现说明](docs/legacy/prototype-README.md)
- [测试、性能与待验收项目](docs/legacy/TEST_STATUS.md)
- [Nature 白平衡处理与修复](docs/legacy/PHOCUS_NATURE_PIPELINE_20261018.md)
- [参考来源与分发说明](NOTICE.md)
