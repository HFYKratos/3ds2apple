# 每游戏 AOT 构建：3dsrecomp → linked IPA

把某一款**用户自有 ROM** 在构建期用 3dsrecomp 翻译成 C、编译成 arm64 iOS 静态库，
与该游戏的 linked 版 `libzakuro_ios.a` 一起静态链接进 `ios/app`，产出
`IPA/<name>-AOT.ipa`。运行时没有 JIT、没有 `dlopen`：`zk_create` 从 App 的
Documents 读取 ROM，Zakuro 直接跑构建期生成的 AOT 代码（title/ABI 不匹配时安全回退
解释器，见 [RECOMP.md](../ios/zakuro-ios/RECOMP.md) §4）。

> 设计以 [`ios/zakuro-ios/RECOMP.md`](../ios/zakuro-ios/RECOMP.md) §3/§5/§9 为准；
> 本文只是把它变成可复制执行的脚本命令。**iOS 构建必须在 macOS（VM）上跑**
> （Xcode 16.4 / iOS 18.5 SDK），Linux 只能做 `bash -n` 语法检查。
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
```

做什么（RECOMP.md §3.2）：

1. 检查 macOS / `xcrun` / `cargo` / `git` / `ar` / `nm`，定位 iOS SDK 与 clang；
2. checkout 固定 rev 的 3dsrecomp 并 `cargo build --release` 出 CLI；
3. 用
   `CC="$(xcrun --sdk iphoneos -f clang) -target arm64-apple-ios16.0 -isysroot $SDK"`、
   `AR=ar` 跑 `3dsrecomp port <rom> build/game/<name> --name <name>`；
4. 校验 `build/game/<name>/code/librecomp.a`：`xcrun lipo -info` 必须含 **arm64**，
   `nm -g` 必须有 7 个 `recomp_*` 表符号；
5. 从 `build/game/<name>/src/main.rs` 提取 16 位十六进制 title ID；
6. 写 `build/game/<name>/recomp-info.txt` 并打印摘要。

| 参数 | 说明 |
|---|---|
| `--name NAME` | 游戏短名（默认从 ROM 文件名派生，如 `Pokemon Y.cci` → `pokemon-y`） |
| `--title-id ID` | 手动指定 title ID（默认从 `src/main.rs` 提取） |
| `--recomp-rev REV` | 覆盖 3dsrecomp rev（默认按 §5 从 Cargo.lock 读取；env `THREEDS_RECOMP_REV`） |
| `--recomp-dir DIR` | 3dsrecomp checkout（默认 `third_party/3dsrecomp`；env `THREEDS_RECOMP_DIR`） |
| `--recomp-bin PATH` | 复用已构建的 3dsrecomp 二进制（跳过 clone/build；env `THREEDS_RECOMP_BIN`） |
| `--auto-serial` | `port` 失败时自动改为顺序编译生成的 C（8 GB VM 推荐） |
| `--serial-compile` | 不跑 `port`，只把 `build/game/<name>/code/*.c` 顺序重编成归档 |
| `--keep-existing` | 不先删除旧的 `build/game/<name>/` |
| `--verbose` | 同时把 3dsrecomp/cargo 输出打到终端 |

产物（gitignored）：`build/game/<name>/code/{*.c,*.o,librecomp.a,recomp.h}`、
`build/game/<name>/{Cargo.toml,build.rs,src/main.rs}`（桌面工程，iOS 只用它取
title ID）、`build/game/<name>/recomp-info.txt`、`build/logs/build-recomp-ios-*.log`。

## 3. `scripts/build-linked-ios-lib.sh`（linked libs）

```bash
scripts/build-linked-ios-lib.sh <name> [options]
scripts/build-linked-ios-lib.sh pokemon-y
scripts/build-linked-ios-lib.sh 0004000000055E00 pokemon-y   # 显式 title ID
```

做什么（RECOMP.md §3.3）：

1. 解析 title ID（显式参数 → `build/game/<name>/recomp-info.txt` →
   `src/main.rs` → 旧 `build-info.txt`）；
2. 确保 `third_party/zakuro` 存在且 workspace 里有 `crates/zakuro-ios`
   （缺了就自动跑一次 `scripts/build-zakuro-ios.sh` 做初始化）；
3. 把 `ios/zakuro-ios` 重新复制到 `third_party/zakuro/crates/zakuro-ios`；
4. `ZAKURO_LINKED_PROGRAM_ID=<title> cargo build -p zakuro-ios --release
   --features linked --target aarch64-apple-ios`；
5. 校验 linked 库：arm64，且 `nm -u` 里**恰好 7 个**未定义 `_recomp_*`
   （`_recomp_abi/_generation/_entries/_entry_count/_modules/_module_count/_origins`，
   由 App 链接时用 `libgame.a` 解析；RECOMP.md §8.2）；
6. 收集 `build/ios/<name>/libzakuro_ios.a` + `libgame.a`，写 `build-info.txt`。

| 参数 | 说明 |
|---|---|
| `--title-id ID` | 16 位十六进制 title ID |
| `--zakuro-dir DIR` | Zakuro checkout（默认 `third_party/zakuro`；env `ZAKURO_DIR`） |
| `--lib-dir DIR` | 输出目录（默认 `build/ios/<name>`） |
| `--isolated-target` | 用 `build/cargo-target/<name>` 作 `CARGO_TARGET_DIR`（多游戏连续构建更稳，但要全量重编依赖；默认共享 target + `cargo clean -p zakuro-ios`，只重编本 crate） |

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
   SHA256，并写 `build/ios/<name>/manifest.txt`。

| 参数 | 默认 | 说明 |
|---|---|---|
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

## 5. 8 GB macOS VM：顺序编译回退

3dsrecomp 只在 Linux/Windows 上估算空闲内存；macOS 上它按 CPU 核数并行起 `clang
-O2` 且不设内存上限（RECOMP.md §3.2）。大游戏单个 `codeNNN.c` 可达数 MB，8 GB VM
可能被 OOM killer 杀掉编译进程。回退方式（脚本已封装）：

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
| `could not determine a valid 16 hex digit title ID` | `build/game/<name>/src/main.rs` 里没有 `0x<16 hex>`；重跑 recomp，或用 `--title-id` 手动指定。 |
| 运行日志：`the code linked in is for title X, not Y`（`zk_recompiled()==0`） | ROM 版本/区域与重编译的不一致（title ID 不同）。对**实际 ROM** 重跑上面三步（RECOMP.md §6）。 |
| 运行日志：`could not use the code linked in, it was built for version V … this is 5` | 接口 ABI 不匹配：Zakuro 与 3dsrecomp rev 混用了。按 §5 重新冻结 rev、重编 C、重出包，不要只换一边。 |
| 运行日志：`K functions changed since the game was recompiled …` | 设备上加载了 update/mod；基础 ROM 之外的 update 暂不支持（RECOMP.md §6），其余 AOT、少数函数走解释器。 |
| `clang: error: invalid target` / `SDK not found` | 检查 `xcrun --sdk iphoneos --show-sdk-path`；Xcode 选错用 `sudo xcode-select -s "$HOME/Applications/Xcode-16.4.0.app"`；确认 iOS 组件已装。 |
| `xcrun: error: unable to find utility "clang"` | Xcode 未接受许可/未装 iOS platform：`xcodebuild -runFirstLaunch`。 |
| 编译进程被 OOM kill / 卡住 | 用 §5 的 `--auto-serial`/`--serial-compile`。 |
| `ld: library not found for -lzakuro_ios` / `-lgame` | 先跑 `build-linked-ios-lib.sh`；确认 `build/ios/<name>/` 里两个 `.a` 都在。 |
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

`manifest.txt` 记录：`name/title_id/bundle_id/display_name/configuration`、
`recomp_rev`、`zakuro_rev`、`libzakuro_ios_sha256`、`libgame_sha256`、
`ipa_sha256`、`ipa_bytes`、`xcode`、`created_utc`。出包/分发时用 `ipa_sha256`
做校验，用两个 rev 复现构建。

## 9. 已知边界（不是本脚本能解决的）

- **update/DLC/mod 暂不支持**：iOS FFI 只跑基础 ROM，3dsrecomp CLI 拒绝 update CIA
  （RECOMP.md §6）；update 改过的函数会安全回退解释器。
- **PRODUCT_NAME 固定 `3ds2apple`**：每款 IPA 通过 `--bundle-id`/`--display-name`
  区分（可并存安装）；彻底 per-game 的 `project.yml` 参数化留到 I4-T4。
- **首轮编译很慢**：大游戏并行编译以小时计、顺序回退更久；后续可做对象级缓存。
- **性能结论待真机**：AOT 后瓶颈可能在 GPU（shader JIT 已关），由 I3-T4/T5 测。

## 10. 验收清单（VM 上一遍过）

- [ ] `bash -n scripts/build-{recomp-ios,linked-ios-lib,game-ipa}.sh` 通过（Linux 可做）
- [ ] `build-recomp-ios.sh` 打印 title ID，`librecomp.a` 为 arm64 且含 7 个 `recomp_*`
- [ ] `build-linked-ios-lib.sh` 打印恰好 7 个未定义 `_recomp_*`
- [ ] `build-game-ipa.sh` 打印 IPA 绝对路径 + SHA256，`manifest.txt` 已写
- [ ] 真机日志：`zk_linked_code()==1`、`zk_linked_program_id()==0x<ROM title>`、
      `zk_recompiled()==1`
- [ ] `git status` 干净；仓库里没有 ROM/生成 C/`.a`/IPA/日志