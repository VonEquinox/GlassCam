# 色彩管线兼容夹具

`color-pipeline-v1-exposure.json` 冻结 HDR 曝光审计前生产 Swift 管线对固定 Float32 HDR TIFF 的输出，对应 `pipelineRevision = 1`。源文件 SHA-256 保存在 JSON 的 `sourceSHA256` 中；测试入口是 [apple_color_chain.swift](../../swift-legacy/apple_color_chain.swift)。

生成方式是运行旧生产管线后采集曝光结果，原始单独生成命令未随夹具保存。该夹具保留旧照片的渲染行为，不能用当前被测实现重新生成。需要恢复时，从仓库根目录读取已冻结版本：

```sh
git show eb4e551:GlassCamPrototype/tests/fixtures/color-pipeline-v1-exposure.json > tests/fixtures/color-pipeline/color-pipeline-v1-exposure.json
```

设计背景见 [色彩链审计素材](../../../docs/legacy/COLOR_CHAIN_AUDIT_20261028.md)。
