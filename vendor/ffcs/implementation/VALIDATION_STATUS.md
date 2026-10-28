# FFCS 0.2.0 验证状态 — 2026-10-13

| 检查 | 结果与范围 |
|---|---|
| 回归测试 | 61 项通过；包括独立合成输入、34 对作者 CIEDE2000 数据 |
| 原生映射对照 | 50 张 LUT × 2,000 样本，合计 100,000；全部平均 ΔE2000 <1 |
| 最高单表平均 ΔE2000 | 0.0540214251 |
| 运行时证据 | `ffcs/data/reference_validation.json`；SHA-256 匹配后才附加测量 |
| 数值复现与安装 | 见交付包 `validation/run_report.json`，与原生对照为不同检查 |
| 真实 RAF / GUI 配对 | 未提供，`unverified` |
| 原生颗粒、RAW 标定和非默认 sigma | 缺乏配对参考，`unquantified` |

测量入口为原生 `ReadMappingData` + `TransFormTrilinear`，显式处理 `.s3d` 头部 Gamma、BGR uint16 和 20,000 工作量程。显示编码采样按 sRGB 转 Lab 后计算 CIEDE2000；这是一套明确的映射比较约定，不是 GUI 色彩管线证明。每表 P95、最大误差与 SHA-256 均保存，不以平均误差掩盖局部残差。

阶段名覆盖只证明导出接口完整。传感器 RAW 阶段以自身数值域比较；CFA 和原码不计算色度 ΔE。预览回退不满足传感器 RAW PSNR 门槛。不同尺寸、缺失文件、无效色卡框、频谱长度或方法不一致都会阻止假通过。

`ffcs compare` 返回 0=通过、1=失败、2=输入错误、3=未验证；`ffcs colorchecker` 要求全部 24 个整数框有效、不重叠、同尺寸且有限。严格 JSON 把无穷 PSNR 写为字符串 `"Infinity"`。

原 `reference_core_validation.json` 与交付的 `historical_core_validation.json` 是 v0.1.0 历史记录；本次运行结果以当前 `reference_validation.json` 为准。审计发现及修复见 [FIXES_20261013.md](FIXES_20261013.md)。
