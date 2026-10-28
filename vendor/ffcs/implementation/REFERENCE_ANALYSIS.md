# 参考二进制与映射证据

参考输入 `RFCEX30Ins81200.dmg` 包含 RAW FILE CONVERTER EX 3.0 powered by SILKYPIX（8.1.20）。本次只读分析与原生诊断调用使用其 x86_64 `SILKYPIX8` 核心库；macOS arm64 上通过 Rosetta 执行。原生库 SHA-256：`a0bdc416748549eada3086c4fa92015912ca6acc4b07b721f38bd2aa95af61b9`。

XH2S/GFX 系列 `.s3d` 使用 `ISL_3DMAP_V2`、80³ 网格；XA3 旧表使用 `ISL_3DMAP`、64³ 网格。头部 Gamma 在这两种格式中分别按整数 /1024 和 /100 解码。原生接口收发 BGR uint16，以 20,000 为工作量程。原生三线性入口已包含矩阵处理，封装表保存最终采样映射，因此封装矩阵为恒等，不重复施加原生矩阵。

v0.2.0 补提取 `CAM_GFX100S_NOSTALGIC_NEG_ISLRGB.s3d` 和 `CAM_GFX100_II_REALA_ACE_ISLRGB.s3d`。当前共 50 张封装表。GFX100S/GFX100II 的其他外观仍可能使用 GFX100 公共表，元数据将其记录为未经验证的机型替代。

本次重新调用 `ReadMappingData` 和 `TransFormTrilinear` 对全部表进行 2,000 个固定随机样本对照，共 100,000 次。显式执行头部 Gamma 解码、原生映射和 Gamma 编码，再按 sRGB 约定计算 ΔE2000。最高单表均值 0.0540214251，全部平均值低于 1；每表最大误差及 P95 见 [完整测量](ffcs/data/reference_validation.json)。这些结果仅覆盖默认 sigma 的映射，解析预设、原生 normal-distribution 分支、RAW 和 GUI 全链均不在此证据范围内。

复核源码在 `tools/native_probe.cpp`、`tools/extract_reference_luts.py`、`tools/verify_native_luts.py`。原生库和安装器无需运行 FFCS，不包含在技术交付 ZIP。旧测量 `reference_core_validation.json` 已标注历史属性，保留作追溯，不再自动附加到当前管线。

```sh
clang++ -std=c++17 -arch x86_64 tools/native_probe.cpp -o /tmp/ffcs-native-probe
python tools/verify_native_luts.py --app '/path/to/expanded/vendor.app' --probe /tmp/ffcs-native-probe --out /tmp/native-validation.json
```

原始静态分析、符号、反汇编和审计证据仍保留于 `audit_review/`；修复后的状态见 [修复记录](FIXES_20261013.md)。
