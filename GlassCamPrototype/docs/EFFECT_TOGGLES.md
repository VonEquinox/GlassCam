# 三个独立的预设效果开关

用户确认：胶片指颗粒，裁切指预设额外裁切（例如Square Crop），不取消用户选择的拍摄画幅。三个开关默认为开启，保持已有参考行为；开启只采用该预设已有参数，没有对应效果时不添加新效果。

## 配方与作用范围

- **Sharpening / USM**：HNCS使用交付的portable Gaussian USM；Standard仍遵循原CLI整体绕过preset空间处理。FFCS控制其现有参考3×3邻域锐化，不把它冒称同一Gaussian USM。
- **Film grain**：分别控制HNCS portable颗粒、FFCS参考颗粒，系数和随机模型不变。
- **Preset extra crop**：只启用实际存在的预设裁切。关闭HNCS Square Crop的额外裁切后恢复选定源画幅，中央取景、比较两侧和最终输出尺寸一起恢复。FFCS当前无预设额外裁切；该开关不产生虚构FFCS裁切，也不改变源画幅。

三个布尔值作为一个共享`EffectToggles`加入不可变`ProcessingRecipe`，切换preset或色彩引擎不重置新选择。图像颜色核、快门捕获、待打开的迟到照片、预览、全源导出和缓存都使用同一快照。关闭颗粒/锐化确实旁路对应阶段，而不是把最终图透明混合回原图。

实时LUT依然只有颜色，忽略空间开关的数值作用；切换开关不能使未经验证的颜色preset获得实时准入。缓存身份包含配方开关，避免复用错误状态。HEIF仍请求10-bit SDR，未新增8位保存路线。

## 旧配方迁移

保持现有UserDefaults recipe键，使旧用户的preset、film curve、EV、虚拟capture CCT和其他设置继续可读取。

1. 若存在新`effects`对象，其显式true/false优先；对象内缺失的开关默认true。错误类型仍作为无效数据处理。
2. 旧配方当前为HNCS时，将旧`hncs.applyGrain`和`hncs.applySharpness`迁入共享开关，缺项默认true；新增crop默认true。
3. 旧配方当前为FFCS时，三个开关默认true，因为旧FFCS从未受潜在HNCS开关影响。这优先保持升级前当前FFCS照片的效果；不能同时将旧HNCS潜在false变为新FFCS全局false却声称当前画面不变。
4. 迁移后的新选择由共享开关持久化，不再有两套同时生效的HNCS/FFCS布尔值。

`ProcessingRecipe` JSON是App保存的配方元数据，不是HEIF内嵌Exif配方。现有HEIF writer保持新建、无原始GPS/HDR附件的图像输出；未新增或宣称HEIF配方标签保留功能。

## 验收

八种组合必须覆盖多个实际预设、无对应效果的预设、旧recipe迁移、裁切开/关尺寸与空间关闭旁路。FFCS19个look的默认新/旧输出、四种grain/sharp组合、完整图/条带和color-only关系分别验证。最终执行结果见[测试状态](TEST_STATUS.md)。Apple Codable/SwiftUI运行、设备构图和HEIF实际位流仍需Apple环境验收，便携模型/源码契约不等于设备测试。

## 已执行数值证据

- HNCS：5预设×8开关组合×2种奇数尺寸方向，共80个实际C++组合流水线案例。32个内存及32个文件空间通道逐位一致，48个直接旁路案例通过；原生/最终UInt16码最大差0，显示Float对double参考最大误差2.9782e-8（阈值1e-7），alpha=1。见[报告](../validation/effect-toggles-hncs-native.json)。
- FFCS：19模式×4颗粒/锐化组合，1,140全图、13,224条带、380九阶段案例逐位一致；76个color-only不变案例、615个非法调用、1–4工作线程、独立context并发均通过。默认输出与修改前285个Float/preview及95个九阶段案例逐位一致。见[报告](../validation/ffcs-effect-switches.json)。
- FFCS AddressSanitizer/UndefinedBehaviorSanitizer通过；LeakSanitizer受sandbox ptrace限制不可用。所有已有FFCS模式的grain/sharp系数均正，无对应效果的零系数行为由测试私有context副本验证，生产系数不改。

以上为Linux数值证据。旧recipe迁移与Swift生命周期仍采用便携模型和源码契约测试，未执行Apple JSONDecoder、SwiftUI或相机硬件。

最终整合216/216通过（26.287秒），183个既有测试ID全部保留，新增33项。212个源/资源/黄金文件测试前后hash一致，独立源码审查无阻断；详见[完整日志](../validation/effect-toggles-regression.txt)与[冻结清单](../validation/effect-toggles-regression-manifest.json)。
