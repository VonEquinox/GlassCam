# 默认 HDR 导出

2026-10-19：新拍摄的 HNCS revision 12 已改为在空间处理前还原工作图像的高光，并在目标 BT.2020 色域裁剪；HEIF/JPEG 在首次编码时保留拍摄元数据。后续元数据故障修正通过 Mac 定向检查及失败照片的 48MP 重放，18:05 已将签名 Release 覆盖安装到 iPhone；本次未启动手机 App 或拍照，完整输出验收仍待继续。详见[新数据契约](HNCS_REVISION12_20261019.md)及[故障记录](METADATA_FAILURE_20261019.md)。下文保留 revision 11 HNCS／既有 FFCS 的拆分方案和历史验证，不能作为新版结果。

更新：2026-10-15，分支 `codex/single-camera-hard-black`。

保存到相册、文件以及分享首选项现在直接使用 10-bit BT.2020/PQ HEIF。没有 SDR 导出开关。成片页的 Float32 → RGBA16Float 显示开启 EDR，保留超过参考白的数值。实际显示亮度取决于屏幕可用的 HDR 亮度空间。

## 源图与效果

- 预览和完整源 RAW 解码均设置 `CIRAWFilter.extendedDynamicRangeAmount = 1`。普通图片预览请求 `kCGImageSourceDecodeToHDR`，完整源请求 `.expandToHDR`。
- HNCS/FFCS 参考内核保持不变。外层为每个像素保存 `gain = max(1, R, G, B)`，把 RGB/gain 送入原效果，再在颜色、颗粒和锐化完成后恢复 gain。这是保留源高光的 HDR 扩展，不是新的相机标定或 HDR 参考算法一致性声明。SDR 源不会凭空增加高光。
- 分条导出在写 RGBAf 时恢复高光；需要全图空间处理的 HNCS 配方额外暂存每像素一个 Float32 gain，完成全局处理后逐条恢复。所有恢复都先于 Lanczos 缩小，避免延迟滤镜优化改变计算顺序。
- RGB 最终仅限制负值及 PQ 的 10,000 nit 上限（Core Image 203 nit 参考白的约 49.26 倍），不再在 1 处截断。输出设置实际测得的处理后高光范围。
- 写出后检查尺寸、10 位深度与 HDR 色彩空间；出错或取消时删除未完成文件。

## 分享

HEIF 分享保持已编码的原始字节。只接受 JPEG 的应用获得同尺寸、显式使用源 headroom 色调映射后的 SDR 兼容图；源 HDR HEIF 不变。部分接收端仍可能自行转换或压缩，不能把接收端的最终显示视为原文件的 HDR 验证。

## 验证

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B tools/test_apple_images.py`

实际编译生产 Swift/C++ 并调用 Core Image、Metal、HEIF 和分享 provider；包含 0.1–8 倍参考白的 HDR 图、两种色彩模式、方裁切、全局颗粒/锐化、条带边界与缩小。回读检查真实超白像素、10 位深度、HDR 色彩空间、取消清理、HEIF 字节保持与 JPEG 高光压缩。整图参考使用完整源解码，避免 ImageIO 缩略图与完整解码的色度差异影响比较。

可加 `--raw-source /absolute/path/photo.dng` 验证真实 DNG 原生尺寸导出。此选项只读输入，产生的测试输出随临时目录删除。便携源码检查不能替代 Apple 编码测试；macOS 的 48MP 成功也不等于 iPhone 峰值内存、温度或所有接收端均已验收。

## Apple 依据

- [Support HDR images in your app](https://developer.apple.com/videos/play/wwdc2023/10181/)
- [writeHEIF10Representation](https://developer.apple.com/documentation/coreimage/cicontext/writeheif10representation(of:to:colorspace:options:))
