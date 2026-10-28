# 轻量取景色彩代理：待测量选型的接入计划

2026-10-11。用户已将未来取景需求缩小为仅颜色，不含颗粒、模糊或其他空间效果；完整拍后处理保持原有算法。本文件保留选型时架构；后续已接入默认关闭的实验开关，当前状态以 [实现文档](LIVE_COLOR_PROXY.md) 为准。先前完整实时颜色处理后置的决定仍适用于完整 CPU 流水线，本候选仅评估轻量 GPU 颜色代理。

## 输入和数值契约

- 来源为 `CameraFrameDelivery` 收到的真实中心镜头帧，沿用原始时间戳、旋转和成片框几何；不可使用截图或静态图冒充实时源。
- 当前相机配置为 8-bit NV12；GPU 高精度处理不能恢复输入已丢失的位数。源格式标签继续可见。
- 相机 YUV→RGB 转换必须保留/尊重实际 pixel buffer 色彩附件，再转换到代理所声明的工作域。不能把 BT.709、sRGB 与线性数值视为同一域。
- 优先候选为 linear-sRGB [0,1] 输入，display-linear-sRGB 输出，alpha=1。颜色函数从真实核心取样，明确省略的只有取景空间效果；它是近似代理，不是最终图算法的替换。
- 同时测量线性格点与 sRGB 整形格点。后者若胜出，需要显式坐标变换，不能直接当作普通线性 `CIColorCube` 数据。

## GPU 与缓存边界

- 现有中心 `AVSampleBufferDisplayLayer` 可换成独立的 Metal-backed Core Image 渲染器。沿用 `cleanRect`；外围继续显示真实更广镜头的原始实时源，暂不假定两路效果一致。
- CI working format 为 RGBA Float，目标 drawable 为 RGBA16Float，SDR 色彩标签与 render destination 匹配，EDR关闭。避免 UInt8/UIImage 中间输出。
- 普通 CI cube 数据为 Float32 RGBA、预乘 alpha、R最快/G其次/B最慢；17³/33³/65³分别约77KiB/562KiB/4.19MiB。格式、轴序、源核/资产版本及输入/输出域随数据一同校验。
- 缓存键包括颜色模式、所有影响逐点输出的参数、输入桥与白平衡/曝光参数、源资产版本、格点方案及尺寸。采样只发生在参数变化时，不逐帧重跑完整 CPU 核。
- 最多一个 GPU command buffer 在途，另保留一个最新帧；新帧替换未提交旧帧。完成回调释放 buffer，session/recipe generation 变更使旧结果失效。停止、镜头切换和后台切换必须清空持有帧。
- 不支持设备、失败的 LUT 构建或 GPU 提交应显示明确状态，不能将无效果帧标为已处理。拍照与最终导出不依赖代理就绪。

## 决策与验收

1. 等待17/33/65点线性/整形格点的随机、边界、灰阶与颜色误差实测，再定尺寸和容差；不先宣称十位精度等于十位颜色准确度。
2. 检查 CI/自定义 Metal 实际插值与离线测试一致。离线 trilinear 结果不是 Apple GPU 实测。
3. 原图/最终效果保持精确 CPU 路径；代理只影响实时显示，绝不进入 DNG、保存的 HEIF 或最终分享文件。
4. Apple 端需验证帧时间、CPU/GPU占用、内存持有上界、切换/取消竞态、颜色空间、方向、热稳态和可接受画质。云 CPU 查表时间不能代表 iPhone GPU 帧率。

## 官方 API 依据

- [CIColorCube cubeData：Float32、预乘、轴序](https://developer.apple.com/documentation/coreimage/cicolorcube/cubedata)
- [CIColorCubeWithColorSpace：显式工作色彩空间](https://developer.apple.com/documentation/coreimage/cicolorcubewithcolorspace)
- [CAMetalLayer pixelFormat](https://developer.apple.com/documentation/quartzcore/cametallayer/pixelformat)
- [Core Image 渲染到 Metal texture](https://developer.apple.com/documentation/coreimage/cicontext/render(_:to:commandbuffer:bounds:colorSpace:))
