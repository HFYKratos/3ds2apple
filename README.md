# 3ds2apple

> **把你自己拥有的 Nintendo 3DS 游戏，以原生 ARM64 代码运行在 iPhone / iPad 上。**

游戏代码在构建时由 [3dsrecomp](https://github.com/fearkov/3dsrecomp) 翻译成 C，再编译成 ARM64；运行时由 [Zakuro](https://github.com/fearkov/zakuro) 提供 3DS 系统服务、GPU 和少量解释器兜底。**没有 CPU JIT。**

平台：iPhone / iPad（iOS 16+） · 构建：macOS + Xcode · 安装：Sideloadly / AltStore 侧载 · 许可：Apache-2.0 · **自带游戏**

> **状态：早期开发。** 当前验证到 Pokémon Y（美版）可以启动、显示上下屏、AOT 代码生效；图形仍由软件 PICA200 渲染，Metal 后端在开发中。兼容性、帧率和功能会随版本变化。

## 原生移植，不是 CPU 模拟器

传统 3DS 模拟器在运行时逐条翻译 CPU 指令。3ds2apple 把这一步放到构建时：

- 每款游戏用 3dsrecomp 把 ARM/Thumb/VFP 代码翻译成 C；
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

## 当前进度

- [x] iPhone 真机运行 SwiftUI 壳
- [x] 导入自有 `.3ds` / `.cci`，加载 3DS 运行时
- [x] 上屏 400×240 / 下屏 320×240 显示
- [x] 触摸按键、GameController 手柄、下屏触摸
- [x] 音频输出（AVAudioEngine）
- [x] Pokémon Y 的 3dsrecomp AOT 代码静态链接，运行时确认 AOT 生效
- [x] 性能 HUD（帧时间分解）与 free-run 帧循环
- [ ] GPU 硬件渲染（Metal / MoltenVK）
- [ ] 更多游戏兼容性与 20 分钟稳定性验证

> 游戏画面和测试数据只用于本地验证，不进入仓库；本仓库不包含任何 ROM、密钥、系统文件或游戏资源。

## 平台与限制

| 项目 | 说明 |
|---|---|
| 设备 | iPhone / iPad，iOS 16 及以上（开发机：iPhone 14 Pro Max，iOS 26.7.2） |
| 构建 | macOS + Xcode（iOS SDK）；Rust 用于 Zakuro 静态库 |
| 安装 | 未签名 IPA，用 Sideloadly / AltStore 以你自己的 Apple ID 签名 |
| CPU | AOT 重编译，无 JIT；少量解释器兜底 |
| GPU | 当前软件 PICA200 渲染；Metal 后端开发中 |
| 不在首版范围 | App Store、相机、麦克风、联机、全游戏库兼容 |

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

脚本细节见 [scripts/README.md](scripts/README.md) 与 [scripts/AOT_BUILD.md](scripts/AOT_BUILD.md)。

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
scripts/                 静态库 / AOT / IPA 构建脚本
docs/architecture.md     架构与设计说明
docs/build.md            构建指南
THIRD_PARTY.md           第三方组件与许可证
CONTRIBUTING.md          贡献指南
NOTICE                   版权、商标与无 ROM 声明
```

## 致谢

- **[Zakuro](https://github.com/fearkov/zakuro)**（MIT）：3DS HLE 运行时，使用 AOT 代码而不是 JIT。
- **[3dsrecomp](https://github.com/fearkov/3dsrecomp)**（MIT）：ARM / Thumb / VFP → C 静态重编译器。
- **[Pocket Native](https://github.com/whovian64/pocket-native)**（MIT）：Zakuro + 3dsrecomp 的 AOT 分支，为本项目的 AOT 链接、渲染器和游戏配置提供了重要参考。
- **Azahar / Citra**（GPLv3，仅行为参考）：3DS HLE、GPU、PICA200 语义的兼容性参考；没有将 GPL 代码链接进本项目。
- **nxnative / S2Arm**（MIT / Apache-2.0）：同 ISA 游戏原生移植到 iOS 的工程与平台层参考。
- **MoltenVK**（Apache-2.0）：计划中的 Vulkan → Metal 兼容层。

完整许可证说明见 [THIRD_PARTY.md](THIRD_PARTY.md) 与 [NOTICE](NOTICE)。

## 许可与法律

本项目以 [Apache License 2.0](LICENSE) 开源。

本项目与 Nintendo 无关联，未获得 Nintendo 的认可或赞助。Nintendo 3DS 是 Nintendo Co., Ltd. 的商标；游戏名称与商标归各自权利人所有。

本项目不包含任何 Nintendo ROM、解密密钥、系统文件、字体或游戏资源。请只使用你自己合法拥有并导出的游戏。
