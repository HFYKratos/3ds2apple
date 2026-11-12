# 每游戏 AOT 构建：3dsrecomp → linked IPA

把某一款**用户自有 ROM** 在构建期用 3dsrecomp 翻译成 C、编译成 arm64 iOS 静态库，
与该游戏的 linked 版 `libzakuro_ios.a` 一起静态链接进 `ios/app`，产出
`IPA/<name>-AOT.ipa`。运行时没有 JIT、没有 `dlopen`：`zk_create` 从 App 的
Documents 读取 ROM，Zakuro 直接跑构建期生成的 AOT 代码（title/ABI 不匹配时安全回退
解释器，见 [RECOMP.md](../ios/zakuro-ios/RECOMP.md) §4）。

> 设计以 [`ios/zakuro-ios/RECOMP.md`](../ios/zakuro-ios/RECOMP.md) §3/§5/§9 为准；
> 本文只是把它变成可复制执行的脚本命令。**iOS 构建必须在 macOS（VM）上跑**
> （Xcode 16.4 / iOS 18.5 SDK）；Linux 上只能跑 `scripts/tests/` 里的语法/逻辑
> 检查（§11），不能链接 iOS 产物。
>
> 首个目标：Pokémon Y（RECOMP.md 的示例 title ID `0004000000055E00`，美版）。
> 实际 ROM 的 title ID 由脚本从生成代码里提取，别手写死。

## 0. 命令速查（macOS VM，仓库根目录）

```bash
# 一次性准备：克隆/补丁 Zakuro、复制 crates/zakuro-ios、构建基线壳库
scripts/build-zakuro-ios.sh

# 三步（每款游戏）：recomp → linked libs → AOT IPA
scripts/build-recomp-ios.sh "ROM/Pokemon Y.cci" pokemon-y
scripts/build-linked-ios-lib.sh pokemon-y
scripts/build-game-ipa.sh pokemon-y --display-name "Pokemon Y"
# -> IPA/pokemon-y-AOT.ipa
```

**两步用法**（已经跑过 `build-recomp-ios.sh`、只想重出包）：

```bash
scripts/build-linked-ios-lib.sh pokemon-y
scripts/build-game-ipa.sh pokemon-y --display-name "Pokemon Y"
```

脚本之间只通过 `build/` 下的文件传递状态（全部 gitignored），所以每一步都可以单独
重跑；`build-recomp-ios.sh` 会清理旧的 `build/game/<name>/` 再重建。

**分机构建 / 增量复用**（C 在 Linux 生成、IPA 在 macOS VM 链接；2026-11-12 首次
真机 run 之后新增，详见 §5）：

```bash
# 在 Linux 上生成 C（3dsrecomp port，产物拷到 VM）
# 在 macOS VM 上：编译 Linux 生成的 C → 校验 archive + 写 recomp-info.txt
scripts/build-recomp-ios.sh pokemon-y --code-dir /path/to/code \
  --title-id 0004000000055E00

# 也可以直接采用别处编译好的 arm64 librecomp.a（不需要 ROM/3dsrecomp）
scripts/build-recomp-ios.sh pokemon-y --archive /path/to/librecomp.a \
  --title-id 0004000000055E00

# 只重出 IPA：静态库已经在 build/ios/<name>/ 里（不需要 cargo/ROM）
scripts/build-game-ipa.sh pokemon-y --display-name "Pokemon Y"
```

> **title ID 必须逐字节正确**：manifest 里的 `title_id=` 是 16 位大写十六进制
> （如 `0004000000055E00`）。首次 VM run 的 `build-info.txt` 曾写出带尾巴的
> `0004000000055E00n`（printf 过度转义），现在所有写入都经过
> `scripts/lib/aot-common.sh` 的 `aot_normalize_title_id` 修复 + 校验，manifest
> 写完后还会 round-trip 自检；看到 `warning: repaired corrupted title ID` 说明旧
> 文件被修好了（不是错误）。

## 1. 前置条件与资源

| 项目 | 要求 |
|---|---|
| 构建机 | macOS VM（M0：Sonoma 14.8.9，Xcode 16.4，iOS 18.5 SDK，4 vCPU / **8 GB RAM**） |
| Rust | 1.99.1 + `aarch64-apple-ios` target；`cargo` 在 PATH |
| 工具 | `git`、`xcrun`（Xcode）、XcodeGen（`brew install xcodegen`）、`ar`/`nm`/`lipo` |
| ROM | **用户自有**的 base-game `.3ds` / `.cci`，放 `ROM/`（gitignored；绝不提交） |
| 磁盘 | 建议 ≥ 15–20 GB 空闲：3dsrecomp 的 cargo target、生成 C/对象（数百 MB–数 GB）、cargo target、IPA |
| 内存 | 建议 ≥ 16 GB；8 GB VM 用 §5 的顺序编译回退 |
| 网络 | 首次需要 clone `fearkov/3dsrecomp`（`third_party/3dsrecomp`） |

版本冻结规则（RECOMP.md §5）：**3dsrecomp 的 rev 必须等于 Zakuro `Cargo.lock`
为 `recomp-abi` pin 的 rev**。`build-recomp-ios.sh` 会自动从
`third_party/zakuro/Cargo.lock` 读取；只有 Zakuro checkout 还不存在时才退回脚本内置的
fallback rev 并打印警告。**不要单独升级 Zakuro 或 3dsrecomp**：升级必须两份一起、
重新生成 C、重新出包。每次构建的 rev 会写进
`build/game/<name>/recomp-info.txt`、`build/ios/<name>/build-info.txt` 与
`IPA` 对应的 `manifest.txt`。

ROM 生命周期：ROM 只在构建机上被 3dsrecomp 读取，**不进仓库、不进 IPA**；App 运行时
仍需要同一份 ROM（通过 Files/iTunes 放进 App 的 Documents），见 §6 真机验证。

## 2. `scripts/build-recomp-ios.sh`（recomp）

```bash
scripts/build-recomp-ios.sh <rom> [name] [options]
scripts/build-recomp-ios.sh "ROM/Pokemon Y.cci" pokemon-y
scripts/build-recomp-ios.sh "ROM/Pokemon Y.cci" pokemon-y --auto-serial   # 8 GB VM

# 采用已有产物（不需要 ROM；分机构建/重跑用，§5）
scripts/build-recomp-ios.sh pokemon-y --reuse
scripts/build-recomp-ios.sh pokemon-y --archive /path/to/librecomp.a --title-id 0004000000055E00
scripts/build-recomp-ios.sh pokemon-y --code-dir /path/to/generated/code --title-id 0004000000055E00
```

做什么（RECOMP.md §3.2）：

1. 检查 macOS / `xcrun` / `cargo` / `git` / `ar` / `nm`，定位 iOS SDK 与 clang；
2. checkout 固定 rev 的 3dsrecomp 并 `cargo build --release` 出 CLI；
3. 用
   `CC="$(xcrun --sdk iphoneos -f clang) -target arm64-apple-ios16.0 -isysroot $SDK"`、
   `AR=ar` 跑 `3dsrecomp port <rom> build/game/<name> --name <name>`；
4. 校验 `build/game/<name>/code/librecomp.a`：`xcrun lipo -info` 必须含 **arm64**，
   `nm -g` 必须有 7 个 `recomp_*` 表符号（符号表只 dump 一次到临时文件再精确匹配
   整行最后一段；不再 `nm | grep -q`，避免 pipefail 下的 SIGPIPE 假缺失，也不再让
   `_recomp_abi_extra` 冒充 `_recomp_abi`）；
5. 从 `build/game/<name>/src/main.rs` 提取 16 位十六进制 title ID；所有来源
   （`--title-id` / `recomp-info.txt` / `src/main.rs` / `build-info.txt`）都经过
   `aot_normalize_title_id` 规范化（大写、去 `0x`、修复历史脏值 `...5E00n`）并校验，
   解析不到/非法就报错，绝不把 `unknown`/带尾巴的值写进任何文件；
6. 写 `build/game/<name>/recomp-info.txt`（含 title ID 来源与 archive SHA256）并打印摘要。

采用模式（`--reuse` / `--archive` / `--code-dir`）跳过 3dsrecomp 生成：只校验已有
产物、必要时按 §5 增量编译、刷新 `recomp-info.txt`；不需要 ROM，也不会碰
`third_party/3dsrecomp`。

| 参数 | 说明 |
|---|---|
| `--name NAME` | 游戏短名（默认从 ROM 文件名派生，如 `Pokemon Y.cci` → `pokemon-y`） |
| `--title-id ID` | 手动指定 title ID；优先级最高，接受小写/`0x` 前缀，规范化后写入所有元数据（默认从 `recomp-info.txt`/`src/main.rs` 提取） |
| `--recomp-rev REV` | 覆盖 3dsrecomp rev（默认按 RECOMP.md §5 从 Cargo.lock 读取；env `THREEDS_RECOMP_REV`） |
| `--recomp-dir DIR` | 3dsrecomp checkout（默认 `third_party/3dsrecomp`；env `THREEDS_RECOMP_DIR`） |
| `--recomp-bin PATH` | 复用已构建的 3dsrecomp 二进制（跳过 clone/build；env `THREEDS_RECOMP_BIN`） |
| `--auto-serial` | `port` 失败时自动改为顺序编译生成的 C（8 GB VM 推荐） |
| `--serial-compile` | 不跑 `port`，只把 `build/game/<name>/code/*.c` 顺序重编成归档（增量：跳过比 `.c` 新的 `.o`） |
| `--keep-existing` | 不先删除旧的 `build/game/<name>/` |
| `--reuse` | 不生成任何东西：校验已有 `build/game/<name>/code/librecomp.a`、刷新 `recomp-info.txt`；不需要 ROM |
| `--archive PATH` | 采用别处构建好的 arm64 `librecomp.a`（拷进 `build/game/<name>/code/`、校验、写 `recomp-info.txt`）；不需要 ROM/3dsrecomp |
| `--code-dir DIR` | 采用别处（如 Linux）生成的 C/H，在 VM 上顺序编译（隐含 `--serial-compile`，默认增量） |
| `--force` | 配合 `--serial-compile`/`--code-dir`：重拷并重编所有 `.c`，忽略 `.o` 缓存 |
| `--verbose` | 同时把 3dsrecomp/cargo 输出打到终端 |

`--archive` 与 `--code-dir`/`--serial-compile` 互斥（组合会直接报错）。

产物（gitignored）：`build/game/<name>/code/{*.c,*.o,librecomp.a,recomp.h}`、
`build/game/<name>/{Cargo.toml,build.rs,src/main.rs}`（桌面工程，iOS 只用它取
title ID）、`build/game/<name>/recomp-info.txt`（`title_id`、`title_id_source`、
`compile_mode`、`recomp_rev`、`archive_sha256`，采用模式还有 `adopted_from`）、
`build/logs/build-recomp-ios-*.log`。

## 3. `scripts/build-linked-ios-lib.sh`（linked libs）

```bash
scripts/build-linked-ios-lib.sh <name> [options]
scripts/build-linked-ios-lib.sh pokemon-y
scripts/build-linked-ios-lib.sh 0004000000055E00 pokemon-y   # 显式 title ID

# 分机构建 / 重出包：库已经在 build/ios/<name>/，不跑 cargo
scripts/build-linked-ios-lib.sh pokemon-y --reuse
scripts/build-linked-ios-lib.sh pokemon-y --libgame /path/to/librecomp.a
```

做什么（RECOMP.md §3.3）：

1. 解析 title ID（显式参数 → `build-info.txt`（`--reuse` 时优先，因为那是 linked
   库实际编译进去的 title）→ `build/game/<name>/recomp-info.txt` → `src/main.rs`）；
   所有来源都经 `aot_normalize_title_id` 规范化/修复（历史 `...5E00n` 会修好并告警），
   写 `build-info.txt` 前再校验一次，非法就拒绝写；
2. 确保 `third_party/zakuro` 存在且 workspace 里有 `crates/zakuro-ios`
   （缺了就自动跑一次 `scripts/build-zakuro-ios.sh` 做初始化）；
3. 把 `ios/zakuro-ios` 重新复制到 `third_party/zakuro/crates/zakuro-ios`；
4. `ZAKURO_LINKED_PROGRAM_ID=<title> cargo build -p zakuro-ios --release
   --features linked --target aarch64-apple-ios`；
5. 校验 linked 库：arm64，且 `nm -u` 里**恰好 7 个**未定义 `_recomp_*`
   （`_recomp_abi/_generation/_entries/_entry_count/_modules/_module_count/_origins`，
   由 App 链接时用 `libgame.a` 解析；RECOMP.md §8.2）。符号检查复用
   `scripts/lib/aot-common.sh`：nm 输出只 dump 一次、按整行最后一段精确匹配，
   不会因 pipefail/SIGPIPE 把存在的符号误判成缺失，`_recomp_abi_extra` 也不能
   冒充 `_recomp_abi`；
6. 收集 `build/ios/<name>/libzakuro_ios.a` + `libgame.a`，写 `build-info.txt`。

| 参数 | 说明 |
|---|---|
| `--title-id ID` | 16 位十六进制 title ID（小写/`0x` 前缀会被规范化） |
| `--name NAME` | 同 `<name>` 位置参数 |
| `--reuse` | 不跑 cargo：复用并校验已有 `build/ios/<name>/libzakuro_ios.a`，刷新 `build-info.txt` |
| `--libgame PATH` | 用别处构建好的 arm64 archive 作 `libgame.a`（不要求 `build/game/<name>/` 存在） |
| `--zakuro-dir DIR` | Zakuro checkout（默认 `third_party/zakuro`；env `ZAKURO_DIR`） |
| `--lib-dir DIR` | 输出目录（默认 `build/ios/<name>`） |
| `--isolated-target` | 用 `build/cargo-target/<name>` 作 `CARGO_TARGET_DIR`（多游戏连续构建更稳，但要全量重编依赖；默认共享 target + `cargo clean -p zakuro-ios`，只重编本 crate） |
| `--verbose` | cargo 输出同时打到终端 |

`--reuse` 分支只做校验 + 复制 + 写元数据（不需要 cargo/Zakuro checkout/ROM）。
如果 `build/game/<name>/code/librecomp.a` 缺失但 `build/ios/<name>/libgame.a` 已存在，
reuse 会复用它并告警（分机构建时手工拷进 `build/ios/<name>/` 的情况）。

产物（gitignored）：`build/ios/<name>/{libzakuro_ios.a,libgame.a,build-info.txt}`、
`build/logs/build-linked-ios-lib-*.log`。**`libzakuro_ios.a` 必须显示 7 个未定义
`_recomp_*`**；如果显示 0 个，说明拿到的是纯解释器壳库，脚本会直接报错。

## 4. `scripts/build-game-ipa.sh`（AOT IPA）

```bash
scripts/build-game-ipa.sh <name> [options]
scripts/build-game-ipa.sh pokemon-y --display-name "Pokemon Y"
```

做什么（RECOMP.md §3.4）：

1. 预检 `build/ios/<name>/libzakuro_ios.a`（linked）与 `libgame.a`（AOT 表）；
2. `cd ios/app && xcodegen generate`（**不改 ios/app**：用 `project.yml` 原样生成）；
3. 用命令行覆盖 `OTHER_LDFLAGS`，顺序固定：

   ```
   OTHER_LDFLAGS=-L<repo>/build/ios/<name> -lzakuro_ios -lgame
   ```

   `-lzakuro_ios` 先产生 `_recomp_*` 未定义引用，`-lgame` 再解析它们；顺序反过来
   或漏掉 `-lgame` 会在链接期报 undefined symbols（这是有意的保护）。
4. `xcodebuild -project 3ds2apple.xcodeproj -target 3ds2apple -sdk iphoneos
   -configuration Release SYMROOT=ios/app/build OBJROOT=ios/app/build
   CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`；
5. 校验最终 App 二进制里 `_recomp_abi` 存在、没有未定义 `_recomp_*`
   （防止"名为 AOT 实际是解释器壳"）；校验 bundle id 覆盖生效；
6. 调 `scripts/package-ipa.sh` 打包成 `IPA/<name>-AOT.ipa`（unsigned），打印
   SHA256，并写 `build/ios/<name>/manifest.txt`；
7. **manifest title ID 自检**：title ID 按 `--title-id` → `build-info.txt` →
   `recomp-info.txt` → `src/main.rs` 解析并规范化，写完后立刻回读 `manifest.txt`，
   要求 `title_id=` 与解析值逐字符相同且恰好 16 位大写十六进制——历史上的
   `0004000000055E00n` 这类尾巴不可能再进入 manifest；失败会直接报错而不是出包。

> **只重出 IPA（split/incremental）**：如果 `build/ios/<name>/{libzakuro_ios.a,libgame.a}`
> 已经在（例如 C 在 Linux 生成、静态库在别处构建后拷进来），本脚本是唯一需要的
> 命令：只需要 Xcode，不需要 cargo/3dsrecomp/ROM（真机运行时仍要同一份 ROM）。

| 参数 | 默认 | 说明 |
|---|---|---|
| `--title-id ID` | 自动解析 | 显式 16 位十六进制 title ID（小写/`0x` 前缀可）；用于 manifest 和 `zk_linked_program_id` 对照，与 linked 库不一致时告警 |
| `--bundle-id ID` | `com.kratos.3ds2apple.<name>` | **每款游戏独立 bundle id**，可与解释器壳 App 共存（RECOMP.md §9） |
| `--display-name T` | `<name>` | 主屏显示名（如 `--display-name "Pokemon Y"`） |
| `--lib-dir DIR` | `build/ios/<name>` | per-game 静态库目录 |
| `--app-dir DIR` | `ios/app` | XcodeGen 工程目录 |
| `--configuration C` | `Release` | xcodebuild 配置 |
| `--out-dir DIR` | `IPA` | IPA 输出目录（gitignored） |
| `--ipa-name NAME` | `<name>-AOT` | IPA 文件名（不含 `.ipa`） |
| `--clean-project` | 关 | 构建后删除生成的 `3ds2apple.xcodeproj`（默认保留；该目录已 gitignore） |
| `--verbose` | 关 | 实时输出 xcodebuild 日志 |

产物（gitignored）：`IPA/<name>-AOT.ipa`（unsigned）、
`build/ios/<name>/manifest.txt`、`build/logs/build-game-ipa-*.log`、
`ios/app/build/…`、`ios/app/3ds2apple.xcodeproj/`。

## 5. 分机构建、增量复用与 8 GB VM 顺序编译回退

首次真机 run（2026-11-12）实际采用的是 **split build**：3dsrecomp 在 Linux 上
生成 C，`libgame.a`/linked 库在 macOS VM 上分步构建，最后单独重出 IPA。三个脚本
都支持这条路径：任何一步只依赖 `build/` 下已有的文件，可以单独重跑。

### 5.1 分机构建：C 在 Linux 生成，VM 上编译/链接

Linux 侧用 3dsrecomp 生成 `code/*.c`、`code/recomp.h` 与 `src/main.rs`（iOS 只用
`src/main.rs` 取 title ID；Linux host 编译出来的 `.o`/`.a` 不要用）。把这两个目录
按原布局拷到 VM：

```bash
# macOS VM
mkdir -p /tmp/pokemon-y-out
# /tmp/pokemon-y-out/code/   <- Linux 生成的 *.c *.h
# /tmp/pokemon-y-out/src/main.rs
scripts/build-recomp-ios.sh pokemon-y --code-dir /tmp/pokemon-y-out/code \
  --title-id 0004000000055E00
scripts/build-linked-ios-lib.sh pokemon-y
scripts/build-game-ipa.sh pokemon-y --display-name "Pokemon Y"
```

- `--code-dir` 隐含 `--serial-compile`，用 RECOMP.md §3.2 的同一组参数逐个编译
  （`-target arm64-apple-ios16.0 -O2 -ffp-contract=off -fno-math-errno -w -fPIC
  -fvisibility=hidden -I.`），最后按当前 `.c` 列表逐个 `ar rcs`；失败时打印日志尾部。
- 只拷贝缺失或比目标新的 C/H，未变化的文件保留 `.o` 缓存；重跑同一条命令会跳过
  所有比 `.c` 新的 `.o`（`recomp-info.txt` 里 `compile_mode=serial-incremental`）。
- `--force` 重拷 + 重编全部 `.c`（改了编译参数或怀疑对象缓存时用）。
- 也可以直接采用别处编译好的 archive：`--archive /path/librecomp.a --title-id <id>`；
  若 linked 库和 `libgame.a` 都已手工放进 `build/ios/<name>/`，则直接
  `scripts/build-linked-ios-lib.sh <name> --reuse` + `scripts/build-game-ipa.sh <name>`，
  完全不需要 cargo/ROM。
- title ID 的规范化/校验（含历史 `...5E00n` 修复）对 `--title-id`、`recomp-info.txt`、
  `src/main.rs`、`build-info.txt` 一视同仁；manifest 写完还会回读自检。

### 5.2 增量复用速查

| 已有状态 | 只需跑 | 不会执行 |
|---|---|---|
| `build/game/<name>/code/librecomp.a` | `build-recomp-ios.sh <name> --reuse` | ROM/3dsrecomp/cargo |
| 别处的 arm64 `librecomp.a` | `build-recomp-ios.sh <name> --archive <a>` | ROM/3dsrecomp |
| Linux 生成的 C | `build-recomp-ios.sh <name> --code-dir <dir>` | ROM/3dsrecomp（但会跑 clang，增量） |
| `build/ios/<name>/{libzakuro_ios.a,libgame.a}` | `build-game-ipa.sh <name>` | cargo/ROM/3dsrecomp |
| 两个库已手工放好、想刷新 build-info | `build-linked-ios-lib.sh <name> --reuse` | cargo/Zakuro checkout |

`build-game-ipa.sh` 每次都重新生成工程并 `xcodebuild`（增量构建由 Xcode 负责），
manifest 覆盖写；重复出包只需要这一个命令。

### 5.3 8 GB macOS VM 的顺序编译回退

3dsrecomp 只在 Linux/Windows 上估算空闲内存；macOS 上它按 CPU 核数并行起 `clang
-O2` 且不设内存上限（RECOMP.md §3.2）。大游戏单个 `codeNNN.c` 可达数 MB，8 GB VM
可能被 OOM killer 杀掉编译进程。回退方式（脚本已封装，即 §5.1 的同一套顺序编译）：

```bash
# 推荐：port 失败时自动改为顺序编译已生成的 C
scripts/build-recomp-ios.sh "ROM/Pokemon Y.cci" pokemon-y --auto-serial

# 或者：C 已经生成（code/*.c 存在），只差编译归档
scripts/build-recomp-ios.sh "ROM/Pokemon Y.cci" pokemon-y --serial-compile
```

顺序编译用的就是 RECOMP.md §3.2 的关键参数（`-O2 -ffp-contract=off
-fno-math-errno -w -fPIC -fvisibility=hidden -I.`，最后 `ar rcs`），只是逐个文件串行
执行；大游戏以小时计。Rust 侧如果也吃紧，可以限制 cargo 并行：

```bash
CARGO_BUILD_JOBS=2 scripts/build-linked-ios-lib.sh pokemon-y
```

## 6. 真机验证（Pokémon Y）

1. 从 VM 取回 `IPA/<name>-AOT.ipa`（scp/共享目录），Windows 用 Sideloadly/AltStore
   以**你自己的** Apple ID 签名安装；
2. 用 iTunes/Finder 或 Files 把**同一份 ROM** 放进 App 的 `Documents/`（IPA 已带
   `UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace`）；App 里选择 ROM →
   `zk_create`；
3. `idevicesyslog` 里确认（RECOMP.md §4 的表）：

   ```
   running the recompiled code linked in, N entry points, M modules
   [3ds2apple] ... zk_linked_code()==1 / zk_linked_program_id()==0xTITLE / zk_recompiled()==1
   ```

   `zk_recompiled()==0` 表示 loader 回退了（title/ABI/update），见 §7；**不是崩溃**。
4. 性能由 qa 记录（I3-T4/T5），本文不承诺倍数；纯解释器基线约 20 fps。

## 7. 失败诊断

| 现象 | 原因 / 处理 |
|---|---|
| xcodebuild：`Undefined symbols … _recomp_abi/_recomp_entries/…` | `libgame.a` 没链上或顺序错。`build-game-ipa.sh` 已固定 `-lzakuro_ios -lgame`；手工 xcodebuild 时不要反序/漏掉。 |
| `has no undefined _recomp_* symbols … interpreter-only shell library` | 用的是默认壳库，不是 linked 变体。重跑 `scripts/build-linked-ios-lib.sh <name>`；确认 build 带 `--features linked`。 |
| `build.rs` panic：`the 'linked' feature needs ZAKURO_LINKED_PROGRAM_ID` | 缺 env 或不是 16 位十六进制。脚本会自动注入；手工 cargo 时补上。 |
| `could not determine a valid 16 hex digit title ID` | 没有可用来源或值非法（15/17/18 位、含非 hex 字符）。重跑 recomp，或用 `--title-id` 传 16 位 hex（小写/`0x` 可）。 |
| `warning: repaired corrupted title ID '...n' -> '...'`（不是失败） | 旧 `build-info.txt`/`recomp-info.txt` 里的历史脏值（首次 VM run 的 `0004000000055E00n`）被自动修复，脚本随后写入规范值。正常；想确认可看写出的 `title_id=` 是否恰好 16 位。 |
| `manifest title_id round-trip failed` | 不应出现；说明 manifest 写出路径回归（写出的值与解析值不一致）。保留日志/`manifest.txt` 并报告 bug，不要出包。 |
| `--reuse needs an existing archive: …` | 该路径还没有 `librecomp.a`。先正常跑一次 recomp，或用 `--archive <path>` 采用现成 archive（§5.1）。 |
| `--archive and --code-dir cannot be combined` / `--archive cannot be combined with --serial-compile` | 采用模式只能选一种；把选项拆成两次命令或去掉其中一个。 |
| `missing recompiled archive … (split-build)` / `libzakuro_ios.a`/`libgame.a` 找不到 | 分机构建时把 `librecomp.a` 放到 `build/game/<name>/code/`，或把 `libzakuro_ios.a` + `libgame.a` 放进 `build/ios/<name>/`，然后用 `--reuse`/`--libgame`（§5.2）。 |
| 运行日志：`the code linked in is for title X, not Y`（`zk_recompiled()==0`） | ROM 版本/区域与重编译的不一致（title ID 不同）。对**实际 ROM** 重跑上面三步（RECOMP.md §6）。 |
| 运行日志：`could not use the code linked in, it was built for version V … this is 5` | 接口 ABI 不匹配：Zakuro 与 3dsrecomp rev 混用了。按 §5 重新冻结 rev、重编 C、重出包，不要只换一边。 |
| 运行日志：`K functions changed since the game was recompiled …` | 设备上加载了 update/mod；基础 ROM 之外的 update 暂不支持（RECOMP.md §6），其余 AOT、少数函数走解释器。 |
| `clang: error: invalid target` / `SDK not found` | 检查 `xcrun --sdk iphoneos --show-sdk-path`；Xcode 选错用 `sudo xcode-select -s "$HOME/Applications/Xcode-16.4.0.app"`；确认 iOS 组件已装。 |
| `xcrun: error: unable to find utility "clang"` | Xcode 未接受许可/未装 iOS platform：`xcodebuild -runFirstLaunch`。 |
| 编译进程被 OOM kill / 卡住 | 用 §5 的 `--auto-serial`/`--serial-compile`。 |
| `ld: library not found for -lzakuro_ios` / `-lgame` | 先跑 `build-linked-ios-lib.sh`；确认 `build/ios/<name>/` 里两个 `.a` 都在。 |
| title ID 检查/修复相关告警 | 见 `scripts/lib/aot-common.sh` 顶部注释；`bash scripts/tests/aot-selfcheck.sh` 可在 Linux 上验证规范化与 nm 匹配逻辑（§11）。 |
| IPA 安装失败/闪退 | 构建产物是 **unsigned**，必须用 Sideloadly/AltStore 签名；免费 Apple ID 7 天过期。 |
| 装好后 App 里没有 ROM | 本流程不把 ROM 打进 IPA；用文件共享把 ROM 放进 App Documents（§6）。 |

## 8. 产物与仓库卫生

所有中间产物都在 gitignored 目录，**不要提交**：

```
build/game/<name>/           3dsrecomp 生成的 C/对象/librecomp.a、桌面工程、recomp-info.txt
build/ios/<name>/            libzakuro_ios.a、libgame.a、build-info.txt、manifest.txt
build/logs/                  各步骤完整日志
build/cargo-target/          --isolated-target 时的 Rust target（可选）
third_party/3dsrecomp/       固定 rev 的 3dsrecomp checkout
third_party/zakuro/          Zakuro checkout（含 crates/zakuro-ios 副本）
ios/app/build/               xcodebuild 产物
ios/app/3ds2apple.xcodeproj/ XcodeGen 生成物（已 gitignore）
IPA/<name>-AOT.ipa           unsigned IPA（IPA/ 已 gitignore）
```

`manifest.txt` 记录：`name/title_id/title_id_source/bundle_id/display_name/configuration`、
`recomp_rev`、`zakuro_rev`、`libzakuro_ios_sha256`、`libgame_sha256`、
`ipa_sha256`、`ipa_bytes`、`xcode`、`created_utc`。`title_id` 必须是 16 位大写
十六进制（脚本写后自检，不允许 `unknown`/带尾巴）；出包/分发时用 `ipa_sha256`
做校验，用两个 rev 复现构建。

## 9. 已知边界（不是本脚本能解决的）

- **update/DLC/mod 暂不支持**：iOS FFI 只跑基础 ROM，3dsrecomp CLI 拒绝 update CIA
  （RECOMP.md §6）；update 改过的函数会安全回退解释器。
- **PRODUCT_NAME 固定 `3ds2apple`**：每款 IPA 通过 `--bundle-id`/`--display-name`
  区分（可并存安装）；彻底 per-game 的 `project.yml` 参数化留到 I4-T4。
- **首轮编译很慢**：大游戏并行编译以小时计、顺序回退更久；目前只做了对象级
  增量（`.o` 比 `.c` 新则跳过），还没有按生成内容哈希的缓存。
- **性能结论待真机**：AOT 后瓶颈可能在 GPU（shader JIT 已关），由 I3-T4/T5 测。

## 10. 验收清单（VM 上一遍过）

- [ ] Linux 先跑 `scripts/tests/aot-selfcheck.sh` 与
      `scripts/tests/aot-sim-harness.sh` 全绿（§11）
- [ ] `build-recomp-ios.sh` 打印 title ID（恰好 16 位大写 hex），`librecomp.a` 为
      arm64 且含 7 个 `recomp_*`；`recomp-info.txt` 的 `title_id=` 无尾巴
- [ ] `build-linked-ios-lib.sh` 打印恰好 7 个未定义 `_recomp_*`；`build-info.txt`
      的 `title_id=` 无尾巴
- [ ] `build-game-ipa.sh` 打印 IPA 绝对路径 + SHA256，`manifest.txt` 已写且
      `title_id=` 恰好 16 位 hex（脚本自检通过）
- [ ] 分机构建路径：`--code-dir`/`--archive`/`--reuse` 三条命令按 §5.1/§5.2 各跑
      一遍，重跑不重复生成/编译（`compile_mode=serial-incremental`/`reuse`）
- [ ] 真机日志：`zk_linked_code()==1`、`zk_linked_program_id()==0x<ROM title>`、
      `zk_recompiled()==1`
- [ ] `git status` 干净；仓库里没有 ROM/生成 C/`.a`/IPA/日志

## 11. Linux 上的检查（无需 Xcode；VM 前先在本机跑）

两个测试脚本都不需要 macOS/Xcode/ROM，也不接触真实仓库的 `build/`：

```bash
# 语法 + aot-common 单元自检 + 静态回归 + 仓库卫生
scripts/tests/aot-selfcheck.sh

# 用 fake Darwin 工具链把三个真实脚本跑一遍（分机构建/增量复用/manifest）
scripts/tests/aot-sim-harness.sh
```

`aot-selfcheck.sh` 覆盖：

- 所有脚本 `bash -n`；
- `aot_normalize_title_id`/`aot_validate_title_id`（含历史 `0004000000055E00n`、
  字面 `\n`、`0x`、小写、15/17/18 位拒绝）；
- `aot_info_value`（CRLF）、`aot_title_id_from_rust`、title ID 解析优先级；
- nm 辅助函数：无前导空白行、`_recomp_abi_extra` 前缀诱饵不得冒充、整行精确匹配；
- 静态回归：三个脚本都 source `scripts/lib/aot-common.sh`、不出现 `nm | grep -q`
  管线、只写经过校验的 title ID、manifest round-trip 自检仍在；
- `--help` 冒烟；`build/`、`ROM/`、`IPA/`、`.a`/`.o`/`.log` 均被 gitignore 且没有
  被 git 跟踪。

`aot-sim-harness.sh` 在临时目录里复刻仓库 + fake `uname/xcrun/lipo/nm/clang/cargo/
xcodegen/xcodebuild`，端到端验证：`--archive`/`--code-dir`/`--reuse` 采用、损坏
title ID 修复、7 个 `_recomp_*` 校验（含反例）、`build-info.txt` 修复、manifest
无尾巴、序列编译的 `-target/-O2` 参数、第二次运行复用 `.o`、`--force` 重编、IPA
打包、非法输入报错。`AOT_SIM_KEEP=1` 可保留临时目录排查。

> 这两个脚本只证明脚本逻辑（title ID/nm/增量/元数据）正确；**iOS SDK 链接与真机
> 行为仍必须在 macOS VM 上按 §10 验证**。