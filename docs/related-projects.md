# 同类项目调研：可直接使用 / 可借鉴

> 调研日期：2026-11-14。目标：给 3ds2apple（AOT 原生 3DS on iOS、无 JIT、侧载分发）
> 找可直接复用（MIT/Apache 等宽松许可）或只可借鉴（GPL/无许可证）的 GitHub 项目。
> **许可证原则**：MIT/Apache-2.0 代码可引入（保留版权/NOTICE）；GPL/AGPL 只能读 UI/设计，
> 不得复制代码；无 LICENSE 的仓库默认「保留所有权利」，只能当资料阅读。

## 1. 结论（最值得马上用/看的 5 个）

| 排名 | 项目 | 许可证 | 相似点 | 对我们最有价值的东西 |
|---|---|---|---|---|
| ⭐1 | **LNPANDY/NX2Apple** <https://github.com/LNPANDY/NX2Apple> | MIT | Switch 原生 ARM64 + Metal + 单 App 整库 + Mac/Windows 一键构建 + 侧载 IPA | `frontend-ios/` 是可独立复用的 **SwiftUI 多游戏壳视图层**（ShellUI：GameTile/GameDetail/Artwork/GameState/设置模型、Cover Flow、主机模式、引导页）；启动器的分层/进度/诊断架构；删除游戏保留存档的设计 |
| ⭐2 | **jhaizhou-ops/S2Arm** <https://github.com/jhaizhou-ops/S2Arm> | Apache-2.0 | 就是用户说的 "S2ARM"：Switch 代码改写 ARM64、Metal、一个 App 装整个库、Mac/Windows 图形启动器 | `ios/` 的 ObjC 层（`hud.m`、`vpad.m` 虚拟按键与布局编辑、`settings.bundle`、诊断导出/脱敏、存档迁移）；**`ios/embed.py` + `ios/macho_dylib.py` 的「外置游戏镜像包 dylib + 运行时注册映射」**；`pack/` 的打包/IPA/重签名占位管线；`s2armctl` 的 AI 可操作 CLI；中文工程文档（Metal HUD/性能口径/显卡语义） |
| ⭐3 | **whovian64/pocket-native** <https://github.com/whovian64/pocket-native> | MIT | 3DS 游戏 AOT 重编译到掌机/Android（Zakuro + 3dsrecomp 的 AOT fork） | `titles/` 每游戏 profile、`recompiler/src/port.rs` 静态 Linked 范式、多平台前端与逐游戏构建流程——是我们现有 AOT 路径最直接的同类实现 |
| ⭐4 | **N64Recomp/N64Recomp** <https://github.com/N64Recomp/N64Recomp> | MIT | 静态重编译 + 原生运行时 + 图形后端，每游戏一个原生工程 | 重编译产物组织、符号/ELF 映射、mod/补丁管线、跨平台工程结构；iOS 移植有 goldenpad 可参考 |
| ⭐5 | **UTMapp/UTM** <https://github.com/UTMapp/UTM> | Apache-2.0（含动态链接 GPL 组件） | iOS 上要求 JIT 也提供无 JIT 的 UTM SE，SwiftUI App + 文件导入 + 侧载文档 | App 架构、文件/配置管理、无 JIT 的取舍、AltStore/SideStore 安装文档；只借架构，注意其 GPL 组件不能静态并入 |

**只可借鉴（GPL/无许可证）**：Folium（GPL-3.0，3DS/DS 的 iOS 产品 UI）、
Provenance-Emu/emuThreeDS（GPLv3，3DS on Apple，SwiftUI 库界面）、
Provenance（GPL 系，多机种库/封面/导入）、Delta（AGPL-3.0，iOS 模拟器 UI 标杆）、
Azahar（GPLv3，3DS 设置/每游戏配置）、goldenpad（无 LICENSE，N64 重编译 iOS 的
工程/法律边界研究文档，只读不抄）。

## 2. NX2Apple 里具体可复用什么

- `frontend-ios/` 是 **Swift 6 Package**，README 明确写它是「multi-game shell 的视图层，
  只渲染输入、上报操作，不依赖引擎」——这正是我们 HomeView/SettingsView/GameView 之外的
  Shell 层缺的东西。直接可借鉴/改编的类型：
  - `GameTile` / `GameDetail`：标题、副标题、16:9 banner、方形 icon、状态、最近游玩、
    设置、云存档、追加内容；
  - `Artwork`：banner 优先、没有 banner 时用方形 icon 放在模糊背景里（不拉伸），
    再没有就用标题色块——正好解决我们封面占位问题；
  - `GameState`：可玩 / 缺游戏数据 / 需更新 / 损坏原因；
  - `SettingSection`/`SettingRow`/`SettingKind`：结构化设置模型；
  - Cover Flow、console 模式、引导页（Onboarding）布局。
- **注意**：它要求 iOS 26 / Swift 6。我们的 deployment target 目前是 iOS 16，
  不能直接整体依赖；正确做法是**按组件移植 + 保留 MIT 版权声明**（我们 Apache-2.0 兼容），
  或评估是否把最低系统提到 iOS 18/26（需产品决定）。
- 启动器（`frontend/`）用 SwiftPM 分 `NXCore`/`NXModel`/`NXLauncher`，把纯逻辑、store、
  视图严格分层，构建进度有阶段/ETA/日志/诊断导出——我们的 `builder/` 可以照这个信息架构做。

## 3. S2Arm 里具体可复用什么（最接近我们要做的分发模型）

- **外置游戏镜像包**（`ios/embed.py`、`ios/macho_dylib.py`、`runtime/src/imgpack.c`）：
  纯 Python 生成一个带预留签名区的 `Frameworks/S2AImages.dylib`，把每个游戏的改写映像
  （`__TEXT,__swcode`/`__SWDATA,__img` + 偏移表）装进去；运行时按需 `MAP_FIXED` 映射，
  shell 主程序本身不含游戏代码、不重编。**这正好回答「单 App 整库」怎么落地**：
  shell 一次构建，每加一个游戏只增量生成/更新游戏包。
  - 对我们的映射：把 3dsrecomp 生成的 C 编成 arm64 代码后，按同样方式做成 `libgame` 镜像包；
    shell 启动时选择 title ID → 注册镜像 → 调用 Zakuro。
  - 前置验证：SideStore/Sideloadly 重签能否正确处理嵌套 dylib（S2Arm 声称其预留签名区可被
    重签工具原地替换；需我们实测），以及 iOS 26 对 dylib 加载/签名的限制。
- **iOS ObjC 层**（Apache-2.0）：
  - `hud.m`：官方 Metal HUD 用 `MetalHUDForceEnabled` 用户默认项 + 重启生效，
    与 0.1.3 的实现一致；同时保留自有诊断浮层——两条腿走路的经验可直接借；
  - `vpad.m`/`vpad_layout.m`/`touch_config.m`：虚拟按键、可编辑布局、触控配置；
  - `settings.bundle`：把部分开关放进系统「设置 → App」里；
  - `diag.m`/`diagredact.m`/`diagzip.m`：一键诊断包 + 脱敏；
  - `save_transfer.m`：存档导入导出；
  - `extdisplay.m`/`phone_motion.m`/`ea_rumble.m`：外接屏/体感/手柄。
- **pack/**：`ipa.sh`、`app_bundle.py`、`shell_build.sh`、`dev_sign.py`、`ipa_tail.py`、
  `banner_fetch.py`、`display_names.tsv`、`save_identity.py` 等，是完整的
  「单 App + 游戏包」打包/命名/签名占位/封面抓取/存档身份管线，可抽出来改造成我们的
  `scripts/`（例如把现在「每游戏一个 IPA」升级成「一个 shell + 游戏包」）。
- **launchers/ + s2armctl**：图形启动器带进度/耗时/磁盘占用，且暴露 CLI 给 AI 操作，
  并有自检/自修/反馈工具。我们的 `builder/`（Rust + zkb）可以借鉴其命令集与诊断包设计。
- **docs/开发监控与MetalHUD.md**：确认 `MTL_HUD_ENABLED` 只在启动时读、
  `MetalHUDForceEnabled` 默认项 + 重启生效、Developer→Graphics HUD 需要 development
  provisioning profile——和我们这轮结论一致，可作为 HUD 文档依据。

## 4. 其他值得看的实现/资料

- **goldenpad** <https://github.com/chrissotraidis/goldenpad>（无 LICENSE，仅阅读）：
  N64 静态重编译 + RT64 Metal 在 iPhone/iPad 的完整工程记录，包含 `docs/RESEARCH.md`
  里对「哪些 AOT 输入可公开、哪些必须私有、GPL 边界」的讨论，以及 PadMint 构建工具思路。
- **Pocket Native**：`titles/` 目录给每个游戏一个 profile（标题 ID、补丁、兼容性）——
  我们的 `GameCatalog` 可以扩展成同类的 per-title 配置。
- **N64Recomp**（MIT）：静态重编译器如何做 ELF/symbol 映射、函数边界识别、
  重编译产物与运行时接口；对 3dsrecomp 的长期维护有参考价值。
- **Delta/Folium/Provenance/emuThreeDS/Azahar**：只抄信息架构和交互（游戏库卡片、
  每游戏设置、导入流程、封面占位、手柄映射、存档管理），不复制代码。
- **封面/元数据来源**：
  - `libretro-thumbnails/Nintendo_-_Nintendo_3DS`（Named_Boxarts/Named_Snaps/Named_Titles，
    社区维护，运行时按需下载，不打包进仓库）；
  - GameTDB（3DS 封面，按 title ID/游戏名）；
  - 3DS title ID → 名称数据库（3dsdb 系）用于自动命名；
  - SideStore/AltStore 的 `source.json` 规范（我们已在用）。
  注意：封面版权属于发行商，运行时抓取/展示与打包分发要区分，别把封面提交进仓库。

## 5. 对我们的落地建议（按优先级）

1. **UI 排版**（正在卡的部分）：把 NX2Apple ShellUI 的 `GameTile`/`Artwork`/`GameState`/
   设置模型移植成 iOS 16 兼容版（MIT 声明保留），先替换 HomeView 卡片/空态/Settings 分组；
   Folium/emuThreeDS 只做视觉对照。截图流水线（Mac Catalyst）恢复后逐屏对照。
2. **单 App 整库**：优先做 S2Arm 外置镜像包的 spike：`shell + Frameworks/GamePack.dylib`
   （壳不重编、游戏按 title 增量），先验证「SideStore 重签后能否加载」；成功则取代
   「每游戏一个 IPA」。若签名路径不可行，退回「一个 shell + 多游戏数据（解释器兜底）」
   并明确标注哪些游戏是 AOT。
3. **封面/库体验**：接入 libretro-thumbnails/GameTDB 运行时抓取 + 本地缓存；标题 ID
   自动命名/分组；沿用 NX2Apple「删除游戏保留存档」。
4. **构建/分发体验**：照 S2Arm launcher + `s2armctl` 的信息架构升级 `builder/`：
   阶段进度/ETA/日志/诊断包、一键安装、AI 可调用的命令集。
5. **HUD/性能**：沿用 S2Arm 的「官方 HUD 请求 + 自有浮层」两条线；把
   `docs/开发监控与MetalHUD.md` 的结论写进我们 docs（HUD 只在 Metal/AOT 路径有意义）。

## 6. 许可证速查

| 项目 | 许可证 | 能做什么 |
|---|---|---|
| NX2Apple | MIT | 可复制/修改/商用，保留版权与许可声明 |
| S2Arm | Apache-2.0 | 可复制/修改/商用，保留 NOTICE、标注修改 |
| Pocket Native | MIT | 同上 |
| N64Recomp | MIT | 同上 |
| UTM | Apache-2.0 | 可借架构；其 GPL 组件（gstreamer 等）不能静态并入闭源分发 |
| SideStore | AGPL-3.0 | 只使用 `source.json` 格式，不复制 App 代码 |
| 3dsrecomp（fearkov） | 无 LICENSE | 仅作为构建工具运行，不 vendor 源码/不复制代码 |
| Folium / emuThreeDS / Azahar | GPL-3.0 | 只读参考，不复制代码 |
| Delta | AGPL-3.0 | 只读参考 |
| Provenance | NOASSERTION（GPL 系） | 只读参考 |
| goldenpad | 无 LICENSE | 只读参考（保留所有权利） |
| libretro-thumbnails / GameTDB | 社区缩略图/网站条款 | 运行时抓取展示，不提交仓库；商用前单独确认 |
