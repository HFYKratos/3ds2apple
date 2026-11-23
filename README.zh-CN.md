<p align="center"><img src="docs/assets/readme-icon.png" width="128" alt="3ds2apple 图标"></p>

<h1 align="center">3ds2apple</h1>

<p align="center">
  <a href="README.md">EN</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <a href="#下载"><b>下载</b></a> ·
  <a href="https://hfykratos.github.io/3ds2apple/">官网</a> ·
  <a href="https://hfykratos.github.io/3ds2apple/press/">媒体资料包</a> ·
  <a href="https://github.com/HFYKratos/3ds2apple/releases">版本发布</a> ·
  <a href="https://github.com/HFYKratos/3ds2apple/discussions">讨论</a> ·
  <a href="CONTRIBUTING.md">参与贡献</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="许可证：Apache-2.0"></a>
  <a href="https://github.com/HFYKratos/3ds2apple/releases/tag/v0.1.6"><img src="https://img.shields.io/badge/release-v0.1.6-brightgreen" alt="最新版本：v0.1.6"></a>
  <a href="https://github.com/HFYKratos/3ds2apple/releases/latest"><img src="https://img.shields.io/badge/platforms-iOS%2016%2B%20%C2%B7%20Windows%2010%2F11%20%C2%B7%20macOS%2013%2B-blue" alt="平台：iOS 16+、Windows 10/11、macOS 13+"></a>
  <a href="https://github.com/HFYKratos/3ds2apple/releases"><img src="https://img.shields.io/github/downloads/HFYKratos/3ds2apple/total?label=downloads" alt="GitHub 下载量"></a>
  <a href="https://github.com/HFYKratos/3ds2apple/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/HFYKratos/3ds2apple/ci.yml?branch=main&label=CI" alt="CI 状态"></a>
</p>

**让你自有的 Nintendo 3DS 游戏以原生方式运行在 iPhone 与 iPad 上——AOT 编译的 ARM64、经 MoltenVK 走 Metal，没有 CPU JIT，也没有解释器兜底。**

## 下载

<p align="center">
  <a href="https://github.com/HFYKratos/3ds2apple/releases/download/v0.1.6/3ds2apple-0.1.6-windows-x64.zip"><img src="https://img.shields.io/badge/Download-Windows%20x64-0078D6?style=for-the-badge&logo=windows&logoColor=white" alt="下载 Windows 启动器"></a>
  <a href="https://github.com/HFYKratos/3ds2apple/releases/download/v0.1.6/3ds2apple-0.1.6-macos-universal.zip"><img src="https://img.shields.io/badge/Download-macOS%20universal-000000?style=for-the-badge&logo=apple&logoColor=white" alt="下载 macOS 启动器"></a>
  <a href="https://github.com/HFYKratos/3ds2apple/releases"><img src="https://img.shields.io/badge/All%20releases-GitHub-lightgrey?style=for-the-badge&logo=github&logoColor=white" alt="在 GitHub 查看全部版本"></a>
</p>

<p align="center"><sub>Windows 10/11 启动器（已验证路径）· macOS 13+ 启动器（开发者预览，见 <a href="https://github.com/HFYKratos/3ds2apple/issues/1">#1</a>）· iOS App 由启动器用你自己的 Apple ID 合成、签名并安装，因此没有单独的 iOS 下载。</sub></p>

<p align="center">
  <img src="docs/assets/hero.png" width="880" alt="3ds2apple 在 iPhone 与 iPad 上运行，以及 Windows 与 macOS 启动器">
</p>

> [!NOTE]
> 3ds2apple 是免费开源软件（Apache-2.0）。启动器与 iOS App 不附带任何游戏、密钥或 BIOS：请用你合法拥有并自行导出的已解密 ROM 构建自己的游戏库。

## 30 秒说明

3ds2apple 是面向自有 Nintendo 3DS 游戏的原生移植流水线，而不是模拟器 App。把你自行导出的已解密 ROM 导入 Windows 或 macOS 启动器：3dsrecomp 把 3DS 代码翻译成 C，本机的 LLVM 或 Apple clang 工具链为每款游戏编译出一个 ARM64 `GamePack`，启动器再合成不含 ROM 的基础壳 IPA、用你自己的 Apple ID 签名安装，最后只把游戏数据（`GameRom.cci` + `GameInfo.json`）推送到 App 的 Documents 目录。手机端由 Zakuro HLE 运行时直接执行这些原生代码，PICA200 GPU 调用经 MoltenVK 转成 Metal。一个 App 装下整个游戏库，暂停菜单里就能处理屏幕布局、虚拟按键、即时存档与诊断。不包含任何游戏、密钥或 BIOS——请自备游戏。

## 演示

<p align="center">
  <img src="docs/assets/demo.gif" width="720" alt="合成演示轮播：竖屏按键、横屏按键、暂停菜单虚拟按键选项与屏幕布局设置">
</p>

<p align="center"><sub>合成预览，不含游戏数据：竖屏按键 → 横屏按键 → 暂停菜单虚拟按键选项 → 屏幕布局设置。</sub></p>

## 0.1.6 新特性

- **自定义屏幕布局进 GPU。** 任意矩形、四向屏幕旋转与上下屏交换都由 GPU presenter 绘制，无需屏幕回读——0.1.5 的较慢回读路径已成为历史。
- **更多屏幕按键。** 快进切换按钮（2x 开/关），以及可编辑的快速存档、快速读档与交换屏幕按钮，与现有虚拟按键并列。
- **按键显隐按横竖方向。** 「切换控制」现在按当前方向分别编辑；C 杆、ZL、ZR 在横竖两个方向都默认隐藏，竖屏还默认隐藏十字键。大小与透明度仍是全局设置。
- **全屏布局编辑器不再抖。** 拖动移动、双指缩放，本地预览在松手时一次提交，布局不再抖动；编辑横向布局时强制横屏。
- **Metal HUD 默认关闭。** 系统 GPU/FPS 浮层从 0.1.6 起默认关闭（已有安装一次性迁移）；可在 设置 → 性能 里打开。
- **更聪明的 Windows 部署。** 启动器先读取手机已安装的 App 与游戏：已是最新则跳过；覆盖更新保留游戏数据、存档与 ROM；手机上有本机库缺失的游戏时先列出并确认，且绝不会删除。

## 功能一览

<table>
  <tr>
    <td align="center" width="25%">⚡<br><b>原生 AOT，不是模拟</b><br><sub>每款游戏在运行前都被重新编译成 ARM64；正式路径上既没有 CPU JIT，也没有解释器兜底。</sub></td>
    <td align="center" width="25%">📚<br><b>一个 App，整个游戏库</b><br><sub>勾选的每款游戏都是同一個已签名 App 里的 GamePack；推送的游戏数据在更新后仍然保留。</sub></td>
    <td align="center" width="25%">🎮<br><b>完整 New 3DS 按键</b><br><sub>十字键、A/B/X/Y、L/R、ZL/ZR、Start/Select、真模拟量 Circle Pad 与 C 杆；可编辑的快进、快速存档、快速读档与交换屏幕按钮；支持 MFi、Xbox、DualSense 手柄。</sub></td>
    <td align="center" width="25%">🧭<br><b>横屏 6 种 + 竖屏 3 种布局，全部走 GPU</b><br><sub>横屏 6 种、竖屏 3 种预设，加上任意自定义矩形——全部由 GPU presenter 绘制、每帧零回读；含四向旋转与上下屏交换。</sub></td>
  </tr>
  <tr>
    <td align="center" width="25%">✏️<br><b>游戏内编辑按键布局</b><br><sub>暂停后在画面上拖动按键，点中央「完成」保存；支持逐键显隐、10%–200% 大小与透明度。</sub></td>
    <td align="center" width="25%">💾<br><b>存档与即时存档</b><br><sub>电池存档保存在 App 容器内，每款游戏三个即时存档槽，存档管理器可导出与导入存档。</sub></td>
    <td align="center" width="25%">⏩<br><b>快进、帧率与 HUD</b><br><sub>2x 快进切换按钮、可编辑的快速存档与快速读档、可选的帧率胶囊、系统 Metal HUD（默认关闭），以及一键导出诊断。</sub></td>
    <td align="center" width="25%">🖥️<br><b>Windows 与 macOS 启动器</b><br><sub>在同一个窗口里导入 → 编译 → 签名 → 安装 → 推送；Windows 路径不需要 Mac，并支持保留游戏数据的增量部署。</sub></td>
  </tr>
</table>

## 屏幕布局：横屏 6 种、竖屏 3 种

**设置 → 显示 → 屏幕布局** 里横竖各自独立。

- **横向屏幕布局（6 种）**：大屏幕 · 单个屏幕 · 并排屏幕 · 混合式屏幕 · 原始 · 自定义布局。
- **纵向屏幕布局（3 种）**：默认 · 原始 · 自定义布局。

**混合式屏幕**是一个大的上屏加右侧上下两个小屏；竖屏**默认**把上屏满宽放在下屏上方。

所有预设排列都由 GPU presenter 绘制——走 Metal 路径，每帧零屏幕回读。**自定义布局**把两块屏幕放在任意矩形：可以在数值页按百分比编辑 X/Y/宽/高（下方实时预览），也可以拖动屏幕；自定义布局同样由 GPU presenter 绘制（任意矩形、四向旋转与上下屏交换），不再退回较慢的回读路径。自定义布局仍从下一次加载游戏起生效。

屏幕旋转与界面方向保留，渲染分辨率（1x–4x）仍在下次载入游戏时生效。0.1.5 已移除旧的画面比例与整数缩放开关。

## 虚拟按键与暂停菜单

虚拟按键是完整的 New 3DS 键位：十字键、A/B/X/Y、L/R、ZL/ZR、Start/Select、真模拟量的 Circle Pad 和 New 3DS C 杆。Circle Pad 输出真正的模拟量（每轴 -1…1，带小死区，手指静止时精确为 0），不是第二套十字键；C 杆同理。默认位置与尺寸参考 ModernCenteredX2 Delta 皮肤的几何：竖屏把整组按键放在游戏画面下方的空白区，D-pad 画成单个十字键——四个方向按压区，按住可滑动换向——不再是四个独立按键；横屏沿用皮肤风格的位置、浮在画面上。

手柄左摇杆映射 Circle Pad、右摇杆映射 C 杆，L2/R2 映射 ZL/ZR，多根手指可以同时按按键、拖摇杆。

暂停游戏后的 **虚拟按键选项** 卡负责自定义：

- **显示/隐藏虚拟按键**、显示帧率、触摸反馈。
- **屏幕按键**——快进切换按钮（2x 开/关），以及可编辑的快速存档、快速读档与交换屏幕按钮。
- **编辑布局**——在暂停画面上直接拖动按键；中央 **完成** 保存当前方向并继续游戏。
- **切换控制**——按当前方向分别设置显隐：C 杆、ZL、ZR 两个方向都默认隐藏，十字键竖屏默认隐藏。
- **调整大小**——每个按钮或组 10%–200%，默认 100%（全局）。
- **调整透明度** 与 **重置**。

显隐按横竖方向分别设置（「切换控制」编辑当前方向）；大小与透明度是全局设置，横竖屏位置各自独立。C 杆需要游戏本身读取 New 3DS 摇杆，且壳必须用当前运行库构建（用 `scripts/build-zakuro-ios.sh` 从源码构建的壳已包含）。

## 游戏内编辑布局

暂停任意游戏后打开 **虚拟按键选项 → 编辑布局**：每个控件都有自己的命中区，你拖动的就是抓住的那一个；中央 **完成** 保存当前方向并继续游戏。同一张卡里还有逐键显隐、10%–200% 大小与透明度，以及 **重置**。竖屏与横屏的位置分开保存。

屏幕布局在 **设置 → 显示 → 屏幕布局** 里单独编辑：按百分比填 X/Y/宽/高并提供实时预览，或使用全屏拖拽编辑器（拖动移动、双指缩放；预览跟手、松手才提交，布局不再抖动）。编辑横向自定义布局时会强制横屏。预设立即生效；自定义屏幕布局从下一次加载游戏起生效。

## 截图

**桌面启动器**——真实 App 截图；游戏库条目为合成演示条目，不含任何游戏画面。

| Windows 启动器 | Windows 启动器（简体中文） | macOS 启动器 |
|:---:|:---:|:---:|
| <img src="launcher/windows/docs/ui/v4-library-en.png" width="330" alt="Windows 启动器游戏库，英文界面"> | <img src="launcher/windows/docs/ui/v4-library-zh.png" width="330" alt="Windows 启动器游戏库，中文界面"> | <img src="launcher/macos/screenshots/launcher-library-empty-dark-en.png" width="330" alt="macOS 启动器空游戏库，深色主题"> |
| 游戏库（English） | 游戏库（中文） | 空游戏库（深色） |

**iOS App**——虚拟按键的合成预览；不含游戏数据。

| 竖屏 | 横屏 |
|:---:|:---:|
| <img src="docs/assets/portrait.png" width="280" alt="竖屏虚拟按键合成预览"> | <img src="docs/assets/landscape.png" width="520" alt="横屏虚拟按键合成预览"> |
| 竖屏按键 | 横屏按键 |

## 快速开始

**前提**：你自有的已解密 3DS ROM、开启开发者模式的 iOS 16+ iPhone/iPad、USB 数据线，以及用于签名的你自己的 Apple ID。不包含任何游戏数据。

1. **下载启动器。** Windows 10/11：解压 zip 到可写目录（不要放 `Program Files`），运行 `3ds2apple-launcher.exe`；安装 *Apple 设备*，保证手机可通过 USB 访问。macOS 13+：解压得到 `3ds2apple-launcher.app`（开发者预览，还需要 Xcode 15+、`xcodegen`、仓库 checkout 以及构建好的工具）。
2. **导入并部署。** 导入你自有的已解密 `.3ds`/`.cci`，勾选游戏，按唯一的一键部署按钮：启动器为每款游戏编译 GamePack、合成不含 ROM 的 IPA、用你自己的 Apple ID 签名安装，然后只推送游戏数据。
3. **开玩。** 在手机上打开 App。增删游戏重新部署即可；已推送的游戏数据在重装与更新后保留，彻底卸载会清空。

完整流程（含 macOS 配置与签名限制）见[安装与上手](#安装与上手)。

## 常见问题

### 3ds2apple 是模拟器吗？

不是。它是一条原生移植与重编译流水线：每款游戏先被翻译成 C，提前编译为 ARM64，再通过 Zakuro HLE 运行时直接执行。正式路径上没有 CPU JIT，也没有解释器兜底。

### 所有游戏都能玩吗？

兼容性因游戏而异。部分游戏可能无法启动或渲染异常，个别游戏的某些菜单也可能渲染异常——见 issue [#2](https://github.com/HFYKratos/3ds2apple/issues/2)。本项目不提供兼容性或性能保证；欢迎带上 16 位 title ID 反馈。

### 从哪里获取 ROM、密钥或 BIOS？

本项目不提供。3ds2apple 不附带任何游戏数据，也不提供 ROM、BIOS、密钥下载或盗版支持；只支持你合法拥有并自行导出的已解密 ROM。

### 需要 Mac 吗？

已验证的 Windows 路径不需要。macOS 启动器是**开发者预览**：需要 macOS 13+、已登录 Apple ID 的 Xcode 15+、`xcodegen`、仓库 checkout 以及构建好的工具，而且真机安装尚未由维护者验证（issue [#1](https://github.com/HFYKratos/3ds2apple/issues/1)）。

### App 上架 App Store 了吗？

没有。启动器用你自己的 Apple ID 合成并签名 App（Windows 用内置官方 Impactor，macOS 用 Xcode 自动签名），再通过 USB 安装。3ds2apple 与 Nintendo、Apple 均无关联，也不代表其立场。

### 为什么 App 过一周左右就打不开了？

免费 Apple ID 每台设备限 3 个 App、签名约 7 天；到期重新部署即可续签。付费开发者账号没有这些限制。

### 重新部署会删掉存档或游戏数据吗？

游戏数据位于 `Documents/Games/<TITLEID>/`，存档与即时存档位于 App 容器内。已推送的数据与存档在重装和更新后保留；彻底卸载 App 会删除它们，所以卸载前请先备份需要保留的内容。你电脑上的 ROM 不受影响。

### 性能如何？

维护者在真机 iPhone 上经 Windows 启动器链路运行**某款商业游戏**实测约 57–60 fps，AOT 100%，Metal GPU 渲染；这只是维护者对那一款游戏的实测，不是保证——兼容性与性能因游戏而异。

### 自定义屏幕布局比预设慢吗？

不再慢了。从 0.1.6 起，自定义布局也由 GPU presenter 绘制——任意矩形、四向旋转与上下屏交换——与预设一样走零回读的 Metal 路径。自定义布局仍从下一次加载游戏起生效。

## 法律与限制

- **自备游戏。** 不提供也不链接任何 ROM、密钥、BIOS、系统文件或游戏资源；不提供盗版支持。请只使用你合法拥有并自行导出的已解密 ROM。
- **无关联、无背书。** 3ds2apple 与 Nintendo、Apple 均无关联、未获赞助或背书，也不通过 App Store 分发；请用你自己的 Apple ID 签名并安装。
- **不做保证。** 兼容性与性能因游戏而异：部分游戏可能无法启动或渲染异常，个别游戏的某些菜单也可能渲染异常（issue [#2](https://github.com/HFYKratos/3ds2apple/issues/2)）。不提供兼容性或性能保证。
- **macOS 是开发者预览。** 分发包尚不自包含，真机安装也还未由维护者验证（issue [#1](https://github.com/HFYKratos/3ds2apple/issues/1)）；Windows 是已验证路径。
- **自定义屏幕布局自 0.1.6 起走 GPU 路径。** 任意矩形、四向旋转与上下屏交换都由 GPU presenter 绘制（0.1.5 及更早使用较慢的回读路径）；自定义布局仍从下一次加载游戏起生效。
- **设计上没有 CPU JIT。** 正式路径是 AOT 代码 + Zakuro HLE 运行时，没有解释器兜底。

## 项目链接

| | |
|---|---|
| **官网** | <https://hfykratos.github.io/3ds2apple/> |
| **媒体资料包** | <https://hfykratos.github.io/3ds2apple/press/> |
| **下载** | [GitHub Releases](https://github.com/HFYKratos/3ds2apple/releases) |
| **问题反馈** | <https://github.com/HFYKratos/3ds2apple/issues> |
| **讨论** | <https://github.com/HFYKratos/3ds2apple/discussions> |
| **参与贡献** | [CONTRIBUTING.md](CONTRIBUTING.md) |
| **许可证** | [Apache-2.0](LICENSE) |

## 平台支持

| 平台 | 支持情况 |
|---|---|
| **iPhone / iPad** | iOS 16 及以上。一个 App 承载游戏库、游戏内菜单、完整 New 3DS 虚拟按键与游戏内布局编辑、横屏 6 种/竖屏 3 种屏幕布局、即时存档与帧率显示。 |
| **Windows** | Windows 10/11 x64。单文件自包含启动器；无需 Mac 即可编译、签名、安装、推送。**已验证路径。** |
| **macOS** | macOS 13+（Intel + Apple 芯片）。SwiftUI 启动器，使用 Xcode 签名；分发包尚不自包含，真机安装尚未由维护者验证。**开发者预览。** |
| **构建主机** | Windows（内置 LLVM/LLD）或 macOS（Apple clang + Xcode）。 |

## 安装与上手

**前提**：你自有的已解密 3DS ROM、开启开发者模式的 iOS 16+ iPhone/iPad、USB 数据线，以及用于签名的你自己的 Apple ID。不包含任何游戏数据。

### Windows 启动器

1. 下载 `3ds2apple-<version>-windows-x64.zip`，解压到可写目录（不要放 `Program Files`）。安装 *Apple 设备*，保证手机可通过 USB 访问。
2. 运行 `3ds2apple-launcher.exe`（未做代码签名；校验 digest 后在 SmartScreen 选 *更多信息 → 仍要运行*）。先跑一次 设置 → 自检，应为绿色。
3. **游戏库 → 导入** 你自有的已解密 `.3ds`/`.cci`；只读取 ROM 头与 SMDH 图标/元数据。
4. **部署**：勾选游戏后按唯一的一键部署按钮。启动器为每个游戏编译 GamePack、合成不含 ROM 的 IPA、用内置 Impactor（登录你自己的 Apple ID）签名安装，然后只推送游戏数据。启动器会先检查手机：若已安装的 App 与所选游戏都是最新，就完全跳过部署；覆盖更新保留游戏数据、存档与 ROM；若手机上有本机库缺失的游戏，会列出并在更新前询问（绝不会删除这些数据）。
5. 在手机上打开 App 开玩。增删游戏重新部署即可；已推送数据在重装后保留，彻底卸载 App 会清空。

### macOS 启动器

1. 下载 `3ds2apple-<version>-macos-universal.zip` 得到 `3ds2apple-launcher.app`（未公证；首次右键 → *打开*）。
2. 分发包**尚不自包含**：需要 macOS 13+、已登录 Apple ID 的 Xcode 15+、`xcodegen`、仓库 checkout，以及构建好的工具（`scripts/build-zakuro-ios.sh`、`builder` 的 pack CLI、`tools/devpush`）。启动器会在自身 bundle、checkout 与 `PATH` 中查找。
3. 导入 → 部署：Apple clang 编译 GamePack，Xcode 自动签名 + `devicectl` 安装合成后的 IPA，随后推送游戏数据。选择规则与 Windows 相同。

### 手机数据、存档与限制

- 游戏数据位于 `Documents/Games/<TITLEID>/`（可在「文件」App 查看）；存档与即时存档保存在 App 容器内。
- 虚拟按键在暂停菜单的 **虚拟按键选项 → 编辑布局** 里编辑（在暂停画面上拖动，再点 **完成**）；屏幕布局在 **设置 → 显示 → 屏幕布局** 里编辑。预设立即生效，自定义屏幕布局从下一次加载游戏起生效。
- 免费 Apple ID 每台设备限 3 个 App、签名约 7 天；到期重新部署即可续签。付费开发者账号没有这些限制。
- 卸载 App 会删除其数据；你电脑上的 ROM 不受影响。

## 下载包与发布策略

公开发布只走 [GitHub Releases](https://github.com/HFYKratos/3ds2apple/releases)。每次发布只附两个平台包：

- `3ds2apple-<version>-windows-x64.zip` —— Windows 10/11 启动器：自包含的 `3ds2apple-launcher.exe`，外加 `LICENSE`、`NOTICE` 和 `THIRD_PARTY.md`。
- `3ds2apple-<version>-macos-universal.zip` —— macOS 13+ 启动器：`3ds2apple-launcher.app`（Intel + Apple 芯片），外加 `LICENSE`、`NOTICE` 和 `THIRD_PARTY.md`。

从 0.1.1 起，两个 zip 根级都带这三份许可文本，与仓库根文件逐字节一致，下载的包因此自包含；它们不作为单独的 Release 资产发布。[THIRD_PARTY.md](THIRD_PARTY.md) 里列出的 GPL 项目仍然只是只读参考——不打包任何 GPL 代码或文本。0.1.0 的包早于此项，依赖仓库内的副本。不含 ROM 的壳模板已内嵌在两个启动器中，无需单独下载。GitHub 会显示每个发布资产的 SHA-256 digest；发布中不含任何游戏数据。

## 从源码构建

| 组件 | 构建 / 测试 |
|---|---|
| Windows 启动器 | `cd launcher/windows && dotnet build Launcher.slnx -c Release` / `dotnet test Launcher.slnx -c Debug` —— 见 [launcher/windows/README.md](launcher/windows/README.md) |
| macOS 启动器 | 在 macOS 上用 XcodeGen + `xcodebuild` —— 见 [launcher/macos/README.md](launcher/macos/README.md) |
| iOS App / 壳 | `scripts/build-zakuro-ios.sh` → `scripts/build-ios-app.sh` → `scripts/package-ipa.sh` —— 见 [scripts/README.md](scripts/README.md) |
| Pack CLI（`3ds2apple-pack`） | `cd builder && cargo build --workspace` / `cargo test --workspace` —— 见 [builder/README.md](builder/README.md) |
| 设备桥（`devpush`） | `cargo build --release --manifest-path tools/devpush/Cargo.toml` —— 见 [tools/devpush/README.md](tools/devpush/README.md) |

宿主机自检（无需 ROM、手机或 Xcode）：

```bash
cd builder && cargo test --workspace
cd launcher/windows && dotnet test Launcher.slnx -c Debug
bash scripts/tests/perf-selfcheck.sh
bash scripts/tests/aot-selfcheck.sh
bash scripts/tests/game-catalog-selfcheck.sh
bash scripts/tests/desktop-aot-selfcheck.sh
```

## 深入一点

### 原生移植，不是模拟器

每款游戏都会被提前重编译：3DS 代码先由 3dsrecomp 翻成 C，再用本机的 LLVM 或 Apple clang 工具链编译成 ARM64 `GamePack`。手机通过 Zakuro HLE 运行时直接执行这些原生代码——没有 CPU JIT，也没有解释器兜底。PICA200 GPU 路径由 MoltenVK 转成 Metal，所有屏幕布局（预设与自定义矩形）都由 GPU presenter 直接画到 `CAMetalLayer`，每帧零屏幕回读。

### 一个 App，装下整个游戏库

你勾选的每款游戏都会编译成独立的 `GamePack<TITLEID>.dylib`，和一个 `GameCatalog.json` 一起被合成进同一个已签名 App。装一个 App 就带走整个游戏库；增删游戏只需重新部署一次，已推送的游戏数据在重装与更新后仍然保留。每游戏代码必须位于已签名的 IPA 内——iOS 不允许从 `Documents` 加载未签名代码。

游戏库卡片上的信息全部来自启动器导入时已读到的 SMDH 元数据：游戏自己的图标、当前语言的标题、发行商和推送的游戏大小。启动器把这些元数据放进 `GameInfo.json` 与游戏数据一起推送，手机端始终不解包 ROM；旧版启动器推送的库照常可用——卡片会回退到 catalog 名称、隐藏发行商一行并显示占位图标，重新部署后即可补全。

### 图形化启动器，几乎零配置

Windows 与 macOS 各有一个启动器。导入你自有的已解密 `.3ds`/`.cci`，勾选游戏，按唯一的一键部署按钮：启动器编译 GamePack、合成不含 ROM 的基础壳 IPA、用你自己的 Apple ID 签名安装（Windows 用内置官方 Impactor/plumesign，macOS 用 Xcode 自动签名），然后只把 `GameRom.cci` + `GameInfo.json` 推送到 App 的 Documents 目录。

启动器会把数据放在 exe/.app 旁的便携目录，读取 ROM 的 SMDH 元数据（图标、本地化名称、发行商），检测编译硬件并自动并行 3dsrecomp，还会显示启动就绪灯与自检——缺工具时不会在部署中途静默失败。Windows 的部署是设备感知的：先读取手机已安装的 App 与游戏，已是最新则跳过；覆盖更新会保留游戏数据与存档；手机上有本机库缺失的游戏时会列出并在更新前询问——这些数据绝不会被删除。

### 游戏画面上的显示

画面铺满整屏：没有标题栏、卡片边框或游戏名。App 自己在画面上的元素只有 **帧率（FPS）胶囊**（默认开启，浮在右上安全区）、悬浮暂停按钮和虚拟按键；帧率可在暂停菜单的 **虚拟按键选项** 里关掉。其余信息都不画在画面上：AOT 状态、渲染路径、Metal HUD 状态和各阶段帧耗时只写入设备日志与诊断报告（设置里的「关于」页仍保留运行状态摘要供排查，但不会盖在游戏上）。

设置页也已去掉旧的「Metal backend」信息行和「首次载入图形预热」开关：游戏加载完立即显示，运行库的管线缓存仍会让同一游戏的后续加载变快。Apple 自己的系统 Metal HUD 开关（GPU/FPS 浮层）自 0.1.6 起默认关闭，位于 设置 → 性能。

### 实测数据

在真机 iPhone 上，**某款商业游戏**经 Windows 启动器链路运行实测约 **57–60 fps**，**AOT 100%**，**Metal GPU** 渲染；`zk_perf` 显示 GPU 每帧 4–6 ms、present 10–11 ms、屏幕回读 0。以上是维护者针对那一款游戏的实测数据；兼容性与性能因游戏而异，不作保证。

## 仓库结构

```text
assets/            本 README 使用的 App 图标
.github/           问题报告与 PR 模板
ios/app/           iOS App：游戏库、游戏内菜单、触摸控制、即时存档
ios/zakuro-ios/    Zakuro iOS C ABI：GamePack 加载器、Metal presenter、性能计数
launcher/windows/  Windows 启动器（C#/Avalonia）与单文件打包
launcher/macos/    macOS 启动器（SwiftUI）、Xcode 签名安装
builder/           3ds2apple-pack：ROM 导入、SMDH 元数据、包与 GameCatalog
tools/devpush/     设备桥：usbmuxd/house_arrest/AFC 推送、安装校验
tools/winbuild/    不依赖 Apple SDK 的 LLVM/LLD GamePack 交叉构建工具
scripts/           构建、打包、发布与自检脚本
licenses/          第三方许可文本（Impactor MIT、apple-codesign MPL-2.0）
```

## 实话实说的边界

- **兼容性因游戏而异。** 部分游戏可能无法启动或渲染异常，个别游戏的某些菜单也可能渲染异常（issue [#2](https://github.com/HFYKratos/3ds2apple/issues/2)）；欢迎带上 title ID 反馈——见[问题反馈与性能数据](#问题反馈与性能数据)。
- **自定义屏幕布局自 0.1.6 起走 GPU 路径。** 任意矩形、四向旋转与上下屏交换都由 GPU presenter 绘制；0.1.5 及更早走屏幕回读路径。自定义布局仍从下一次加载游戏起生效。
- **C 杆依赖游戏支持。** 它通过 New 3DS 摇杆 API 上报；不读取该摇杆的游戏会忽略它，用旧运行库构建的壳也不提供它。
- **国行 iPhone 首次弹出键盘时可能询问「无线数据」。** 这是 iOS 的已知系统问题：系统文本输入首次出现时（例如游戏内键盘覆盖层），UIKit 内部的听写/网络路径自检会被系统归因到 App，于是弹出「允许使用无线数据」。本应用不发起任何网络请求、蜂窝数据用量为 0，选*不允许*或*仅限无线局域网*即可，功能不受影响（重装后可能再次出现）。详见 [ios/app/README.md](ios/app/README.md)。
- **旧安装与旧推送仍然兼容。** `GameInfo.json` 只新增了可选字段（schema 版本仍为 1），0.1.0 启动器推送的数据仍能校验并运行；在重新部署之前，卡片没有发行商、没有真实 SMDH 图标、也没有大小。从 0.1.0 升级上来的 App 会保留游戏库与存档。
- **macOS 包是开发者预览。** 尚不自包含，真机安装也还未由维护者验证——真机验收征集见 [#1](https://github.com/HFYKratos/3ds2apple/issues/1)；Windows 包是已验证路径。
- **不提供 ROM、密钥或 BIOS。** 只支持你合法拥有并自行导出的已解密 ROM。
- **设计上没有 CPU JIT。** 正式路径是 AOT 代码 + Zakuro HLE 运行时，没有解释器兜底。

## 问题反馈与性能数据

欢迎提交 bug 与兼容性报告：从[兼容性报告模板](.github/ISSUE_TEMPLATE/compatibility-report.yml)开始（GitHub 会在 **New issue** 里提供）。请附上游戏名、16 位 title ID、区域与版本（base/update/DLC）、设备型号与 iOS 版本、使用的 3ds2apple 版本或 commit、AOT 状态、现象与复现步骤。**禁止**上传 ROM、解密密钥、BIOS/固件、生成的 C、含游戏画面的截图或录像、签名 IPA/pack、Apple 凭据或设备 UDID。

每个版本都能导出诊断报告：打开游戏内菜单点 **Export logs / 导出日志**（菜单会暂停帧循环，点下的瞬间卡顿计数就冻结），再用系统分享面板分享 `.txt`。主页路径 **设置 → 更多 → 导出日志** 也能导出，但卸载游戏会把帧率/卡顿计数清零——需要这些数字时请用游戏内菜单；设置页导出的那份仍包含完整会话日志。0.1.1 起每次导出还会写入 App 容器的 `Documents/Diagnostics/<时间戳>.txt`（保留最近 5 份）；同一目录可在「文件」App 的「我的 iPhone → 3ds2apple → Diagnostics」里看到，也可以用设备桥通过 USB 拉取：

```bash
devpush ls  --bundle-id com.kratos.3ds2apple --remote Documents/Diagnostics
devpush get --bundle-id com.kratos.3ds2apple --remote Documents/Diagnostics/<时间戳>.txt --local diagnostics.txt
```

报告里已包含构建与设备状态、AOT 证明（`aot_percent`、`aot_fallbacks`）、渲染路径、帧率上限/快进/渲染分辨率设置、各阶段帧耗时以及两次会话的 App 日志。0.1.1 起还会记录卡顿（`>33.3 ms` 帧）与严重卡顿（`>100 ms`）计数、每分钟次数、最差帧、按阶段归因和最近 20 条尖峰事件。如果是卡顿反馈（例如「大部分时间 57–60 fps 但偶发卡顿」），再说明发生的时机与场景（游戏 + 场景/菜单）、第二次运行是否更顺，以及使用的启动器链路与设置。**请附上诊断文件**——计数与尖峰就是测量数据，没有文件的卡顿反馈通常只会被要求补上文件。

有 Mac + iPhone/iPad 的验证者尤其欢迎：[macOS 真机验收模板](.github/ISSUE_TEMPLATE/macos-acceptance.yml)会按 [launcher/macos/README.md](launcher/macos/README.md#real-device-acceptance) 的清单逐项收集结果（Xcode 签名、`devicectl` 安装、`devpush` 推送）。

## 贡献与发布

- [CONTRIBUTING.md](CONTRIBUTING.md) —— 贡献规则、问题反馈与发布规范。
- [问题模板](.github/ISSUE_TEMPLATE) —— 兼容性报告与 macOS 真机验收清单。
- [LICENSE](LICENSE) —— Apache-2.0。
- [THIRD_PARTY.md](THIRD_PARTY.md) 与 [NOTICE](NOTICE) —— 第三方组件与法律声明。

## 致谢

3ds2apple 建立在开源工作之上：**Zakuro**（MIT，HLE 运行时与 PICA200 渲染器）、**3dsrecomp**（MIT，静态重编译器）、**MoltenVK**（Apache-2.0，Vulkan on Metal）、**Impactor**（MIT）与 **apple-codesign**（MPL-2.0，Windows 签名）、**pocket-native**（MIT，iOS 原生移植参考），以及 LLVM 项目的编译工具链。也感谢所有在真机上测试构建的人。

## 许可证与法律

3ds2apple 使用 **Apache-2.0** 许可（见 [LICENSE](LICENSE)）。它不含任何 Nintendo ROM、解密密钥、BIOS、系统文件、游戏资源或游戏画面截图，也不提供 ROM 下载或盗版支持。请只使用你合法拥有并自行导出的游戏。3ds2apple 与 Nintendo、Apple 均无关联、未获赞助或背书。

第三方组件及许可见 [THIRD_PARTY.md](THIRD_PARTY.md) 与 [NOTICE](NOTICE)。Windows 启动器原样内置官方 Impactor v2.7.3 + plumesign 发布文件（MIT；其中内嵌的 apple-codesign 0.29.0 为 MPL-2.0），许可文本保存在 [licenses/impactor](licenses/impactor)；macOS 启动器改用 Xcode 签名，不内置 Impactor。iOS 壳模板与 macOS 启动器内嵌未修改的 MoltenVK 1.4.2 框架（Apache-2.0）。GPL 项目仅作为架构参考阅读，不复制其代码或文本，也不会随包分发。
