# 3dsrecomp → iOS 静态链接方案（I3-T2）

> 目标：让 3dsrecomp 的 AOT C 代码以**静态链接**方式进入 iOS App，与
> `libzakuro_ios.a` 一起链接，运行时由 `zk_create` 交给 Zakuro；**不使用
> `dlopen`、不启用 JIT**。本文是设计、命令、版本规则与 build-infra 清单；
> C ABI 本身见 [`README.md`](README.md)，集成大图见
> [`docs/integration.md`](../../docs/integration.md)。

## 0. 结论（TL;DR）

- **每款游戏一个 IPA**：3dsrecomp 生成 C → `clang -target arm64-apple-ios` →
  `libgame.a` → 与 `libzakuro_ios.a` 一起静态链接进 App。
- **`Config.linked` 是唯一通路**：`zakuro-ios` 加 cargo feature `linked`，编译期把
  `recomp_*` 表交给 Zakuro；`zk_create` 自动挂上，Swift 调用方式不变。
- **title ID 必须构建期注入**：生成的符号里没有 title ID（只有表和 ABI/generation），
  所以通过 `ZAKURO_LINKED_PROGRAM_ID` 在编译期烘进库；`build.rs` 校验。
- **不匹配安全回退**：title ID 或接口 ABI 不符时，Zakuro 的 loader 打印警告并
  **全解释器**运行，不崩溃（只是慢）。用 `zk_linked_code()` /
  `zk_linked_program_id()` / `zk_recompiled()` 诊断。
- **update/DLC 暂不覆盖**：3dsrecomp 目前不读 update/DLC，iOS FFI 也未暴露
  `Config.update`/`dlc`；见 §6。
- 默认构建（不带 feature）仍是**纯解释器壳**，无 ROM 也能启动；两种构建来自同一份
  `src/lib.rs`。
- **方案选择（2026-11-12 更新）**：评估 [Pocket Native](https://github.com/whovian64/pocket-native)
  （MIT；背景见 [`docs/pocket-native.md`](../../docs/pocket-native.md)）后，本次采用
  **方案 B（vanilla Zakuro + 静态 `Linked`）**；**方案 A（整套换成 Pocket Native 的
  `engine` + `recompiler` 上游）**留作 I3-T4 渲染/性能升级路径。两者的实测事实、
  优缺点与迁移清单见 §0.5 与 §11。

## 0.5 方案评估：Pocket Native 上游（A）vs vanilla Zakuro + 静态 Linked（B）

> 2026-11-12 实测 Pocket Native 仓库 `main`（workspace 0.5.5）；背景复用清单见
> [`docs/pocket-native.md`](../../docs/pocket-native.md)。这里只写与 **I3-T2 静态
> 链接**直接相关的结论。

### 0.5.1 实测事实

| 事实 | 证据（Pocket Native 仓库） |
|---|---|
| `recompiler/` 是 **3dsrecomp 的 vendored fork**，`engine/` 是 Zakuro fork；workspace 版本 **0.5.5**（vanilla Zakuro 为 0.2.32） | `Cargo.toml`、`CREDITS.md` |
| fork 的接口版本是 **ABI 7**（`OLDEST_ABI = 5`）；`Context` 在 vanilla ABI5 布局**末尾追加** `uint8_t *fastmem`，编译期 `RECOMP_FASTMEM` 让代码走快速内存视图 | `recompiler/abi/recomp.h`、`recompiler/abi/src/lib.rs` |
| fork 的 `Linked` 只有 6 个字段（program_id, abi, entries, count, modules, module_count），**没有** upstream ABI5 的 `generation`/`origins`（update/mod 变更检测） | `recompiler/src/port.rs`、`recompiler/abi/src/lib.rs` |
| fork 的 `port.rs` 与 upstream 是**同一范式**：`extern "C"` 读 `recomp_*` 符号 → `Linked::new(...)` → `run(Some(code))`；`build.rs` 用 `cargo:rustc-link-lib=static=recomp` 链接 `code/librecomp.a` | `recompiler/src/port.rs` |
| **它自己的量产路径是 dlopen**：容器里 `3dsrecomp build` 出 `<title>.so`，Android/手持前端从 `<title>.so` 加载 | `scripts/container/inside.sh`、`android/src/lib.rs` |
| `engine/` 的 GLES 渲染器基于 **EGL**（`gles = glow + glutin_egl_sys`），面向 Linux/Android；iOS 需换 `CAEAGLLayer`/`EAGLContext` 或 Metal | `engine/gpu/Cargo.toml`、`frontend/` |
| `titles/<id>/profile.toml` 已有 Pokémon **X/Y/AS/USUM** 的 per-game 性能配置（`realtime_gpu`、`[[option]]` 降低 GPU 工作量、副屏帧率等） | `titles/0004000000055D00`（X）、`0004000000055E00`（Y）、`000400000011C500`（AS）、`00040000001B5000`/`01B5100`（US/UM） |
| MIT：`LICENSE` 保留 `fearkov`/`whovian` 版权，`CREDITS.md` 列明 upstream 与贡献者 | `LICENSE`、`CREDITS.md` |

**结论先行**：Pocket Native 的 `port.rs` **没有另一套 iOS 静态链接机制**，它确认的正是
我们已经实现的"构建期符号 → `Config.linked`"范式（且上游 ABI5 版本还多了
`generation`/`origins`）。它真正多出来的是 **engine fork 的渲染器/性能改动、ABI 7、
`titles/` profile**；而它的量产路径是 dlopen，iOS 用不了——静态链接仍是我们自己的
必要工作。

### 0.5.2 方案 A：以 Pocket Native 的 `engine` + `recompiler` 作为 iOS 上游

做法：固定 Pocket Native commit 并 vendor（或作为 Zakuro 替代目录），
`scripts/build-zakuro-ios.sh` 改为在 `engine/` 布局里加入 `crates/zakuro-ios`；
生成 C 用 fork 的 `recompiler`（可在 Linux 容器出 C），再在 macOS 用 iOS clang 编译。

- 优点：一套上游同时带来 **GLES 渲染器、`RECOMP_FASTMEM` 快速路径、per-game
  profile、低功耗性能调优**（I3-T4/I4 的硬需求）；fork 的 loader 同样支持
  `Config.linked`；`recompiler` 支持 `CC`/`RECOMP_CFLAGS` 注入（与容器里
  `-DRECOMP_FASTMEM` 同一机制），iOS clang 路径可复用；MIT 可商用。
- 代价/风险：
  - **ABI 不兼容**：fork 生成 **ABI 7** 代码，vanilla Zakuro（ABI 5）会拒绝并回退
    解释器 → 必须 **engine + recompiler 成套替换**，不能只换一边；
  - fork `Linked` **没有 `generation`/`origins`**：我们 `linked` 模块的
    `with_origins(...)` 与 7 个符号要改成 5 个（update/mod 检测更弱）；
  - engine fork 与 vanilla API 有差异（实测：`Config.texture_packs` 不存在、
    `resolution` 为 `f32`、新增 `software_draws`；`System`/`loader`/`Screen`/
    `InputState` 接口本身兼容），`zakuro-ios/src/lib.rs` 需适配；
  - 目录/脚本布局（`engine/`、`recompiler/`）、`THIRD_PARTY`/`NOTICE` 归属、许可证
    文件都要新增；fork 活跃，必须固定 commit 防漂移；
  - GLES 渲染器是 EGL，**不能直接用于 iOS**，仍要 ios-shell 做 CAEAGLLayer/Metal
    适配（属 I3-T4，不是 I3-T2 的阻塞项）。
- 估算：I3-T2 范围内约 **2–4 人日**（vendor + 脚本 + FFI 适配 + 编译验证），外加
  I3-T4 的 GLES/iOS 适配。

### 0.5.3 方案 B：cherry-pick `port.rs` 静态范式 + 沿用 vanilla Zakuro（本次采用）

做法：保持 `fearkov/zakuro` + `fearkov/3dsrecomp`（ABI 5，带
`generation`/`origins`）；`zakuro-ios` 加 `linked` feature，编译期读 `recomp_*` 表交给
`Config.linked`。`titles/` profile 只作为**将来 app 配置的格式参考**（它的
`[advanced]`/`[[option]]` 是 Pocket Native engine 的功能，vanilla 不识别，不能直接生效）。

- 优点：
  - **已实测通过**（Linux + Rust 1.99.1 + 真实 Zakuro checkout，见 §8.4）：
    `cargo check --target aarch64-apple-ios`（默认与 `--features linked`）、host 单测
    8/9 个、`cargo fmt --check`、`llvm-nm -u` 的符号检查全部通过；
  - ABI 5 的 `origins` 能在 update/mod 改动函数时只把变动函数降级解释器（比 fork 强）；
  - 改动只在 `ios/zakuro-ios/`，无 fork/许可证归属负担，不阻塞 I3-T3/T4；
  - 与现有 `scripts/build-zakuro-ios.sh`、`libzakuro_ios.a` 流程零冲突。
- 代价：拿不到 Pocket Native 的 GLES 渲染器 / fastmem / profile 调优（留到 I3-T4）。

### 0.5.4 建议

1. **I3-T2 采用 B**：与 Pocket Native `port.rs` 等价的静态 `Linked` 范式已实现并通过
   编译/单测，不引入 fork 风险。
2. **I3-T4 单独立项评估 A**：先做 fork `engine` 的 iOS 编译 spike（GLES→CAEAGLLayer
   或 Metal）与 fastmem 收益；若显著，再整套切换 engine+recompiler（固定 commit、补
   `THIRD_PARTY`/`NOTICE`），并按下文 §11 改本 crate 的 `linked` 模块。
3. `titles/<id>/profile.toml` 的 **per-game 配置思路**进 I4 build manifest
   （由 ios-shell/build-infra 映射到 app 设置，不进本 crate）。
4. 若 Lead 决定直接走 A，本 crate 与构建脚本的改动清单见 §11。

## 1. 上游事实（2026-11-12，`fearkov/3dsrecomp` 与 `fearkov/zakuro` 的 main）

### 1.1 `3dsrecomp port` 做什么

```bash
3dsrecomp port <rom> <dir> [--overrides ...] [--name <name>] [--zakuro <checkout>]
```

- 在 `<dir>/code/` 写出：`recomp.h`、`entries.c`（全部常量表）、每个程序一份
  函数头、`codeNNN.c`（函数体）、可选 `natives.c` 与 `hand/`（手写 override），
  以及编译好的 `code/librecomp.a`；
- 在 `<dir>/` 写一个**桌面** Cargo 工程（`Cargo.toml`、`build.rs`、`src/main.rs`），
  `main.rs` 里把 `program_id` 烘成 `0x{16 hex}` 字面量并用
  `Linked::new(...).with_origins(...)` 交给 Zakuro——**这个工程 iOS 不用**，
  我们只借它的 `main.rs` 取 title ID；
- 编译参数（[`src/compile.rs`](https://github.com/fearkov/3dsrecomp/blob/main/src/compile.rs)）：
  `-O2 -ffp-contract=off -fno-math-errno -w -fPIC -fvisibility=hidden`，
  编译器来自 `CC`，归档器来自 `AR`。**`-ffp-contract=off` 必须保留**，否则浮点
  结果与解释器不一致；
- 生成的 C 只用到 clang 都支持的内建与头文件（`__builtin_clz`、`__builtin_bswap32`、
  `__builtin_expect`，`math.h`/`stdint.h`/`string.h`），没有内联汇编或 GNU 扩展，
  **可以直接用 iOS clang 编译**；也没有任何 `dlopen`。

导出的符号（[`docs/interface.md`](https://github.com/fearkov/3dsrecomp/blob/main/docs/interface.md)，
当前接口版本 5）：

| 符号 | C 类型 | 作用 |
|---|---|---|
| `recomp_abi` | `const uint32_t` | 接口版本（`RECOMP_ABI` = 5） |
| `recomp_generation` | `const uint32_t` | 代码生成器版本（当前 5） |
| `recomp_entry_count` | `const uint32_t` | 可执行文件的入口点数量 |
| `recomp_entries` | `const Entry[]` | 入口点表（地址 + 函数指针） |
| `recomp_module_count` | `const uint32_t` | CRO 模块数量 |
| `recomp_modules` | `const Module[]` | 每个 CRO 模块一张表 |
| `recomp_origins` | `const Origins[]` | 函数由哪些字节生成（update/mod 变更检测） |
| `recomp_natives` | `uint8_t` | host 侧 C 库函数开关（linked 路径暂不用） |

> **没有 title ID 符号**。title ID 由 `port` 写进 `main.rs`，所以 iOS 侧也要
> 构建期注入（见 §3.3）。

> **Pocket Native 的 `recompiler/` 是 3dsrecomp 的 vendored fork，接口版本是 ABI 7**
> （`OLDEST_ABI = 5`）：符号集里**没有** `recomp_generation`/`recomp_origins`，`Linked`
> 只有 6 个字段，`Context` 末尾多一个 `fastmem`。它和 upstream ABI 5 **不能混用**
> （详见 §0.5、§5）。本文件的所有命令/符号表默认指 **upstream 3dsrecomp（ABI 5）**。

### 1.2 Zakuro 怎么消费 linked code

[`crates/zakuro-core/src/loader.rs`](https://github.com/fearkov/zakuro/blob/main/crates/zakuro-core/src/loader.rs)
在加载 ROM 后：

1. `Config.linked: Option<recompiled::Linked>`（`recompiled::Linked` 即
   `recomp_abi::Linked`）非空时优先使用；
2. 检查 `linked.program_id() == title.program_id()`，不符 → `log::warn!` 并
   **解释全部代码**；
3. `recompiled::Library::linked(&linked)` 检查接口 ABI（接受
   `OLDEST_ABI..=ABI`，当前 **4..=5**）；不符 → 警告 + 解释全部；
4. `Origins` 可用（generation ≥ 3）时按 `recomp_origins` 的 FNV 哈希校验函数字节，
   被 update/mod 改过的函数标 stale → 只让这些函数走解释器；
5. 成功则 `system.recompiled = Some(library)`，CPU 优先跑 AOT 代码。

iOS 上 `Config.recompiled`（dlopen 路径）与 `find_recompiled` 都必须保持关闭：
iOS 不允许加载未签名的 dylib，本 crate 的 `zk_create` 固定
`find_recompiled = false`、`recompiled = None`。

## 2. 静态链接的实现方式（与 §0.5 的 A/B 上游选择无关）

> §0.5 的 A/B 是"选哪个上游"；这一节是"静态链接在 iOS 上怎么落地"的选择，两者独立。

| 实现方式 | 做法 | 结论 |
|---|---|---|
| **1. 构建期 `Linked`（采用）** | `--features linked`：Rust 侧用 `extern "C"` 读 `recomp_*` 表，编译期烘 title ID；App 链接 `libgame.a` | 无运行时注册、无 constructor 顺序问题、Swift 不改；代价是**每款游戏重链一次 `libzakuro_ios.a`** |
| 2. `dlopen` 加载库 | Zakuro 的 `Library::open("/path.dylib")` | **iOS 不可行**：不能加载未签名/包外的动态库，且违背侧载与无 JIT 策略 |
| 3. 运行期注册 C shim | App 里放一个 C 构造函数调用 `zk_register_linked(...)`，传表地址 + title ID | 可保留**一份通用** `libzakuro_ios.a`；但需要 per-game C shim + `-force_load`（静态归档不会因 constructor 被拉入组成员），ABI 多一层、更容易出错。作为未来选项保留 |

为什么不能"通用 `libzakuro_ios.a` + 任意 `libgame.a`"：静态归档的链接语义是
"**谁引用了符号才拉入成员**"；通用库不引用 `recomp_*`，因而无法从中拉出表对象，
除非用 `-force_load` 或运行期注册（方式 3）。而每款游戏本来就要出一个独立 IPA，
per-game 重链 Rust 静态库的增量成本很小（依赖已缓存，只有本 crate 重新编译/归档）。

**为什么 C ABI 里没有 `zk_create_linked`**：链接发生在构建期、一个 IPA 只带一款游戏，
`zk_create` 没有第二份代码可选，再加一个入口只会重复语义。等价路径是：
`--features linked` 决定行为 + `zk_linked_code()` / `zk_linked_program_id()` 报告构建
形态 + `zk_recompiled(sys)` 报告运行时是否真的用上了 AOT。若将来要做"一份通用库 +
运行期注册"（方式 3），再新增带表指针的 `zk_create_linked(...)` 不迟。

### 2.1 ABI 边界在哪

```
┌──────────────────────────── App（Swift） ────────────────────────────┐
│  zk_create(rom, data_dir) / zk_run_frame ...                         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ C ABI（ios/ZakuroBridge.h）
┌──────────────────────────────▼──────────────────────────────────────┐
│ libzakuro_ios.a（Rust）：System/CPU/GPU/HLE；Config.linked            │
│   · 只读 recomp_* 常量表 → recompiled::Library（二进制搜索入口）       │
│   · 提供 Host 回调（read/write/interpret/lookup/svc）                  │
└──────────────────────────────▲──────────────────────────────────────┘
                               │ recomp.h：Context / Entry / Module / Host
┌──────────────────────────────┴──────────────────────────────────────┐
│ libgame.a（3dsrecomp 生成的 C，AOT ARM→C 代码）                        │
│   · 遇到内存访问/svc/解释器缺口 → 回调 Host，再回到 Rust              │
└─────────────────────────────────────────────────────────────────────┘
```

- 边界 = `recomp.h` 的结构体布局 + 上表 7 个符号（ABI 版本保护布局）。
- guest 的 ARM 指令在构建期变成普通 C；运行时没有 ARM 模拟/JIT。
- `Context` 的寄存器、`Host` 回调、`Entry`/`Module`/`Origins` 表都由
  `recomp-abi`（Rust 侧）与 `recomp.h`（C 侧）成对定义，上游用测试保持一致。
- **title ID 是 ABI 之外的唯一构建期信息**：`zk_create` 需要它来构造
  `Linked`，因此通过 `ZAKURO_LINKED_PROGRAM_ID` 提供。

## 3. iOS 构建流水线

### 3.1 前置

- macOS VM：Xcode 16.4 / iOS 18.5 SDK（现有环境）、Rust 1.99.1 +
  `aarch64-apple-ios`、`3dsrecomp` CLI（版本规则见 §5）；
- 用户自己的 ROM 放 `ROM/`（**gitignored，绝不提交**）；
- 生成物放 `build/game/<title>/`（gitignored）。

### 3.2 生成 C 并用 iOS clang 编译

`3dsrecomp port` 内部用 `CC`/`AR` 编译并归档，所以把 `CC` 指向 iOS clang 即可
一步得到 arm64 iOS 的静态库：

```bash
export SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export CC="$(xcrun --sdk iphoneos -f clang) -target arm64-apple-ios16.0 -isysroot $SDK"
export AR=ar

cd <3dsrecomp checkout>
cargo build --release
target/release/3dsrecomp port "$ROM" "$REPO/build/game/<title>" --name <title>
```

> `-target arm64-apple-ios16.0` 与应用 deployment target（`ios/app/project.yml`
> 的 iOS 16.0）保持一致；如 SDK 要求可改成对应版本。

校验产物 arch 与符号：

```bash
xcrun lipo -info "$REPO/build/game/<title>/code/librecomp.a"      # 期望 arm64
nm -g "$REPO/build/game/<title>/code/librecomp.a" | grep 'recomp_' # 见表
```

取 title ID（`port` 写进桌面工程 `src/main.rs` 的字面量）：

```bash
TITLE_ID=$(grep -oE '0x[0-9A-F]{16}' "$REPO/build/game/<title>/src/main.rs" \
           | head -1 | sed 's/^0x//')
echo "$TITLE_ID"    # 例如 0004000000055E00（Pokémon Y 美版）
```

**内存/并行注意**：`3dsrecomp` 只在 Linux/Windows 上估算空闲内存，macOS 上
`spare_memory()` 返回 `None` → 会按 CPU 核数并行起 clang，且不设内存上限。
大游戏的 `codeNNN.c` 单个可达数 MB，`clang -O2` 峰值内存高：**macOS VM 建议 ≥ 16 GB
内存**；内存不足时改用顺序编译（保留同样的关键参数）：

```bash
cd "$REPO/build/game/<title>/code"
for f in *.c; do
  "$(xcrun --sdk iphoneos -f clang)" -target arm64-apple-ios16.0 \
    -isysroot "$SDK" -O2 -ffp-contract=off -fno-math-errno -w \
    -fPIC -fvisibility=hidden -I. -c "$f" -o "${f%.c}.o" || exit 1
done
ar rcs librecomp.a *.o
```

大游戏首轮编译以小时计（数百个对象），后续可做对象级缓存。

### 3.3 构建 linked 版 `libzakuro_ios.a`

```bash
# 1) 先跑现有脚本：clone/补丁 Zakuro checkout、复制本 crate、构建默认壳库
scripts/build-zakuro-ios.sh

# 2) 在同一 checkout 里按游戏构建 linked 变体（title ID 来自 §3.2）
cd third_party/zakuro
ZAKURO_LINKED_PROGRAM_ID="$TITLE_ID" \
  cargo build -p zakuro-ios --release --features linked --target aarch64-apple-ios

# 3) 收集到 per-game 目录
mkdir -p "$REPO/build/ios/<title>"
cp target/aarch64-apple-ios/release/libzakuro_ios.a "$REPO/build/ios/<title>/libzakuro_ios.a"
cp "$REPO/build/game/<title>/code/librecomp.a"        "$REPO/build/ios/<title>/libgame.a"
```

- `build.rs` 校验 `ZAKURO_LINKED_PROGRAM_ID`：缺失/不是 16 位十六进制 →
  **编译期报错**（防止产出"看起来 AOT 实际解释器"的包）。
- 多游戏连续构建建议 per-game `CARGO_TARGET_DIR`（或 `cargo clean -p zakuro-ios`）；
  `build.rs` 已声明 `rerun-if-env-changed`，但独立 target dir 更稳。
- 静态库/二进制、生成 C 都在 `build/`，**不进仓库**。

### 3.4 App 最终链接（`ios/app/` 由 ios-shell 改，不在本任务作用域）

同一目录放两个静态库，**`-lzakuro_ios` 必须排在 `-lgame` 之前**（先产生
`_recomp_*` 未定义引用，再让 `libgame.a` 解析）：

```yaml
# ios/app/project.yml（示例，ios-shell 按游戏参数化）
OTHER_LDFLAGS:
  - "-L$(SRCROOT)/../../build/ios/<title>"
  - "-lzakuro_ios"
  - "-lgame"
```

- 不需要 `-force_load`：`recomp_*` 表对象由未定义引用拉入；若启用 `-all_load`
  反而可能把测试/多余对象带进来。
- 缺少 `libgame.a` 或顺序颠倒时，链接器报
  `Undefined symbols ... _recomp_abi/_recomp_entries/...`——把错误提前到构建期，
  符合预期。
- 两套 IPA：
  - **壳/无游戏**：默认 `libzakuro_ios.a`（不带 feature、无 `-lgame`），
    `zk_linked_code()` 返回 `0`；
  - **游戏**：linked 库 + `libgame.a`，`zk_linked_code()` 返回 `1`。
- 建议 ios-shell 把新增的 `zk_linked_code` / `zk_linked_program_id` /
  `zk_recompiled` 同步进 `ios/ZakuroBridge.h`，并在 `zk_create` 成功后把
  `zk_recompiled` 写进应用日志（真机诊断最可靠的方式）。

## 4. 运行期行为（QA 对照日志用）

| 情况 | 结果（Zakuro loader 日志 / `zk_recompiled`） |
|---|---|
| 正常 | `running the recompiled code linked in, N entry points, M modules`，`zk_recompiled()==1` |
| title ID 不符 | `the code linked in is for title X, not Y, interpreting everything`，`zk_recompiled()==0` |
| 接口 ABI 不符 | `could not use the code linked in, it was built for version V of the interface, this is 5, interpreting everything`，`zk_recompiled()==0` |
| update/mod 改动函数 | `K functions changed since the game was recompiled ... they run in the interpreter`（其余 AOT） |

`zk_create` 自身也会 `eprintln!` 一行 linked 结果；`zk_last_error()` 仍只表示
**加载失败**（不是回退）。

## 5. 版本匹配规则

- **接口 ABI**：`recomp.h` 的 `RECOMP_ABI`（当前 **5**）对应 `recomp_abi::ABI`；
  Zakuro 接受 `OLDEST_ABI..=ABI`（当前 **4..=5**）。版本号在布局/字段语义变化时
  由上游 +1。
- **generation**（代码生成器，当前 **5**）：更老的代码仍可运行，只是缺优化
  （4 = svc 就地执行，5 = 主机侧除法）；`Library::generation()` 可读。
- 结构体布局由上游测试把 `recomp.h` 与 `recomp-abi` 绑在一起；**不要跨 rev 混用**
  （ABI 号只在正确 bump 时保护，错误的混用可能静默错位）。
- 推荐规则：
  1. 用 **Zakuro 的 `Cargo.lock` pin 的 recomp-abi rev** 构建 3dsrecomp CLI：
     ```bash
     grep -A3 'name = "recomp-abi"' third_party/zakuro/Cargo.lock
     #  source = "git+https://github.com/fearkov/3dsrecomp#<rev>"
     git -C <3dsrecomp checkout> checkout <rev>
     cargo build --release
     ```
  2. 升级时 **Zakuro 与 3dsrecomp 同批升级、重新生成 C、重新出包**；不要只换一边。
  3. 运行时兜底：不匹配只会回退解释器 + 警告（性能问题，不是稳定性问题）。
  4. 出包自检：`zk_linked_code()==1`、`zk_linked_program_id()==ROM title ID`、
     `zk_recompiled()==1`。

**vanilla 与 Pocket Native fork 的兼容矩阵**（切换上游前必读）：

| 生成代码 \ 宿主 | vanilla Zakuro（ABI 5，接受 4..=5） | Pocket Native engine（ABI 7，接受 5..=7） |
|---|---|---|
| upstream 3dsrecomp（ABI 5，本方案） | ✅ 已实测（§8.4） | ⚠️ 理论上 ABI 在范围内、`Context` 只是末尾多 `fastmem`，但 fork 的 `Linked`/loader 没有 `origins`，需适配后才能静态链 |
| Pocket Native recompiler（ABI 7，含 `RECOMP_FASTMEM`） | ❌ 7 > 5 → 拒绝 → 全解释器（安全但慢） | ✅ 但必须 engine + recompiler 整套、且用 fork 的 `Linked`（6 字段） |

- 结论：**不能只换渲染器/只换 recompiler**。方案 A 必须成套替换，并按 §11 改 FFI。

## 6. update / DLC / mod

- iOS FFI 现状：`zk_create` 不传 `Config.update`（update CIA）、`Config.dlc`
  （DLC CIA）或 mod → 目前只跑**基础 ROM**。
- **update**：3dsrecomp CLI 明确拒绝 update CIA
  （`rom.rs`：`this .cia is an update, not a game`），且当前没有"按 update 代码
  重编译"的入口。若设备上加载了 update，`Origins` 哈希校验会把被 update 改过的
  函数转为解释器（安全但变慢）；要全速需上游支持或按 update 的 exefs 重编译。
- **DLC**：DLC CIA 不在基础 ROM 里，3dsrecomp 的模块发现只读 ROM 内 CRO；因此
  DLC 专属代码即使将来加载也会走解释器。
- **mod**：iOS 侧无 mod 加载路径；3dsrecomp 的 `Mods` API 支持 code/romfs 覆盖，
  但需要自定义构建流程，不在本次范围。
- **不同 region/版本 ROM**：title ID 不同 → 内置代码被拒（安全回退）；必须对
  实际 ROM 版本重编译。
- 当前 linked 路径不暴露 `recomp_natives`，`ZAKURO_NATIVES=0` 对 linked 代码无效
  （host 除法快速路径始终开启）。

## 7. 覆盖率与性能预期（不承诺具体数字）

- 上游实测 4 款游戏约 **99.8%** 指令由重编译代码执行（Pokémon Y 约 0.21% 走
  解释器），见 [`docs/feasibility.md`](../../docs/feasibility.md)。
- 当前基线：Pokémon Y 纯解释器真机约 **20 fps**（I2 验收）。
- AOT 后 CPU 侧预计大幅提升；但 iOS 关闭 shader JIT 后，PICA200 顶点/光栅在 CPU
  上跑，**GPU 侧可能成为新瓶颈**（`docs/feasibility.md` 风险表）。因此整体帧率
  必须真机测（I3-T4：速度 %、1% low、内存、热降频），本文不预先给倍数。
- 判据：`zk_recompiled()==1` 且帧率明显高于 20 fps；若 `==0`，先按 §4 查
  title/ABI 回退，而不是当性能问题。
- 体积：`libgame.a` 中间对象可达数百 MB；Release + `-dead_strip`/`strip` 后
  IPA 仍会变大，按游戏逐包接受。

## 8. 测试计划

### 8.1 已实现：host 单元测试（不需要 ROM，也不需要游戏 C）

`cfg(test)` 会用占位表替代真实符号，所以 `--features linked` 的测试可以在
任何有 Rust 的机器上跑（crate 需在 Zakuro checkout 内，且必须给
`ZAKURO_LINKED_PROGRAM_ID`，否则 `build.rs` 会拒绝构建）：

```bash
ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 cargo test -p zakuro-ios --lib --features linked
# 默认（解释器）构建回归
cargo test -p zakuro-ios --lib
```

覆盖：`zk_linked_code()`/`zk_linked_program_id()` 与构建期 env 一致；
`linked::code()` 用占位表构造 `Linked` 且 `recompiled::Library::linked` 接受
（ABI 范围）；ABI 3 被拒绝（版本门）；默认构建返回 `0`；原有错误路径测试不变。

> 占位表验证的是**接线**（符号名/字段映射/版本门），不是生成 C 的真实布局；
> 真实布局由上游对 `recomp.h` 的测试保证。

### 8.2 macOS 链接彩排（不需要 ROM）

```bash
cd third_party/zakuro
ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 \
  cargo build -p zakuro-ios --release --features linked --target aarch64-apple-ios
nm -u target/aarch64-apple-ios/release/libzakuro_ios.a \
  | grep -E '_recomp_(abi|generation|entries|entry_count|modules|module_count|origins)$'
# 期望 7 个未定义符号：App 链接时由 libgame.a 解析
```

真实生成归档存在时（`libgame.a`）再做：

```bash
xcrun lipo -info build/ios/<title>/libgame.a          # arm64
nm -g build/ios/<title>/libgame.a | grep 'recomp_abi' # 表对象在
```

如果没有 ROM、只想验证 extern 的名字/类型与链接器解析，可用一个**手写的**
小 C 桩（不是生成的 C，也不含游戏数据）：

```c
/* recomp_stub.c：仅用于链接彩排，不是游戏代码 */
#include <stdint.h>
typedef struct { uint32_t address; void (*code)(void *); } Entry;
typedef struct { const char *name; uint32_t *base; uint32_t size;
                 uint32_t count; const Entry *entries; } Module;
typedef struct { uint32_t count, piece_count; const void *pieces, *functions;
                 const void *runs, *owners; uint8_t *stale; uint32_t *starts; } Origins;
const uint32_t recomp_abi = 5;
const uint32_t recomp_generation = 5;
const uint32_t recomp_entry_count = 0;
const uint32_t recomp_module_count = 0;
const Entry recomp_entries[1] = {{0, 0}};
const Module recomp_modules[1] = {{0, 0, 0, 0, 0}};
const Origins recomp_origins[1] = {0};
```

```bash
cc -c recomp_stub.c -o recomp_stub.o && ar rcs librecomp_stub.a recomp_stub.o
# 再链接一个只调 zk_linked_code()/zk_linked_program_id() 的小程序即可
```

### 8.3 真机验收（需要 ROM，I3-T3/T4 之后）

1. Pokémon Y 构建 linked IPA → 安装；
2. 日志确认 `zk_linked_code()==1`、`zk_linked_program_id()==` ROM title ID、
   `zk_recompiled()==1`；
3. 20 分钟 soak：fps、1% low、内存、温度（qa-compat 归档 `docs/qa/`）；
4. 若回退，按 §4 的三类警告定位（title ID / ABI / update）。

### 8.4 本仓库已实际执行的验证（2026-11-12，Linux + Rust 1.99.1）

在本地 Linux（无 macOS）按 `scripts/build-zakuro-ios.sh` 的同样方式把本 crate 复制
进真实 Zakuro checkout（`recomp-abi` 用其 `Cargo.lock` pin 的 `df82e6e3`，ABI 5 /
GENERATION 5）后执行：

| 命令 | 结果 |
|---|---|
| `cargo check -p zakuro-ios --target aarch64-apple-ios` | ✅ 通过，本 crate 0 警告 |
| `ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 cargo check -p zakuro-ios --target aarch64-apple-ios --features linked` | ✅ 通过，本 crate 0 警告 |
| 同上但**不给** env | ✅ 按预期在 `build.rs` 报错退出（"needs ZAKURO_LINKED_PROGRAM_ID"） |
| `cargo test -p zakuro-ios --lib` | ✅ 8 passed |
| `ZAKURO_LINKED_PROGRAM_ID=... cargo test -p zakuro-ios --lib --features linked` | ✅ 9 passed（含 ABI 版本门、占位表构造 `Linked`） |
| `cargo fmt -p zakuro-ios -- --check` | ✅ 干净 |
| `cargo build -p zakuro-ios --release --target aarch64-apple-ios`（默认） | ✅ 通过；`llvm-nm -u` 里 `_recomp_*` 未定义符号 **0 个**（纯解释器壳不引用游戏代码） |
| 同命令 `--features linked` | ✅ 通过；`llvm-nm -u` 恰有 **7 个**未定义 `_recomp_*`（`_recomp_abi/_entries/_entry_count/_generation/_modules/_module_count/_origins`），将由 `libgame.a` 在 App 链接时解析——与 §8.2 预期一致 |

Linux 做不到、需要 macOS VM/Lead 的部分：`clang -target arm64-apple-ios` 编译生成 C、
App 最终链接（`-lzakuro_ios -lgame` 顺序）、`xcodebuild`、真机性能——即
I3-T3/T4 的验证项。

## 9. build-infra 可执行清单

- [ ] **冻结版本**：把 3dsrecomp rev（= Zakuro `Cargo.lock` 的 recomp-abi rev）与
      Zakuro rev 写进构建 manifest/CI 变量；出包记录二者。
- [ ] **3dsrecomp CLI**：macOS VM 上 `cargo build --release`；确认 `port` 可用
      （或评估 Linux 生成 C + macOS 编 C 的替代路径）。
- [ ] **per-game 生成脚本**：封装 §3.2 的 `CC`/`AR` 用法 → `build/game/<title>/`；
      校验 `lipo -info` = arm64、`nm` 有 `recomp_*`；提取 `TITLE_ID`。
- [ ] **linked 静态库脚本**：`ZAKURO_LINKED_PROGRAM_ID=$TITLE_ID cargo build ...
      --features linked` → `build/ios/<title>/{libzakuro_ios.a,libgame.a}`
      （per-game target dir）。
- [ ] **IPA 打包**：壳（默认库、无 `-lgame`）与游戏（linked 库 + `-lgame`，顺序正确）
      两套；per-game `PRODUCT_NAME`/bundle id；产物 SHA256 + manifest。
- [ ] **发布前自检**：`ZAKURO_LINKED_PROGRAM_ID=<title> cargo test -p zakuro-ios
      --lib --features linked`；`nm -u` 的
      7 个 `_recomp_*`；`zk_linked_code()==1` 日志；失败时把三类回退日志写进报告。
- [ ] **CI/缓存**：Rust target 缓存 + 3dsrecomp Cargo 缓存；避免每款重编 Zakuro
      依赖（只重编/重链本 crate）。
- [ ] **仓库卫生**：`build/`、`third_party/`、`ROM/` 均 gitignored；不提交
      `.a`/`.o`/生成的 C/ROM（见 `AGENTS.md` 硬性规则）。

## 10. 已知缺口 / 后续任务

1. `zk_create` 尚未暴露 update/DLC/mod 配置 → 需要后续 FFI（如
   `zk_create_ex` 或 `zk_set_update`/`zk_set_dlc`），并与 3dsrecomp 上游配合。
2. **Pocket Native 方案 A 未实施**（建议作为 I3-T4 专项评估）：需要 vendor 固定
   commit、整套换成 fork 的 engine+recompiler、按 §11 适配 FFI、补
   `THIRD_PARTY`/`NOTICE` 归属。当前方案 B 不依赖它。
3. 运行期注册方案（§2 方式 3）未实现；若 per-game 重链成本成为 CI 瓶颈再评估。
4. `titles/<id>/profile.toml` 的 per-game 配置尚未映射到 iOS app 设置
   （I4，ios-shell/build-infra）。
5. 真机性能数据待 I3-T4/T5；若 AOT 后仍受 GPU/顶点限制，按 `docs/plan.md` 走
   MoltenVK / AOT shader 路线。
6. `ios/app/` 的 per-game 链接参数与 bridging header 更新由 ios-shell 落地；
   本次任务只改 `ios/zakuro-ios/`。

## 11. 附录：切到 Pocket Native（方案 A）时的改动清单（未实施）

> 仅在 Lead 决定采用方案 A 时执行；当前分支是方案 B，不含这些改动。

### 11.0 许可证/归属（硬性，Lead 维护）

- 新增 `THIRD_PARTY.md`/`NOTICE`：写明 `engine/`、`recompiler/` 来自
  [Pocket Native](https://github.com/whovian64/pocket-native)（MIT，
  Copyright (c) 2026 fearkov / whovian），上游为 Zakuro、3dsrecomp（MIT，fearkov），
  并链接其 `CREDITS.md`；
- 仍不提交 ROM/生成 C/静态库；生成物只在 `build/`。

### 11.1 构建脚本（build-infra）

- `scripts/build-zakuro-ios.sh`：checkout 改为固定的 Pocket Native commit；
  workspace member 路径从 `crates/zakuro-core` 变为 `engine/core` 等
  （fork 的 `Cargo.toml` members 已是 `engine/*`），本 crate 复制到
  `engine/zakuro-ios` 并在 workspace 加对应 member；
- 关闭 JIT：fork 的 `engine/gpu` 默认特性为空（不含 cranelift），确认 iOS 构建
  不启用 `jit`；
- 生成 C：用 fork 的 `recompiler` 构建 3dsrecomp CLI，`CC` 指向 iOS clang；如需
  `RECOMP_FASTMEM`，使用 fork 支持的 `RECOMP_CFLAGS`/`CC` 注入（参考其
  `scripts/container/inside.sh`）；
- ABI 自检：fork 生成 C 的 `recomp_abi` 应为 **7**；若仍为 5，说明用的是 upstream
  3dsrecomp，与 fork engine 虽在 `OLDEST_ABI` 范围内但缺 `fastmem`，需验收决定。

### 11.2 runtime-ffi（本 crate）

- `linked` 模块改为 fork 的 **5 符号**（去掉 `recomp_generation`/`recomp_origins`），
  调用 `Linked::new(...)` 后**不要** `.with_origins(...)`（fork 无此方法）；
- `zk_create`：fork `Config` 没有 `texture_packs` → 删除该行；`resolution` 为 `f32`
  （本 crate 未设置，无需改）；`hardware_renderer = false` 保留（iOS 先软件渲染，
  I3-T4 再决定 GLES/Metal）；
- `System`/`loader`/`Screen`/`InputState` 接口经核对与 vanilla 兼容，**`zk_*` 签名
  全部不变**；
- 测试：占位表 ABI 改 7；ABI 门测试改为"低于 5 被拒"。

### 11.3 ios-shell / build-infra

- bridging header 不变（`zk_*` 签名兼容），仅需新增 3 个诊断函数声明；
- per-game 链接参数、IPA 打包不变（仍是 `-lzakuro_ios -lgame` 顺序）。

## 参考

- 3dsrecomp：[`docs/port.md`](https://github.com/fearkov/3dsrecomp/blob/main/docs/port.md)、
  [`docs/interface.md`](https://github.com/fearkov/3dsrecomp/blob/main/docs/interface.md)、
  [`abi/recomp.h`](https://github.com/fearkov/3dsrecomp/blob/main/abi/recomp.h)、
  [`src/compile.rs`](https://github.com/fearkov/3dsrecomp/blob/main/src/compile.rs)
- Zakuro：[`loader.rs`](https://github.com/fearkov/zakuro/blob/main/crates/zakuro-core/src/loader.rs)、
  [`recompiled.rs`](https://github.com/fearkov/zakuro/blob/main/crates/zakuro-core/src/recompiled.rs)、
  [`lib.rs`（Config）](https://github.com/fearkov/zakuro/blob/main/crates/zakuro-core/src/lib.rs)
- Pocket Native（MIT，2026-11-12 评估）：
  [`README`](https://github.com/whovian64/pocket-native)、
  [`CREDITS.md`](https://github.com/whovian64/pocket-native/blob/main/CREDITS.md)、
  [`recompiler/src/port.rs`](https://github.com/whovian64/pocket-native/blob/main/recompiler/src/port.rs)、
  [`recompiler/abi/recomp.h`](https://github.com/whovian64/pocket-native/blob/main/recompiler/abi/recomp.h)、
  [`titles/`](https://github.com/whovian64/pocket-native/tree/main/titles)、
  [`android/src/lib.rs`](https://github.com/whovian64/pocket-native/blob/main/android/src/lib.rs)
- 本仓库：[`docs/pocket-native.md`](../../docs/pocket-native.md)（Lead 的评估）、
  [`docs/integration.md`](../../docs/integration.md)、
  [`docs/feasibility.md`](../../docs/feasibility.md)、[`docs/plan.md`](../../docs/plan.md)
