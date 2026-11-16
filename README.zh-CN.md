# 3ds2apple

把你自有的 Nintendo 3DS 游戏以原生 ARM64 方式带到 iPhone / iPad：桌面端提前 AOT 编译，
手机端不使用 CPU JIT、不在手机上模拟。

## 工作方式

1. 打开 **Windows 或 macOS 启动器**，导入你自有的、已解密的 `.3ds` / `.cci` ROM。
2. 启动器编译每游戏的 AOT `GamePack.dylib`，并合成不含 ROM 的基础壳 IPA。
3. 在 Impactor（Windows）或 Xcode（macOS）中用你自己的 Apple ID 登录；启动器签名安装壳，
   然后只把 `GameRom.cci` + `GameInfo.json` 推送到 App 的 Documents。
4. 手机 App 显示游戏库，使用 Zakuro 运行时和 PICA200 GPU 路径运行游戏。

一个手机 App 装整个游戏库；IPA 不含 ROM，游戏数据由启动器推入
`Documents/Games/<TITLEID>/`。

## 可测试的启动器包

构建产物在 `out/launchers/`（git 忽略，不在仓库中）：

- `3ds2apple-windows-single-0.1.0.zip` —— 单文件 Windows 启动器；内嵌 ROM-free 基础壳、
  Impactor、本地 3dsrecomp + LLVM 工具链和 CLI 工具。
- `3ds2apple-launcher-0.2.1-macos-app.zip` —— macOS universal App（Xcode 签名）。

这些包不含 ROM、密钥、BIOS 或 Apple 凭据；请只使用你自有的已解密 ROM。

## 环境要求

- Windows 10/11 x64 或 macOS 13+（Intel / Apple Silicon）。
- iOS 16+ 的 iPhone/iPad、USB 线、开发者模式。
- 免费或付费 Apple ID 用于签名（只在 Impactor/Xcode 中输入）。
- 你自有的已解密 3DS ROM。

## 仓库结构

```text
ios/app/           手机壳（SwiftUI、游戏库、Documents 游戏数据）
ios/zakuro-ios/    Zakuro iOS C ABI、presenter、存档桥
ios/sim/           x86_64 模拟器 AOT 开发/验证 harness
launcher/windows/  Windows 启动器（C#/Avalonia）与单文件打包
launcher/macos/    macOS 启动器（SwiftUI）、Xcode 签名安装
tools/devpush/     usbmuxd/AFC 设备桥（Rust）
tools/winbuild/    开源 LLVM/LLD GamePack 交叉编译
builder/pack/      ROM/打包/catalog CLI（3ds2apple-pack）
builder/device/    签名安装与推送封装
scripts/           构建、打包、自检脚本
docs/              启动器架构、设备桥、构建和验证文档
```

## 构建

- Windows 启动器：`launcher/windows/README.md`（.NET 10，无需 Mac）。
- macOS 启动器：`launcher/macos/README.md`（Xcode 26.6 + Xcodegen）。
- 手机壳：在 macOS 上运行 `scripts/build-ios-app.sh`（Xcode 26.6 / iOS 26.5 SDK）。
- 设备桥：`cargo build --release --manifest-path tools/devpush/Cargo.toml`。

文档：[启动器架构](docs/launcher-architecture.md)、[v2 流程](docs/launcher-flow-v2.md)、
[设备桥](docs/device-bridge.md)、[Windows 启动器](docs/windows-launcher.md)、
[macOS 启动器](docs/macos-launcher.md)。

## 许可证与法律

Apache-2.0。本项目不提供 ROM、解密密钥、BIOS 或系统文件，也不提供 ROM 下载/破解支持。
请只导入你自有的游戏。第三方许可证与来源见 [THIRD_PARTY.md](THIRD_PARTY.md) 和 [NOTICE](NOTICE)。
