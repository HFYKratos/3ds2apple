# Pocket Native 评估（2026-11-12）

> <https://github.com/whovian64/pocket-native> · MIT · Rust · 111★
>
> 结论：**这是目前最接近本项目的公开实现，应该作为 AOT 集成、渲染器和 per-game
> 配置的主要参考，而不是继续从 vanilla Zakuro/3dsrecomp 从零摸索。**

## 1. 它是什么

Pocket Native = **Zakuro + 3dsrecomp 的 AOT 分支**，目标是把 3DS 游戏在 PC 上
**一次性重编译**成手持设备/Android 的原生程序，运行在 R36S、H700、RG DS、Android
手机等低功耗设备上。

- 仓库结构：`engine/`（Zakuro fork：CPU/HLE/GPU/音频）、`recompiler/`（3dsrecomp
  fork + `port` 模式）、`frontend/`（KMS/framebuffer + evdev + ALSA）、`android/`
  （NativeActivity/JNI）、`titles/<title id>/profile.toml`（per-game 配置）。
- 构建：x86_64 PC 上 Docker/Podman 容器运行 `scripts/build.sh`；`3dsrecomp build`
  生成 `.so`，再把游戏和 `.so` 放进 `Pocket Native` 文件夹，复制到设备。
- 兼容性：Pokémon **Y / Alpha Sapphire / Ultra Moon** 都是其展示/可玩列表中的
  游戏；`titles/0004000000055E00`（Y）、`000400000011C500`（AS）、
  `00040000001B5000`（USUM）已有 profile。
- MIT；`CREDITS.md` 明确 upstream 为 Zakuro、3dsrecomp，并保留 fearkov/whovian
  版权。**可复用，但必须保留 MIT 声明与 CREDITS 归属。**

## 2. 与本项目的关系

| 维度 | Pocket Native | 3ds2apple |
|---|---|---|
| CPU | AOT 重编译 + 解释器兜底 | 同 |
| 运行时 | Zakuro fork | vanilla Zakuro（当前） |
| 重编译器 | 3dsrecomp fork（含 `port` 静态链接） | upstream 3dsrecomp（当前只做了调研） |
| 渲染 | OpenGL ES 3.1（Mali 优化） | 软件渲染（当前） |
| 前端 | KMS/framebuffer/evdev/ALSA + Android | SwiftUI/UIKit + CoreAudio/GameController |
| 平台 | Linux 手持机、Android | iOS（侧载） |
| 构建 | PC Docker/Podman，per-game 原生程序 | macOS VM，per-game IPA |
| 配置 | `titles/<id>/profile.toml` | 尚未实现 |

**它已经解决了我们 I3/I4 最难的几件事**：AOT 代码如何静态链接进运行时、per-game
构建、shader 首次构建、游戏 profile、低功耗性能调优；我们缺的只是 iOS 前端和
iOS 工具链。

## 3. 可直接复用的部分

| 部分 | 复用方式 | 注意 |
|---|---|---|
| `recompiler/src/port.rs` | 静态 `Linked::new(program_id, recomp_abi, entries, count, modules, count)` 的完整范式 | 我们的 `zakuro-ios` 可按同样方式把生成 C 的符号交给 `Config.linked` |
| `recompiler/`（3dsrecomp fork） | 替代 upstream 3dsrecomp，生成 C/`.so`/静态库 | MIT；需保留 CREDITS |
| `engine/`（Zakuro fork） | 获得 GLES 渲染器、性能修复、Android/手持机前端所需的 core 改动 | fork 与 vanilla 有差异；FFI 需适配 `System`/`Config` API |
| `titles/<id>/profile.toml` | 直接采用 Pokémon Y/AS/USUM 的 profile（性能选项、分辨率、按键等） | 游戏版本要匹配；profile 语法需移植到我们的 app |
| `docs/compatibility.md` | 兼容性/已知问题/性能数据参考 | 只作参考，不复制游戏数据 |
| `android/src/lib.rs` | iOS 前端生命周期的参考（窗口/输入/音频/第二屏） | JNI/Android 专用，不能直接编译 |

## 4. 不能直接复用的部分

- **Linux 手持机前端**：KMS/framebuffer/evdev/ALSA 在 iOS 不存在；我们继续用
  SwiftUI + CAMetalLayer/MoltenVK + CoreAudio + GameController。
- **OpenGL ES 渲染器**：iOS 的 OpenGL ES 已弃用但可用；短期可作为硬件渲染捷径，
  长期仍建议 Metal 后端（或 GLES→Metal 封装）。需先验证 iOS 上 GLES 3.1 的可用性与
  性能，再决定。
- **构建容器**：容器产出 Linux/Android 二进制；iOS 需要把生成的 C 用
  `clang -target arm64-apple-ios` 编译，再与 `libzakuro_ios.a` 静态链接或做签名
  dylib。容器本身可在 CachyOS 上跑（Docker 已可用），负责“重编译”这一步。
- **Android APK/签名**：iOS 用 IPA + Sideloadly/AltStore。

## 5. 对现有计划的影响

### I3-T2（3dsrecomp 静态链接）——改为以 Pocket Native 为主参考

- 不再从 upstream 3dsrecomp 的 `port` 模式重新推导；直接看
  `recompiler/src/port.rs` 的 `Linked::new` 与 `librecomp.a` 链接方式。
- 在 `ios/zakuro-ios` 增加静态 `Linked` 构造路径：
  - 生成 C 里的 `recomp_abi`/`recomp_entries`/`recomp_entry_count`/
    `recomp_modules`/`recomp_module_count` 符号；
  - 编译成 `libgame.a`；
  - `zk_create` 时把这些符号交给 `zakuro_core::Config.linked`。
- 构建脚本：CachyOS Docker 跑重编译 → 生成 C → macOS VM 用 iOS clang 编译
  `libgame.a` → Xcode 链接。

### I3-T3（渲染器）——新增评估

- 方案 A：把 Pocket Native 的 GLES 3.1 渲染器接到 iOS 的 `CAEAGLLayer`/GLES 上下文
  （快，但 API 已弃用）。
- 方案 B：以它的 PICA200→GLES 翻译为参考，写 Metal 后端（长期）。
- 先做 A 的 spike；如果 iOS 26 上 GLES 可用且性能可接受，可作为 v1 的硬件渲染路径。

### I4（10 款）——采用 per-game profile

- 直接沿用 `titles/<id>/profile.toml` 的结构，先把 Pokémon Y/AS/USUM 的 profile
  移植进来；profile 可控制分辨率、帧率、GPU 行为、按键等。
- 兼容性测试参考 `docs/compatibility.md` 的记录，但以我们真机结果为准。

## 6. 风险

- **许可证/归属**：MIT 允许商用/闭源，但必须保留版权与许可声明；我们的 Apache-2.0
  仓库要新增 `THIRD_PARTY`/`NOTICE` 归属，不能把 Pocket Native 的代码当成自有。
- **Fork 漂移**：Pocket Native 是活跃 fork，和 vanilla Zakuro/3dsrecomp 有差异；
  选定一个 commit 固定，避免上游变动导致不可复现。
- **GLES 弃用**：iOS 可能在未来版本移除 OpenGL ES；v1 可用，长期要 Metal。
- **构建链**：容器在 Linux x86_64 跑；iOS 交叉编译仍需 macOS SDK；两段式构建要
  脚本化、可复现。
- **游戏版本**：profile 与 ROM 版本绑定；更新/DLC 可能使 profile/重编译失效。

## 7. 下一步

1. **runtime-ffi**：按 `recompiler/src/port.rs` 在 `ios/zakuro-ios` 落地静态
   `Linked` 路径；更新 `RECOMP.md`。
2. **build-infra**：在 CachyOS 用 Docker 跑 Pocket Native 构建容器，先对 Pokémon Y
   产出生成 C/`librecomp.a`，验证与 `libzakuro_ios.a` 的符号/ABI 兼容。
3. **ios-shell**：继续输入/音频；后续把 Pocket Native 的布局/菜单思路映射到 SwiftUI。
4. **Lead**：固定 Pocket Native commit，更新 `AGENTS.md`/`THIRD_PARTY.md`，再决定
   是否把 `engine/` 整体换成 Pocket Native fork。