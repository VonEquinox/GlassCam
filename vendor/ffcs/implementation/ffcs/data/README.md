# 参考 LUT 与 ICC 资产

当前版本包含 50 张 `FFCSLUT2` 表：`xh2s/` 19、`gfx100/` 18、`xa3/` 11、`gfx100s/` 1（NOSTALGIC Neg.）、`gfx100ii/` 1（REALA ACE）。XA3 为 64³，其余 80³。表为原生最终矩阵映射采样，封装矩阵恒等，uint16 /20,000 值通过 zlib 保存，BGR 轴顺序、RGB 通道顺序。

各目录 `manifest.json` 保存原始封装文件大小及 SHA-256。新提取的两张表另附原生文件/库 hash、Gamma 与方法。`reference_validation.json` 保存全部 50 张表本次原生三线性对照；每表 2,000 个样本，共 100,000，仅覆盖默认 sigma 的核心映射。运行时先检查封装 hash，再附加证据。

GFX100S/GFX100II 专用表优先，其余可用外观回退 GFX100 公共表，并记录机型替代未经验证。找不到表时可用解析预设或自定义 `.cube`。

`icc/ISL-sRGB.icc`、`icc/ISL-ARGB1998.icc` 为输出配置文件。RGB 输入转换使用浮点 CMS 和参数式 sRGB 工作目标，以避免将 vendor 采样 TRC 作为逆目标时损失暗部精度。实际输出仍保留对应封装 ICC。
