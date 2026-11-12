# zakuro-ios — Zakuro 的 iOS C ABI

把 [Zakuro](https://github.com/fearkov/zakuro)（3DS HLE 运行时）包装成 iOS 可链接的
Rust `staticlib`。Swift 只看到不透明指针和下面列出的 `zk_*` 函数；`System` 的所有权
始终在 Rust 侧。

- **构建方式**：本目录由 [`scripts/build-zakuro-ios.sh`](../../scripts/build-zakuro-ios.sh)
  复制为 `<zakuro>/crates/zakuro-ios`，再在 Zakuro workspace 里
  `cargo build -p zakuro-ios --release --target aarch64-apple-ios`。产物
  `build/ios/libzakuro_ios.a` 不进仓库。完整步骤以
  [`docs/integration.md`](../../docs/integration.md) 为准。
- **无 JIT**：iOS 不允许可执行内存。`zk_create` 固定
  `find_recompiled = false`、`hardware_renderer = false`，只跑 AOT/HLE 代码与解释器
  兜底；不要重新打开 `zakuro-gpu` 的 `jit` 特性。
- **调用约定**：所有 `zk_*` 调用必须串行，`System*` 不是线程安全的（见
  [线程规则](#线程规则)）。

## C ABI

头文件由 Swift bridging header 手写（`ios/app/`，I1-T1）。需要声明的 C 原型：

```c
#include <stddef.h>
#include <stdint.h>

void       *zk_create(const char *rom, const char *data_dir);
int32_t     zk_run_frame(void *system);
uint32_t    zk_screen_width(uint32_t which);
uint32_t    zk_screen_height(uint32_t which);
size_t      zk_read_screen(void *system, uint32_t which, uint8_t *out, size_t capacity);
size_t      zk_take_audio(void *system, int16_t *out, size_t capacity);
void        zk_set_input(void *system, uint32_t buttons, float circle_x, float circle_y,
                         int32_t touch, uint16_t touch_x, uint16_t touch_y);
void        zk_destroy(void *system);
const char *zk_last_error(void);
int32_t     zk_linked_code(void);
uint64_t    zk_linked_program_id(void);
int32_t     zk_recompiled(void *system);
const char *zk_recompiled_status(void *system);
uint64_t    zk_last_frame_micros(void);
uint64_t    zk_last_screen_read_micros(uint32_t which);
uint64_t    zk_last_audio_take_micros(void);
int32_t     zk_profiler_start(void *system);
const char *zk_profiler_hot_spots(void *system, uint32_t count);
```

### 函数表

| 函数 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `zk_create` | `rom`：解密后的 `.3ds` / `.cci` 绝对路径；`data_dir`：可选数据目录，可传 `NULL` 用默认值 | `void *`；失败返回 `NULL` | 加载 ROM 并初始化 `System`。失败原因用 `zk_last_error` 读，成功会清空错误 |
| `zk_last_error` | 无 | `const char *`；无待处理错误时为 `NULL` | 返回**当前线程**最近一次 `zk_create` 失败的可读文本 |
| `zk_run_frame` | `system` | `int32_t`：`0` 完成、`1` 退出、`-1` fault、`-2` 空句柄 | 跑一帧 |
| `zk_screen_width` | `which`：`0` 上屏，其余下屏 | `uint32_t`：上屏 `400`，下屏 `320` | 屏幕宽度 |
| `zk_screen_height` | `which`（两屏同为 240） | `uint32_t`：`240` | 屏幕高度 |
| `zk_read_screen` | `system`；`which`；`out`：`uint8_t*` RGBA8 缓冲；`capacity`：字节数 | `size_t`：完整字节长度（可能大于 `capacity`，此时已截断） | 读一屏像素；`system` 或 `out` 为 `NULL` 返回 `0` |
| `zk_take_audio` | `system`；`out`：交错立体声 `i16` 缓冲；`capacity`：`i16` 元素个数 | `size_t`：写入的**帧数**（每帧 2 个 `i16`） | 取音频；`system` / `out` 为 `NULL` 或 `capacity < 2` 时返回 `0` |
| `zk_set_input` | `system`；`buttons`：3DS HID 位掩码；`circle_x/y`：圆盘摇杆 `-1.0..=1.0`；`touch`：`0`/`1`；`touch_x/y`：下屏像素坐标 | 无 | 更新输入状态 |
| `zk_destroy` | `system` | 无 | 释放 `System`；每个指针只能调一次，之后不得再使用 |
| `zk_linked_code` | 无 | `int32_t`：`1` 内置了某款游戏的重编译代码，`0` 纯解释器壳 | 构建时信息，不依赖 ROM；用于 UI/日志判断当前是哪种构建 |
| `zk_linked_program_id` | 无 | `uint64_t`：内置重编译代码的 3DS title ID；无则为 `0` | 与 ROM 的实际 title ID 不符时 loader 会回退解释器（见 RECOMP.md） |
| `zk_recompiled` | `system` | `int32_t`：`1` = 该 `System` 正在跑 3dsrecomp 代码，`0` = 全解释器 | 诊断/性能定位：AOT 构建里返回 `0` 说明 loader 拒绝了内置代码，只是慢，不是崩 |
| `zk_recompiled_status` | `system` | `const char *`：一行状态文本（永不 `NULL`） | 说明该 `System` 是否在跑 linked 代码；返回 `0` 时给出原因（无 linked 代码 / title ID 不符 / ABI 不符 / loader 拒绝），并报告已解释执行的指令比例。指针归本库，同一线程下一次调用前有效 |
| `zk_last_frame_micros` | 无 | `uint64_t`：上一次 `zk_run_frame` 的微秒数；未跑帧为 `0` | 帧时间 HUD/日志用；不含 Swift 侧呈现 |
| `zk_last_screen_read_micros` | `which`：`0` 上屏，其余下屏 | `uint64_t`：上一次 `zk_read_screen` 的微秒数 | 读屏/呈现成本（framebuffer 读出+拷贝） |
| `zk_last_audio_take_micros` | 无 | `uint64_t`：上一次 `zk_take_audio` 的微秒数 | 音频 pump 成本 |
| `zk_profiler_start` | `system` | `int32_t`：`0` 成功，`-1` 空句柄 | 打开 guest PC 采样（诊断用，有少量开销；默认不开） |
| `zk_profiler_hot_spots` | `system`；`count`：条数（上限 100） | `const char *`：最热 guest PC，`thread 0xPC hits` 每行一条；未开 profiler 时为空串 | 配合 `profiler` feature 或 `zk_profiler_start` 定位热点；指针契约同 `zk_recompiled_status` |

`zk_recompiled_status` / `zk_profiler_hot_spots` 的指针归本库所有：不要 `free`，
在同一线程下一次调用前有效，Swift 侧立即复制。**新增的 6 个诊断函数需要同步到
`ios/ZakuroBridge.h`（ios-shell 维护）**；不补头文件时日志路径仍可用
（`zk_create` 与每 60 帧的 `zk_perf` 行走 stderr，`idevicesyslog` 能抓）。

`buttons` 使用 3DS HID 位布局（`PadState`）：A=`1<<0`、B=`1<<1`、Select=`1<<2`、
Start=`1<<3`、Right=`1<<4`、Left=`1<<5`、Up=`1<<6`、Down=`1<<7`、R=`1<<8`、
L=`1<<9`、X=`1<<10`、Y=`1<<11`、ZL=`1<<14`、ZR=`1<<15`。

缓冲区大小：上屏 `400 × 240 × 4 = 384000` 字节，下屏 `320 × 240 × 4 = 307200` 字节；
可先用 `zk_screen_width` / `zk_screen_height` 分配。

## 错误处理

`zk_create` 失败时返回 `NULL`，并把可读文本记录到**调用线程**的错误槽；成功后清空。

| 失败情形 | `zk_last_error()` 文本 |
|---|---|
| `rom` 为 `NULL` | `zk_create: rom path is NULL` |
| `rom` 不是合法 UTF-8 | `zk_create: rom path is not valid UTF-8` |
| `data_dir` 非 `NULL` 但不是合法 UTF-8 | `zk_create: data_dir path is not valid UTF-8` |
| loader 加载失败 | `zk_create: failed to load <path>: <loader error>` |

`zk_last_error` 契约：

- 没有待处理错误时返回 `NULL`；否则返回 NUL 结尾的 UTF-8 文本指针。
- 指针归本库所有：**不要 `free`**，也不要写它。
- 指针在**同一线程**下一次 `zk_create` 或 `zk_last_error` 调用之前有效。要跨调用保存，
  请立刻复制成 `String`（Swift 里 `String(cString:)`），不要保存裸指针。
- 错误状态是**线程局部**的：在哪个线程上 `zk_create` 失败，就要在同一个线程上读
  `zk_last_error`。用后台 `DispatchQueue` 加载时，在同一个 block 内复制错误文本，
  再切主线程展示；否则主线程读到的是 `NULL`。
- 其他 `zk_*` 函数不会修改错误状态，也不通过它报错；它们的失败看返回码/返回值。
- 错误文本同时会以 `eprintln!` 打到 stderr（真机上可用 `idevicesyslog` 抓取），
  但不要把 stderr 当成唯一诊断途径。

Swift 侧示例（在同一个串行队列 block 内读取）：

```swift
let system = zk_create(romPath, dataDir)
if system == nil {
    // 必须还在同一个线程/队列 block 内读取并复制。
    var message = "unknown error"
    if let cMessage = zk_last_error() {
        message = String(cString: cMessage)
    }
    DispatchQueue.main.async { self.showError(message) }
}
```

## 线程规则

- `System*` **不是线程安全的**：所有 `zk_*` 调用必须串行，建议整个运行时共用一个
  专用串行 `DispatchQueue`；不要并发调用，也不要重入。
- `zk_create` 可能耗时数秒（解析 ROM + HLE 初始化），必须放后台队列，不要在主线程调用。
- `zk_create` / `zk_last_error` 的错误槽是每线程独立的（见上）。
- `zk_destroy` 可以在与创建不同的线程调用，但必须保证此时没有其他线程还在使用同一个
  `System*`。销毁后不得再把该指针传给任何 `zk_*` 函数。
- `zk_read_screen` / `zk_take_audio` 不与帧循环并发：在帧循环的同一串行队列里调用。

## 链接重编译代码（`linked` build）

默认构建是**纯解释器壳**（`libzakuro_ios.a` 不引用任何游戏代码，无 ROM 也能启动）。
每款游戏的 IPA 再额外构建一个 **`linked` 变体**：把 3dsrecomp 生成的 C 编译成
`libgame.a`，与本库一起静态链接进 App，由 `zk_create` 自动交给 Zakuro 跑 AOT 代码
（无 `dlopen`、无 JIT、Swift 侧无需改调用）。

```bash
# 在 Zakuro checkout 内（先把本目录复制为 crates/zakuro-ios，见 scripts/build-zakuro-ios.sh）
ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 \
  cargo build -p zakuro-ios --release --features linked --target aarch64-apple-ios
```

- `ZAKURO_LINKED_PROGRAM_ID` 是 ROM 的 16 位十六进制 title ID，由 `build.rs` 校验并在
  编译期写进库里；`linked` 构建缺少它会在编译期报错。
- 生成的 `libgame.a` 必须在 App 的最终链接里排在 `libzakuro_ios.a` 之后，否则
  `recomp_*` 未定义、链接失败；这是有意为之（防止把解释器壳误当 AOT 包）。
- loader 会检查 title ID 和 `recomp.h` 接口版本（当前 ABI 5，接受 4–5）；不匹配时
  打印警告并**回退解释器**，不会崩。`zk_linked_code` / `zk_linked_program_id` /
  `zk_recompiled` 提供诊断；`zk_recompiled_status` 给出回退原因，`zk_create` 也会
  把 linked 构建信息、ABI 检查结果和实际 `AOT active|inactive: <原因>` 打到 stderr。
- 完整流水线（3dsrecomp `port`、iOS clang、版本匹配、update/DLC 限制、性能预期、
  build-infra 清单）：见 [`RECOMP.md`](RECOMP.md)。
- 上游选择：目前采用 **vanilla Zakuro + upstream 3dsrecomp（方案 B）**。
  [Pocket Native](https://github.com/whovian64/pocket-native)（MIT）的
  `recompiler/src/port.rs` 提供了同一套静态 `Linked` 范式（我们已按其实现）；它的
  engine fork（GLES/fastmem/per-game profile）作为 I3-T4 的升级路径评估，见
  [`RECOMP.md`](RECOMP.md) §0.5 与 [`docs/pocket-native.md`](../../docs/pocket-native.md)。

> 新增的 6 个诊断函数需要同步到 Swift bridging header（`ios/ZakuroBridge.h`，
> ios-shell 维护）；不补头文件时 `zk_create` / `zk_perf` 日志仍可用。

## 性能诊断（帧时间分解，I3-T5）

想知道“AOT 到底有没有在执行、一帧时间花在哪”时，用同一份库即可，不需要改 App：

- `zk_create` 打印 linked 状态与回退原因（见上）；Zakuro 自己的 `log::info`/`log::warn`
  被转发成 `zk[INFO]` / `zk[WARN]`，`idevicesyslog` 直接可见。
- 每 60 帧打印一行 `zk_perf:`：`frame avg/max`、`read top/bottom`、`audio`、
  `gpu`/`non-gpu`、`cpu … cyc/s (…% of real time)`、`interpreted %`、`AOT`，
  `profiling` 构建或 `zk_profiler_start` 时再加 guest PC 热点。
- App 可轮询 `zk_last_frame_micros` / `zk_last_screen_read_micros` /
  `zk_last_audio_take_micros`，并用 `zk_recompiled_status` / `zk_profiler_hot_spots`
  直接显示状态。

`profiling` 是只用于诊断的 cargo feature（默认关；每 61 个 guest step 采一次 PC）：

```bash
ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 \
  cargo build -p zakuro-ios --release --features linked,profiling --target aarch64-apple-ios
```

测量方法、`zk_perf` 字段表、CPU/软件 GPU/呈现/音频的区分、以及“软件渲染器 vs
Pocket Native GLES”的下一步建议：见 [`PERF.md`](PERF.md)。

## 验证

本目录不能单独构建：它依赖 Zakuro workspace 里的 `zakuro-core` / `zakuro-common`。

```bash
# 完整静态库（macOS + Xcode + Rust aarch64-apple-ios target）
scripts/build-zakuro-ios.sh

# 或在 Zakuro checkout 内做编译检查
cargo check -p zakuro-ios --target aarch64-apple-ios

# 单元测试（不依赖 ROM；在 Zakuro checkout 内）
cargo test -p zakuro-ios --lib

# linked 变体的单元测试（cfg(test) 用占位表，不需要 ROM/游戏代码）
ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 cargo test -p zakuro-ios --lib --features linked
```

单元测试覆盖 `zk_last_error` 的默认值、写入/清空、文本内 NUL 转义、空 `rom`、
非法 UTF-8 路径、错误状态的线程隔离；`linked` 构建的 title ID/接口版本接线、
占位表 `Linked`、ABI 版本门；`zk_recompiled_status` 对“有 linked 表但未接受 / 已接受”
与回退原因的区分；帧计时初值/清零、profiler 空句柄。不加载 ROM，也不需要 iOS
设备。真实 `libgame.a` 的链接验证与已验证命令/结果见
[`RECOMP.md`](RECOMP.md#8-测试计划) 与 [`PERF.md`](PERF.md) §6。
