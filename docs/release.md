# 构建与发布

普通 Release 使用 Xcode 工程和工程内的开发签名设置。默认验收执行未签名构建；连接 iPhone、安装、启动和真机测试都需要用户明确同意。

## 工作方式

需要 macOS 和 Xcode 27；应用最低系统为 iOS 27.0。在仓库根目录执行：

```sh
python3 scripts/iphone_release.py --unsigned
```

`--unsigned` 关闭代码签名，只生成构建产物。脚本使用 `GlassCam` scheme、Release 配置和通用 iOS 目标，资源构建阶段准备 FFCS／LUMIX 数据。`DEVELOPER_DIR` 可选择其他 Xcode 安装。

`--output` 可指定产物目录；默认目录是用户 Library 下的 `Developer/GlassCamRelease`。目录中包含 `release-build.log`、`release.json` 和 `Build/Products/Release-iphoneos/GlassCam.app`。结果文件记录包标识、签名、安装与启动结果，签名构建还记录描述文件到期时间。

### 签名

需要开发签名包时运行：

```sh
python3 scripts/iphone_release.py
```

脚本使用工程的现有开发团队，构建后执行严格签名校验并读取描述文件的实际到期时间。`--refresh-signing` 允许 Xcode 更新已有描述文件，需要 Xcode 中已有可用账号与签名身份。`--unsigned` 与 `--refresh-signing`、`--install-device` 互斥。

### 设备操作

取得用户明确同意后，才可连接并解锁 iPhone、查询设备或执行以下命令。`DEVICE_ID` 指已配对 iPhone 的 CoreDevice ID。

```sh
xcrun devicectl list devices
python3 scripts/iphone_release.py --refresh-signing --install-device DEVICE_ID
```

`--install-device` 会覆盖安装并启动 App，也会终止同包标识的已有进程。若只授权安装，先签名构建，再单独执行 `devicectl device install app`，不要使用此组合选项。覆盖安装沿用包标识 `dev.glasscam.prototype`；有待完成照片时保留 App 及其数据，不卸载清空。

### 验收

离线验收运行[测试说明](testing.md)中的 `make test`、`make test-ui`；有本地 ProRAW 素材时另运行 `make test-baseline`。数值结果、恢复兼容与未签名构建共同用于检查发布候选。

模拟器测试默认从已有可用的 iOS 27 或更高版本 iPhone 模拟器中选择，优先已启动项；也可显式设置 `SIMULATOR_ID`。入口不创建模拟器或安装运行时。

真机验收由用户执行或明确授权后执行：

1. 检查冷启动、相机及相册权限拒绝与恢复、签名有效期。
2. 检查主摄原生视角、横竖屏、快门冻结及恢复、源照片与取景边界；记录实际 RAW 尺寸，并核对主摄／超广角配对取景。
3. 检查 Speed、Balanced 与三个色彩引擎；Speed 核对单张 12MP Bayer，Balanced 核对四张等曝光 Bayer 及双密度重建，两者成片都为 24MP，模式选择只显示这两项。检查相册原件的白点、曝光、ISO、尺寸、方向、HDR 和拍摄日期。
4. 检查切后台、锁屏和进程结束后的单张恢复，Speed 待完成记录恢复后的 24MP 输出，保存失败重试，以及保存结果未知时的人工确认。
5. 检查回看、分享接收端、设置恢复、外围玻璃外观、运动稳定性，以及连续单拍的耗时、内存和热状态。

需要自动化收集真机证据时，使用 `GlassCam-research` 的 `device-acceptance/`。该目录保留来源提交、完整 UI 方法和独立项目准备／构建说明；产品仓库的 UI target 只运行模拟器流程。

## 不变量

1. 发布候选的 HNCS 数值输出保持固定参考值。— `tests/numeric/test_native_core.py::test_original_native_golden_vectors_match`
2. 发布候选的 FFCS 分条处理保持整图结果，LUMIX 插值保持固定参考值。— `tests/numeric/test_ffcs_strips.py::test_strips_match_full_frame`、`tests/numeric/test_lumix_reference.py::test_rgb12_interpolation_matches_native_vectors`
3. 更新后的处理逻辑能读写已有单张及 F5 拍摄记录，保持固定 JSON 字节。— `F5Tests/currentJournal_decodeEncodePreservesBytes`
4. 恢复到相册保存结果未知时，继续保存必须由用户明确选择。— `CaptureTests/RecoveryTests.unknownSave_requiresExplicitResolution`

## 数据与版本

发布按当前首版模式与数据约定验收，不为历史版本额外保留兼容层。当前可接纳的照片按记录中的处理配方和管线版本恢复；具体格式见[拍摄与恢复](capture-and-recovery.md)及[F5](f5.md)。构建日志和签名、安装结果保存在指定产物目录，不作为产品数据写入仓库。

## 已知限制

- 未签名包不能安装到 iPhone。
- 自动化测试和构建不覆盖真实相机组合、最终屏幕观感、接收端分享行为或持续拍摄功耗。
- 开发签名受描述文件有效期限制，到期后需使用有效签名重新覆盖安装。
- 发布脚本的签名与设备操作分支没有自动化测试，需要检查对应命令的实际结果。

## 代码入口

- [iphone_release.py](../scripts/iphone_release.py)：构建、签名验证、有效期读取及显式设备安装入口。
- [GlassCam.xcodeproj](../App/GlassCam.xcodeproj/project.pbxproj)：应用目标、包标识和签名设置。
- [Makefile](../Makefile)：离线测试与模拟器测试入口。
- [CaptureWorkflowUITests](../App/GlassCamUITests/CaptureWorkflowUITests.swift)：模拟器用户流程。
- [select_simulator.py](../scripts/select_simulator.py)：只读发现并校验已有模拟器。
