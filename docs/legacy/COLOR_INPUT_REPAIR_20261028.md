# 实拍反差与 LUMIX 色彩溢出修复 · 2026-10-28

用户确认问题发生在 **Quality / 高质量** 拍摄，HNCS、FFCS 成片也反差偏大。本轮使用已有 ProRAW 复现并修改生产流程，照片和完整诊断产物保存在源码仓库外。

## 原因

HNCS、FFCS 原来的输入启用了 CIRAWFilter 的完整全局色调曲线 `boostAmount=1`，随后又执行各自的 film curve／Photo Style 明暗映射。同一张照片上，这个叠加明显压低了阴影。把像素转换为 linear-sRGB 只改变传递函数，不会撤销已经应用的全局色调曲线。

LUMIX revision 2/3 使用另一种输入：把 baselineExposure、boost、局部 tone map 和 EDR 全部归零。它去掉了照片自己的曝光基准和暗部调整，使同一张 ProRAW 明显变暗。此前聊天中“LUMIX 默认对比度曲线重复加反差”的推断不成立：解出的原生默认 contrast=10 折线从黑到白均为恒等映射。

LUMIX 还有独立的算术问题。原始 RGB48 接口保留了原程序的 UInt16 低位写回语义：调整色度、对比度后，超出 65535 的通道会回绕。旧手机适配器直接调用这个接口，后面的 clamp 已无法修复回绕值。例如纯绿色在默认对比度下的输出线性 G 约 0.9984，对比度提高到 +1 后反而约为 0.0009。原生接口逐值复刻正确，不代表这套越界语义适用于 iPhone 成片。

Apple 的 SDK 对 `boostAmount` 明确规定：0 关闭全局色调曲线，1 完整应用。全 scene-linear 配方还会关闭曝光基准和局部映射，Apple 也说明其显示结果会偏暗。依据：[boostAmount](https://developer.apple.com/documentation/coreimage/cirawfilter/boostamount)、[ProRAW 官方说明](https://developer.apple.com/videos/play/wwdc2021/10160/)。

## 修改

新照片在配方中冻结 `rawInputPolicy=cameraNeutral`。三个引擎统一关闭 Apple 全局色调曲线，保留源照片自己的 baselineExposure、局部 tone map、白点、色域映射和 EDR；HNCS 继续关闭解码器锐化，由其原有锐化阶段处理。这里的 camera-neutral 是应用输入策略，不是未经任何处理的 scene-linear RAW，也不使用自动直方图匹配或固定曝光补偿。

LUMIX 升级为 revision 4，新增独立的 `lumix_process_iphone_rgba`：

- 保留原始双 129³ 表、色温节点混合、用户对比度／饱和度和黑白色度寄存器。
- 有界 RGB12 输入坐标，色度和 tone 运算使用浮点，去掉 UInt16 回绕。
- 在 SDR 编码域沿等 Y 中性色轴压缩越界色度；95% 边界处开始连续的软压缩，避免各通道单独截断造成突变。它保持该编码域的色度方向，不声称等同于感知色相保持。
- iPhone 路径停止套用松下传感器专用 ISO 50/64/80 补偿，源 ISO 继续保存于照片配方。
- 继续在完整源图上分条处理，保留曝光在 HDR 幅度分离之前的规则和 10-bit BT.2020/PQ HEIF 输出。

原 `lumix_process_rgb12`、`lumix_process_rgb16`、revision 1–3 的浮点入口保持原有数值。持久照片缺少 `rawInputPolicy` 时解析为 legacy；白平衡和 ISO 绑定保留该字段。相机偏好仅为未来拍摄迁移到新策略。已有 HEIF 不会被重写。

## 验证

保留样片 SHA-256 为 `4ad933b123960952a6bfc40dc59455192b2352d5b026854ed390ef54088aca15`，ISO 400，完整解码尺寸 **5416×7222**。生产 Swift／Core Image 管线生成了修复前后预览与三种引擎的完整 HEIF，每种引擎直接导出与预览后导出的文件逐字节一致。

同一张照片的 512px 诊断预览，在线性 sRGB 亮度 Y 上的分位数如下。这是该样片的明暗分布，不能当作所有场景的感知对比度评分。

| 引擎 | 修复前 P10 / P90 | 修复后 P10 / P90 |
|---|---|---|
| HNCS | 0.00529 / 0.63528 | 0.04064 / 0.67917 |
| FFCS | 0.00886 / 0.48949 | 0.05477 / 0.52337 |
| LUMIX | 0.00079 / 0.01366 | 0.05631 / 0.70473 |

验证结果：

- 新增 6 项 LUMIX 数值回归通过，覆盖 16 种风格和参数端点、饱和渐变连续性、灰阶大幅反转、有限 signed 输入、ISO 独立性、并发分条、曝光等价性和非有限输入拒绝。
- 重放冻结原程序的 **56 组、5,506,816 个 RGB48 像素**，三个通道逐值一致；没有重新生成或覆盖原始 golden。
- 生产 LUMIX 检查通过 16 风格、HDR、±1/2 EV、直接／预览／条带一致、历史配方恢复和引擎切换。真实 ProRAW 检查确认三个引擎 boost=0，源 baseline/local map 保留，EDR=1。
- 完整 Apple 图像／拍摄恢复检查通过，包括真实源图 10-bit PQ、24MP／48MP 输出、元数据、白平衡、取消和兼容分享。
- Python 全套 223 项中 **212 通过、11 失败**。在移除本次产品修改的独立源码副本中运行相关 85 项，得到完全相同的 11 项失败；它们是此前 F5／导出重构后未更新的源码字符串断言。本轮没有新增失败，也没有把这 11 项计为通过。
- iPhone 签名 Release、严格签名和包内 33 个 LUMIX 数据文件校验通过，修复版已覆盖安装到连接的 iPhone，bundle ID 为 `dev.glasscam.prototype`。

结构化记录和验证日志位于 [`validation/color-repair-20261028/`](../validation/color-repair-20261028/)。原始照片、HEIF、浮点数据和对照图保留在 `/Users/vonequinox/Library/Developer/GlassCamDiagnostics/color-repair-20261028/`。真机新拍摄后的视觉确认仍需用户实际使用；本轮的实图验收来自保留 ProRAW 的生产流程重放。
