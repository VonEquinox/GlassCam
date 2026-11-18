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
| Metal 成片内核 | 调用真实 GPU，与 CPU 参考比较；整数锐化逐位一致，颜色使用 HDR 预算 | `Packages/GlassCamKit/Tests/ImagingCoreTests/MetalColorTests.swift` |
| 用户操作流程 | XCUITest，在模拟器上运行 | `App/GlassCamUITests/` |
| 相机硬件、成片观感 | 手动验收清单 | 不写成自动测试 |

## 运行命令

在仓库根目录运行；Apple 平台检查需要 macOS 和 Xcode 27，数值检查使用 `uv` 准备 [Python 依赖](../tests/numeric/requirements.txt)。[Makefile](../Makefile) 是统一入口。

| 命令 | 执行内容 |
|---|---|
| `make test` | 开发工具、原生内存安全、数值、package Swift Testing 与 App 模拟器单元测试 |
| `make test-tools` | 模拟器选择策略，以及 FFCS 参考资源的选择性展开与归档校验 |
| `make test-native` | SwiftPM Release 构建原生可执行程序，再在独立 scratch 目录以 AddressSanitizer / UBSan 构建并运行 |
| `make test-numeric` | `uv` 准备 Python；`native_build.py` 构建 `GlassCamNative`／`GlassCamNativeTestSupport` 动态库，pytest 经 `ctypes` 比较固定 golden、边界输入与分条结果 |
| `make test-swift` | SwiftPM Release 模式的 package Swift Testing；准备 FFCS／LUMIX 与夹具，真实 Metal 验证成片及 F5 数值契约 |
| `make test-app` | `GlassCamUnitTests` scheme 的 App 模拟器单元测试 |
| `make test-ui` | `GlassCamCaptureTests` scheme 的模拟器流程：质量选择持久化、外围滤镜拨盘、控件重开与 RAW 记录入口 |
| `make test-baseline` | 固定完整色彩链检查，以及显式开启的本地 ProRAW 基线 |

模拟器命令默认读取已有设备和运行时清单，选择可用且运行 iOS 27 或更高版本的 iPhone 模拟器：优先已启动项，再按系统版本从新到旧、设备类型和 UUID 稳定排序。找不到合适目标时直接报错，不安装运行时或创建模拟器。可用 `SIMULATOR_ID` 指定已有模拟器的 UUID，例如 `make test-app SIMULATOR_ID=SIMULATOR_UUID`；显式目标也必须满足上述条件。`DIAGNOSTICS` 可指定 App 测试和基线产物目录；`DEVELOPER_DIR` 可选择其他 Xcode 安装。

原生入口由 [test_native.py](../scripts/test_native.py) 枚举 12 个可执行程序：`hncs_smoke`、`hncs_spatial_smoke`、`hncs_parallel_sanitizer`、`hncs_revision8_sanitizer`、`hncs_native_pipeline_sanitizer`、`ffcs_smoke`、`ffcs_strip_sanitizer`、`ffcs_color_only_test`、`ffcs_effect_switches_test`、`f5_core_tests`、`lumix_smoke`、`float_raster_smoke`。它们调用真实产品内核；`CF5` 只在这里做数学自检，无图像 golden，也不在生产 F5 依赖中。

SwiftPM 将 `.metal` 源码作为资源拷贝。F5 和成片颜色／锐化测试以 safe／precise 运行时编译，外围 GPU 测试编译内嵌源码并采用默认选项；App 测试及 Release 同时检查 Xcode 编入 `default.metallib` 的路径。各等级约束、编译标志与必跑套件见 [ADR 0017](adr/0017-native-and-metal-contracts.md)。

| 环境变量 / make 参数 | 用途 |
|---|---|
| `DEVELOPER_DIR` | 选择 Xcode；Makefile 默认使用标准安装位置 |
| `SIMULATOR_ID` | 显式选择符合运行要求的既有模拟器 |
| `DIAGNOSTICS` | App／UI 测试及本地基线产物目录，使用仓库外目录 |
| `GLASSCAM_TEST_RESOURCES` | `TestResources` 的 FFCS／LUMIX 根目录；`make test-swift` 与 `make test-baseline` 自动注入 |
| `GLASSCAM_TEST_FIXTURES` | 冻结夹具根目录；以上 make 入口自动指向 `tests/fixtures` |
| `GLASSCAM_DNG_DIR` / `GLASSCAM_BASELINE_OUTPUT` | 开启三镜头本地 ProRAW 基线／指定基线 HEIF 目录；输出变量由 `make test-baseline` 注入 |
| `GLASSCAM_BAYER_REPLAY` / `GLASSCAM_BAYER_OUTPUT` / `GLASSCAM_BAYER_ARCHIVE` | Speed、Balanced 输入根目录／六组合 HEIF 目录／Balanced 调色前归档根目录 |
| `GLASSCAM_RAW_SCENE_REPLAY` / `GLASSCAM_RAW_SCENE_OUTPUT` | 七帧完整 bundle／纯原片记录输出，单独检查无品牌资源的归档链 |
| `GLASSCAM_LARGE_NUMERICS` | 设为 `1` 时开启大尺寸数值样本 |

UI target 只包含模拟器用户流程。真机取证脚本和来源提交位于 `GlassCam-research` 的 `device-acceptance/`，设备操作需按[发布说明](release.md)另行授权。Speed 单帧和 Balanced 七帧选择由设置、采集预算和拍摄记录测试覆盖。

本地 ProRAW 基线通过 `GLASSCAM_DNG_DIR` 开启。目录应至少包含主摄、超广角、长焦的三份 DNG；测试按文件名排序读取前三份。将 `DNG_DIR` 设为自己的素材目录后运行：

```sh
GLASSCAM_DNG_DIR="$DNG_DIR" make test-baseline
```

未设置 `GLASSCAM_DNG_DIR` 时跳过 `BaselineTests`，固定 `ColorChainTests` 仍运行。本地 Bayer 完整导出由 `GLASSCAM_BAYER_REPLAY` 开启，目录内的 `speed/` 与 `balanced/` 分别包含一帧／七帧完整 capture bundle；`GLASSCAM_BAYER_OUTPUT` 可指定保存六种模式与色彩组合的 HEIF 目录；`GLASSCAM_BAYER_ARCHIVE` 开启 Balanced 的完整尺寸调色前归档。未配置时不读取本机素材。`GLASSCAM_RAW_SCENE_REPLAY` 指向一组完整七帧 Bayer 输入，`GLASSCAM_RAW_SCENE_OUTPUT` 指定归档根目录，可单独运行 `F5BayerReplayTests.recordedScene_archivesMergedRAWWithoutColorResources` 验证完整分辨率的纯原片记录；使用可写的素材副本，重建会更新输入目录内的线性相机结果。

其他可选检查通过 `GLASSCAM_LARGE_NUMERICS=1` 开启大尺寸数值样本。旧样条 GPU 与似然表实验位于研究仓库。

## Golden 数据

- 放在 `tests/fixtures/<主题>/`。每个目录有一个 `README.md`，写明来源、生成命令和对应的算法版本。
- 测试不能现场生成 golden 再和自己比较。
- 修改 golden 时，提交说明必须写明原因和受影响的版本号。

数值测试将固定参考实现作为真实 C++ 输出的 oracle，逐组比较阶段数组、线性与预览输出、并行和分条结果。输入样本、随机种子、数据类型及容差由测试保留；`tests/numeric/support/` 负责加载参考数据、绑定 C ABI 和返回观察结果，行为断言写在参数化用例中。

当前 HNCS 13、FFCS 3、LUMIX 5 另有固定原厂颜色夹具，分别约束白平衡与工作配置、整数网格映射、低 ISO 和整数色彩控制；原 CPU 参考与旧 golden 保持独立。`CurrentColorTests` 核对 Swift 的实际分派，`MetalColorTests` 同时检查 HDR 预算、黑白截断和灰阶反转。原厂采集、源码对照和真实 RAW 测量工具保留在研究仓库。

GPU 颜色遵守 [HDR 预算](image-pipeline.md#gpu-精度预算)，不放宽 CPU golden。生产 F5 的曲率、配准与源边界由 `F5CurvatureTests`、`F5CurvatureRegistrationTests`、`F5CurvatureSourceTests` 的解析信号约束；`F5CurvatureOutputTests.orderedPostOperations_matchFrozenReference` 消费固定的 [DNG 与浮点参考](../tests/fixtures/f5-post-operations/README.md)。`NativeTestSupport` 的 BT.2124 指标只比较真实输出。完整尺寸 RAW、编码后色差与手机性能测量保存在研究仓库。

FFCS 只展开参考代码、资源与来源清单；交付文档、上游测试和历史报告保存在固定 `source.zip` 中。来源校验同时检查保留文件与归档内的其余交付项，冻结 golden 的来源身份保持不变。性能和诊断命令在 `GlassCam-research` 的 `tools/studies/product-tooling/` 使用固定产品源码快照运行。

拍摄记录候选由独立 [journal-fixtures 工具包](../tools/journal-fixtures/Package.swift)生成；命令见[样本说明](../tests/fixtures/journal/README.md)。它复用测试输入和真实产品序列化器，只接受仓库外不存在的目标目录。正常 `make test` 不执行生成器。

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
