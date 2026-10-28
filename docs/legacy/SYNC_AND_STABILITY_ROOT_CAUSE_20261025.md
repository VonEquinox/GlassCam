# 中心／外围同步与玻璃波动：根因及修复 · 2026-10-25

后续更新：用户反馈该安装版仍不稳定、遮黑不够积极。2026-10-26 的 [积极遮黑与稳定恢复](OPAQUE_RESPONSE_20261026.md) 覆盖本文的玻璃时域控制和显示阈值；本文保留为当时的同步链及根因调查记录。

用户要求把中心和外围的时间差尽量减小，并从根本上解决同一场景微动时玻璃深浅跳变。继续遵守：外围不追加几何或颜色矫正；原始错位小可透明，严重错位应遮住；上下取较大遮罩共同变化。

## 已复现的两个独立问题

### 同步取流没有贯穿到同步显示

之前的 `AVCaptureDataOutputSynchronizer` 已把两路帧交给同一回调，但中心经过 `CameraFrameDelivery` 向独立的 `AVSampleBufferDisplayLayer` 立即提交；外围在另一个 `MTKView` 绘制，并且上传新帧后仍采样 `textures.completed`，等下一轮才显示这次上传。光有同步回调无法消除这个确定的一帧延迟，两个独立显示表面也不能保证一起呈现。

用户已有的 15:30:35 记录中，180 条外围提交状态的 `submittedDisplaySkew`（外围源 PTS 减中心最近一次提交 PTS）中位数为 **−23.478 ms**，范围 **−40.259 至 −6.674 ms**；原始同一配对自身约有 **−6.67 ms** 的镜头时间差。外围纹理年龄中位数约 **63.918 ms**。这些是提交／源帧记录，不是高速摄影测得的屏幕扫描或端到端延迟。

此外，原始中心回退层在主线程闭包等待期间保留最早一帧、丢弃更新的帧，也会在主线程繁忙时扩大年龄。

### 单帧不确定性被误当成大畸变或零误差

使用原始记录制作共同平移／旋转的受控图像序列，保持两路在固定视场下的相对映射，不改变真实双目位移。变动范围为 ±0.5／1 个分析像素、±0.15／0.3°。旧版在多个场景明显波动：

| 记录 | 旧版原始遮罩范围 | 根因 |
|---|---:|---|
| `1792731299962` | 0.009–0.667 | 宽而歧义的候选区间被当成实际位移；参与高分位数的纹理块集合改变。 |
| `1792731307591` | 0–0.915 | 少数强边／弱边像素跨门槛，最大距离成为整块玻璃的代表误差。 |
| `1792731320140` | 0.495–1 | 同样的歧义、最坏点及稀疏样本统计问题叠加。 |
| `1792731379724` | 0.460–1 | 歧义区间上界在小运动中出现／消失，直接进入显示控制。 |

具体错误包括：

1. `segmentSearchComplete` 加“存在有限上界”不代表唯一匹配。状态仍为 ambiguous 的宽区间，甚至包含零的区间，其最远端也会被当成真实错位。
2. 普通直线只能可靠测法向位移，但旧显示判断优先取完整二维区间，混入沿直线方向不可观测的变化。
3. 每块接缝用单个最大的强边距离；几颗噪声像素足以把这个最大值推远。固定 3 个像素的支持门槛也没有随原生分辨率缩放。
4. 用“被找到的纹理块”计算离散的 75% 分位数，丢掉平坦块。一个块进出集合就可能换成另一段很远的数值。
5. 只要块内出现一条不匹配细边，就把整个 16 分析像素的块都算作结构缺失；细边穿过块边界会成倍改变缺失比例。
6. 没有有效观测的结果也可能以普通判断身份提交，默认零误差重开玻璃。原来只给最终透明度加动画，不能纠正这些输入错误。

## 显示链修改

- `PeripheralLiveTextureStore` 从同一个不可变 `Pair` 上传中心、外围两个纹理；Core Image 和最终合成共用同一个 Metal 命令队列、同一个命令缓冲。
- 采样当前命令中的 `uploading`，无需等下一帧完成回调。GPU 保证前面的纹理生成先于后面的采样；没有 CPU 等 GPU 的阻塞等待。
- `pairedPreviewFragment` 将中心和外围写入同一个 drawable、同一次呈现。中心分支只读中心源；外围的遮罩、固定 FOV 采样都无法进入中心分支。旧 `glassFragment` 保留给外围验证／离线工具。
- 原始中心显示层保留在下面，服务单镜头、没有新鲜配对及拍照切图时的回退；正常双摄时由同一 Metal 表面同时覆盖两路。系统 Liquid Glass 依然只覆盖外围。
- 双摄下的实验颜色预览也在同一对源帧、同一命令中处理中心，不再由第三个独立取帧／呈现循环盖上旧中心画面。单镜头保留已有颜色路径。
- 新配对到达会合并唤醒绘制；主线程最多排一个唤醒，读取最新配对，不排积压的历史帧。连续刷新仍负责遮罩过渡与失效保护。GPU 同时只允许一个未完成命令；drawable 池设为 2。
- 取得 drawable 后再选择最新配对，避免等待显示缓冲时把预选帧放旧。原始回退层同样改为一个可替换的待显示样本。

## 传感器同步接口与保留的限制

Apple [MultiCam WWDC19](https://developer.apple.com/videos/play/wwdc2019/249/) 区分硬件同步的 constituent streams 和仅归并回调的 synchronizer。虚拟设备的子镜头可以共同控制读出、曝光等；应用仍应自己合成两路画面。公开 [子镜头端口 API](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/ports(for:sourcedevicetype:sourcedeviceposition:)) 明确支持把主摄／长焦的子端口分别连接到视频输出。

新版在原生焦段优先请求匹配的 Dual Wide／Dual／Triple 子镜头端口，在同一帧率先尝试该路径，再回退独立物理输入。查询格式、成本、子镜头身份、视场和实际缩放；不支持或构图发生变化就回退。保留 60 → 30 → 15 的优先级，不能为了“同步”先选 15 Hz 而放弃能运行的 60 Hz。数字变焦继续使用现有可独立控制视场的物理输入路径。高分辨率照片仍切单摄，再恢复双摄。

`captureMode=virtual-constituent-request` 表示请求了该接口，不声称本轮已经在手机测出零曝光偏差。保留原始两路 PTS 与 `cameraExposureSkew`，独立记录中心／外围源配对身份、共同呈现模式及应用附加帧差。不能把“同一回调”“GPU 完成”或“同一 drawable”冒充两块传感器所有行同时曝光。

## 测量及玻璃控制修改

- 只有明确的唯一二维匹配，或有界的法向匹配，才进入实际位移估计；不把宽歧义区间的最远端当作大畸变。
- 在可观测方向上取测量区间中点；原有完整区间仍保留在物理诊断里。
- 原生边缘距离增加受支持像素的 80% 分位数，用于抗少量极端像素；最大值继续记录用于排查。强边支持门槛随实际样本面积变化。
- 统计中保留已观测的平坦块，采用插值分位数；未知块保持未知。周期图案的原始可见接缝距离不再冒充唯一物理深度。
- 结构缺失按实际沿接缝延伸的范围计量，使用连续距离权重；不再因为一条细边碰到某块就把整块计坏。
- 对测量量本身做短历史中位数、时间滤波和一个分析像素的静区，再进入遮罩曲线。上下先合并较坏观测，再做时域处理，换边也不会中途变亮。
- 每边单独保存观测时间和可用覆盖。缺失观测不产生“零误差”；低覆盖不能仅凭匹配丢失就宣告原有坏接缝改善。保留启动、失效和持续严重错位保护。
- 去掉生产直接拼接不用的九个内部点完整搜索，避免为旧单应／颜色证书消耗分析期限。完整边界候选搜索仍保留，没有偷偷缩窄搜索范围来制造匹配成功。
- 原始及滤波后的每边误差、结构缺失比例、覆盖、原始判断时间和两路时间差一同记录，后续可以定位波动来自哪一层。

这里的覆盖和滤波是显示控制的经验量，没有把它们声称为标定过的概率，也没有新增雷达或显示几何矫正。

## 文档和社区调查

| 来源 | 对实现的约束／作用 |
|---|---|
| [Apple：Synchronizer 初始化规则](https://developer.apple.com/documentation/avfoundation/avcapturedataoutputsynchronizer/init(dataoutputs:)) | 第一输出决定回调时机，会等待其余输出；保留 PTS，不能把归并回调当最终显示同步。 |
| [Apple：Optimize the Core Image pipeline](https://developer.apple.com/videos/play/wwdc2020/10008/) | 混合 Core Image 与 Metal 时共用命令队列，复用 context，避免多余 GPU 同步。 |
| [Apple：MTLCommandQueue](https://developer.apple.com/documentation/metal/MTLCommandQueue) | 命令队列保证有序提交；GPU 依赖放入同一链，代替多等一帧。 |
| [Apple：CAMetalLayer](https://developer.apple.com/documentation/quartzcore/cametallayer) | drawable 数量是资源池设置，不能承诺仅改 double buffering 就消除扫描／垂直同步延迟。 |
| [开发者原帖：多 MTKView 多等一次 VSync](https://stackoverflow.com/questions/79566331/ios-metal-system-delayed-one-vsync-period-to-really-display-the-frame-on-the-scr) | 发帖者区分 GPU 完成与 drawable 实际呈现。它是开发者问题记录，不是 Apple 给出的已验证修复。本项目不照搬成确定规律。 |
| [另一位开发者的多会话同步观察](https://stackoverflow.com/questions/66953416/multiple-avcapturesession-on-macos-what-is-the-right-approach) | 独立表面／会话的画面可能错开；只作问题线索，API 行为仍以 Apple 文档和实际代码验证为准。 |
| [CVPR：Exploiting the Power of Stereo Confidences](https://openaccess.thecvf.com/content_cvpr_2013/html/Pfeiffer_Exploiting_the_Power_2013_CVPR_paper.html) | 单次硬切置信度会丢信息，不能把失配当改善。借用证据处理原则，没有宣称实现其贝叶斯模型。 |
| [WACV：Stereo Matching in Time](https://openaccess.thecvf.com/content/WACV2024/html/Cheng_Stereo_Matching_in_Time_100_FPS_Video_Stereo_Matching_for_WACV_2024_paper.html) | 相邻时刻的信息值得保留；本文采用轻量测量历史，没有引入其网络或冒称其性能。 |

## 验证证据和边界

`validation/sync-stability-20261025/` 保存旧／新原始输入扰动、逐帧玻璃轨迹、两批完整原始记录回放、原生 GPU／内存检查、构建和回归日志。`tools/replay_peripheral_stability.py` 可以在不接手机的情况下重跑导出 ZIP；`--sources` 可指定保留的旧源码快照。

原生检查增加独立的像素真值：2/192 的实际双目错位可透明，24/192 在默认容差下必须遮住；两个镜头的显示都不经过矫正。连续 8 对不断变化的源帧在同一 GPU 命令中上传并采样，验证没有读取上一帧；外围全黑时中心颜色仍与源纹理一致。原有 CI／Metal、身份隔离、旧回调、取景停止、容差、启动与已知近景反例继续检查。

受控共同运动是从已保存图像生成的测试，不是手机视频、光学校准或全场景正确率。两批历史场景没有人工标注的“应透明”真值，透明数量不能冒充准确率。本轮未启动手机相机；最终构建、安装状态与源文件指纹以 `verification.json` 为准，手机实际剩余曝光／屏幕延迟尚未重新测量。
