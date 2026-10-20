# HNCS revision 12：HDR 工作域、输出色域与拍摄元数据

2026-10-19。用户要求修复新版 HNCS 文档核查发现的三项问题。代码基于 `main` 的 `7fc092c` 加本轮工作区修改，已完成**签名 Release 构建、严格签名校验和 USB 覆盖安装**。用户随后报告元数据写入失败，该问题已修正；Mac 定向元数据检查及原失败照片重放通过，18:05 已安装修正版。完整回归未运行，本次未启动手机 App 或拍照。见[故障定位和验证边界](METADATA_FAILURE_20261019.md)。

## 修复内容

| 问题 | 新行为 | 主要实现 |
|---|---|---|
| 浮点导出先裁到 sRGB，损失目标色域可表示的颜色 | 保留带符号的 extended-linear-sRGB，转换到线性 BT.2020 后才裁剪和编码 | [hncs.cpp](../core/hncs.cpp)、[ImagePipeline](../ios/GlassCam/ImagePipeline.swift) |
| 逐像素拆除高光后锐化，部分 HDR 明暗差绕过空间处理 | 高光先还原到整张工作图像，再以统一尺度进入锐化；结束后不再乘回旧 gain 图 | [C++ 空间处理](../core/hncs_spatial.cpp)、[Swift 桥接](../ios/GlassCam/HNCSEngine.swift) |
| 成片只保留尺寸，缺少机型、镜头、曝光和拍摄时间 | 从原始文件保留拍摄字段，在首次编码时写入原生 TIFF/EXIF；相册使用原拍摄时间；兼容 JPEG 同样保留 | [PhotoMetadata](../ios/GlassCam/SourceImageStore.swift)、[相册交付](../ios/GlassCam/HEIFSaveDelivery.swift)、[分享](../ios/GlassCam/ShareDelivery.swift) |

依据是 HNCS 新版 `docs/10_原生Phocus全链路审计.md` 的原生锐化、HDR、ICC 和 HEIF 元数据章节，以及 `docs/03_光源模型与白平衡.md`。原生分析的范围与 Apple 输入适配仍分别记录；没有搬入 Sony 标定矩阵或原厂传感器前处理。

## HDR 的完整数据契约

原有非 HDR HNCS 颜色核心、工厂资产、白平衡策略、曲线、CPU 锐化数学仍保留。新的 Apple 适配接口为：

```text
完整 Apple extended-linear-sRGB
→ 有界参考颜色核心、Film Curve、预设 gradation
→ 将源高光还原到工作空间编码值
→ 扫描整张图像的工作值上限，确定一个共同尺度 S
→ 全图除以 S，执行匹配尺度的原生 CPU 锐化及便携颗粒
→ 原生后置饱和度/灰度
→ 解码 S × 工作码，转换到 signed extended-linear-sRGB
→ 在线性 BT.2020 中缩放、处理目标色域越界及 PQ 上限
→ 附加经过筛选的原生拍摄元数据
→ 单次编码为 10-bit PQ HEIF，并回读字段和时间
```

颜色适配仍以 `g=max(1,R,G,B)` 构造有界颜色输入。不同的是，在原版 gradation 后就计算：

```text
w = encode_working(decode_working(code/65535) * g)
```

`w` 是尚未打包的工作空间编码值，可以超过 1。`g=1` 时保留原 Float32 工作值，不做多余的 transfer 往返。工作 transfer 使用现有 legacy ICC gamma 或 L* 定义。

因此 `[2,2,2]` 和 `[4,4,4]` 不再以同一亮度进入锐化。颜色核心仍基于现有 Apple→虚拟 X2D 模型；这个修复没有将 Apple 像素冒充为准备好的原生 X2D HDR RAW，也没有把整条 Phocus HDR 颜色曲线接入声明为已完成。

共同尺度由**整张、已裁切工作图像**计算：

```text
maximum = max(w)
S = 1                              maximum <= 1
S = max(5.8829245141, maximum)      maximum > 1
```

允许的有限工作值和尺度上限为 64，非法或超范围输入返回错误。HDR 分支至少保留原生编码域的 `5.8829245141` 容量，给锐化保留高于源峰值的空间。它是工作码的单位转换，不能理解为再次曝光。

- `hncs_process_apple_hdr_work_float[_parallel]` 输出未打包的 `w`。
- `hncs_prepare_apple_hdr_spatial[_file]` 用一个 `S` 归一整张工作图，并把同一个 `S` 交给锐化的 amount/noise 表。即使关闭两个空间效果，也会执行共同尺度打包。
- 便携颗粒的幅度继续以参考白工作值为单位，打包时幅度除以 `S`，不因 HDR 容量放大颗粒。
- `hncs_clone_with_apple_hdr_work_scale` 创建不可变输出上下文，一次建立 65,536 项解码表；结束阶段使用查表及矩阵，不对每个输出像素重复计算幂函数。
- `hncs_finish_apple_hdr_work_linear[_parallel]` 要求上下文和参数的 `S` 相同，拒绝混用尺度。
- Swift 上下文缓存身份包含 `workScale`。全源导出仍使用 64 行条带，但尺度不会按条带或像素重新决定。
- 新版不写旧的每像素高光 gain 临时图，也不在锐化结束后恢复未经处理的 gain 图。

关闭锐化时新版仍需要完整工作图像，以保证后置颜色阶段使用同一个尺度。原先无空间效果的路径会增加工作文件读写；原先有锐化的路径移除了独立 gain 文件。本轮未做性能与峰值内存验收。

## 色域与显示

新增浮点结束接口不会裁掉 sRGB 的负分量或超过 1 的分量。旧 C ABI 的 SDR 结果维持原行为，避免改变已有参考和旧照片的颜色解释。

新版 HEIF 的输出 `CIContext` 使用 `extendedLinearITUR_2020`。SDK 明确规定输入先匹配到 context 的工作色域，然后执行滤镜；因此末端 `CIColorClamp` 在 BT.2020 中执行。目标范围为非负至 `10000/203`，由 PQ 的亮度上限约束。

成片回看的 Metal/CIContext 也使用线性 BT.2020，再由 Core Animation 转到实际屏幕。这样不会在回看时又把合法的扩展 sRGB 坐标提前截断。实时相机流及外围玻璃不进入照片处理路径。

## 元数据与恢复

`SourceImageFile` 在读取源文件时保存 `PhotoMetadata` 值快照。保留标准 TIFF/EXIF 的机型、镜头、曝光、光圈、ISO、焦距、拍摄时间、时区、秒的小数部分等字段，以及源文件已有的标准 GPS 值；不新增位置采集。

写入时重新设置最终尺寸、方向 1、GlassCam 软件名和自定义处理标记。选择带固定白平衡的 Original preset 时，白平衡标记反映手动目标。RAW-only MakerNote、源图像几何和源编码/色彩标签不直接复制。

拍摄字段通过 `CIImage.settingProperties` 交给原有 HEIF 编码器，在首次编码时写入原生 TIFF/EXIF/GPS 字典。编码后回读主要拍摄字段和时间，并保留 iOS 完整文件保护；没有第二次压缩图像。最初采用的编码后 XMP 合并虽然返回成功，却遗漏必要原生字段并导致每次处理失败，已按[故障记录](METADATA_FAILURE_20261019.md)移除。失败或取消仍保留源照片用于重试；已有保存重试继续复用相同成片。

相册 `creationDate` 使用源拍摄时间；跨进程恢复则从已编码文件重读。EXIF 有 offset/subseconds 时一并解析；无时区的 EXIF 日期仍按设备当前时区解释，不虚构缺失的时区。JPEG 分享读取最终 HEIF 的拍摄字段，在兼容 JPEG 的首次编码时一并写入。

Mac 上的 HEIF/JPEG 原生字段、时区、子秒、输出几何及像素对比已通过定向检查；原失败 RAW 已成功导出 6000×8000、10-bit HDR，拍摄时间差为 0 秒。手机上的处理和相册显示仍待运行验收。

## 旧配方兼容

- 新相机选择及新建配方使用 revision 12。
- 明确的 revision 11 照片继续走旧颜色/HDR流程。
- 旧的 8/9/10、缺失 revision 的持久配方维持上一版兼容到 11 的规则，不在恢复时直接变成 12。
- 相机偏好为**未来拍摄**升级到 12，保留已选择的白平衡、效果、风格等设置。
- 已编码的待保存 HEIF 不重新渲染。未知 revision 仍被拒绝。
- 旧 Square Crop 的照片配方仍能恢复，新相机入口继续排除该选项。

## 构建与安装记录

2026-10-19 17:32（Asia/Shanghai），已将包含 revision 12 与最新 UI 的普通 Release 覆盖安装到 `Equinox的iPhone`。应用版本为 `0.1.0 (1)`，bundle identifier 仍为 `dev.glasscam.prototype`；使用相同标识安装，未卸载应用。开发签名有效至 **2026-10-22 12:56:12 +08:00**。

`xcodebuild build`、`codesign --verify --deep --strict` 及 `devicectl device install app` 均通过；设备安装 JSON 明确返回 `success`。本次没有启动 App 或执行测试。构建日志、安装回执及二进制摘要见[结构化安装记录](../validation/iphone-install-revision12-20261019.json)。

同日 18:05 已覆盖安装元数据故障修正版；Mac 定向验证通过，本次未启动手机 App 或拍摄照片。见[最新修复与安装记录](../validation/metadata-failure-20261019.json)。

## 完整回归与剩余验收

[新增 C++ 接口回归](../tests/test_hncs_hdr_domain.py)尚未运行：

- 用独立工作主色矩阵和 Bradford 公式检查扩展 sRGB 输出，明确要求保留负值及超单位值。
- 检查 2×/4× 中性亮度在空间处理前已不同，并符合工作 transfer 的亮度比例。
- 对高于参考白的中性细纹，分别检查亮边增强、暗边降低及关闭锐化的打包行为。
- 检查全图/不同条带、单线程/并行、内存/文件结果一致，覆盖不同工作尺度和非法调用。

[Apple 图像检查](../tests/apple_image_pipeline.swift)：新增生产 HDR 空间路径、相机元数据、时区与子秒、方向/尺寸、拒绝旧 MakerNote、编码元数据前后像素一致、HEIF 位深/HDR、JPEG 字段保留。其中元数据定向检查已单独运行，完整脚本尚未运行。旧 HDR 归一化预期明确只用于 revision 11 的重放检查，不能继续作为新版锐化是否正确的唯一依据。

得到测试许可后，在仓库根目录执行：

```sh
PYTHONPATH=GlassCamPrototype/tests python3 -B -m unittest test_hncs_hdr_domain test_phocus_native_chain test_x2d_native_gain
PYTHONPATH=GlassCamPrototype/tests python3 -B -m unittest discover -s GlassCamPrototype/tests -q
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B GlassCamPrototype/tools/test_apple_images.py
```

还需真实 RAW 的视觉/24MP/48MP 完整回归、处理耗时、内存和手机验收。上述完整回归命令本轮均未执行；单张失败照片的 Mac 重放与定向元数据检查不证明完整原厂 RAW→成片和跨相机色彩等价。
