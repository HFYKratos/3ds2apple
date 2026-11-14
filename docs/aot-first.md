# AOT-first 路线（0.1.5 之后）

> 目标版本：0.1.6 / 1.0 之前的下一个大版本。
> **状态（2026-11-14）**：壳侧 launcher-first 模型已实现（§7，含两段式安装、逐游戏数据
> 校验、文件共享、模拟器夹具）；macOS/Windows 启动器与设备桥在并行任务中开发（§8）。
> 核心变化：**去掉解释器兜底，只运行 AOT 代码；手机端不再导入 ROM。游戏分两部分：
> AOT 包随签名 IPA 安装（iOS 不允许 dlopen Documents 里的未签名 dylib），用户游戏数据
> 由设备桥推送进 `Documents/Games/<TITLEID>/`；壳用 Bundle `GameCatalog.json` 作为
> 游戏列表，并在启动时校验/加载推送的数据。**

## 1. 与当前版本的区别

| | 0.1.5-beta1（当前） | 下一版本（AOT-first） |
|---|---|---|
| 手机端 ROM 导入 | 支持（Files 多选） | **移除**，只保留“已安装游戏” |
| 运行方式 | AOT（有 catalog 时）+ 解释器兜底 | **只允许 AOT**；无 AOT 的 ROM 不能启动 |
| 导入/构建 | 桌面脚本 / `builder/` | 桌面图形 launcher（Linux/Windows/macOS）一条龙 |
| 游戏来源 | 壳 IPA 或单游戏 IPA（游戏打进包） | **AOT 包 + catalog 随签名 IPA 重新安装；游戏数据推送到 `Documents/Games/`**（两段式） |
| 兼容性标注 | AOT/Interpreter 徽标 | AOT / Checking / Data missing / Error（逐游戏数据校验） |

## 2. 桌面端（macOS / Windows，launcher-first）

参考 S2Arm（Apache-2.0）与 NX2Apple（MIT）的 launcher 形态：

1. **导入**：用户选择自己的已解密 ROM（.3ds/.cci），桌面端读取 NCSD/NCCH 头得到
   title ID、product code、游戏名；不支持/读不到头的 ROM 直接拒绝。
2. **预编译**：macOS 原生复用 `build-recomp-ios.sh` 等现有脚本；Windows 第一版把 AOT
   编译交给 macOS 构建机（远程 agent），启动器负责导入/排队/分发。
3. **生成游戏包数据**（每游戏独立目录）：
   ```text
   GamePack-<TITLE_ID>/
     GamePack.dylib          # AOT 代码：编译进 IPA 的 Frameworks/ 并写入 GameCatalog.json
     GameRom.cci             # 用户 ROM：通过设备桥推送到 Documents/Games/<TITLE_ID>/
     GameInfo.json           # 推送数据的清单（titleID/名称/ROM 大小与 SHA-256；pack 字段仅供参考）
     cover.png               # 可选
   ```
4. **两段式安装与推送**：
   a. 启动器把 AOT 包写进 IPA 的 `Frameworks/GamePack-<TITLE_ID>.dylib` 并生成/合并
      `GameCatalog.json`，然后签名/安装这个壳构建（加游戏 = 重建 + 重装；AOT 代码必须随
      IPA 签名，iOS 不允许从 Documents dlopen 未签名 dylib）。
   b. 再用设备桥（S2Arm 风格 `house_arrest` + AFC）只推送 `GameRom.cci` +
      `GameInfo.json` 到已安装 App 的 `Documents/Games/<TITLE_ID>/`（`GameInfo.json`
      最后写）。**推送的数据在 App 重装/升级后保留**，之后再加游戏不需要重推旧数据。
   Windows 用官方 Impactor + `plumesign` 完成签名/安装。
5. **不做的事**：不内置 ROM/keys/游戏数据；不在手机端编译；不下载可执行内容；不把
   ROM/游戏数据打进公开 IPA。

## 3. 壳（手机端，launcher-first）

- 壳**不内置任何游戏数据**，游戏分两部分到达手机：
  1. **AOT 包 + catalog**：桌面启动器构建包含 `Frameworks/GamePack-<TITLE_ID>.dylib`
     和 `GameCatalog.json` 的壳 IPA 并签名安装（加游戏 = 重建 + 重装；iOS 不允许从
     Documents `dlopen` 未签名 dylib）。
  2. **游戏数据**：设备桥把用户自己的 ROM 数据写入 App 的 Documents 目录：

  ```text
  App bundle（已签名）
    Frameworks/GamePack-<TITLEID>.dylib   # 该游戏 AOT 代码
    GameCatalog.json                      # 游戏列表 + packFile / ABI / 注册符号

  Documents/Games/<TITLEID>/
    GameInfo.json     # 启动器清单（schema 1，最后写入）
    GameRom.cci       # 用户已解密的游戏数据
    cover.png         # 可选
  ```

- `GameLibrary` 用 Bundle `GameCatalog.json` 作为游戏列表，再与 Documents 里推送的数据
  join：快速校验（目录名=TITLEID、清单可解析且与目录一致、ROM 存在且大小匹配），然后
  后台校验清单记录的 SHA-256。首页状态：**AOT**（可启动）、**Data missing**（catalog 有
  游戏但数据还没推送，点按说明下一步）、**Checking**、**Error**（数据损坏/缺失/大小或
  哈希不匹配，点按逐条列出原因）。**绝不启动**数据缺失或校验失败的游戏。
- 启动：从签名 Bundle `dlopen` GamePack → 校验 title/ABI/注册钩子 → 注册 AOT 表 →
  `zk_create` 载入 Documents 里已校验的 ROM；GamePack 注册路径与之前完全一致（ABI 1）。
- **移除解释器路径**：`AOTStatus` 只有 linked/active；AOT 不可用或数据校验失败都给出
  明确错误，不回退解释器。
- 存档/即时存档按 titleID（或清单的 `saveNamespace`）命名空间隔离。
- 开启 iOS 文件共享（`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`，
  写在显式 Info.plist 里），用户在“文件”App 能看到同一个 `Documents/Games`；手机端
  仍无导入 UI。
- 从上一版自包含构建升级的安装：其 ROM 还在 Bundle 里，壳继续从 Bundle 启动（legacy
  回退）；启动器重装并推送数据后走新路径。全新安装没有 Bundle catalog，首页显示
  “No games in this build yet”。
- 调试：`-gamesRoot <path>` 扫描夹具数据目录，`-openAOTTitleID <TITLEID>` 自动启动；
  配合 `simctl app container` 注入数据夹具，模拟器无需人工点击即可验证整条路径。

## 4. 需要改的代码/脚本

| 位置 | 改动 | 状态 |
|---|---|---|
| `ios/app/Sources/GameInfo.swift` | 新增：推送数据清单 schema 1（titleID/displayName/saveNamespace/ROM 大小与 SHA-256；pack 字段仅供参考） | ✅ |
| `ios/app/Sources/InstalledGame.swift` | 新增：扫描 `Documents/Games` 推送数据、快速校验、后台 SHA-256 校验 | ✅ |
| `ios/app/Sources/GameLibrary.swift` | Bundle catalog + Documents 数据 join；AOT / Data missing / Checking / Error 状态；playHistory 保留 | ✅ |
| `ios/app/Sources/AOTPackageLoader.swift` | 从签名 Bundle `dlopen` pack + 校验 title/ABI/注册钩子；ROM 取推送数据（或旧 Bundle ROM）；保留静态链接旧路径 | ✅ |
| `ios/app/Sources/ROMSession.swift` | 启动门槛：数据校验 + AOT；ROM 取推送数据；存档按 titleID/saveNamespace | ✅ |
| `ios/app/Sources/HomeView.swift` | 空态改为桌面启动器说明；AOT/Data missing/Checking/Error 徽标；逐游戏提示；刷新 | ✅ |
| `ios/app/Sources/DebugLaunch.swift` | `-gamesRoot` / `-openAOTTitleID` 调试入口 | ✅ |
| `ios/app/project.yml` | 显式 Info.plist：`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` | ✅ |
| `ios/zakuro-ios/src/lib.rs` | GamePack 注册 / AOT 映像交接 | ✅（task-10/11） |
| 启动器 `launcher/macos`、`launcher/windows` + 设备桥 | 导入 → 编译 pack → 重建/重装含 catalog 的壳 → 设备桥推送 ROM+GameInfo 到 `Documents/Games` | 并行任务 task-16/18/19 |
| `docs/build.md` / 公开文案 | 新流程、旧手机端导入说明删除 | 待发布时统一 |

## 5. 里程碑

1. **M1** ✅ 桌面端单游戏 AOT 包 + 壳按 catalog 加载；dylib 动态加载在模拟器验证。
2. **M2** ✅ 多游戏包、titleID→pack 分配、存档按 titleID 隔离。
3. **M3** ✅ 删除解释器与手机导入路径；无 AOT / 校验失败给出明确错误。
4. **M4**：launcher-first 分发（base 壳 + Documents 推送；task-17 壳侧 ✅，
   task-16/18/19 启动器与设备桥进行中）；真机签名/重签实测；10 款构建矩阵。

## 6. 风险

- **iOS 代码签名与安装步骤**：AOT 包必须随 IPA 重新签名安装（加游戏 = 重装壳），用户游戏
  数据单独推送并在升级后保留；真机需验证重装后数据仍可见、壳能正确 join。签名仍走
  SideStore/Sideloadly。
- **跨平台编译**：Windows 上没有 Apple SDK；第一版用远程 macOS 构建机，注意 Apple 许可。
- **兼容性**：去掉解释器后，没有 AOT 包的游戏完全不可用；现在有逐游戏校验错误提示。
- **大文件校验**：约 1.7 GB ROM 的 SHA-256 首次校验耗时（后台进行，不阻塞 UI，但占 I/O）。
- **法律**：仍然只支持用户自有 ROM；launcher 不提供 ROM/keys 下载。

## 7. 已实现子集（0.1.6-alpha 壳，2026-11-14）

> 范围：`ios/app/Sources` 的壳侧改造。桌面打包（`builder/`、`scripts/`）由并行任务负责，
> 当前构建脚本仍生成 schemaVersion 1，见 §8。
>
> **注**：§7.1–§7.7 描述上一版**自包含**（游戏和 ROM 都打进壳 Bundle）模型的实现；**§7.8
> 是当前两段式模型**（AOT 包随签名 IPA，游戏数据推送到 `Documents/Games/`）。两者在代码
> 中并存：catalog 里的 `romFile` 旧条目不阻塞启动（legacy 从 Bundle ROM 启动），普通
> catalog 条目则等待推送数据。

### 7.1 GameCatalog.json v2（向后兼容）

构建期写入 app bundle（根目录或 `Resources/`）的 `GameCatalog.json` 现在是**游戏库的唯一来源**：

```json
{
  "schemaVersion": 2,
  "games": [
    {
      "titleID": "0004000000055E00",
      "displayName": "Pokémon Y",
      "productCode": "CTR-P-EK2A",
      "aot": true,
      "aotVersion": 1,
      "packFile": "Frameworks/GamePack-0004000000055E00.dylib",
      "packABIVersion": 1,
      "registrationSymbol": "zk_gamepack_register",
      "coverFile": "Covers/0004000000055E00.png",
      "notes": ""
    }
  ]
}
```

| 字段 | 必需 | 语义 |
|---|---|---|
| `schemaVersion` | 是 | 2；1 仍然接受（按“静态链接”迁移，见下） |
| `titleID` | 是 | 16 位大写十六进制；重复/非法条目被丢弃并记日志 |
| `displayName` | 是 | 卡片标题；缺失时回退为 titleID |
| `productCode` | 否 | 3DS 产品编号 |
| `aot` | 是 | 桌面端是否为该游戏分配了 AOT 代码；false 显示“No AOT”，不可启动 |
| `aotVersion` | 否 | AOT 产物版本（信息用） |
| `packFile` | 否 | **相对 app bundle 的游戏包 dylib 路径**；缺省 = AOT 代码静态链接进主二进制（0.1.x 单游戏构建） |
| `packABIVersion` | 否 | GamePack ABI 版本，默认 1 |
| `registrationSymbol` | 否 | 覆盖默认注册符号名 |
| `coverFile` | 否 | 相对 bundle 的封面图（可选） |
| `notes` | 否 | 构建信息 |

兼容规则：schemaVersion 1 的条目没有 `packFile`，一律按“静态链接”处理——0.1.x 单游戏
IPA 升级到新壳后仍按原样工作。`packFile` 会被校验（拒绝绝对路径、`..`、空分段），
非法值降级为静态链接并记日志。

### 7.2 只读游戏库

- `GameLibrary` 只做 `GameCatalog.json → 卡片`：没有 ROM 扫描、没有复制、没有 Files 导入，
  `ROMDocumentPicker` 已删除。
- 本地仅保存**游玩历史** `Documents/Library/playHistory.json`（`titleID → 最近一次开始时间`，
  原子写入）；卡片按最近游玩排序。
- 首次从 0.1.x 升级时，旧的 `Documents/Library/library.json` 只被读取一次，用于迁移
  最近游玩时间；它不再决定库里有哪个游戏。
- `HomeView` 移除 Import 按钮/流程；空库显示“此构建没有游戏：在电脑上构建 AOT 包并重新安装”
  （launcher-first 版本的空态改为提示使用桌面启动器，见 §7.8）。

### 7.3 只启动 AOT：解释器兜底移除

- `ROMSession.start(_:)` 先过 `AOTPackageLoader` 的 AOT 检查；不能启动时展示
  “No AOT build for this game” 通知卡（可 Dismiss），**不会**再用解释器启动。
- 即使运行时的 `zk_create()` 成功，也要求 `zk_recompiled() == 1`；否则
  `zk_destroy()` 并展示同一错误（含 linked title id）。没有“解释器警告/确认”了。
- `AOTStatus` 只剩 `AOT not loaded` / `AOT · linked`，About 与诊断导出只显示真实状态。
- 包存在但运行时还不能从游戏包启动时，给出明确说明（“AOT package ready … 需要下一版运行时”），
  同样不启动解释器。

### 7.4 GamePack dylib 加载与 C/Rust 契约（host ABI v1）

`AOTPackageLoader`（`ios/app/Sources/AOTPackageLoader.swift`）：

1. `packFile` 相对 `Bundle.main.bundleURL` 解析，拒绝绝对路径/`..`；不存在 →
   “No AOT build for this game”（缺包）。
2. `dlopen(path, RTLD_NOW | RTLD_LOCAL)`；失败 → 错误通知（含 `dlerror()` 文本）。
3. 可选导出符号校验（`dlsym`）：
   `uint64_t zk_gamepack_title_id`（与 catalog titleID 不符则 `dlclose` 并拒绝）、
   `uint32_t zk_gamepack_abi_version`（必须等于 host ABI 1）。
4. 可选注册钩子：`int32_t zk_gamepack_register(uint32_t host_abi_version)`
   （符号名可由 catalog 的 `registrationSymbol` 覆盖）；返回 0 才接受，加载后缓存句柄。
5. 生命周期：验证过的 pack 在 app 进程内保持打开（后续交给运行时）；失败即 `dlclose`。

C 契约（游戏包侧；全部符号可选）：

```c
#include <stdint.h>

uint64_t zk_gamepack_title_id(void);        /* 可选：本包对应的 title ID */
uint32_t zk_gamepack_abi_version(void);     /* 可选：本包实现的 ABI 版本，必须为 1 */
int32_t  zk_gamepack_register(uint32_t host_abi_version);  /* 可选注册钩子，0 = 接受 */
```

**尚未实现**：注册钩子目前只做版本/握手校验，运行时（`ios/zakuro-ios`）还没有
“从 GamePack 映像启动”的 `zk_*` 入口；真正的映像交接留给 runtime-ffi 任务（见 §8）。

### 7.5 存档按 titleID 隔离

- 电池存档：`Documents/data/<TITLEID>`；即时存档：`Documents/states/<TITLEID>`；
  Save Manager/ZIP 导入导出都走同一命名空间。
- 从 0.1.x 升级的静态构建启动时，旧的 `data/<ROM文件名>`、`states/<ROM文件名>` 会
  一次性改名为 titleID 目录（目标已存在则保留目标并记日志）。
- 静态构建仍需要旧库里的 ROM 文件作为卡带数据：按旧 `library.json` 的 titleID→文件映射
  查找 `Documents/roms/`；没有旧库且只有一个卡带文件时使用它；找不到则显示
  “Game data missing”，不启动解释器。

### 7.6 现有单游戏 AOT 构建兼容

- 静态构建（catalog `aot: true`、无 `packFile`）：`zk_linked_code() == 1` 且
  `zk_linked_program_id()` 等于 catalog titleID 时才可启动；否则明确报错。
- 构建脚本无需改动即可产出可运行的单游戏 IPA（catalog 仍是 v1）。
- 加载后仍强制 `zk_recompiled() == 1`，保证不会悄悄退回解释器。

### 7.7 UI 与本地化

- 首页：目录网格、最近游玩、AOT/No AOT 徽标；“No AOT build for this game” 通知卡；
  空态提示“在电脑上添加游戏并重新安装”。
- 设置/关于/存档页文案改为 AOT-only 说法；诊断导出 `rom=` 改为 `game=<name> (<titleID>)`。
- 新增/更新文案全部进 `en.lproj` 与 `zh-Hans.lproj`。
- `ios/preview`（Catalyst 无头截图）新增三种状态：`home-empty`、catalog 填充的 `home`、
  `home-no-aot`（点击未构建的游戏后）。

### 7.8 Launcher-first 两段式库（task-17，2026-11-14）

> 架构修正（Lead）：iOS 不允许 `dlopen` Documents 里的未签名 dylib，因此
> **AOT 包必须随签名 IPA 安装**；Documents/Games 只放用户游戏数据。

两段式模型（布局见 §3）：

1. **AOT 包 + catalog 随 IPA**：桌面启动器重建含 `Frameworks/GamePack-<TITLE_ID>.dylib`
   和 `GameCatalog.json` 的壳并签名/安装（加游戏 = 重建 + 重装）。
2. **游戏数据推送**：设备桥只把 `GameRom.cci` + `GameInfo.json`（最后写）推送到
   已安装 App 的 `Documents/Games/<TITLE_ID>/`；数据在 App 升级/重装后保留。

壳侧实现：

- **游戏列表**（`GameLibrary.swift`）：Bundle `GameCatalog.json` 是唯一游戏列表；每个
  catalog 条目与 Documents 里对应 titleID 的推送数据 join。没有推送数据的 catalog 游戏
  显示 **Data missing**（不是 AOT 错误），提示用启动器推送；有效数据按最近游玩/标题排序。
- **数据校验**（`InstalledGame.swift`）：快速校验目录名/清单/ROM 存在与大小/路径不越界；
  清单记录的 SHA-256 在后台流式校验（4 MiB 块，期间卡片显示 **Checking**）。错误按游戏
  显示（**Error** 徽标 + 点击逐条列出原因），不会启动。
- **启动**（`ROMSession.swift` + `AOTPackageLoader.swift`）：从签名 Bundle `dlopen`
  `GamePack-<TITLE_ID>.dylib`（title/ABI/注册钩子校验与注册流程不变，ABI 1），随后
  `zk_create` 载入 Documents 里已校验的 ROM；若后台哈希校验未完成，启动会等待结果。
- **存档**：`Documents/data/<saveNamespace 或 titleID>`、`Documents/states/...`；
  Save Manager 与即时存档使用同一命名空间。
- **文件共享**：`ios/app/project.yml` 用 XcodeGen 显式 `Info.plist`
  （`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` 均为 true；此前的
  `INFOPLIST_KEY_UIFileSharingEnabled` 被 Xcode 静默丢弃，已修正）。
- **升级兼容**：上一版自包含构建的 ROM 还在 Bundle 里（catalog 有 `romFile`），壳继续从
  Bundle 启动（legacy 回退）；0.1.x 静态链接 / `Documents/roms` 路径保留。全新 base 壳
  catalog 可以为空，首页显示 launcher 空态。
- **调试**：`-gamesRoot <path>` 扫描夹具数据目录 + `-openAOTTitleID <TITLEID>` 自动
  启动；配合 `simctl app container` 注入数据夹具，模拟器无需人工点击即可验证整条路径；
  `ios/app/README.md` 有完整命令（含 `build-ios-app-sim.sh --game-pack` 把 AOT 包嵌进
  Simulator 壳）。
### 7.8.1 验证证据（2026-11-14，macOS VM + iPhone 17 Pro Simulator）

构建（VM，Xcode 26.6，8 vCPU）：

- `PATH=/usr/local/bin:$PATH scripts/build-ios-app.sh --keep-project`：**通过**，产出
  `ios/app/build/Release-iphoneos/3ds2apple.app`；构建后 `Info.plist` 实测
  `UIFileSharingEnabled=true`、`LSSupportsOpeningDocumentsInPlace=true`。
- `scripts/build-ios-app-sim.sh --app shell --game-pack <GamePack.dylib> --game-title-id
  0004000000055E00`：**通过**，x86_64 Simulator 壳内含
  `Frameworks/GamePack-0004000000055E00.dylib` + `GameCatalog.json`
  （schemaVersion 2、1 game、packFile/packABIVersion）。

模拟器（iPhone 17 Pro / iOS 26.5，Documents 夹具经 `simctl get_app_container` 注入）：

| 场景 | 结果 | 证据文件（VM `/tmp/corrected-sim/`） |
|---|---|---|
| catalog 有游戏、未推送数据 | 卡片橙色 **Data missing** | `home-data-missing.png` |
| 推送真实 ROM（1,807,118,336 B，硬链接）+ GameInfo(size) | 卡片绿色 **AOT**，日志 `1 catalog game(s); 1 with pushed game data ... 1 checking` → 校验通过 | `home-aot-ready.png`、`previous.log` |
| `-openAOTTitleID` 从推送数据启动 | **真实游戏启动**（Pokémon Y 语言选择画面，AOT 编码执行），日志 `library entry: Pokemon Y ... from app bundle pack + Documents/Games/0004000000055E00` | `game-launched.png` |
| SHA-256 不匹配（小假 ROM + 错误记录哈希） | 卡片红色 **Error** + 通知卡逐字列出期望/实际 SHA-256 与修复方法 | `home-hash-mismatch.png`、`previous.log` |
| 半推送（只有 GameInfo.json、无 ROM） | 卡片红色 **Error**（`romMissing`），不会启动 | `home-partial-push.png`、`latest.log` |

证据目录在 VM `/tmp/corrected-sim/`（`test.log`、`*.png`、`previous.log`/`latest.log`、
`device-log.txt`），按规则不入 git。测试结束后已 `xcrun simctl shutdown all`。

## 8. 仍未完成 / 交给并行任务

1. **macOS 启动器（task-18）与 Windows 启动器（task-19）**：导入 ROM → 本机/构建机编译
   AOT → 重建/签名安装含 `Frameworks/GamePack-<TITLEID>.dylib` + `GameCatalog.json`
   的壳 → 通过设备桥只把 `GameRom.cci` / `GameInfo.json`（最后写）写入
   `Documents/Games/<TITLEID>/`。
2. **设备桥（task-16）**：`devpush` 的 put/put-tar、大小校验、安装/签名流程；只推送
   `GameRom.cci` + `GameInfo.json`（后者最后写），可执行代码永不推送（AOT 包在 IPA 内）。
3. **真机验证**：模拟器已验证两段式路径（§7.8）；真机还需验证文件共享可见、AFC 推送后
   壳刷新、约 1.7 GB ROM 的 SHA-256 校验耗时、以及重装壳后 Documents 数据仍保留。
4. **公开文案**：`README.md` / `README.zh-CN.md` / `docs/architecture.md`、
   `docs/build.md` 仍描述旧的“手机端导入 ROM + 解释器兜底 / 单游戏 IPA”，随版本发布统一
   改写；旧预览脚本 `scripts/ios-ui-preview.sh` 仍按旧 `library.json` 播种，需跟随
   `ios/preview` 更新。
5. **base shell IPA 发布物**：需要由 dist/Lead 固定版本（bundle id `com.kratos.3ds2apple`、
   sha256、version），供两个启动器内嵌分发；task-17 只负责壳代码与构建验证。
