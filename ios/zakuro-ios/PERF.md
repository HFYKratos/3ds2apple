# AOT 是否生效与帧时间分解（I3-T5）

> 目标：回答两个问题——**linked 进来的 AOT 代码到底在不在执行？**、**一帧的时间
> 花在 CPU 模拟、软件 PICA200、读屏/呈现还是音频上？** 本文给出测量方法、日志
> 判读规则、CPU/GPU/呈现/音频的区分办法，以及拿到数据后的下一步建议。
>
> 代码：`src/lib.rs`（C ABI、linked 状态日志）、`src/perf.rs`（帧时间窗口、
> profiler、日志转发）。构建与版本规则见 [`README.md`](README.md)、
> [`RECOMP.md`](RECOMP.md)；QA 记录格式见 [`docs/qa/README.md`](../../docs/qa/README.md)。

## 0. 结论先行

- **不要只凭 fps 猜**：28 fps（AOT）vs 26 fps（解释器）只差 7.7%，可能是 AOT 生效
  但软件 GPU 成了瓶颈，也可能是 linked 代码被 loader 回退、fps 差异来自别的变量
  （是否开音频、场景不同）。先看 `zk_recompiled()` / `zk_recompiled_status()`
  和 `zk_create` 日志，再看 `zk_perf` 行，最后才讨论渲染器。
- **本次新增的诊断**（`ios/zakuro-ios/`，不改 App 也能从日志读到）：
  - `zk_create` 打印 linked 构建信息、`recomp-abi` 是否接受表、以及 loader 最终
    是否在跑 AOT（含回退原因）；
  - 每 60 帧（约 2 s @30 fps）打印一行 `zk_perf:`，把一帧拆成
    `frame avg`（整帧 FFI，含软件 GPU）、`gpu` / `non-gpu`、`read top/bottom`、
    `audio`、`cpu cyc/s (%)`、`interpreted %`、`AOT active|interpreting`；
  - App 可轮询 `zk_last_frame_micros()` / `zk_last_screen_read_micros()` /
    `zk_last_audio_take_micros()`，并用 `zk_profiler_start()` +
    `zk_profiler_hot_spots()` 取 guest PC 热点（诊断构建用，默认不开 JIT、
    不影响 release）。
- **音频卡顿首先按“速度 < 100%”解释**：音频按模拟时间生成、按墙钟消费，46.8% 速度
  必然 underrun；在速度接近 100% 前它不是独立 bug。`zk_perf` 的
  `cpu … cyc/s (…% of real time)` 就是速度。
- **下一步建议**：先按 §5 跑一次带诊断的 linked IPA 并回收日志；根据
  `AOT`/`interpreted %`/`gpu vs non-gpu`/`frame avg vs 墙钟帧间隔` 四组数据分流。
  在拿到这些数据前不建议直接换渲染器：换 Pocket Native GLES（ABI 7 + engine fork）
  是一次大改，先确认瓶颈确实在软件 PICA200。

## 1. 新增的 C ABI 诊断（与现有 `zk_*` 完全兼容）

现有签名一律未动，只新增以下函数（实现见 `src/lib.rs`）：

| 函数 | 返回 | 说明 |
|---|---|---|
| `uint64_t zk_last_frame_micros(void)` | 微秒；未跑帧为 `0` | 上一次 `zk_run_frame` 的墙钟耗时。App HUD 可每帧读 |
| `uint64_t zk_last_screen_read_micros(uint32_t which)` | 微秒；未读屏为 `0` | 上一次 `zk_read_screen` 的耗时（`0` 上屏，其余下屏）。属**呈现**成本，不计入 `zk_run_frame` |
| `uint64_t zk_last_audio_take_micros(void)` | 微秒；未取音频为 `0` | 上一次 `zk_take_audio` 的耗时 |
| `const char *zk_recompiled_status(void *system)` | 一行文本指针；永不 `NULL` | 该 `System` 是否在跑 linked 代码、为什么没跑、已解释执行比例。指针归本库，**同一线程**下一次调用前有效，Swift 侧立即 `String(cString:)` 复制 |
| `int32_t zk_profiler_start(void *system)` | `0` 成功，`-1` 空句柄 | 打开 guest PC 采样（每 61 个 guest step 采一次，开销很小但非零；诊断时开，正式跑不要开） |
| `const char *zk_profiler_hot_spots(void *system, uint32_t count)` | 文本指针；未开 profiler 或没样本时为空串 | 最热的 guest PC，`thread 0xPC hits` 每行一条，`count` 上限 100。指针契约同上 |

行为要点：

- `zk_recompiled()` 仍返回 **loader 是否接受了 linked 代码**（`system.recompiled
  .is_some()`），不是“构建里带了 linked 代码”（那是 `zk_linked_code()`）。要在
  “接受了但某些函数被降级”时看 `zk_perf` 的 `interpreted %` 或
  `zk_recompiled_status()` 的已解释百分比。
- 每 60 帧的 `zk_perf` 行与 3 个 `zk_last_*_micros()` 同源；`zk_create` 会清零窗口
  （重新 Load ROM 后不会混入上一个 `System` 的数）。
- `zk_create` 会安装一个 stderr logger，把 Zakuro 自己的 `log::info`/`log::warn`
  转发成 `zk[INFO]` / `zk[WARN]`，loader 的 linked 回退原因因此能在
  `idevicesyslog` 里看到；App 自己装了 logger 时不动它。

> **bridging header 待同步**：以上 6 个函数尚未写进 `ios/ZakuroBridge.h`
> （`ios/app/` 是 ios-shell 作用域）。这不影响日志路径——`zk_create` 与
> `zk_perf` 行本来就打到 stderr，`idevicesyslog` 直接能抓；只有 App 想在 HUD 里
> 直接读这些毫秒数/状态字符串时才需要 ios-shell 补声明。需要补的原型见 §7。

## 2. 测量方法（在真机上复现）

### 2.1 构建与安装

用现有 AOT 流水线重新构建 **linked** 诊断包（与平时唯一的区别：库是新版本；
`linked` feature 一定要在）：

```bash
# 在 Zakuro checkout 内，capsule 由 scripts/build-linked-ios-lib.sh 执行
ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 \
  cargo build -p zakuro-ios --release --features linked --target aarch64-apple-ios

# 可选：需要 guest PC 热点时，再加 profiling（自动从第一帧开始采样）
ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 \
  cargo build -p zakuro-ios --release --features linked,profiling \
  --target aarch64-apple-ios
```

随后照常 `scripts/build-game-ipa.sh` 出包、Sideloadly 安装。首包建议**默认不开
`profiling`**：先看 `zk_recompiled_status`/`zk_perf` 是否已经足够分流，需要热点再
出第二个包。

> 无 ROM 的 host 单测已覆盖接线（§6），但没有真机数据前不要宣称 AOT 生效。

### 2.2 抓日志（Windows / Linux 均可）

iOS App 的 stdout/stderr 进系统日志，`idevicesyslog` 能抓：

```bash
# Windows（libimobiledevice 的 exe）：
idevicesyslog.exe > pokemon-y-i3t5.log
# 另开窗口跑游戏 30–60 s，然后 Ctrl+C

# Linux：
idevicesyslog | grep -E 'zk_perf|zk_create|zk\[|AOT|recompiled' | tee pokemon-y-i3t5.log
```

只要三类关键行（grep 用）：

```bash
grep -E 'zk_create|zk_perf|zk\[(WARN|INFO)\]|AOT' pokemon-y-i3t5.log
```

若 `idevicesyslog` 抓不到 Rust 的 stderr（不同 iOS/启动方式偶尔如此），退路：
用 Xcode 的 Devices → Open Console，或让 App 打一条 `NSLog` 后再从
`idevicesyslog` 里看（App 目前已经打 `[3ds2apple] AOT linked=… recompiled=…`）。

### 2.3 同一场景、同一口径

1. 进到**固定场景**（例如标题画面或同一段赛道/城镇），保持不动 30 s；
   记录 App 状态行 fps/frames（或 I3-T6 的 HUD）。
2. 先等过启动期：`zk_perf: first frame …` 那行是 boot+首帧，**不能当稳定值**；
   从第 2–3 个 `zk_perf` 窗口开始算稳定态。
3. 复测 2–3 次，取中位数；温度/电量状态记录到 QA 表（见
   [`docs/qa/soak-checklist.md`](../../docs/qa/soak-checklist.md)）。
4. 对比实验：
   - 音频 Mute 一次，看 `frame avg`/`audio` 是否变化（排除音频回压）；
   - 开/关 3D 或换到 2D 场景（软件 PICA200 负载变化，验证 GPU 假设）；
   - 20 分钟 soak 首尾各取一段（热降频，`frame avg` 应上升而 `interpreted %` 不变）。

### 2.4 仪器本身的可信度

- `frame avg`/`max` 是 `zk_run_frame` 的**墙钟**耗时（含软件 GPU、HLE、DSP 生成）；
  不含 Swift 侧读屏后的 `CGImage`/UI 发布、也不含 CADisplayLink 的调度间隔。
- `read top/bottom` 是 `zk_read_screen` 的耗时（含 framebuffer 读取 + 拷贝到
  App 缓冲）；`audio` 是 `zk_take_audio`。
- `gpu` 是 Zakuro 自己累计的 `System::gpu.busy`（软件 GPU 走命令列表/光栅的 host
  时间），从一帧内部统计，**不会**和 `frame avg` 重复计数——`non-gpu = frame avg
  − gpu` 已经把它扣掉。
- 单次 `zk_last_*_micros` 噪声大（首帧、GC、调度），趋势要看窗口平均。

## 3. 判读：AOT 到底生效了吗？

### 3.1 先看 `zk_create` 的四行日志

正常 linked 构建+匹配 ROM 时应看到（顺序固定）：

```text
zk_create: linked build, tables for title 0004000000055E00: interface ABI 5, generation 5, 12345 entry points, 7 modules
zk_create: recomp-abi accepted the linked tables: 12345 entry points, 7 modules
zk_create: AOT active: linked code, 12345 entry points, 7 modules, 0 instruction fallbacks, 0 instructions ran so far
```

若出现下列任一行，说明 **AOT 没生效**（全部走解释器）：

| 日志 | 含义 | 处理 |
|---|---|---|
| `zk_create: linked build without a title ID …` | 构建期没给 `ZAKURO_LINKED_PROGRAM_ID` | 重新构建，见 RECOMP.md §3.3 |
| `zk_create: no linked tables to hand the loader (missing title ID) …` | 同上（防御分支） | 同上 |
| `zk_create: recomp-abi accepted …` 之后是 `AOT inactive: interpreting everything: the code linked in is for title X, but the ROM is Y` | **title ID 不匹配**：ROM 是另一个 region/版本，或构建时 ID 填错 | 对**这台设备上实际运行的 ROM** 重新 3dsrecomp + 重新构建（RECOMP.md §5） |
| `AOT inactive: … the linked tables were built for an interface version this Zakuro refuses: …` | **ABI 不匹配**：Zakuro 与 3dsrecomp/recomp-abi 不是同一版本 | 以 Zakuro `Cargo.lock` 的 recomp-abi rev 为准重新生成 C + 重编（RECOMP.md §5） |
| `AOT inactive: … the loader did not accept the linked code …` + `zk[WARN] could not use the code linked in, …` | loader 其它拒绝原因，`zk[WARN]` 行有原文 | 按 warn 文本处理（多数是 ABI/title，少数是 mod/update 改动代码） |
| `zk[WARN] a mod/the update changed the game's code … interpreting everything` | ROM 带 update/mod，linked 代码无法校验，**整体回退** | iOS 目前只跑基础 ROM；确认没有混入 update（RECOMP.md §6） |
| `AOT active`，但稍后 `zk[WARN] K functions changed since the game was recompiled … they run in the interpreter` | 部分函数降级解释器（有 origins 校验时的安全降级） | 正常安全行为；看 `interpreted %`，若 >5% 考虑按实际 ROM 版本重编译 |

### 3.2 再看 `zk_perf` 行里的 `interpreted %` 与 `AOT`

`zk_recompiled()` 返回 1 只代表 **Library 被接受**；如果所有函数都被 origins 校验
降级，实际执行仍是解释器。真正的执行比例看 `zk_perf`：

- `AOT active` + `interpreted < 1%`：AOT 正常（上游 Pokémon Y 约 0.2%）。
- `AOT active` + `interpreted` 明显 >1%：有函数降级。看同窗口的 `zk[WARN]`
  “K functions changed…”：update/mod 改过的函数按设计走解释器。
- `AOT interpreting`（或 `zk_recompiled()==0`）：全解释器，先按 §3.1 修，不要调渲染器。

> `zk_recompiled_status()` 把同样信息合成一行（含 title/ABI/回退原因/已解释比例），
> App 想显示在状态栏时用它；没同步 bridging header 前就靠日志。

## 4. 判读：一帧的时间花在哪？

### 4.1 `zk_perf` 行格式

```text
zk_perf: 60 frames in 2.14s | frame avg 34.50ms max 41.00ms | \
 read top 2.00ms/2.60ms bottom 1.80ms/2.30ms (60 reads) | audio 0.05ms (60 takes) | \
 gpu 18.00ms/frame non-gpu 16.50ms/frame | cpu 126.0M cyc/s (47.0% of real time) | \
 draws 512/f xfr 8/f fills 2/f | interpreted 0.21% | AOT active
```

| 字段 | 含义 | 怎么用 |
|---|---|---|
| `N frames in T s` | 窗口覆盖的帧数与墙钟秒数 | 平均 fps = N/T；和 App 状态行的 fps 应一致（差异大说明 App 侧丢 tick/后台） |
| `frame avg` / `max` | `zk_run_frame` 平均/最大墙钟耗时 | 主要判据：和 $1000/\mathrm{fps}$ 比 |
| `read top avg/max bottom avg/max (N reads)` | `zk_read_screen` 耗时 | 呈现成本（framebuffer 读出+拷贝） |
| `audio X ms (N takes)` | `zk_take_audio` 耗时 | 音频 pump 成本；每帧应远小于 1 ms |
| `gpu X ms/frame` | 软件 PICA200（命令列表/光栅/传输）host 时间 | 判断是否 GPU 瓶颈 |
| `non-gpu X ms/frame` | `frame avg − gpu` | 模拟 CPU + HLE 服务 + DSP 生成 + 帧边界工作 |
| `cpu X M cyc/s (Y% of real time)` | 模拟 CPU 速度 = 每秒模拟的 3DS 周期 / 268.111856 MHz | **速度 %**；音频是否必然卡顿的判据 |
| `draws/xfr/fills` | 每帧 draw call / 显存传输 / fill 数 | 软件 GPU 负载的量；对比场景变化 |
| `interpreted X%` | 解释器执行比例（含 linked 代码回退给解释器的指令） | AOT 覆盖判据 |
| `AOT active` / `AOT interpreting` | loader 是否接受 linked Library | 与 `zk_recompiled()` 一致 |
| `hot thread@0xPCxHITS`（仅 profiler 开时） | 最热 3 个 guest PC | 找解释器/热点代码 |

### 4.2 三条预算等式（把毫秒对上）

设 App 状态行 fps 为 $F$（或 HUD 的 avg fps），则墙钟每帧

```text
wall_ms      = 1000 / F
frame avg    = gpu ms/frame + non-gpu ms/frame        （恒等，定义）
emulation_ms = frame avg + read top avg + read bottom avg + audio avg
gap_ms       = wall_ms - emulation_ms
```

- `gap_ms` 小（<2–3 ms）⇒ **模拟/读屏本身**就是帧率上限，瓶颈在 Rust 侧；
- `gap_ms` 大 ⇒ 时间在 App 侧：`CGImage` 创建/拷贝、主线程发布、SwiftUI 刷新、
  CADisplayLink 背压（上一帧没跑完丢弃本 tick）、音频 ring 回压。这部分本库测不到，
  用 I3-T6 的 HUD（App 端计时）确认。

### 4.3 分流判定

| 观测 | 结论 | 下一步 |
|---|---|---|
| `AOT interpreting` 或 `zk_recompiled()==0` | linked 被回退，先别看性能 | §3.1 修 title/ABI/update，重建 |
| `AOT active`，`interpreted %` > 5% | 部分函数走解释器 | 看 `zk[WARN] K functions changed`；按实际 ROM 版本重编译；否则用 profiler 看是否解释器热点 |
| `AOT active`，`interpreted %` ≈ 0，`gpu/ frame avg` > 50% | **软件 PICA200 瓶颈**：iOS 关了 shader JIT，顶点/光栅在 CPU 上跑 | 见 §5 渲染器路线 |
| `AOT active`，`gpu` 占比低、`non-gpu` 高 | 模拟 CPU/HLE 瓶颈（AOT 覆盖率或 HLE 服务） | `profiling` 包看 `hot` PC；查 `draws/xfr/fills` 异常、HLE warn |
| `frame avg` 不高但 fps 低、`gap_ms` 大 | **呈现/主线程**瓶颈 | App HUD 拆 CGImage/UI；复用缓冲、少拷贝（I3-T6 范围） |
| `audio` avg 明显 >0.5 ms 或随帧率抖动 | 音频 pump/缓冲问题 | 查 `zk_take_audio` 调用频率与 ring 容量；通常应 <0.1 ms |
| `cpu % of real time` 明显 <100% | 音频必然 underrun（按模拟时间生成、按墙钟消费） | 先提速度；`AVAudioSourceNode` 补零的 crackle 是症状不是独立 bug（见 `ios/app/README.md` 音频段） |

### 4.4 为什么 28 fps 只有 ~47% 速度，音频一定卡

3DS 帧周期 4,481,136 cycles，CPU 时钟 268,111,856 Hz ⇒ **满速 59.83 fps**。
28 fps ⇒ $28 \times 4{,}481{,}136 / 268{,}111{,}856 = 46.8\%$。DSP 按模拟时间每秒
生成 32,728 帧音频，而 AVAudioEngine 按墙钟 32,728 Hz 消费：46.8% 速度下每秒只生产
约 15,300 帧，ring 必然周期性不足、补零 → 卡顿/爆音。**在速度接近 100% 前，音频
卡顿不是独立 bug**；如果 `cpu … % of real time` 已接近 100% 而音频仍卡，才去查
音频路径（buffer 大小、sample rate 常量、engine 配置）。

## 5. 下一步建议：软件渲染器 vs Pocket Native GLES

**先测后换。** 现有渲染路径是 Zakuro 的软件 PICA200（`hardware_renderer = false`，
build 脚本还关掉了 shader JIT/cranelift）。换渲染器属于 I3-T4 的评估范围，代价不小：

| 方案 | 内容 | 代价/风险 | 何时才值得 |
|---|---|---|---|
| A. 继续软件 PICA200 + 局部优化 | 保持 vanilla Zakuro；按 §4 数据优化帧循环/读屏/HLE 热点；必要时降低内部分辨率（`Config.resolution` 目前 FFI 未暴露，需加参数） | 小；收益不确定但风险低 | `gpu` 占比高但**不到 50%**，或瓶颈在 `non-gpu`/呈现 |
| B. Pocket Native engine（GLES 渲染器） | 整套换 fork engine + recompiler（**ABI 7**，`Linked` 6 字段、`Context` 带 fastmem）；把 EGL 渲染器适配到 iOS（`CAEAGLLayer`/`EAGLContext` 或 Metal）；补 MIT 归属与固定 commit | 大：`Config`/loader 差异、ABI 7 生成代码、iOS GLES 适配、每款重编译、许可证/归属；fork 活跃需锁版本 | `AOT active`、`interpreted%≈0`、`gpu ≥ frame avg 一半`、且 20 分钟 soak 稳定（不是崩溃/回退问题） |
| C. MoltenVK / 硬件渲染 | Zakuro `hardware_renderer` 走 Vulkan 路径；iOS 需 MoltenVK（Metal 之上的 Vulkan）+ 打包 | 工程量与不确定性最大，v1 不建议 | 只在 A/B 都不够、且产品目标要求 60 fps 时评估 |

推荐决策顺序：

1. **第一优先**：用本次诊断确认 AOT 状态与瓶颈类别（§3/§4）。若 AOT 被回退，先修
   构建——那与渲染器无关。
2. 若瓶颈是**呈现/主线程**：交 ios-shell（I3-T6 HUD + 缓冲复用），不动渲染器。
3. 若瓶颈是**软件 GPU** 且差距可接受（例如 28→35 fps 就能玩）：先做 A（含
   per-frame 读屏/音频拷贝优化），把数据记入 QA；同时让 I3-T4 开 Pocket Native
   iOS 编译 spike（只验证 fork engine 能否在 iOS 编过 + 一个三角形），**不要**在
   spike 成功前承诺切换。
4. 只有当 A 的优化到顶、数据仍显示 GPU 占帧时间 >50%、且目标 fps 必须更高时，才
   按 RECOMP.md §11 整套切到 B。切换前把 §4 的基线数据固定下来，否则换完无法
   证明提升。

另外两条与性能直接相关的事实（RECOMP.md §6/§7）：

- **update/DLC/mod**：iOS FFI 目前只跑基础 ROM；update 改过的函数会被 origins 校验
  降级解释器。要全速就得按实际运行版本重编译，或上游支持 update。
- **per-game profile**：Pocket Native 的 `titles/<id>/profile.toml`（`realtime_gpu`
  等）是 fork engine 的功能，vanilla 不识别；若走方案 B 才能利用。

## 6. 本仓库已执行的验证与未验证项

已在 Linux + Rust 1.99.1 + 真实 Zakuro checkout（`fearkov/zakuro` main，
recomp-abi = `Cargo.lock` 的 `df82e6e3`，ABI 5 / generation 5；按
`scripts/build-zakuro-ios.sh` 同样方式把本 crate 复制进 workspace、关掉
`zakuro-gpu` 默认 `jit` feature）执行：

| 检查 | 结果 |
|---|---|
| `cargo fmt -p zakuro-ios -- --check` | ✅ 干净 |
| `cargo test -p zakuro-ios --lib` | ✅ 16 passed（含 `zk_last_*` 计时、profiler 空句柄、`reset`、加载失败路径） |
| `ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 cargo test -p zakuro-ios --lib --features linked` | ✅ 19 passed（含占位表 `Linked`、ABI 版本门、`zk_recompiled_status` 区分 AOT/解释、回退原因） |
| `cargo check -p zakuro-ios --target aarch64-apple-ios`（默认 / `linked` / `profiling` / `linked,profiling`） | ✅ 全部通过，本 crate 0 warning |
| `cargo build --release --target aarch64-apple-ios`（默认 / `linked`）+ `llvm-nm -u` | ✅ 默认 0 个未定义 `_recomp_*`；`linked` 恰好 7 个由 `libgame.a` 解析（见 §8.2） |

**本任务在 Linux 上无法验证**（必须 macOS VM / 真机）：

1. `clang -target arm64-apple-ios` 编译生成 C、App 最终链接（`-lzakuro_ios -lgame`
   顺序）、`xcodebuild`/IPA——由 Lead 在 VM 执行；
2. `zk_perf`/`zk_create` 的 stderr 是否出现在 `idevicesyslog`（历史任务用同样
   `eprintln!` 路径，预期一致）；
3. 真机上的实际数值（AOT 是否 active、帧时间划分、速度 %）——**这正是本任务要
   Lead/用户回收的数据**；
4. `profiler` 热点 PC 到函数名的映射（需要 `libgame.a` 的符号/调试信息，release
   包可能已 strip，只能定位到地址）。

## 7. 需要同步到 `ios/ZakuroBridge.h` 的原型（ios-shell）

```c
uint64_t zk_last_frame_micros(void);
uint64_t zk_last_screen_read_micros(uint32_t which);
uint64_t zk_last_audio_take_micros(void);
const char *zk_recompiled_status(zk_system_t system);
int32_t zk_profiler_start(zk_system_t system);
const char *zk_profiler_hot_spots(zk_system_t system, uint32_t count);
```

Swift 侧注意：`zk_recompiled_status` / `zk_profiler_hot_spots` 返回的指针归库所有，
**同一线程**下一次调用前有效；立即 `String(cString:)` 复制。计时读数是整数微秒，
适合做 HUD 的 last/avg/max。

## 8. 复现命令（摘要）

### 8.1 构建诊断包（macOS VM，由 Lead 执行）

```bash
# 1) 更新 ios/zakuro-ios → Zakuro checkout 的 crates/zakuro-ios（构建脚本会做）
scripts/build-zakuro-ios.sh

# 2) linked 版库（含诊断；如需热点再加 profiling）
cd third_party/zakuro
ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 \
  cargo build -p zakuro-ios --release --features linked --target aarch64-apple-ios
cp target/aarch64-apple-ios/release/libzakuro_ios.a \
   "$REPO/build/ios/<title>/libzakuro_ios.a"

# 3) 照常出 AOT IPA（链接顺序 -lzakuro_ios -lgame）
scripts/build-game-ipa.sh <game>
```

### 8.2 符号自检

macOS 上用 Xcode 的 `nm`；Linux 上用 `llvm-nm`（语义相同）。

```bash
# 默认壳：不应引用任何 recomp_*（否则误把 AOT 表当解释器壳）
nm -u build/ios/libzakuro_ios.a | grep _recomp_ || echo 'OK: no recomp_*'
# linked 库：去重后恰好 7 个未定义符号，交给 libgame.a 解析
nm -u build/ios/<title>/libzakuro_ios.a | grep _recomp_ | sort -u | wc -l
# 新增诊断符号应导出
nm -g build/ios/<title>/libzakuro_ios.a | grep -E 'zk_(last_frame_micros|last_screen_read_micros|last_audio_take_micros|recompiled_status|profiler_start|profiler_hot_spots)'
```

### 8.3 host 单测（Linux/macOS 均可，不需要 ROM/设备）

```bash
cd <zakuro checkout>            # 本 crate 复制到 crates/zakuro-ios 后
cargo test -p zakuro-ios --lib
ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 cargo test -p zakuro-ios --lib --features linked
```

## 9. 给 Lead/QA 的数据回收表

跑完带诊断的 linked IPA 后，请把下列内容（脱敏后）回填到
[`docs/qa/i3-aot-pokemon-y.md`](../../docs/qa/i3-aot-pokemon-y.md)：

| 项 | 值（示例） |
|---|---|
| IPA SHA256 / 构建提交 | `…` / `agent/runtime-ffi/I3-T5@<commit>` |
| ROM title ID / region / 是否有 update/DLC | `0004000000055E00` / USA / 无 |
| `zk_create` 的 linked 行（4 行原文） | `linked build, tables for title …` / `recomp-abi accepted …` / `AOT active …` 或 `AOT inactive: … <原因>` |
| `zk_recompiled()` / `zk_recompiled_status()` | `1` / `AOT active: … interpreted 0.21% of …` |
| 场景 / 时长 | 标题画面 / 60 s（稳定窗口 ≥3 个） |
| fps（App 状态行）/ 1% low（HUD） | `28` / `…` |
| `zk_perf` 稳定窗口原文（2–3 行） | `zk_perf: 60 frames in …` |
| 其中 `frame avg` / `gpu` / `non-gpu` / `read` / `audio` / `cpu %` / `interpreted %` / `AOT` | 摘出数字 |
| 音频是否卡顿 / Mute 后是否变化 | 是（随速度<100% 可解释）/ … |
| 20 分钟 soak 首尾 `frame avg` 对比 | `…` → `…`（热降频幅度） |

拿到这组数据后，§4.3 的分流表能直接给出“修构建 / 优化呈现 / 优化软件 GPU / 换
渲染器”的结论；在此之前不要根据 fps 猜原因。

## 参考

- C ABI 与构建：[`README.md`](README.md)
- linked 静态链接、版本匹配、update/DLC：[`RECOMP.md`](RECOMP.md)
- 帧循环/音频实现：[`../app/README.md`](../app/README.md)
- QA 记录格式与 soak：[`docs/qa/README.md`](../../docs/qa/README.md)、
  [`docs/qa/i3-aot-pokemon-y.md`](../../docs/qa/i3-aot-pokemon-y.md)、
  [`docs/qa/soak-checklist.md`](../../docs/qa/soak-checklist.md)
- Zakuro `System::gpu.busy`、`enable_profiler`、`hot_spots`：
  <https://github.com/fearkov/zakuro/blob/main/crates/zakuro-core/src/lib.rs>
- Pocket Native（评估见 `docs/pocket-native.md`）：
  <https://github.com/whovian64/pocket-native>
