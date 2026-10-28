# 拍摄记录兼容样本

这些文件由重构前提交 `582a723` 的真实 Swift 序列化器生成，输入来自合成测试数据，不包含用户照片。生成器调用 `CaptureJournal.retain`、`retainBurst`、`storeEncoded`、`F5BurstTransaction` 和现有 `F5Fixtures`；固定 UUID、参考日期 `800000000` 秒和文件名后，使用同一产品 Codable 模型编码。

| 样本 | 内容 | 编解码约定 |
|---|---|---|
| `single-photo/` | schema 1、Quality、单张 RAW 的恢复记录 | 解码后编码与 `capture.json` 逐字节相同 |
| `f5-five-frames/` | schema 2、五帧合成 Bayer、burst/intent/profile 与各帧文件 | 当前记录及三个 F5 JSON 分别逐字节往返；文件摘要由真实加载器验证 |
| `f5-encoded.json` | schema 2、已编码照片、F5 来源信息与 fallback 分类 | 解码后编码逐字节相同 |
| `speed-legacy/` | schema 1、旧 Speed 12 MP、缺少 `archiveF5RAW` | 解码保留 Speed 与 12 MP；编码与 `speed-normalized.json` 逐字节相同 |
| `speed-normalized.json` | 重构前解码器对旧 Speed 的编码结果 | 原解码器补 `archiveF5RAW: false`，其余字段不变 |

旧 Speed 的原文件为 849 字节，原解码器输出为 870 字节。T07 的兼容验收已明确采用现有标准化结果，不修改旧数据的解码规则。其余当前格式要求原字节往返一致。

版本保持为 `schemaVersion` 1/2、`f5-burst-v1`、`f5-effective-v2.0.1`、`f5-effective-v2` 与 `f5-dng-linear-d50-v1`；配方中的版本字段由提交 `582a723` 的 `.standard` 生成。单张 RAW 和编码 HEIF 的内容是可验证哈希的短文本；五帧目录中的 DNG 是可由实际 F5 解码器读取的合成 TIFF/DNG。

运行兼容测试：

```sh
make test-swift
```

生成到仓库外一个不存在的目标目录，供人工审查；正常测试只读本目录，不重新生成 golden：

```sh
GLASSCAM_GENERATE_JOURNAL_FIXTURES=<仓库外的新样本目录> \
swift test -c release --package-path Packages/GlassCamKit --filter generateJournalFixtureCandidate
```

生成器在 [JournalFixtures.swift](../../../Packages/GlassCamKit/Tests/F5Tests/JournalFixtures.swift)，兼容测试在 [JournalCompatibilityTests.swift](../../../Packages/GlassCamKit/Tests/F5Tests/JournalCompatibilityTests.swift)。候选生成入口默认跳过，不会覆盖已有目录。
