# FFCS 0.2.0：真实参考移植与当前边界

## 来源与适用范围

同步用户最新交付 commit `c4b3383da838ea607bcc37d2776b90c8770795f6`；115份交付文件、50张原生LUT与2份ICC逐一核验。原始88,509,373字节普通Git ZIP、逐文件摘要与可读源码见[来源](../reference_ffcs/ORIGIN.md)。研究分支不变，JSR未接入。

App仍由Apple解码获得已显影、经过色彩管理的linear-sRGB，再独立选择HNCS或FFCS。研究表族选择是XH2S、XA3、GFX100、GFX100S、GFX100 II的资产来源，不表示Apple物理镜头或已标定的富士传感器输入。选择器只提供该表族实际支持的外观；GFX100S/II按新参考优先专用表、再用公共GFX100表，并标明实际来源。REALA ACE仅在有真实表的GFX100 II可用，不伪造XH2S表。

## 这次真正改变的数学

0.2.0的原生表默认中性后处理：contrast/saturation为1，hue/shoulder/toe/grain/sharpness为0。中性Lab/UCS必须直接旁路，不能继续旧版浮点往返。因此旧配方在新版会采用修正的默认外观；这不是维持旧版错误叠加的兼容模式。

“Reference adjustments”是显式选择的研究解析叠加，默认关闭；开启后才使用原look参数。用户独立颗粒、锐化开关仍保留，永远不能自行把零系数变成非零。新版锐化使用真实Gaussian半径、完整邻域归一化与原始求和次序，默认半径1对应3像素halo。App提供有限半径范围，仍是参考算法参数，不是新增物理标定。FFCS没有额外裁切阶段。

研究包装流程的阶段顺序为：输入→gamma_pre→包装容器矩阵→采样LUT的浮点三线性→Lab/UCS或准确旁路→tone→全图坐标grain→Gaussian USM→sRGB输出。输入linear分支不再重复sRGB解码。原生MONO滤镜已包含在LUT中，不能再套解析路径的彩色加权修复。此处的包装容器和插值不等同于原版 `.s3d` 的固定点处理；见下方独立审计。

C++只开放有真实表的路径。新版Python的自定义Cube输入域/shaper、解析无表MONO、sensor RAW/CFA修复、RAF预览挑选、tifffile和Python CMS/AdobeRGB保存等也完整保留在参考里，但App没有这些独立入口。Apple现有ImageIO/Core Image色彩管理与CIRAWFilter承担解码，不把Python传感器校正叠到已经显影的Apple RGB。

## ABI、内存与全源导出

不可变上下文包含表族、实际表、解析叠加、半径以及两个空间开关；旧构造器采用新版中性默认。严格检查容器头部、矩阵/scale有限性、flags、解压长度和完整zlib流，非法资产失败，不偷换近似表。

完整参考、优化、分块都使用相同算术和全图grain坐标。`ffcs_required_halo`根据真实活动锐化阶段返回所需行数，Swift按该查询读全源条带；不能再写死旧版1行halo。默认中性路径无空间halo。开启Gaussian锐化时环形缓存随邻域增长，且仅在整图边界截断，不能在条带边界截断。App继续64输出行处理、颜色和空间阶段完成后才在线性光缩小。

效果预览取Float display-linear RGB，经RGBA16Float SDR显示；全源导出取Float并走RGBAf→HEIF10 SDR sRGB。无UInt8中间回退。共享源、配方和输出尺寸快照包含新FFCS设置与三个独立开关。配方JSON不等于新增HEIF内嵌Exif功能。

## 资产准备与复现

```
python tools/materialize_ffcs_reference.py
bash tools/prepare_ffcs_resources.sh reference_ffcs/source.zip ios/GlassCam/Resources/FFCS
```

Xcode构建阶段离线验证ZIP及`tools/ffcs_native_SHA256SUMS`全部50表。固定清单路径提取，失败终止；不联网、安装包或执行归档代码。源ZIP直接复用同仓库Git对象。

## 实时代理与验证范围

旧FFCS实时cube属于0.1数学，不能带入新版本。缓存合同升级；只有经0.2独立重新测量的窄配方才可再次放行，其他配方明确显示系统取景。取景代理始终仅颜色，空间开关不会让grain/USM进入cube。HNCS的既有独立准入不受影响。当前准入与测量见[LIVE_COLOR_PROXY](LIVE_COLOR_PROXY.md)。

新数值证据与整合测试见[TEST_STATUS](TEST_STATUS.md)。既有`ffcs_*`和阶段性能报告保留为0.1历史，不用旧golden证明新默认正确，也不把旧性能当成新版基准。上游50表原生核对仅覆盖其声明的固定插值/Gamma/BGR量程；不证明完整Apple或富士相机等价。

2026-10-18 的[原始 SILKYPIX 独立审计](FFCS_ORIGINAL_AUDIT_20261018.md)纠正了旧交付“三线性入口已包含矩阵”的说法，区分 encoded 默认分派和显式 gamma 入口，并以 50 表／1,450,500 输入验证固定点数学。当前采样 LUT 仍有残差，本次最大 ΔE00 为 3.502497；低均值不能替代其 P95／P99／极值。原始交付快照与历史结果保留。

Apple编译、实际ICC照片/ProRAW、HEIF位流、条带方向、内存/耗时/热状态、微信兼容仍须Apple环境验证。测试通过只说明所列便携算法与源合同，不代表已经完成真机验收。
