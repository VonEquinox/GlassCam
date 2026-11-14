# 架构决策记录（ADR）

每篇记录一项架构取舍的背景、决定与后果。被后续决定更新的条目在原文件中标注替代状态，正文保持原貌。

| 编号 | 决策 | 状态 |
|---|---|---|
| [0001](0001-durable-single-capture.md) | 持久保留一张待完成照片 | 生效 |
| [0002](0002-adaptive-output-resolution.md) | 按有效像素选择 24MP／48MP 输出，并允许插值 | 已被 [0015](0015-fixed-24mp-camera-output.md) 替代 |
| [0003](0003-swift-ui-cpp-kernels.md) | Swift 界面与标准 C++ 数值内核 | 生效 |
| [0004](0004-full-source-export.md) | 成片从完整源照片独立生成 | 生效 |
| [0005](0005-original-heif-compatible-sharing.md) | 原始 HEIF 保存与兼容分享分开 | 生效 |
| [0006](0006-genuine-peripheral-liquid-glass.md) | 真实外围取景与系统 Liquid Glass | 生效 |
| [0007](0007-single-photo-capture-handoff.md) | 高分辨率 ProRAW 在单摄照片会话中捕获 | 已被 [0016](0016-main-camera-bayer-capture.md) 替代 |
| [0008](0008-independent-persisted-effects.md) | 效果开关独立保存在处理配方中 | 生效 |
| [0009](0009-color-only-viewfinder-proxy.md) | 取景只接入受限的逐点色彩代理 | 生效 |
| [0010](0010-photo-aware-hncs-white-balance.md) | HNCS 默认保留每张照片的白平衡 | 生效 |
| [0011](0011-independent-ffcs-reference-engine.md) | FFCS 使用独立的真实参考后端 | 生效 |
| [0012](0012-neutral-ffcs-defaults.md) | FFCS 0.2.0 默认采用原生表的中性处理 | 生效 |
| [0013](0013-exact-core-bounded-optimizations.md) | 数值内核保留精确参考路径 | 已被 [0014](0014-bounded-gpu-photo-processing.md) 替代 |
| [0014](0014-bounded-gpu-photo-processing.md) | 成片采用有界误差的 GPU 颜色处理 | 生效 |
| [0015](0015-fixed-24mp-camera-output.md) | 两种拍摄模式统一输出 24MP | 生效 |
| [0016](0016-main-camera-bayer-capture.md) | 首版拍摄固定主摄 Bayer RAW | 生效 |
