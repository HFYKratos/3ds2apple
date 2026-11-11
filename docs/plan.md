# 3ds2apple 执行计划 v0.5

> 首发 10 款 · 本地无 Mac（Windows / Linux）· 侧载 · 开源 · iPhone 14 Pro Max（A16 / 6 GB / iOS 26.7.2）

## 0. 结论

**没有本地 Mac 不会卡死项目，但必须承认一件事：iOS 的 C 编译/链接需要 macOS 工具链（Xcode SDK）。**  
最现实的分工是：

1. **Linux / Windows 本地**：Zakuro 桌面版、3dsrecomp、ROM/资源处理、日常开发与单测。
2. **按需租的云 Mac（1–2 周/批）**：每款游戏的 AOT C 编译、Xcode 打包、unsigned IPA。
3. **Windows**：AltStore / SideStore / Sideloadly 签名安装；`idevicesyslog` / 崩溃报告调试。

**不要把 ROM 传到 GitHub Actions。** 3DS ROM 通常 1–4 GB，既超过仓库/artifact 的合理范围，也涉及版权与 GitHub ToS。GitHub 的 macOS runner 只用来构建**不含游戏数据的通用壳和 Zakuro 核心**；每款游戏的构建放在云 Mac 上，ROM 只留在那台机器，构建完删除。

首发 10 款全部来自 Zakuro 兼容表（34 款 Playable 里挑），先做 1 款端到端，再扩到 10 款。接受 **0.2% 解释器兜底**、**每款构建一次**、**首版不做相机/麦克风/联机**。

**预算：** 云 Mac **$25–50/月**或 **$1–2/小时**（10 款集中 1–2 周）；Apple Developer **$99/年**；GitHub 公开仓库的通用壳 CI 免费。

---

## 1. 约束

| 约束 | 决定 |
|---|---|
| 首发 10 款 | 从 Zakuro 兼容表选 10 款，见第 7 节 |
| 0.2% 解释器兜底 | 接受；不追求 100% 纯 AOT |
| 每款构建一次 | 接受；每个游戏一个 IPA（约 10 分钟构建 + 打包） |
| 首版"能正常运行"优先 | 不做相机/麦克风/联机/金手指/高清材质 |
| 无本地 Mac | 通用壳走 GitHub macOS CI；每款构建走按需云 Mac；签名走 Windows |
| 侧载 | AltStore / SideStore / Sideloadly；不上 App Store |
| 开源 | Zakuro MIT；3dsrecomp MIT（Cargo.toml，仓库缺 LICENSE 文件，需确认） |

---

## 2. 目标架构：每个游戏一个 IPA

```
┌──────────────────────────────────────────────┐
│ 通用 iOS 壳（SwiftUI + Metal + CoreAudio）     │
│  ├─ 启动页 / 单游戏库                          │
│  ├─ ROM/keys 导入（可选）                      │
│  ├─ 双屏布局、触摸/手柄                        │
│  └─ 链接：libzakuro.a + libgame.a              │
└──────────────────────────────────────────────┘
                    ▲
                    │ 每个游戏链接一次
┌──────────────────────────────────────────────┐
│ libgame.a：3dsrecomp 生成的 C → arm64-apple-ios │
│ libzakuro.a：Zakuro 核心（Rust staticlib）      │
│ 资源：该游戏的 ROM 解包内容（用户自有）          │
└──────────────────────────────────────────────┘
```

**为什么不做"S2Arm 式"的壳 + 游戏 dylib 注入？**

- S2Arm 的 Windows 路线是"预编译壳 + 纯 Python 写 Mach-O dylib + 自定义 `MAP_FIXED` 加载"，因为 Switch 游戏代码已经是 AArch64，不需要 C 编译器。
- 3DS 的 AOT 代码是 **C**，必须用 clang 编译成 ARM64；没有官方、稳定的 Windows/Linux iOS 工具链。**把 C 编译放到 macOS 最稳。**
- 每个游戏一个 IPA 的代价是构建次数多、App 数量多；好处是没有自定义 loader、没有动态代码加载、签名路径简单。

**10 款 = 10 个 IPA。** 每个 IPA 只含一个游戏的 AOT 代码和资源；用户装哪个玩哪个。

---

## 3. 没有本地 Mac：构建、签名、调试

### 3.1 两条构建线

#### A. 通用壳 / 核心：GitHub Actions（macOS，无 ROM）

- 公开仓库的标准 macOS runner 免费；私有仓库 macOS 分钟按 10× 计费。
- 只构建不含游戏数据的部分：Zakuro 核心 `libzakuro.a`、SwiftUI 壳、Metal/CoreAudio/输入层、单元测试。
- 产物：通用壳的 Xcode 工程 / 未签名的空壳 App / 测试报告。
- 这条线可以每天跑，不涉及版权数据。

#### B. 每款游戏：按需云 Mac（ROM 只留在云 Mac）

- 3DS ROM 1–4 GB，不适合上传到 GitHub；而且把 ROM 交给 GitHub 托管/处理有版权和 ToS 风险。
- 租一台云 Mac（MacinCloud / Scaleway Apple Silicon / AWS EC2 Mac / MacStadium），按小时或按月；把 ROM 通过 SFTP/远程桌面放上去，构建完删除。
- 在云 Mac 上跑同一套脚本：
  1. `3dsrecomp build game.3ds out/` 生成 C；
  2. `clang -target arm64-apple-ios` 编译 C → `libgame.a`；
  3. 链接通用壳 + `libzakuro.a` + `libgame.a`；
  4. `xcodebuild CODE_SIGNING_ALLOWED=NO`；
  5. 打包 `Payload/App.app` → unsigned IPA；
  6. 下载 IPA 到 Windows，删除云 Mac 上的 ROM/中间产物。
- 10 款可以在一台云 Mac 上批量跑；按 1–2 周租，比长期买 Mac 便宜。
- 如果不想手动 SSH，可以在云 Mac 上装 **self-hosted GitHub Actions runner**：公开仓库里只有脚本，ROM 留在 runner 本地，workflow 触发构建，artifact 回传 IPA。

**云 Mac 选择（按需）：**

| 方案 | 大致费用 | 适合 |
|---|---|---|
| MacinCloud / MacStadium 按月 | $25–50/月起 | 1–2 个月集中开发 |
| Scaleway Apple Silicon 按小时 | €0.10–0.30/小时 | 10 款集中 1–2 周 |
| AWS EC2 Mac | ~$0.65/小时，24 小时起 | 短期批量构建 |
| 借/买一台二手 M1 Mac mini | $300–400 一次性 | 长期做、不想反复租 |

> 如果 10 款都要长期维护/更新，买一台二手 M1 Mac mini 往往比 cloud Mac 更省；但首版验证阶段租 1–2 周足够。

> **纯 Windows/Linux 可行吗？** 技术上可以用 osxcross + iPhoneOS SDK + `ld64.lld` + `ldid`/`rcodesign` 交叉编译/签名，但 SDK 授权、Xcode 工程、描述文件/签名、调试都要自己维护；对 10 款游戏的首版，租云 Mac 的时间成本更低。除非你明确要"零 Mac 依赖"，否则不建议 v1 走这条路。

### 3.2 签名 / 安装：Windows

- **AltStore**（AltServer for Windows）、**SideStore**（pairing file + WireGuard）或 **Sideloadly**。
- 云 Mac 产出的是 **unsigned IPA**；签名时用你的 Apple ID。
- **免费 Apple ID**：证书 7 天过期，每台设备最多 3 个 App；10 个 IPA 要反复换装。
- **付费开发者账号（$99/年）**：证书 1 年，100 台设备，10 个 IPA 可同时装；首发 10 款建议直接上付费账号。
- S2Arm 的 Windows 启动器已经验证过 `Impactor` / `apple-codesign` 这条路；如果不想用 AltStore，可以复用它的签名/安装脚本。
- 第一次打开要在 iPhone「设置 → 通用 → VPN 与设备管理」里信任开发者证书。

### 3.3 调试：Windows / Linux

没有 Xcode 调试器，但足够做首版：

| 需求 | 工具 |
|---|---|
| 设备系统日志 | `idevicesyslog`（libimobiledevice，Windows/Linux 都有） |
| 崩溃日志 | `idevicecrashreport -e` 导出 |
| App 内日志 | `os_log` / `NSLog`，经 `idevicesyslog` 看 |
| 核心逻辑 | 直接在 Linux 跑 Zakuro 桌面版 + `RUST_LOG` |
| 性能 | 游戏内帧率 + `ideviceinfo` 电量/温度；Instruments 需要 Mac |
| UI/LLDB | 云 Mac 上远程桌面/Xcode，按小时计费 |

**建议：** Phase 0–1 用云 Mac 的 SSH + 日志；进入 UI 打磨/性能深调时，用 1–2 周云 Mac 的远程桌面。

### 3.4 开发循环

```
Windows/Linux: 改代码 → Linux 跑 Zakuro 桌面版单测 → git push
        │
        ├─ 通用壳/核心 → GitHub Actions macOS（无 ROM）→ 空壳/测试
        │
        └─ 每款游戏 → 云 Mac（ROM 临时上传）→ unsigned IPA → 下载
                                      │
                                      ▼
Windows: AltStore/SideStore 签名安装 → iPhone
        │
        ▼
idevicesyslog / crash report → 回到 Windows/Linux 修
```

---

## 4. Phase 0：4–6 周（Go/No-Go）

### 4.1 本地（Linux）验证核心

1. 在 Linux 上构建 Zakuro（Rust 1.95+；需要 ALSA/udev 开发包；Vulkan 可选）。
2. 用 3dsrecomp 对 5 款游戏跑 `analyze` + `build`：**3D Land、MK7、OoT3D、Pokémon USUM、MH4U**。
3. 记录：能否启动、满速与否、重编译覆盖率、shader 解释开销、CPU 占用。
4. 目标：5 款中 ≥3 款能进游戏；≥1 款满速。

### 4.2 云 Mac 验证 iOS 链路

1. 租一台云 Mac（按小时即可），装 Xcode + Rust + XcodeGen。
2. 写最小 SwiftUI App：一个按钮 + 一个标签；链接 `libzakuro.a`。
3. 构建 unsigned IPA；下载到 Windows；用 AltStore/SideStore 装到 iPhone 14 Pro Max。
4. 再把它换成"启动 Zakuro + `read_screen` 显示一帧"的最小版本。
5. 目标：真机能显示 3DS 画面；`idevicesyslog` 能看到日志。

### 4.3 通过标准

- [ ] Linux 上 5 款中 ≥3 款能启动。
- [ ] 云 Mac 能稳定产出 unsigned IPA（<30 分钟/款）。
- [ ] Windows 能签名安装，App 能启动。
- [ ] 真机能显示至少 1 款游戏的画面 + 音频。
- [ ] 连续运行 20 分钟不崩溃。

**不通过：** 先解决 Xcode/iOS SDK、Rust iOS 链接、签名这三件事，再谈 10 款。

---

## 5. Phase 1：MVP（3–5 个月，10 款）

### 5.1 壳的功能（首版）

- 启动页 / 单游戏库（每个 IPA 一个游戏，先不做多游戏库）。
- ROM/keys 导入：如果构建时已把资源打进 IPA，可省；但存档目录、更新/DLC 仍要能导入。
- 视频：`read_screen` → Metal 纹理；上下屏布局；横屏；1×/2× 分辨率。
- 音频：`take_audio` → AVAudioEngine；延迟 <50 ms。
- 输入：GameController（MFi/Xbox/DualSense）+ 触摸 overlay + 圆盘摇杆。
- 存档：电池存档；即时存档（可选）。
- 设置：帧率上限、分辨率、音频开关、按键映射。
- 诊断：日志导出、崩溃报告。

### 5.2 构建

- 10 个游戏在云 Mac 上批量构建；每个产出 `3ds2apple-<game>.ipa`。
- 版本固定：每个 IPA 绑定游戏版本（v0/v1.1 等）；更新后重新构建。
- 资源：构建时从用户 ROM 解包；IPA 只给用户自己用，不公开分发。
- ROM 生命周期：上传 → 构建 → 删除；云 Mac 磁盘加密/单独用户；不在 GitHub 留任何 ROM/生成 C。

### 5.3 验收（"能正常运行"）

- 启动到游戏画面，20 分钟不崩溃。
- iPhone 14 Pro Max 上 ≥90% 速度（1× 分辨率）；重载游戏允许 80%。
- 音频正常，无明显爆音/延迟。
- 触摸/手柄可用；存档能保存/读取。
- 20 分钟后不明显热降频（或可接受）。

---

## 6. Phase 2：Beta（4–6 个月）

- 打开 `hardware_renderer`，走 MoltenVK；对比软件渲染。
- Shader JIT 关闭后的优化：批量解释器调优、AOT shader（可选）。
- 10 款逐个修兼容/性能；per-game 设置；金手指；快进；即时存档。
- UI 打磨：游戏库、封面、中文、手柄皮肤、iCloud 存档。
- 可选：把 10 款合成一个多游戏 App（避开免费账号 3 个 App 限制，但体积大）。

---

## 7. 首发 10 款清单

全部来自 Zakuro 当前 `Playable` 列表：

| # | 游戏 | 类型 | 首版风险 |
|---|---|---|---|
| 1 | Super Mario 3D Land | 轻量 3D，首个跑通 | 低 |
| 2 | Mario Kart 7 | 60 fps，顶点/纹理 | 中 |
| 3 | The Legend of Zelda: Ocarina of Time 3D | 中型 3D | 中 |
| 4 | The Legend of Zelda: A Link Between Worlds | 中型 3D | 中 |
| 5 | Pokémon Ultra Sun | 重载，HLE/存档 | 高 |
| 6 | Monster Hunter 4 Ultimate | 重载，CPU/GPU | 高 |
| 7 | Fire Emblem Fates | 中型，文本/存档 | 中 |
| 8 | Kirby: Planet Robobot | 轻中量 | 低 |
| 9 | Animal Crossing: New Leaf | 中型，存档/时间 | 中 |
| 10 | Super Smash Bros. for Nintendo 3DS | 重载，CPU/GPU | 高 |

> 备选：Majora's Mask 3D、Metal Gear Solid 3D、Persona Q、Yo-kai Watch。若某款在 iOS 上卡住，用备选替换，不阻塞首发。

---

## 8. 预算与资源

| 项目 | 费用 | 说明 |
|---|---|---|
| 云 Mac（按需） | **$25–50/月** 或 **$1–2/小时** | 10 款集中 1–2 周；ROM 临时上传 |
| Apple Developer | **$99/年** | 10 个 IPA 建议付费；免费账号 7 天/3 App |
| GitHub Actions | 公开仓库免费 | 只跑通用壳/核心，不含 ROM |
| 二手 M1 Mac mini（可选） | $300–400 一次性 | 长期维护/频繁更新时更划算 |
| iPhone | 已有 14 Pro Max | iOS 26.7.2 |
| Windows/Linux | 已有 | 本地开发 + 签名 |

**时间：** Phase 0 4–6 周；Phase 1 3–5 个月；Phase 2 4–6 个月。1–2 人 + AI 辅助。

---

## 9. 风险（无 Mac 相关加粗）

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| **云 Mac 的 Xcode/iOS 26 SDK 版本不匹配** | 中 | 高 | Phase 0 先验证；选支持 Xcode 26 的镜像 |
| **ROM 上传耗时/隐私** | 高 | 中 | 只传当前批次；构建后删除；磁盘加密；不在 GitHub 留 |
| **签名/安装流程不顺** | 中 | 高 | 先用 hello-world IPA 跑通 AltStore/SideStore |
| **无 Xcode 调试器，定位慢** | 高 | 中 | 日志 + 桌面版 + 按需云 Mac 远程桌面 |
| **云 Mac 成本/可用性** | 中 | 中 | 按小时租；10 款集中 1–2 周；长期考虑二手 Mac mini |
| **GitHub Actions 无 ROM 只能做空壳** | 高 | 中 | 每款构建走云 Mac；CI 只做通用部分 |
| Shader JIT 关闭后性能不足 | 高 | 高 | 真机测顶点密集场景；批量解释器调优；AOT shader |
| 兼容性长尾 | 高 | 高 | 10 款先锁定；备选替换；上游修 |
| 3dsrecomp LICENSE 文件缺失 | 中 | 中 | 向作者确认/补 MIT |
| Nintendo 法务 | 中 | 高 | 无 ROM/keys、BYO、侧载、开源、免责声明 |
| 单作者项目停更 | 中 | 高 | fork + 自维护（MIT） |

---

## 10. 本周就能做的 5 件事

1. 建公开 GitHub 仓库，提交"通用壳/核心"的 macOS CI 骨架（先跑 hello-world，不含 ROM）。
2. 在 Linux 上构建 Zakuro，跑通 Super Mario 3D Land。
3. 用 3dsrecomp 对 3D Land 跑 `analyze/build`，确认生成的 C 和覆盖率。
4. 租 1 小时云 Mac，装 Xcode + Rust + XcodeGen，构建一个 unsigned hello-world IPA。
5. 在 Windows 用 AltStore/SideStore 装到 iPhone，抓一次 `idevicesyslog`。

---

## 11. 需要你确认

1. 10 款清单是否 OK？要不要换掉某款（比如把 Smash 换成 Majora's Mask）？
2. 云 Mac 预算：按小时租 1–2 周，还是直接买二手 M1 Mac mini？
3. Apple ID 用免费还是付费 $99/年？（10 款建议付费）
4. ROM 上传云 Mac 是否接受？（只传当前批次、构建后删除）
5. Bundle ID / App 名称 / 图标有没有偏好？

---

## 附录 B：Windows-only 出包（S2Arm 式）可行吗？

> 这一节回答"理论上是不是不用 macOS 也能实现"。结论：**每款游戏的打包/签名可以 Windows-only；但通用壳仍然至少要构建一次 macOS 版本。S2Arm 自己也是这么做的。**

### B.1 先拆成三层

| 层 | S2Arm 怎么做 | 3ds2apple 能否 Windows-only |
|---|---|---|
| 通用壳（SwiftUI/UIKit + 引擎 + Metal） | `pack/shell_build.sh` **只在 Mac 上跑**（要 `xcodebuild` / `xcrun` / `codesign`） | 不能，除非自建完整 iOS 交叉工具链 |
| 每款游戏的模块 | 纯 Python 写 Mach-O dylib（Switch 代码已是 AArch64，不需要 C 编译器） | **可以**，但 3DS 多一步 C → ARM64 |
| 签名/安装 | Windows 随包 Impactor + plumesign | 可以（`rcodesign` / Impactor / AltStore） |

关键事实：S2Arm 的 Windows 发行包里，`Shell/` 是"预编壳"，由 Mac 产出后作为输入；Windows 只做"游戏模块 + 注入 + 签名"。所以它不是"完全不用 macOS"，而是"**macOS 只出一次壳**"。

### B.2 3DS 比 S2Arm 多出来的那一步

Switch 的游戏代码是 AArch64，S2Arm 可以直接把 ARM64 代码写进 Mach-O dylib，**不需要 C 编译器**。  
3DS 的 AOT 代码是 **C**，必须编译成 ARM64 Mach-O。Windows 上的可选工具链：

| 步骤 | 工具 | 风险 |
|---|---|---|
| C → ARM64 Mach-O object | LLVM `clang -target arm64-apple-ios -c` | 需要 iOS SDK 头文件或最小 sysroot |
| 链接 dylib | LLVM `ld64.lld -dylib` 或 S2Arm 式 Python Mach-O writer | `ld64.lld` 在 Windows 上不是官方主路径 |
| 签名 | `rcodesign`（apple-codesign）、Impactor/plumesign | 描述文件/entitlements 要自己处理 |
| 注入/加载 | S2Arm 式 `Frameworks/Game.dylib` + 自定义 `MAP_FIXED` loader | **最大风险**：iOS 26.7.2 的代码签名/内存保护是否允许 |
| Shader | Metal Developer Tools for Windows → `.metallib`；或运行时 `makeLibrary(source:)` | 只解决 shader，不解决 app 编译/链接/签名 |

**Metal Developer Tools for Windows 的边界：** 它能把 `.metal` 编译成 `.metallib`，可能带 Metal Shader Converter；它**不包含** iOS SDK、UIKit/SwiftUI、Swift 编译器、`ld64`、`codesign`、描述文件。它能让 shader 在 Windows 上编译，但不能让整个 App 在 Windows 上构建。

### B.3 可行的 Windows-only 管线（壳由 Mac 出一次）

```
[一次性] 云 Mac / 借的 Mac / CI：
  SwiftUI 壳 + Zakuro 核心 + 游戏加载器 → shell.ipa（预编壳）

[每款，Windows]：
  3dsrecomp（Rust，Windows 可跑）→ C
  clang -target arm64-apple-ios -c → .o
  ld64.lld -dylib → Game.dylib（或 Python Mach-O writer）
  注入 shell.ipa 的 Frameworks/ + 更新 loader 表
  rcodesign / Impactor 签名 + 描述文件
  AltStore / SideStore 安装到 iPhone
```

### B.4 风险

1. **自定义 loader 在 iOS 26.7.2 的兼容性**：S2Arm 的 `MAP_FIXED` 方案依赖签名/内存保护行为；新 iOS 可能收紧。必须先用 hello-world dylib 实测。
2. **`ld64.lld` 在 Windows 的稳定性**：链接 dylib、处理 ARM64 重定位、ad-hoc 签名；没有 Apple 官方支持。
3. **iOS SDK 头文件/授权**：生成 C 只依赖少量标准头；但一旦需要 iOS SDK，授权和分发都是问题。
4. **Swift/ObjC 壳不能重链接**：只能"注入 dylib"，不能像静态链接那样改主程序；壳的 ABI/加载器要一次设计好。
5. **壳更新仍需 Mac**：Zakuro 升级、iOS 新 SDK、Metal 新特性，都要重新出壳。
6. **两套构建脚本**：Mac 出壳 + Windows 出包，维护成本高。

### B.5 建议

- **v1 先用云 Mac 批量**（方案 A）：壳 + 10 款一次做完，风险最低。
- 同时做 **2–3 周 Windows-only spike**：
  1. 用云 Mac 出一个最小壳（带 `Frameworks/` 注入点和 loader）；
  2. 在 Windows 编译一个 hello-world C 函数为 ARM64 dylib；
  3. 注入、签名、装到 iPhone 26.7.2；
  4. 能跑 → 再试 3dsrecomp 生成的真实 C；不能跑 → 回到方案 A。
- **不要承诺"完全不用 Mac"**：S2Arm 的壳本身也是 Mac 构建的；3ds2apple 至少要有一次 macOS 出壳。

### B.6 仓库边界

- 仓库只放脚本、模板、文档；**不提交** ROM、keys、生成的 C、IPA、dylib、截图中的游戏资源。
- 构建产物全部在 `.gitignore` 的 `out/`、`build/`、`Payload/`、`*.ipa` 下。
- 贡献指南已明确：生成的 C 是游戏衍生内容，不进仓库。