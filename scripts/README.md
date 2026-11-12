# 构建与打包脚本

本目录放 **ROM-free** 的 3ds2apple 构建/打包脚本。它们只构建通用 iOS 壳（SwiftUI
外壳 + `libzakuro_ios.a`），不读取、不打包任何 ROM、密钥或游戏数据。

| 脚本 | 作用 | 运行环境 |
|---|---|---|
| `build-zakuro-ios.sh` | 构建 Zakuro iOS 静态库 → `build/ios/libzakuro_ios.a` | **macOS**（Xcode + Rust） |
| `build-ios-app.sh` | XcodeGen 生成工程 + `xcodebuild` → unsigned `.app` | **macOS**（Xcode + XcodeGen） |
| `package-ipa.sh` | `.app` → `Payload/` → unsigned `.ipa` + SHA256 | macOS 或 Linux（`zip` + `shasum`/`sha256sum`） |

> **macOS-only：** iOS App 必须用 Apple iOS SDK 构建，`build-ios-app.sh` 在非 Darwin
> 系统上会直接报错退出。Linux/Windows 只负责写脚本、文档和（可选的）IPA 打包；
> 不要在 Linux 上尝试 iOS 链接。

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
| `git status` 出现 `3ds2apple.xcodeproj` | 用 `--keep-project` 之外的默认行为会删除；长期方案是 Lead 在 `.gitignore` 加 `ios/app/3ds2apple.xcodeproj/` |

## 6. 检查（Linux 上可做）

```bash
bash -n scripts/build-ios-app.sh
bash -n scripts/package-ipa.sh
command -v shellcheck >/dev/null && shellcheck scripts/build-ios-app.sh scripts/package-ipa.sh
```

> 本仓库当前 Linux 环境未安装 `shellcheck`；`bash -n` 已通过。装了 shellcheck 的
> 机器建议再跑一遍。