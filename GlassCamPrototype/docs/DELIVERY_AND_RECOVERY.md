# 保存、兼容分享与失败恢复

更新：2026-10-11。以下为已实现源码；Apple 编译、权限交互、接收端与实际文件仍需设备验证。

## 三条明确的交付路径

1. **保存 HEIF 到 Photos**：仅在点击时申请 `.addOnly` 权限；将最终 HEIF URL 作为 `.photo` 资源交给 Photos，不经过 UIImage/JPEG，文件所有者保留到事务完成。拒绝权限显示错误，可改用 Files。事务提交后不假装能取消或撤销已经发生的保存。
2. **保存 HEIF 到 Files**：document picker 以 `asCopy: true` 导出同一个原始 HEIF。只有成功回调显示保存完成；取消不显示成功。原始临时文件由 sheet/coordinator 保持有效。
3. **分享**：NSItemProvider 先注册 HEIC 文件/数据，再注册 JPEG 文件/数据作为较低保真兼容表示。接收方选择支持的类型；仅在请求 JPEG 时，从最终 HEIF 转码，同尺寸、像素方向归一、8 位 SDR sRGB。没有 JPEG 保存菜单，也不从低分辨率预览转码。标准 Save to Camera Roll activity 从分享面板排除，保存请走前两条明确路径。

HEIC/JPEG 都是 `public.image` 的具体类型。实现没有把任意字节标成 UIImage，没有判断微信 bundle ID，也没有假定所有接收方都按预期协商。微信能否发送、接收、查看，最终是否重编码，仍是未验证事项。

兼容转换为串行、按需、缓存一次的操作。原始文件与兼容临时文件由 provider 和进行中的回调共同保留；不能在关闭 sheet 时立即删除。JPEG 编码前后检查取消；Apple 同步 codec 调用本身不能中途停止。编码器可能分配全图缓冲，串行队列不是峰值内存上限承诺。

## 取消与错误恢复

- 导出保留 worker Task 和显式加锁的取消信号，信号跨越 GCD 解码队列。每个64行块及 codec 前后检查。取消期间保持 busy，直到当前不可中断调用返回，不叠加另一份 RAW/导出工作。
- Photos 保存事务提交前才允许取消；事务已提交时等待真实结果。Files 和分享面板分别有系统取消流程。
- 导入/重新渲染保留可取消 worker，返回后再检查请求标识和取消状态，已取消结果不提交。
- 新图成功解码后先保留源、清空旧的效果图；效果失败仍可看到源图并重试，不丢掉已解码拍摄源。
- 控件配方与显示结果不同或上次效果失败时，保存和分享暂停。相机内改模式后返回编辑页，会重新渲染待应用配方。
- 相机终止错误、打断或严重压力会通过统一错误处理结束挂起拍摄一次；迟到的旧回调不能清理新请求。用户可以关闭或显式重试。

## 验收清单

- Photos 首次允许、拒绝、系统设置撤销；只申请添加权限，不要求读取整个照片库。
- Files 保存、取消、目标不可写；保存的文件与原HEIF逐字节比较。
- 接收端分别只请求 HEIC、只请求 JPEG、请求数据、请求文件；验证类型、尺寸、方向和 SDR 色彩。
- 分享先取消、转换中取消、关闭面板后回调仍在进行、反复分享；确认临时文件不提前失效且最终释放。
- 在 RAW 解码、颜色块处理中和 HEIF 编码期间取消；不保存取消结果，UI 能恢复。
- 效果失败后 Retry；相机模式修改后不拍摄直接关闭；中断/压力发生在快门后；检查没有旧结果覆盖、错误配方导出或卡住快门。

## 官方 API 依据

- [Photos asset resource](https://developer.apple.com/documentation/photos/phassetcreationrequest/addresource(with:fileurl:options:))
- [Photos add-only authorization](https://developer.apple.com/documentation/photos/phphotolibrary/requestauthorization(for:handler:))
- [Document picker export copy](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(forexporting:ascopy:))
- [Provider fidelity ordering](https://developer.apple.com/documentation/foundation/nsitemprovider/registeredcontenttypes)
- [Receiver file lifetime](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation(fortypeidentifier:completionhandler:))

## revision8：快门配方与迟到成功交付

快门同时冻结完整ProcessingRecipe和输出尺寸。一个交付reservation从快门持有至失败/取消，或成功DNG已交给解码源所有者；关闭界面不会丢弃已终态成功照片。新导入、相机打开或导出使旧自动打开资格失效，普通配方rerender不改变这个代次。旧成功回调不得关闭新相机、取消新导入或抢占导出。

成功先保留为一个拥有生命周期的临时DNG文件，再重新检查代次。过期成功显示明确的Open captured photo入口，仅空闲时由用户打开并恢复快门配方；打开失败/取消仍保留，可重试。reservation未释放时另一快门不可用，避免无限待交付队列。若磁盘保留失败，则仅这一份DNG暂留内存并显示警告，仍阻止下一快门；这不是跨退出/崩溃的永久照片库。所有终态失败/取消即使发生在Close之后也释放匹配reservation。

相关源码/状态模型测试不替代Apple并发、后台FileProtection、实际磁盘故障与相机回调时序验收。
