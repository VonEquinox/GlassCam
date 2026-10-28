# 按钮记录原始双摄输入与玻璃状态 · 2026-10-23

用户反馈研究方案安装后仍然无效，要求能逐次记录透明／变黑状态，并保留原始数据传到这台 Mac。新增功能用于取得真实失败证据；它不更改玻璃透明判断，也不宣称已修复视觉问题。

## 手机使用

取景框下缘新增“记录状态”按钮和文件夹按钮。每按一次“记录状态”，立即固定当时可用的帧和状态，在后台写入；保存过程中暂时禁用按钮，成功显示勾号，文件夹角标显示已保存数量。即便相机未启动、会话停止或没有对齐结果，也可以记录。

透明、黑色、轻微移动后突然变化时各记录几次即可。按文件夹→“导出全部记录”，会生成不转码图像的 ZIP，通过系统分享菜单隔空投送到 Mac。也可以从 iPhone“文件”→“我的 iPhone”→GlassCam→GlassCamStateRecords，或 Mac 访达的 iPhone 文件共享中复制原始文件夹。导出不删除手机原件。

## 数据契约

- 原始数据是相机已经输出的、未进一步缩放／配准／有损编码的 `CVPixelBuffer`，不是 Bayer／ProRAW。逐平面保存原始字节，保留每行跨度和原始像素格式，包括 10 位双平面 YUV；提供尺寸、平面尺寸、字节序、颜色附件和可序列化附件的二进制 plist。
- 分别标记按下时最新的双路帧、渲染时考虑的双路帧、实际纹理来源、最后完成分析的双路帧。相同帧去重，不同来源即便 epoch／serial 相同也通过原始 receipt 的位模式区分。没有配成对时，另存每路仍缓冲的最新原始输入。
- 保存双路 PTS、主机时钟映射、帧编号、epoch、帧间隔、K、工厂 R／t、输出角度、视场比例、运动估计和源配置。缺失值明确标记；NaN／Infinity 保存为字符串，防止 JSON 写入失败后却显示“已保存”。
- 保存匹配器实际使用的缩小参考 RGBA 和选中候选的配准 halo RGBA，完整的分段状态、区间、法向、梯度特征值、最佳位移、前后向检查、噪声 MAD、搜索次数、候选矩阵／覆盖余量、Vision 错误、几何／颜色认证、发布／拒绝原因和分析耗时。无选中候选时没有虚构配准图；原始双路图仍保留供重新计算。
- 保存最终提交到 Metal 的黑色覆盖率、策略值、目标值、锁黑状态、认证截止时间、全部渲染拦截原因、有效纹理的帧／几何／颜色身份和年龄、实际矩阵和增益、提交显示时差、相机界面状态、变焦及工作流状态。
- 附最多 180 次渲染状态和 90 次 GPU 完成／外围 drawable 呈现事件，便于检查按钮之前的变化。它们不是完整的视频录制。原始图像仅保存上述明确选定的帧，不持续录制全分辨率视频。
- 所有原始平面和派生分析文件附字节数和 SHA-256。临时目录全部写完后才原子改名为完成记录；写失败会报告错误。应用重启后仍能发现原记录。

`effectiveBlackOpacity` 代表向外围 Metal 层提交的值，不能直接证明系统 Liquid Glass 最终合成像素。呈现事件是外围 drawable 的身份和时间，也不冒充中央预览实际呈现身份。电脑报告明确提示渲染状态是否陈旧。

## 资源与保存

平时只保留有限的内存状态和已有分析字节，不额外运行全尺寸图像转换、匹配或磁盘写入。按下时持有原始缓冲区，在专门的后台队列逐平面复制、散列和写入。保存／导出串行，ZIP 使用分块读写和原样存储，不有损重编码。

记录保存在 `Documents/GlassCamStateRecords/record-…/`，总保存预算为 512 MiB，单次估算上限 256 MiB。达到预算停止接受新记录并明确提示，已有记录不会自动被覆盖或清除。导出成功、确认 Mac 原始文件完整后，可以用“文件”手动整理旧记录。

## 这台 Mac 的复制和分析

连接手机后运行：

```sh
python3 GlassCamPrototype/tools/pull_peripheral_records.py --device 00008160-001E02E111680036
```

它只复制应用文稿下的记录，不启动相机、不按快门、不删除手机数据。每次复制到新的时间目录，默认在 `~/Library/Developer/GlassCamDiagnostics/manual-records/`。随后逐个验证原始文件并生成 `analysis/analysis.json`、`analysis/analysis.md` 和独立的分析图 PNG。

收到隔空投送的 ZIP，也可直接分析而不修改 ZIP：

```sh
python3 GlassCamPrototype/tools/analyze_peripheral_records.py /absolute/path/GlassCam-records-example.zip --output /absolute/path/analysis
```

报告列出当次提交透明度、原始文件完整性、策略原因、渲染拒绝条件、分析是否超期未发布、分段匹配状态、最近策略变化及帧的角色。这个汇总是定位入口，复杂的场景原因仍需结合保留的原始图像做复现，不能仅从原因字符串推断根因。

## 验证

- `tools/test_peripheral_recording.py`：生产保存代码中的 BGRA／10 位 YUV 各平面及行尾字节逐字节一致，K／PTS 保留，空相机与未配对原始输入，真实 worker 拒绝结果，非有限 JSON，失败／空间上限清理，重启发现记录及 ZIP 导出。
- 同一测试中的电脑工具检查：ZIP CRC、逐文件 SHA-256、目录与 ZIP 分析结果一致、派生预览生成、损坏输入拒绝。
- `tools/test_peripheral_glass.py`：生产策略、双路配对、Vision／CI、匹配器、原有有界诊断和实际 Metal 着色器检查通过。Mac 实际时钟热启动分析约 15.6 ms，仅是 Mac 离线结果。
- 36 项相机源码契约通过。新增 iOS 模拟器界面检查 1 项通过（109.857 秒）：中文按钮、连续两次保存、记录列表和重启保留。未运行拍照测试。

Apple 原始平面访问与文稿共享依据：[CoreVideo plane API](https://developer.apple.com/documentation/corevideo/cvpixelbuffergetbaseaddressofplane(_:_:))、[Apple 文稿共享设置](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html)。

签名 Release 已覆盖安装到用户连接的 iPhone，devicectl 确认成功，最终安装包的文稿共享开关复核为 true；未启动手机应用或读取手机画面。结构化证据见 `validation/manual-state-recording-20261023/`。

## 2026-10-23：容差校准与空间修正字段

“记录状态”上方新增实时容差滑条（0.25–4.00，默认 1.00，步长 0.05）。原始相机数据继续保存；`camera.tolerance` 为按下时选择，`analysis.tolerance` 为分析实际设置，`renderer.tolerance` 为提交时设置，`renderer.textureTolerance` 为当前纹理实际采用的设置，`renderer.alignment.tolerance` 为最新结果设置。调节瞬间这些值可能不同，不能默认把按下时设置套到旧分析或旧纹理上。电脑分析同时列出这些字段。

分析存在空间修正候选时，附 `dense-refinement.rgba32f` 原始浮点字段和 SHA-256、宽高、坐标域、矩阵、算法、各候选分数、源帧身份；外围分边质量／就绪／实际遮罩也各自保存。具体实现和静态验证限制见 `GRAYSCALE_TOLERANCE_20261023.md`。
