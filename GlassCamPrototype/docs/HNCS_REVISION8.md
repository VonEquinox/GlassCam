# HNCS render revision 8 同步

来源固定为用户技术交付分支提交 `34fa10f42bc32efea0ca5559f006ebe9a8bf6489`。colour path revision 仍为 2，render path 从 6 升至 8。本页记录当前同步的实现合同和验收边界；测试完成记录在末节补充。

## 参考不变与新增阶段

七个基础颜色/显示函数与旧版本 AST 相同，原始颜色 NPZ、ICC 和黄金向量继续保留。旧报告属于当时基线，不改写为新预设已通过的证据。

新预设使用原始六张 UInt16×65536 后曲线表，不能用手画 Nature 曲线替代。严格顺序是：输入源域桥与曝光 → HNCS 工作码（所选 film curve）→ 饱和度与相应 UInt16 量化 → RGB 后曲线 → contrast 表与 RecoverHue → 可选 luma/Points → 灰度 → portable 颗粒 → 可选 Gaussian USM → 最终 UInt16 工作码 → 原始显示变换。

参考中的 Float32、Double、截断和 ties-to-even 边界各自保留，不能为“更高精度”全部改成 double 后声称等价。关闭 preset tone curve 只跳过 Points，不跳过 Gamma/contrast；XML EV=1 是倍率1，即额外0EV。film curve 的 As Shot 是选择哨兵，必须有明确的 RAW/default 解析值，不能把名字当独立新算法。

## 白平衡：两个不同合同

原生参考的 capture WB 先决定传感器响应/光源插值，再以完整 configured X2D 目标增益替换目标 WB。固定 WB 预设不能仅改变工厂 CCT，也不能仅套 tint multiplier。显式工厂 CCT 只选择原厂核表。

2026-10-15：App 的 Apple RAW 入口自动读取 `CIRAWFilter` 的 as-shot 色温、Tint 和 xy 白点。Apple 负责源图白平衡；完整 xy 经虚拟 X2D 响应逆变换得到捕获基线，白平衡预设再替换目标增益。默认不再依赖手动捕获 CCT。数学、来源和验证见 [自动白平衡](AUTOMATIC_WHITE_BALANCE.md)。

原 `hncs_create_preset` 的 CCT/显式增益合同保持原数值，供旧参考测试调用；App 使用新增的 `hncs_create_preset_whitepoint`。二者属于不同源域适配合同，均不证明 iPhone→X2D 的实测传感器标定。

## 方形裁切与配方

Square Crop 对实际源尺寸取居中 min(width,height) 正方形；奇数剩余边允许一像素不对称，不能照搬 XML 中针对另一比例的 .125/.875。完整源先裁切，再决定实际输出尺寸；原图/效果比较用同一裁切。相机中央成片边界须与方形输出对应，不能通过拉伸或玻璃遮盖模拟。

43个原始XML payload及已知别名均保留在后端catalog；UI展示29个有实际效果的预设（含Standard），不把原参考的无效果工具项伪装成处理模式。C ABI接受canonical/已列别名，并只剥离空格、tab、CR/LF；不会完整复刻Python对所有Unicode空白的str.strip。

预设、film curve、tone 开关、每张源图的完整白点、工厂 CCT/目标 WB、空间阶段设置均属于不可变处理配方。预览、导出和缓存不得分别读取不断变化的 UI 值。HNCS 的自动白点不继承旧65³代理误差预算，因此使用系统取景；已验证的 FFCS 实验代理继续保留。独立颗粒/锐化/预设裁切开关不向cube加入空间处理，完整身份仍进入缓存；见[三个开关](EFFECT_TOGGLES.md)。

## 空间阶段边界

交付源本身把 grain 和可选 USM 标为 portable 模型，不是恢复出的原生 Phocus 空间核。八个有效 grain 预设使用按 preset key 与全图 shape 生成的 NumPy PCG64 正态流、wrap 高斯和平面全图 Float32 方差。不能把它替换为坐标 hash 后叫参考一致；条带导出也不能对每条带各自归一化。

USM 是参考可选的 nearest Gaussian unsharp，保留 amount/radius/noise threshold，不等于专有多遍 CSharpnessFilter。全图阶段使用独立暂存和多遍处理，保持逐点实时LUT与最终照片空间阶段隔离。Swift输出临时RGB Float32为12B/像素，C++最大额外scratch16B/像素、固定处理RAM小于4MiB（不含调用方/系统解码与文件缓存）。之后仍有16B/像素RGBAf输出；48MP空间导出因此需数GB可用临时空间，不能沿用单RGBAf文件的总磁盘估算。

预览使用较小图像，其grain seed包含不同shape且全局统计不同，因此预览颗粒图样可能与完整源导出不同；配方仍相同，导出不复用缩小预览。

空间数值计算为C++17；当前文件后端采用Apple/Linux均支持的POSIX文件API，PCG64使用Clang/GCC的128位整数扩展。不能把现有CMake中的MSVC分支当作Windows已验证支持。保留所适配NumPy/SciPy随机/归约算法相关许可与来源。

## 已执行的数值验证

- 六张曲线与原生向量：278,528个有效native像素，UInt16最大差0；identity/no-tone按源代码绕过，不把无条件native探针额外舍入当正确输出。
- 43个payload/56个原始名称的逐点预设：20,134,896通道比较，最大差0；120个film解析案例与86个native+预设案例通过。
- 原52组/6656像素黄金、892,080额外通道继续0差；默认旧/新54组字节/Float路径逐位一致，包含5500/6500K。原65³代理默认输入没有改变，新增配方仍不放行。另以5500/6500K各自全部274,625个整形cube节点与200,003个独立随机/负值/超白输入比较旧/新构造器，总949,256像素逐位相同，见[节点身份回归](../validation/hncs_revision8_live_identity.json)。
- 260个desired/baseline矩阵案例验证实验桥数学，不能用作Apple传感器标定证据。
- portable空间：324案例、114,980,382 Float32通道逐位一致，其中241个文件路径案例；包括4097×4097和3073×4097全图统计。完整工作码→空间→finish分段接口及行序模型分别验证。
- RNG：10,032个SeedSequence种子、32,000,096个double正态值及对应Float32 cast逐位一致。
- ASan/UBSan通过；此环境ptrace限制使LeakSanitizer不可用，不声称泄漏检查通过。

证据：[核心](../validation/hncs_revision8.json)、[空间](../validation/hncs_spatial_revision8/spatial_parity.json)、[随机流](../validation/hncs_spatial_revision8/numpy_rng_parity.json)、[空间sanitizer](../validation/hncs_spatial_revision8/sanitizers.json)。报告记录实际源码/参考/生成器/编译器身份；此轮NumPy2.3.5、SciPy1.17.0、GCC14 strict-FP，与上游锁定的NumPy2.5.3/SciPy1.18.1不同，未自动升级依赖。逐位一致结论只覆盖实际所测环境/样本。

## 空间阶段成本样本

1024×1024独立空间阶段单次样本：Artistic颗粒RAM输入0.304s/文件输入0.308s；Fine Texture 0.091/0.085s；High USM 0.082/0.100s。文件在tmpfs，不能当iPhone存储性能或真实SSD测量；均不含HNCS核、Apple解码/编码、缩放和显示。RAM输入模式只指调用方工作RGB在内存，内部Gaussian scratch仍使用文件。没有preset同时启用颗粒和USM量，不能把两种独立成本叫混合效果实测。

## 集成验收边界

上游云端阶段的Swift配方、裁切、文件行序、取消、迟到拍摄恢复及项目注册检查为183/183通过，保留当时的38个源文件摘要。2026-10-13本机Apple回归纠正了此前模型中的位图行序假设：解码数组、工作文件及原生空间阶段统一从上到下，只有CI矩形坐标需要换算。实际Foundation文件、颗粒/锐化、方裁切及HEIF分块回归已通过，Xcode模拟器Debug/Release也已构建；详见[测试状态](TEST_STATUS.md)。真机显示/构图、独立HEIF位流检查与手机性能仍待验收。
