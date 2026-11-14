# AOT-first 路线（0.1.5 之后）

> 目标版本：0.1.6 / 1.0 之前的下一个大版本。
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
