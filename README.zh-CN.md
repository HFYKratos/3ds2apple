# 3ds2apple

[English](README.md) | **简体中文**

> **把你自己拥有的 Nintendo 3DS 游戏，以原生 ARM64 代码运行在 iPhone / iPad 上。**

游戏代码在构建时由 [3dsrecomp](https://github.com/fearkov/3dsrecomp) 翻译成 C，再编译成 ARM64；运行时由 [Zakuro](https://github.com/fearkov/zakuro) 提供 3DS 系统服务、GPU 和少量解释器兜底。**没有 CPU JIT。**

平台：iPhone / iPad（iOS 16+） · 构建：macOS + Xcode · 安装：Sideloadly / SideStore / AltStore 侧载 · 许可：Apache-2.0 · **自带游戏**

> **当前 shell 版本：v0.1.5-beta3（2026-11-14）** — [GitHub Release](https://github.com/HFYKratos/3ds2apple/releases/tag/v0.1.5-beta3)
>
> 换了新应用图标；横屏改为“大画面上屏”布局（上屏放大在左、下屏缩小在右下），不再是上下堆叠拉伸；按键悬浮在画面上。
> New app icon; landscape now uses the large-top arrangement (large upper screen left, small lower screen at its lower right) instead of the stacked/stretched layout, with controls floating over the picture.

**状态：早期开发。** shell 可以导入你自己的 ROM、维护多游戏库并通过解释器运行；要达到接近 60fps 需要在自己 Mac 上用自有 ROM 构建 per-game AOT 版本。兼容性、稳定性和支持的游戏数量仍在验证中。

## 试用 shell 构建

v0.1.5-beta3 GitHub Release 里的 `3ds2apple-shell-0.1.5-beta3.ipa` 是**无游戏数据的通用壳**：

- 可以一次导入多个你自己已解密的 `.3ds` / `.cci` / `.cia`，文件复制进 App 并持久保存在游戏库中；
- 它**不包含**任何 per-game AOT 代码，游戏由 Zakuro 解释器运行，速度会明显低于 AOT 版本；
- IPA 未签名，用 Sideloadly / SideStore / AltStore 和你自己的 Apple ID 安装。

想获得 Pokémon Y 实测的接近 60fps，需要在你自己的 Mac 上按 [docs/build.md](docs/build.md) 用你的 ROM 构建 per-game AOT IPA。该 IPA 含游戏衍生代码，**不会**随 Release 分发。

## 原生移植，不是 CPU 模拟器

传统 3DS 模拟器在运行时逐条翻译 CPU 指令。3ds2apple 把这步提前到构建时：

- 每款游戏由 3dsrecomp 把 ARM / Thumb / VFP 代码翻译成 C；
- C 代码用 iOS clang 编译成 ARM64 并链接进 App；
- 运行时只保留游戏仍然需要的部分：HLE 系统服务、PICA200 GPU、音频和输入；
- 重编译未覆盖的少量指令回退到 Zakuro 解释器。

因此设备上运行的是**普通 ARM64 代码**——没有 JIT，也没有调试器注入。

## 工作原理

```text
你自己的 .3ds / .cci（不会上传或打包）
        │
        ▼
   3dsrecomp（构建机）
        │  生成的 C
        ▼
   clang -target arm64-apple-ios
        │  libgame.a
        ▼
   SwiftUI 壳 + libzakuro_ios.a（Zakuro 运行时）
        │
        ▼
   未签名 IPA → 侧载签名 → iPhone / iPad
```

iOS 侧通过一套小型 C ABI（`ios/zakuro-ios/`）调用 Zakuro：加载 ROM、运行帧、读取上下屏、取音频、发送输入。壳还会读取构建时生成的 `GameCatalog.json`，判断哪些 title ID 已链接 AOT 代码；其余走解释器。游戏代码和运行时静态链接进 App。

## 当前状态

- 多游戏库：网格首页、通过 Files 多选导入、持久化 `library.json`、删除、最近游玩时间、AOT/解释器徽标；
- Settings / 游戏内菜单 / 存档页统一为简洁分组风格；游戏页只保留上下屏、触摸按键和暂停/菜单按钮；
- 触摸按键、GameController、下屏触摸、音频输出、即时存档与电池存档导入/导出；
- 快进 1× / 2× / 4×（不再静音）、渲染分辨率 1×–4×、屏幕布局/旋转/比例设置；
- 通过 CAMetalLayer（MoltenVK）直接呈现，并保留软件回退；AOT/Metal 构建可在设置里请求 Metal Performance HUD（需重启）；
- pipeline cache 持久化在 App 的 Caches 目录，后续运行不会重复编译同一批 pipeline；可选的“Preparing graphics”预热默认关闭；
- 应用内可导出诊断（设备 / 构建 / AOT / 显示 / 帧时间 / 日志）；
- Pokémon Y（美版）在链接 AOT 代码、pipeline cache 预热后可在 A16 设备上接近 60fps；shell 构建（无 AOT）达不到。

当前 shell 的 UI 截图（Mac Catalyst 无头渲染，不含游戏内容）：[docs/qa/ui](docs/qa/ui)。

> 游戏画面和测试数据只用于本地验证，不进入仓库；本仓库不包含任何 ROM、密钥、系统文件或游戏资源。

## 路线图

下一版转向纯 AOT：用户在自己的电脑（Linux / Windows / macOS）上导入 ROM 并提前编译，手机端只安装每游戏 AOT 包，并移除解释器兜底。包结构与里程碑见 [docs/aot-first.md](docs/aot-first.md)。

## 平台与限制

| 项目 | 说明 |
|---|---|
| 设备 | iPhone / iPad，iOS 16 及以上（开发机：iPhone 14 Pro Max） |
| 构建 | macOS + Xcode（iOS SDK）；Rust 用于 Zakuro 静态库 |
| 安装 | 未签名 IPA，用 Sideloadly / SideStore / AltStore 以你自己的 Apple ID 签名 |
| CPU | AOT 重编译，无 JIT；少量解释器兜底 |
| GPU | Metal（经 MoltenVK / CAMetalLayer），带软件回退 |
| 暂不在范围 | App Store、相机、麦克风、联机、全游戏库兼容 |

## 开始构建

完整步骤见 [docs/build.md](docs/build.md)。简要流程：

```bash
# 1. 构建 Zakuro iOS 静态库（macOS + Xcode + Rust + aarch64-apple-ios）
scripts/build-zakuro-ios.sh

# 2. 构建 shell App，产出 unsigned IPA
scripts/build-ios-app.sh
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple-shell-0.1.5-beta1

# 3. 每款游戏：3dsrecomp → libgame.a → linked 静态库 → IPA
scripts/build-recomp-ios.sh "path/to/game.cci" pokemon-y --auto-serial
scripts/build-linked-ios-lib.sh pokemon-y
scripts/build-game-ipa.sh pokemon-y --title-id 0004000000055E00 \
  --display-name "Pokemon Y" --product-code CTR-P-EK2A
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
ios/app/                 SwiftUI iOS 壳（游戏库、上下屏、输入、音频、设置）
ios/zakuro-ios/          Zakuro 的 iOS C ABI / presenter / save state
ios/preview/             Mac Catalyst 无头 UI 预览（开发工具）
ios/ZakuroBridge.h       Swift 与 C ABI 的桥接头
builder/                 Windows/Linux 桌面 Builder + macOS Build Agent
scripts/                 静态库 / AOT / IPA 构建脚本
docs/architecture.md     架构与设计说明
docs/build.md            构建指南
docs/aot-first.md        下一版纯 AOT / 桌面端导入编译规划
docs/related-projects.md 同类项目与许可证调研
docs/qa/ui/              当前 UI 截图与重新生成方法
THIRD_PARTY.md           第三方组件与许可证
CONTRIBUTING.md          贡献指南
NOTICE                   版权、商标与无 ROM 声明
```

## 致谢

- **[Zakuro](https://github.com/fearkov/zakuro)**（MIT）：3DS HLE 运行时，运行 AOT 代码而不是 JIT。
- **[3dsrecomp](https://github.com/fearkov/3dsrecomp)**：ARM / Thumb / VFP → C 静态重编译器（构建时工具）。
- **[Pocket Native](https://github.com/whovian64/pocket-native)**（MIT）：Zakuro + 3dsrecomp 的 AOT 分支，为本项目的 AOT 链接、渲染器和游戏配置提供了重要参考。
- **Azahar / Citra**（GPL，仅行为参考）：3DS HLE、GPU、PICA200 语义的兼容性参考；没有将 GPL 代码链接进本项目。
- **nxnative / NX2Apple**（MIT）与 **S2Arm**（Apache-2.0）：同 ISA 游戏原生移植到 iOS 的工程与平台层参考。
- **MoltenVK**（Apache-2.0）：Vulkan → Metal 兼容层，已用于直接呈现。

完整许可证说明见 [THIRD_PARTY.md](THIRD_PARTY.md) 与 [NOTICE](NOTICE)。

## 许可与法律

本项目以 [Apache License 2.0](LICENSE) 开源。

本项目与 Nintendo 无关联，未获得 Nintendo 的认可或赞助。Nintendo 3DS 是 Nintendo Co., Ltd. 的商标；游戏名称与商标归各自权利人所有。

本项目不包含任何 Nintendo ROM、解密密钥、系统文件、字体或游戏资源。请只使用你自己合法拥有并导出的游戏。