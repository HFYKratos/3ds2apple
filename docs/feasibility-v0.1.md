# 3DS 游戏运行于 iOS：可行性评估

> 版本：v0.1 · 2026-11-11  
> 范围：技术路线、性能、工程量、许可与分发。仅评估，不含实现。

## 0. 结论摘要

**一句话：把 3DS 游戏跑在 iOS 上，技术上已经成立；难的是"以什么形态跑、跑得多好、是否合规"。**

| 目标 | 可行度 | 建议 |
|---|---|---|
| 让大量 3DS 游戏在 iPhone/iPad 上运行（iOS 原生 App + HLE 模拟内核） | ★★★★★ | **首选**。复用 Azahar/Cytrus，MVP 约 3–4 人月，产品级 6–11 人月 |
| 把某一款 3DS 游戏 AOT 重编译成 ARM64、不含 CPU 模拟器（S2Arm 式"原生移植"） | ★★☆☆☆ | 只做 1–2 款旗舰 PoC；iOS 运行时 6–14 人月 + 每款 3–6 人月 |
| 从零写 3DS 模拟器 / 通用静态重编译器 | ★☆☆☆☆ | 不建议；2–4 人年起，且无成功先例 |

**三个硬约束：**

1. **现代 iOS 不执行 32 位 ARM 代码**。3DS 的 ARM11（ARMv6K）代码必须被翻译——解释执行或构建时重编译。"直接原生执行 3DS 二进制"不存在。
2. **App Store 应用没有 JIT 权限**。商店版只能用解释器（Azahar 的 FastInterp）或 AOT；dynarmic JIT 只可能出现在侧载/越狱环境。
3. **复用 Azahar / Cytrus / TriAevum 就是 GPLv3**。想保持 Apache-2.0 或闭源，就得重写核心，不现实。

**推荐路径：** 先用 2–4 周做真机性能验证（路线 A），用数据决定是否投入；若坚持"无模拟器"的 native 卖点，把路线 B 限制在 1–2 款旗舰作品，不做"全库原生"的承诺。

---

## 1. "原生"到底指什么

这个词在本项目里会决定工程量差 5–10 倍，必须先拆开：

| 定义 | 典型实现 | 是否有 CPU 模拟 | 覆盖游戏 | 工程量 | 性能上限 |
|---|---|---|---|---|---|
| **A. 原生 App + HLE 模拟** | Folium、Manic EMU、Azahar libretro | 有（解释器） | 上千款 | 中 | 中高，受解释器限制 |
| **B. AOT 静态重编译** | TriAevum、MM3D-PC | 无（ARM 代码改写为 ARM64） | 单款 | 高 | 接近原生 |
| **C. 反编译重写** | zeldaret/oot3d | 无（C/C++ 源码级） | 单款 | 极高 | 原生 |

- 要"游戏库"→ 只能选 A。
- 要"没有 CPU 模拟器"的品牌叙事 → 选 B，但接受单款、逐款移植。
- 选 C 是 preservation/研究，不是产品路线。

后文按 A / B / C 分别评估。

---

## 2. 平台硬约束

### 2.1 3DS 硬件：CPU 很弱，GPU/系统很专有

| 部件 | 规格 | 对移植的含义 |
|---|---|---|
| CPU | ARM11 MPCore ×2 @ 268 MHz（New 3DS：×4 @ 804 MHz；一个核心主要留给系统），ARM9 @ 134 MHz | 主频低，解释器有希望；但双核/ARM9 协同、缓存/时序敏感 |
| 内存 | 128 MB FCRAM + 6 MB VRAM（New 3DS：256 MB） | iOS 内存不是瓶颈 |
| GPU | DMP PICA200；固定管线 + 可编程 shader；上屏 400×240（3D 模式 800×240），下屏 320×240 | 专有 GPU，必须 HLE；命令流/shader 翻译是核心工作量 |
| 输入 | 圆盘摇杆、十字键、ABXY、L/R、触摸屏、陀螺仪、麦克风；New 3DS 增加 C 摇杆、ZL/ZR、NFC | 双屏 + 触摸是 UX 主难点 |
| 媒体 | 卡带最大 4 GB；`.3ds` / `.cci` / `.cia` | 文件导入、解密、存档管理 |
| 在线 | Nintendo Network 已于 2024-04 停止；eShop 2023-03 关闭 | 联机不是 MVP；Pretendo 等社区替代另算 |

### 2.2 iOS 的五个约束

1. **32 位代码不可用**：iOS 11 起不再支持 32 位 App；现行 iOS 上无法直接执行 ARMv6/ARMv7 用户态代码。3DS 代码必须翻译。
2. **没有 JIT**：App Store 应用没有 `allow-jit` 权限。JIT 只能靠侧载 + 调试器（如 [StikDebug](https://github.com/StikDebug/StikDebug)，iOS 17.4+）或 TrollStore 等路径。商店版只能 FastInterp/AOT。
3. **图形只有 Metal**：OpenGL ES 已弃用；Azahar 没有 Metal 后端，实际方案是 **Vulkan → MoltenVK**（Cytrus 已这么做），有 10–30% 的 GPU 开销；长期可写 Metal 后端。
4. **沙盒/热/内存**：ROM/keys 导入受沙盒限制；3DS 内存需求小；持续 30/60 fps 会热降频，iPhone 比 iPad 明显。
5. **分发**：App Store（4.7 允许模拟器，但 2.5.2 禁止下载/执行代码；Nintendo 风险）vs 侧载（AltStore/SideStore/TestFlight；S2Arm 模式）。

### 2.3 推论

- iOS 上的"原生"= **原生 ARM64 App + 某种代码翻译**。差别只在"运行时解释"还是"构建时重编译"。
- 不做 CPU 翻译的方案不存在；所谓"直接跑 3DS 游戏"是营销话术，不是工程现实。

> 这一点对 S2Arm 尤其关键：[S2Arm 的 README](https://github.com/jhaizhou-ops/S2Arm) 明确写"Apple silicon cannot execute 32-bit ARM code, so 32-bit games are outside what S2Arm supports." 3DS 的 ARM11 正是 32 位——现有 S2Arm 管线不能直接套用到 3DS，必须新增 ARM32→ARM64 的翻译层（解释器或 AOT）。这也是本项目与 S2Arm 最大的技术分水岭。

---

## 3. 现有项目盘点

| 项目 | 定位 | 许可 | 平台/状态 | 对本项目的价值 |
|---|---|---|---|---|
| [Azahar](https://github.com/azahar-emu/azahar) | Citra 后继，HLE 3DS 模拟器 | GPLv3+（2127 起；2126.2 为 GPLv2+） | Win/Linux/macOS/Android；官方 iOS/tvOS ARM64 libretro 核心（iOS 14+，约 6.6 MB） | **核心**；FastInterp；Vulkan |
| [Cytrus](https://github.com/folium-app/Cytrus) | Azahar 的 iOS 移植 | GPLv3 | iOS；CoreAudio、MoltenVK、Swift bridge、FastInterp | **最直接的参考/底座** |
| [Folium](https://github.com/folium-app/Folium) | App Store 多机种模拟器（含 3DS） | GPLv3 | iOS 16+；$2.99；v2.2；2.39/847 评分 | 商业先例；UX/发行参考 |
| [Manic EMU](https://github.com/Manic-EMU/ManicEMU) | App Store 多机种（30+，含 3DS） | AGPL-3.0 | iOS 15+；免费+IAP；4.71/1.7 万评分 | 竞品；Azahar 核心；JIT 侧载 |
| [Panda3DS](https://github.com/wheremyfoodat/Panda3DS) | HLE 3DS 模拟器 | GPLv3 | Win/Linux/macOS/Android；无 iOS | 备选核心；兼容性较弱 |
| [TriAevum](https://github.com/coccofresco/TriAevum) | OoT3D AOT 重编译运行时 | GPLv3 | Win/Linux x64；Vulkan/NRI；v0.8 beta | **路线 B 的唯一成熟参考** |
| [MM3D-PC](https://github.com/Volpe34/MM3D-PC) | MM3D 的 TriAevum 移植 | GPLv3 | Win/Linux x64 | 证明运行时可按游戏复用 |
| [zeldaret/oot3d](https://github.com/zeldaret/oot3d) | OoT3D 反编译 | CC0 | WIP；需 ARMCC；不可玩 | 路线 C 的长期参考 |

### 3.1 五个关键事实

1. **Azahar 已经官方产出 iOS/tvOS 核心。** 2127.0-rc2 的发布资产里有 `azahar-libretro-ios-arm64` 和 `tvos-arm64`，CMake 最低 iOS 14.0。官方 FAQ 仍写"iOS 不在可预见计划内"，但同时发布 iOS/tvOS libretro 核心——可以理解为**不做独立 App、只提供核心**，这正好给第三方 App 留了空间。
2. **FastInterp 改变了商店版的可行性。** 2127.0-alpha1（2026-10-10）用 FastInterp 取代 DynCom，官方称在 iPhone XS 上"部分游戏速度超过 200%"，且明确面向"无 JIT 的 iOS/tvOS"。2127.0-rc2 已发布。这是商店版不越狱也能玩的关键。
3. **Cytrus + Folium 证明完整链路可跑。** Cytrus 217k 行，含 MoltenVK 加载、Metal surface、CoreAudio sink/input、相机、Swift bridge；Folium 是 96 个 Swift 文件的完整 App，已在 App Store 售卖。
4. **Manic EMU 证明 3DS 在 App Store 不是禁区。** 免费 + IAP，4.71 分，3DS 走 Azahar 核心；其 JIT 相关发布说明面向 TrollStore/侧载构建，App Store 版仍受无 JIT 限制。
5. **TriAevum 证明单款 AOT 可行，但不等于通用。** 它把 OoT3D 的 ARM 代码在 PC 上 AOT 翻译，用 Vulkan/NRI 渲染 PICA200 命令流，HLE 服务参考 Azahar。TriAevum 本体覆盖 OoT3D，MM3D 由 MM3D-PC 复用其运行时；两者都只支持 Windows/Linux x64。

### 3.2 复用地图（走路线 A 时）

| 层 | 可直接复用 | 说明 |
|---|---|---|
| 模拟核心 | Azahar `src/core`、`src/video_core` | FastInterp、HLE 服务、PICA200；GPLv3 |
| iOS 平台层 | Cytrus `System/` | MoltenVK、CoreAudio、相机、Swift bridge；GPLv3 |
| App 壳/UX | Folium `Folium/`（参考） | 游戏库、导入、控制器皮肤、布局；GPLv3 |
| 竞品参考 | Manic EMU | 多机种架构、JIT 开关、iPad 窗口；AGPL，不要直接抄 |
| 单款 AOT | TriAevum | 代码生成、Vulkan/NRI、单屏 UI；GPLv3 |

**建议**：以 Cytrus 为底座（它已经把 Azahar 的 iOS 平台层做完），Folium 只作 UX 参考，不直接 fork 其完整产品——避免继承它的产品债务和 2.39 分的口碑包袱。

---

## 4. 路线 A：Azahar/Cytrus iOS 化（推荐）

### 4.1 技术链路

```
用户自有 ROM + keys
   → Azahar core（FastInterp 解释 ARM11；HLE 系统服务；PICA200 命令流）
   → Vulkan（MoltenVK）
   → CAMetalLayer
   → CoreAudio / AVAudioEngine
   → GameController + 触摸 overlay
   → SwiftUI/UIKit 壳、游戏库、存档、设置
```

### 4.2 为什么说"可行"而不是"可能"

- Azahar 官方 iOS 核心已用 CMake 交叉编译（`-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DENABLE_OPENGL=OFF`），证明核心代码在 iOS 上可构建。
- Cytrus 已解决 iOS 平台层：MoltenVK 动态加载、`VK_USE_PLATFORM_METAL_EXT` surface、CoreAudio、相机、Swift 调用。GitHub 上有完整源码。
- Folium 与 Manic EMU 证明：审核、签名、分发、用户导入 ROM 的完整产品链路能走通。
- 因此，**这不是研究项目，而是集成 + 产品化项目**；真正的难点在性能调优和 UX，不在"能不能跑"。

### 4.3 性能预期（需 Phase 0 实测替换）

| 场景 | 粗略预期（iPhone A15/A16 起） | 说明 |
|---|---|---|
| 轻量/2D/早期 3DS 游戏 | 100–200%+（满速） | FastInterp；A12 上官方称部分游戏 >200% |
| 中型 3D（马车 7、时之笛 3D） | 70–120% | A15/A16 可能满速；A12 约 50–80% |
| 重载（MH4U、宝可梦 日月、FE if） | 40–90% | 需降分辨率/跳帧；侧载 JIT 可再提 2–4× |
| MoltenVK 开销 | GPU −10~30% | 3DS GPU 轻，通常 CPU 先瓶颈 |
| 热降频 | 10–30 分钟后 −20~40% | 30 fps cap、iPad、散热背夹可缓解 |

> 这些是工程估算，不是 benchmark。必须以第 8 节的 Phase 0 数据为准。

### 4.4 工作量（1–2 名工程师 + AI 辅助）

| 阶段 | 内容 | 人月 |
|---|---|---|
| M0 验证 | 编译 Azahar iOS 核心；RetroArch/最小 harness；6–10 款游戏跑分 | 0.5–1 |
| M1 MVP | SwiftUI 壳、ROM/keys 导入、MoltenVK、音频、触摸/手柄、双屏布局、基础存档 | 2–3 |
| M2 Beta | 兼容性、性能、shader cache、横屏、金手指、快进、崩溃上报 | 3–5 |
| M3 商店/合规 | 材料、GPL 合规、隐私、年龄分级、法务 | 1–2 |
| **合计** | 产品级 | **6–11 人月** |

若不用 Cytrus、从 Azahar 自建 iOS 层，加 3–6 人月。

### 4.5 主要风险

- **重载游戏达不到满速**，且 JIT 只能侧载；这会限制"3DS 全库"的宣传。
- **MoltenVK/驱动兼容**、shader 编译卡顿、音频延迟。
- **GPLv3 + App Store + Nintendo** 三重合规风险。
- **竞品已占位**（Folium/Manic），必须差异化：性能、横屏、存档、金手指、中文、手柄、iPad。

---

## 5. 路线 B：逐游戏 AOT 原生移植

### 5.1 TriAevum 怎么做的

1. 用户自有 ROM → 提取代码/资源。
2. AOT 把 ARM 代码翻译成原生代码（不是运行时 JIT）。
3. 用 Vulkan/NRI 渲染 PICA200 命令流；HLE 系统服务参考 Azahar。
4. 游戏逻辑以 30 Hz 原生跑；渲染可 4K/宽屏/60 插帧；单屏 UI 重排。

结果：OoT3D v0.8 beta 可玩；MM3D-PC 复用运行时。**这是"无 CPU 模拟器"的唯一成熟证明。**

### 5.2 移植到 iOS 的缺口

| 缺口 | 说明 | 估算 |
|---|---|---|
| 代码生成 x64 → ARM64 | 若用 LLVM，后端可复用；若是自研 x64 emitter，需重写 | 1–3 人月 |
| 运行时 OS 层 | Win32/POSIX → iOS（线程、文件、内存、计时） | 2–4 人月 |
| 图形 | NRI/Vulkan → MoltenVK；或写 Metal | 1–3 人月 |
| 音频/输入/窗口 | CoreAudio、GameController、UIKit | 1–2 人月 |
| 构建/签名 | Mac 交叉编译、IPA、资源包、增量更新 | 1–2 人月 |
| 单款适配 | 代码发现、HLE 补齐、渲染 bug、UI | 3–6 人月/款 |

合计：运行时 **6–14 人月**；加单款适配后，OoT3D 约 **9–20 人月（中位 ~14）**；MM3D 复用运行时后 **3–6 人月/款**。

### 5.3 覆盖范围

- 目前只有 OoT3D、MM3D 有可复用的 AOT 运行时；其他游戏没有现成管线。
- 每款都要处理：ARM/Thumb 混合、overlay 动态加载、间接跳转、SDK HLE、PICA200 shader、触摸/双屏 UI。
- 这不是"构建器"，是"移植工作室"。

### 5.4 与 S2Arm 的关键差异（重要）

| 维度 | Switch（S2Arm） | 3DS（本项目） |
|---|---|---|
| guest ISA | AArch64 | ARMv6K（32 位） |
| 与 iOS 主机 ISA | 相同 | 不同，必须翻译 |
| 代码改写 | 重链接/ABI/HLE 为主 | 全量 ARM→ARM64 翻译 |
| GPU | NVN → Metal（现代管线） | PICA200 → Metal/Vulkan（固定管线 + 自定义 shader） |
| HLE | Horizon 服务，Ryujinx 积累 | 3DS 服务 + ARM9 + DSP，Citra/Azahar 积累 |
| 单款工作量 | 低（构建器） | 高（复用运行时后 3–6 人月） |
| 规模效应 | 211 款 / 95% 首跑成功率（S2Arm 数据） | 目前 2 款有 AOT 运行时，无法承诺覆盖率 |

**结论：S2Arm 的"批量构建"模式不能直接搬到 3DS。** 3DS 的"原生"只能是单款精品路线。

### 5.5 适用场景

- 1–2 款旗舰（OoT3D/MM3D）做 60 fps/宽屏/高清，作为技术品牌。
- 不适合"我的 3DS 库都能装"的产品承诺。

---

## 6. 路线 C：自研 / 通用 AOT（不建议）

- Azahar 仅 `src/` 就有 **272,659 行**（`core` 141k、`video_core` 51k、Qt 30k）。
- Citra 从 2013 年起十余年；PICA200 逆向、HLE 服务、shader JIT、兼容性测试都是积累。
- 通用 AOT 还要解决：静态代码发现（ARM/Thumb、跳转表、overlay）、自修改代码、间接调用、SDK 识别、每款 patch。
- 估算 **2–4 人年起步**，且没有成功先例；失败概率高。
- 除非目标是"长期做 3DS 模拟器平台"，否则不建议从零开始。

---

## 7. 法律、许可、分发

### 7.1 Nintendo

- 2024-03：Yuzu 以 **240 万美元**和解并停止开发；Citra 作为"附带损害"被下架（[Nintendo Life](https://www.nintendolife.com/news/2024/03/switch-emulator-yuzu-to-pay-usd2-4-million-to-nintendo-and-cease-development)、[Yahoo Tech](https://tech.yahoo.com/gaming/articles/nintendo-3ds-emulator-citra-taken-205837162.html)）。
- 2024-10：Ryujinx 被关停，域名归 Nintendo（[80.lv](https://80.lv/articles/ryujinx-switch-emulator-domain-is-now-officially-owned-by-nintendo)）。
- 3DS eShop 2023 关闭、Nintendo Network 2024 停止，**不等于 ROM 合法化**。
- 模拟器本身在多国判例中合法（Sony v. Connectix 等），但 Nintendo 会用 DMCA/反规避/诱导侵权施压。

### 7.2 ROM 与密钥

- 只支持用户自有卡带 dump；不内置 ROM、不提供下载链接、不内置 Nintendo 密钥。
- 3DS 加密游戏的 AES 密钥是反规避敏感点；让用户导入自己的 `sysdata`/keys。
- App 内文案、年龄分级、隐私政策要明确"BYO ROM"。

### 7.3 GPLv3

- Azahar 2127+、Cytrus、TriAevum、Panda3DS 都是 GPLv3；Folium 也是 GPLv3；Manic 是 AGPL-3.0。
- 链接/分发衍生作品需提供源码、保留版权声明、允许修改；App Store 的 DRM/使用条款与 GPLv3 存在冲突（FSF 观点）。Folium/Manic 的先例不等于无风险。
- 若要闭源/Apache-2.0（S2Arm 模式），不能复用这些代码；自研核心不现实。

### 7.4 App Store 规则

- [Guideline 4.7](https://developer.apple.com/app-store/review/guidelines/) 明确允许 "retro game console and PC emulator apps"，但 4.7.1–4.7.5 有合规要求（内容过滤、年龄分级、不得扩展原生 API 等）。
- **2.5.2**：不得下载、安装或执行会改变 App 功能的代码；JIT/动态代码生成在商店版不可用。
- 先例：Folium（$2.99）、Manic EMU（免费 + IAP）均在售；说明审核可通过，但 Nintendo 投诉风险仍在。
- 建议：**v1 侧载**（AltStore/SideStore/TestFlight），v2 再评估商店；不要在 v1 就押注 App Store。

---

## 8. 推荐路线与里程碑

### 8.1 总体策略

**先验证，再产品化；先侧载，再商店；先通用，再单款精品。**

### 8.2 Phase 0：2–4 周技术验证（Go/No-Go）

- 编译 Azahar 2127 iOS 核心（或直接用 Cytrus），在 iPhone 15/16 Pro + iPad 上跑。
- 测试 6–8 款：OoT3D、MK7、SM3DL、FE Awakening、Pokémon USUM、MH4U、Animal Crossing NL、Kirby。
- 记录：平均 fps、1% low、CPU/GPU、内存、20 分钟热降频、耗电。
- 对比：FastInterp vs 侧载 JIT（若设备可用）。
- **通过标准**：≥4/8 款在 iPhone 15/16 上 ≥95% 速度；≥2 款重载 ≥80%；无崩溃。
- **不通过**：路线 A 只能做小众；转向 B 的单款 PoC，或做"侧载 JIT 优先"的产品。

### 8.3 Phase 1：MVP（6–10 周）

- SwiftUI 壳、游戏库、封面、导入（Files/DocumentPicker）、keys 导入。
- 视频：MoltenVK + CAMetalLayer；双屏布局（上下/左右/单屏）；横屏。
- 音频：AVAudioEngine/CoreAudio；延迟 <50 ms。
- 输入：GameController（MFi/Xbox/DualSense）、触摸 overlay、圆盘摇杆。
- 存档：电池存档 + 即时存档（至少 1 槽）。
- 设置：分辨率、帧率上限、音频后端、CPU 核心（FastInterp；有 JIT 则加开关）。
- 分发：AltStore/SideStore IPA；TestFlight。

### 8.4 Phase 2：Beta（3–5 个月）

- 兼容性 Top 50；per-game profiles；shader cache 预热；卡顿治理。
- 金手指、快进、倒带（可选）、截图/录像、iCloud 存档。
- 崩溃上报/日志导出；本地化（中/英/日）。
- 性能模式：省电/均衡/画质；热降频策略。

### 8.5 Phase 3：可选

- App Store 合规/法务/隐私；GPL 源码发布流程。
- 路线 B PoC：TriAevum→iOS，OoT3D 单款 60 fps/宽屏，验证"native"品牌。
- Metal 原生后端（替代 MoltenVK）——长期性能优化。

### 8.6 团队

- 1× iOS/Swift + 1× C++/图形/模拟器 + 0.5× QA；AI 辅助可压缩 30–50%。
- 需要能读 Azahar/Cytrus 代码、调 MoltenVK、处理 iOS 音频/输入/签名。

---

## 9. 风险矩阵

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| 重载游戏性能不达标 | 高 | 高 | FastInterp 调优、JIT 侧载、分辨率/帧率、per-game |
| 热降频 | 高 | 中 | 30 fps cap、画质档、iPad、散热 |
| GPLv3 / App Store 冲突 | 中 | 高 | 侧载优先、源码合规、法务 |
| Nintendo DMCA | 中 | 高 | 无 ROM/keys、BYO、品牌谨慎、响应流程 |
| 兼容性长尾 | 中 | 中 | 上游 Azahar、兼容列表、社区反馈 |
| 竞品（Folium/Manic） | 高 | 中 | 性能/UX/中文/存档/金手指差异化 |
| 团队技能缺口 | 中 | 中 | Cytrus 参考、分阶段、外部顾问 |

---

## 10. 待确认问题

1. 你说的"原生"是哪一种：**A**（原生 App + 模拟内核）、**B**（AOT 无模拟器）、**C**（反编译重写）？
2. 首发目标是"尽量多的游戏"，还是"1–2 款旗舰 60 fps/高清"？
3. 分发：侧载（AltStore/S2Arm 模式）还是 App Store？是否接受 GPLv3 开源？
4. 目标机型/最低 iOS 版本/是否支持 iPad？
5. 团队规模与时间窗口（3 个月 MVP？6 个月？）。

---

## 11. 参考

- Azahar：<https://github.com/azahar-emu/azahar>；2127.0-alpha1：<https://github.com/azahar-emu/azahar/releases/tag/2127.0-alpha1>；FAQ：<https://azahar-emu.org/pages/faq/>
- Cytrus：<https://github.com/folium-app/Cytrus>
- Folium：<https://github.com/folium-app/Folium>；App Store：<https://apps.apple.com/us/app/folium/id6498623389>
- Manic EMU：<https://github.com/Manic-EMU/ManicEMU>；App Store：<https://apps.apple.com/us/app/manic-emu-game-emulator/id6743335790>
- Panda3DS：<https://github.com/wheremyfoodat/Panda3DS>
- TriAevum：<https://github.com/coccofresco/TriAevum>；MM3D-PC：<https://github.com/Volpe34/MM3D-PC>
- zeldaret/oot3d：<https://github.com/zeldaret/oot3d>
- Apple App Store Review Guidelines（4.7 / 2.5.2）：<https://developer.apple.com/app-store/review/guidelines/>
- StikDebug（iOS JIT enabler）：<https://github.com/StikDebug/StikDebug>
- Yuzu 和解：<https://www.nintendolife.com/news/2024/03/switch-emulator-yuzu-to-pay-usd2-4-million-to-nintendo-and-cease-development>
- Citra 下架：<https://tech.yahoo.com/gaming/articles/nintendo-3ds-emulator-citra-taken-205837162.html>
- Ryujinx 关停：<https://80.lv/articles/ryujinx-switch-emulator-domain-is-now-officially-owned-by-nintendo>
- 3DS 规格：<https://en.wikipedia.org/wiki/Nintendo_3DS>

> 注：文中"人月"为经验估算，假设 1–2 名熟悉 C++/iOS 的工程师 + AI 辅助，实际可能 ±50%。性能数字除标注"官方"外均为工程预估，需以真机 benchmark 为准。本文不构成法律意见。

---

## 附录 A：Phase 0 最小验证路径

1. **环境**：Mac（Apple silicon）+ Xcode 16+；iPhone 15/16 Pro（iOS 18+）与一台 iPad；可选 Apple Developer 账号（签名/TestFlight）。
2. **核心**：取 Azahar 2127.0-rc2 源码，参考 `.github/workflows/libretro.yml` 的 `libretro-ios` job 编译 `azahar_libretro`（CMake：`CMAKE_SYSTEM_NAME=iOS`、`arm64`、`ENABLE_OPENGL=OFF`、`ENABLE_OPT=OFF`、iOS 14+）。
3. **前端**（二选一）：
   - 快速路：侧载 RetroArch（自带 Vulkan/MoltenVK），把核心放进 cores 目录，加载 ROM。
   - 产品路：用 Cytrus 的 Xcode 工程（已封装 MoltenVK/CoreAudio/Swift），套一个最小 SwiftUI 壳。
4. **输入**：自有 ROM（`.3ds`/`.cci`）+ 自己的 keys/sysdata；先用 OoT3D、MK7 做 smoke test。
5. **测量**：Xcode Instruments（CPU/GPU/内存/能耗）+ 游戏内计时；每款 20 分钟；记录 1% low、热降频、崩溃。
6. **对照**：同设备对比 FastInterp 与 dynarmic JIT（若能用 StikDebug/TrollStore）。
7. **产出**：8 款游戏的"fps/稳定性/温度"矩阵 + Go/No-Go 结论。