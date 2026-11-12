# 构建与打包脚本

本目录放 3ds2apple 的构建/打包脚本：

- **ROM-free 通用壳**（I1/I2）：`build-ios-app.sh`、`package-ipa.sh`；
- **每游戏 AOT 流水线**（I3，3dsrecomp）：`build-recomp-ios.sh`、
  `build-linked-ios-lib.sh`、`build-game-ipa.sh`，完整说明见
  [AOT_BUILD.md](AOT_BUILD.md)；三者共享的 title ID/nm/元数据逻辑在
  `lib/aot-common.sh`；
- **测试**（Linux 可跑）：`tests/aot-selfcheck.sh`（语法 + 单元自检 + 静态回归 +
  仓库卫生）、`tests/aot-sim-harness.sh`（fake Darwin 工具链端到端模拟分机构建）。

两类脚本都不会把 ROM、密钥、生成的 C、静态库或 IPA 提交进仓库：AOT 脚本只在构建机
上读取 `ROM/` 中**用户自有**的 ROM，所有中间产物都落在 gitignored 的 `build/`、
`third_party/`、`IPA/`。

| 脚本 | 作用 | 运行环境 |
|---|---|---|
| `build-zakuro-ios.sh` | 构建 Zakuro iOS 静态库 → `build/ios/libzakuro_ios.a` | **macOS**（Xcode + Rust） |
| `build-ios-app.sh` | XcodeGen 生成工程 + `xcodebuild` → unsigned `.app` | **macOS**（Xcode + XcodeGen） |
| `package-ipa.sh` | `.app` → `Payload/` → unsigned `.ipa` + SHA256 | macOS 或 Linux（`zip` + `shasum`/`sha256sum`） |
| `build-recomp-ios.sh` | 3dsrecomp `port` → `build/game/<name>/code/librecomp.a`；也支持采用已有 C/archive（`--reuse`/`--archive`/`--code-dir`，不需要 ROM/Rust） | **macOS**（Xcode；完整 `port` 路径另需 Rust） |
| `build-linked-ios-lib.sh` | linked `libzakuro_ios.a` + `libgame.a` → `build/ios/<name>/`；`--reuse`/`--libgame` 用于分机构建 | **macOS**（Xcode + Rust；`--reuse` 不需要 cargo） |
| `build-game-ipa.sh` | 链接两个静态库 → `IPA/<name>-AOT.ipa` + manifest（可单独重出包） | **macOS**（Xcode + XcodeGen） |
| `lib/aot-common.sh` | 共享函数：title ID 规范化/校验、build-info 解析、nm 符号匹配（SIGPIPE/前缀安全） | 任何 POSIX bash |
| `tests/aot-selfcheck.sh` | `bash -n` + 单元自检 + 静态回归 + 仓库卫生 | Linux/macOS |
| `tests/aot-sim-harness.sh` | fake Darwin 工具链端到端模拟（分机构建/增量/manifest） | Linux/macOS（不碰真实 `build/`） |

> **macOS-only：** iOS App/静态库必须用 Apple iOS SDK 构建；`build-ios-app.sh`、
> `build-recomp-ios.sh`、`build-linked-ios-lib.sh`、`build-game-ipa.sh` 在非 Darwin
> 系统上会直接报错退出。Linux/Windows 只负责写脚本、文档、跑 `tests/` 里的检查
> 和（可选的）IPA 打包；不要在 Linux 上尝试 iOS 链接。

## 前置条件

1. macOS 构建机（macOS VM 或 Mac）已装好 Xcode（M0 验证组合：Xcode 16.4 / iOS 18.5 SDK）。
2. [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`。
3. iOS 静态库：先跑 `scripts/build-zakuro-ios.sh` 生成
   `build/ios/libzakuro_ios.a`（约 52 MB，`build/` 已 gitignore，不进仓库）。
4. `zip`、`shasum`（macOS 自带）。

## 1. `scripts/build-ios-app.sh`

```bash
scripts/build-ios-app.sh                       # 默认 Release、ios/app、build/ios/libzakuro_ios.a
scripts/build-ios-app.sh --configuration Debug
scripts/build-ios-app.sh --app-dir ios/app --staticlib build/ios/libzakuro_ios.a
scripts/build-ios-app.sh --clean --verbose     # 先 clean，并实时输出 xcodebuild 日志
scripts/build-ios-app.sh --help
```

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--app-dir DIR` | `ios/app` | 含 `project.yml` 的 XcodeGen 工程目录 |
| `--staticlib PATH` | `build/ios/libzakuro_ios.a` | Zakuro 静态库（相对路径按仓库根解析） |
| `--configuration CFG` | `Release` | `xcodebuild -configuration` |
| `--project NAME` | `3ds2apple.xcodeproj` | 生成的 Xcode 工程 |
| `--target NAME` | `3ds2apple` | Xcode target |
| `--clean` | 关 | 先执行 `xcodebuild clean` 再 build |
| `--verbose` | 关 | 构建输出同时打印到终端 |
| `--keep-project` | 关 | 保留生成的 `.xcodeproj`（默认在未 gitignore 时构建后删除，保持 `git status` 干净） |

脚本流程：

1. 检查 macOS / `xcodebuild` / `xcodegen`；**提前检查静态库存在且非空**（否则
   只会在链接阶段看到 `ld: library not found for -lzakuro_ios`）。
2. `cd ios/app && xcodegen generate --spec project.yml`。
3. `xcodebuild -project 3ds2apple.xcodeproj -target 3ds2apple -sdk iphoneos
   -configuration Release SYMROOT="$PWD/build" OBJROOT="$PWD/build"
   CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`。
4. 校验 `.app` 存在，检查 `zk_screen_width` 符号已链接（非致命告警），打印 `.app`
   绝对路径。

产物：

- `ios/app/build/Release-iphoneos/3ds2apple.app`（unsigned；被 `.gitignore` 的
  `build/` 覆盖）
- `ios/app/build/logs/build-ios-app-<timestamp>.log`（完整构建日志；失败时脚本会
  把最后 80 行打到 stderr 并以非零退出）
- `ios/app/3ds2apple.xcodeproj`（XcodeGen 生成物，**不是**源码；默认构建后删除，
  除非 Lead 已把它加进 `.gitignore` 或传了 `--keep-project`）

脚本可重复运行：XcodeGen 每次重新生成工程，`xcodebuild` 增量构建；`--clean` 可强制全量。

## 2. `scripts/package-ipa.sh`

```bash
# 从默认命名打包（3ds2apple.app -> IPA/3ds2apple.ipa）
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app

# 指定名字
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple-I1

# 指定输出目录
scripts/package-ipa.sh <path/to/App.app> --name 3ds2apple-I1 --out-dir IPA
```

脚本会：

1. 校验输入是合法 `.app`（目录且含 `Info.plist`）。
2. 在临时目录建 `Payload/<App>.app`，`zip -qry` 成 `<name>.ipa`。
3. 移动到 `IPA/<name>.ipa`（`IPA/` 已 gitignore），打印 **绝对路径、SHA256、大小**。

安全约束：脚本从不执行 `git add`；若目标路径已被 git 跟踪会直接拒绝写入；输出路径
未 gitignore 时给出告警。产物一律不进仓库。

## 3. 端到端（macOS VM，仓库根目录）

```bash
# 1) 静态库（首次或 Zakuro/FFI 变更后）
scripts/build-zakuro-ios.sh                 # -> build/ios/libzakuro_ios.a

# 2) 构建 unsigned App（无 ROM）
scripts/build-ios-app.sh                    # -> ios/app/build/Release-iphoneos/3ds2apple.app

# 3) 打包 unsigned IPA
scripts/package-ipa.sh \
  ios/app/build/Release-iphoneos/3ds2apple.app \
  3ds2apple-I1                              # -> IPA/3ds2apple-I1.ipa (+ SHA256)
```

把 IPA 拷到 Windows，用 Sideloadly / AltStore 以**你自己的** Apple ID 签名安装；
Apple ID、证书、设备 UDID 不进仓库、不写日志、不在 Agent 之间传递。

### 3.1 每游戏 AOT（I3-T3，需要用户自有 ROM）

```bash
scripts/build-zakuro-ios.sh                                    # 一次性：Zakuro checkout
scripts/build-recomp-ios.sh "ROM/<your-game>.3ds" <name>       # 3dsrecomp -> librecomp.a
scripts/build-linked-ios-lib.sh <name>                         # linked 库 + libgame.a
scripts/build-game-ipa.sh <name> --display-name "<Game Name>"  # -> IPA/<name>-AOT.ipa
```

8 GB VM 首轮编译若被 OOM kill：给 `build-recomp-ios.sh` 加 `--auto-serial` 顺序回退
（RECOMP.md §3.2）。

**分机构建 / 增量复用**（C 在 Linux 生成，VM 只编译/链接/出包；不需要重跑前一步）：

```bash
# 采用别处生成的 C（--code-dir 隐含序列编译，重跑只编变化的 .c；--force 全量）
scripts/build-recomp-ios.sh <name> --code-dir /path/to/code --title-id 0004000000055E00
# 或采用别处编译好的 arm64 archive（不需要 ROM）
scripts/build-recomp-ios.sh <name> --archive /path/to/librecomp.a --title-id 0004000000055E00
# 已有 build/ios/<name>/ 两个库时，只重出包（不需要 cargo/ROM）
scripts/build-game-ipa.sh <name> --display-name "<Game Name>"
# 两个库已手工放好、想刷新 build-info（不需要 cargo）
scripts/build-linked-ios-lib.sh <name> --reuse
```

> `manifest.txt` / `build-info.txt` / `recomp-info.txt` 里的 `title_id=` 一律是 16 位
> 大写十六进制：所有来源先经 `lib/aot-common.sh` 规范化（修复历史 `...5E00n` 尾巴）
> 并校验，manifest 写完还会 round-trip 自检。看到
> `warning: repaired corrupted title ID` 是旧值被修好，不是错误。

完整流程、参数表、失败诊断与真机验证见 [AOT_BUILD.md](AOT_BUILD.md)；分机构建与
增量复用见其 §5，Linux 检查见 §11。

## 4. 与 `ios/app/` 的契约

脚本依赖 `ios-shell` 维护的 XcodeGen 工程约定（I1-T1）：

- `ios/app/project.yml`：`name: 3ds2apple`，target `3ds2apple`，iOS 16.0，
  `GENERATE_INFOPLIST_FILE=YES`，`CODE_SIGNING_ALLOWED=NO`。
- 静态库链接：`OTHER_LDFLAGS: ["-L$(SRCROOT)/../../build/ios", "-lzakuro_ios"]`
  （`SRCROOT` = `ios/app`，即仓库根的 `build/ios/libzakuro_ios.a`）。
- 构建输出固定为 `ios/app/build/Release-iphoneos/3ds2apple.app`。

本目录脚本只消费该工程配置，不修改 `ios/app/` 源码。

## 5. 排错

| 现象 | 处理 |
|---|---|
| `this script must run on macOS` | 在 macOS VM/Mac 上跑；Linux 只做语法检查 |
| `xcodebuild not found` | 选好 Xcode 工具链：`sudo xcode-select -s /Applications/Xcode.app`；M0 的 macOS VM 把 Xcode 装在 `~/Applications/Xcode-16.4.0.app`（见 `ios/app/README.md`） |
| `xcodegen not found` | `brew install xcodegen` |
| `static library not found` | 先跑 `scripts/build-zakuro-ios.sh`，或 `--staticlib <path>` |
| 链接报 `library not found for -lzakuro_ios` | 检查 `build/ios/libzakuro_ios.a` 是否存在；`--staticlib` 传对 |
| `zk_screen_width not found` 告警 | 静态库没链上：检查 `project.yml` 的 `OTHER_LDFLAGS` |
| 构建失败 | 看 stderr 的日志尾部 + `ios/app/build/logs/` 下完整日志 |
| `git status` 出现 `3ds2apple.xcodeproj` | 该目录（`ios/app/3ds2apple.xcodeproj/`）已被 `.gitignore` 覆盖；默认保留便于调试，`build-game-ipa.sh --clean-project` 可删 |
| AOT 链路（recomp / linked / IPA）| 见 [AOT_BUILD.md](AOT_BUILD.md) §5（分机构建/增量/8 GB VM 顺序编译）、§7（失败诊断）、§11（Linux 检查） |

## 6. 检查（Linux 上可做）

```bash
# 推荐：一条命令覆盖语法 + 单元自检 + 静态回归 + 仓库卫生
scripts/tests/aot-selfcheck.sh

# 端到端模拟：fake Darwin 工具链跑三个真实脚本（分机构建/增量/manifest）
scripts/tests/aot-sim-harness.sh

# 或者只做语法检查
bash -n scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh
command -v shellcheck >/dev/null && \
  shellcheck scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh
```

> 本仓库当前 Linux 环境未安装 `shellcheck`；两个测试脚本已通过。装了 shellcheck
> 的机器建议再跑一遍。两个测试都不需要 macOS/Xcode/ROM，也不会写真实仓库的
> `build/`（模拟器在 `mktemp` 目录里复刻仓库）。