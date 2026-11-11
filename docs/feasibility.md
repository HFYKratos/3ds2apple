# 3DS 游戏 AOT 原生移植到 iOS：可行性评估（v0.2）

> 2026-11-11 · 针对你的选择：**路线 B（无 CPU 模拟器）**、尽量兼容全部 3DS 游戏、不做逐款人工适配、侧载、开源、iPhone 14 Pro Max（A16 / 6 GB / iOS 26.7.2）。
>
> 上一版（v0.1，通用评估）见 [feasibility-v0.1.md](feasibility-v0.1.md)。执行细节（首发 10 款、无本地 Mac）见 [plan.md](plan.md)。

## 0. 结论

**可行，而且比我上一版估计的更可行：你要的"通用 AOT + 免逐款适配"，已经有人把核心做出来了——[3dsrecomp](https://github.com/fearkov/3dsrecomp) + [Zakuro](https://github.com/fearkov/zakuro)。缺的是 iOS 这一层，以及"全库兼容"的长尾。**

- **3dsrecomp**：ARM / Thumb / VFP → C 的静态重编译器。自动发现主程序和 CRO 模块里的函数，生成 C，编译成库；找不到/不支持的指令回退给 Zakuro 的解释器。作者用 4 款游戏测试，约 **99.8% 的指令**由重编译代码执行（Pokémon Y 0.21%、Persona Q 0.26% 走解释器）。
- **Zakuro**：MIT 许可的 3DS HLE 运行时，用 AOT 代替 JIT；自带内核、服务、GPU、音频。当前 **35 款测试游戏，34 款 Playable、1 款 In-game**，包括 Pokémon 全系、时之笛/假面/三角力量 2、MH4U/MHXX、火焰纹章、合金装备 3D、逆转裁判等。
- **Zakuro 没有 iOS 版**（只有 Windows / Linux / macOS）。所以项目主体不是"写模拟器"，而是"把 Zakuro + 3dsrecomp 移植到 iOS，并在 Mac 上做一条 3DS → IPA 的自动构建管线"。
- 你的 iPhone 14 Pro Max 够用；AOT 不需要 JIT；侧载 + 开源正好匹配 MIT。

**但必须接受两个现实：**

1. **它不是 100% "无模拟器"。** CPU 代码是构建时翻译的，但运行时仍有 HLE 系统服务、GPU 模拟、以及约 0.2% 指令的解释器兜底。**纯 AOT（零解释器）只适用于单款游戏**（TriAevum 对时之笛 3D），无法覆盖全库。
2. **"所有 3DS 游戏"是长期兼容性目标，不是首版承诺。** 当前 35 款；3DS 全库上千款。3dsrecomp 解决的是"代码翻译自动化"，Zakuro 解决的是"运行时兼容"；后者需要一款一款游戏地补 HLE/GPU/时序，像 Citra/Azahar 一样是长尾工程。

**一句话：这条路在技术上成立，而且有现成底座；它更像"做一个 3DS 版的 nxnative"，而不是"写一个 3DS 模拟器"。**

---

## 1. 你的目标 vs 现实

| 你的要求 | 对应实现 | 现实 |
|---|---|---|
| 无 CPU 模拟器（B） | 构建时 ARM→C→ARM64；运行时无 CPU JIT | 3dsrecomp 做到；但 HLE/GPU/解释器兜底仍在 |
| 兼容所有 3DS 游戏 | 通用 recompiler + 通用 HLE/GPU 运行时 | 架构通用；当前 35 款测试，全库是长尾 |
| 无需逐款人工适配 | 自动函数发现 + CRO + 回退 | 构建自动化；少数游戏需 override 修 bug，但不是人工移植 |
| 侧载 | IPA / AltStore / SideStore | 可行；不需要 App Store，也不需要 JIT |
| 开源 | MIT（Zakuro / 3dsrecomp） | 可行；注意 3dsrecomp 仓库没有 LICENSE 文件，需确认 |
| iPhone 14 Pro Max | A16 / 6 GB / iOS 26.7.2 | 够用；A16 支持 Metal 3；6 GB 对 3DS 足够 |

> **"无模拟器"要分三层看：**
> 1. **CPU**：3dsrecomp 构建时翻译，运行时基本不解释 → 这是你要的"原生"。
> 2. **系统服务/GPU**：HLE + GPU 模拟，无法"原生"（3DS 的 PICA200、ARM9、DSP 没有 iOS 对应物）。
> 3. **兜底**：未发现的代码/不支持指令走解释器，约 0.2%。
>
> 只要你能接受第 2、3 层，这条路就是正确的；如果要求三层都"零模拟"，只能做单款纯 AOT。

---

## 2. 关键证据：3dsrecomp + Zakuro

### 2.1 3dsrecomp 做了什么

- 输入：用户自有 `.3ds` / `.cci`（解密后的 ROM）。
- 分析：从入口点、调用、导出、重定位、数据里的指针、CRO 模块之间的导入关系找函数；剩下的区域再用启发式找函数开头。
- 翻译：ARM、Thumb、VFP → C；不常见的指令走解释器。
- 模块：CRO 代码生成位置无关的 C，游戏把它加载到哪里都能跑。
- 验证：`verify` 把重编译函数和 Zakuro 解释器从同一状态跑，比较寄存器、标志、内存。
- 兜底：没找到/没覆盖的代码仍由 Zakuro 解释器执行；下一次构建可以把"哪里还在解释"吃进去。
- 覆盖：测试的 4 款游戏约 **99.8%** 指令由重编译代码执行。
- 可选 override：手写 C 替换某个地址的函数，用于修 bug、mod、或更快的原生实现；**大多数游戏不需要**。
- 许可：`Cargo.toml` 写的是 MIT，但仓库里没有 `LICENSE` 文件——商用/分发前建议向作者确认。

### 2.2 Zakuro 做了什么

- Rust 写的 HLE 3DS 运行时：内核、SVC、服务（APT/GSP/HID/FS/DSP/CAM/NFC/IR/UDS…）、GPU、音频、存档、金手指、纹理包、mod、更新/DLC。
- 用 AOT 代替 JIT：加载 3dsrecomp 生成的库；没有库的代码走解释器。
- 平台：Windows / Linux / macOS（macOS 版较新，作者说还没在真 Mac 上充分验证）。
- 兼容性：35 款测试，34 Playable、1 In-game；大量重载游戏可玩。
- 性能：桌面端测试游戏"重编译后满速"；只靠解释器会低于满速。
- 许可：MIT。
- 规模：约 71,800 行 Rust；单作者项目，v0.2.32，仍在快速迭代。

### 2.3 它离"你的产品"还差什么

| 已有 | 还缺 |
|---|---|
| ARM→C 重编译器、函数发现、CRO、VFP、回退 | macOS 上的构建验证（3dsrecomp 官方只测 Linux/Windows） |
| HLE 运行时、GPU、音频、输入、存档、mod | iOS 平台层（UIKit/Swift、Metal/MoltenVK、CoreAudio、触摸/手柄） |
| 35 款游戏兼容数据 | iOS 打包/签名/构建管线 |
| MIT 许可 | 关闭 Cranelift shader JIT 后的性能验证 |
| 桌面 CLI / GUI | "全库兼容"的长尾测试与修复 |

---

## 3. 架构：3DS → iOS 的 AOT 管线

```
用户自有 ROM（.3ds/.cci，已解密）
        │
        ▼
┌─────────────────────────────────────────────┐
│ Mac / Linux 构建机                           │
│  3dsrecomp analyze/build                     │
│    ├─ 找函数（主程序 + CRO）                  │
│    ├─ ARM/Thumb/VFP → C                      │
│    ├─ clang -target arm64-apple-ios          │
│    └─ libgame.a + 元数据                      │
│  Zakuro 运行时（Rust）                        │
│    ├─ HLE 内核/服务                          │
│    ├─ PICA200 GPU（Vulkan/MoltenVK 或软件）   │
│    ├─ 解释器兜底（未覆盖代码）                │
│    └─ 链接 libgame.a → zakuro.a              │
└─────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────┐
│ iOS App（SwiftUI/UIKit）                     │
│  ├─ ROM/keys 导入（Files/DocumentPicker）     │
│  ├─ 视频：CAMetalLayer / MoltenVK             │
│  ├─ 音频：CoreAudio（cpal 或 AVAudioEngine）  │
│  ├─ 输入：GameController + 触摸 overlay       │
│  ├─ 双屏布局、存档、设置                      │
│  └─ IPA（AltStore/SideStore/TestFlight）      │
└─────────────────────────────────────────────┘
```

**关键点：**

- AOT 发生在**构建机**上，不在 iPhone 上；所以 iOS 不需要 JIT 权限。
- 每个游戏生成自己的 `libgame.a`，链接进 App（或作为单独 IPA）——这就是 nxnative/S2Arm 的"每款构建一次"模式，不是"一个二进制跑所有 ROM"。
- 运行时仍是一个 HLE 模拟器；"无模拟器"指 CPU 代码不再逐条解释/JIT，而不是没有 HLE/GPU。

**iOS 上的具体接法（重要）：**

- 用 3dsrecomp 的 `port` 静态链接模式，而不是 `build` 的共享库 + `dlopen`；Zakuro 的 `Config.linked` 支持把代码直接链进程序，绕开 iOS 对动态库加载的限制。
- 3dsrecomp 通过 `CC` 环境变量找 C 编译器；把 `CC` 指向一个包装脚本（`xcrun -sdk iphoneos clang -target arm64-apple-ios …`）即可交叉编译，不需要改生成器。
- 生成 C 的编译参数是 `-O2 -ffp-contract=off -fno-math-errno -fPIC -fvisibility=hidden`，clang 全部支持；`-ffp-contract=off` 是为了浮点结果与解释器逐位一致，别去掉。

---

## 4. 为什么 nxnative / S2Arm 看起来"通用"，3DS 要另走一条路

### 4.1 nxnative / S2Arm 的通用性来自"同 ISA"

- [nxnative](https://github.com/seedds/nxnative)：描述是 "NSO rewriter, Horizon HLE host, NVN→Metal"。Switch 的可执行文件是 **AArch64**，Apple 芯片也是 **ARM64**；它做的是把 NSO 重写/重链接、把 Horizon 服务 HLE、把 NVN 图形调用翻译到 Metal。**没有 ARM→ARM 的指令翻译**。
- [S2Arm](https://github.com/jhaizhou-ops/S2Arm)：同样，guest 是 AArch64，宿主是 ARM64；"code rewritten to native ARM64" 本质是重写/重链接 + HLE + NVN→Metal，不是跨 ISA 翻译。其 README 也明确说 32 位游戏不支持；它报告的规模是 211 款游戏、95% 首跑成功率。
- 它们的"免逐款适配"来自：**代码不用翻译，只需要重写加载/ABI/服务/图形**。这仍然是很大的工程，但不是每款游戏都要重新理解指令语义。

### 4.2 3DS 是 32 位 ARMv6K，必须跨 ISA

- 3DS 的 ARM11 是 **ARMv6K（32 位）**；iOS 是 **ARM64**。每一条指令都要翻译，且要处理 ARM/Thumb 混合、条件执行、VFP、CRO 重定位、间接跳转、数据里的函数指针。
- 所以"把 S2Arm 的管线改一改跑 3DS"不成立；必须有一个 **ARM32→ARM64 的翻译层**。
- **3dsrecomp 就是这个翻译层**：它把 ARM→C，再用 clang 编译到 ARM64。它和 nxnative 的 NSO rewriter 是同一生态位，只是跨了 ISA。
- 代价：每款游戏要跑一次重编译（约 10 分钟），且总有少量代码翻译不了 → 解释器兜底。这正是"通用 AOT"与"纯 AOT"的分界线。

### 4.3 结论

- nxnative/S2Arm 证明的是"**同 ISA 的通用构建管线**"可行。
- 3dsrecomp/Zakuro 证明的是"**跨 ISA 的通用 AOT 管线**"在 3DS 上可行（4 款 99.8% 覆盖、35 款可玩）。
- 你要做的，是把后者搬到 iOS；不是把前者的代码搬过来。

---

## 5. iOS 移植缺口与工作量

### 5.1 缺口清单

| 模块 | 现状（桌面） | iOS 需要 | 估算（人月） |
|---|---|---|---|
| Rust 核心 | `zakuro-core` 跨平台 | `aarch64-apple-ios` 静态库 + C ABI | 2–3 |
| 前端 | winit + glutin + egui 桌面窗口 | SwiftUI/UIKit + `CAMetalLayer` | 3–4 |
| 视频（MVP） | `read_screen` 返回 RGBA | Metal 纹理上传 + 双屏布局 | 1–2 |
| 视频（优化） | Vulkan（ash）/ OpenGL | MoltenVK / Metal surface；或继续软件渲染 | 2–4 |
| 音频 | cpal | cpal 的 CoreAudio 后端，或 AVAudioEngine | 0.5–1 |
| 输入 | winit 键盘/鼠标 + gilrs 手柄 | GameController + 触摸 overlay + 圆盘摇杆 | 1–2 |
| 相机/麦克风 | nokhwa | AVFoundation 或先 stub | 0.5–1 |
| 文件/ROM/keys | 桌面路径 + rfd | UIDocumentPicker + 沙盒目录 | 1 |
| 构建管线 | 3dsrecomp CLI（Linux/Windows） | macOS 上构建、C 交叉编译、IPA 打包 | 2–3 |
| Shader JIT | Cranelift（默认开启） | 关闭 JIT；顶点/几何 shader 解释执行，或做 AOT | 1–3 |
| 兼容/性能 | 35 款桌面测试 | iOS 真机 top 20–50、热降频、内存 | 3–6 |
| **合计** | | **MVP 约 9–14；产品级 16–28**（各行有重叠，不是严格相加） | |

### 5.2 建议的 MVP 捷径

先不要一上来就 port Vulkan/MoltenVK：

1. 用 `System::read_screen()` 拿 RGBA → 上传到 Metal 纹理 → 显示上下屏。3DS 分辨率低（400×240 + 320×240），A16 完全扛得住。
2. 音频用 `take_audio()` → AVAudioEngine。
3. 输入用 Swift 的 GameController + 触摸，调用 Rust 的 `set_input()`。
4. 先跑通 1 款游戏（建议 Super Mario 3D Land 或 Mario Kart 7），再扩到 5 款。
5. 等 MVP 稳定后，再把 `hardware_renderer` 打开，走 MoltenVK；或者继续软件渲染，把 CPU 留给 AOT 代码。

这样可以把"iOS 图形栈"风险推迟，先验证最核心的：**AOT 代码 + HLE + 音频 + 输入 + 打包**。

### 5.3 关键不确定性

- **Zakuro 的 macOS 构建**：作者说 macOS 版较新、未在真 Mac 充分验证；3dsrecomp 官方只测 Linux/Windows。Mac 是 iOS 构建的必经之路，需要先验证 `cargo build` + `clang` 交叉编译链路。
- **Shader JIT**：Zakuro 的 PICA200 顶点/几何 shader 在 CPU 上跑，默认用 Cranelift JIT 加速；iOS 必须关闭（不能用可执行内存），关闭后走批量解释器。**这是 iOS 性能的最大变数**，必须用真机测顶点密集场景（如马车 7、Smash）。
- **Vulkan/MoltenVK**：`ash-window` 是否直接支持 iOS 的 `VK_EXT_metal_surface` 需要验证；最坏自己写几十行 surface 创建，或先走软件渲染。
- **3dsrecomp 的 macOS 支持**：Rust + clang 理论上可跑，但没有官方 CI；需要在 Mac 上实测，或退到 Linux 容器/CI 构建。

---

## 6. 性能预期（A16 / iPhone 14 Pro Max）

> 以下为工程估算，必须以 Phase 0 真机数据替换。

| 场景 | 预期 | 说明 |
|---|---|---|
| 轻量/2D/早期 3DS | 满速（≥100%，有余量） | AOT 代码 + 软件/GPU 渲染都够 |
| 中型 3D（马车 7、时之笛 3D、3D Land） | 90–120% | 1× 分辨率；顶点 shader 解释可能掉帧 |
| 重载（MH4U、Pokémon USUM、Smash、FE if） | 60–100% | 可能需要跳帧/降分辨率；GPU 路径更好 |
| 软件渲染 vs MoltenVK | 软件更省事，GPU 更快 | 3DS GPU 简单，CPU 通常是瓶颈 |
| 热降频 | 20–30 分钟后 −15~30% | 30 fps cap、画质档、散热背夹 |
| Shader JIT 关闭 | 顶点密集场景 −10~40%（估） | 最大变数；需实测 |

**对照：** 作者称桌面端重编译后测试游戏满速；macOS 版还没在真 Mac 上充分验证。A16 单核与 M1 同档（峰值接近，持续性能受散热限制），而 3DS 的 CPU 只有 268 MHz，AOT 后的 ARM64 代码通常不是瓶颈。真正的瓶颈更可能是：shader 解释、GPU 路径、HLE 时序、以及 iOS 的散热。

---

## 7. 兼容性现实："所有游戏"到底有多远

### 7.1 当前数据

- Zakuro 兼容表：**35 款测试，34 Playable，1 In-game**（Tomodachi Life）。
- 3dsrecomp 覆盖：4 款测试约 **99.8%** 指令走重编译；剩余 0.2% 解释。
- 这 35 款覆盖了 Pokémon、Zelda、Mario、MH、FE、MGS、逆转等主流作品，说明 HLE/GPU 的骨架是通的。

### 7.2 长尾在哪里

- **HLE 服务**：eShop、StreetPass、SpotPass、Download Play、摄像机、麦克风、NFC、红外、UDS 联机等；很多游戏只用到一部分，但用到了就要补。
- **GPU**：PICA200 的纹理格式、shader 指令、渲染状态、帧缓冲/双屏；Zakuro 已覆盖不少，但边缘情况仍多。
- **时序/线程**：3DS 的双核/ARM9、系统节拍、音频同步；有些游戏对时序敏感。
- **CRO/overlay**：3dsrecomp 已处理位置无关，但每个游戏的加载方式可能不同。
- **更新/DLC/mod**：Zakuro 支持，但更新会改变代码，需要重新编译或回退解释。
- **反盗版/加密**：只支持已解密的自有 ROM；不处理密钥分发。

### 7.3 "无需逐款适配"的准确含义

- **构建**：每款游戏跑一次 `3dsrecomp build`，自动分析/翻译/编译，约 10 分钟；不需要人工读汇编、不需要每款写 adapter。**这是自动化的，符合你的要求。**
- **运行时**：如果某款游戏在 Zakuro 里黑屏/崩溃/图形错误，仍然要在 Zakuro 里修 HLE/GPU bug；这是"兼容性修复"，不是"逐款移植"。修好后对所有同类游戏都有益。
- **例外**：少数游戏可能需要 `--overrides` 手写一个函数（修 bug/性能），但这是例外，不是主流程。

**建议目标：** 首版 10–20 款主流游戏；6–12 个月做到 50–100 款；"全库"是 2–3 年的社区工程，不要作为首发承诺。

---

## 8. 与 TriAevum / Azahar 的定位

| 维度 | 3dsrecomp + Zakuro | TriAevum（单款纯 AOT） | Azahar（模拟器） |
|---|---|---|---|
| CPU | AOT + 少量解释器兜底 | 纯 AOT | 解释器（FastInterp）或 JIT |
| 覆盖 | 通用，多款 | 单款（OoT3D/MM3D） | 上千款 |
| "无模拟器"纯度 | ~99.8% 指令原生 | 100% CPU 原生 | 0（就是模拟器） |
| 每款工作 | 自动构建 + 兼容修复 | 人工移植 3–6 人月 | 无 |
| 性能 | 接近原生（AOT） | 最高（可 60fps/高清） | 中高（受解释器限制） |
| 许可 | MIT | GPLv3 | GPLv3 |
| 适合 | **你的"全库 + 免逐款适配"** | 1–2 款旗舰 | 快速验证/全库兼容 |

**结论：** 你的目标对应的是第一列。TriAevum 是"纯度"的证明，但不是"规模"的方案；Azahar 是"兼容性"的证明，但不是"无模拟器"的方案。

---

## 9. 许可、法律、分发

### 9.1 许可

- **Zakuro：MIT**，可商用、可修改、可闭源分发（保留版权声明）。
- **3dsrecomp：`Cargo.toml` 声明 MIT，但仓库没有 `LICENSE` 文件**。严格说，缺少 LICENSE 文件会让权利边界不清晰；建议向作者确认，或在分发前补一份 MIT 文本。
- **生成的 C 代码来自游戏**，属于游戏的衍生内容；不要随 App/源码分发，只放在用户自己的构建产物里。
- ROM、keys、游戏资源：用户自有；不内置、不下载、不分享。

### 9.2 Nintendo

- 2024-03：Yuzu 以 240 万美元和解并停止开发，Citra 作为附带损害下架。
- 2024-10：Ryujinx 被关停，域名归 Nintendo。
- 3DS eShop 2023 关闭、Nintendo Network 2024 停止，不等于 ROM 合法化。
- 侧载 + 开源降低"应用商店下架"的风险，但不消除版权/反规避风险；保持"BYO ROM、无密钥、无 ROM 下载"是底线。
- 不要用 Nintendo 商标/角色做应用图标/宣传；README 里保留免责声明。

### 9.3 分发

- **侧载**：AltStore / SideStore / Sideloadly / LiveContainer；IPA + 用户自己的 Apple ID 签名。
- **不需要 JIT**：AOT 代码是普通 ARM64 机器码，解释器兜底也是普通代码；这比 Azahar 路线更适合侧载。
- **不需要 App Store**：避开 2.5.2（不得执行下载代码）和 4.7 的合规麻烦。
- **开源**：MIT 运行时 + MIT 工具；构建脚本/文档一起开源，方便社区补兼容。

---

## 10. 路线图

### Phase 0：3–4 周，技术验证（Go/No-Go）

1. 在 Mac 上构建 Zakuro（`cargo build --release`），跑 3dsrecomp 的 `analyze/build`，测试 5 款游戏：3D Land、MK7、OoT3D、Pokémon USUM、MH4U。
2. 记录：能否启动、满速与否、GPU/软件渲染、shader 解释开销、CPU 占用。
3. 把 `zakuro-core` 编译成 `aarch64-apple-ios` 静态库；写一个最小 Swift App，调用 `System::new` + `run_frame` + `read_screen`，在 iPhone 14 Pro Max 上显示画面。
4. 跑通 1 款游戏（3D Land）的“ROM 导入 → 画面 → 触摸输入 → 音频”。
5. **通过标准**：1 款游戏在真机上可玩（≥90% 速度、无崩溃、音频正常）；5 款中 ≥3 款能启动。
6. **不通过**：先修 macOS 构建/FFI/性能，再谈产品；不要直接投入完整 App。

### Phase 1：3–5 个月，MVP

- SwiftUI 壳：游戏库、ROM/keys 导入、设置、双屏布局、横屏。
- 视频：`read_screen` → Metal 纹理；先软件渲染。
- 音频：`take_audio` → AVAudioEngine。
- 输入：GameController + 触摸 overlay + 圆盘摇杆。
- 构建管线：Mac 上 `3dsrecomp build` → C → `clang -target arm64-apple-ios` → 链接 → IPA。
- 目标：3–5 款游戏可玩，IPA 可侧载。

### Phase 2：4–6 个月，Beta

- 打开 `hardware_renderer`，走 MoltenVK；对比软件渲染的性能/兼容。
- Shader JIT 关闭后的优化：批量解释器调优、AOT shader（可选）、或对侧载用户提供 JIT 开关（可选）。
- 10–20 款游戏兼容；per-game 设置；存档/即时存档；金手指；快进。
- 热降频/帧率策略；崩溃日志；本地化。

### Phase 3：6–12 个月，产品化

- 50–100 款兼容；自动化测试/兼容列表。
- UI/UX 打磨；iCloud 存档；手柄皮肤；中文。
- 开源发布：构建脚本、文档、兼容列表、贡献指南。
- 可选：Metal 原生后端（替代 MoltenVK）；AOT shader 编译。

### 团队

- 1× Rust/C++ 系统工程师（Zakuro/3dsrecomp/FFI）
- 1× iOS/Swift + 图形（Metal/MoltenVK、音频、输入）
- 0.5× QA/兼容测试
- 你已有的 S2Arm 经验（IPA 打包、侧载、Metal、启动器）能显著加速 Phase 1–2。

---

## 11. 风险矩阵

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| Zakuro 桌面构建/macOS 链路不稳 | 中 | 高 | 先在 Mac 验证；必要时 Linux CI 构建 |
| iOS FFI/生命周期/音频/输入 | 中 | 中 | 先做最小 App；用 `read_screen` 绕过 GPU |
| Shader JIT 关闭后性能不足 | 高 | 高 | 真机测顶点密集场景；批量解释器调优；AOT shader；侧载 JIT 开关 |
| MoltenVK/ash surface 不兼容 | 中 | 中 | 先软件渲染；自定义 surface；或 Metal 后端 |
| 兼容性长尾 | 高 | 高 | 先 10–20 款；建兼容列表；社区贡献 |
| 3dsrecomp 覆盖率/边缘指令 | 中 | 中 | 回退解释器；override；上游修 |
| 3dsrecomp LICENSE 文件缺失 | 中 | 中 | 向作者确认/补 MIT |
| Nintendo 法务 | 中 | 高 | 无 ROM/keys、BYO、侧载、开源、免责声明 |
| 单作者项目停更 | 中 | 高 | fork + 自维护；MIT 允许 |
| 团队/时间 | 中 | 中 | 分阶段；先 MVP 再产品 |

---

## 12. 待确认

1. **"全兼容"的首发目标**：10 款？50 款？还是"能跑就行，慢慢加"？
2. **是否接受解释器兜底**（约 0.2% 指令）？如果要求 100% 无解释器，只能走 TriAevum 单款路线。
3. **是否接受每款游戏构建一次**（约 10 分钟，自动化）？还是要求"一个 App 里随便换 ROM"（那只能走 Azahar 模拟器路线）？
4. **相机/麦克风/联机**是否在首版范围内？（建议先 stub）
5. **团队与时间窗口**：1–2 人？3 个月 MVP？6 个月？

---

## 13. 参考

- 3dsrecomp：<https://github.com/fearkov/3dsrecomp>
- Zakuro：<https://github.com/fearkov/zakuro>；兼容列表：<https://github.com/fearkov/zakuro/blob/main/COMPATIBILITY.md>
- nxnative：<https://github.com/seedds/nxnative>
- S2Arm：<https://github.com/jhaizhou-ops/S2Arm>
- TriAevum：<https://github.com/coccofresco/TriAevum>
- Azahar：<https://github.com/azahar-emu/azahar>
- Apple App Store Review Guidelines（2.5.2 / 4.7）：<https://developer.apple.com/app-store/review/guidelines/>
- Yuzu 和解：<https://www.nintendolife.com/news/2024/03/switch-emulator-yuzu-to-pay-usd2-4-million-to-nintendo-and-cease-development>
- Citra 下架：<https://tech.yahoo.com/gaming/articles/nintendo-3ds-emulator-citra-taken-205837162.html>
- Ryujinx 关停：<https://80.lv/articles/ryujinx-switch-emulator-domain-is-now-officially-owned-by-nintendo>

> 注：人月为经验估算，假设 1–2 名熟悉 Rust/C++/iOS 的工程师 + AI 辅助，实际可能 ±50%。性能数字除标注"官方/作者"外均为工程预估，需以真机 benchmark 为准。本文不构成法律意见。