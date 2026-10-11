# FFCS：真实参考移植与当前边界

更新：2026-10-11。

## 来源与范围

原始交付已重新核实为普通 Git ZIP，不再是 LFS 指针。来源、ZIP 和逐文件摘要见 [ORIGIN](../reference_ffcs/ORIGIN.md)。完整 92 文件、48 张 LUT、2 份 ICC 的原始字节保存在 `reference_ffcs/source.zip`。原始 Python、说明和基准另保留为可读文件；不修改原始研究分支。

当前 iOS 选择器提供独立的 HNCS / FFCS 引擎。FFCS 使用交付中真实的 19 款 XH2S 参考 LUT；没有对应资产的 REALA ACE 不展示。其余相机配置和分析模型保存在研究交付中，尚未成为手机模式。XH2S 资产名称表示参考模型来源，不表示 iPhone 已变成 XH2S 原生输入，也不是物理相机匹配证明。

## 数学与域

Apple 解码输出的 Float linear-sRGB 显式进入 FFCS 的 linear 输入分支，不串接 HNCS。C++17 保留参考顺序：输入归一化、gamma_pre、3×3 矩阵、原始 80³ 三线性 LUT、Lab/UCS、tone、坐标确定性 grain、邻域 sharpen、输出颜色域。矩阵截断、LUT 轴/通道顺序、灰度模式、边界邻域、种子和全图坐标均属于可测试行为。即使默认 UCS 参数中性，也保留原参考往返数学。

移动预览输出 8 位 sRGB；导出取独立 Float display-linear RGB，再添加不透明 alpha，交由共享 RGBAf/extendedLinearSRGB → HEIF10 SDR sRGB 写入器。没有先做 UInt8 再扩展的导出路径。预览与导出使用同一不可变引擎/模式/曝光/种子快照。CCT 仅用于 HNCS。

## 离线资产准备

Xcode 首个构建阶段运行 `tools/prepare_ffcs_resources.sh`，核对 ZIP SHA-256 后提取 19 个原始资源，并逐个核对 SHA-256。不联网、不安装包、不执行 ZIP 内代码；失败则构建失败，不切换近似 LUT。重复构建验证缓存摘要。

完整 Python 参考复现先运行：

```sh
python tools/materialize_ffcs_reference.py
python -m unittest discover -s tests -v
python tools/verify_ffcs.py --help
python tools/benchmark_ffcs.py --help
```

Git 复用研究分支已经存在的 ZIP blob；没有再上传一份不同内容的资源，也没有将所有 LUT 再重复展开到 Git。

## 已执行结果

- 原始 9 项测试、14 个案例/153 个阶段图复现通过；原始阶段最大误差 8.606e-15。
- 19 款移动模式、513 个 C++ 阶段图对 Python double 最大误差 2.5102142576186878e-14，阈值 1e-12。
- 57 组 Float32 输入/曝光案例及预览字节通过。
- 分块优化的 456 个双输出、912 个单输出组合跨 19 款/6 尺寸/1–4 线程与基线逐值一致；非法参数拒绝测试通过。
- ASan + UBSan smoke 通过：19 款、190 个小图/线程组合；LSan 因容器限制关闭。证据 `validation/ffcs_sanitizer.txt`。CMake 未安装，直接 g++ 构建执行；CTest 配置尚未执行。
- 原始双全帧 double 暂存被每线程三行环形缓冲替代。3MP 暂存从 144MiB 降为单线程 144KiB、四线程 576KiB，不含 LUT、输入、输出及 Apple 缓冲。全局坐标和一行 halo 保持 grain/sharpen 结果。

计时见 `validation/ffcs_optimization.json`。共享云 CPU 波动明显：3MP 四线程一次中位 3.42s 对基线 6.06s，但 1MP 四线程更慢，不能据此认定稳定加速。App 默认单线程；核心保留 1–4 工作线程以便真机调优。上下文按模式缓存，预览不申请未使用的 Float 输出，导出不申请预览字节。

独立 cube-multiply 候选通过已有样本及额外 242,079 像素，但计时没有稳定收益，因此未合入；记录 `validation/ffcs_cube_candidate.json` 是被否决实验，不代表当前代码使用它。没有启用 fast-math。

## 未验证

Apple 编译、实际照片审美、ProRAW、HEIF bitstream、微信兼容、手机性能/内存/热稳定仍未执行。黄金测试验证恢复的研究算法，不验证真实 Fujifilm 相机等价性。导入效果预览默认最长边 2048px；全源导出与原生相机源码已在后续阶段加入，见 [全源导出](FULL_RESOLUTION_EXPORT.md) 和 [相机能力](camera-capture.md)，仍须 Apple 环境验证。
