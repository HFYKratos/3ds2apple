# 里程碑

## M0：iOS 构建链路打通（2026-11-12）

**结果：** 在无本地 Mac 的情况下，用 CachyOS 上的 macOS 14.8.9 VM 构建出 unsigned IPA，经 Windows Sideloadly 签名安装到 iPhone 14 Pro Max（iOS 26.7.2），App 正常运行。

| 项目 | 配置 |
|---|---|
| 宿主机 | CachyOS，Intel i5-9300H（4C8T），15 GB RAM，NVMe |
| 虚拟化 | QEMU 11.1.3 + KVM，macOS 14.8.9 Sonoma（OpenCore 1.0.6） |
| VM 参数 | `-cpu host`、4 vCPU、8 GB RAM、`-device VGA`、VNC 5901、SSH 转发 2222 |
| Xcode | 16.4（16F6），安装到 `~/Applications/Xcode-16.4.0.app`，iOS 18.5 SDK |
| 构建 | `xcodebuild -target Hello3DS -sdk iphoneos`，`CODE_SIGNING_ALLOWED=NO` |
| 产物 | `Hello3DS.ipa`（arm64，min iOS 16.0，bundle `com.kratos.hello3ds`） |
| 签名/安装 | Windows Sideloadly + 免费 Apple ID |
| 真机 | iPhone 14 Pro Max，iOS 26.7.2，App 启动正常 |

### 踩过的坑

1. **OpenCore 键盘无驱动**：Drivers 缺 `OpenUsbKbDxe.efi` / `XhciDxe.efi`；补上后才能用 VNC 键盘选择启动项。
2. **`EB.LD.LKC` / `Halting on critical error`**：最终用 `-cpu host`（而不是 `Haswell-noTSX`）+ 标准 VGA 才过 kernel collection；期间也补了 `HfsPlus.efi`。
3. **`xcodes` 报 “Directory argument must be a directory”**：`~/Applications` 必须预先存在。
4. **Xcode 首次启动组件**：`xcodebuild -runFirstLaunch` 解包 CLTools/CoreSimulator 很慢，必须等 `xcodebuild -checkFirstLaunchStatus` 返回 0。
5. **scheme 构建报 “Found no destinations”**：iOS 18.6 Simulator runtime 未装；改用 `-target` + `SYMROOT` 可绕过（不需要模拟器）。
6. **`PRODUCT_NAME` 为空**：XcodeGen 工程里显式设置 `PRODUCT_NAME` / `EXECUTABLE_NAME`，否则产物变成 `.app`。
7. **`@` 输入**：QEMU VNC 不支持剪贴板同步；用 macOS 内部 `pbcopy` + Cmd+V，或用 Character Viewer。
8. **VM 卡死**：`system_reset` 后 QEMU 会停在 `paused (prelaunch)`，需要 monitor `cont`；更稳妥是 `quit` 后重新启动。

### 下一里程碑

- [x] Zakuro 核心编译为 `aarch64-apple-ios` 静态库（`libzakuro_ios.a`，52 MB）
- [ ] SwiftUI 壳接入 `read_screen` + `take_audio` + `set_input`
- [ ] 3dsrecomp 生成第一款游戏的 C 代码并链接
- [ ] 第一款游戏在真机跑起来

## I1：iOS 壳骨架（2026-11-12 构建通过，待真机确认）

**结果：** `xcodegen` + `xcodebuild` 成功，产出 `3ds2apple-I1.ipa`（23 KB，arm64，
min iOS 16.0，bundle `com.kratos.3ds2apple`）；`libzakuro_ios.a` 已链接，二进制中含
`_zk_screen_width` / `_zk_screen_height` 符号。

- 源码：`ios/app/`（SwiftUI）、`ios/ZakuroBridge.h`、`scripts/build-ios-app.sh`、
  `scripts/package-ipa.sh`。
- 预期 UI：标题 `3ds2apple`，Upper 400×240，Lower 320×240，`No ROM loaded` 占位。
- 待办：真机安装确认 UI（Sideloadly）；之后进入 I2 ROM 导入 + 第一款游戏 boot。

## I2：ROM 导入 + 帧循环（2026-11-12 构建通过，待真机）

**I2-T1（ROM 导入 + zk_create）**
- `3ds2apple-I2T1.ipa`：1.4 MB，`com.kratos.3ds2apple`，SHA256
  `4775562f35b5beb420bedd9abecd7c23eb52d3cbca734ed9a82c66bd2fbb1d1b`
- 已注入 `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`，
  可用 iTunes/Finder 文件共享传 ROM。

**I2-T2（帧循环 + 上下屏）**
- `3ds2apple-I2T2.ipa`：2.2 MB，SHA256
  `e766f1ad9c238a3e1b7efa97942d0bcb2ec639deedaacf9f10f9add534e5c16b`
- CADisplayLink → runtime 串行队列 → `zk_run_frame` → `zk_read_screen(0/1)` →
  CGImage；上下屏 400×240 / 320×240；fps/帧数/最后结果状态行。

**待真机验收（Pokémon Y）**
- [ ] 导入 ROM → `Loaded`
- [ ] 第一帧出现在上下屏
- [ ] 颜色/比例正确（R/B 不交换、非拉伸）
- [ ] Unload / 后台切换 / 重启后 Load last 正常
- [ ] 记录纯解释器下的 emulated fps（I3 再上 3dsrecomp）

> 当前是纯解释器模式（尚未接 3dsrecomp），首帧可能很慢；这是 I2 的预期，
> 不代表最终性能。

## I2 真机验收（2026-11-12，通过）

- ROM：`Pokemon Y.cci`（用户自有，`ROM/` 本地，不提交）。
- 结果：绿色 `Loaded: Pokemon Y.cci`；上屏 400×240、下屏 320×240 均正常显示；
  状态行 `20 fps · 700 frames · last: completed`；游戏已到语言选择界面。
- 说明：当前是**纯解释器**（未接 3dsrecomp），20 fps 属预期；I3 接 3dsrecomp 后复测。
- 尚缺输入：停在语言选择，需要 I3 的触摸/手柄才能继续。
- 游戏截图不入库（AGENTS.md 规则）；此处只记录文字指标。

## I3-T1 输入（2026-11-12 构建通过，待真机）

- `3ds2apple-I3T1.ipa`：2.3 MB，SHA256
  `ad237e6d906a08716f822ac76ab45c79a93736ac51f43f66e00860b0508cfb7f`
- 触摸 overlay（D-pad、A/B/X/Y、L/R、Start/Select）+ GameController 映射；
  单一 `zk_set_input` 调用点，在每帧 `zk_run_frame` 前于 runtime 串行队列执行。
- 待真机：Pokémon Y 语言选择 → ▼/▲ + A；再测 Start/L/R、手柄、Unload/后台无卡键。

## I3-T1 真机验收（2026-11-12，通过）

- Pokémon Y 语言选择已用触摸 D-pad + A 通过；进入开场画面，上屏正常显示，
  下屏为 3DS 触摸屏；状态行 `26 fps · 1,482 frames · last: completed`。
- 触摸 overlay 的 L/Select/Start/R、D-pad、A/B/X/Y 均可见；未接手柄时提示
  `No controller connected — use the on-screen controls`。
- 截图不入库（AGENTS.md 规则）；此处只记录文字指标。

## I3-T2/I3-T3 AOT 链路（2026-11-12 进行中）

- 在 Linux 上用 pinned upstream 3dsrecomp（recomp-abi `df82e6e`，ABI5/GEN5）
  对 Pokémon Y 生成 C：**489 个 C 文件，约 635 MiB**，title ID
  `0004000000055E00`。
- 已构建 linked `libzakuro_ios.a`（`--features linked`，
  `ZAKURO_LINKED_PROGRAM_ID=0004000000055E00`），`nm -u` 出现 7 个
  `_recomp_*` 未定义符号，等待 `libgame.a` 解析。
- 正在 macOS VM 用 iOS clang 并行（3 路）编译生成 C → `librecomp.a`；
  完成后链接 `-lzakuro_ios -lgame` 出首个 AOT IPA。
- 预计首帧/性能对比：纯解释器 26 fps（Pokémon Y 开场）；AOT 后复测。

## I3-T4 音频（2026-11-12 构建通过，待真机）

- `3ds2apple-I3T4-audio.ipa`：2.3 MB，SHA256
  `23dee490088fbc939711fcc84fffb600330ed4684959871dbd337a4ddae3200b`
- `zk_take_audio`（32730 Hz 假设）→ ring buffer → AVAudioEngine/SourceNode；
  mute/Unload/后台停止；纯解释器 ~26 fps 下音频不连续属预期。
- 待真机：开场有声、Mute/Unmute、Unload/后台不崩、Load last 恢复。

## I3-T2 AOT 构建（2026-11-12）

- 3dsrecomp 固定 rev `df82e6e`（ABI5/GEN5）生成 Pokémon Y：
  **489 个 C 文件，约 635 MiB**；ROM title ID `0004000000055E00`
  （product code CTR-P-EK2A）。
- iOS clang（arm64-apple-ios16.0，-O2）编译 → `librecomp.a` 283 MB；
  链接顺序 `-lzakuro_ios -lgame`。
- linked `libzakuro_ios.a`（`ZAKURO_LINKED_PROGRAM_ID=0004000000055E00`，
  `--features linked`）含 7 个未定义 `_recomp_*`，由 `libgame.a` 解析。
- 产物：`IPA/pokemon-y-AOT.ipa`，85 MB，bundle
  `com.kratos.3ds2apple.pokemon-y`，SHA256
  `bb15392cbb2a01671edd4c54453ce39521e5af6a09989504cc59411b4e7360ad`
  （含 I3-T1 输入 + I3-T4 音频）。
- 待真机：fps 对比 26 fps 基线、`zk_recompiled()==1`、20 分钟 soak。
