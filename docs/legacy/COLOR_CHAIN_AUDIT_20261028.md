# 三种色彩流程复查与重构前基线 · 2026-10-28

本轮复核此前 Quality ProRAW 的反差／LUMIX 回绕修复，并检查解码、白平衡、曝光、原生颜色核、空间效果、分条、HDR 编码和历史配方恢复。此前修复的源码、已安装构建及验证文件指纹吻合；原生 LUMIX 数值回归重新通过。

## 本轮补齐的三处问题

1. **HNCS／FFCS 的 HDR 曝光顺序。** 旧路径先分离高光幅度，再在有界颜色核中施加 EV。同一个线性灰色高光 `[2,2,2]`，0／+1／+2 EV 输出仍约为 `[2,2,2]`。新流程先缩放完整线性输入，再分离高光，颜色核接收 0 EV，避免重复曝光。LUMIX 原本正确的顺序继续保留。
2. **冻结白平衡与解码输入不一致。** 配方已保存白点时，原预览／直接导出入口仍可能重新取当前解码器的 as-shot 白点，造成解码器与颜色核使用不同白点。现在重新解码和完整源图导出都采用配方冻结的 xy；测试同时核对实际解码像素，不能只改元数据标签。
3. **启用 Apple 锐化时，RAW 分条读取的重复性。** 在本机 `8.dng` 解码器与保留 DNG 上，重复小区域读取会出现极少量 Float32 差异；该差异还能改变后续有损 HEIF 的编码结果。独立 CIRAWFilter 实验确认：关闭锐化或整图读取时连续三次稳定，开启锐化并直接分条时不稳定。使用 `insertingTiledIntermediate()` 后连续三次解码摘要一致，保留 Apple 锐化。缓存必须保持到全部源条带／halo 读取结束；中途 `clearCaches()` 的实验再次出现差异，因此产品只在全部源行读取结束后、空间处理及编码前释放缓存。

完整 RAW 与缓存分条之间仍有少量浮点运算差异：该独立夹具中最大约 `6.24e-4`，约 1.56 亿个 RGBA 通道中 6 个通道超过 `1e-5`，平均绝对差约 `1.39e-11`。这不是原生 C++ 滤镜改了 LUT，也不证明所有系统解码器版本都有同样行为。

## 版本与回放

`ProcessingRecipe.pipelineRevision` 当前为 **2**，与 HNCS／FFCS／LUMIX 各自的原生算法版本分开。缺少该字段的旧照片按 revision 1 恢复；相机未来快门快照使用 revision 2。白平衡、ISO 绑定都必须保留该版本。原生 C++ 算法和 LUMIX revision 4 的数值实现本轮未改动。

冻结的旧曝光输出保存在 `tests/fixtures/color-pipeline-v1-exposure.json`，来源是修复前生产 Swift 流程，不由新实现实时生成。

## 验证与边界

- 三种引擎 × 7 个 EV，共 **21 组**真实生产流程对照，和预先缩放完整源像素的结果最大误差 **0**。
- **15 组**旧版曝光 golden 重放通过，缺失版本字段和元数据绑定保持旧版本。
- **12 组**整图／分条／空间效果导出检查通过，覆盖正负曝光、锐化及颗粒开关、FFCS halo 与 10-bit HDR HEIF。
- 主摄、超广角、长焦保留 ProRAW × 三种引擎，共 **9 组**冻结白平衡及完整源导出检查通过。直接导出与预览后重放的 HEIF **逐字节一致**；与独立 Core Image 白平衡解码对照通过。
- 完整 Apple 图像、照片恢复、元数据、取消、分享及真实源图 24MP／48MP 导出检查通过。
- Python **223 项全部通过**。此前 11 项失效的源码字符串检查已更新到当前 F5 快照／共用导出入口，最后一项调用签名检查也随缓存参数更新。没有删除失败测试或放宽数值误差来隐藏问题。
- 签名 iOS Release 构建通过，部署回执保留在本机诊断目录。正式构建不含临时的像素摘要跟踪代码。

以上实图检查使用保留 RAW 重放；本轮没有新增手机快门实拍或测量设备峰值 RSS。分块缓存由 Core Image 管理，在源读取结束后显式释放；不能据此声称 Apple 内部临时内存有固定上限。F5 的产品资格和既有画质限制继续以其独立文档为准，本轮没有扩展 F5 研究。

## 后续重构应保留的运行时检查

```sh
python3 tools/test_lumix_images.py --test-source tests/apple_color_chain.swift \
  --output /absolute/path/audit \
  --proraw /absolute/path/main.dng \
  --proraw /absolute/path/ultra.dng \
  --proraw /absolute/path/tele.dng
python3 tools/test_apple_images.py --raw-source /absolute/path/main.dng
python3 -m unittest discover -s tests -v
```

第一项是完整流程的运行时回归底线；不要只依靠源码字符串检查。尤其要保留：曝光只应用一次、冻结白点同时进入解码器与颜色核、源缓存覆盖全部条带读取、HEIF 编码前恢复正确的 headroom、旧配方版本不被相机偏好迁移覆盖。

结构化结果见 `validation/color-chain-audit-20261028/`。原片、完整 HEIF、临时跟踪副本和设备回执保留在本机 `~/Library/Developer/GlassCamDiagnostics/color-chain-audit-20261028/`。
