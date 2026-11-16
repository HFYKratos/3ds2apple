# launcher-first 公开分发与发布流程（GitHub Releases）

> 状态：决策 + 可执行发布流程 · 2026-11-16 · task-4，task-9 更新到 Windows 0.2.5 / macOS 0.2.4 build 7 · 维护者：release-docs
> 读者：Lead（发布执行人）与后续维护者。相关文件：AGENTS.md、.internal/PROJECT_HANDOFF.md、
> docs/windows-launcher.md、docs/macos-launcher.md、THIRD_PARTY.md、NOTICE、
> scripts/release/assemble-release.sh、scripts/release/verify-release.sh。

## 0. TL;DR（决策摘要）

| 编号 | 决策 | 说明 |
|---|---|---|
| D1 | 公开二进制只走 GitHub Releases | 源码在仓库；不做 App Store/TestFlight、不做第三方商店；SideStore/AltStore 源暂不适用（§7）。 |
| D2 | 每期 Release 资产 = 3 个可执行包 + 校验文件 + 许可文本 | Windows 启动器 zip、macOS 启动器 zip、ROM-free 基础壳 IPA 模板、SHA256SUMS.txt、LICENSE/NOTICE/THIRD_PARTY.md；release notes 写在 GitHub Release 正文。 |
| D3 | 永不发布 | ROM/BIOS/密钥/系统文件、生成 C、GamePack-*.dylib、含 pack 的每用户 IPA、游戏数据、含游戏画面截图、Apple ID/证书/profile/UDID、被修改过的第三方二进制。 |
| D4 | 版本线：v0.3.0-beta.1 → v0.3.0 | beta 为 GitHub pre-release；正式版需通过 §3.2 的 Phase B 门槛。组件版本独立（Windows 0.2.5、macOS 0.2.4 build 7、shell 0.2.3/build 11）。 |
| D5 | macOS 真机验收 + Windows 0.2.5 用户真机复测前只发 pre-release | 未验证项必须在 release notes 的"验证状态"里列出，不得暗示已验证。 |
| D6 | 人工发布、资产不可变 | 由 Lead 验收后执行；不自动发布；已 push 的 tag 与已上传的资产不覆盖，修正走新 tag。 |

**关键契约（决定资产边界）**：每游戏的 AOT <code>GamePack-&lt;TITLEID&gt;.dylib</code> 必须由用户本机从
**用户自有的 ROM** 生成，并在签名前放进 IPA 的 <code>Frameworks/</code>；iOS 不允许从 Documents
dlopen 未签名代码。因此可玩 IPA 天然是"每用户、每游戏"的产物，不能作为公共资产分发。

## 1. 产品形态与分发边界

launcher-first 链路（AGENTS.md §4）：

~~~text
用户自有 decrypted ROM (.3ds/.cci)
  → Windows/macOS 启动器导入（只读头部 + ExeFS icon）
  → 3dsrecomp → C → 本机 LLVM/Apple clang → arm64 GamePack.dylib
  → 启动器合成 ROM-free 基础壳 IPA（壳 + GamePack-*.dylib + MoltenVK.framework + catalog）
  → Impactor/plumesign（Windows，用户 Apple ID）或 Xcode/devicectl（macOS）签名安装
  → devpush 只推送 Documents/Games/<TITLEID>/{GameRom.cci,GameInfo.json}
  → 手机壳扫描 bundle catalog + Documents 游戏数据，Zakuro + MoltenVK/Metal 运行 AOT 代码
~~~

由此得到三条资产推论：

1. **桌面启动器可以预编译分发**：它们是普通桌面应用，内含 ROM-free 壳模板、Impactor/plumesign、
   本地 LLVM 工具链等"无游戏数据"的组成部分。
2. **手机壳只能作为 ROM-free 模板分发**：空 catalog 的壳单独安装后不可玩，只是给启动器合成用的底座。
3. **每游戏 IPA（含 GamePack）只能由用户本机生成并签名，绝不公开**：公开它等于公开用户 ROM 的衍生代码，
   且并不存在"一份对所有用户都可用"的 GamePack。

## 2. 资产矩阵

### 2.1 每期 Release 必发附件

| 资产 | 构建来源 | 版本/标识 | 大小 | SHA-256（2026-11-16 基线） |
|---|---|---|---|---|
| 3ds2apple-windows-single-0.2.5.zip | out/launchers/ | Windows 启动器 0.2.5（单文件 exe；SMDH icon 花屏修复） | 148,817,314 B | b9b2a0b079347a45953f40232735ca4162f6fdd9120df8427a9d14c7af52f0d7 |
| 3ds2apple-launcher-0.2.4-macos-app.zip | out/launchers/ | macOS 启动器 0.2.4 build 7（仅 .app） | 5,495,796 B | 8c34398f7a25709598626769adc56d146ea89ff9f3718313c7c0d796f719d28b |
| 3ds2apple-shell-0.2.3-build11.ipa | out/shell/3ds2apple-shell.ipa（重命名） | 壳模板 0.2.3 / build 11 | 5,487,675 B | 831357dbfeffa81f92fbde0eab8c2962d36e99c924d08f535aa5b60557cfba21 |
| SHA256SUMS.txt | scripts/release/assemble-release.sh 生成 | 本目录全部文件的 SHA-256 | 由脚本生成 | 由脚本生成 |
| LICENSE | 仓库根目录 | 项目 Apache-2.0 | 11,358 B | 由脚本纳入校验 |
| NOTICE | 仓库根目录 | 项目声明 + 随包第三方说明 | 3,967 B（2026-11-16 版） | 由脚本纳入校验 |
| THIRD_PARTY.md | 仓库根目录 | 第三方完整清单 | 4,479 B | 由脚本纳入校验 |

Windows zip 内部只有一个 <code>3ds2apple-launcher.exe</code>（155,464,387 B，
SHA-256 8b921fb4365674bc6fba9d362a89f55da4678e974cce3d6348b6845ba854e57a）；macOS zip 内部只有
<code>3ds2apple-launcher.app</code>（9 个文件，含内嵌 MoltenVK.framework，其 SHA-256
6cd5888490d08b36356d04c50c05e2eda5b9bcb3d0338ece693a28987de96aff 与壳模板一致）。

> 哈希规则：上表只是 2026-11-16 的构建基线。**每期发布以当次
> <code>assemble-release.sh</code> 生成的 <code>SHA256SUMS.txt</code> 为准**，并把各资产 SHA-256
> 复制到 release notes；禁止手填、复用旧哈希或发布未经脚本校验的文件。
>
> 旧 0.2.4 Windows zip（7d3f735f…296fa9）与旧 0.2.3 macOS zip（6ffcf9c6…11c3a）仍留在本地
> out/launchers/ 作历史备份，但**不再作为发布资产**；assemble 时用 --windows-zip/--macos-zip
> 显式指定新文件（旧包会让自动发现变歧义）。

### 2.2 明确不发布（硬性）

- 任何 Nintendo 游戏 ROM（.3ds/.cci/.cia/.cxi/.3dsx/.nsp/.xci）、解密密钥、BIOS/系统文件、字体、游戏资源。
- 生成 C 代码、<code>GamePack-*.dylib</code>、含 pack 的每用户 IPA、<code>Documents/Games/</code> 游戏数据。
- 含游戏画面的截图/录屏（启动器 UI、壳空库界面等非游戏画面可以）。
- Apple ID、密码、2FA、会话 token、证书、描述文件、设备 UDID、签名后的 IPA。
- 修改/重签/改名 fork 过的 Impactor、plumesign、LLVM、MoltenVK 等第三方二进制。
- 被 <code>.gitignore</code> 排除的本地目录内容：/out/、/build/、/ROM/、/third_party/、.internal/、
  *.ipa、*.dylib、*.a、Payload/ 等（见仓库 .gitignore）。

## 3. 版本与 tag 计划

### 3.1 现状（2026-11-16）

- 源码 main HEAD：6421e58（已 push）；工作树中还有其它任务的未提交改动，发布前必须先由 Lead 收敛。
- 公开 Release 仍是旧版本线：最新为 <code>v0.1.5-beta3</code>（pre-release，资产
  <code>3ds2apple-shell-0.1.5-beta3.ipa</code>）；最后一个非 pre-release 是 <code>v0.1.4</code>。
  launcher-first 尚未公开发布（以 <https://github.com/HFYKratos/3ds2apple/releases> 为准）。
- 待发布组件（2026-11-16 ICON 修复后定稿）：Windows 启动器 **0.2.5**、macOS 启动器
  **0.2.4 build 7**、手机壳 0.2.3/build 11（壳未变，仍为 sha256 831357db…cfba21）。

### 3.2 本轮 tag 计划

| 阶段 | tag | GitHub 标记 | 内容 | 放行门槛 |
|---|---|---|---|---|
| Phase A（现在可发） | v0.3.0-beta.1 | pre-release = 是，latest = 否 | 全部 3 个资产 + 许可附件 + SHA256SUMS；macOS 标注"开发者预览/未真机验证"；Windows 0.2.5 游戏库 UI/icon 标注"待用户复测" | Windows 真机链路已验证、Windows 0.2.5 clean-folder self-test 32 PASS/0 FAIL/0 WARN、壳 host 验证通过、脚本 verify 通过、NOTICE 与随包内容一致 |
| Phase B（正式） | v0.3.0 | pre-release = 否，latest = 是 | 同资产集合（除非重新构建，否则沿用相同字节与哈希） | §4 验证状态表中所有"阻塞正式版"项通过（macOS 真机、Windows 0.2.5 用户真机复测、macOS 分发包自包含或 Lead 书面接受"开发者预览"定位） |
| 需要重发时 | v0.3.0-beta.2 / v0.3.0-beta.3 … 或 v0.3.1 | 按阶段 | 新 tag + 修好的资产 | 旧 tag 不移动；旧 release 保留并在正文标注 superseded |

版本命名理由：产品形态从"壳 + 内置游戏"切换到 launcher-first，组件版本已到 0.2.x，因此发布线用
0.3.x 区分，避免用户把 Release 版本与 Windows 启动器 0.2.5 混淆。Release 标题示例：
<code>3ds2apple v0.3.0-beta.1 — launcher-first (Windows 0.2.5 / macOS 0.2.4 build 7 / shell 0.2.3 build 11)</code>。

### 3.3 tag / 版本规则

- tag 形式：<code>v&lt;major&gt;.&lt;minor&gt;.&lt;patch&gt;[-suffix]</code>；用 annotated tag：
  <code>git tag -a v0.3.0-beta.1 -m "3ds2apple launcher-first beta 1"</code>，由 Lead push。
- 已 push 的 tag 不移动、不删除、不 force-push；tag 打错就发新 tag。
- 已上传的 Release 资产不静默替换；修正必须新版本。
- release notes 必须包含：组件版本表、资产 SHA-256、验证状态、已知问题、安装摘要、法律声明（§8.4 模板）。
- tag 与构建产物一一对应：记录构建机、构建命令、<code>git rev-parse HEAD</code>、脚本输出。

## 4. 验证状态表（截至 2026-11-16）

| # | 组件 / 链路 | 版本 | 状态 | 证据 | 阻塞正式版？ |
|---|---|---|---|---|---|
| 1 | Windows 全链路真机（导入→编译→Impactor 签名→devpush→启动） | 0.2.3 构建线 | **已验证** | 用户真机：Pokémon Y 约 57–60fps、AOT 100%、Metal GPU、HUD 开启；GPU 4–6ms/帧、present 10–11ms、screen readback 0、interpreted 0.04% | 否 |
| 2 | Windows 0.2.5 修复/新增：SMDH icon 花屏修复（pack 0x24C0 + tile 解码）、重新导入自动 --force 自愈旧封面、删除旧 Build Agent/builder 前端（exe 约小 1.24 MB）、便携数据目录/SMDH 元数据/硬件行 | 0.2.5 | **clean-folder self-test 32 PASS / 0 FAIL / 0 WARN（Lead 复核）**；游戏库 UI/icon 真机交互**待用户复测** | Lead 复核记录；launcher/windows/README、AGENTS.md §3 | 是（beta 需标注"待用户复测"） |
| 3 | Windows 单文件包 clean-folder self-test（32 项检查） | 0.2.5 | **已验证**：32 PASS / 0 FAIL / 0 WARN，SELF-TEST OK（portable 0.2.5、payload 326 files、shell 0.2.3/build11、Impactor v2.7.2、LLVM 21.1.8 PASS） | Lead 复核；out/launchers/SHA256SUMS-single.txt、clean-run-win/ | 否 |
| 4 | 壳模板 host 验证：MoltenVK.framework、空 schema-2 catalog、无 ROM/无 dylib | 0.2.3 / build 11 | **已验证** | out/shell/BUILD-EVIDENCE.md；verify-release.sh 2026-11-16 实跑 PASS | 否 |
| 5 | 壳 Simulator AOT smoke（软件渲染） | 0.2.3 | **已验证** | BUILD-EVIDENCE.md：dlopen + register OK，interpreted 0.00% | 否 |
| 6 | 壳真机 Metal 路径（嵌套 MoltenVK/GamePack 签名） | 0.2.3 | **已验证**（Windows 链路） | handoff §2 | 否 |
| 7 | macOS 启动器构建 / self-check / UI 截图 | 0.2.4 build 7 | **已验证**（macOS VM，selfcheck 207/207；新增重新导入 --force 自愈） | launcher/macos 构建日志、docs/macos-launcher.md | 否 |
| 8 | macOS 启动器真机（Mac + iPhone：Xcode 签名 + devicectl + 推送） | 0.2.4 build 7 | **未验证**（真实 iPhone 仍未验证） | Lead 说明；.internal/PROJECT_HANDOFF.md | 是 |
| 9 | macOS 分发包自包含性（工具是否内嵌） | 0.2.4 build 7 | **不足**：app-only zip 未内嵌 3ds2apple-pack/devpush/xcodegen，运行依赖仓库 checkout + Xcode + 单独构建工具 | launcher/macos/Sources/Toolchain.swift 检测顺序：bundle Resources/tools → checkout → PATH；0.2.4 zip 仍只有 .app（16 条目，无 tools/、无许可文本） | 是（或由 Lead 明确接受"开发者预览"定位） |
| 10 | Impactor/plumesign v2.7.2 官方二进制 SHA-256 固定且未被修改 | v2.7.2 | **已验证**（GitHub API release digests，2026-11-14） | builder/device/impactor.py、launcher/windows/vendor/impactor/PINS.json、scripts/impactor/licenses/README-bundled-tools.txt | 否 |
| 11 | LLVM 21.1.8 工具链 payload SHA-256 + 许可随包 | 21.1.8 | **已验证**（manifest pin；打包脚本 staging LICENSE.TXT） | tools/winbuild/llvm-manifest.json、launcher/windows/tools/prepare-dist-singlefile.sh | 否 |

## 5. 用户安装 / 签名步骤

### 5.1 通用前置

- 只从 <https://github.com/HFYKratos/3ds2apple/releases> 下载，并用同目录 <code>SHA256SUMS.txt</code>
  校验（Windows：<code>certutil -hashfile &lt;文件&gt; SHA256</code> 或 PowerShell
  <code>Get-FileHash -Algorithm SHA256</code>；macOS：<code>shasum -a 256 &lt;文件&gt;</code>）。
- 自备**合法取得、自行解密**的 ROM（.3ds/.cci）；本项目不提供 ROM、密钥、BIOS 或下载/破解支持。
- 发行包不含任何 Apple ID、证书或描述文件；Apple ID 只在 Impactor（Windows）或 Xcode（macOS）内输入。
- iPhone/iPad：iOS 16+、USB 数据线、开启开发者模式（Developer Mode）、信任电脑。

### 5.2 Windows（启动器 zip + Impactor v2.7.2 + plumesign）

1. 下载并校验 <code>3ds2apple-windows-single-0.2.5.zip</code> 与 <code>SHA256SUMS.txt</code>。
2. 解压到**可写目录**（不要放 Program Files 等只读位置。启动器会在 exe 旁创建
   <code>3ds2apple-data/</code> 保存 workspace 与内嵌工具；只读目录才回退到 %LOCALAPPDATA%）。
3. 该 exe 未做代码签名，Windows SmartScreen 可能提示"已保护你的电脑"：**只有哈希校验通过后**
   才点"更多信息 → 仍要运行"，并从官方 Release 下载。
4. 安装并启动 Microsoft Store 的 **Apple 设备**（或 iTunes），保证 Apple 移动设备服务可用
   （启动器与 plumesign 通过 usbmuxd 连接设备）。
5. 打开启动器 → Settings 运行 self-test（应为绿）；Library 导入自己的 ROM → Deploy 一键部署。
6. 首次部署会拉起 Impactor 登录 Apple ID（**只在 Impactor 内输入**；3ds2apple 不读取/不记录密码、
   token）；plumesign 负责对合成后的 IPA 签名安装；devpush 只把
   <code>GameRom.cci</code> + <code>GameInfo.json</code> 推进 <code>Documents/Games/&lt;TITLEID&gt;/</code>。
7. 免费 Apple ID 的签名有效期与数量限制由 Apple 决定（当前约 7 天有效、3 个 App、10 App ID/周；
   以 Apple 实际报错与 docs/windows-launcher.md §6 错误目录为准）；到期后重新部署/重签。付费开发者账号可延长。
8. 更新：覆盖安装保留 Documents 游戏数据；**卸载会清空** App 数据。
9. ROM 与合成后的含 pack IPA 属于用户数据：不要公开分享。

### 5.3 macOS（启动器 zip + Xcode 自动签名 + devicectl）

1. 下载并校验 <code>3ds2apple-launcher-0.2.4-macos-app.zip</code>；解压得到
   <code>3ds2apple-launcher.app</code>。
2. 该包未做 Developer ID 签名/公证：首次打开可能被 Gatekeeper 拦截 → 右键 → 打开，或
   "系统设置 → 隐私与安全性 → 仍要打开"。风险自担，只从官方 Release 下载。
3. 前置：macOS 13+、Xcode（验收环境 Xcode 26.6 / iOS 26.5 SDK；项目文档下限 Xcode 15+）、
   <code>xcodegen</code>（brew install xcodegen）。**0.2.4 build 7 分发包当前仍不自包含**：还需要仓库
   checkout 并提供已构建的 3ds2apple-pack / devpush（启动器会给出缺少工具的提示）。
4. 在 Xcode 登录自己的 Apple ID（Settings → Accounts）；设备开启开发者模式后，启动器自动读取
   Team ID，调用 xcodebuild/codesign/devicectl 完成签名安装。
5. 其余流程与 Windows 相同：导入自有 ROM → Deploy → 编译 pack → 合成 ROM-free IPA → 验证 →
   签名安装 → 推送 Documents。真机验收尚未完成（§4 第 8 项），此包定位为开发者预览。
6. 签名/安装问题参考 docs/macos-launcher.md；启动器不保存 Apple 凭据，也不实现签名/USB/AFC 本身。

## 6. 法务 / NOTICE / 第三方许可

### 6.1 本项目

- 代码与文档：**Apache-2.0**（根目录 LICENSE、NOTICE）。
- NOTICE 含：与 Nintendo 无关联声明、Nintendo 商标声明、无 ROM/密钥/系统文件声明、随包第三方说明。
- THIRD_PARTY.md 是完整第三方清单（含只读参考的 GPL 项目）。发布时 LICENSE/NOTICE/THIRD_PARTY.md
  会作为 Release 附件并纳入 SHA256SUMS。

### 6.2 真实随包的第三方（以仓库与打包脚本证据为准）

| 组件 | 许可 | 随包位置 | 当前状态 / 义务 |
|---|---|---|---|
| Impactor v2.7.2 | MIT（Copyright 2025 Samara M） | Windows payload 的 ThirdParty/Impactor（zip 内 exe 内嵌，首次运行解出） | 官方二进制原样、SHA-256 固定、MIT 文本随包（launcher/windows/vendor/impactor/、scripts/impactor/licenses/） |
| plumesign（Impactor v2.7.2 官方 release 内的 CLI） | MIT（同一 claration/impactor 仓库） | 同上 | 官方二进制原样、SHA-256 固定 |
| apple-codesign 0.29.0（内嵌在 Impactor 二进制内） | MPL-2.0 | Impactor 二进制内 | 不修改；MPL 文本随包；源码链接见 scripts/impactor/licenses/README-bundled-tools.txt |
| MoltenVK 1.4.2 | Apache-2.0 | 壳模板 <code>Frameworks/MoltenVK.framework</code>；macOS launcher <code>Contents/Resources/MoltenVK.framework</code> | 上游 <https://github.com/KhronosGroup/MoltenVK>；当前媒体包内未随附许可文本，由 Release 附件 NOTICE/THIRD_PARTY 覆盖，建议下一轮打包在 bundle 内补 licenses（§9 R4） |
| LLVM / Clang / LLD 21.1.8 | Apache-2.0 WITH LLVM-exception | Windows payload 的 Bin/llvm（官方 win64 release，单文件 exe 内嵌） | 原样、SHA-256 固定（tools/winbuild/llvm-manifest.json）；打包脚本 staged LICENSE.TXT；<https://llvm.org/LICENSE.txt> |
| .NET 10 runtime | MIT | Windows 单文件 exe（自包含发布） | 许可文本未随 exe 显式附上；repo NOTICE/THIRD_PARTY 提供链接，建议附件补齐（§9 R4） |
| Avalonia 12.1.5 | MIT | Windows 单文件 exe（UI 框架） | 同上 |
| Zakuro | MIT | 链接进壳（构建产物，不随源码仓库） | Cargo 依赖；MIT |
| 3dsrecomp | MIT（Cargo.toml 声明；上游无 LICENSE 文件） | 仅构建工具，不随包、不 vendored；生成 C 不发布 | 已注释说明；如上游补 LICENSE 再同步 |
| idevice（tools/devpush） | MIT（pinned commit 5171e34e…） | devpush 可执行文件随 Windows payload | MIT |
| S2Arm | Apache-2.0 | 仅 API/架构参考，未复制代码、不随包 | 参考声明 |

### 6.3 GPL 边界（只读参考，不随包）

any3ds（GPL-2.0）、Azahar（GPL-3.0）、Citra/TriAevum 等只作为架构/行为/文档参考，
**不复制、不改写、不移植任何代码或文本**，不在发行包中。详见 AGENTS.md §2.6 与 docs/related-projects.md。

### 6.4 硬性禁发清单（发布前逐项确认）

- [ ] 无 ROM/BIOS/密钥/系统文件/字体/游戏资源；
- [ ] 无生成 C、无 GamePack-*.dylib、无含 pack 的 IPA、无 Documents 游戏数据；
- [ ] 无含游戏画面的截图（仅启动器/壳的 UI 截图可进 release notes）；
- [ ] 无 Apple ID/密码/token/证书/profile/UDID；
- [ ] Impactor/plumesign/LLVM/MoltenVK 等二进制与官方一致、未被修改；
- [ ] LICENSE、NOTICE、THIRD_PARTY.md 与随包内容一致并已附到 Release。

### 6.5 用户义务

仅导入自己合法拥有并解密的游戏；不得再分发合成后的含 pack IPA（其中含你 ROM 的衍生代码）。
本项目与 Nintendo 无关联。

## 7. SideStore / AltStore 源：暂不适用的分析（含来源）

### 7.1 机制（已查证）

- AltStore 的"源"是一个自托管的 JSON 元数据文件，列出 app、版本和可下载的 IPA
  （[AltStore: Make a Source](https://faq.altstore.io/developers/make-a-source)）。
- SideStore 兼容 AltStore Sources；SideStore 本身是一个 iOS App，用**用户自己的 Apple ID** 对
  下载到的 App 重新签名后安装，并用本地 VPN 技巧完成安装、后台刷新以避免 7 天开发证书过期；
  免费账号限制 3 个 App/10 个 App ID（[SideStore FAQ](https://docs.sidestore.io/docs/faq)）。
- 源只负责"提供预编译 IPA 下载地址"；签名由 SideStore 在设备端用用户证书重签
  （[SideStore App Sources](https://docs.sidestore.io/docs/advanced/app-sources)）。

### 7.2 为什么 launcher-first 现在不适用

1. **源分发的是整包 IPA，而我们的可玩 IPA 必须按用户 ROM 在本机生成 GamePack 并签进 IPA。**
   源无法按用户 ROM 编译/注入，也不能分发含游戏衍生代码的 pack。
2. **ROM-free 壳单独不可玩**：空 schema-2 catalog，必须由桌面启动器合成 pack 并推送用户 ROM；
   SideStore 安装完壳之后无法完成这条链路。
3. **无 JIT/解释器契约 + iOS 签名约束**：设备端不能 dlopen 未签名代码；SideStore 只会重签下载到的
   IPA，不能注入新的 GamePack dylib；当前也没有"设备端 AOT 编译 + 签名注入"的受支持路径。
4. **法律边界**：向公共源上传含 pack 的 IPA = 公开游戏衍生代码；只传 ROM-free 壳则对用户没有可玩价值，
   容易误导入门用户。
5. **账号/刷新限制仍在 Apple/SideStore 层**（免费账号约 7 天、3 App），与桌面启动器 + Impactor/Xcode
   的流程重复，没有收益。

### 7.3 什么条件会改变结论（复核清单）

- (a) Apple 允许且 SideStore/AltStore 支持"设备端按用户 ROM 完成 AOT 编译并把生成代码签进已安装 App"
  （仍无 JIT）→ 重新评估；
- (b) 产品改为可分发的通用 AOT 运行时（不是"每 ROM 生成代码"）→ 需要产品/架构重决策，
  与当前 AOT-first 契约冲突；
- (c) 源生态支持"桌面构建器 + 每用户远程构建/签名"的合规流程（云端不得持有用户 ROM）→ 需法务/架构评估；
- (d) SideStore/AltStore 提供"安装壳 + 接收本机推送 ROM/pack"的官方机制 → 重新评估。

### 7.4 当前结论

不创建 AltSource、不在 README/文档发布源 URL；只提供 GitHub Releases 链接。社区询问时引用本节。

## 8. 发布 checklist（Lead 可执行）

### 8.1 发布前 gate

- [ ] git 工作树已收敛：<code>git status</code> 只含预期提交；记录 <code>git rev-parse HEAD</code>。
- [ ] 组件版本号一致且已 bump：launcher/windows/Directory.Build.props、launcher/macos/project.yml 与
      app Info.plist、ios/app/project.yml（壳 manifest 同步）。
- [ ] 三个构建产物存在于 out/launchers/ 与 out/shell/；与各自 BUILD-EVIDENCE/README 记录的哈希一致。
- [ ] <code>bash scripts/release/verify-release.sh</code> 对三件套通过（§8.3）。
- [ ] NOTICE/THIRD_PARTY/LICENSE 与随包内容一致（§6.2/§6.4 逐项）。
- [ ] beta/正式版门槛：§3.2 表格；未验证项写入 release notes。

### 8.2 构建（产物由各 owner 提供，本任务不重新构建）

~~~bash
# Windows 启动器（单文件，内嵌壳模板/Impactor/LLVM）：
cd launcher/windows
DOTNET_ROOT=$HOME/.dotnet10 dotnet build Launcher.slnx -c Release
THREEDS2APPLE_LLVM_DIR=<llvm 根> bash tools/prepare-dist-singlefile.sh
# -> out/launchers/3ds2apple-windows-single-0.2.5.zip

# 手机壳模板（macOS VM）：
PATH=/usr/local/bin:$PATH scripts/build-ios-app.sh --keep-project
MOLTENVK_FRAMEWORK=<MoltenVK.framework> scripts/package-ipa.sh \
  ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple-shell --out-dir out/shell --require-moltenvk
# -> out/shell/3ds2apple-shell.ipa + manifest.json

# macOS 启动器：
bash launcher/macos/scripts/vm-build.sh
# -> out/launchers/3ds2apple-launcher-0.2.4-macos-app.zip
~~~

### 8.3 收集、哈希与自检（本任务脚本，实跑通过）

~~~bash
# 1) 收集并生成 SHA256SUMS.txt（幂等、非破坏；会自动调用 verify-release.sh）
#    out/launchers 仍保留旧版本 zip 时自动发现会报"multiple candidates"：
#    显式传新资产路径（2026-11-16 基线：Windows 0.2.5 + macOS 0.2.4 build 7）
bash scripts/release/assemble-release.sh --version v0.3.0-beta.1 \
  --windows-zip out/launchers/3ds2apple-windows-single-0.2.5.zip \
  --macos-zip out/launchers/3ds2apple-launcher-0.2.4-macos-app.zip \
  --shell-ipa out/shell/3ds2apple-shell.ipa
# -> out/release/v0.3.0-beta.1/

# 2) 独立只读复验（发布门禁；--release-dir 模式要求三件套 + SHA256SUMS 齐全）
bash scripts/release/verify-release.sh --release-dir out/release/v0.3.0-beta.1

# 3) 标准 sha256sum 交叉验证
cd out/release/v0.3.0-beta.1 && sha256sum -c SHA256SUMS.txt

# 可选：dry-run 只校验不写盘（同样建议显式传路径）
bash scripts/release/assemble-release.sh --version v0.3.0-beta.1 --dry-run \
  --windows-zip out/launchers/3ds2apple-windows-single-0.2.5.zip \
  --macos-zip out/launchers/3ds2apple-launcher-0.2.4-macos-app.zip \
  --shell-ipa out/shell/3ds2apple-shell.ipa
~~~

脚本行为（详见脚本头部注释）：assemble 缺文件直接报错；shell IPA 会与
out/shell/manifest.json 的 sha256/bytes 交叉校验并重命名为
<code>3ds2apple-shell-&lt;ver&gt;-build&lt;n&gt;.ipa</code>；重复运行同输入为 no-op（仅重写相同
SHA256SUMS）；不同字节默认拒绝覆盖（需 --force）；不删除/不移动任何文件。

### 8.4 Release notes 模板（正文）

~~~markdown
# 3ds2apple v0.3.0-beta.1 — launcher-first

把自有的 Nintendo 3DS 游戏以 AOT 原生 ARM64 带到 iPhone/iPad：桌面启动器编译 GamePack，
手机壳运行编译后的原生代码（无 CPU JIT、无解释器兜底）。

## 组件版本
| 组件 | 版本 |
|---|---|
| Windows 启动器 | 0.2.5 |
| macOS 启动器 | 0.2.4 build 7（开发者预览：需 Xcode + 仓库工具链，未真机验证） |
| 手机壳（ROM-free 模板） | 0.2.3 / build 11 |

## 资产与校验
| 文件 | SHA-256 |
|---|---|
| （从 SHA256SUMS.txt 逐行复制） | |

## 安装
1. 下载对应启动器包与 SHA256SUMS.txt，校验后使用。
2. Windows：解压启动器 → 导入自有 ROM → Deploy（Impactor 内登录自己的 Apple ID）。
3. macOS：见 docs/release-launcher-first.md §5.3（Xcode 自动签名 + devicectl）。
4. 手机壳模板不需要单独安装：启动器会合成并签名安装，再推送数据。

## 验证状态 / 已知问题
- 已验证：Windows 真机全链路（导入→部署→启动），AOT 100%、Metal GPU（Pokémon Y 57–60fps 量级）。
- 已自检：Windows 0.2.5 clean-folder self-test 32 PASS / 0 FAIL / 0 WARN（含 SMDH icon 花屏修复与重新导入自愈）；游戏库 UI/icon 真机交互待用户复测。
- 未验证：macOS 启动器真机；macOS 0.2.4 build 7 分发包当前不自包含（需仓库 checkout 工具 + Xcode）。
- 已知：启动器 exe 未代码签名（SmartScreen）、macOS app 未公证（Gatekeeper）；免费 Apple ID 约 7 天有效；
  部分游戏下屏可能出现粉色/斜纹（已记录，待修）。

## 法律
本项目 Apache-2.0；不提供 ROM、解密密钥、BIOS 或游戏资源；请只导入你合法拥有的游戏，
且不要分享合成后的含 pack IPA。Nintendo 3DS 为 Nintendo 商标，本项目与其无关联。
第三方许可见 NOTICE / THIRD_PARTY.md 与本附件。
~~~

> release notes 里不要放含游戏画面的截图；只可放启动器/壳的非游戏 UI 截图。

### 8.5 上传（二选一，由 Lead 执行）

- 网页：GitHub → Releases → Draft a new release → 选择/创建 tag
  <code>v0.3.0-beta.1</code> → 勾选 "Set as a pre-release"（正式版不勾）→ 上传
  <code>out/release/v0.3.0-beta.1/</code> 下全部文件 → 正文粘贴 §8.4 → Publish release。
- gh CLI：
  <code>gh release create v0.3.0-beta.1 --prerelease --title "3ds2apple v0.3.0-beta.1 — launcher-first" --notes-file &lt;notes.md&gt; out/release/v0.3.0-beta.1/*</code>
  （正式版去掉 --prerelease，并确认 latest 标记策略；不要上传目录外的额外文件。）

### 8.6 发布后校验（独立下载，避免只信本地文件）

~~~bash
gh release download v0.3.0-beta.1 -D /tmp/release-verify
cd /tmp/release-verify && sha256sum -c SHA256SUMS.txt
diff -u /tmp/release-verify/SHA256SUMS.txt /path/to/out/release/v0.3.0-beta.1/SHA256SUMS.txt
~~~

- [ ] 资产数量/命名与 SHA256SUMS 一致；页面无未列文件；
- [ ] pre-release / latest 标记正确；
- [ ] 正文链接可点（docs、Releases、许可链接）；
- [ ] 页面与附件无 ROM/密钥/游戏画面/凭据；
- [ ] 把哈希、命令输出与 release URL 记入 .internal/PROJECT_HANDOFF.md（唯一交接文件）。

### 8.7 回滚 / 下架规则

| 情况 | 动作 |
|---|---|
| 文案/链接/notes 小错 | gh release edit 更新正文；不新增/替换资产 |
| 漏附件或资产内容需变更 | 发布新 tag（如 v0.3.0-beta.2），旧 release 保留并标注 superseded；不覆盖已上传资产 |
| 资产有安全/崩溃/安装问题 | 立即 gh release delete-asset 移除问题资产（或把 release 改为 draft 隐藏），发布新 tag 修复，正文说明 |
| 法律/侵权风险（出现 ROM/密钥/游戏代码） | 立即删除相关资产并公开说明；记录时间线；通知维护者；重跑 §8.1 gate 后再发 |
| tag 打错/需改 tag | 新 tag；已 push tag 不移动不删除，必要时把旧 release 标注 deprecated |

通用原则：**已发布 tag 与资产不可变；只增不改；任何下架/回滚都记录在 HANDOFF 与 release 正文。**

## 9. 风险与待决事项

| 编号 | 风险 / 待决 | 影响 | 建议 |
|---|---|---|---|
| R1 | macOS 启动器真机未验证 | 阻塞 v0.3.0 正式版 | beta 标注"开发者预览"；真机验收后转正式 |
| R2 | Windows 0.2.5 游戏库 UI / ROM icon 真机交互待用户复测（self-test 32 PASS 已过） | 阻塞正式版 | 用户真机复测通过后更新 §4；beta notes 标注 |
| R3 | macOS 分发包不自包含（工具未内嵌） | 用户可能无法直接用 zip 部署 | launcher-macos owner 打包时内嵌 tools；或 Lead 明确接受"需仓库 checkout"的预览定位 |
| R4 | 许可文本未随媒体包（MoltenVK 在壳/APP 内、.NET/Avalonia 在单文件 exe 内） | Apache-2.0/MIT 文本随附义务 | 当前由 Release 附件 NOTICE/THIRD_PARTY 覆盖；下一轮打包在 bundle 内补 licenses 目录 |
| R5 | 无代码签名（exe SmartScreen / macOS Gatekeeper） | 用户信任与误杀 | 文档写明校验哈希；如需消除警告要购买签名证书，属产品决策 |
| R6 | 部分游戏下屏粉色/斜纹（known issue） | 体验 | 不阻塞分发；release notes 标注，待 presenter/2D 修复 |
| R7 | SideStore 结论依赖当前架构 | 未来可能过期 | 架构变化时按 §7.3 复核 |

需 Lead 明确：tag 名（v0.3.0-beta.1 / v0.3.0）；beta 是否包含 macOS 资产（建议包含并标注 experimental）；
是否把 LICENSE/NOTICE/THIRD_PARTY 作为附件（本方案要求是）；macOS 自包含打包排期。

## 10. 相关文件

- scripts/release/assemble-release.sh — 收集资产、生成 SHA256SUMS、自动调用 verify
- scripts/release/verify-release.sh — 只读发布门禁（zip/IPA 内容、catalog、ROM/pack 检查、SHA 校验）
- NOTICE、THIRD_PARTY.md、LICENSE — 许可与第三方清单
- out/shell/BUILD-EVIDENCE.md、out/shell/manifest.json — 壳模板构建证据（git 忽略）
- docs/windows-launcher.md、docs/macos-launcher.md、docs/launcher-flow-v2.md — 启动器/签名流程
- builder/device/impactor.py、scripts/impactor/licenses/README-bundled-tools.txt — Impactor/plumesign 固定与来源
- tools/winbuild/llvm-manifest.json — LLVM 21.1.8 固定与许可链接
- README.md — 下载入口（只放通用 Releases 链接）

## 11. 附录：2026-11-16 基线实跑记录（task-9 新资产，装配目录已生成）

环境：WSL2 Linux x86_64，bash 5.x，unzip 6.00，sha256sum；脚本 shellcheck 0.10.0 干净。

~~~text
$ bash scripts/release/assemble-release.sh --version v0.3.0-beta.1 --dry-run \
    --windows-zip out/launchers/3ds2apple-windows-single-0.2.5.zip \
    --macos-zip out/launchers/3ds2apple-launcher-0.2.4-macos-app.zip \
    --shell-ipa out/shell/3ds2apple-shell.ipa
[assemble] DRY-RUN: nothing will be written
[assemble] release tag: v0.3.0-beta.1
[assemble] release dir: .../out/release/v0.3.0-beta.1
[plan] 3ds2apple-windows-single-0.2.5.zip           <- .../out/launchers/3ds2apple-windows-single-0.2.5.zip
[plan] 3ds2apple-launcher-0.2.4-macos-app.zip       <- .../out/launchers/3ds2apple-launcher-0.2.4-macos-app.zip
[plan] 3ds2apple-shell-0.2.3-build11.ipa            <- .../out/shell/3ds2apple-shell.ipa
[plan] LICENSE / NOTICE / THIRD_PARTY.md            <- 仓库根目录
[plan] SHA256SUMS.txt over the 6 files above
[PASS] windows zip: single entry 3ds2apple-launcher.exe (148817314 bytes, sha256 b9b2a0b0...)
[PASS] macOS zip: one .app bundle 3ds2apple-launcher.app (9 files, 5495796 bytes, sha256 8c34398f...)
[PASS] shell IPA: Payload/3ds2apple.app, MoltenVK 4822128 bytes, empty schema-2 GameCatalog (5487675 bytes, sha256 831357db...)
verify-release: 3 passed, 0 failed, 1 skipped
verify-release: OK
DRY-RUN OK: 6 files (159820589 bytes) would be written to .../out/release/v0.3.0-beta.1
~~~

2026-11-16 用新资产在 <code>out/release/v0.3.0-beta.1/</code> 真实执行（该目录 git 忽略）：

~~~text
$ bash scripts/release/assemble-release.sh --version v0.3.0-beta.1 \
    --windows-zip out/launchers/3ds2apple-windows-single-0.2.5.zip \
    --macos-zip out/launchers/3ds2apple-launcher-0.2.4-macos-app.zip \
    --shell-ipa out/shell/3ds2apple-shell.ipa
[assemble] added 3ds2apple-windows-single-0.2.5.zip
[assemble] added 3ds2apple-launcher-0.2.4-macos-app.zip
[assemble] added 3ds2apple-shell-0.2.3-build11.ipa
[assemble] added LICENSE / NOTICE / THIRD_PARTY.md
[PASS] windows zip: single entry 3ds2apple-launcher.exe (148817314 bytes, sha256 b9b2a0b0...)
[PASS] macOS zip: one .app bundle 3ds2apple-launcher.app (9 files, 5495796 bytes, sha256 8c34398f...)
[PASS] shell IPA: Payload/3ds2apple.app, MoltenVK 4822128 bytes, empty schema-2 GameCatalog (5487675 bytes, sha256 831357db...)
[PASS] release dir: no ROM/key/GamePack-looking files
[PASS] SHA256SUMS: 6 listed file(s) verified
[PASS] SHA256SUMS: covers every file in .../out/release/v0.3.0-beta.1 (6 file(s))
verify-release: 6 passed, 0 failed, 0 skipped
verify-release: OK
assemble-release: OK — 6 files, 159820589 bytes
~~~

<code>verify-release.sh --release-dir out/release/v0.3.0-beta.1</code> 独立复验同样 6 passed / 0 failed；
<code>sha256sum -c SHA256SUMS.txt</code> 6/6 OK；第二次 assemble 为 0 added / 6 unchanged（幂等）。
由于 out/launchers 仍保留旧 0.2.4 Windows / 0.2.3 macOS zip（历史备份），本次用
--windows-zip/--macos-zip 显式指定新文件。负例（双条目 Windows zip、含 GamePack 的壳 IPA、
被篡改的 SHA256SUMS）均以退出码 1 拒绝。
