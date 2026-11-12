# AGENTS.md — 3ds2apple 协作与迭代指南

> **所有 Agent 先读这份文件，再读 `docs/plan.md`、`docs/milestones.md`、`docs/integration.md`。**
> 最后更新：2026-11-12 · 维护者：Lead

## 1. 项目一句话

把 3DS 游戏以 **AOT 原生方式**带到 iPhone/iPad：ROM 里的 ARM 代码在构建时经
3dsrecomp 翻译为 C，再编译成 ARM64 静态库，链接进 SwiftUI 壳；运行时由 Zakuro
提供 HLE 系统服务、GPU 和约 0.2% 的解释器兜底；**不使用 CPU JIT**。

当前目标：首发 10 款、侧载（Sideloadly/AltStore）、iPhone 14 Pro Max（iOS 26.7.2）。

## 2. 硬性规则（违反即回滚）

1. **仓库不出现任何侵权内容**：ROM、解密密钥、BIOS、系统文件、字体、游戏资源、
   生成的 C 代码、IPA、截图中的游戏画面，全部不提交。
2. **本地目录约定**：`ROM/`（ROM）、`IPA/`（测试 IPA）、`build/`、`third_party/`、
   `.worktrees/` 都是本地/忽略目录；`git status` 必须干净。
3. **不把 Apple ID、SSH 密码、设备 UDID、签名证书写进代码、日志、提交或 PR。**
   iOS 构建机的访问由 Lead 协调；需要凭据时走会话内临时方式，绝不落盘到仓库。
4. **不要开启 CPU JIT**：iOS 不允许可执行内存。允许 AOT 代码 + 解释器兜底；
   不要恢复 `zakuro-gpu` 的 `jit` 默认特性（见 `docs/integration.md`）。
5. **只用用户自己的 ROM**：不提供 ROM 下载/破解/密钥分发；兼容性报告只描述
   游戏与 bug，不写获取途径。
6. **许可证**：本项目 Apache-2.0；Zakuro、3dsrecomp、Pocket Native 为 MIT。
   复用 MIT 代码必须保留版权/许可声明；不要粘贴 GPL 代码（Azahar、TriAevum
   仅作参考，不进入本仓库代码）。
7. **一个作用域一个写者**：同一目录/文件不要两个 Agent 同时改；用 worktree + 分支。
8. **提交前自测**：Rust 至少 `cargo check`；iOS 至少 `xcodebuild` 成功；文档改动
   检查链接。不要提交"只在我机器上能跑"的东西。
9. **不改 macOS VM 的磁盘/OpenCore/网络配置**，除非 Lead 明确分配；VM 很脆，
   一次错误重启可能丢掉环境。
10. **每次任务完成必须写 handoff**：改了什么、怎么验证、证据（日志/截图路径）、
    已知问题、下一步。

## 3. 目标与非目标

### 3.1 目标（v1）

- 10 款首发游戏（见 `docs/plan.md` 第 7 节），每款一个 IPA。
- 每款：能启动到游戏画面，20 分钟不崩，音频/触摸/手柄可用，存档可用。
1. 侧载安装；不上 App Store。
2. 开源（Apache-2.0），构建脚本可复现。

### 3.2 非目标（v1 不做）

- App Store 上架、JIT、全库兼容、相机/麦克风/联机、高清材质/金手指/即时存档
  （后两项可放 I5 可选）。
- 纯 Windows/Linux 全交叉编译（见 `docs/plan.md` 附录 B/C，非首选）。

## 4. 架构与组件

```
用户自有 ROM（ROM/，不提交）
   │  3dsrecomp（构建机）
   ▼
C 代码 → clang -target arm64-apple-ios → libgame.a
   │
   ▼
SwiftUI 壳  ←  libzakuro_ios.a（Zakuro core，Rust staticlib）
   │            ├─ HLE 内核/服务
   │            ├─ PICA200 GPU（软件渲染，后续 MoltenVK）
   │            └─ 解释器兜底
   ▼
unsigned IPA → Windows Sideloadly/AltStore → iPhone
```

| 组件 | 位置 | 说明 |
|---|---|---|
| iOS C ABI / staticlib | `ios/zakuro-ios/` + `scripts/build-zakuro-ios.sh` | `zk_create`、`zk_run_frame`、`zk_read_screen`、`zk_take_audio`、`zk_set_input` |
| SwiftUI 壳 | 待建（I1） | ROM 导入、上下屏、音频、GameController、设置 |
| 3dsrecomp | 上游 `fearkov/3dsrecomp` | 构建时 ARM→C；不修改游戏数据 |
| Zakuro | 上游 `fearkov/zakuro` | HLE 运行时；本地补丁见构建脚本 |
| Pocket Native | <https://github.com/whovian64/pocket-native> | **主要参考/候选上游**：Zakuro + 3dsrecomp AOT fork，GLES 渲染器、`port` 静态链接、`titles/` 游戏 profile；MIT |
| 构建机 | CachyOS + macOS VM | Xcode 16.4 / iOS 18.5 SDK；Rust 1.99.1 |
| 签名/安装 | Windows | Sideloadly / AltStore；Apple ID 只由用户本人输入 |

### 4.1 当前状态（2026-11-12）

- **M0 完成**：macOS VM → Xcode → Hello3DS IPA → 真机运行。
- **Zakuro iOS 静态库已构建**：`libzakuro_ios.a`（aarch64-apple-ios，约 52 MB，
  Cranelift JIT 已关闭）。
- **下一步（I1）**：SwiftUI 壳链接 `libzakuro_ios.a`，无 ROM 也能启动并优雅报错；
  产出 IPA。

## 5. 迭代周期

> 每个迭代结束必须满足"验收"；未满足则不开下一个迭代。
> 工作量是经验估算（1–2 人 + AI），±50%。

### I0 — 工具链与静态库（已完成，2026-11-12）

- 交付：Hello3DS IPA；`libzakuro_ios.a`；`scripts/build-zakuro-ios.sh`；
  `docs/integration.md`；M0 记录。
- 验收：IPA 能在 iPhone 14 Pro Max 启动。

### I1 — iOS 壳骨架（1–2 周）

**目标**：App 链接 Zakuro 静态库，能启动、显示 UI；无 ROM 时优雅提示。

| 任务 | 交付 | 写者 |
|---|---|---|
| I1-T1 Xcode 工程 + bridging header | `ios/app/`、`ZakuroBridge.h`、XcodeGen `project.yml` | ios-shell |
| I1-T2 `libzakuro_ios.a` 链接 | `xcodebuild` 成功，`zk_screen_width()` 可调用 | ios-shell + Lead |
| I1-T3 无 ROM 启动页 | 选择 ROM 的入口/占位；错误提示 | ios-shell |
| I1-T4 构建脚本 | `scripts/build-ios-app.sh`（ROM-free） | build-infra |
| I1-T5 验收 | IPA 安装、启动、`zk_*` 调用日志 | Lead + qa |

**验收**：IPA 能在真机启动；静态库符号存在；不崩溃；文档更新。

### I2 — ROM 导入 + 第一款游戏启动（2–3 周）

**目标**：从 `ROM/` 或 Files 导入 `.3ds/.cci`，`zk_create` 成功，显示上下屏。

| 任务 | 交付 | 写者 |
|---|---|---|
| I2-T1 ROM 导入 | DocumentPicker + 复制到 Documents/roms | ios-shell |
| I2-T2 `zk_create` 接线 | 后台加载、错误码/日志 | runtime-ffi |
| I2-T3 帧循环 + 上下屏 | `CADisplayLink`/Timer + `CGImage`，400×240 + 320×240 | ios-shell |
| I2-T4 首款游戏 boot | 3D Land（或用户指定）纯解释器 boot | runtime-ffi + qa |
| I2-T5 20 分钟 soak | 崩溃/内存/温度记录 | qa |

**验收**：第一款游戏到标题/首个可操作画面；20 分钟不崩；输入能过标题；
截图/日志归档。

### I3 — 输入、3dsrecomp、音频与渲染（4–6 周）

> 参考实现：**Pocket Native**（MIT，Zakuro + 3dsrecomp 的 AOT 分支，见
> `docs/pocket-native.md`）。其 `recompiler/src/port.rs` 已给出静态 `Linked` 的
> 完整范式，`titles/` 有 Pokémon Y/AS/USUM 的 profile，`engine/gpu` 有 GLES
> 渲染器，应优先复用/参考，不要从零推导。

| 任务 | 交付 | 写者 |
|---|---|---|
| I3-T1 输入 | 触摸 overlay + GameController + `zk_set_input`（已完成构建） | ios-shell |
| I3-T2 3dsrecomp 静态链接 | 按 Pocket Native `port.rs` 的 `Linked::new` 把生成 C 静态链进 `libzakuro_ios.a`；`libgame.a` + Xcode 链接 | runtime-ffi + build-infra |
| I3-T3 音频 | `zk_take_audio` → AVAudioEngine | ios-shell |
| I3-T4 渲染器评估 | Pocket Native GLES 3.1 渲染器/iOS GLES spike；决定 v1 用 GLES 还是 Metal/MoltenVK | runtime-ffi + ios-shell |
| I3-T5 性能基线 | 速度 %、1% low、热降频、内存；对比 3dsrecomp 前后 | qa |
| I3-T6 可玩性 | 第一款游戏可玩 20 分钟；存档 | Lead + qa |

**验收**：第一款游戏"能正常玩"；构建可复现；性能数据入库。

### I4 — 10 款批量构建（4–6 周）

| 任务 | 交付 | 写者 |
|---|---|---|
| I4-T1 每款构建脚本 | 3dsrecomp → C → `libgame.a` → IPA | build-infra |
| I4-T2 10 款兼容矩阵 | 启动/画面/音频/输入/存档 | qa |
| I4-T3 失败分类 | HLE/GPU/时序/ROM 版本 | runtime-ffi + qa |
| I4-T4 IPA 分发 | 命名、版本、SHA256、安装说明 | build-infra |

**验收**：10 个 IPA；≥8 款到游戏画面；失败项有归因和 issue。

### I5 — 产品化（4–6 周，可选）

- UI/UX：游戏库、封面、中文、横屏、设置。
- 存档/即时存档、金手指、快进、iCloud 存档。
- MoltenVK 硬件渲染（性能允许时）；AOT shader（可选）。
- 文档、兼容列表、发布流程、安全审计。

## 6. Agent 团队与协作

### 6.1 角色

| 角色 | 负责 | 默认写作用域 |
|---|---|---|
| **Lead**（本会话） | 任务拆解、VM/构建协调、合并、最终验收 | `docs/`、`README`、`.gitignore`、合并 |
| **ios-shell** | SwiftUI/UIKit、视频/音频/输入、Xcode 工程 | `ios/app/` |
| **runtime-ffi** | Rust FFI、Zakuro 补丁、内存/线程/错误处理 | `ios/zakuro-ios/`、Zakuro 本地副本 |
| **build-infra** | 3dsrecomp、静态库/IPA 脚本、CI、可复现 | `scripts/`、`.github/` |
| **qa-compat** | ROM 矩阵、性能、崩溃/日志、验收报告 | `docs/qa/`、测试脚本 |

### 6.2 任务板

- 用共享任务板（`team_task_create` / `team_task_update`）。
- 每个任务必须写：目标、交付、验收、写作用域、依赖、预估。
- 开工前先 `claim`；完成时写 handoff 并 `complete`。
- 依赖用 `blocked_by`；不要抢未就绪任务。

### 6.3 分支 / worktree（防冲突）

```bash
git worktree add .worktrees/<agent> -b agent/<agent>/<task> main
```

- `.worktrees/` 已在 `.gitignore`；每个 Agent 一个 worktree。
- 提交信息用 conventional commits：`feat(ios): ...`、`fix(runtime): ...`、
  `docs: ...`。
- 完成后 push 分支并在任务里写 PR/分支名；Lead 合并到 `main` 并跑最终构建。
- 不在 `main` 上直接改代码（Lead 的文档/合并除外）。

### 6.4 构建与 VM

- **macOS VM 只由 Lead/指定 runner 操作**：Xcode、IPA、真机安装都在那里。
- Agent 本地（Linux）可跑 Rust `cargo check`/`cargo test`、Python、文档；
  不要在 Linux 上尝试 iOS 链接。
- 需要 iOS 构建时，在任务里写清楚：改了什么、要什么产物、如何验证，交给 Lead。
- 不要在 Agent 之间传递密码/Apple ID；签名由用户本人操作。

### 6.5 Handoff 模板

```md
## Handoff
- 任务：I2-T3
- 分支/提交：agent/ios-shell/I2-T3 @ abc1234
- 改动：...
- 验证：命令 + 结果 + 日志路径
- 已知问题：...
- 需要 Lead：...
```

## 7. 验收与质量门

每个迭代结束检查：

- [ ] 代码在 `main` 合并；`git status` 干净。
- [ ] Rust：`cargo check -p zakuro-ios --target aarch64-apple-ios` 通过（在 macOS/CI）。
- [ ] iOS：`xcodebuild` 成功；IPA 能在真机安装/启动。
- [ ] 没有 ROM/keys/IPA/生成 C/凭据进入 git（`git diff --stat` + `.gitignore`）。
- [ ] 文档/里程碑更新；验收证据归档到 `docs/qa/`（截图、日志摘要）。
- [ ] 性能：记录速度 %、内存、20 分钟热降频。
- [ ] 回归：上一迭代的验收项仍通过。

## 8. 本地命令速查

```bash
# 仓库
git status
git worktree list

# Rust / FFI（macOS VM 上）
scripts/build-zakuro-ios.sh
cargo check -p zakuro-ios --target aarch64-apple-ios

# Xcode（macOS VM 上）
xcodebuild -project ... -target ... -sdk iphoneos \
  -configuration Release SYMROOT="$PWD/build" OBJROOT="$PWD/build" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

# 打包 unsigned IPA
mkdir -p Payload && cp -R <App>.app Payload/
zip -qry <name>.ipa Payload

# 真机日志（Windows/Linux）
idevicesyslog
idevicecrashreport -e
```

## 9. 风险与升级

| 风险 | 影响 | 处理 |
|---|---|---|
| 关掉 shader JIT 后顶点性能不足 | 帧率低 | 先测 3D Land；后续 AOT shader / MoltenVK |
| macOS VM 不稳定/卡死 | 构建中断 | `quit` 后重启；不频繁改 VM 配置 |
| Zakuro 兼容性长尾 | 游戏黑屏/崩溃 | 按游戏分类修 HLE/GPU；记录 issue |
| 3dsrecomp 覆盖/版本不匹配 | 回退解释器 | 重新 recomp；版本固定 |
| 许可证/法律 | 下架/纠纷 | 只支持自有 ROM；不内置 keys；侧载 |
| 静态库体积 52 MB | IPA 大 | `strip`、`-dead_strip`、按需裁剪 |

升级路径：Agent 遇到阻塞 → 在任务里写清 `blocked_by`/证据 → 通知 Lead；
Lead 决定是否调整迭代或找用户确认。

## 10. 参考

- `docs/plan.md`：10 款、云 Mac/VM、Windows 签名、附录 B/C。
- `docs/feasibility.md`：3dsrecomp + Zakuro 可行性。
- `docs/milestones.md`：M0 记录与踩坑。
- `docs/integration.md`：静态库构建与 C ABI。
- 上游：<https://github.com/fearkov/zakuro>、<https://github.com/fearkov/3dsrecomp>。
- **Pocket Native**（MIT）：<https://github.com/whovian64/pocket-native>；评估见
  `docs/pocket-native.md`。