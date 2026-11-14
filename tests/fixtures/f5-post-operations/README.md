# F5 镜头操作参考数据

固定 DNG 输入及其调色前 RGBA 输出，覆盖 RGB GainMap、GainMap 与 WarpRectilinear 的顺序、局部通道广播和 HDR 增益。输出布局为从上到下的 RGBA Float32 小端，输入像素为 `[0.02, 0.04, 0.06, 1]`；宽高取各 DNG 的 ActiveArea。

参考版本为 `f5-post-operations-v1`。输出冻结自提交 `715030ed6a207ade57ac2d9c35fcaa094f34f941` 的 `f5_output_strip`，该参考实现及生成器保存在 `GlassCam-research`。`reference.json` 记录源提交、布局和逐文件 SHA-256。固定数据用于保留旧参考的镜头操作结果，当前产品测试直接调用曲率输出实现，不再编译或运行旧样条输出路径。

生成器入口为研究仓库源码快照中的 `FreezePostReference.swift`；在该快照的工具包运行：

```sh
GLASSCAM_REFERENCE_OUTPUT="$OUTPUT_DIR" swift test -c release --build-system native --filter freezePostOperationReference
```

`OUTPUT_DIR` 必须指向仓库外尚不存在的目录。正常测试只读取固定数据，不执行生成器；消费入口是 `F5CurvatureOutputTests.orderedPostOperations_matchFrozenReference`，线性光容差为 `2e-5`。
