# GlassCam iPhone 构建与试用

当前开发目标是用户自己的 iPhone，工程最低系统为 **iOS 27.0**，使用 **Xcode 27**。应用启动即相机，拍摄 Apple ProRAW，经现有 HNCS／FFCS 处理后自动保存 10-bit BT.2020/PQ HDR HEIF，并提供成片回看与分享。

本轮按用户要求先离线开发，开发完成后统一连接手机验收。编译通过与真实三摄拍摄通过是两项独立结果；最终状态见[测试记录](../docs/TEST_STATUS.md)。完整产品约定见[首版日常试用](../docs/IPHONE_FIRST_USABLE_20261018.md)。

## 构建普通 Release

在仓库根目录运行：

```sh
python3 GlassCamPrototype/tools/iphone_release.py --unsigned
```

这只编译，不连接设备、不安装应用。产物默认保存在 `~/Library/Developer/GlassCamRelease`，结果和日志分别为 `release.json` 与 `release-build.log`。

需要有签名的安装包时：

```sh
python3 GlassCamPrototype/tools/iphone_release.py
```

使用工程已有的开发团队。工具检查最终签名，并从包内描述文件读取实际到期时间。普通 Release 不启用性能探针或神经实验入口。

项目没有额外包管理器或工程生成器依赖。保留 `../core`、`../reference_ffcs/source.zip` 和 `../tools` 的布局；构建阶段会校验并展开 FFCS 资源。命令行使用 `/Applications/Xcode.app/Contents/Developer`，也可通过 `DEVELOPER_DIR` 指定其他 Xcode 安装。

## 安装与续签

开发完成、手机连接并解锁后，查询已配对设备：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices
```

用列表中的 CoreDevice ID 替换下方的 `DEVICE_ID`：

```sh
python3 GlassCamPrototype/tools/iphone_release.py --refresh-signing --install-device DEVICE_ID
```

只有明确提供 `--install-device` 才会安装并启动 App。`--refresh-signing` 允许 Xcode 更新现有描述文件；需要 Xcode 中已有可用账号及签名身份。它不购买开发者会员。

用户已接受现有开发签名的定期续签方式。之前的包使用 7 天描述文件，新包有效期以 `release.json` 中读取的时间为准。使用相同 bundle identifier 覆盖安装可保留应用数据；有待完成照片时不要卸载 App。

## 相机与输出

- 双指捏合连续变焦；焦段按钮跳到超广、主摄和原生长焦入口；长按按钮打开连续标尺。控件倍率来自实际设备能力。
- 首选虚拟三摄，由 iOS 根据倍率、光线和对焦自动接力。没有可用虚拟 ProRAW 时按物理镜头能力回退；每次只运行一个普通 `.photo` 会话。
- 若虚拟三摄只公布较小 RAW、其当前主镜头支持更高分辨率，快门时冻结该系统选镜结果，用同一物理镜头和等价倍率采集高分辨率 RAW，随后恢复虚拟取景。这样保留自动选镜和原生 48MP 能力；捕获时会短暂停住取景。
- 弱光或近摄时，长焦倍率可以由较短焦距镜头裁切提供。焦段按钮代表所选视角，不承诺强制某一颗镜头。
- 快门前冻结构图、方向、处理配方与输出选择。当前照片保存完成前，不能再拍下一张。
- 相机已经施加的变焦不会在 RAW 解码后再次裁切；HNCS 预设额外裁切是单独的设置。

| 档位 | 最终构图的有效像素 | 输出 |
|---|---|---|
| 24MP | 任意合法源尺寸 | 24MP |
| 48MP | 至少 24MP | 48MP |
| 48MP | 小于 24MP | 24MP |

保持构图比例，需要时插值放大。原始 ProRAW 回调仍校验格式、缓冲尺寸和比例；已知原生未裁切焦段不会把异常降低的 RAW 分辨率当作成功。

Apple 没有逐档保证 ProRAW 内部采样、裁切与上采样方式。当前有效像素使用解码栅格上限和实际镜头中心裁切模型的保守估计，界面明确标为估计；照片 EXIF 可补充数字变焦证据，默认值不能抹去已知裁切。实际物理镜头、EXIF、RAW 返回尺寸和解码尺寸随照片记录，恢复回看继续使用真实解码画幅。最终三摄验收需要核对取景边界、DNG 裁切标签及解码尺寸，不能只根据一个 48MP 文件标签证明独立细节。

## 恢复与保存

RAW 和快门配方完整写入本机恢复目录后，一张待完成照片可跨进程恢复。处理在前台进行，切后台或锁屏在安全边界停止后续工作，回到前台继续。已经提交的 Photos 请求继续等待它自己的回调。

- RAW 阶段恢复：使用原配方重新处理同一照片。
- 已编码阶段恢复：复用保留的 HEIF，不重新渲染。
- Photos 写入途中被结束：显示“结果可能已保存”，保留成片，由用户核对相册后确认已保存或再次保存。
- 成功回执写入失败：提示恢复记录需要重试，不把它误报成 Photos 保存失败并自动重发。
- 保存成功后清理恢复数据；回看和分享另持有有效的成片文件。

相册保持仅添加权限。分享优先原始 HEIC，需要兼容格式时从最终 HEIF 生成 JPEG；接收端实际选择仍以实际应用测试为准。应用不提供长期 RAW 图库。

## 离线验证

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B GlassCamPrototype/tools/test_apple_images.py
```

它在 Mac 上编译生产 Swift／C++，运行真实 Core Image／Metal／HEIF，以及可注入的权限、恢复和 Photos 状态测试。相机与 Photos 的替身验证不等于真机拍摄。

完整 Python 回归需要仓库 `requirements.txt` 中的环境：

```sh
PYTHONPATH=GlassCamPrototype/tests python3 -B -m unittest discover -s GlassCamPrototype/tests -q
```

## 统一真机验收

1. 普通 Release 冷启动、相机／相册权限拒绝及恢复，检查签名有效期。
2. 三颗实际镜头及中间倍率：快速往返变焦、横竖屏、快门冻结、照片与取景边界对应；记录真实镜头、RAW 类型、尺寸和实际焦段。
3. HNCS／FFCS、24MP／48MP、方形裁切组合，核对系统相册原件的尺寸、方向、HDR 与插值提示。
4. 处理中切后台／锁屏、返回前台，以及保留任务后结束再启动；验证同一照片恢复和单张互斥。
5. Photos 在途未知状态的人工确认、普通保存失败重试，确认不自动产生重复照片。
6. 多次连续单拍、回看、设置重启保留，并测量快门到保存和再次可拍的耗时、热状态与内存。

`GlassCamCaptureTests` 会实际拍摄并保存照片，只在统一真机验收阶段执行。旧版的设备成功记录不能替代本轮三摄版本的验收。
