# 当前架构与颜色域

## 分层与数据路径

SwiftUI 管理导入、相机、比较、设置与交付；Apple 层负责解码/颜色管理、真实视频流、缩放与编码；标准 C++17 负责真正 HNCS / FFCS 数值处理。Swift 不重写颜色算法，C++ 不依赖 Apple SDK。Python 对保留资产执行参考验证和诊断。

完整原始文件 → Apple 解码的 linear-sRGB → 选定独立后端 → Float display-linear → 线性光 Lanczos（仅需缩小时）→ 专用 HEIF10 SDR sRGB writer。

预览独立：导入默认最长边 2048px；相机中心/外围视频输出各自缩放。最终输出重新打开完整源，绝不读取 8 位 UIImage 或缩小预览作为导出输入。每颗物理镜头保存 12/24/48MP 输出选择；捕获源、视频预览与处理后输出是三个独立尺寸。

## HNCS：真实核，实验性源桥

原核需要黑位扣除、归一化、白平衡后的 X2D II native RGB。第一版为先看效果采用：linear sRGB(D65) → XYZ → Bradford → inverse(interpolated camera_to_xyz) → virtual native RGB → 原 HNCS → Hasselblad 工作码 → 原显示变换。

桥沿用已有矩阵，不拟合新色卡，不声称 iPhone 标定。JPEG/HEIC 的既有 tone mapping 无法靠线性化恢复，系统 ProRAW 解码也不等于未处理 CFA。工厂 CCT 是核参数而非实测光源；EV 进入核前只乘一次。

保留 double、[0,1] 截断、16 位 ties-to-even 量化、原二维 chroma LUT、暗部/灰度权重、索引、65536 项曲线及色温插值/外推规则。没有新增 HDR 负值/超白保留承诺。

## FFCS：独立完整阶段

linear-sRGB 对应原 FFCS 的 linear 输入路线，不经过 HNCS。19 款真实 XH2S 表，原矩阵、80³ LUT 轴/通道规则、Lab/OKLab、tone、全图坐标/种子 grain 与 sharpen 均保留。CCT 只用于 HNCS。见 [FFCS](FFCS.md)。

## 精确导出与有界暂存

源文件由共享不可变所有者保留。导出每块 64 输出行，FFCS 带一行 halo 和原全图坐标，保证锐化邻域与颗粒在条带间连续。处理后 RGBAf 顺序写临时文件，再只读映射给 Core Image；需要缩小时在线性光 Lanczos 后 clamp，再请求 HEIF10 SDR。没有 8 位回退、PQ/HLG 或 gain map。

这只约束应用处理暂存，不保证总 RSS：Apple 解码、过滤、编码、mmap 常驻页和页缓存可能是全图。48.8MP RGBAf 磁盘中间图约 781MB，另有源、编码文件和安全余量；详见 [全源导出](FULL_RESOLUTION_EXPORT.md)。

## 保存与分享分别交付

- 保存 Photos：add-only 权限，直接以原始 HEIF 文件创建 photo resource；提交后不能取消已开始的 Photos transaction。
- 保存 Files：document picker 复制同一原始 HEIF。
- 分享：一个 NSItemProvider，按 HEIC 在前、JPEG 在后注册准确类型的 file/data 表示。JPEG 只在接收方请求时从最终 HEIF 解码生成，同尺寸、方向归一、8 位 SDR sRGB，成功后缓存。没有独立 JPEG 保存选项，也不重渲染配方/使用预览。
- 分享排除系统 Save to Camera Roll；专门的保存入口承担原始 HEIF 保真承诺。接收方仍可自行选择/重编码，优先注册不是兼容性保证。
- 共享文件所有权覆盖 picker/provider/在途回调，不能仅在 sheet dismiss 时删文件。失败/取消清理不完整输出；Apple 运行时与微信尚待实测。

## 并发、失败与取消

解码/效果/导出离开主线程，阶段串行避免不可取消解码或编码重叠。operation token 阻止旧任务覆盖新选择；导出绑定成功显示的源/引擎/外观/曝光/CCT/种子/输出快照。未渲染配方禁止保存/分享，失败保留可重试的已解码源。

保留实际 worker 的取消句柄，使用 NSLock 保护的显式 token 跨 decodeQueue 传递，在条带与 codec 前后检查；同步 Apple 调用期间不能强制中断，busy 持续到它返回，取消后不提交交付。相机取消/最终回调错误清理 pending capture。Photos 提交后的取消边界独立于编码取消。

## 相机几何与能力

中心使用实际照片比例与窗口 bounds；玻璃仅置于中心之外。主摄/长焦使用真实更广物理流，近似 FOV 映射加覆盖门控；并非同视点无缝拼接，视差/时差/畸变仍存在。超广接受黑色外围。外围永不进入 photo output。取景默认系统色彩，中心可显式开启 [实验性颜色GPU代理](LIVE_COLOR_PROXY.md)，不执行完整逐帧CPU流水线。

完整 graph 配置后及拍摄前检查 ProRAW；最大源、视频输出尺寸、实际 RAW 回调尺寸均门控。单超广 `.photo` 与 MultiCam `.inputPriority` 的高分辨率限制分别处理；没有宣传 48MP 即必然可用的推断。详见 [相机契约](camera-capture.md)。

## 优化与验证界限

HNCS 上下文预计算与精确解码表不改变核；fast 路径只在最终 8 位预览 OETF 允许最多 1 码差，支持至多四线程。Float 导出不经过 fast 字节编码。FFCS 三行环形缓冲是精确路径，默认一线程，避免把不稳定云计时当提速证明。

原核、阶段及条带回归已在云端验证；Apple 编译、光学对齐、HEIF 位流/标签、手机峰值内存/热状态和接收方选择仍未验证。参考测试不替代视觉审美或相机标定。

## 高精度效果显示

原图与效果图均由 Float32 PreviewRaster 保持，单个 Metal-backed CIContext 做比较合成，最终 RGBA16Float SDR drawable。没有8位UIImage中间结果；半精度仅显示存储，CPU原核精度不变。实时视频当前独立为8bit YUV并在UI显示实际格式。详见 [高精度预览](HIGH_PRECISION_PREVIEW.md)。
