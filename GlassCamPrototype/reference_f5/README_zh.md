# F5 最终设计交付包 · 1.0

本包是 **iPhone 四张主曝光 + 一张短曝光 RAW 超分辨率 / HDR 系统的设计与验证材料**，不是完整 App、SDK 或已经验证的手机算法。

## 首先阅读

1. `F5_RAW_System_Design_zh.pdf`：排版阅读版，带目录与书签。
2. `F5_RAW_System_Design_zh.md`：相同内容的可检索、可修改权威正文。核心决策、公式、数据含义、边界和回退均在此文件；不需要前序聊天。
3. `acceptance.csv` 与 `implementation_tasks.csv`：测试门槛的当前状态、实施依赖与工包出口。设计冻结不意味着设备已合格。

文档优先级：正文 → 同版本规范 JSON → 实现。出现冲突时报告并修订版本，不静默猜测。

## 包含什么

- `research/sources.json`：30 条一手来源、阅读深度和设计用途。部分资料只读了摘要或官方索引，登记中如实注明；没有将它们伪称全文复现。
- `specs/burst.schema.json`：五帧交换格式；结构约束之外还需执行 `contract_rules.json` 的语义检查。
- `specs/quality.schema.json`：质量、失败与资源状态。
- `specs/policy_defaults.json`：设计初值和候选范围，不是实机测得的最佳参数。
- `specs/device_profile.template.json`：待标定字段均为 null，资格为 UNQUALIFIED；不能用于声称支持某镜头。
- `fixtures/`：5 个程序生成的小型 16-bit mosaic 文件与 manifest，用于验证 padding、奇数 ActiveArea、CFA 原点、哈希和预算规则。它们 **不是 DNG，也不是 iPhone 实拍**。
- `experiments/`：可独立运行的设计检查、前轮复跑及原始 JSON 结果。
- `VALIDATION_STATUS.json`：已做和未做的工作清单。
- `SHA256SUMS.txt`：交付文件哈希，不包含此哈希清单自身。

## 复现实验

本轮实际执行环境：Python 3.13.5、NumPy 2.3.5、SciPy 1.17.0、jsonschema 4.26.0。依赖见 `requirements.txt`。其他兼容平台可尝试运行，但浮点末位和时延不承诺一致。

在包根目录执行；这些命令只写 `reproduction/`，不会改动原结果。

```bash
python -m venv .venv
# macOS / Linux:
source .venv/bin/activate
python -m pip install -r requirements.txt
python experiments/design_checks.py --out reproduction/design_results.json
python experiments/likelihood_checks.py --out reproduction/likelihood_results.json
python experiments/prior_information_checks.py --out reproduction/prior_reproduced.json
python experiments/verify_contracts.py --out reproduction/contract_results.json
```

Windows 可在相同虚拟环境下运行同样的 Python 命令。不要使用 `python -O`：这些研究脚本有用于机制检查的 assert。`verify_contracts.py` 是测试工具，不是生产环境的安全输入验证器；生产实现须显式返回类型化错误，不依赖 assert。

`design_checks.py` 验证 effective-image 等价、删除饱和样本的选择偏差、观测值逆方差偏差、Schur/Woodbury 等价、重复使用证据、B-spline 算子与导数、采样互补、分块与两级求解。`likelihood_checks.py` 检查 PG 区间/删失 score、有符号样条系数及 warp/响应不可交换的反例。前轮脚本复跑短曝光频率信息、相位互补与共享配准误差模型。契约脚本验证实际 fixture 字节并拒绝十种错误元数据。

所有这些结果都是 **小规模合成、统计或代数检查**。1D 两级求解的收敛次数不能推断 48MP 图像所需次数；四相位信息特征值的倍数不是解析力倍数。

一个最初尝试的纯细块固定迭代门槛失败了；结果中保留 `initial_24_sweep_1_percent_relative_gate_failed=true`。最终设计改用共享全局状态与粗校正，没有删掉这个反例。

## 仍未做的验证

没有真实五帧 RAW；没有任何 iPhone 17 / 18 Pro Max 的标定或实机 API 探针结果；没有 Apple SDK 类型检查；没有完整二维产品联合求解器；没有 Metal 数值、时延、内存、热测试；没有运行强基线盲测；没有验证 HEIF 的 HDR 元数据与跨查看器行为。

因此包内的 500ms、3s/5s、1.2GiB、质量提升门槛均为 **预注册的工程目标**，不是性能报告。必须按 P0/G1/G2/G3/G4 依次取得证据。

## 实施入口

W0 可立即开发真实平台探针；W1 可用随包 fixture 开发交换和解析契约；W3 可用合成算子先完成 FP64 参考。真实画质试验必须等 W2 的设备噪声、辐射度和响应标定通过，不应直接套用 null profile。

如系统接口不支持预定输入、重要强基线无法合法适配、或设备资源达不到预算，按照正文的资格与退化规则缩小功能声明。不能多拍第六张来补齐“严格五帧”，也不能把系统 ProRAW 的未知内部帧当单次 Bayer 测量。

## 许可与资料

本包只包含本轮设计文本、研究验证代码及合成 fixture；没有附第三方论文全文、字体或相机 SDK。第三方论文/代码/SDK 须从来源登记获取，并独立检查许可、可分发性与商业使用条款。本设计未完成专利新颖性或自由实施审查。
