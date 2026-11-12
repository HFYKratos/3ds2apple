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
