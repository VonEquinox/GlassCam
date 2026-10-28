# GlassCam 重构计划

这份计划交给执行重构的 agent 使用。每个任务交给一个 agent，按编号顺序执行；标明可以并行的除外。全部完成后删除本文件（T12）。

交给 agent 时这样说：

> 你负责 GlassCam 重构的 **T0x**。先读 `AGENTS.md`、`GlassCamPrototype/docs/writing-docs.md`、`GlassCamPrototype/docs/testing.md`，再读 `REFACTOR_PLAN.md` 的「执行规则」「验收套件」、你的任务和它引用的附录。只做这一个任务，完成后按「执行规则」第 7 条汇报。

## 目标

1. 产品代码按分层模块组织，依赖只能向下。
2. 测试只测行为：删除读源码文本的测试和镜像模型测试；Swift 测试改用 Swift Testing；C++ 只在一个地方定义构建。
3. 文档合并重写成约 12 篇主题文档。
4. 逆向工程、研究、实验和历史证据迁到独立的 `GlassCam-research` 仓库。

产品行为、数值输出和已保存数据的兼容性**全部保持不变**。

## 执行规则

1. **不改变行为。** 不改产品功能、数值输出、持久化格式（拍摄记录和 F5 连拍记录的 JSON 结构、UserDefaults 键名、文件名、`pipelineRevision` 等版本号）。发现 bug 只写进汇报，不要顺手修。
2. **C++ 编译参数不变。** HNCS、FFCS、LUMIX 用 `-O3 -fno-fast-math -ffp-contract=off`；F5 用 `-O2 -fno-fast-math -ffp-contract=off`；`F5Kernels.metal` 不开 fast math。
3. **Swift 语言模式不变。** 保持 Swift 5 模式（Xcode 工程现为 `SWIFT_VERSION = 5.0`），新建的 package target 也要显式指定 Swift 5 模式。
4. **不碰手机、不改写 git 历史、不创建远程仓库。** 用户已授权分批推送：每个任务验收完成、合并回 `refactor` 后推送到现有 `origin`；不合并到 `main`。
5. **不删除用户数据。** 未跟踪的大文件、`~/Library/Developer/GlassCamDiagnostics/`、`~/Library/Application Support/GlassCam/` 只能按任务说明移动，不能删除。
6. **分支。** T00 从 `main` 建出 `refactor` 分支。每个任务在 `refactor-Tnn-<英文短名>` 上完成，验收通过后合并回 `refactor`。Git 不允许 `refactor` 与 `refactor/Tnn-<英文短名>` 同时存在，用户已确认采用此命名。是否合并到 `main` 由用户决定。
7. **汇报。** 任务结束时在对话里汇报四件事：改了什么；运行了哪些验收命令、结果是什么；和计划不一致的地方；留给后续任务的事项。汇报不要写成文件。需要交接给后续任务的数据，写进本文件对应的附录。
8. **计划和代码对不上时，停下来汇报。** 不要自行扩大范围。

## 已定决策

- 研究仓库放在本机 `../GlassCam-research`（与本仓库同级），本地 git 仓库，不建远程。
- 主仓库不包含任何加载原厂二进制（Phocus、SILKYPIX）或调用 radare2 / r2ghidra 的代码。HNCS、FFCS、LUMIX 的数据提取脚本也迁到研究仓库；`vendor/*/ORIGIN.md` 记录提取时所用的研究仓库 commit。
- C++ 只用 SwiftPM 构建。删除 `core/CMakeLists.txt` 和 `core/ffcs.cmake`：仓库里没有脚本调用它们，本机也没有安装 cmake。
- 不使用 Git LFS，已提交的 zip 保持原样。
- F5 留在 App 里，做成独立模块，依赖方向反转（F5 依赖拍摄流程，拍摄流程不依赖 F5）。
- Python 只用于数值 golden 测试，改用 pytest。

## 目标结构

```
GlassCam/
├── AGENTS.md  CLAUDE.md  README.md  CHANGELOG.md  GLOSSARY.md  NOTICE.md  Makefile
├── App/
│   ├── GlassCam.xcodeproj          文件夹同步组，增删文件不改 pbxproj
│   ├── GlassCam/
│   │   ├── UI/                     SwiftUI 视图
│   │   ├── Camera/                 AVFoundation 会话、拍摄驱动、取景帧
│   │   ├── Bench/                  DevicePerformance（GLASSCAM_PERFORMANCE）
│   │   └── Resources/              Info.plist、Localizable.xcstrings、构建时生成的 FFCS/LUMIX
│   └── GlassCamUITests/
├── Packages/GlassCamKit/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── CHNCS/ CFFCS/ CLUMIX/ CF5/      C++：include/ 放 C 头文件，generated/ 放生成的 .inc
│   │   ├── ImagingCore/{Model,Engines,Processing}/
│   │   ├── Capture/
│   │   ├── F5/
│   │   └── Peripheral/
│   ├── NativeTests/                C++ 冒烟和 sanitizer 程序（executable targets）
│   └── Tests/{ImagingCoreTests,CaptureTests,F5Tests,PeripheralTests}/
├── tests/
│   ├── numeric/                    pytest；support/ 放数值参考实现
│   └── fixtures/<主题>/            golden 数据，每个目录一个 README.md
├── vendor/{hncs,ffcs,lumix}/       原 reference/、reference_ffcs/、reference_lumix/
├── scripts/                        构建、发布、资源准备、资产生成
├── tools/{diagnostics,bench}/
└── docs/                           主题文档、adr/、writing-docs.md、testing.md
```

## 验收套件

T00 负责确认这些命令能实际运行，并把最终写法记进附录 A。路径变化后，由改路径的那个任务同步更新本节。

先定义 Python 环境（本机系统 Python 没有 numpy）：

```sh
PY="uv run --no-project --python 3.12 --with-requirements GlassCamPrototype/requirements.txt --with tifffile python -B"
```

| 编号 | 内容 | 命令（重构前路径） |
|---|---|---|
| V1 | Python 全套 | `PYTHONPATH=GlassCamPrototype/tests $PY -m unittest discover -s GlassCamPrototype/tests` |
| V2 | Apple 图像管线、拍摄流程与恢复 | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $PY GlassCamPrototype/tools/test_apple_images.py --raw-source <MAIN_DNG>` |
| V3 | 完整色彩链基线 | `$PY GlassCamPrototype/tools/test_lumix_images.py --test-source GlassCamPrototype/tests/apple_color_chain.swift --output <DIR> --proraw <MAIN_DNG> --proraw <ULTRA_DNG> --proraw <TELE_DNG>` |
| V4 | F5 | `$PY GlassCamPrototype/tools/test_f5.py` |
| V5 | 外围玻璃 | `$PY GlassCamPrototype/tools/test_peripheral_glass.py`，以及 `$PY GlassCamPrototype/tools/test_peripheral_recording.py` |
| V6 | 原生 C++ | `$PY GlassCamPrototype/tools/verify_cpp.py`（macOS 的已知报告错误与可用 golden 入口见附录 A）；`$PY GlassCamPrototype/tools/test_hncs_numpy_rng.py`；`$PY GlassCamPrototype/tools/test_hncs_spatial.py --reference GlassCamPrototype/reference`；`$PY GlassCamPrototype/tools/test_hncs_spatial_sanitizers.py --disable-leak-detection` |
| V7 | 未签名 Release 构建 | `$PY GlassCamPrototype/tools/iphone_release.py --unsigned` |
| V8 | UI 测试（模拟器） | `xcodebuild test -project GlassCamPrototype/ios/GlassCam.xcodeproj -scheme GlassCamCaptureTests -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -parallel-testing-enabled NO -only-testing:GlassCamUITests/CaptureWorkflowUITests/testCapturePriorityMenuAndSpeed12MPOnSimulator -only-testing:GlassCamUITests/CaptureWorkflowUITests/testManualStateRecordsWithoutCameraOnSimulator` |

「与基线一致」是指：通过的检查仍然通过；已知失败的错误信息不变；V3 输出的 HEIF 文件 SHA-256 与附录 A 逐个相同。

## 任务总览

| 任务 | 内容 | 依赖 | 可并行 |
|---|---|---|---|
| T00 | 建立基线 | — | 与 T01 |
| T01 | 清理根目录 | — | 与 T00 |
| T02 | 迁出研究材料 | T00 | — |
| T03 | 清理测试 | T02 | — |
| T04 | 目录重排 | T03 | — |
| T05 | SwiftPM 与 C++ targets | T04 | — |
| T06 | 拆出领域模型，打断循环依赖 | T05 | — |
| T07 | F5 依赖反转 | T06 | — |
| T08 | 外围模块边界 | T07 | — |
| T09 | Swift 代码迁入 package，测试改用 Swift Testing | T08 | — |
| T10 | 拆分大文件 | T09 | — |
| T11 | 重写文档 | T10 | 各主题之间可并行 |
| T12 | 收尾 | T11 | — |
| T13 | 真机验收 | T12 | 只能由用户执行 |

---

## T00 建立基线

**做什么**

1. 从 `main` 建 `refactor` 分支。
2. 向用户要三张 ProRAW DNG（主摄、超广角、长焦）的路径，V2 用主摄那张。拿不到就把 V2 的 `--raw-source` 去掉，在附录 A 注明 V3 不可用。
3. 依次运行 V1–V8，记录每条命令的最终写法、耗时、结果。失败的记录完整错误信息（已知的旧失败示例：「Recovered old Nature capture adopted automatic WB or lost its frozen recipe」）。
4. V3 的输出放到 `~/Library/Developer/GlassCamDiagnostics/refactor-baseline/`，记录其中每个 HEIF 的 SHA-256。
5. 记录 V7 产出的 `.app` 内完整文件清单（`find <app> -type f | sort`），以及 `Resources/FFCS`、`Resources/LUMIX` 下各文件的 SHA-256。保存到同一个基线目录。
6. 把以上内容写进附录 A。

**不做**：不改任何代码。

**验收**：附录 A 已填写完整，后续任务可以直接拿来对比。

## T01 清理根目录

**做什么**

1. 创建 `../GlassCam-archive/`，把根目录下这些未跟踪内容**移动**过去：
   - `GlassCam-records-BC969EDB-….zip`、`GlassCam-records-DA8E5440-….zip`
   - `GlassCam_Research_Handoff_20261022.zip`
   - `GlassCam_Offline_Evidence_20261023/` 和同名 zip
   - `GlassCam_Research_Answer_Q01-Q26_20261023.md`
   - `F5_RAW_Implementation_Package.zip`、`F5_RAW_System_Design_zh.pdf`
   - `tmp/`
2. 先用 `cmp` 确认根目录的 `F5_RAW_System_Design_zh.md` 和 `GlassCamPrototype/reference_f5/F5_RAW_System_Design_zh.md` 完全相同，再 `git rm` 根目录这份。
3. 删除未跟踪的 `.DS_Store` 和 `__pycache__/`。
4. 把 `GlassCamPrototype/.gitignore` 合并进根目录 `.gitignore`（规则改写成相对根目录的路径），然后删除前者。

**验收**：`git status --short` 只剩 `GlassCamPrototype/validation/` 下的未跟踪内容（T02 处理）；V7 通过。

## T02 迁出研究材料

**做什么**

1. `git init ../GlassCam-research`，建立目录 `tools/reverse-engineering/`、`tools/f5/`、`tools/studies/`、`evidence/`、`specs/`、`docs/reports/`。
2. 按附录 C，把标为「研究仓库」的 `tools/` 文件**复制**到研究仓库对应目录，然后在本仓库 `git rm`。
3. 把整个 `GlassCamPrototype/reference_f5/` 移到研究仓库 `specs/f5/`。
4. 处理 `GlassCamPrototype/validation/`：附录 D 列出的文件留在原处（T04 再移到 `tests/fixtures/`）；其余内容，包括所有未跟踪目录，移到研究仓库 `evidence/` 并保持原有相对路径。其中的反编译 C 文件（`lumix-full-proraw-20261026/evidence/*.c`）也一起迁走。
5. 把 `reference_lumix/ANALYSIS.md`、`ANALYSIS_REVIEW.md` 移到研究仓库 `docs/reports/lumix/`。
6. 研究仓库提交一次，提交说明写明来源仓库的 commit；然后把研究仓库的 commit 记到附录 C 末尾。

用户确认的依赖与上游材料补充：

- `hncs_spatial_evidence.py` 暂留主仓库，待 T03/T05 消除 RNG、空间和 sanitizer 三个验收脚本的依赖后迁出，不能在 T02 提前移除。
- 补迁 `reference_ffcs/implementation/tools/` 下的 `extract_reference_luts.py`、`native_probe.cpp`、`verify_native_luts.py`，以及 `reference_ffcs/validation/macho_inventory.json`。研究仓库保留它们的上游相对路径。
- 上游清单对这些迁出文件的校验从原有、哈希固定的 `reference_ffcs/source.zip` 读取；其他文件继续检查工作区内容。保持上游清单和 golden 不变，资源准备脚本不得重新展开已迁出的工具。
- 验收允许规则文档中的命令说明，以及保留的来源元数据中出现原厂路径；不允许主仓库中的代码加载原厂二进制。`reference/work/hncs-pipeline/phocus_presets.json` 和 `evidence/wb_preset_probe.json` 保持原样。

**不做**：文档（`docs/`）留给 T11 处理。附录 C 中标为「保留」的文件不能移走，测试要用它们。

**验收**

- 以下命令只命中 `NOTICE.md`、`vendor` 或 `reference*` 下的 `ORIGIN.md`、`docs/` 下的旧文档，以及上述规则文档和来源元数据：
  `git grep -nE "dlopen|r2ghidra|radare2|Phocus\.app|SILKYPIX8\.framework|SILKYPIX Developer Studio"`
- V1、V2、V4、V5、V6、V7 与基线一致。

## T03 清理测试

**做什么**

1. **先整理不变量清单（附录 B）。** 逐个阅读附录 E 中「删除」类的测试方法。凡是描述**行为**的约定，写成一句可以验证的话，注明来源测试，并预留一列给 T09 填写新的 Swift 测试名。纯实现细节不收录，比如某行代码存在、调用顺序、某个 API 没被使用。至少覆盖以下几类：
   - 配方编解码和旧版本迁移
   - 拍摄流程：授权失败、处理失败、保存失败重试、重启后恢复
   - 相册保存方式：只申请 `.addOnly` 权限、文件复制而不是移动
   - 取景几何：照片区居中、外围四块区域的划分
   - 效果开关的迁移规则
   - HDR 输出：色彩空间和位深
2. **按测试方法删除。** 删除读取 `.swift`、`.cpp`、`.h`、`.metal`、`.sh`、`.pbxproj`、`CMakeLists.txt` 文本并断言内容的方法，以及附录 E 中的镜像模型测试。文件删空了就删文件。
3. **建立 pytest 数值测试**，位置 `GlassCamPrototype/tests/numeric/`：
   - 把附录 E 中「保留」的 Python 测试移进来。unittest 写法可以先不改，pytest 能直接运行。
   - 把附录 C「数值测试支持」的模块移到 `tests/numeric/support/`，并更新所有 import。
   - 把附录 C「转成 pytest 数值测试」中的脚本改写成测试：去掉 argparse 和 JSON 报告输出，保留原有的检查。不能只靠仓库内容运行的脚本，改归研究仓库，并在汇报里列出。
   - 只是编译并运行某个 C++ 程序、再检查退出码的 Python 文件，保留到 T05，由 T05 改成 NativeTests。
   - 在 `requirements.txt` 中加入 `pytest` 和 `tifffile`。

**验收**

- `git grep -nE "read_text\(\)|open\(" GlassCamPrototype/tests` 的结果里，没有任何一处读取的是 Swift 或 C++ 源文件。
- pytest 全部通过。汇报中给出数量：保留了多少项，从 tools 转入了多少项。
- V2、V4、V5、V7 与基线一致。
- 附录 B 已填写。

## T04 目录重排

**做什么**（全部用 `git mv`，保留历史）

| 原路径 | 新路径 |
|---|---|
| `GlassCamPrototype/ios/GlassCam.xcodeproj` | `App/GlassCam.xcodeproj` |
| `GlassCamPrototype/ios/GlassCam/` | `App/GlassCam/`（暂时平铺，T06 再分目录） |
| `GlassCamPrototype/ios/GlassCamUITests/` | `App/GlassCamUITests/` |
| `GlassCamPrototype/core/` | `core/`（暂放，T05 移入 package） |
| `GlassCamPrototype/reference/` | `vendor/hncs/` |
| `GlassCamPrototype/reference_ffcs/` | `vendor/ffcs/` |
| `GlassCamPrototype/reference_lumix/` | `vendor/lumix/` |
| `GlassCamPrototype/tools/` 中保留的文件 | 按附录 C 放进 `scripts/`、`tools/diagnostics/`、`tools/bench/` |
| `GlassCamPrototype/tests/numeric/` | `tests/numeric/` |
| `GlassCamPrototype/tests/*.swift` | `tests/swift-legacy/`（T09 删除） |
| `GlassCamPrototype/tests/*.cpp` | `tests/native-legacy/`（T05 删除） |
| `GlassCamPrototype/tests/fixtures/` 和附录 D 的文件 | `tests/fixtures/<主题>/`，每个目录补一个 `README.md`（来源、生成方式、对应版本） |
| `GlassCamPrototype/docs/writing-docs.md`、`testing.md` | `docs/` |
| `GlassCamPrototype/docs/adr/` | `docs/adr/` |
| `GlassCamPrototype/docs/` 中其余文件，以及 `GlassCamPrototype/README.md`、`ios/README.md`、`core/README.md` | `docs/legacy/`（T11 的素材，T11 结束时清空） |
| `GlassCamPrototype/NOTICE.md` | `NOTICE.md` |
| `GlassCamPrototype/requirements.txt` | `tests/numeric/requirements.txt` |

还要做：

1. 更新所有路径引用：pbxproj 的构建脚本阶段、`HEADER_SEARCH_PATHS`、bridging header 路径，以及各脚本、测试、`AGENTS.md`、`CLAUDE.md`、根目录 README 里的命令，还有本文件的「验收套件」。
2. 把 Xcode 工程改用文件夹同步组（`PBXFileSystemSynchronizedRootGroup`），覆盖 `App/GlassCam/` 和 `App/GlassCamUITests/`。`Info.plist`、bridging header 不能被当成资源打包。如果手工修改 pbxproj 无法可靠完成，停下来汇报，由用户在 Xcode 里操作。

**验收**

- `GlassCamPrototype/` 已不存在。
- V2、V4、V5、V6、V7、V8 和 pytest 与基线一致。
- V7 产出的 `.app` 文件清单和资源哈希与附录 A 相同。
- 任选 3 个移动过的文件执行 `git log --follow`，能追溯到移动前的历史。

## T05 SwiftPM 与 C++ targets

**做什么**

1. 新建 `Packages/GlassCamKit/Package.swift`。平台为 iOS 27 和 macOS 27；Swift target 一律用 Swift 5 语言模式；`cxxLanguageStandard: .cxx17`。
2. 建四个 C target，编译参数按「执行规则」第 2 条，通过 `cxxSettings` 的 `unsafeFlags` 设置；链接 `z`，需要的 target 链接 pthread：
   - `CHNCS`：`hncs.cpp`、`hncs_spatial.cpp`、`hncs_numpy_rng.cpp`，以及相关头文件；生成的 `hncs_*.inc` 放进 `generated/`
   - `CFFCS`：`ffcs.cpp`
   - `CLUMIX`：`lumix.cpp`
   - `CF5`：`f5_math.cpp`、`f5_registration.cpp`、`f5_quality.cpp`、`f5_c.cpp`
   - `ffcs_v020_loader.cpp`、`ffcs_v020_native.cpp`、`hncs_cli.cpp` 目前不在 Xcode 工程里。先查清用途：有测试使用的，放进测试支持 target；否则移到研究仓库。
   - 生成脚本 `core/generate_assets.py`、`core/generate_preset_assets.py` 移到 `scripts/`；它们的输入文件（如 `hncs_preset_catalog.json`）和脚本放在一起。
3. 提供一个动态库 product `GlassCamNative`（包含四个 C target），供 Python 测试加载。测试专用的 C++ 桥（`x2d_hdr_post_model_bridge.cpp`、`hncs_numpy_rng_bridge.cpp` 等）另外打成一个测试支持用的动态库 product。
4. `tests/native-legacy/` 和 `core/` 里的冒烟程序（`hncs_smoke.cpp`、`ffcs_smoke.cpp`、`*_sanitizer.cpp`、`*_test.cpp`、`f5_core_tests.cpp` 等）改成 `NativeTests/<名称>/` 下的 executable target。T03 留下的「只编译并运行 C++ 程序」的 Python 包装一并删除。
5. App 改为依赖本地 package：Swift 文件改成 `import CHNCS` 等；删除 bridging header，以及 pbxproj 中的 C++ 源文件条目和 `COMPILER_FLAGS`。
6. pytest 的 `conftest.py` 先执行 `swift build -c release --package-path Packages/GlassCamKit --product GlassCamNative`，再从 `.build` 目录加载动态库。删除所有 Python 脚本里自行调用 `clang++` 的代码。
7. `tests/swift-legacy/` 现有的 runner（V2–V5）改为链接 SwiftPM 构建出的库，不再自己编译 C++。
8. 删除 `core/CMakeLists.txt`、`core/ffcs.cmake`，以及空的 `core/` 目录。
9. 新建 `Makefile`，提供三个目标：
   - `make native`
   - `make test-native`：运行冒烟程序；再用 `swift build --sanitize=address --sanitize=undefined` 构建后运行一遍
   - `make test-numeric`

**验收**

- `git grep -nE "clang\+\+|xcrun clang"` 在 `scripts/`、`tests/`、`tools/` 中没有命中。
- C++ 编译参数只出现在 `Package.swift` 一处。
- 数值 golden 全部逐值通过；`make test-native` 通过；V2–V8 与基线一致；V3 的 HEIF 哈希与附录 A 相同。

## T06 拆出领域模型，打断循环依赖

**做什么**

1. 按附录 F 的归属表，把 `App/GlassCam/` 下的 Swift 文件移进对应的层目录（这一步只移动，不改内容）。把附录 F 中的检查脚本保存为 `scripts/check_layers.py`，运行一次，记下当前违规清单。
2. 从 `ImagePipeline.swift` 中拆出这些类型，移到 `ImagingCore/Model/`：`RAWInputPolicy`、`RAWDecodeRecipe`、`ColorMode`、`EffectToggles`、`FFCSCameraFamily`、`FFCSSettings`、`ProcessingRecipe`、`PipelineError`。同一文件里的 `HNCSPresetWorkFile` 被 `HNCSEngine` 使用，移到 `ImagingCore/Engines/`。
3. `SourceImageStore` 改为不依赖 Processing 层：`PipelineError` 已移入 Model，或者给它单独定义错误类型。
4. 资源目录改为注入：`FFCSEngine`、`LUMIXEngine`、`LiveColorProxy` 不再读取 `Bundle.main.resourceURL`，由调用方传入目录 URL；App 启动时传入 `Bundle.main` 的资源目录。
5. 修复 Model、Engines、Processing 三层的其余违规。

**验收**

- `scripts/check_layers.py` 报出的违规只剩两类：目标层是 F5 的（留给 T07），以及涉及 Peripheral 的（留给 T08）。
- V2、V3、V7 与基线一致。

## T07 F5 依赖反转

当前 F5 被下层直接引用的情况（按附录 F 的分层，用 `scripts/check_layers.py` 实测）：
- `CaptureGeometry` → `F5BurstSource`
- `CaptureJournal` → `F5ArchiveStore`、`F5BurstManifest`、`F5BurstSource`、`F5BurstTransaction`、`F5Failure`、`F5Hash`
- `CaptureWorkflow` → `F5BurstSource`、`F5CaptureProvenance`、`F5Failure`、`F5ImagePipeline`
- `ImagePipeline` → `F5Failure`、`F5LinearImage`

**做什么**

1. **先冻结持久化格式。** 动代码之前，用当前代码生成拍摄记录的 JSON fixture，至少覆盖三种：单张照片、F5 五帧连拍、旧的 Speed 档位。存进 `tests/fixtures/journal/`，并补上 README。
2. 在 Capture 和 Processing 层定义扩展点（例如连拍载荷协议、通用的线性图像类型、错误类型），由 F5 实现并注册。具体设计由执行者决定，但必须满足：Capture 和 ImagingCore 不再引用任何 F5 类型。
3. JSON 格式不变：旧 fixture 能正确解码；解码后再编码，得到的字节与原文件相同。

**验收**

- `scripts/check_layers.py` 中不再有目标层为 F5 的违规。
- 上述 fixture 测试通过；V2、V4 与基线一致。

## T08 外围模块边界

当前存在的跨层引用：
- `PeripheralAlignment` → `CameraFrameDelivery`（App/Camera 层的 AVFoundation delegate 类）
- `CameraFrameDelivery` → `LiveCameraFrameSource`（定义在 `LiveColorProxy.swift`）

**做什么**

1. Peripheral 层定义自己的取景帧输入抽象（协议或值类型），由 `CameraFrameDelivery` 适配。
2. `LiveCameraFrame`、`LiveCameraFrameSource` 移到 Peripheral 层，或移到 Peripheral 可以依赖的层。
3. `CameraFraming` 移到 Peripheral 层。

**验收**：`scripts/check_layers.py` 零违规；V5、V7 与基线一致。

## T09 Swift 代码迁入 package，测试改用 Swift Testing

**做什么**

1. **建 Swift target。** 在 GlassCamKit 中新建 `ImagingCore`、`Capture`、`F5`、`Peripheral` 四个 Swift target，按附录 F 移入文件，App 依赖它们。
   - 包内跨 target 使用的声明用 `package` 访问级别；只有 App 直接用到的才标 `public`。
   - 包内代码的本地化字符串仍然要从主 bundle 查找，中英文显示保持不变。
2. **F5 着色器。** `F5Kernels.metal` 移到 F5 target 下，作为 `.copy` 资源，供测试走「从源码编译」路径（`fastMathEnabled = false`）。App target 额外引用同一个文件，以 `-fno-fast-math` 预编译进 App 的默认库，App 继续走 `makeDefaultLibrary()` 路径。不要把 App 改成运行时编译。
3. **改写测试。** 按 `docs/testing.md` 把 `tests/swift-legacy/` 改写成 Swift Testing：一个测试一个行为、用 `#expect`、能参数化的参数化；去掉 `fatalError` 断言和 `sleep` 轮询。归属如下：

   | 原文件 | 新位置 |
   |---|---|
   | `apple_image_pipeline.swift`、`apple_ci_strip_roundtrip.swift`、`apple_lumix_pipeline.swift` | `ImagingCoreTests` |
   | `apple_color_chain.swift` | `ImagingCoreTests` 的基线测试；需要环境变量 `GLASSCAM_DNG_DIR`，没有就跳过 |
   | `apple_capture_workflow.swift`、`apple_capture_recovery.swift` | `CaptureTests` |
   | `apple_f5_contracts.swift`、`apple_f5_metal.swift`、`F5Fixtures.swift` | `F5Tests` |
   | `apple_peripheral_glass.swift`、`apple_peripheral_timing.swift`、`apple_peripheral_recording.swift` | `PeripheralTests` |

4. **补测试。** 为附录 B 中的每条不变量写 Swift 测试，并把测试名填回附录 B。
5. **测试资源。** `make test-swift` 先用 `scripts/prepare_*` 把 FFCS / LUMIX 资源准备到 `.build/test-resources/`，再通过环境变量把路径传给测试。
6. **删除旧文件。** 删除 `tests/swift-legacy/`、`scripts/check_layers.py`，以及附录 C 中标为「T09 删除」的 runner 脚本。
7. **更新 Makefile**：
   - `make test` = `test-native` + `test-numeric` + `test-swift`
   - `make test-baseline`
   - `make test-ui`

**验收**

- `make test` 通过。
- 汇报中附一张对照表：旧 harness 里的每组检查，分别由哪个新测试覆盖。
- `make test-baseline` 输出的 HEIF 哈希与附录 A 相同。
- V7、V8 通过。
- 测试代码中不再有 `fatalError(`；任何 `sleep` 都必须带注释说明为什么必须使用真实时间。

## T10 拆分大文件

**做什么**：只做移动和提取，不改逻辑。单个文件原则上不超过 500 行。

| 文件 | 拆分方向 |
|---|---|
| `CameraController.swift`（1616 行） | 会话配置、镜头与变焦、ProRAW 拍摄、F5 拍摄、取景帧接线 |
| `CameraView.swift`（1088 行） | 每个私有类型单独一个文件：取景布局、照片边框和网格、设置页、风格选择、回看 |
| `PeripheralAlignment.swift`（1459 行） | 元数据/标定/运动、帧来源与同步器、对齐 worker、诊断记录器 |
| `LiveColorProxy.swift`（714 行） | 配方、帧处理器、渲染视图 |
| `ImagePipeline.swift`（剩余部分） | RAW 解码、渲染、分条导出、HDR 编码 |

App 内的文件放进 `UI/`、`Camera/`、`Bench/`。

**验收**：`make test`、V7、V8 通过。用 `git diff -M --color-moved` 检查，除了声明和访问级别的调整之外，代码都只是移动。

## T11 重写文档（各主题可以并行）

每个主题交给一个 agent，素材见附录 G。

**做什么**

1. 以代码为准，按 `docs/writing-docs.md` 的模板写主题文档。旧文档只用来提取三样东西：设计参数、决定的理由、已知限制。
2. 不变量要引用实际存在的测试名（来自附录 B 和 T09）。
3. 写完一个主题，就把对应的旧文档移到研究仓库 `docs/reports/`。
4. 最后一个 agent 负责以下几项：
   - 把 `DECISIONS.md` 中仍然有效的条目转成 ADR（从 0003 开始编号）
   - 重写 `README.md`
   - 新建 `CHANGELOG.md`：根据 git log 和旧 README 中的「最新」段落整理，每个变化一行
   - 更新 `docs/testing.md` 里的运行命令

**验收**

- `docs/legacy/` 已清空并删除。
- `grep -rnE "/Users/|\.codex|最新|本轮|未安装|待验收" docs README.md CHANGELOG.md` 无命中。
- 每篇主题文档都有「不变量」「已知限制」「代码入口」三节；不变量引用的测试名都能在代码中找到。
- 所有 Markdown 相对链接的目标都存在（用脚本检查）。

## T12 收尾

1. 从 `AGENTS.md` 删除「正在按 REFACTOR_PLAN.md 重构」那一行，并核对其中的路径。
2. 删除本文件。
3. 运行 `make test` 和 V7，向用户汇报最终状态。

## T13 真机验收（只能由用户执行）

对照清单逐项实拍检查：
- 三摄 × 三种色彩引擎拍摄并保存到相册
- F5 五帧连拍
- 外围玻璃
- 重构前保存的待完成照片能否恢复
- 分享
- 中英文界面

---

## 附录 A：基线（T00 填写）

源提交为 `380abd47ae299ac353039fe942e66fe15edc3278`。执行环境为 macOS 27.2 arm64、Xcode 27.0（27A266a）、Apple Swift 6.4、Python 3.12、NumPy 2.5.4、SciPy 1.18.1。下面命令使用 bash；系统默认开发目录是 Command Line Tools，因此全部显式设置 `DEVELOPER_DIR`。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PYTHONPATH=GlassCamPrototype/tests
PY="uv run --no-project --python 3.12 --with-requirements GlassCamPrototype/requirements.txt --with tifffile python -B"
BASELINE_DIR="$HOME/Library/Developer/GlassCamDiagnostics/refactor-baseline"
```

每次命令的完整参数、退出码和墙钟耗时保存在基线目录的 `results.json`；完整 stdout/stderr 保存在下表对应的日志。后续任务使用另一个输出目录，保留基线目录和已有 `.xcresult`。

| 编号 | 实际命令 | 耗时 | 结果 | 已知失败（原文） |
|---|---|---|---|---|
| V1 | `$PY -m unittest discover -s GlassCamPrototype/tests` | 33.811 s | 223 项通过；`V1.log` | 无 |
| V2 | `$PY GlassCamPrototype/tools/test_apple_images.py` | 38.173 s | 通过；`V2.log`；包括配方、几何、拍摄恢复、HEIF/HDR、分享 | 无；未出现计划举例的旧 Nature 恢复错误 |
| V3 | 未运行 | — | 用户未提供三摄 ProRAW DNG；完整色彩链基线及 HEIF 哈希不可用 | 无输入 |
| V4 | `$PY GlassCamPrototype/tools/test_f5.py --work "$BASELINE_DIR/f5"` | 37.422 s | 核心数值、Metal、契约/管线通过；`V4.log` 及 `f5/*.log` | 无 |
| V5 玻璃 | `$PY GlassCamPrototype/tools/test_peripheral_glass.py` | 20.699 s | 通过；`V5-glass.log` | 无 |
| V5 记录 | `$PY GlassCamPrototype/tools/test_peripheral_recording.py` | 14.302 s | 通过；`V5-recording.log` | 无 |
| V6 原始入口 | `$PY GlassCamPrototype/tools/verify_cpp.py` | 10.810 s | 退出 1；数值检查和 benchmark 返回后，报告环境采集失败；完整 traceback 在 `V6-cpp.log` | `FileNotFoundError: [Errno 2] No such file or directory: '/proc/cpuinfo'` |
| V6 golden 入口 | 见下方直接调用既有检查的命令 | 1.540 s | 52 组 golden、892080 个随机/边界通道比较通过；`V6-cpp-goldens.log` | 无 |
| V6 RNG | `$PY GlassCamPrototype/tools/test_hncs_numpy_rng.py` | 1.006 s | 通过，bit mismatches 为 0；`V6-rng.log` | 无 |
| V6 空间 | `$PY GlassCamPrototype/tools/test_hncs_spatial.py --reference GlassCamPrototype/reference` | 3.917 s | 322 个案例通过，float32/u16 mismatches 为 0；`V6-spatial.log` | 无 |
| V6 sanitizer 原始入口 | `$PY GlassCamPrototype/tools/test_hncs_spatial_sanitizers.py` | 1.697 s | 退出 1，子进程 SIGABRT；`V6-sanitizers.log` | `AddressSanitizer: detect_leaks is not supported on this platform.` |
| V6 sanitizer 可用入口 | `$PY GlassCamPrototype/tools/test_hncs_spatial_sanitizers.py --disable-leak-detection` | 1.885 s | AddressSanitizer / UBSan 通过；`V6-sanitizers-no-leaks.log` | macOS 不运行 LeakSanitizer |
| V7 | `$PY GlassCamPrototype/tools/iphone_release.py --unsigned --output "$BASELINE_DIR/release"` | 30.098 s | 未签名 Release 构建通过；`V7.log`、`release/release-build.log` | 无 |
| V8 原始 scheme | `xcodebuild test -project GlassCamPrototype/ios/GlassCam.xcodeproj -scheme GlassCam -destination 'platform=iOS Simulator,id=4B643785-C6D2-402D-AB5A-753CCD96BA0D' -derivedDataPath "$BASELINE_DIR/simulator" -resultBundlePath "$BASELINE_DIR/ui-tests.xcresult"` | 0.682 s | 退出 66；`V8.log` | `xcodebuild: error: Scheme GlassCam is not currently configured for the test action.` |
| V8 模拟器用例 | 见下方 `GlassCamCaptureTests` 命令 | 127.132 s | 退出 65；2 项执行，1 项通过、1 项失败；`V8-simulator.log`、`ui-simulator.xcresult` | `testCapturePriorityMenuAndSpeed12MPOnSimulator` 在 `CaptureWorkflowUITests.swift:27`：`XCTAssertTrue failed`，找不到 `camera.quality.speed` |

V6 golden 命令直接调用已有检查函数，不修改产品或测试源码，也不执行报告环境采集：

```bash
$PY -c 'import json, sys; sys.path.insert(0, "GlassCamPrototype/tools"); import verify_cpp; print(json.dumps(verify_cpp.verify(verify_cpp.library()), indent=2))'
```

默认 sanitizer 脚本捕获了子进程 stderr，但没有打印。补充执行使用 `runpy.run_path` 调用原脚本，在捕获 `subprocess.CalledProcessError` 后打印其 stdout/stderr 并重新抛出；耗时 2.022 s，完整命令及原始错误在 `results.json`、`V6-sanitizers-stderr.log`。关闭 leak detection 采用脚本已有参数；脚本输出中关于 ptrace 的说明不适用于本机，实际原因是上述平台不支持错误。

V8 只运行两个显式用于模拟器的方法；`testManualStateRecordsWithoutCameraOnSimulator` 通过，拍摄优先级菜单用例失败。完整断言及辅助功能树保存在 `V8-simulator.log` 和 `ui-simulator.xcresult`。测试结束时 Xcode 另报告 `Failure collecting diagnostics from simulator: Process exited with error 72` 和 `xcrun: error: unable to find utility "simctl", not a developer tool or in PATH`，未改动系统 `xcode-select` 配置。

```bash
xcodebuild test -project GlassCamPrototype/ios/GlassCam.xcodeproj \
  -scheme GlassCamCaptureTests \
  -destination 'platform=iOS Simulator,id=4B643785-C6D2-402D-AB5A-753CCD96BA0D' \
  -parallel-testing-enabled NO \
  -only-testing:GlassCamUITests/CaptureWorkflowUITests/testCapturePriorityMenuAndSpeed12MPOnSimulator \
  -only-testing:GlassCamUITests/CaptureWorkflowUITests/testManualStateRecordsWithoutCameraOnSimulator \
  -derivedDataPath "$BASELINE_DIR/simulator" \
  -resultBundlePath "$BASELINE_DIR/ui-simulator.xcresult"
```

基线产物位于 `~/Library/Developer/GlassCamDiagnostics/refactor-baseline/`：

- `release/Build/Products/Release-iphoneos/GlassCam.app/`：未签名 App。
- `app-files.txt`：App 的完整文件路径清单；`app-files-relative.txt`：相对 App 根目录的清单，共 92 个文件，供目录迁移后比较。
- `resource-sha256.txt`：App 内 `FFCS/`、`LUMIX/` 的逐文件 SHA-256，共 87 项。打包后的资源位于 App 根目录，没有额外的 `Resources/` 层。
- V3 未生成任何 HEIF，也没有 HEIF SHA-256 基线；后续不能据此宣称完整三摄色彩链字节一致。

## 附录 B：不变量清单（T03 填写，T09 补测试名）

| # | 不变量 | 来源测试 | 新测试（T09） |
|---|---|---|---|

## 附录 C：`tools/` 文件归属

共 158 个文件，每个文件都已归类。

**保留：scripts/（构建、资源准备、资产生成）**（8）：`ffcs_native_SHA256SUMS`、`generate_hncs_spatial_assets.py`、`generate_hncs_whitepoint_assets.py`、`iphone_release.py`、`materialize_ffcs_reference.py`、`phocus_sharpness_settings.py`（被 `generate_hncs_spatial_assets.py` 引用）、`prepare_ffcs_resources.sh`、`prepare_lumix_resources.py`

**保留：数值测试支持，移到 tests/numeric/support/**（5）：`phocus_binary_reference.py`、`reference_runtime.py`、`verify_effect_toggle_hncs.py`、`verify_ffcs.py`、`verify_ffcs_v020.py`

`verify_ffcs_v020.py` 从 `materialize_ffcs_reference.py` 导入归档哈希校验与四项研究文件清单；T03/T04 移动模块时须保留此依赖。清单中的四项从固定哈希归档读取，其他上游文件继续检查工作区内容。

**保留：测试专用 C++ 桥，T05 放进测试支持 target**（1）：`x2d_hdr_post_model_bridge.cpp`

**转成 pytest 数值测试（T03）**（10）：`test_hncs_numpy_rng.py`、`test_hncs_spatial.py`、`verify_cpp.py`、`verify_ffcs_effect_switches.py`、`verify_ffcs_strips.py`、`verify_hncs_revision8.py`、`verify_hncs_revision8_live.py`、`verify_linear_export.py`、`verify_lumix.py`、`verify_parallel_linear.py`。不能只靠仓库内容运行的，改归研究仓库 `tools/studies/`。

**T05 删除**（1）：`test_hncs_spatial_sanitizers.py`，改由 `make test-native` 的 sanitizer 构建覆盖。

**暂留至依赖解除后迁出**（1）：`hncs_spatial_evidence.py`。T03 改写 RNG、空间数值测试后移除相应依赖；T05 删除 sanitizer runner 后，把该文件迁到研究仓库 `tools/studies/`。

**T09 删除**（5）：`test_apple_images.py`、`test_f5.py`、`test_lumix_images.py`、`test_peripheral_glass.py`、`test_peripheral_recording.py`

**保留：tools/diagnostics/**（10）：`analyze_peripheral_records.py`、`inspect_proraw_profile.py`、`pull_peripheral_records.py`、`render_preview.py`、`replay_peripheral_native.py`、`replay_peripheral_native.swift`、`replay_peripheral_records.swift`、`replay_peripheral_stability.py`、`replay_peripheral_stability.swift`、`replay_peripheral_transitions.swift`

**保留：tools/bench/**（9）：`benchmark_current_pipeline.py`、`benchmark_ffcs.py`、`benchmark_lowres_color.cpp`、`benchmark_lowres_color.py`、`benchmark_optimized.py`、`profile_ffcs.cpp`、`profile_hncs.cpp`、`run_device_performance.py`、`summarize_device_performance.py`

**研究仓库 tools/reverse-engineering/：直接或间接依赖原厂二进制**（49）：`apple_color_performance.swift`、`audit_ffcs_original.py`、`audit_phocus_binaries.py`、`audit_phocus_input_spatial.py`、`audit_phocus_post_stages.py`、`audit_phocus_raw_contract.py`、`audit_phocus_sharpness_settings.py`、`audit_phocus_white_balance.py`、`audit_x2d_hdr_gradation.py`、`audit_x2d_identity.py`、`benchmark_ffcs_cache.py`、`collect_phocus_validation.py`、`compare_hdr_images.swift`、`compare_x2d_crops.py`、`decompile_ffcs_stages.py`、`decompile_phocus.py`、`decompile_x2d_pipeline.py`、`diagnose_metal_hdr_export.py`、`extract_lumix_assets.py`、`extract_lumix_pipeline.py`、`extract_lumix_reference.cpp`、`hdr_image_metrics.cpp`、`hdr_image_metrics.h`、`measure_source_acceleration.py`、`metal_hncs_source_bridge.mm`、`native_ffcs_audit.cpp`、`native_phocus_filters_bridge.cpp`、`native_x2d_hdr_bridge.cpp`、`native_x2d_pipeline_bridge.cpp`、`phocus_sharpness_model_bridge.cpp`、`phocus_sharpness_reference.py`、`phocus_sharpness_vectors.py`、`probe_coreml_source_matrix.py`、`probe_lumix_pipeline.cpp`、`probe_x2d_native_pipeline.py`、`report_phocus_reference.py`、`run_color_performance.py`、`run_metal_performance.py`、`run_x2d_export_audit.py`、`verify_ffcs_header_matrix.py`、`verify_ffcs_strict_cache.py`、`verify_lumix_pipeline.py`、`verify_phocus_chain.py`、`verify_phocus_sharpness.py`、`verify_phocus_spatial_integration.py`、`verify_x2d_color_gain.py`、`verify_x2d_hdr.py`、`verify_x2d_hdr_chain.py`、`verify_x2d_hdr_post.py`

**研究仓库 tools/f5/**（32）：`F5DesktopQualityMain.swift`、`F5GaussianAuditMain.swift`、`F5LocalDenoiseMain.swift`、`F5OfflineMain.swift`、`build_f5_sdk_oracle.py`、`f5_burst_denoise_control.py`、`f5_calibration.py`、`f5_design_review_report.py`、`f5_device_audit.py`、`f5_diagnostic_truth.py`、`f5_external_baseline.py`、`f5_family_diagnostic.py`、`f5_frozen_reference.py`、`f5_initializer_report.py`、`f5_linear_fusion.py`、`f5_local_dct.py`、`f5_local_quality_report.py`、`f5_local_registration.py`、`f5_lucky_baseline.py`、`f5_natural_benchmark.py`、`f5_offline.py`、`f5_quality_benchmark.py`、`f5_quality_report.py`、`f5_real_quality.py`、`f5_residual_audit.py`、`f5_sampling_audit.py`、`f5_scale_diagnostic.py`、`f5_sdk_color_oracle.cpp`、`f5_temporal_guide.py`、`f5_unit_diagnostic.py`、`test_f5_initializer.py`、`test_f5_local.py`

**研究仓库 tools/studies/**（27，另有 1 个文件暂留至依赖解除）：`apple_hncs_study.swift`、`apple_raw_input_study.swift`、`device_neural_study/`（8 个文件）、`ffcs_stage_profile/`（5 个文件）、`ffcs_v020_live_study.py`、`ffcs_xh2s_SHA256SUMS`、`lut_proxy_bake.py`、`lut_proxy_default_kelvin.py`、`lut_proxy_oracle.cpp`、`lut_proxy_study.py`、`lut_proxy_verify.py`、`nature_white_balance_study.swift`、`report_raw_input_study.py`、`research_apple_acceleration.py`、`run_hncs_study.py`、`verify_ffcs_v020_benchmark.py`

**补迁上游材料**：`reference_ffcs/implementation/tools/` 下的三个文件和 `reference_ffcs/validation/macho_inventory.json`，在研究仓库按 `upstream/ffcs/` 下的原有相对路径保存。

研究仓库 commit（T02）：`799f5a6a560a7be4c3a520b0f5359a9e1758a53b`，来源主仓库 `77d2507fd61b647e8567d99a5b46112975d10039`。

## 附录 D：`validation/` 中保留的 golden

这些文件保留在主仓库，T04 移到 `tests/fixtures/`；其余全部迁到研究仓库。移动之后运行测试，缺哪个补哪个，并更新这份清单。

- `ffcs-v020-stage-goldens.json`、`ffcs-v020-native.json`、`ffcs-effect-defaults-before.json`（仅当引用它的测试方法在 T03 后仍然保留）
- `phocus-native-chain-goldens.json`、`phocus-native-chain-vectors.npz`
- `x2d-hdr-goldens.json`、`x2d-hdr-vectors.npz`
- `x2d-hdr-gradation-goldens.json`、`x2d-hdr-gradation-goldens.npz`
- `x2d-hdr-post-goldens.json`、`x2d-hdr-post-goldens.npz`
- `x2d-hdr-sharpness-goldens.json`、`x2d-hdr-sharpness-goldens.npz`
- `x2d-native-gain-goldens.json`、`x2d-native-gain-vectors.npz`
- `lumix-full-proraw-20261026/native-full-vectors.zip`
- `lumix-integration-20261026/native-vectors/`（被 `verify_lumix.py` 使用）
- `ffcs_mobile_stage_goldens.json`（如果仍被引用）

## 附录 E：`tests/` 的处理

**删除：读源码文本的测试**（15 个文件，139 项）。以方法为单位判断，执行代码的方法保留。
`test_camera_chrome_source.py`、`test_camera_geometry.py`、`test_camera_source.py`、`test_effect_toggle_source.py`、`test_ffcs_v020_contracts.py`、`test_ffcs_v020_resources.py`、`test_full_resolution_export_source.py`、`test_heif_source.py`、`test_hncs_revision8_source.py`、`test_hncs_revision8_spatial_integration.py`、`test_live_proxy_source.py`、`test_precision_preview_source.py`、`test_save_recovery_source.py`、`test_share_delivery.py`、`test_single_camera_capture_source.py`

**删除：Python 镜像模型**（3 个文件，35 项，外加一个模型文件）。其中关于配方迁移和几何的约定必须收进附录 B。
`test_effect_toggle_models.py`、`test_hncs_revision8_capture_recipe.py`、`test_hncs_revision8_geometry.py`、`capture_lifecycle_model.py`，以及 `test_camera_geometry.py` 中的模型部分

**保留：数值测试，移到 tests/numeric/**（14 个文件）
`test_automatic_white_balance.py`、`test_effect_toggle_native.py`、`test_ffcs_color_only.py`、`test_ffcs_effect_switches.py`、`test_ffcs_source.py`、`test_hncs_hdr_domain.py`、`test_hncs_parallel_stages.py`、`test_hncs_revision8_reference_contracts.py`、`test_lumix_iphone.py`、`test_phocus_native_chain.py`、`test_reference.py`、`test_x2d_hdr.py`、`test_x2d_hdr_post.py`、`test_x2d_native_gain.py`

**保留，T09 改写**：全部 `apple_*.swift` 和 `F5Fixtures.swift`

**保留，T05 改成 NativeTests**：全部 `*.cpp`。其中 `hncs_numpy_rng_bridge.cpp` 放进测试支持动态库。

**保留**：`fixtures/`

## 附录 F：Swift 文件分层

| 层（目录） | 文件 | 允许依赖 |
|---|---|---|
| `ImagingCore/Model` | `ExportSettings`、`CaptureGeometry`，以及从 `ImagePipeline` 拆出的类型（见 T06） | 无 |
| `ImagingCore/Engines` | `HNCSEngine`、`FFCSEngine`、`LUMIXEngine`、`PhotoWhiteBalance` | Model |
| `ImagingCore/Processing` | `ImagePipeline`（剩余部分）、`PreviewRaster`、`SourceImageStore`、`ShareDelivery` | Model、Engines |
| `Capture` | `CaptureWorkflow`、`CaptureJournal`、`CameraSettingsStore`、`CameraSessionRecovery` | ImagingCore |
| `F5` | `F5BurstStore`、`F5ColorBridge`、`F5Errors`、`F5ImagePipeline`、`F5LocalDenoise`、`F5Metal`、`F5MetalOutput`、`F5MetalRuntime`、`F5MetalSolver`、`F5Models`、`F5RAW`、`F5Reconstruction`、`F5Kernels.metal` | ImagingCore、Capture |
| `Peripheral` | `PeripheralAlignment`、`PeripheralDenseRefinement`、`PeripheralGlassPolicy`、`PeripheralGlassShader`、`PeripheralLiveDisplay`、`PeripheralStateRecording`、`PeripheralVisibleSeam`、`CameraFraming` | Model |
| `Camera`（App） | `CameraController`、`CameraFrameDelivery`、`F5CaptureDriver`、`LiveColorProxy` | 以上全部 |
| `UI`（App） | `GlassCamApp`、`ContentView`、`CameraView`、`CameraDesign`、`F5SettingsCard`、`PeripheralGlassView`、`PeripheralRecordingControls`、`PrecisionPreview`、`HEIFSaveDelivery` | 以上全部 |
| `Bench`（App） | `DevicePerformance` | 以上全部 |

T06–T08 期间使用的检查脚本，保存为 `scripts/check_layers.py`，T09 删除：

```python
#!/usr/bin/env python3
"""Temporary layer check for App/GlassCam Swift files (T06–T08 only)."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1] / 'App/GlassCam'
ALLOWED = {
    'ImagingCore/Model': set(),
    'ImagingCore/Engines': {'ImagingCore/Model'},
    'ImagingCore/Processing': {'ImagingCore/Model', 'ImagingCore/Engines'},
    'Capture': {'ImagingCore/Model', 'ImagingCore/Engines', 'ImagingCore/Processing'},
    'F5': {'ImagingCore/Model', 'ImagingCore/Engines', 'ImagingCore/Processing', 'Capture'},
    'Peripheral': {'ImagingCore/Model'},
}
APP_LAYERS = ('Camera', 'UI', 'Bench')
DECLARATION = re.compile(
    r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|final|nonisolated)\s+)*'
    r'(?:class|struct|enum|actor|protocol|typealias)\s+([A-Z]\w*)', re.M)


def layer(path):
    relative = path.relative_to(ROOT).as_posix()
    for name in (*ALLOWED, *APP_LAYERS):
        if relative.startswith(name + '/'):
            return name
    return None


files = sorted(ROOT.rglob('*.swift'))
owner = {}
for path in files:
    for name in DECLARATION.findall(path.read_text()):
        owner.setdefault(name, path)

violations = 0
for path in files:
    source = layer(path)
    if source not in ALLOWED:
        continue
    text = re.sub(r'//[^\n]*', '', path.read_text())
    for name in sorted(set(re.findall(r'\b[A-Z]\w*\b', text))):
        target_path = owner.get(name)
        if target_path is None or target_path == path:
            continue
        target = layer(target_path)
        if target != source and target not in ALLOWED[source]:
            violations += 1
            print(f'{path.relative_to(ROOT)} -> {name} ({target})')
sys.exit(1 if violations else 0)
```

## 附录 G：文档主题与素材

旧文档在 T04 之后位于 `docs/legacy/`。标「逆向」的文档只提取结论，原文直接移到研究仓库。

| 新文档 | 素材 |
|---|---|
| `docs/architecture.md` | `DESIGN.md`、`REQUIREMENTS.md`、`IPHONE_FIRST_USABLE_20261018.md`、旧 `GlassCamPrototype/README.md`、旧 `core/README.md` |
| `docs/capture-and-recovery.md` | `AUTOMATIC_CAPTURE.md`、`DELIVERY_AND_RECOVERY.md`、`camera-capture.md`、`CAPTURE_PRIORITY_20261026.md`、`RAW_CAPTURE_OPTIONS_20261026.md`、`SINGLE_CAMERA.md`、`CAPTURE_SESSION_HANDOFF.md`、`METADATA_FAILURE_20261019.md`、`adr/0001`、`adr/0002` |
| `docs/raw-decode-and-export.md` | `HDR_EXPORT.md`、`FULL_RESOLUTION_EXPORT.md`、`COLOR_CHAIN_AUDIT_20261028.md`、`COLOR_INPUT_REPAIR_20261028.md`、`RAW_INPUT_STUDY_20261017.md`、`AUTOMATIC_WHITE_BALANCE.md`、`EXACT_FLOAT_PARALLEL.md`、`EFFECT_TOGGLES.md`、`COLOR_PERFORMANCE.md`、`COLOR_PERFORMANCE_20261018.md`、`HARDWARE_PERFORMANCE.md`、`IPHONE_PERFORMANCE_20261018.md`、`apple_precision_acceleration.md`、`IPHONE_NEURAL_ACCELERATION_20261018.md` |
| `docs/viewfinder.md` | `UI_REDESIGN_20261019.md`、`CLEAR_GLASS_UI.md`、`LIVE_COLOR_PROXY.md`、`LIVE_COLOR_PROXY_PLAN.md`、`gpu-preview-design.md`、`lut-proxy-preview.md`、`HIGH_PRECISION_PREVIEW.md`、`LOWRES_COLOR_PERFORMANCE.md` |
| `docs/peripheral-glass.md` | `PERIPHERAL_MATCHING_RESEARCH_20261022.md`、`PERIPHERAL_RESEARCH_IMPLEMENTATION_20261023.md`、`PERIPHERAL_STABILITY_20261022.md`、`FIELD_REPAIR_IMPLEMENTATION_20261023.md`、`MOTION_INSTABILITY_20261022.md`、`SYNC_AND_STABILITY_ROOT_CAUSE_20261025.md`、`TRANSPARENCY_REVIEW_20261025.md`、`OPAQUE_RESPONSE_20261026.md`、`DIRECT_STITCH_AND_MULTICAM_20261025.md`、`LIVE_RECOVERY_FAILURE_20261023.md`、`MANUAL_STATE_RECORDING_20261023.md`、`USER_SCENE_DIAGNOSIS_20261023.md`、`GRAYSCALE_TOLERANCE_20261023.md` |
| `docs/color/hncs.md` | `HNCS_REVISION8.md`、`HNCS_REVISION12_20261019.md`、`HNCS_AUDIT_AND_SPEED_20261017.md`、`PHOCUS_NATURE_PIPELINE_20261018.md`、`PHOCUS_REVISION10_20261018.md`、`X2D_COLOR_PIPELINE_20261018.md`、`IPHONE_NATURE_GREEN_20261018.md`、`COLOR_PIPELINE_WORK_20261018.md`；逆向：`HNCS_BINARY_AUDIT_20261017.md`、`PHOCUS_READABLE_ANALYSIS_20261018.md` |
| `docs/color/ffcs.md` | `FFCS.md`、`FFCS_V020_LIVE.md`、`FFCS_STAGE_PROFILE.md`；逆向：`FFCS_ORIGINAL_AUDIT_20261018.md` |
| `docs/color/lumix.md` | `LUMIX_COLOR_20261026.md`、`LUMIX_PRORAW_20261026.md`；`vendor/lumix/ORIGIN.md` 中的函数地址等逆向细节移到研究仓库，ORIGIN 只保留来源、版本、哈希和权利说明 |
| `docs/f5.md` | `F5_IMPLEMENTATION_20261027.md`、`F5_DESIGN_REVIEW_DIAGNOSTICS_20261027.md`、`F5_DETAIL_INITIALIZATION_20261027.md`、`F5_FEASIBLE_GRADIENT_20261027.md`、`F5_JSR_INSPIRATION_20261027.md`、`F5_LOCAL_STEP_AND_MOTION_CACHE_20261027.md`、`F5_PERCEPTUAL_EVALUATION_20261027.md`、`F5_SAMPLING_DIVERSITY_20261027.md`；原始设计规格在研究仓库 `specs/f5/` |
| `docs/release.md` | 旧 `ios/README.md`、`scripts/iphone_release.py` |
| `docs/adr/0003+` | `DECISIONS.md` 中仍然有效的条目 |
| `README.md`、`CHANGELOG.md` | 旧根目录 README、`TEST_STATUS.md`（只取变化，一条一行）、git log |
| `docs/testing.md`（只更新运行命令） | `Makefile`、`TEST_STATUS.md` |

`vendor/` 下的上游文档（`vendor/hncs/docs/`、`vendor/ffcs/docs/`）属于原始交付材料，保持原样，不重写。
