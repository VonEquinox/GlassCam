# 测试与性能状态

更新：2026-10-18。应用配方版本仍为 render revision 10，新增独立 X2D HDR 阶段 API 和严格 FFCS 缓存优化。后续日期章节保留历史证据，其中“当前源码”“已安装”和手机计时均指对应当时构建。

## 2026-10-18：X2D HDR、原始 FFCS 审计与受控加速

- 普通 X2D 有效处理增益修复、HDR film curve／颜色核，以及原版导出工厂和机型／RAW 身份检查已形成独立报告。HDR 后置的 42 组比较共 8,707,059 通道为零差；HDR 锐化的 293 组参数／46 组模式、9,601,024 表项与 1,668,417 像素通道一致。
- HDR 使用独立 gradation 表，不能复用 SDR 表。Standard／Nature 的 471,846 个合成通道及三个真实 HDR 串联案例通过；真实锐化比较排除未保存邻域的四像素边界，最终内部区域 28,224 通道零差。RAW 前处理和最终 ICC 未被扩大声明为完整独立移植。
- 原始 SILKYPIX 50 表、1,450,500 输入像素的两种固定点映射逐项零差；当前 FFCS 再采样资产的最大 ΔE00 为 3.502497，不能声称富士机内 JPEG 等价。39 个 V2 文件头在读取前的矩阵替换补测也通过，原文件哈希不变。
- 完整 Python 回归 **206 项通过（25.541 s）**。首次失败为文件保护封装后的旧源码定位断言；已改为检查共享配置中的 iOS 完整保护分支，没有改变数值预期。
- 实际 Apple 运行回归通过：预览／Metal HDR headroom、14 组 SDR/HDR HEIF、真实 6048×8064 DNG 到 10-bit PQ、工作文件行序、设置迁移、取消、保存失败重试与分享 provider。相机及 Photos 使用测试替身，没有操作手机。
- ASan/UBSan：FFCS 19 个外观／760 次条带调用、HNCS 106 组阶段／空间检查通过，含 HDR 新接口和异常参数；本次没有启用 LeakSanitizer。
- iOS Release、`generic/platform=iOS`、`CODE_SIGNING_ALLOWED=NO` 构建成功。保留现有弃用和界面方向警告，未签名、安装或真机测试。
- 严格 FFCS 缓存使 Mac 完整耗时降低约 0.8%–2.1%，64 个旧新 HEIF 逐字节一致；额外缓存 512 KiB／上下文。Metal 候选的完整 HDR 质量失败，Core ML FP16 失败，FP32 仅通过合成筛查且计划优先 CPU，均未替换默认路径。

证据：[统一验收](../validation/color-research-final-20261018.json)、[X2D](X2D_COLOR_PIPELINE_20261018.md)、[FFCS](FFCS_ORIGINAL_AUDIT_20261018.md)、[性能](COLOR_PERFORMANCE_20261018.md)、[逐项工作记录](COLOR_PIPELINE_WORK_20261018.md)。

## 2026-10-18：原版锐化、后置颜色及本地完整验收

- 使用 analyze-it 指定的 radare2 / r2ghidra 生成 18 份可读 C 反编译，补入已验证的 ABI 参数名，直接读取二进制常量。修复局部预设缺失锐化字段的解析，原生 getter 验证 56 个键与 8 组缺失／开关案例。
- 原版亮度锐化接入生产内存／磁盘流水线；从每张 RAW 冻结 BaselineSharpness，HNCS 明确关闭 Apple 额外锐化，Standard 不再错误旁路。版本 8/9 的选择和效果开关迁移到 10，未知版本拒绝。
- 修复饱和度／灰度执行顺序及全局饱和度近似。两轮颜色核／曲线对比共 203,709,420 个通道，最大 UInt16 差 0；56 个后置颜色检查共 33,855,528 个通道为 0 差。整条串联另有 712 组、4,949,196 个通道为 0 差。
- 两个不同随机种子、O0/O3 锐化测试分别覆盖 293 组参数及 46 组图像模式，所有表值与 UInt16 像素一致；96 组新接口／边界／取消检查通过 ASan/UBSan。
- 本地完整 198 项测试通过。首次运行的 FFCS 缺失资源已从哈希锁定的原始 ZIP 恢复；115 个参考文件与 50 个原生 LUT 摘要核验通过，未修改参考数学或历史黄金值。
- Mac 实际 Swift／Core Image／Metal／14 组 SDR/HDR HEIF 回读通过。已有 48MP DNG 的基线读取、关闭解码锐化、配方重放、全源 10-bit PQ 导出通过。Standard/Nature 的 24/48MP 各一对直接／预览后导出文件与完整 Float32 解码均一致；实际自动处理服务的内存回退和失败重试通过，相机及 Photos 使用测试替身。
- iOS Release 通用设备目标编译成功，未签名、未安装或实测手机。旧版手机耗时不能作为 revision 10 的性能保证。原版数值等价限于已列的非 HDR 工作域、全源像素尺度和工厂参数；HDR、源域适配及跨相机匹配边界单独说明。

详见 [可读反编译](PHOCUS_READABLE_ANALYSIS_20261018.md)、[本轮交付](PHOCUS_REVISION10_20261018.md)及[统一证据](../validation/phocus-revision10-20261018.json)。

## 2026-10-17：直接 Phocus 二进制核查与 render revision 9

- 直接调用原始 Phocus 4.2.2 arm64 颜色核和 gradation；修复 revision-8 参考中错误的无调整旁路。原版 Standard 通道表及 RecoverHue 仍有舍入，旧实现最多相差 2 个 UInt16 码值。
- 当前源码通过 36 组颜色核、43 套配置的 86 组曲线及 24 组组合检查，合计 58,797,558 个通道比较，最大差 0。另有 10 组白平衡、80 组暗部色度权重和 60 组 film 选择检查。
- 77 项相关便携检查、逐点数值回归、949,256 像素密集检查及 Apple 实际 Swift／Metal／14 组 HEIF 回归通过。render revision 8 的设置完整迁移到 9，未知版本拒绝。Release 签名和安装成功，手机设置按值保留。
- Standard 补回处理后有额外 CPU 成本；本轮仅有 Mac 颜色阶段测量，历史 2.77 秒手机结果不能直接代表 revision 9。未在本轮重新实拍或测量手机完整导出。
- 原版暗部权重作用于色度，不是暗部提亮。这里的数值一致不覆盖 Apple 输入适配、完整 RAW／HDR／镜头处理或原版空间锐化，跨相机色彩匹配仍未完成。

详见 [二进制核查](HNCS_BINARY_AUDIT_20261017.md)、[本轮证据](../validation/hncs-binary-audit-20261017.json)、[Apple 日志](../validation/hncs-binary-apple-20261017.txt)。

## 2026-10-17：统一 RAW 输入与候选显影对照

- RAW 缩小解码、自动导出元数据绑定、全源导出共用配置入口；候选配方保留所选解码器版本和捕获白点。当前默认显影输出不变。
- 完整解析本机内嵌双光源矩阵、257 点色调曲线和 12×16×257 局部增益表；不把这些表再次作为 sRGB 纠色变换叠加。
- Mac 与 iPhone 各生成 15 张全源处理后的 24MP HDR 成片，10 组 HNCS 直接/预览后导出逐字节一致。当前配方的 Mac 24/48MP 与手机 24MP 结果保持旧输出。
- 65 项便携检查、Apple 图像回归、真实 48MP RAW 和 iPhone Release 构建通过；交互对照页面通过 Chrome 运行检查。
- 有限非饱和区间的 ±1 EV 解码响应逐位满足倍率关系；EDR 参数会改变像素，不能顺手归零。候选仍明显改变明暗，尚未形成原版 Phocus 匹配或绝对色准结论。
- 额外中间调对齐只使用一个曝光标量，并通过独立计算核验；不作为哈苏风格定义。正式 App 安装、启动和进程检查通过，原有设置按值保留，临时诊断 App 已移除。

详见 [RAW 输入实验](RAW_INPUT_STUDY_20261017.md) 和 [验证数据](../validation/raw-input-study-20261017.json)。

## 2026-10-17：HNCS 保精度提速与续接验收

- 自动拍摄直接从 RAW 导出，省去不会展示的预览计算；Apple 精确颜色核复用最多四个 libdispatch worker，并行空间预设前后的独立像素阶段。原数学、空间算法、浮点编译约束保持不变。
- 历史 Standard 真机前后基线 24MP 3.632→2.772 秒、48MP 3.746→2.875 秒有对应 RAW、报告和源码摘要。续接补测 L*RGB/EV -0.05：同构建双路径对照中，Standard 直接导出为 2.737/2.853 秒，Nature 为 5.437/5.684 秒（24/48MP）。这些计时均不含相机拍摄和 Photos 事务，不代表相机取景同时运行时的延迟。
- 续接共 24 个 HEIF，四个预设/尺寸组内文件逐字节一致；每组首对完整 Float32 解码摘要一致。两种预设分别通过实际生产 CaptureWorkflow/live 处理服务的磁盘保留、内存回退、失败后复用同一成片重试；相机回调与 Photos 为测试替身。
- 67 项相关便携检查、Apple 图像/Metal/14 组 HEIF 回归通过；22 个基准源码/资产摘要与当前代码一致。正式 App Release 构建、安装、启动和进程检查通过，既有设置按值保留。
- HNCS 核及预设与参考一致，不等于 iPhone 已完成哈苏配对标定。未部署 GPU 近似颜色核或 ANE 模型；GPU double 能力探针返回不支持。

详见 [颜色核查与续接验收](HNCS_AUDIT_AND_SPEED_20261017.md)、[真机报告](../validation/hncs-followup-iphone-20261017.json)、[Apple 回归日志](../validation/hncs-followup-apple-tests-20261017.txt)。

## 2026-10-15：自动读取每张 RAW 白平衡

- 移除固定虚拟捕获色温滑块，每张 RAW 从 Apple 解码器读取温度、Tint 和完整 xy，随本张配方冻结。HNCS 用完整白点建立虚拟捕获基线与预设相对变化；FFCS 保留源图解码白平衡。成片页显示实际读值，旧有效效果/尺寸设置继续保留。详见 [自动白平衡](AUTOMATIC_WHITE_BALANCE.md)。
- 143项相关便携合同检查和3项新 NumPy 原生数值测试通过；新数值测试覆盖7个白点的CCT/增益、28个白点/预设矩阵组合、无重复WB的中性灰、Tint变化与非法参数。
- 生产 Swift/C++ Apple 回归通过，包含自动白点快照/Codable/缓存切换/每图绑定、旧手动WB迁移、原流程失败重试，以及14组真实HEIF整图/条带/缩小比较（最大解码像素差0）。
- 真实48MP DNG：自动读到5222K、Tint +8.7，输出6048×8064、10位PQ，解码峰值20.319805。原52组/6656像素黄金向量与892080额外原生通道继续0差。
- 真机 Release 构建通过，已安装且使用 devicectl 正常启动 GlassCam。新增成片页自动WB读值的UI断言；本轮自动化程序启动被 iOS 签名信任检查拒绝，因此没有将本轮新拍照验收记为通过。普通 GlassCam 可正常启动；此前24/48自动保存验收属于上一节历史功能记录。
- HNCS 自动白点不沿用旧固定5500/6500K实时cube的误差预算，取景使用系统画面；FFCS 已验证的实验路径保留。虚拟模型仍非配对色卡标定。

证据：[本轮结果](../validation/automatic-white-balance-tests.txt)、[实际Apple运行日志](../validation/automatic-white-balance-apple-tests.txt)。

## 2026-10-15：设置前置、拍后自动保存

- 永久相机主界面，独立全屏设置页；所有效果和取景偏好由同一个设置存储持久化。原配方兼容恢复，输出仅 24MP/48MP，原 12MP 迁移至 24MP。详见 [自动拍摄](AUTOMATIC_CAPTURE.md)。
- 根对象持有生产 `CaptureWorkflow`，快门冻结配方/尺寸，先授权后拍摄；一张照片自动完成 RAW 保留、全源处理、HDR 编码和 Photos 保存。保存失败保留同一 HEIF 并直接重试；Photos 事务在途拒绝重试/放弃/第二次快门。
- 143 项相关便携检查通过。删除只描述旧编辑器自动打开资格的状态模型，改为实际编译生产 Swift 流程并注入服务，验证权限拒绝、重复/迟到回调、设置不可变、处理/保存重试、内存保留和持久化迁移。不是把源码检查计数等同于 Apple 运行时测试。
- Apple 图像运行时回归通过，包含 14 组真实 HEIF 整图/条带/缩小比较、HDR 超白、Metal、分享以及真实 48MP DNG 导出；原生颜色核心不变。
- 真机 UI 操作已分别完成设置选择 → 返回拍摄 → 自动保存：24MP 为 4242×5656，48MP 为 6048×8064。只在 Photos 成功回调后显示成功状态，拍后仍保留快门和缩略图。
- 新增独立 `GlassCamCaptureTests` 真机验收 scheme；运行它会实拍并保存照片，普通构建不会自动执行。
- 最终 `testSettingsAndAutomatic48MPSaveAndReview` 真机 UI 验收通过：真实 48MP 自动保存、从缩略图打开成片、返回相机、终止并重启后恢复 48MP 选择。界面显示用 Metal 层现明确禁用 UIKit 触摸，避免吞掉缩略图按钮或缩放手势；设置页保留打开时的能力快照，后台停止相机不会清空设置选项。
- 原分支及原有 32 个改动/新增文件的 SHA-256 摘要保持不变。

## 2026-10-15：默认 HDR 导出

- 单摄黑边分支现默认写 BT.2020/PQ 10-bit HEIF。RAW 预览/全源解码启用 EDR；原有参考效果外层分离并恢复源高光，编辑显示启用 EDR。原 HNCS/FFCS 数学内核不变，HDR 适配边界见 [HDR 导出](HDR_EXPORT.md)。
- 本机实际 Apple 回归通过：7 组 SDR 来源与 7 组 HDR 来源的整图/条带/裁切/颗粒/锐化/缩小输出，经相同 HEIF 编码后解码像素最大差异均为 0；包含真实超白回读、10 位深度、HDR 色彩空间、取消清理与分享 provider。兼容 JPEG 显式读取源 headroom 后色调映射，两处源高光的红通道回读约 0.790 / 1.009（JPEG 与色彩转换可略超出 1），未一起被裁成白色。
- 使用 iPhone 保留的真实 DNG 运行生产流水线，输出 6048×8064、10 位 PQ HEIF，3,882,012 字节；回读最高线性值 20.414772。此完整源导出及回读检查在 Mac 上约 3.4 秒，不代表 iPhone 耗时或峰值内存。
- 28 项导出/保存/分享/显示检查通过；Xcode 27.0 真机 Release 编译和签名校验通过，完整新版已安装并启动到连接的 iPhone。此次未在手机上执行 Photos/Files 保存或测量 HDR 屏幕亮度、48MP 导出峰值内存。
- 原分支仍为 `glasscam-ios-hncs-prototype-20261011`，原工作区 32 个改动/新增文件 SHA-256 摘要全部保持一致。

## 2026-10-15：单主摄黑边分支

- 新分支 `codex/single-camera-hard-black` 在独立工作目录实现；原分支工作目录的 32 个原有修改/新增文件摘要保持一致。
- 启动自动打开相机，原生玻璃和编辑器材质背景替换为实色；相机外围为纯黑硬边。只使用物理主摄，普通 `.photo` 会话同时取景和拍照，已删除 MultiCam 和外围取景逻辑。
- Xcode 27.0 Release 构建与签名通过。单摄生产控制器真机自动拍摄收到 8064×6048 RAW，生成 37,101,840 字节 DNG。
- 114 项相机相关检查与 28 项导出/保存/分享/显示检查通过。旧双摄切换模型移除，迟到照片的配方测试改用终态提交/取消模型；保留图像最大等比、控件安全区域、原始数据类型与尺寸、取消/晚回调等检查。
- 完整 App 安装后，15:48 的实际拍摄已返回编辑页并保留约 48MB 源文件；只读截图显示 DNG / Apple RAW 解码信息及实色编辑控件。
- 具体路径与未验证范围见 [单摄版本说明](SINGLE_CAMERA.md)。以下多摄/玻璃章节是之前版本的历史记录。

## 2026-10-15：真机快门与高分辨率请求修复

- 真机点击日志确认旧版快门收到操作，但预约检查为 `available=true, currentSession=false`，随后静默返回。相机改为由同一个可识别会话项驱动 `fullScreenCover(item:)`，弹层直接使用传入项的票据；修复后日志为 `currentSession=true`。旧回调仍只能关闭匹配的相机页，预约拒绝会显示错误。
- 第一次进入实际拍摄后，请求 8064×6048，返回 RAW 元数据和像素缓冲区均为 4032×3024，因此原有严格尺寸校验拒收。没有放宽校验来接收较小照片。
- iOS 27 模拟器中直接运行 AVFoundation API 证实：设置 `.quality` 后调用旧版 `isAutoStillImageStabilizationEnabled = false`，`photoQualityPrioritization.rawValue` 从 3（quality）变为 1（speed）。已移除该弃用 setter。Apple [高分辨率拍摄说明](https://developer.apple.com/videos/play/wwdc2026/304/)规定 48MP 支持 balanced / quality，不支持 speed。
- 仅移除弃用 setter 仍返回 12MP。最小普通 `.photo` 会话在相同光线下可返回 48MP；原控制器中，恢复默认帧率、预分配 RAW 资源或重新应用 `.photo` 预设都未单独解决。实际差异是新会话刚启动时 `captureReadiness` 已为 ready，但立即拍摄仍返回 12MP；等待 2 秒后两次返回 8064×6048。
- 拍照图启动后增加 2 秒最短准备期，并继续受原 8 秒就绪期限、请求身份和取消校验约束；释放图时清除准备期限。最终生产控制器在新的进程中再次自动测试，通过完整双摄→单摄→拍摄路径，RAW 元数据和缓冲区均为 8064×6048，`fileDataRepresentation()` 返回 21,314,292 字节。此等待是该设备/iOS 上的实测缓解措施，其他设备/状态仍可能拒收，严格尺寸校验保留。
- 更新后 120 项相机、切换状态、预约/配方和界面相关检查通过；真机 Release 编译、签名校验、安装与启动通过。自动诊断程序已由完整 GlassCam 替换。13:55:30 的用户实际快门再次返回 8064×6048 RAW；只读设备截图显示已回到编辑器，App 容器保留约 52MB 原始源文件，编辑页显示 RAW 解码信息。未执行此次照片的 Photos/Files 保存、分享或完整导出验收。

## 2026-10-15：iPhone 预览格式修复与本机取景

- Xcode 27.0 真机 Release 构建、签名、安装与启动通过；设备为 iPhone 18 Pro Max，iOS 27.0.1。
- 真实主摄预览仅公布 10 位 YCbCr 格式，旧版只接受 8 位，触发启动错误。协商移到连接提交后，系统取景新增 `x420` / `xf20` 支持并保留实际帧格式、尺寸校验。
- 主摄/外围分别以 `x420`（10 位）和 `420f`（8 位）收到匹配帧。Device Hub 远程交互会让两个 App 收到空视频；退出后，用户在 iPhone 本机确认 GlassCam 取景正常。临时像素/图层诊断代码已移除。
- 68 项相机、几何、拍摄切换、状态规格和实验色彩源码检查通过。使用 Python 3.14 运行 `PYTHONPATH=tests python3.14 -B -m unittest test_camera_source test_camera_geometry test_capture_handoff_source test_capture_handoff_model test_live_proxy_source -q`。工程引用检查兼容 Xcode 保存时插入的注释和换行。
- 该预览检查阶段没有拍摄或保存照片；随后快门实测见上一节。超广/长焦、旋转矩阵、导出、光学对齐或性能仍未验收。10 位系统预览不代表实验实时色彩覆盖范围扩大。

## 本机 Apple 验证与行序修复（2026-10-13）

- Xcode 27.0（27A266a）、iOS 27.0 Simulator SDK、arm64：Debug / Release 构建通过；应用已安装并启动于 iPhone 18 Pro Max 模拟器。现有相机旧 API 仍有弃用警告。
- 修复 CI 坐标与从上到下位图行序混用，统一导出分块、HNCS 工作文件、奇数尺寸方裁切；两个 Metal 预览共用显式翻转的渲染目标。
- 实际编码回归发现 alpha clamp 会扩大图像范围，已在缩小 HEIF 和兼容 JPEG 编码前恢复有限边界。
- 77 项相关便携检查通过，覆盖裁切、空间文件、预览、保存/分享及其状态约束；不是重新运行上游全部 225 项数值测试。
- `python3 -B tools/test_apple_images.py` 通过：64/64/3 行重建误差 0；Foundation 文件以不同分块读写仍保持像素和通道；奇数竖图/横图比较与效果裁切一致；Swift 文件空间处理与原生颗粒、锐化 oracle 一致；真实 Metal 纹理的四象限方向一致。
- 7 个真实 HEIF 案例覆盖 HNCS Standard、Square Crop、Artistic Grain、High Sharpness，FFCS 中性/带 halo 的解析叠加，以及缩小输出。和全帧处理经同一编码器产生的结果比较，解码像素最大差均为 0；ImageIO 检查输出尺寸和 10-bit 深度。
- 取消导出保留输入且不发布文件；真实 `NSItemProvider` 回调返回不变的 HEIF 字节，并成功生成、缓存同尺寸 8-bit JPEG。

尚未验证：iPhone ProRAW / 多摄硬件、真机显示与功耗/内存/热状态、完整 EXIF/RAW 格式矩阵、独立 HEVC 位流检查、Photos/Files 真机保存与微信等接收端行为。上述合成图与本机提供者测试不证明这些结果。

## FFCS 0.2.0 新参考同步（2026-10-13）

最终整合 **225/225通过，30.090秒**；288个源码/资源/参考文件测试前后摘要一致。见[完整日志](../validation/ffcs-v020-integration-tests.txt)、[冻结清单](../validation/ffcs-v020-integration-manifest.json)和[独立审阅源快照](../validation/ffcs-v020-reviewed-source-sha256.json)。

- 来源c4b3383：115份交付文件、50原生表、2ICC、ZIP/Gitblob摘要核验。上游61项测试全过；19案例/198阶段复现，原baseline未改，见[上游运行](../validation/ffcs-v020-upstream.json)。
- 新参考86个表族/外观组合覆盖50资产；134 encoded案例、1,206阶段最大误差5.5164e-15（阈值1e-12），48 linear参考案例最大Float误差0；576优化输出和900全局条带逐位一致，见[核心报告](../validation/ffcs-v020-native.json)。
- 另有160全图/线程/动态halo配置与163非法容器测试通过ASan/UBSan；LSan在ptrace环境不可用，见[命令与源摘要](../validation/ffcs-v020-sanitizers.json)。旧开关专项也迁移到显式解析叠加后验证独立阶段，保留0.1历史报告。
- 旧FFCS实时cube失效，0.2重测每look452,780个holdout，仅XH2S中性PROVIA/ACROS、EV0、半径1回到实验准入。其他表族/解析叠加/参数原画回退，见[实时误差](FFCS_V020_LIVE.md)。
- 单线程完整Float输出云CPU中位数（预热+3次）：256×144中性6.99ms/解析叠加31.08ms；1024²中性235.31ms/叠加1000.13ms。二者数学和像素有意不同，不能称为无损优化；不含Apple解码/编码/屏幕，也不是iPhone速度。见[benchmark](../validation/ffcs-v020-benchmark.json)。
- 独立源码审查通过；Apple Swift编译、实际ICC/RAW、HEIF位流、行方向、内存、设备性能及微信未执行。JSON/生命周期测试是便携模型及源码契约。


早期保存/分享合并运行 [43 项测试通过，26.105s](../validation/final-source-tests.txt)，随后精确 Float 并行集成 [43 项通过，19.088s](../validation/performance-integration-tests.txt)，包含保存/分享、显式跨队列取消 token、render 完成竞态 guard 与已解码源 Retry 的源码契约。Apple 代码仍只做静态验证。

## 已执行并通过

- 新增 Float display-linear 导出路径：884,736 个 RGB 通道对 double 参考，最大绝对误差 2.9801849987798334e-8（阈值 1e-7）。灰阶扫描保留 4,096 / 4,096 / 4,070 个不同通道值，排除先降 8 位再扩展的实现。
- Float 导出 tile 一致、alpha=1、范围 [0,1]、非法参数检查通过；原核黄金测试重新执行仍为 0 差。
- 既有 HEIF 静态契约覆盖专用 HEIF10 writer、RGBAf/extendedLinearSRGB 输入、快照与无 8 位导出回退。分享新增按需 JPEG 不属于 HEIF 保存回退；新交付静态契约已纳入上述 43 项运行。静态测试不等于 Swift 编译或真实 HEIF 检验。
- 原始资产 SHA-256 对照 provenance.json 通过。
- 原始 Python 生产函数与独立参考实现：52 组黄金向量、6,656 像素，最大 UInt16 差 0。
- 标准 C++17 原核：同一 52 组/6,656 像素，最大 UInt16 差 0；覆盖 legacy/L* × standard/reproduction 四模式。
- 额外随机/负值/超白/量化边界/色温范围测试：892,080 个通道比较，最大 UInt16 差 0。
- 精确输入桥与显示输出对 Python：最大 8 位差 0；tile 切分不改变结果。
- 优化显示路径：2,700,027 个通道对精确输出，最大差 1/255；2,283 个通道发生变化（约 0.085%）。另以 2,196,606 个密集值/边界样本验证输出编码表，最大差 1。
- 1/2/3/4 工作线程的优化输出逐字节相同。
- C ABI 非有限值、空指针、零长度、过大长度、非法设置/线程数检查通过。
- ASan + UBSan C ABI smoke 测试通过。LeakSanitizer 因容器 ptrace 限制不能运行，已明确关闭；不宣称泄漏检查通过。
- Xcode 工程文件引用、scheme XML 静态检查通过；不是 Apple 编译。
- 诊断渐变/色块图跑通输入→HNCS→PNG，并人工查看生成图。它不是实拍照片，也不用于证明肤色/审美或设备匹配。

## 历史预览基准与已实现优化

新增精确 Float 导出核与分段测量见 [当前颜色性能报告](COLOR_PERFORMANCE.md)。下面保留旧同轮基准用于解释优化来源，不以新旧不同负载互算加速比。

环境：Linux x86_64，Intel Xeon Platinum 8370C，g++ 14.2，`-O3 -fno-fast-math -ffp-contract=off -pthread`。以下为同一输入、同一次对比测试的中位耗时，预热后各 3 次。共享云 CPU 的短测会有噪声，不能当作稳定硬件极限。

| 尺寸 | 精确单线程 | 编码表单线程 | 编码表 2 线程 | 编码表 4 线程 | 4 线程加速比 |
|---|---:|---:|---:|---:|---:|
| 1024×1024 | 466.8 ms | 305.9 ms | 220.0 ms | 145.8 ms | 3.20× |
| 2048×1536 | 1308.8 ms | 968.1 ms | 750.2 ms | 400.4 ms | 3.27× |
| 4000×3000 | 5151.7 ms | 4105.6 ms | 2042.4 ms | 1139.0 ms | 4.52× |

计时包括源域桥、HNCS 与显示编码；**不包括解码、缩放、Swift 缓冲区、图像文件编码（当时为 PNG，当前为 HEIF）、界面与上下文初始化**。12MP 是独立 C++ 预览 benchmark；当前全源导出源码已不受 2048px 预览上限限制，但尚无 Apple 端到端导出测量。这不是 iPhone 测量，不能推算手机帧率。

本轮可归因优化：

1. 参数上下文预计算插值矩阵与 2D LUT，融合逐像素运算，避免全帧 double 中间图。
2. 原始 ICC 解码表按全部 65,536 个输入码精确预计算。
3. 精确输出路径保留。另加显式 fast API，只把最终 linear-sRGB→8bit OETF 的三个逐像素 pow 换成 65,536 项查表；该单项优化实测约 1.25–1.53×。
4. 加入最多 4 线程的连续块并行，原核不改，线程创建失败时安全串行补齐。
5. 当时 Swift 预览使用 fast 路径并按低电量/系统热状态将工作线程降至 2 或 1；当前 App 预览与导出已切至精确 Float 路径，继续采用有界工作线程策略；该 Apple 策略尚未真机测量，不能声称节电效果。

显示近似的边界：最近 16 位 linear 采样误差 ≤0.5/65535；sRGB 最大斜率约 12.92，连续字节尺度误差约 ≤0.0252，因此量化输出最多差 1 码。原始 HNCS UInt16 核仍需 bit-exact。精确 API 与 Swift `exactReference` 选项保留，便于比较或重新导出。该有界近似仅保留在旧8位诊断/预览API；当前App已改用精确Float高精度效果显示。HEIF 导出走独立 Float display-linear 路径，不通过 fast 字节编码；实际 HEIF10 编码器仍未在此环境执行，不能把已通过的 Float 测试称为已验证的 HEIF bitstream。当前 HNCS Float 导出已新增 1–4 线程精确并行，336 组对串行 oracle 逐位一致；真实8064×64条带及12MP计时见 [精确 Float 并行](EXACT_FLOAT_PARALLEL.md)。前表的旧8位预览速度仍不适用于端到端 HEIF 导出。

## 云端阶段未执行（历史记录）

- Xcode/Swift/Apple SDK 编译、模拟器或 iPhone 安装。
- 实际 JPEG/HEIC/DNG/Apple ProRAW 导入、portrait 方向与 Core Image bitmap 行方向一致性。
- Apple HEIF10 编码实际执行、输出 HEVC/HEIF 位深与 SDR/sRGB 标签、无 HDR gain map 验证。
- 原生分享 sheet、微信/接收端可查看性、文件重开检查、Liquid Glass 真机外观。HEIC-first/按需 JPEG 兼容转码已实现源码，但接收方类型选择与兼容性未验证。
- 手机峰值内存、后台恢复、低电量与热稳态、持续运行 p50/p95、功耗。
- 完整 HNCS 旧 pipeline 的 RAW 解码、双光源拟合和全部空间阶段；FFCS 则已另行验证所移植的颜色、颗粒与锐化阶段，仍不等于完整相机 pipeline。
- FFCS Apple 平台运行、实时拍摄、48MP/高位深全尺寸导出、RAW+配方管理。
- 真实照片的审美验收和 iPhone→Hasselblad 匹配；没有新标定，也没有把合成图当作实拍证据。

## 复现与证据

- `python -m unittest discover -s tests -v`
- `python tools/verify_cpp.py`
- `python tools/benchmark_optimized.py`
- `python tools/verify_linear_export.py`
- `validation/linear-export.json`：Float 导出精度与未执行的 Apple/微信验证边界。
- `validation/cpp-verification.json`：精确基线与运行环境。
- `validation/optimization.json`：最终优化准确性、各路径耗时及输出摘要。
- `validation/sanitizer-tests.txt`：检测结果与 LSan 限制。
- `ios/README.md`：Apple 环境逐项验收清单。

“极限优化”是持续目标，不是这次已经完成的标签。下一轮优先验证 Apple 编译与真实输入，再测 decode、核心、encode、内存峰值分段成本；根据瓶颈选择 SIMD/Metal，不盲目把小矩阵搬到 ANE。

## FFCS 0.1 历史独立验证

详见 [FFCS 实现和性能边界](FFCS.md)：原始 9 测试、14 案例/153 阶段；19 种移植模式/513 阶段图最大误差 2.51e-14；1,368 个分块组合逐值一致。三行缓冲明显降低暂存内存，但云端线程计时不稳定，不承诺加速。App 暂用单线程，保留 1–4 核心接口。

早期 13 项测试的记录已由后续 43 项合并运行替代，不能作为当前总数。此云环境未安装 CMake，CMake configure/build/ctest 未执行；g++ 数值/回归构建已执行。


## 当前原生拍摄 / 全源导出证据

[拍摄/导出阶段记录](../validation/final-source-tests.txt)：43 项合并 Python/source-contract 测试通过（其中 Apple 代码仅静态契约，非编译）。新增 FFCS strip 数值回归：399 全图、6,326 分块、653,904 像素与完整路线逐值一致；21 个非法调用无输出修改。项目新 Swift 文件引用/标识符检查通过。完整原始源临时保留、64 行输出块、FFCS halo/global grain、磁盘 RGBAf、颜色后 Lanczos 与十位写入已实现源码。

这些新增源码未在 Apple 平台编译运行；相机硬件、双路预览与单摄48MP捕获切换、实际条带行方向、HEIF 位流、磁盘/RSS/热状态、微信仍须设备测试。2048px 只限制默认导入预览，不限制全源输出。性能表仍是旧 HNCS 预览基准，不适用于完整新拍摄/导出链。

FFCS strip ASan+UBSan：19模式/760调用通过，见 `validation/ffcs_strip_sanitizer.txt`；LSan关闭。新增 `tests/apple_ci_strip_roundtrip.swift` 为未执行的 Apple 行方向诊断。


## 新交付与生命周期：源码已实现，运行待验收

- Photos add-only 原始 HEIF 保存、Files 原始 HEIF 复制；普通分享排除 Save to Camera Roll。
- 一个 NSItemProvider 的 HEIC-first / lazy JPEG file/data 表示。JPEG 仅从最终 HEIF 生成，不经预览；真正接收方选择、回调取消、sheet/file 生命周期尚待 Apple 实测。
- 保留导出 worker，显式 NSLock 取消 token 跨 decodeQueue 传递，条带与 codec 边界取消，不可中断调用结束前保持 busy。Photos 提交后不可取消。
- 导入效果失败保留 decoded source 可 Retry；未渲染配方禁止 Save/share；相机取消/失败解除 pending capture。
- 近似 FOV 外围映射、真实宽镜头覆盖门控、独立缩放的中心/外围视频输出不构成光学对齐或任意设备组合可用的证明。

设备验收：见 [iOS 清单](../ios/README.md)。43 项合并通过仅覆盖报告列出的 portable/source-contract 范围，不意味着这些新增交互已在 Apple 运行时通过。

## 精确 Float 并行回归

52 组/6656 像素、额外892080通道原核仍为0差；336并行case逐位一致；ASan/UBSan通过。真实64行条带1→4线程104.9→54.3ms，12MP2.731→1.063s（同轮云CPU中位数，含启动/join，不含Apple解码编码）。总CPU时间增加，不宣称省电。详见 [实现与原始样本](EXACT_FLOAT_PARALLEL.md)。

## 高精度效果预览追加

Float32原图/效果图→CoreImage/Metal RGBA16Float SDR源码已加入；软件binary16灰阶4096样本保留3073级，线性及sRGB编码域误差低于声明样本预算。此检查不等于Apple编译、GPU或面板实测；详见 [高精度预览](HIGH_PRECISION_PREVIEW.md)。

高精度预览合并 [52项测试通过，20.372s](../validation/high-precision-integration-tests.txt)。其中九项新增为源码/软件存储检查，Apple显示未执行；当时完整实时HNCS/FFCS已后置；随后新增的仅色彩GPU实验路径见下节，不执行完整空间处理。

## 未来低分辨率色彩成本诊断

完整实时CPU处理已由用户后置，此项仅估计成本。45 配置、225 计时样本与45预热输出全部与串行 oracle 的 hash 一致；覆盖 HNCS、完整 PROVIA / ACROS、128×72 至1080p及1/2/4 workers。记录墙钟与进程 CPU 时间，不能将多线程墙钟直接换算成低功耗。具体样本、画质代价和限制见 [低分辨率报告](LOWRES_COLOR_PERFORMANCE.md)。这些是共享云 CPU 数据，不是 iPhone 帧率或整机占用。

## 实验性仅色彩GPU取景

默认关闭的65³整形cube接入源码与原始取景回退已实现。新增FFCS逐点API在19模式×13,229输入上对三种oracle逐位一致，304非法调用不写输出，原完整/分块回归继续通过（`validation/ffcs-color-only.json`）。HNCS默认6500K单独补测168,193holdout，ΔE76 max0.79777/p99 0.13801。仅放行EV0的HNCS5500/6500与FFCS PROVIA/ACROS；其他配方显示系统取景。

这不是Apple GPU执行结果。CIshaper/插值、实际位深/颜色附件、源新鲜度、窗口切换、GPU失败回退、帧率和功耗均需设备验收；见 [实现边界](LIVE_COLOR_PROXY.md)。

[最终合并运行](../validation/live-proxy-integration-tests.txt)：71项通过，其中18项新增实验取景源码契约；Apple运行时与编译仍未执行。源码审查同时修复了源帧过期、离窗调度、不可用drawable及旋转后旧GPU完成回调的回退问题。

## 2026-10-12：双路预览 / 单摄高分辨率捕获切换

MultiCam视频预览与普通.photo ProRAW图已分离；快门保留冻结图像并真正释放旧会话，再拍摄最高支持源并恢复预览。逐请求身份、同步取消令牌、终态照片成功保留、同镜头/FOV/方向/真实RAW尺寸验证、冻结渲染栅栏和显式关闭路径已纳入源码审查。最终99项测试通过（9.477秒），新增19项切换源码契约和9项状态规格测试。独立审查未发现剩余阻断项；源文件契约与状态模型测试记录见 `validation/capture-handoff-integration-tests.txt`。

状态模型遍历100,000条短事件序列，只验证独立可执行规格，不等同Swift/AVFoundation执行。Apple编译、双摄→单摄切换延迟、实际48MP及预览/成片构图依然未验证。见 [会话切换](CAPTURE_SESSION_HANDOFF.md)。

## 2026-10-12：方案A原生clear玻璃UI

参考布局已接入，中央按完整窗口最大aspect-fit，控件不再通过controlBand压缩成片框；clear玻璃与字形阴影限制在天然外围，紧凑窗口采用独立普通控制面板。真实网格/高精度缩略图/效果与设置入口保留，未加入B方案的边缘复制、拉伸、额外blur或seam shader。

几何测试含6060个随机比例案例、精确竖横/方窗、边界分区、极端/无效尺寸和控件区域契约；新增16项clear UI源码契约并重跑完整套件：122项通过（10.461秒），测试前后45个源码/规格文件hash一致。最终运行和源码hash见 `validation/clear-glass-integration-tests.txt`、`validation/clear-glass-source-hashes.json`。独立源码审查未发现阻断项，仍未执行Apple编译、原生玻璃渲染、参考图视觉一致性或真机成本测试。

## 2026-10-13：HNCS revision8预设同步

新增真实六张UInt16后曲线、film解析、完整目标WB的实验源桥、方形裁切和全图portable grain/USM。核心278,528有效native像素及20,134,896逐点通道均0差，旧52组黄金与默认5500/6500路径不变。空间324案例/114,980,382Float32通道逐位一致；RNG32,000,096double及cast一致。ASan/UBSan通过，LSan不可用。细目、环境版本与证据链接见[revision8](HNCS_REVISION8.md)。

最终整合183/183通过（9.688秒），包含原122项与新增61项；38个生产/构建/生成源文件测试前后hash一致。日志与快照见 `validation/hncs-revision8-integration-tests.txt`、`validation/hncs-revision8-source-hashes.json`。覆盖完整快门配方、迟到成功不抢占新导入/导出或关闭新相机、单槽临时保留与失败恢复。C++三编译单元联合smoke通过。此证据不代表Apple编译或硬件验收。

## 2026-10-13：独立锐化、颗粒与预设额外裁切

最终216/216通过（26.287秒），保留全部183个既有测试ID，新增33项；212个源码/资源/黄金文件测试前后SHA-256一致。证据：`validation/effect-toggles-regression.txt`、`validation/effect-toggles-regression-manifest.json`。覆盖八组合、多preset、旧HNCS/FFCS迁移、共享持久化、快门/待打开照片/导出快照、缓存、裁切开关几何与空间旁路。

实际C++ HNCS组合80案例UInt16精确、display Float最大误差2.9782e-8；FFCS19×4状态、1,140全图、13,224条带、380阶段案例逐位一致，修改前默认字节不变。ASan/UBSan通过，LSan受ptrace限制不可用。独立源码审查无阻断。详见[开关合同与证据](EFFECT_TOGGLES.md)。旧recipe迁移仍是便携模型/源码测试，Apple JSONDecoder/SwiftUI/设备尚未执行；HEIF未新增内嵌配方元数据。
