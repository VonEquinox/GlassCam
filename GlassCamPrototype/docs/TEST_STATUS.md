# 测试与性能状态

## 2026-10-28 · 完整色彩链复查收尾

补齐 HDR 曝光顺序、冻结白平衡与 RAW 解码一致性、带 Apple 锐化的分条解码稳定性。21 组曝光对照误差为 0；15 组历史 golden、12 组整图／分条／空间效果及三摄 × 三引擎的 9 组保留 ProRAW 检查通过，后者的直接／重放 HEIF 逐字节一致。223 项 Python 回归全部通过。详见[复查记录与重构回归底线](COLOR_CHAIN_AUDIT_20261028.md)。

## 2026-10-28 · 实拍反差与 LUMIX 通道回绕

Quality ProRAW 的三个引擎统一采用 camera-neutral 输入，关闭 Apple 全局色调曲线并保留源曝光与局部明暗调整；LUMIX revision 4 使用独立有界浮点路径。新增 6 项数值回归、冻结原程序 56 组共 5,506,816 个 RGB48 样本、生产 LUMIX／Apple 图像恢复检查、三种引擎真实 5416×7222 ProRAW 的直接／预览后导出一致性均通过。签名 Release、33 个 LUMIX 数据文件校验通过，修复版已覆盖安装到 iPhone。

Python 全套 223 项中 212 通过，11 项旧源码断言失败；在移除本次修改的独立副本中运行相关 85 项，失败集合完全相同。详细证据、输入策略和旧配方兼容说明见[本轮修复](COLOR_INPUT_REPAIR_20261028.md)。本轮未完成真机新拍摄的视觉验收。

## 2026-10-26 · ProRAW 优先级与 Speed 12MP

新增 Speed／Balanced／Quality 按钮及持久化。Speed 明确请求 12MP ProRAW 并保存 12MP HEIF；Balanced／Quality 保留原有 24／48MP 输出偏好。拍摄优先级冻结到可恢复快照，旧记录默认 Quality。Speed 只等待输出自身就绪，跳过现有高分辨率拍摄的额外两秒稳定等待。

217 项 Python 回归通过（79.716 秒）；生产 Swift 工作流中的源尺寸选择、12MP 输出、偏好恢复、快照及旧记录兼容检查通过。模拟器界面测试通过三档选择、Speed 12MP 显示和重启记忆。签名 Release、资源校验、设备覆盖安装成功，未启动手机应用或触发真实拍照。

完整 Apple 图像套件仍有既有的旧 Nature 恢复用例失败，其余图像及新工作流检查通过；该既有失败已记录于下方 2026-10-20 条目。未证明真机三档的实际拍摄尺寸、画质和端到端时延。见 [实现与验证](CAPTURE_PRIORITY_20261026.md)及 `validation/capture-priority-20261026/verification.json`。

## 2026-10-26 · LUMIX ProRAW revision 2

参考 HNCS／FFCS 的处理快照、资源准备和完整源图导出路径，补齐 S1M2 SDR 3D-LUT VE 分支。56 组共 **5,506,816 个 RGB48 原程序像素逐值一致、最大误差 0**，包括双表色温混合、低 ISO、Y/C、黑白有符号色度、对比度和取整；原始 Set3DLUT 的三组全部网格节点及低 ISO 寄存器也逐值一致。并发条带、非法设置、缺失／损坏寄存器拒绝检查通过。217 项 Python 回归通过，生产 Swift 16 种风格、HDR HEIF、旧配方和 HNCS／FFCS 兼容检查通过。

既有 ISO 400 ProRAW 使用 scene-linear 输入成功导出 **5416×7222** 的完整解码尺寸 HEIF，源 ISO、白点和配方保持一致。普通签名 Release、严格签名验证与包内 33 个 LUMIX 数据文件哈希检查通过，并已覆盖安装到连接的 iPhone。首次安装遇到 CoreDevice 连接中断，重试成功；没有启动应用或触发快门。

已完成的是原生 SDR VE 色彩分支，输入解码及细节处理仍由 Apple ProRAW 提供；尚未复刻松下传感器专用去马赛克、降噪和 SmartSharp3，不能宣称全部 RAW 管线或跨相机成片等价。说明与证据见 [LUMIX ProRAW](LUMIX_PRORAW_20261026.md)及 `validation/lumix-full-proraw-20261026/verification.json`。

## 2026-10-26 · LUMIX 色彩接入

新增 LUMIX 独立后端及 16 个 S1M2 原始 SDR Photo Style。196,864 组原程序 RGB12 样本逐值一致；Float32 适配、并发条带、损坏资源拒绝、生产 Swift 全部风格预览、10-bit HDR HEIF、配方冻结与设置恢复、旧引擎兼容及 217 项 Python 回归通过。iOS Release 已构建，未安装或启动手机。范围限定为原始 LUT 对 iPhone 输入的适配，未宣称完整 RW2／机内色彩等价。

详见 [LUMIX 接入与边界](LUMIX_COLOR_20261026.md)；完整证据见 `validation/lumix-integration-20261026/verification.json`。

2026-10-23 真机反馈：用户安装本轮修复版后反馈“还是完全不能用”。按请求清空手机上的 12 条旧场景记录，独立目录回读确认已无记录；电脑原始 ZIP 和分析证据保留，等待用户重新采集。离线通过不能替代此次真机失败反馈，见 `validation/field-repair-20261023/phone-feedback-and-record-reset.json`。

2026-10-23 最新：根据用户提供的两份故障分析，修复证据接纳、首纹理准备和恢复计时的互相阻塞；新增独立的原生尺寸可见接缝检查、每边颜色模型及不可变 GPU 显示组合。217 项回归、生产 Swift／Metal、AddressSanitizer、原始数据保存／导出及签名 Release 检查通过。16 个预定可见正例全部通过，160 个零相对位移反例没有误报大位移；但 12 组实拍的两种重放仍只有第 10 组完全透明，其他 11 组仍被边界检查拒绝，不能称为全部修好。本轮没有连接或安装手机，也未证明连续实拍稳定性。见[实现与限制](FIELD_REPAIR_IMPLEMENTATION_20261023.md)及 `validation/field-repair-20261023/`。

2026-10-23：应用户要求新增原始双摄帧“记录状态”按钮和 ZIP 导出，生产保存／电脑校验、玻璃组件、36 项相机源码检查及 1 项模拟器界面检查通过，签名 Release 已覆盖安装。未启动手机应用；真实场景记录由用户采集。见[记录说明](MANUAL_STATE_RECORDING_20261023.md)及 `validation/manual-state-recording-20261023/`。此前双摄研究方案与限制见[实施记录](PERIPHERAL_RESEARCH_IMPLEMENTATION_20261023.md)；记录功能不代表已经解决真机场景的透明问题。

2026-10-23 后续：用户提供 12 个真实场景记录，原始数据校验通过，生产匹配器重放复现全部逐段状态。2160 个历史渲染样本全部为黑，可靠证据和有效纹理上传均为 0；此前的离线通过不能证明真实场景能恢复透明。根因与逐场景证据见[12 场景诊断](USER_SCENE_DIAGNOSIS_20261023.md)。

## 2026-10-22：轻微转动的相关峰误判，最新版本仅离线构建

- 用户反馈此前安装版本仍不稳定，随后禁止手机调试；此后没有再访问手机。新增零位移夹具证明，对齐后的同一纹理共同旋转并加入独立噪声，就可使旧算法误报约 14% 的错位。
- 修正为先检查当前接缝的一致性，再解释远处的相关峰；保留原有阈值、认证期限和大位移／遮挡回退。160 个运动残差样本、生产 Swift／Metal 检查、AddressSanitizer、217 项 Python 回归（29.763 秒）及签名 Release 检查通过。
- 这个新构建未安装、未启动，也未进行真机视觉验收。详细原因与证据见[诊断说明](MOTION_INSTABILITY_20261022.md)和[结构化记录](../validation/motion-instability-20261022.json)。

## 2026-10-22：双摄匹配稳定性与切镜头会话修复

- **此阶段的修正版曾按用户重新连接后的请求覆盖安装并正常启动，随后用户仍反馈不稳定。** 此前版本在 21:24 的实时场景仍发生匹配截止并黑化；离线修正平坦区域独立噪声误判、无实际外围的边界误检及新旧配准切换，新增连续噪声与多深度用例。该阶段 217 项 Python 回归（30.240 秒）、生产 Swift／Metal 检查、AddressSanitizer 和签名 Release／严格签名校验通过；构建安装成功不替代真机视觉验收。
- 保留双路图像匹配，不启用 LiDAR。整体配准与接缝跟踪分频，保留真实框外搜索余量，独立弱点使用固定 200 ms 截止时间，增加误差滤波，修正重复外观和局部亮度差的误判。
- 修复 60 fps 双摄转普通 `.photo` 图时遗留的帧时长范围冲突；六次真实镜头往返就绪检查通过，未触发快门。
- 两组已保存的预览 PNG 在新版本静态重复回放中完成透明恢复；第一组残差约 1.34%，第二组约 4.26%。失败房间的那一刻没有双路原始帧，不能把两组成功样本替代失败场景验收。详见[论文与公开实现调研](PERIPHERAL_MATCHING_RESEARCH_20261022.md)。
- 详细算法、性能边界、签名安装结果和剩余范围见[本轮说明](PERIPHERAL_STABILITY_20261022.md)及[结构化记录](../validation/peripheral-stability-20261022.json)。以下章节保留对应版本的历史状态。

2026-10-19 历史版本说明：当时 `main` 工作区的 UI 重写及 HNCS revision 12 已覆盖安装到 iPhone；元数据故障修正版于 18:05 完成更新，Mac 定向元数据检查及原失败照片重放通过。该轮未启动手机 App 或拍照，完整回归和手机保存结果当时仍待验收。新拍摄使用 revision 12，旧照片保留 revision 11。以下日期章节保留历史证据，其中“当前源码”“已安装”和手机计时均指对应当时构建。

## 2026-10-20：Liquid Glass 外围、连续畸变黑化与 60 Hz 取景

- 用户授权 Mac 离线回归与 iOS Release 构建；随后用户要求安装。2026-10-22 18:59 原描述文件已于当日 12:56 到期，按既定续签方式用 `--refresh-signing` 重新签名（新到期 2026-10-29 18:59:15 +08:00），严格签名校验通过，用 `devicectl` 覆盖安装到 `Equinox的iPhone`，bundle identifier 不变、未卸载、未启动 App。
- Python 回归 **217 项全部通过**（Python 3.12 临时环境，按 `requirements.txt` 安装；FFCS 参考包另需 `tifffile`，未列在 requirements 中）。
- `test_peripheral_glass.py` 通过：连续映射、单调性、10% 锁黑、8%／0.4 秒恢复、恒速动画与中断、未知数据；Metal 中央 RGBA 排除，外围亮度与输入一致、仅按黑化缩放。
- `test_apple_images.py`：11 项通过，1 项失败（“Recovered old Nature capture adopted automatic WB or lost its frozen recipe”）。同一检查在未修改的 `HEAD`（df0b891）上同样失败，两次输出逐行一致，属既有问题，与本次 UI 改动无关，尚未处理。
- 未签名 iOS Release 构建成功，无新增警告。
- 未验证：真机 Liquid Glass 对相机／Metal 层的呈现、实际帧率与双摄 60 fps 可用性、功耗与热状态、接缝视觉效果。

## 2026-10-19 18:05：元数据导致反复处理失败，已修正并安装

- 用户提供的提示对应 `PipelineError.metadata`。只读复制手机保留的 RAW 和配方，校验和匹配；用真实元数据复现了 XMP 合并返回成功、原生 TIFF/EXIF 字段却缺失的问题，校验因此拒绝成片。
- 改为在 HEIF/JPEG 首次编码时通过 `CIImage.settingProperties` 写入筛选后的原生字典，保留输出字段校验及 iOS 完整文件保护；没有额外压缩或颜色算法改动。
- 生产 `checkCaptureMetadata` 定向检查通过，覆盖缺失字段拒绝、机型／镜头／曝光、时区和子秒、几何／MakerNote、像素无差异、10-bit HDR HEIF 与兼容 JPEG。7 项相关源码检查通过。
- 同一份失败 RAW 按原配方在 Mac 上成功导出 **6000×8000、10-bit HDR HEIF**；机型、镜头、曝光、ISO 400 和子秒 `271` 回读正确，拍摄时间差为 0 秒。
- 签名 Release 构建、严格签名校验及 USB 覆盖安装成功。未卸载应用，未启动手机 App 或拍摄照片；完整回归套件、UI／相机测试及手机 Photos 保存结果未验证。

证据：[故障与修复说明](METADATA_FAILURE_20261019.md)、[结构化结果及最新安装回执](../validation/metadata-failure-20261019.json)。

## 2026-10-19 17:32：HNCS revision 12 初次构建并安装，当时未运行测试

- 用户要求修复新版 HNCS 分析发现的三项问题；已完成浮点输出色域、HDR 高光参与锐化、拍摄元数据与时间保留的代码。
- 新版工作图像先包含真实高光亮度，再按全图尺度处理；浮点输出保留扩展 sRGB，编码与回看在目标 BT.2020 色域中裁剪。旧照片配方仍使用旧处理路径。
- 当时的元数据实现采用编码后 XMP 合并，随后被上方故障修复替换；相册仍使用原拍摄时间，图像没有额外重新压缩。
- 已编写独立主色向量、HDR 中性细纹、文件/内存与条带/并行、元数据/时间/位深以及旧配方回归，均未运行。
- 按用户随后提出的 USB 安装请求，普通签名 Release 构建、严格签名校验及设备安装均成功。2026-10-19 17:32 已覆盖安装到 `Equinox的iPhone`，bundle identifier 保持 `dev.glasscam.prototype`，未卸载。签名有效至 2026-10-22 12:56:12 +08:00；[安装记录](../validation/iphone-install-revision12-20261019.json)保留日志位置与二进制摘要。
- 本次未启动 App、运行测试、原生 Phocus 探针或拍摄照片。构建及安装成功不代表 revision 12 的运行效果已通过验收。

实现、数据契约及待运行命令见 [revision 12 交付说明](HNCS_REVISION12_20261019.md)。

## 2026-10-19：UI 重写已构建并安装，运行效果待验收

- 用户已确认取景与设置设计并授权写代码，随后明确要求先写完汇报，得到新许可后再测试。
- 已实现固定中央画幅、真实多摄外围、自定义 Metal 玻璃、10% 黑化／8% 稳定恢复、设置分层、中英文文案与新拍摄 Square Crop 移除。详见[设计及实现边界](UI_REDESIGN_20261019.md)。
- 已补充外围状态机、Vision／Core Image 配准、独立接缝残差、Metal 中央像素排除、方形旧配方迁移及中英文 UI 导航用例，并更新旧源码合同与几何规格。以上用例均未执行。
- 最终源码已与 revision 12 一同通过签名 Release 构建并覆盖安装到 iPhone；本次未启动 App、运行测试或拍摄照片。
- 后续的 Python、Apple 图像／外围检查以及真机接缝、动画、拍摄与恢复验收均等待新的许可。以下历史 209 项通过记录不验证本次改动。

## 2026-10-19：GlassCam 仓库整理

- 移除顶层独立 HNCS 技术交付目录的 398 个文件，保留 GlassCam 所需的 `reference/`、`reference_ffcs/`、数值资产、工具和回归证据。
- HNCS 资源生成与验证只使用项目内参考目录，删除对顶层旧交付目录的回退依赖。
- 删除后 209 项 Python 回归全部通过，普通 iOS Release 未签名构建成功；134 个已编辑文档的相对链接均可解析。
- 本轮构建没有安装或启动手机应用，已有真机验收暂停状态不变。构建成功不扩展原来的设备或颜色验证结论。

## 2026-10-18：Nature 全流程二进制核查与偏绿修复

- radare2 / r2ghidra 核查 38 个函数。原生调用证明白平衡可以独立修改：Nature 的 327,680 项曲线值及其余 correction 字节不变。28 组有效白平衡驱动的矩阵／LUT 选择完全匹配，修复后的 C++ context 与原版颜色核比较 688,128 通道为零差。
- 相机默认保留每张照片的完整白平衡，并按同一白点选择颜色参数；Nature 的原始曲线、细节设置和原厂资产保留。可选 Original preset 重放原始白平衡。旧偏好为未来照片迁移，旧持久照片保持原配方，显式选择可记忆。
- 209 项 Python 回归通过。Mac 生产 Swift／Core Image／Metal／HDR HEIF 检查通过，覆盖两种策略、旧版本及未知版本、缓存、成片描述、持久恢复、输出政策与保存重试。
- 已有三摄 RAW 各导出修复前／后全源成片，共 6 张 6048×8064、10-bit HDR 文件，回读通过；主摄／长焦旧模式 PNG 与修复前诊断逐像素相同。明显新增的黄绿色偏色消除，Nature 的曲线和细节效果仍保留。
- 通用 iOS Release 编译通过；该离线核查没有拍摄或继续真机验收。随后用户仅要求安装，2026-10-18 的签名 Release 构建和设备安装日志均确认成功，未启动 App 或复测。跨相机绝对色准、原版完整 RAW 显影及最终成片等价仍不在本轮已证明范围。

证据：[详细流程与修复报告](PHOCUS_NATURE_PIPELINE_20261018.md)、[结构化验证](../validation/nature-pipeline-20261018.json)。

## 2026-10-18：三摄真机阶段与偏绿问题暂停点

- 手机连接后已安装并启动 Release。实机发现虚拟三摄只公布最高约 12MP 的 ProRAW 尺寸，而三个物理镜头各有 8064×6048；已增加快门时使用系统所选物理镜头、保持视角采集高分辨率 RAW、然后恢复虚拟取景的流程。
- 修正后的 **8 项真机 UI 测试全部通过**，覆盖三摄能力、主摄／长焦的进程结束恢复、超广后台恢复、捏合及横屏拍摄、24MP／48MP 自动保存和回看、设置记忆、焦段按钮及连续标尺。三颗镜头实际 RAW 均为 8064×6048；原生视角 48MP 成片为 6048×8064，数字变焦后的回退为约 24MP。最新 Python 206 项回归通过，25.915 秒。
- 最初两次 UI 定位失败分别来自弹层／底层同名按钮及旋转后的紧凑布局，已改为通过焦距弹层定位。失败记录保留，未将其当作相机拍摄失败。
- 用户随后要求停止继续测试，先解释成片发绿。**真机验收现已暂停**；FFCS／方形裁切组合、相册未知结果的设备注入场景、手动锁屏及完整相册原件回读尚未完成。现有自动保存成功回调和 App 内成片不替代相册原件逐项核验。
- 当时只用已有 RAW／HEIF 在 Mac 上对照，定位到 Nature 的固定白平衡会改变拍摄自动白平衡的色调补偿；该诊断阶段未修改生产颜色代码。后续修复见本页 revision 11 章节。原始诊断见 [Nature 偏绿诊断](IPHONE_NATURE_GREEN_20261018.md)。

证据：[阶段记录](../validation/iphone-first-usable-20261018.json)、[偏绿数值记录](../validation/iphone-nature-green-20261018.json)。下方离线章节保留当时的构建及未连接状态。

## 2026-10-18：三摄首版离线开发与交付构建

- 已按用户 Q12 的完整确认实现自动三摄接力、捏合／快捷焦段／连续标尺、快门构图冻结，以及最终构图后的 24MP／48MP 输出政策。HNCS／FFCS C++ 颜色核及参考资产未变。
- 单张任务持久保留 RAW、配方与 HEIF；Mac 行为测试覆盖重启恢复、未知相册结果、保存回执失败、原子写入前后失败、前后台切换、在途保存、数据损坏保留与清理重试。相机和 Photos 使用替身，未据此宣称真机恢复已通过。
- 最终完整 Python 回归 **206 项通过，27.348 秒**。Mac 生产 Swift／Core Image／Metal／HDR HEIF 测试通过，含输出阈值、裁切后选档、插值比例、EXIF 数字变焦和实际解码尺寸持久化；旧数值基线未修改。
- 同一张真实 6048×8064 DNG：24MP 档输出 4242×5656、48MP 档保留 6048×8064，均为 10-bit PQ；48MP 输出与原生 HEIF 逐字节一致。小尺寸夹具插值到 24MP 与独立全帧 oracle 相同。像素量是保守估计，不代表 ProRAW 独立细节已被测量。
- 最终普通 **签名 Release 构建及严格签名检查通过**。`GlassCamCaptureTests`、Release、通用 iOS 目标的 **build-for-testing 通过**；只编译了测试程序，未执行手机测试。
- 签名包到期 **2026-10-22 12:56:12 +08:00**。离线阶段未安装或启动新版；下一阶段统一验收实际镜头／RAW 构图、Photos 原件、手势与旋转、恢复及快门到保存时延。
- 离线开发收尾后查询设备，用户的 iPhone 18 Pro Max 为 `unavailable`。目前等待手机连接并解锁，未执行新版安装、启动或真机 UI 测试。

证据：[本轮完整验证记录](../validation/iphone-first-usable-20261018.json)、[范围与完成项](IPHONE_FIRST_USABLE_20261018.md)、[构建、安装与验收步骤](../ios/README.md)。此前 iPhone 性能数字仍仅适用于其原始测量边界。

## 2026-10-18：当前生产导出的 iPhone 分段实测

- iPhone 18 Pro Max（iPhone19,7／A20 Pro）、iOS 27.0.1（24A446），有签名的 Release 构建，以 devicectl 启动，未附加调试器。
- 同一张 6048×8064 DNG，4 种配方 × 24／48MP，完成 8 次预热、40 次正式计时及 8 次关闭计时的数值对照。另有一次独立试运行。
- 24／48MP 完整中位数：Standard **3.913／3.989 s**；Nature **3.867／4.004 s**；PROVIA **5.032／5.135 s**；ACROS **5.030／5.143 s**。包括 RAW 保留、完整导出和 HEIF 回看，排除拍摄、Photos 保存和并行取景。
- 40 次正式样本的开始／结束和条带热状态采样均为 nominal；低电量模式关闭、USB 供电。末尾两个额外 ACROS 数值对照出现 fair，等待时间和状态单列，不进入正式中位数。慢样本未删除。
- 56 个 HEIF 取回后哈希全部匹配；每个配方／尺寸的 7 个输出包括关闭计时对照均逐字节一致。8 组代表文件另由 ffprobe 确认 HEVC 10-bit／PQ／BT.2020 primaries。
- 在实际 API 前后新增可选计时，RAW 渲染、颜色入口、像素转换、空间处理、文件调用和最终编码可以分别统计。数学和并行策略保持原实现；没有把这次测量宣称为新优化的收益。
- 测量版及普通版 Release 均编译成功，既有全源导出契约检查 5 项通过。完整原始样本、源代码／二进制指纹和计时边界见下列报告。

证据：[真机性能报告](IPHONE_PERFORMANCE_20261018.md)、[汇总及原始样本](../validation/iphone-performance-20261018.json)。

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

## 2026-10-23：灰度空间修正与用户可调容差

新增 0.25–4.00 / 0.05 的匹配容差滑条（默认 1.00），记录实际选择、分析与纹理容差；生产匹配器区分灰度几何与颜色模型，后台双向光流提供空间候选，原生接缝验证逐边授权。217 项 Python 回归、真实原生记录／ZIP、独立位移真值与 CI／Metal 检查通过，签名 iPhone Release 构建完成。

新 10 组在默认容差的静态重复重放中，10 组至少一侧全透明、4 组所有外围边全透明；容差 4.00 时后者为 8 组。旧 12 组默认容差冷启动中 6 组全透明、8 组至少一侧透明。这些是静态 Mac 输入结果，不能当作手机运动稳定性或系统玻璃最终效果。完整说明及最终验证索引：`docs/GRAYSCALE_TOLERANCE_20261023.md`、`validation/second-field-20261023/verification.json`。本轮未连接、安装、启动或调试手机。

## 2026-10-25：实时外围显示与渐暗策略审查

按用户“多数场景透明、允许更多畸变”的要求，解耦当前相机纹理与后台匹配；未知／局部错误不再锁黑。新增真实 GPU 的无分析启动、容差变化、镜头／窗口身份、旧回调、颜色帧更新与大面积误差渐暗检查。22 组原始场景在默认容差下全部外围可见，其中 20 组全部外围边完全打开；另两组局部渐暗。另两次现场捕获与真实手机调度时间也纳入验证。

生产组件／AddressSanitizer、原始记录与 ZIP 以及 217 项 Python 回归通过，签名 Release 构建完成。详细边界与证据见 `docs/TRANSPARENCY_REVIEW_20261025.md`、`validation/transparency-review-20261025/verification.json`；本轮未访问手机。

## 2026-10-25：原始外围直接拼接（覆盖上节显示策略）

用户指出 15:30:35 的近距离电脑记录不应透明，并明确外围不做几何矫正。该记录的 44 个文件已从手机复制并校验；旧版 180 条状态全部透明且实际使用了单应／局部光流。新版移除显示与生产分析中的场景自适应矫正，按固定视场比例拼接，灰度匹配只测量原始错位。容差不再把有纹理区域变成平坦区域；未完成首个判断不放行，已确认坏接缝不会因测量缺席而自动变透明。

最新电脑反例在容差 4 时上下均为全遮罩，包括启动阶段。此前两批共 22 组静态原始场景在容差 4 时，19 组全部外围遮罩小于 0.1%，其余 3 组有部分渐暗；所有 22 组仍有可见外围。原生 CI／Metal 与 AddressSanitizer、原始记录／ZIP 完整性、217 项 Python 回归均通过，签名 iPhone Release 已构建，尚未安装。真实近景负例、远景小位移正例与旧手机调度时间均有回归；Mac 静态回放不代表移动手机的最终效果或帧率。

详见 [直接拼接与多摄接口](DIRECT_STITCH_AND_MULTICAM_20261025.md)，最终证据索引为 `validation/direct-stitch-20261025/verification.json`。`livePreview` 是当前实际显示策略；回放中保留的旧严格证书与旧静态策略字段仅用于历史对比，不决定新版遮罩。

## 2026-10-25：上下遮罩跟随较大值

上下接缝分别测量，在延时与平滑之前取较大遮罩需求，再同步渐暗／恢复。原生回归验证单侧严重错位使上下同黑、半透明程度取大不取平均、较坏接缝上下换边不短暂变亮，且左右遮罩不参与上下取大。原有 CI／Metal、当前纹理更新、启动保护与记录时序检查通过；签名 Release 构建通过。日志和安装结果见 `validation/shared-opacity-20261025/`；未启动手机相机或新增实拍。

## 2026-10-25：同步显示和接缝测量根因修复

旧记录的中心／外围源 PTS 提交差中位数约 23.48 ms。源码确认独立的中心显示层与外围“上传后下一帧才采样”路径额外引入时间差；改为同一对镜头帧、同一 Metal 命令及 drawable，并合并新帧唤醒和中心颜色处理。原生焦段优先尝试 Apple 虚拟设备的子镜头同步端口，不支持、视场变化或数字变焦时保留物理输入路径；没有把同步回调冒充硬件零曝光差。

测量层修复宽歧义区间上界被当大位移、最大离群距离、稀疏高分位数及整块缺失计数；未知不再提交零误差，测量量在映射遮罩前做短历史稳健处理。23 组原始记录、299 次共同微动的受控测试中，预热后的上下遮罩没有跳变；指定电脑近景仍全黑。独立真值 2/192 位移透明、24/192 位移不透明；真实 GPU 检查连续 8 对变化帧当次上传／采样与中心坐标方向、外围遮罩隔离，AddressSanitizer 通过。完整 217 项 Python 回归通过（31.787 s），签名 Release 构建通过。

两批 22 组静态原始输入在默认容差的当前显示回放中均能打开；这一数量没有人工接受真值，不是正确率。Mac 受控图像与实际时钟检查不等于手机运动、最终 Liquid Glass 或屏幕延迟验收。详细根因与 Apple／社区来源见 [同步与稳定性报告](SYNC_AND_STABILITY_ROOT_CAUSE_20261025.md)，完整证据及安装状态见 `validation/sync-stability-20261025/verification.json`。

## 2026-10-26：变坏快确认，恢复须稳定

新增坏接缝响应与假恢复回归。受控生产策略测试中，95% 遮黑由旧版 0.833 s 缩短为 0.200 s，稳定好证据至 5% 遮罩由 0.400 s 改为 1.233 s；好／坏交替不重开，单次孤立坏观测不黑闪。过期分析恢复时需重新积累连续证据。实际像素测试新增三分之一接缝上的错位物体，避免被平坦多数压掉；多个相邻匹配的可观测位移须一致。

23 组、299 次原始图像微动回放最坏约 5.66 个百分点深浅变化，未见透明／全黑往返；指定电脑反例保持全黑。此为受控 Mac 输入，不冒充真机视频或屏幕响应时间。阈值及语义覆盖此前同日／前日冲突策略。详细说明见 [积极遮黑与稳定恢复](OPAQUE_RESPONSE_20261026.md)，完整检查与安装状态见 `validation/opaque-response-20261026/verification.json`。

最终原生 GPU／AddressSanitizer、原始记录／ZIP、217 项 Python 回归和签名 Release 均通过。系统将此前配对的手机报告为不可用，因此本轮新包尚未安装，未启动手机相机。
