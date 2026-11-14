# AOT-first 路线（0.1.5 之后）

> 目标版本：0.1.6 / 1.0 之前的下一个大版本。
> **状态（2026-11-14）**：壳侧子集已实现（§7）；桌面打包与运行时从游戏包启动仍待并行任务（§8）。
> 核心变化：**去掉解释器兜底，只运行 AOT 代码；手机端不再导入 ROM，改由桌面端导入、
> 预编译并按游戏分配 AOT 包。**

## 1. 与当前版本的区别

| | 0.1.5-beta1（当前） | 下一版本（AOT-first） |
|---|---|---|
| 手机端 ROM 导入 | 支持（Files 多选） | **移除**，只保留“已安装游戏” |
| 运行方式 | AOT（有 catalog 时）+ 解释器兜底 | **只允许 AOT**；无 AOT 的 ROM 不能启动 |
| 导入/构建 | 桌面脚本 / `builder/` | 桌面图形 launcher（Linux/Windows/macOS）一条龙 |
| 包结构 | 壳 IPA 或单游戏 IPA | **一个壳 + 每游戏 AOT 包**（打包时写入 IPA） |
| 兼容性标注 | AOT/Interpreter 徽标 | 只有“已构建 AOT / 不可用” |

## 2. 桌面端（Linux / Windows / macOS）

参考 S2Arm（Apache-2.0）与 NX2Apple（MIT）的 launcher 形态：

1. **导入**：用户选择自己的已解密 ROM（.3ds/.cci/.cia），桌面端读取 NCSD/NCCH 头得到
   title ID、product code、游戏名；不支持/读不到头的 ROM 直接拒绝。
2. **预编译**：
   - macOS：`build-recomp-ios.sh` + `build-linked-ios-lib.sh`（复用现有脚本）；
   - Linux：3dsrecomp 可原生运行；arm64-apple-ios 产物用可再分发的 LLVM/clang + iOS SDK
     （或交给 macOS builder）——第一版可以先要求“Linux/Windows 只负责导入与排队，
     AOT 编译交给 macOS build agent”，与当前 `builder/` 的 macOS Build Agent 一致；
   - Windows：WSL2/远程 macOS agent 二选一。
3. **生成游戏包**（每游戏独立目录，互不覆盖）：
   ```text
   GamePack-<TITLE_ID>/
     GamePack.dylib          # AOT 代码 + 数据映像（S2Arm image-pack 风格）
     GameInfo.json           # titleID / 名称 / productCode / aotVersion / 大小 / 校验
     cover.png               # 可选（用户本地生成或抓取，不入仓库）
   ```
4. **打包 IPA**：把用户勾选的游戏包写进壳 App：
   `Payload/3ds2apple.app/Frameworks/GamePack-<TITLE_ID>.dylib` +
   根目录 `GameCatalog.json`（现有 schema 扩展 `packFile`、`titleId`、`aotVersion`）。
   签名仍由用户用 SideStore/Sideloadly 完成；**加游戏 = 重新打包 + 重签**（iOS 不允许
   运行时下载可执行代码）。
5. **不做的事**：不内置 ROM/keys/游戏数据；不在手机端编译；不下载可执行内容。

## 3. 壳（手机端）

- `GameLibrary` 改为**只读目录**：由 `GameCatalog.json` 生成，不再扫描/导入 ROM；
  “导入”按钮移除，改为提示“请在电脑上添加游戏并重新安装”。
- 启动时按 catalog 里的 `titleId` 加载对应 `GamePack.dylib`（`dlopen` 或静态注册表），
  把映像映射给 Zakuro；`zk_create` 只接受 catalog 内的 title。
- **移除解释器路径**：`AOTStatus` 只有 linked/active；不匹配的 ROM 直接报错并说明
  “此版本没有为该游戏构建 AOT”。
- 存档/即时存档按 `titleId` 命名空间隔离（现有按文件名的逻辑迁移到 titleId）。
- 首页与设置保持 0.1.5 的布局；AOT 徽标改为“已构建”。

## 4. 需要改的代码/脚本

| 位置 | 改动 |
|---|---|
| `ios/app/Sources/GameCatalog.swift` | schema 扩展：`packFile`、`aotVersion`、可选封面 |
| `ios/app/Sources/GameLibrary.swift` | 删除导入/复制/ROM 头解析，改为 catalog → entries |
| `ios/app/Sources/HomeView.swift` | 去掉 Import；空态改为“在电脑上添加游戏” |
| `ios/app/Sources/ROMSession.swift` | 只能从 catalog 启动；去掉 interpreter 分支/告警 |
| `ios/zakuro-ios/src/lib.rs` | 提供按 title 注册 AOT 映像的入口（参考 S2Arm `imgpack.c`） |
| `scripts/build-game-ipa.sh` | 支持多游戏包：收集多个 `GamePack-*` 写入一个 IPA |
| 新增 `pack/` 或 `builder/` | 桌面 launcher：导入 → 排队编译 → 游戏包 → 打包 IPA |
| `docs/build.md` | 新流程；旧手机端导入说明删除 |

## 5. 里程碑

1. **M1**：桌面端单游戏 AOT 包 + 壳能按 catalog 加载（不追求多游戏），验证 dylib 重签后可加载。
2. **M2**：多游戏包写入同一 IPA；GameCatalog 分配 titleID→dylib；存档按 titleID 隔离。
3. **M3**：删除解释器与手机导入路径；无 AOT 的 ROM 给出明确错误。
4. **M4**：Linux/Windows launcher（第一版可复用 macOS build agent 远程编译）；
   SideStore 重签流程实测；10 款构建矩阵。

## 6. 风险

- **iOS 代码签名**：嵌套 dylib 必须由重签工具一并签名；S2Arm 的“预留签名区 + 重新签名”
  需要先用 SideStore/Sideloadly 实测，否则退回“每游戏一个 IPA”。
- **跨平台编译**：Windows/Linux 上没有 Apple SDK；第一版用远程 macOS agent，后续再评估
  可再分发的 SDK/clang 方案（注意 Apple 许可）。
- **兼容性**：去掉解释器后，没有 AOT 包的游戏完全不可用，需要在 UI 和文档里说清楚。
- **法律**：仍然只支持用户自有 ROM；launcher 不提供 ROM/keys 下载。

## 7. 已实现子集（0.1.6-alpha 壳，2026-11-14）

> 范围：`ios/app/Sources` 的壳侧改造。桌面打包（`builder/`、`scripts/`）由并行任务负责，
> 当前构建脚本仍生成 schemaVersion 1，见 §8。

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
- `HomeView` 移除 Import 按钮/流程；空库显示“此构建没有游戏：在电脑上构建 AOT 包并重新安装”。

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

## 8. 仍未完成 / 交给并行任务

1. **运行时从游戏包启动**（runtime-ffi）：`ios/zakuro-ios` 需要接受 GamePack 注册的 AOT
   映像（新增 `zk_*` 入口或扩展 `zk_create`），壳侧 `ROMSession.start` 的
   “AOT package ready … 需要下一版运行时” 分支改为真正启动。
2. **桌面打包与脚本**（任务 task-7）：`scripts/lib/game-catalog.sh` 的校验器目前只接受
   schemaVersion 1，需要按 §7.1 生成/校验 v2、收集多个 `GamePack-*.dylib`、
   输出 `GameInfo.json` 并更新 `docs/build.md` / `docs/desktop-aot.md`。
3. **签名实测**：嵌套 dylib 必须随 IPA 一起重签（SideStore/Sideloadly），需要在真机验证
   `dlopen` 成功；失败时的降级已在壳侧覆盖（明确错误，不启动解释器）。
4. **旧预览脚本**：`scripts/ios-ui-preview.sh` 仍按旧的 `library.json` 播种；当前 UI 自检
   以 `ios/preview` 的 Catalyst 无头路径为准，脚本与 `ios/preview/README.md` 需要同步更新。
5. **公开文案**：`README.md` / `README.zh-CN.md` / `docs/architecture.md` 仍描述“手机端导入
   ROM + 解释器兜底”，随版本发布统一改写。
