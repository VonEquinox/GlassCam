# 测试写法

判断标准：**不改变行为的重构不应让任何测试失败；引入行为错误时至少有一个测试失败。** 做不到这两点的测试不要写。

## 禁止

1. **读源文件做断言。** 不在源码文本里找字符串，不检查代码出现的先后顺序，不靠搜索证明「某个 API 没被调用」。
2. **测副本。** 不在测试里用另一种语言重写一份产品逻辑，再去测这份副本。
3. **用测试记录修改。** 不为了证明「这次改动做了」而写测试。只为将来可能被改坏的行为写测试。
4. **用 `fatalError`、`exit`、`precondition` 当断言。** 第一个失败会终止进程，后面的检查全部不会运行。
5. **用 `sleep` 轮询等待。** 异步结果用 async/await、continuation 或注入的时钟等待。
6. **依赖环境。** 不依赖原厂二进制、本机绝对路径、网络、手机或测试执行顺序。需要本地素材（如 DNG）的测试只在显式开启时运行，素材缺失时跳过。
7. **免责声明。** 测试文件开头不写「本测试不验证 X」。需要这样声明的测试就不该存在。

## 怎么写

1. **一个测试一个行为。** 名字写成「条件_结果」：`saveFailure_retryReusesEncodedFile`、`recipeWithoutRevision_decodesAsRevision1`。
2. **三段式。** 准备 → 一次动作 → 检查结果，三段之间空一行。
3. **断言要少而准。**
   - 通常 1–3 个，都描述这一次动作的结果。超过 5 个就拆成多个测试。
   - 一个断言只查一件事，不用 `&&` 拼接条件。
   - 用 `#expect(a == b)` 或 pytest 的 `assert a == b`，让失败时显示两边的实际值。不写 `assertTrue(a == b)`，不用手写消息代替实际值。
   - 多组输入用参数化：Swift Testing 用 `@Test(arguments:)`，pytest 用 `@pytest.mark.parametrize`。不在循环里断言。
   - 不写来历不明的数字（如 `at: 10.02, epoch: 8`），改用有名字的常量、fixture 或构造函数。
4. **依赖注入。** 相机、相册、文件系统、时钟等外部依赖通过协议或闭包注入。`CaptureWorkflow` 的 `services` 是现成的例子。
5. **数值比较。** 要求逐值一致就用 `==`。需要容差时，定义成有名字的常量，并注释写明容差的来由。

## 用哪种测试

| 被测对象 | 测试方式 | 位置 |
|---|---|---|
| C++ 数值内核 | 与 golden 数据逐值比对（pytest + numpy） | `tests/numeric/` |
| C++ 内存安全 | 冒烟程序，在 AddressSanitizer / UBSan 下运行 | `Packages/GlassCamKit/NativeTests/` |
| Swift 逻辑：配方编解码与迁移、拍摄流程状态机、记录恢复、外围策略 | Swift Testing 单元测试 | `Packages/GlassCamKit/Tests/` |
| 图像管线端到端 | 少量集成测试；完整色彩链用本地 DNG 基线，显式开启 | `Packages/GlassCamKit/Tests/` |
| 用户操作流程 | XCUITest，在模拟器上运行 | `App/GlassCamUITests/` |
| 相机硬件、成片观感 | 手动验收清单 | 不写成自动测试 |

## Golden 数据

- 放在 `tests/fixtures/<主题>/`。每个目录有一个 `README.md`，写明来源、生成命令和对应的算法版本。
- 测试不能现场生成 golden 再和自己比较。
- 修改 golden 时，提交说明必须写明原因和受影响的版本号。

## 产品代码里的断言

外部输入、文件、系统 API 出错时用 `throw`。只有「不可能发生」的程序员错误才用 `precondition`。不在产品代码里用 `assert` 做输入校验。

## 改写示例

原来的写法（检查源码文本）：

```python
def test_save_retry_uses_encoded_file_and_keeps_single_admission(self):
    workflow = (ROOT/'ios/GlassCam/CaptureWorkflow.swift').read_text()
    self.assertIn('if let existing = current.encoded { encoded = existing }', workflow)
    self.assertIn('job?.encoded = encoded', workflow)
    self.assertIn('try await services.save(encoded.file)', workflow)
```

应该写成（示意）：

```swift
@Test func saveFailure_retryReusesEncodedFile() async throws {
    let harness = try WorkflowHarness(saveFailures: 1)
    let workflow = harness.makeWorkflow()

    workflow.capturePhoto(snapshot: .fixture)
    try await harness.until(workflow, is: .failed)
    workflow.retry()
    try await harness.until(workflow, is: .idle)

    #expect(harness.processCalls == 1)
    #expect(harness.saves[0].url == harness.saves[1].url)
}
```

## 评审清单

- 删掉被测的功能，这个测试会失败吗？
- 只改实现、不改行为，这个测试还会通过吗？
- 失败信息能直接看出哪里错、实际值是多少吗？
- 只看测试名，能知道它在测什么吗？
