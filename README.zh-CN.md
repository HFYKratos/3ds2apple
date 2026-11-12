# 3ds2apple

[English](README.md) | **简体中文**

> **把你自己拥有的 Nintendo 3DS 游戏，以原生 ARM64 代码运行在 iPhone / iPad 上。**

游戏代码在构建时由 [3dsrecomp](https://github.com/fearkov/3dsrecomp) 翻译成 C，再编译成 ARM64；运行时由 [Zakuro](https://github.com/fearkov/zakuro) 提供 3DS 系统服务、GPU 和少量解释器兜底。**没有 CPU JIT。**

平台：iPhone / iPad（iOS 16+） · 构建：macOS + Xcode · 安装：Sideloadly / AltStore 侧载 · 许可：Apache-2.0 · **自带游戏**

> **第一个实验版本：** [v0.1.0-alpha](https://github.com/HFYKratos/3ds2apple/releases/tag/v0.1.0-alpha)（源码 + 无游戏数据的 shell IPA）；发布说明提供[英文版](docs/releases/v0.1.0-alpha.md)与[简体中文版](docs/releases/v0.1.0-alpha.zh-CN.md)。
>
> **状态：早期开发。** Pokémon Y（美版）已验证 AOT 代码生效、Metal 直接呈现、接近 60fps；pipeline cache 可持久化，第二次启动不再重复编译。首次启动仍可能遇到 pipeline 编译尖峰，正在优化。兼容性和功能会随版本变化。

## 试用 v0.1.0-alpha（shell）

GitHub Release 里的 `3ds2apple-shell-v0.1.0-alpha.ipa` 是**无游戏数据的通用壳**：

- 安装后可以从 Files 导入你自己的 `.3ds` / `.cci`，由 Zakuro 解释器直接运行；
- 它**不包含**任何 per-game AOT 代码，因此只能用于验证安装、UI、兼容性和基本运行；
- 帧率会明显低于 per-game AOT 构建，部分游戏可能非常慢；
- IPA 未签名，用 Sideloadly / AltStore 和你的 Apple ID 安装。

想获得 Pokémon Y 实测的接近 60fps，需要在你自己的 Mac 上按 [docs/build.md](docs/build.md) 用你的 ROM 构建 per-game AOT IPA。该 IPA 含游戏衍生代码，**不会**随 Release 分发。

## 原生移植，不是 CPU 模拟器

传统 3DS 模拟器在运行时逐条翻译 CPU 指令。3ds2apple 把这一步放到构建时：

- 每款游戏用 3dsrecomp 把 ARM / Thumb / VFP 代码翻译成 C；
- C 代码用 iOS clang 编译成 ARM64，链接进 App；
- 运行时只保留游戏仍需要的部分：HLE 系统服务、PICA200 GPU、音频、输入；
- 未被重编译覆盖的少量指令由 Zakuro 解释器兜底（测试游戏约 0.2%）。

因此设备上运行的是**普通 ARM64 代码**，不需要 JIT，也不需要调试器注入。

## 工作原理

```text
你自己的 .3ds / .cci（不会上传或内置）
        │
        ▼
   3dsrecomp（构建机）
        │  生成 C 代码
        ▼
   clang -target arm64-apple-ios
        │  libgame.a
        ▼
   SwiftUI 壳  +  libzakuro_ios.a（Zakuro 运行时）
        │
        ▼
   unsigned IPA → 侧载签名 → iPhone / iPad
```

iOS 侧通过一个很小的 C ABI（`ios/zakuro-ios/`）调用 Zakuro：加载 ROM、跑帧、读上下屏、取音频、送输入。游戏代码与运行时都静态链接进 App，每款游戏一个 IPA。

## 当前状态

- iPhone / iPad 真机可以启动 SwiftUI 壳、导入自有 ROM、显示上下屏；
- 触摸按键、GameController、下屏触摸和音频输出可用；
- Pokémon Y（美版）的 3dsrecomp AOT 代码已静态链接，运行时确认 AOT 生效；
- 性能 HUD 与 free-run 帧循环已接入，可在设备上查看各阶段帧时间；
- GPU 通过 MoltenVK / Vulkan 直接呈现到 CAMetalLayer，并保留软件回退；
- Pokémon Y AOT 在 A16 上接近 60fps；pipeline cache 已持久化；
- 首次运行的 GPU pipeline 编译放在加载页完成：ROM 载入后先在 "Preparing
  graphics" 遮罩后跑若干帧（至少 2 秒、连续 90 帧无 >50ms 尖峰、最多 5 秒），
  再把游戏显示出来；同一 ROM 的 cache 保存在 App 的 Caches 目录，第二次运行
  直接读取，预热明显更短；渲染器回退到软件时跳过预热；
- 应用内可导出诊断日志（设备 / 构建 / AOT / 帧时间）；
- 兼容性、稳定性和更多游戏的支持仍在验证中。

> 游戏画面和测试数据只用于本地验证，不进入仓库；本仓库不包含任何 ROM、密钥、系统文件或游戏资源。

## 平台与限制

| 项目 | 说明 |
|---|---|
| 设备 | iPhone / iPad，iOS 16 及以上（开发机：iPhone 14 Pro Max，iOS 26.7.2） |
| 构建 | macOS + Xcode（iOS SDK）；Rust 用于 Zakuro 静态库 |
| 安装 | 未签名 IPA，用 Sideloadly / AltStore 以你自己的 Apple ID 签名 |
| CPU | AOT 重编译，无 JIT；少量解释器兜底 |
| GPU | Metal（经 MoltenVK / CAMetalLayer），带软件回退 |
| 首版不在范围 | App Store、相机、麦克风、联机、全游戏库兼容 |

## 开始构建

完整步骤见 [docs/build.md](docs/build.md)。简要流程：

```bash
# 1. 构建 Zakuro iOS 静态库（macOS + Xcode + Rust + aarch64-apple-ios）
scripts/build-zakuro-ios.sh

# 2. 构建通用壳 / 无游戏的 App，产出 unsigned IPA
scripts/build-ios-app.sh
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple

# 3. 每款游戏：3dsrecomp → libgame.a → linked 静态库 → IPA
scripts/build-recomp-ios.sh "path/to/game.cci" pokemon-y --auto-serial
scripts/build-linked-ios-lib.sh pokemon-y
scripts/build-game-ipa.sh pokemon-y --display-name "Pokemon Y"
```

[builder/](builder/README.md) 里的桌面 Builder 可以从 Windows 或 Linux 机器通过 SSH 驱动 macOS 构建，复用同一套脚本。脚本细节见 [scripts/README.md](scripts/README.md) 与 [scripts/AOT_BUILD.md](scripts/AOT_BUILD.md)。

## 自带游戏

本项目**不提供** ROM、解密密钥、BIOS、系统文件或游戏资源，也不提供获取途径。

- 只能使用你自己从自己的主机上导出、已解密的游戏；
- 构建和运行都在你自己的机器上进行；
- 仓库和 CI 不接收、不上传、不缓存 ROM 或由游戏生成的数据；
- 兼容性报告只描述游戏和问题，不包含游戏文件。

## 项目结构

```text
ios/app/                 SwiftUI iOS 壳（上下屏、输入、音频、HUD）
ios/zakuro-ios/          Zakuro 的 iOS C ABI 与 staticlib crate
ios/ZakuroBridge.h       Swift 与 C ABI 的桥接头
builder/                 Windows/Linux 桌面 Builder + macOS Build Agent
scripts/                 静态库 / AOT / IPA 构建脚本
docs/architecture.md     架构与设计说明
docs/build.md            构建指南
docs/releases/           发布说明（英文 + 简体中文）
THIRD_PARTY.md           第三方组件与许可证
CONTRIBUTING.md          贡献指南
NOTICE                   版权、商标与无 ROM 声明
```

## 致谢

- **[Zakuro](https://github.com/fearkov/zakuro)**（MIT）：3DS HLE 运行时，使用 AOT 代码而不是 JIT。
- **[3dsrecomp](https://github.com/fearkov/3dsrecomp)**（MIT）：ARM / Thumb / VFP → C 静态重编译器。
- **[Pocket Native](https://github.com/whovian64/pocket-native)**（MIT）：Zakuro + 3dsrecomp 的 AOT 分支，为本项目的 AOT 链接、渲染器和游戏配置提供了重要参考。
- **Azahar / Citra**（GPL，仅行为参考）：3DS HLE、GPU、PICA200 语义的兼容性参考；没有将 GPL 代码链接进本项目。
- **nxnative / S2Arm**（MIT / Apache-2.0）：同 ISA 游戏原生移植到 iOS 的工程与平台层参考。
- **MoltenVK**（Apache-2.0）：Vulkan → Metal 兼容层，已用于直接呈现。

完整许可证说明见 [THIRD_PARTY.md](THIRD_PARTY.md) 与 [NOTICE](NOTICE)。

## 许可与法律

本项目以 [Apache License 2.0](LICENSE) 开源。

本项目与 Nintendo 无关联，未获得 Nintendo 的认可或赞助。Nintendo 3DS 是 Nintendo Co., Ltd. 的商标；游戏名称与商标归各自权利人所有。

本项目不包含任何 Nintendo ROM、解密密钥、系统文件、字体或游戏资源。请只使用你自己合法拥有并导出的游戏。
