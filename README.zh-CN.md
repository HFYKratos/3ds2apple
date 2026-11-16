<img src="assets/icon.png" width="112" alt="3ds2apple 图标">

# 3ds2apple

[English](README.md) | [简体中文](README.zh-CN.md)

**把你自有的 Nintendo 3DS 游戏以原生方式带到 iPhone / iPad。** 3ds2apple 是一套
以桌面启动器为中心的工具：导入你自有的已解密 ROM，提前把游戏编译成原生 ARM64 库，
生成不含 ROM 的 iOS App，用你自己的 Apple ID 签名安装 —— 游戏在手机上以原生代码运行，
不使用 CPU JIT，也不包含模拟器内核。

> 3ds2apple 不含、不下载也不链接任何 Nintendo ROM、解密密钥、BIOS 或系统文件，
> 与 Nintendo 没有任何隶属、授权或赞助关系。请只导入你合法拥有并自行导出的游戏。

![Windows 启动器 — 游戏库](launcher/windows/docs/ui/v4-library-zh.png)

*Windows 启动器游戏库页面（合成演示条目，不含游戏数据）。*

![macOS 启动器 — 空游戏库](launcher/macos/screenshots/launcher-library-empty-dark-en.png)

*macOS 启动器空游戏库页面。*

## 一个产品，三部分

| 部分 | 作用 |
|---|---|
| **Windows 启动器** — `launcher/windows`，C#/Avalonia | 导入 `.3ds`/`.cci` ROM；用内置的开源 LLVM/LLD 工具链在 PC 上为每个游戏编译 GamePack；合成不含 ROM 的基础壳 IPA（壳 + packs + MoltenVK + catalog）；用内置的官方 Impactor/plumesign 和你自己的 Apple ID 签名安装；随后只把游戏数据推送到手机。 |
| **macOS 启动器** — `launcher/macos`，SwiftUI | 在 Mac 上完成同样的一键流程：Apple clang 编译 GamePack，Xcode 自动签名 + devicectl 安装 IPA，然后推送游戏数据。 |
| **iOS App** — `ios/app`，SwiftUI | 手机端壳：游戏库、游戏内菜单、触摸控制和存档。它从已签名的 App 包内加载 AOT GamePack，用 Zakuro HLE 运行时和 MoltenVK 提供的 Metal 路径运行。 |

同一仓库内的配套工具：`builder/`（`3ds2apple-pack`：ROM 导入、SMDH 元数据、
包与 GameCatalog）、`tools/devpush`（设备桥：usbmuxd/AFC 推送与安装校验）、
`tools/winbuild`（Windows/Linux 上不依赖 Apple SDK 的 LLVM/LLD GamePack 构建文档）。

## 工作原理

```text
你自有的已解密 ROM (.3ds/.cci)
  → 启动器导入（只读 ROM 头 + SMDH 图标）
  → 3dsrecomp：ARM/Thumb → C
  → 本机 clang：C → arm64 GamePack-<TITLEID>.dylib
  → 启动器合成不含 ROM 的壳 IPA（壳 + packs + MoltenVK + GameCatalog.json）
  → 你的 Apple ID 签名（Windows 用 Impactor/plumesign，macOS 用 Xcode）并安装
  → devpush 只推送 Documents/Games/<TITLEID>/{GameRom.cci, GameInfo.json}
  → App 运行 AOT 代码：Zakuro HLE + MoltenVK/Metal
```

每游戏的可执行代码**必须**位于已签名的 IPA 内：iOS 不允许从 Documents 加载未签名代码。
因此启动器总是为你选中的游戏重新合成并签名 IPA；之后只推送游戏数据（ROM + 元数据），
这些数据在重装和 App 更新后仍然保留。

## 特性

- **原生 AOT 执行** —— 每个游戏都提前重编译为 ARM64，手机直接运行。不使用 CPU JIT，
  不在设备上重新编译。
- **一个 App 装下整个游戏库** —— 壳内携带 catalog 和每个选中游戏的 GamePack；
  增删游戏只需再次部署。
- **桌面优先的工作流** —— 在同一个启动器窗口（游戏库 → 导入手机）完成导入、编译、
  合成、签名与安装；数据目录可便携地放在启动器旁边。
- **Metal 渲染** —— PICA200 GPU 路径经 MoltenVK 走 Metal，并带性能 HUD 与诊断。
- **官方签名工具，原样使用** —— Windows 启动器内置官方 Impactor v2.7.2 + plumesign
  （MIT / MPL-2.0，SHA-256 固定）；Apple ID 凭据不会经过 3ds2apple 代码。
- **宿主机可测** —— 每个组件都有无需游戏机或手机即可运行的自检/测试套件。

## 下载

公开发布只走 **[GitHub Releases](https://github.com/HFYKratos/3ds2apple/releases)**。
每次发布**只附两个平台包**：

- `3ds2apple-<version>-windows-x64.zip` —— Windows 10/11 启动器（单个自包含可执行文件）；
- `3ds2apple-<version>-macos-universal.zip` —— macOS 13+ 启动器（`.app`，Intel + Apple Silicon）。

说明：

- 不含 ROM 的**壳模板已内嵌在两个启动器里**，不需要单独下载；
- 发布**不附** `LICENSE`、`NOTICE`、`THIRD_PARTY.md`，也**不附** `SHA256SUMS.txt`：
  许可文本在本仓库内；完整性可在 GitHub Release 资产页面查看每个资产的 SHA-256 digest
  （也可在本地自行计算）；
- 发布资产不含任何游戏 ROM、解密密钥、BIOS、生成的 C 或每游戏代码：每游戏代码由启动器
  在本机从你自己的 ROM 现场编译；
- Release 正文只写产品版本与中英双语「更新要点」；发布规则见
  [CONTRIBUTING.md](CONTRIBUTING.md#release-policy)。

## 使用说明

**本 README 是唯一、完整的使用说明。** 各组件 README 仅为开发者笔记。

### 环境要求

- **Windows 10/11 x64** —— 无需 Mac，启动器自带工具链与签名工具；
- **或 macOS 13+**（Intel / Apple Silicon）并安装 **Xcode 15+** 用于签名与安装；
- **iOS 16+** 的 iPhone/iPad、USB 数据线，并开启**开发者模式**；
- 免费或付费 **Apple ID** 用于签名（只在 Impactor 或 Xcode 中输入）；
- 你合法拥有、已解密的 3DS ROM（`.3ds` / `.cci`）。

### Windows 启动器

1. 下载 `3ds2apple-<version>-windows-x64.zip`，解压到**可写目录**（不要放 `Program Files`）。
2. 从 Microsoft Store 安装 **Apple 设备**（或 iTunes），让手机可以通过 USB 访问。
3. 运行 `3ds2apple-launcher.exe`。exe 未做代码签名：校验 digest 后，在 SmartScreen 提示里
   选择「更多信息 → 仍要运行」。先运行一次 Settings → self-test，应为绿色（内置工具校验通过）。
4. **游戏库 → 导入**：选择你自有的已解密 `.3ds`/`.cci`。启动器只读取 ROM 头与 SMDH
   图标/名称/发行商。
5. **导入手机（Deploy）**：勾选一个或多个游戏，按唯一的一键部署按钮。启动器为每个游戏编译
   GamePack、合成一个不含 ROM 的 IPA，用内置的官方 Impactor/plumesign 签名安装（首次部署会
   打开 Impactor，用你自己的 Apple ID 登录），随后只把每个游戏的 `GameRom.cci` +
   `GameInfo.json` 推送到 `Documents/Games/<TITLEID>/`。
6. 等到「可以打开手机 App 游玩 / Done」后，在手机上打开 App 游玩。增删游戏需要再次部署；
   已推送的游戏数据会保留；彻底卸载 App 会清空 App 数据。

### macOS 启动器

1. 下载 `3ds2apple-<version>-macos-universal.zip` 并解压，得到 `3ds2apple-launcher.app`。
2. 该 App 未公证：校验 digest 后首次用右键 →「打开」绕过 Gatekeeper。
3. 前置条件 —— macOS 包**尚不自包含**，需要：macOS 13+、Xcode 15+ 并在 Xcode → Settings →
   Accounts 里登录自己的 Apple ID、`xcodegen`、仓库 checkout 以及已构建的工具
   （`scripts/build-zakuro-ios.sh` 生成 `build/ios/libzakuro_ios.a`；`builder` 的 pack CLI；
   `tools/devpush`）。启动器会在自身 bundle、checkout 或 `PATH` 中查找这些工具。
4. 运行 App → **游戏库 → 导入** → **导入手机**。Apple clang 编译每个 GamePack，Xcode 自动签名
   + `devicectl` 安装合成后的 IPA，随后启动器推送游戏数据。选择/更新规则与 Windows 相同。

### 手机数据、存档与限制

- App 把游戏数据放在 `Documents/Games/<TITLEID>/`（可在「文件」App 中查看）；存档与即时存档
  保存在 App 容器内。
- 免费 Apple ID：每台设备 3 个 App、签名约 7 天有效 —— 到期后重新部署即可续签；付费开发者账号
  没有这些限制。
- 卸载 App 会删除其数据；你电脑上的 ROM 不受影响。

### 常见问题（FAQ）

**为什么必须自备 ROM？** 3ds2apple 不分发 ROM、密钥或 BIOS，也不提供下载；只支持用户自己
导出并解密的 ROM。

**为什么要在我的电脑上编译？** 每游戏 GamePack 由你的 ROM 派生，无法预置进公开发布包，
所以启动器在本机完成 AOT 编译并把结果签进 IPA。

**有 JIT 或兼容模拟器吗？** 手机端没有 CPU JIT：正式路径以原生 AOT 代码运行，经 Zakuro HLE
运行时与 Metal 呈现。

**哪些游戏能玩？** 兼容性按游戏区分；如果某个游戏无法启动或画面异常，请带上 title ID 提 issue
（见 [CONTRIBUTING.md](CONTRIBUTING.md)）。

**macOS 包为什么需要 checkout？** macOS 包目前是开发者预览，尚不自包含；Windows 包是单个
可执行文件。

## 从源码构建

| 组件 | 构建 / 测试 |
|---|---|
| Windows 启动器 | `cd launcher/windows && dotnet build Launcher.slnx -c Release` / `dotnet test Launcher.slnx -c Debug` —— 见 [launcher/windows/README.md](launcher/windows/README.md) |
| macOS 启动器 | 在 macOS 上用 XcodeGen + `xcodebuild` —— 见 [launcher/macos/README.md](launcher/macos/README.md) |
| iOS App / 壳 | `scripts/build-zakuro-ios.sh` → `scripts/build-ios-app.sh` → `scripts/package-ipa.sh` —— 见 [scripts/README.md](scripts/README.md) 与 [ios/app/README.md](ios/app/README.md) |
| Pack CLI（`3ds2apple-pack`） | `cd builder && cargo build --workspace` / `cargo test --workspace` —— 见 [builder/README.md](builder/README.md) |
| 设备桥（`devpush`） | `cargo build --release --manifest-path tools/devpush/Cargo.toml` —— 见 [tools/devpush/README.md](tools/devpush/README.md) |

宿主机自检（无需 Xcode、ROM 或手机）：

```bash
cd builder && cargo test --workspace
cd launcher/windows && dotnet test Launcher.slnx -c Debug
bash scripts/tests/perf-selfcheck.sh
bash scripts/tests/aot-selfcheck.sh
bash scripts/tests/game-catalog-selfcheck.sh
bash scripts/tests/desktop-aot-selfcheck.sh
```

AOT 构建开关、打包细节与排错见 [scripts/README.md](scripts/README.md)。

## 仓库结构

```text
assets/            本 README 使用的 App 图标
ios/app/           iOS App：游戏库、游戏内菜单、触摸控制、存档
ios/zakuro-ios/    Zakuro iOS C ABI：GamePack 加载器、Metal presenter、性能计数
launcher/windows/  Windows 启动器（C#/Avalonia）与单文件打包
launcher/macos/    macOS 启动器（SwiftUI）、Xcode 签名安装
builder/           3ds2apple-pack：ROM 导入、SMDH 元数据、包与 GameCatalog
tools/devpush/     设备桥：usbmuxd/house_arrest/AFC 推送、安装校验
tools/winbuild/    不依赖 Apple SDK 的 LLVM/LLD GamePack 交叉构建文档
scripts/           构建、打包、发布与自检脚本
licenses/          第三方许可文本（Impactor MIT、apple-codesign MPL-2.0）
```

## 贡献与发布

- [CONTRIBUTING.md](CONTRIBUTING.md) —— 贡献规则、问题反馈与**发布规范**（只发两个平台包、
  中英双语更新要点、tag/资产不可变）。
- [LICENSE](LICENSE) —— Apache-2.0。
- [THIRD_PARTY.md](THIRD_PARTY.md) 与 [NOTICE](NOTICE) —— 第三方组件与法律声明。

## 许可证与法律

3ds2apple 使用 **Apache-2.0** 许可（见 [LICENSE](LICENSE)）。本仓库不含任何 Nintendo
ROM、解密密钥、BIOS、系统文件、游戏资源或游戏画面截图，也不提供 ROM 下载或盗版支持。
请只使用你合法拥有并自行导出的游戏。

第三方组件及许可见 [THIRD_PARTY.md](THIRD_PARTY.md) 与 [NOTICE](NOTICE)。
启动器原样内置官方 Impactor v2.7.2 + plumesign 发布文件（MIT；其中内嵌的
apple-codesign 0.29.0 为 MPL-2.0），许可文本保存在
[licenses/impactor](licenses/impactor)。GPL 项目仅作为架构参考阅读，不复制其代码或文本。
