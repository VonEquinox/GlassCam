# 02 · 「一整块光学玻璃」UI 视觉与交互重塑（已完成）

> 状态：`C1`、`C3`、`G1`–`G5` 均已落地并完成编译与单元校验，同步更新了 `docs/viewfinder.md`、`docs/peripheral-glass.md` 与 `CHANGELOG.md`。

GlassCam 最独特的技术资产是**中心无损取景 + 外围超广角实时拼接 + 系统原生 Liquid Glass**。本分册的目标是拆除表层传统相机 App 的「黑底仪表盘外壳」，让用户从打开相机、切换滤镜、按下快门到回看照片，始终感觉自己正握着**一块有厚度、有折射、带精密光学蚀刻的取景玻璃**。

---

## [C1] 清理取景器上的「假按钮」与残余遮挡

### 现状问题
- `CameraView+Controls.swift:166-175` 的 `24 MP` 做成胶囊按钮样式，实为 `Button {}` + `.disabled(true)`。
- 顶栏中央常驻大号 `GLASSCAM` 品牌字标，占用取景外围空间。
- 底部常驻一整排 `zoomButtons`（`0.5× / 1× / 2× / 5×`）及双指缩放，在固定主摄 Bayer 模式下永久灰死禁用。
- 过多半透明胶囊堆叠在外围区域，遮挡了底下的广角画面与液态玻璃折射。

### 打算怎么做
1. 移除顶栏 `GLASSCAM` 字标、点不动的 `24 MP` 胶囊按钮以及永久禁用的 `zoomButtons` / `zoomRuler` 面板。
2. 需要表达主摄等效焦距与输出规格时，合并为极简的只读光学蚀刻信息（如 `24mm · 24MP`），不伪装成可点击按钮。
3. 统一竖屏、横屏、紧凑布局的核心控件集合，消除竖屏与横屏功能不一致的问题。

---

## [G1] 一体镂空外围玻璃与 0.5pt 光学倒角窗框（Beveled Aperture）

### 现状问题
- `PeripheralGlassView.swift:246-267`（`PeripheralLiquidGlass`）用 `ForEach(framing.perimeter)` 画了上、下、左、右 **4 个独立的矩形**分别套 `.glassEffect`。系统玻璃材质在每个矩形边缘各自生成高光，四角交接处存在隐约的拼缝感，像四块碎玻璃拼起来。
- `PhotoFrameBoundary.swift` 在中心取景框四角画了 18pt 的白线折角（`opacity 0.65`），观感偏向数码相机的电子 OSD 叠加线，而非实体玻璃开孔。

### 打算怎么做
1. **整板开窗（Single-Sheet Cutout）**：
   - 将外围玻璃改为覆盖全窗口的单体形状（Window 矩形通过 `eoFill` 镂空减去中央 `framing.photo` 矩形），使外围成为**一整块连续无拼缝的玻璃板**，同时严格保持「中央照片区内部零玻璃覆盖、零像素污染」的不变量。
2. **光学倒角内沿（Optical Bevel Rim）**：
   - 替换或升级 `PhotoFrameBoundary`：沿着 `framing.photo` 外扩 `0.5pt` 的物理切口边缘，绘制一道极细的受光渐变描边（左上受光面 `white.opacity(0.38)` 过渡至右下背光面 `white.opacity(0.10)`，四角可保留极克制的微亮刻度点）。
   - 视觉效果：中央 4:3 区域像直接穿透空气的纯净通光孔，四周外围则像一块精密切割并做过抛光倒角的厚光学取景器玻璃。

---

## [G2] 光学蚀刻排版语言（Etched Glass Typography）

### 现状问题
- 外围控件大量套用 `CameraPill`（白底半透明胶囊 + 描边），视觉零碎且割裂了背后的广角流动画面。

### 打算怎么做
1. **默认态去胶囊化**：非激活的静态/切换指示采用类似旁轴相机亮线框（Bright-line）与镜头铭文的设计——高对比精细字重（SF Pro Rounded / Monospaced Digits）配合极柔和的底层微阴影，仿佛直接**激光蚀刻在玻璃表面**。
2. **激活态浮起液态玻璃**：仅在当前点选展开的项（如当前选中的滤镜拨盘项、弹出的微调条）上呈现温润的 `.glassEffect` 胶囊高光，做到「平时通透隐形，触碰凝聚成玻璃」。

---

## [G3] 光学棱镜玻璃快门与流光进度弧（取代实心大白饼与系统菊花）

### 现状问题
- `CameraView.swift:280-285` 快门按钮是直径 82pt 的不透明纯白实心圆 `Circle().fill(.white)`，在通透的玻璃界面上像贴了一块死白的圆贴纸；处理照片时内芯消失，直接放一个系统默认 `ProgressView()` 菊花，破坏了整体质感。

### 打算怎么做
1. **透镜快门（Lens Shutter）**：
   - 外圈保留精密高光金属/玻璃细环；内芯改为带高折射边缘高光与柔和内部亮度的半透液态玻璃圆盘（`.glassEffect(.regular.interactive(), in: Circle())` 叠加轻微光学高光径向渐变），既醒目易点，又能隐约透出底层色彩流动。
2. **三态光学动效**：
   - **按下与四帧采集中（Capturing）**：内芯透镜轻微内缩聚拢，中央取景框倒角切边泛起一圈柔和呼吸高光，明确告知用户「正在凝光采集，请稳住手机」。
   - **后台重建与编码中（Processing / Saving）**：取消系统默认 `ProgressView()` 菊花，改为沿快门外环顺时针流淌的平滑光学进度弧线（绑定 `workflow.progress`）。

---

## [G4 & C3] 底部横向「光学滤镜拨盘」取代全屏纯文字列表

### 现状问题
- `CameraLookPicker.swift` 通过 `.sheet` 弹出大面板，里面是 23pt 衬线体排成的一长串纯文字黑块按钮：不仅完全挡住取景画面，而且没有任何色调提示，新用户面对几十个名字只能盲猜。

### 打算怎么做
1. **镜前滤镜条（Optical Filter Strip）**：
   - 点按风格入口时，直接在底部外围玻璃区（快门上方）展开一条轻薄的横向滑动玻璃拨盘（顶部切换 `HNCS / FFCS / LUMIX` 三枚小晶片的引擎标签，下方横向滚动预设名）。
   - **不遮挡中央 4:3 取景框**：用户在滑动切换时，如果开启了实时色彩或观察外围玻璃折射，视线始终留在画面上；手指每拨过一档触发一次清脆的微刻度震动（`UISelectionFeedbackGenerator`）。
2. **风格微色标与两字特性标签**：
   - 为每个预设提供一枚极简的光学色温/对比度微圆点（如黑白系 `ACROS / Monochrome` 显示银灰单色环，高饱和 `Velvia / Vivid` 显示暖金青翠双色微弧）及几个字的特性短签（如 `Neutral`、`High Contrast B&W`、`Warm Negative`），告别纯文字盲选。

---

## [G5] 不断流的半透玻璃浮层取代死黑背景页

### 现状问题
- 打开 `CameraSettingsView` 时采用 `.fullScreenCover` + 不透明深黑 `CameraSettingsBackground`，并停止外围玻璃渲染；`CaptureWorkflowStatusCard` 采用 `Color.black.opacity(0.9)` 黑块，每次点开设置或弹出状态都让「玻璃」瞬间变成传统黑底 App。

### 打算怎么做
1. **设置页改为叠加在实时模糊相机上的半透玻璃页**：
   - 将日常设置改为大尺寸液态玻璃 Sheet（`.presentationBackground(.ultraThinMaterial)` / 系统 Liquid Glass Sheet），底层相机会话保持低功耗运行或保留柔和模糊透射，让设置卡片像悬浮在真实场景光影之上。
2. **状态提示液态玻璃化**：
   - 将 `CaptureWorkflowStatusCard` 的 `0.9` 纯黑底改为半透明深色磨砂玻璃胶囊，边角圆润并与外围控制区自然融合。
