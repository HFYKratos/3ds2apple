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

## 验证

本目录不能单独构建：它依赖 Zakuro workspace 里的 `zakuro-core` / `zakuro-common`。

```bash
# 完整静态库（macOS + Xcode + Rust aarch64-apple-ios target）
scripts/build-zakuro-ios.sh

# 或在 Zakuro checkout 内做编译检查
cargo check -p zakuro-ios --target aarch64-apple-ios

# 单元测试（只覆盖不依赖 ROM 的错误路径；在 Zakuro checkout 内）
cargo test -p zakuro-ios
```

单元测试覆盖 `zk_last_error` 的默认值、写入/清空、文本内 NUL 转义、空 `rom`、
非法 UTF-8 路径，以及错误状态的线程隔离；不加载 ROM，也不需要 iOS 设备。