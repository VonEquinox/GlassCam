# GlassCam

GlassCam 是以 SwiftUI、AVFoundation 和 C++17 开发的 iPhone 相机，支持三摄接力变焦、Apple ProRAW、Speed 单帧 Bayer RAW、Balanced 四帧曲率融合、HNCS／FFCS／LUMIX 色彩处理，以及 10-bit HDR HEIF 保存、回看和分享。运行需要 iOS 27.0，构建需要 macOS 和 Xcode 27，数值测试使用 `uv`。

## 构建与测试

在仓库根目录运行：

```sh
make native
python3 scripts/iphone_release.py --unsigned
make test
make test-ui
```

`make test` 包含原生、数值、Swift 与 App 模拟器单元测试；`make test-ui` 运行模拟器操作测试。模拟器选择及可选素材见[测试说明](docs/testing.md)，签名和设备操作见[发布说明](docs/release.md)。

## 目录与文档

- [App](App)：相机、界面和 Xcode 工程；[Packages/GlassCamKit](Packages/GlassCamKit/Package.swift)：图像、拍摄、外围、F5 与原生内核；[架构](docs/architecture.md)。
- [scripts](scripts)：构建与资源准备；[tests](tests)：数值检查和固定夹具；[vendor](vendor)：参考资源与[来源说明](NOTICE.md)。
- [拍摄与恢复](docs/capture-and-recovery.md) · [RAW 解码与导出](docs/raw-decode-and-export.md) · [F5](docs/f5.md)。
- [取景](docs/viewfinder.md) · [外围玻璃](docs/peripheral-glass.md) · [HNCS](docs/color/hncs.md) · [FFCS](docs/color/ffcs.md) · [LUMIX](docs/color/lumix.md)。
- [术语](GLOSSARY.md) · [决策](docs/adr) · [变更记录](CHANGELOG.md) · [工作规则](AGENTS.md) · [文档写法](docs/writing-docs.md)。
