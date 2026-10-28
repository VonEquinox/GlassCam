# 外围玻璃回放夹具

这些 JSON 来自用户保存的拍摄状态记录，保留当时的观测值，不包含相机图像。`phone-glass-timing-20261023.json` 对应记录 `record-1792750091524-1DE46ECC`；两个 `direct-stitch-*` 文件分别对应远景记录 `record-1792743367981-70E427C9` 和近景记录 `record-1792913435797-F96EE7D0`。

生成方式是从原始状态记录中选取时序行或接缝 tile 数据。原始单独导出命令未随夹具保存；文件没有独立算法版本字段，以文件名、记录 ID 和主仓库提交 `eb4e551` 标识冻结版本。该版本的记录结构由 [PeripheralStateRecording.swift](../../../Packages/GlassCamKit/Sources/Peripheral/PeripheralStateRecording.swift) 定义。

从仓库根目录恢复冻结版本：

```sh
for name in phone-glass-timing-20261023 direct-stitch-distant-scene-20261025 direct-stitch-near-computer-20261025; do
  git show "eb4e551:GlassCamPrototype/tests/fixtures/$name.json" > "tests/fixtures/peripheral/$name.json"
done
```

时序消费入口为 [PhoneTimingTests.swift](../../../Packages/GlassCamKit/Tests/PeripheralTests/PhoneTimingTests.swift)和[LiveGPUFrameTests.swift](../../../Packages/GlassCamKit/Tests/PeripheralTests/LiveGPUFrameTests.swift)。接缝夹具保留原始数据供后续行为测试使用。
