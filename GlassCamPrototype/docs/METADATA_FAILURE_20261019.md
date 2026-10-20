# 2026-10-19：拍摄信息写入失败的定位与修复

用户在安装 revision 12 后报告每次处理失败，提示：

> The photo's capture information could not be preserved. Its source has been retained for retry.

问题发生在图像处理和 HEIF 编码完成后的元数据校验。2026-10-19 18:05（Asia/Shanghai）已将修正版签名 Release 覆盖安装到用户的 iPhone；本轮未启动手机 App 或拍摄新照片。

## 失败原因

从手机只读复制了失败照片的 `source.dng` 和 `capture.json`。RAW 为 31,750,693 字节，校验和与恢复记录一致；配方为 HNCS revision 12、Standard、L*、照片白平衡、48MP。恢复记录停在 `rawReady`，没有向 Photos 提交成片。

使用这张照片的真实元数据在 Mac 上复现：所有 `CGImageMetadataSetValueMatchingImageProperty` 调用都返回成功，`CGImageDestinationCopyImageSource` 也返回 `true`，但写出的 HEIF 原生 TIFF/EXIF 中缺少 Make、Model、ExposureTime、FNumber、ISO、焦距、LensModel 等字段。拍摄时间的 `271` 毫秒也丢失了。随后的必要字段校验抛出 `PipelineError.metadata`，丢弃不完整成片并保留 RAW，因此重试仍然失败。

根因是把编码后的 XMP 合并接口当成了完整的原生 EXIF 写入接口。接口返回成功不能证明拍摄字段已经按要求写入。这是本次新增元数据保留代码中的错误。

## 修复

- `PhotoMetadata.encodingProperties` 生成经过筛选、保持原生类型的 TIFF/EXIF/GPS 字典，并写入最终尺寸、方向 1、软件名和处理标记。
- 在 `CIImage.settingProperties` 中附加这些字典，由原有的 `writeHEIF10Representation` 在首次编码时写入。JPEG 兼容分享使用同样的方式。
- 移除编码后的 XMP 合并和临时容器替换。图像仍只经过原有的一次编码，颜色与 HDR 处理配方没有变化，render revision 仍为 12。
- 保留编码后字段、拍摄时间、尺寸、位深与 HDR 校验，以及 iOS 完整文件保护；失败或取消仍保留源照片。

主要实现：[SourceImageStore.swift](../ios/GlassCam/SourceImageStore.swift)、[ImagePipeline.swift](../ios/GlassCam/ImagePipeline.swift)、[ShareDelivery.swift](../ios/GlassCam/ShareDelivery.swift)。

## 已执行的验证

- 单独运行生产 Swift／ImageIO／Core Image 的 `checkCaptureMetadata`：机型、镜头、曝光、ISO、时区及子秒回读通过；拒绝缺少拍摄信息的成片；旧 MakerNote 和几何未混入；附加元数据前后解码像素无差异；10-bit HDR HEIF 和兼容 JPEG 均通过。
- 在 Mac 上以失败照片的原始 RAW 和原配方完成完整导出，得到 **6000×8000、10-bit HDR HEIF**。机型、镜头、1/50 秒曝光、ISO 400 及 `271` 毫秒子秒均保留，拍摄时间差为 **0 秒**。诊断只读取复制的源文件。
- 7 项相关分享／文件保护源码检查通过，`git diff --check` 通过。
- 普通 iOS Release 构建、严格签名校验和 USB 安装均成功。仍使用 `dev.glasscam.prototype` 覆盖安装，未卸载应用。签名有效至 2026-10-22 12:56:12 +08:00。

完整回归套件、UI／相机测试及手机 Photos 保存结果本轮未验证。用户重新打开 App 后，现有恢复流程会继续处理保留照片；Mac 成功不代替手机相册保存的确认。

结构化结果、源文件与二进制摘要、构建及安装回执位置见[故障验证记录](../validation/metadata-failure-20261019.json)。原始照片和诊断产物保留在本机 `~/Library/Developer/GlassCamDiagnostics/revision12-failure-20261019/`，未加入仓库。
