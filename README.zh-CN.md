<p align="center"><img src="assets/icon.png" width="128" alt="3ds2apple 图标"></p>

<h1 align="center">3ds2apple</h1>

[English](README.md) · [简体中文](README.zh-CN.md) · [下载启动器](https://github.com/HFYKratos/3ds2apple/releases) · [全部版本](https://github.com/HFYKratos/3ds2apple/releases) · [参与贡献](CONTRIBUTING.md)

> [!NOTE]
> 3ds2apple 是免费开源软件（Apache-2.0）。启动器与 iOS App 不附带任何游戏、密钥或 BIOS：请用你合法拥有并自行导出的已解密 ROM 构建自己的游戏库。

**把你自有的 Nintendo 3DS 游戏以原生方式运行在 iPhone / iPad 上。** 游戏代码会在本机被提前重编译为原生 ARM64，直接跑在手机处理器上；图形经 MoltenVK 走 Metal。整个游戏库都在同一个 App 里，在 Windows 或 macOS 启动器里点几下就能把一款游戏从导入带到开玩。

平台：iPhone / iPad（iOS 16 及以上）· Windows 10/11（启动器，无需 Mac）· macOS 13+（启动器，Intel + Apple 芯片）· 可在 Windows 或 macOS 上构建 · 许可：Apache-2.0 · **自备游戏**

<p align="center">
  <img src="launcher/windows/docs/ui/v4-library-zh.png" width="470" alt="Windows 启动器游戏库">
  <img src="launcher/macos/screenshots/launcher-library-empty-dark-zh.png" width="380" alt="macOS 启动器空游戏库">
</p>
<p align="center"><sub>Windows 启动器（游戏库，合成演示条目）与 macOS 启动器（空游戏库）。</sub></p>

## 原生移植，不是模拟器

每款游戏都会被提前重编译：3DS 代码先由 3dsrecomp 翻成 C，再用本机的 LLVM 或 Apple clang 工具链编译成 ARM64 `GamePack`。手机通过 Zakuro HLE 运行时直接执行这些原生代码——没有 CPU JIT，也没有解释器兜底。PICA200 GPU 路径由 MoltenVK 转成 Metal，手机壳直接呈现到 `CAMetalLayer`，每帧零屏幕回读。

## 一个 App，装下整个游戏库

你勾选的每款游戏都会编译成独立的 `GamePack<TITLEID>.dylib`，和一个 `GameCatalog.json` 一起被合成进同一个已签名 App。装一个 App 就带走整个游戏库；增删游戏只需重新部署一次，已推送的游戏数据在重装与更新后仍然保留。每游戏代码必须位于已签名的 IPA 内——iOS 不允许从 `Documents` 加载未签名代码。

## 图形化启动器，几乎零配置

Windows 与 macOS 各有一个启动器。导入你自有的已解密 `.3ds`/`.cci`，勾选游戏，按唯一的一键部署按钮：启动器编译 GamePack、合成不含 ROM 的基础壳 IPA、用你自己的 Apple ID 签名安装（Windows 用内置官方 Impactor/plumesign，macOS 用 Xcode 自动签名），然后只把 `GameRom.cci` + `GameInfo.json` 推送到 App 的 Documents 目录。

启动器会把数据放在 exe/.app 旁的便携目录，读取 ROM 的 SMDH 元数据（图标、本地化名称、发行商），检测编译硬件并自动并行 3dsrecomp，还会显示启动就绪灯与自检——缺工具时不会在部署中途静默失败。

## 实测数据

在真机 iPhone 上经 Windows 启动器链路运行 Pokémon Y：约 **57–60 fps**，**AOT 100%**，**Metal GPU** 渲染；`zk_perf` 显示 GPU 每帧 4–6 ms、present 10–11 ms、屏幕回读 0。以上是维护者针对该游戏的实测数据；兼容性与性能因游戏而异。

## 平台

| 平台 | 支持情况 |
|---|---|
| **iPhone / iPad** | iOS 16 及以上。一个 App 承载游戏库、游戏内菜单、触摸控制与即时存档。 |
| **Windows** | Windows 10/11 x64。单文件自包含启动器；无需 Mac 即可编译、签名、安装、推送。 |
| **macOS** | macOS 13+（Intel + Apple 芯片）。SwiftUI 启动器，使用 Xcode 签名；分发包尚不自包含，真机安装尚未由维护者验证。 |
| **构建主机** | Windows（内置 LLVM/LLD）或 macOS（Apple clang + Xcode）。 |

## 快速开始

**前提**：你自有的已解密 3DS ROM、开启开发者模式的 iOS 16+ iPhone/iPad、USB 数据线，以及用于签名的你自己的 Apple ID。不包含任何游戏数据。

### Windows 启动器

1. 下载 `3ds2apple-<version>-windows-x64.zip`，解压到可写目录（不要放 `Program Files`）。安装 *Apple 设备*，保证手机可通过 USB 访问。
2. 运行 `3ds2apple-launcher.exe`（未做代码签名；校验 digest 后在 SmartScreen 选「更多信息 -> 仍要运行」）。先跑一次 Settings -> 自检，应为绿色。
3. **游戏库 -> 导入** 你自有的已解密 `.3ds`/`.cci`；只读取 ROM 头与 SMDH 图标/元数据。
4. **部署**：勾选游戏后按唯一的一键部署按钮。启动器为每个游戏编译 GamePack、合成不含 ROM 的 IPA、用内置 Impactor（登录你自己的 Apple ID）签名安装，然后只推送游戏数据。
5. 在手机上打开 App 开玩。增删游戏重新部署即可；已推送数据在重装后保留，彻底卸载 App 会清空。

### macOS 启动器

1. 下载 `3ds2apple-<version>-macos-universal.zip` 得到 `3ds2apple-launcher.app`（未公证；首次右键 ->「打开」）。
2. 分发包**尚不自包含**：需要 macOS 13+、已登录 Apple ID 的 Xcode 15+、`xcodegen`、仓库 checkout，以及构建好的工具（`scripts/build-zakuro-ios.sh`、`builder` 的 pack CLI、`tools/devpush`）。启动器会在自身 bundle、checkout 与 `PATH` 中查找。
3. 导入 -> 部署：Apple clang 编译 GamePack，Xcode 自动签名 + `devicectl` 安装合成后的 IPA，随后推送游戏数据。选择规则与 Windows 相同。

### 手机数据、存档与限制

- 游戏数据位于 `Documents/Games/<TITLEID>/`（可在「文件」App 查看）；存档与即时存档保存在 App 容器内。
- 免费 Apple ID 每台设备限 3 个 App、签名约 7 天；到期重新部署即可续签。付费开发者账号没有这些限制。
- 卸载 App 会删除其数据；你电脑上的 ROM 不受影响。

## 下载

公开发布只走 [GitHub Releases](https://github.com/HFYKratos/3ds2apple/releases)。每次发布附两个平台包：

- `3ds2apple-<version>-windows-x64.zip` —— Windows 10/11 启动器（单个自包含可执行文件）。
- `3ds2apple-<version>-macos-universal.zip` —— macOS 13+ 启动器（`.app`，Intel + Apple 芯片）。

不含 ROM 的壳模板已内嵌在两个启动器中，无需单独下载。GitHub 会显示每个发布资产的 SHA-256 digest；发布中不含任何游戏数据。

## 从源码构建

| 组件 | 构建 / 测试 |
|---|---|
| Windows 启动器 | `cd launcher/windows && dotnet build Launcher.slnx -c Release` / `dotnet test Launcher.slnx -c Debug` —— 见 [launcher/windows/README.md](launcher/windows/README.md) |
| macOS 启动器 | 在 macOS 上用 XcodeGen + `xcodebuild` —— 见 [launcher/macos/README.md](launcher/macos/README.md) |
| iOS App / 壳 | `scripts/build-zakuro-ios.sh` -> `scripts/build-ios-app.sh` -> `scripts/package-ipa.sh` —— 见 [scripts/README.md](scripts/README.md) |
| Pack CLI（`3ds2apple-pack`） | `cd builder && cargo build --workspace` / `cargo test --workspace` —— 见 [builder/README.md](builder/README.md) |
| 设备桥（`devpush`） | `cargo build --release --manifest-path tools/devpush/Cargo.toml` —— 见 [tools/devpush/README.md](tools/devpush/README.md) |

宿主机自检（无需 ROM、手机或 Xcode）：

```bash
cd builder && cargo test --workspace
cd launcher/windows && dotnet test Launcher.slnx -c Debug
bash scripts/tests/perf-selfcheck.sh
bash scripts/tests/aot-selfcheck.sh
bash scripts/tests/game-catalog-selfcheck.sh
bash scripts/tests/desktop-aot-selfcheck.sh
```

## 仓库结构

```text
assets/            本 README 使用的 App 图标
ios/app/           iOS App：游戏库、游戏内菜单、触摸控制、即时存档
ios/zakuro-ios/    Zakuro iOS C ABI：GamePack 加载器、Metal presenter、性能计数
launcher/windows/  Windows 启动器（C#/Avalonia）与单文件打包
launcher/macos/    macOS 启动器（SwiftUI）、Xcode 签名安装
builder/           3ds2apple-pack：ROM 导入、SMDH 元数据、包与 GameCatalog
tools/devpush/     设备桥：usbmuxd/house_arrest/AFC 推送、安装校验
tools/winbuild/    不依赖 Apple SDK 的 LLVM/LLD GamePack 交叉构建工具
scripts/           构建、打包、发布与自检脚本
licenses/          第三方许可文本（Impactor MIT、apple-codesign MPL-2.0）
```

## 实话实说的边界

- **兼容性因游戏而异。** 部分游戏可能无法启动或渲染异常；欢迎带上 title ID 反馈。
- **macOS 包是开发者预览。** 尚不自包含，真机安装也还未由维护者验证；Windows 包是已验证路径。
- **不提供 ROM、密钥或 BIOS。** 只支持你合法拥有并自行导出的已解密 ROM。
- **设计上没有 CPU JIT。** 正式路径是 AOT 代码 + Zakuro HLE 运行时，没有解释器兜底。

## 贡献与发布

- [CONTRIBUTING.md](CONTRIBUTING.md) —— 贡献规则、问题反馈与发布规范。
- [LICENSE](LICENSE) —— Apache-2.0。
- [THIRD_PARTY.md](THIRD_PARTY.md) 与 [NOTICE](NOTICE) —— 第三方组件与法律声明。

## 致谢

3ds2apple 建立在开源工作之上：**Zakuro**（MIT，HLE 运行时与 PICA200 渲染器）、**3dsrecomp**（MIT，静态重编译器）、**MoltenVK**（Apache-2.0，Vulkan on Metal）、**Impactor**（MIT）与 **apple-codesign**（MPL-2.0，Windows 签名）、**pocket-native**（MIT，iOS 原生移植参考），以及 LLVM 项目的编译工具链。也感谢所有在真机上测试构建的人。

## 许可证与法律

3ds2apple 使用 **Apache-2.0** 许可（见 [LICENSE](LICENSE)）。本仓库不含任何 Nintendo ROM、解密密钥、BIOS、系统文件、游戏资源或游戏画面截图，也不提供 ROM 下载或盗版支持。请只使用你合法拥有并自行导出的游戏。

第三方组件及许可见 [THIRD_PARTY.md](THIRD_PARTY.md) 与 [NOTICE](NOTICE)。启动器原样内置官方 Impactor v2.7.2 + plumesign 发布文件（MIT；其中内嵌的 apple-codesign 0.29.0 为 MPL-2.0），许可文本保存在 [licenses/impactor](licenses/impactor)。GPL 项目仅作为架构参考阅读，不复制其代码或文本。