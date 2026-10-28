# GlassCam 工作规则

适用于所有在本仓库工作的人和 AI 助手。

## 必读

- 写文档：[writing-docs.md](GlassCamPrototype/docs/writing-docs.md)
- 写测试：[testing.md](GlassCamPrototype/docs/testing.md)
- 仓库正在按 [REFACTOR_PLAN.md](REFACTOR_PLAN.md) 重构。执行其中的任务时，以计划为准。

## 硬性规则

1. 不新建带日期的报告、「本轮说明」或状态文件。改变行为时，更新相关主题文档，并在 `CHANGELOG.md` 加一行。
2. 不写读取源码文本的测试，不写用另一种语言重写产品逻辑的镜像测试。
3. 调查、实验、性能测量、逆向分析放在 `GlassCam-research` 仓库，不进本仓库。本仓库不包含加载原厂二进制或调用反编译工具的代码。
4. 不改变数值输出。C++ 内核保持 `-fno-fast-math -ffp-contract=off`，改动后必须通过 golden 比对。
5. 不破坏已保存的数据。已保存照片和拍摄记录的 JSON 结构、UserDefaults 键名、文件名必须保持兼容。
6. 未经用户明确同意，不安装、不启动、不连接 iPhone，不推送，不改写 git 历史。
7. 工作结束时在对话里汇报：改了什么、运行了哪些测试、结果如何。汇报不写进仓库。
