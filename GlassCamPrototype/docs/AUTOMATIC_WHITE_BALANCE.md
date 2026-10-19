# 每张 RAW 自动白平衡

2026-10-15，`codex/single-camera-hard-black`。

2026-10-18 更新：revision 11 将“照片白平衡”和“原始预设白平衡”显式分开。新拍默认 `Photo · Automatic`：下文公式中的 D=B，颜色核 CCT 也跟随同一照片白点，除非用户明确设置 factory override。`Original preset` 保留下文固定目标增益的历史行为；旧待恢复配方仍按这个行为重放，未来相机偏好独立迁移。成片标签对应实际选择。原厂资产与虚拟模型边界不变，详见[Nature 全流程与偏绿修复](PHOCUS_NATURE_PIPELINE_20261018.md)。

## 数据与流程

拍摄保持系统自动白平衡，不锁定固定 Kelvin、不复制其他传感器的 RGB gains。收到不可变 DNG 后，`PhotoWhiteBalance.asShot` 在计算 `CIRAWFilter.outputImage` 前读取解码器默认 `neutralTemperature`、`neutralTint`、`neutralChromaticity`。色温/Tint 用于展示，完整 xy 用于 HNCS 数学；Apple 与 Phocus 的 Tint 单位不能直接互抄。

Apple 解码器负责源图 WB 与内嵌相机配置。这里不从 DNG `AsShotNeutral` 单项推算，不再次应用 iPhone `ColorMatrix`，也不在已经白平衡的 linear-sRGB 上额外套 Kelvin 滤镜。实拍 DNG 的 `AsShotNeutral=[1,1,1]` 不能解释为场景固定6500K；其 AnalogBalance 和内嵌 Apple 配置也参与解码。

`ImportedImage` 持有完整白点；处理时将其绑定到不可变 `ProcessingRecipe`，随后预览、全源条带、空间处理、缓存、导出和成片信息使用同一份数据。全源 RAW 解码也明确复用原 xy。保存重试直接重用 HEIF。处理重试重读同一不可变 DNG，取得其同一 as-shot 白点。设置中移除旧虚拟捕获色温滑块，迁移时保留其他有效设置，忽略旧手动色温。成片页显示实际自动读值。

FFCS 继续使用 Apple 已完成 WB 的输入，不额外加入 HNCS 虚拟响应。已渲染的 HEIF/JPEG 按其内嵌配置解码，视为 WB 已烘焙的 D65 工作空间，不能把不存在的 RAW 白点称为测量值。RAW 白点非法或模型响应非正时使用明确标识的 D65 适配回退，仍保留 Apple 原有解码 WB。

## 虚拟 HNCS 响应

复用原参考 `GainToTempAndTint` 的虚拟传感器响应：

```
F = camera_to_xyz[2] × diag(factory_wb[1])
W = (x/y, 1, (1-x-y)/y)
n = inverse(F) × W
B = n.green / n
A = diag(D / n.green) × inverse(F) × Bradford(D65→W) × sRGB_to_XYZ
```

B 是绿色归一化的虚拟捕获增益；无 WB 预设时 D=B，固定 WB 预设时 D 是原参考的完整目标增益。A 把已经白平衡的 linear-sRGB 映射到参考核心的虚拟输入。无 WB 预设时 A×(1,1,1)≈(1,1,1)，避免重复偏色；不同 xy（包括 Tint）改变完整颜色映射与相对预设增益。

Robertson 表直接从已有、摘要校验的 `x2dii_phocus_422.npz` 提取，可用 `tools/generate_hncs_whitepoint_assets.py` 重建。由白点求出的 CCT 仅选择原有工厂矩阵/LUT，沿用2000–10000K模型范围；成片显示的原始 Apple 色温仍保留到50000K。工厂 CCT override 是独立的高级颜色配置参数。

新增 C ABI `hncs_whitepoint_parameters` 与 `hncs_create_preset_whitepoint`；原 CCT/显式增益构造器和原生 HNCS 核心数值保持兼容。新自动白点没有沿用旧 HNCS 实时 cube 的误差证明，因此 HNCS 显示系统取景；FFCS 已验证的实验实时颜色路径仍可使用。

## 证据与边界

- 独立 NumPy oracle 覆盖暖光、日光、冷光、偏离黑体轨迹的 Tint、28个白点/预设组合；验证虚拟基线、Robertson CCT、完整适配矩阵、无重复 WB 的灰色及非法输入。
- 实际编译生产 Swift/C++：白点快照、Codable、缓存切换/恢复和源图绑定；迁移旧手动WB且保留其他设置；原自动拍摄失败/重试流程。
- 14组真实 HEIF 整图/条带/缩小比较仍为解码像素最大差0；保留 HDR 超白、10位PQ、Metal、JPEG兼容分享、裁切、颗粒和锐化。
- 本机提供的48MP真机DNG读到5222K、Tint +8.7、xy=(0.339429795742,0.352590560913)，输出6048×8064、10位PQ，解码峰值20.319805，HDR没有因自动WB被压到1。

上述是使用实际照片白点驱动的虚拟模型，不是 iPhone/X2D 配对色卡标定。公开其他手机型号的色彩矩阵不能直接套到这台设备。若要验证跨相机绝对色彩准确度，仍需同场景、已知光源/色卡的成对 RAW 测量。Apple RAW 默认还包含解码器处理，本实现不宣称完全恢复物理场景线性光谱响应。

接口依据：[Apple CIRAWFilter neutralTemperature](https://developer.apple.com/documentation/coreimage/cirawfilter/neutraltemperature)、[Apple RAW 解码与白平衡说明](https://developer.apple.com/videos/play/wwdc2021/10160/)。
