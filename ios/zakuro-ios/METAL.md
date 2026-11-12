# Metal/MoltenVK 渲染兼容层评估（I3-T10）

> 目标：回答"能不能把 Zakuro 的软件 PICA200 换成 **Metal 原生渲染**"，并给出
> 可落地的路线。优先评估 **Plan A：Zakuro 已有 Vulkan 渲染器 + MoltenVK**，
> 其次 **Plan B：直接写 Metal PICA 兼容层**。
>
> 结论：**Plan A 可行，且分两级——A0 只换渲染器、保持现有 CPU 回读呈现，
> 几乎不需要动 App；A1 再把呈现也搬上 Metal（CAMetalLayer + swapchain）。
> Plan B（直接 Metal 后端）v1 不做，留作 I5。**
>
> 本文件是本任务的唯一设计交付；代码（`zk_hardware_*` FFI）、验证命令和上游
> 补丁见 §7、§8。相关文档：[`PERF.md`](PERF.md)（帧时间拆分）、
> [`RECOMP.md`](RECOMP.md)（AOT 静态链接）、
> [`../app/README.md`](../app/README.md)（帧循环/HUD）、
> [`docs/pocket-native.md`](../../docs/pocket-native.md)、
> [`docs/qa/i3-aot-pokemon-y.md`](../../docs/qa/i3-aot-pokemon-y.md)。

## 0. 结论先行（TL;DR）

**已确认的事实（本任务实测，不是推测）：**

1. **`libzakuro_ios.a` 里已经编进了 Vulkan 渲染器**：`zakuro-core` 的
   `Cargo.toml` 固定 `zakuro-gpu = { workspace = true, features = ["vulkan"] }`，
   所以 `ash`、`ash-window`、`naga`、以及 MoltenVK 加载/设备创建代码本来就在
   静态库里（`cargo tree -p zakuro-ios --target aarch64-apple-ios -e features`
   可见 `zakuro-gpu feature "vulkan"`）。**不需要新的 cargo feature、不需要改
   依赖、不增加编译产物**；构建脚本关掉的只是 `jit`（cranelift），Vulkan 保持。
2. **iOS 上唯一真正的缺口是"MoltenVK 找不到"**：`zakuro-gpu` 的
   `instance::entry()`（2026-11-05 合入的上游 PR #26 只为 macOS 加了 MoltenVK
   路径）在 iOS 上只会 `dlopen("libvulkan.dylib")`，一定失败 → 渲染器创建
   Vulkan device 失败 → loader 自动回退软件 PICA200（只打一条 `zk[WARN]`）。
   这就是当前 `hardware_renderer = false` 之外的第二道门。
   修法是一个 **约 20 行、只影响 `crates/zakuro-gpu/src/instance.rs`** 的补丁
   （§8，已在本任务用 `cargo check --target aarch64-apple-ios` 验证能编译）。
3. **A0 不需要实现 Vulkan 呈现/swapchain**：把 `Config.hardware_renderer`
   打开后，loader 会自己调 `gpu.enable_hardware_renderer(...)`，在没有
   presenter 共享 device 时用 `Hardware::with_device(device, direct = false)`，
   屏幕仍由 `zk_read_screen` 从 guest 内存回读（GPU→CPU `sync_gpu`），
   **现有 SwiftUI/CGImage 呈现路径一行不用改**。这是最小真机验证路径。
4. **A1（GPU→GPU 呈现）在依赖上也可行**：`ash-window 0.13` 原生支持 iOS
   （`RawWindowHandle::UiKit` → `raw-window-metal` → `vkCreateMetalSurfaceEXT`），
   而 `VulkanPresenter::new` 接受任意 `HasDisplayHandle + HasWindowHandle`
   类型，所以可以在 `zakuro-ios` 里用 `UIView*` 包一个 handle 直接构造
   presenter，**不需要改 `VulkanPresenter` 本身**。需要新增 session 型 FFI
   （不改现有 `zk_*` 签名），ui 侧需要 ios-shell 提供 UIView/CAMetalLayer。
5. **数据前提还没满足**：当前 HUD 只证明"呈现（读屏/CGImage/音频）≈0，
   `run` 22.6ms"，**没有 `zk_perf` 的 `gpu` / `non-gpu` 拆分**（PERF.md §4.1）。
   软件 GPU 到底占 22.6ms 里的多少，决定了 A0 的上限。**A0 的第一步不是出
   IPA，而是抓一条稳态 `zk_perf` 行**。

**建议决策：**

| 选择 | 何时 | 工作量（经验值，±50%） |
|---|---|---|
| **A0**（MoltenVK 渲染 + 现有回读呈现） | **现在做**：成本最低，能直接量出软件 GPU 的真实占比和收益 | 上游补丁 0.5 人日 + ios-shell 链接 MoltenVK / Lead 出 IPA 1–2 人日 + 真机验证 |
| **A1**（CAMetalLayer + swapchain 呈现） | A0 证明 GPU 路径有收益、且回读/延迟成为新瓶颈，或要 3D 立体/纹理包/插帧 | 3–5 人日（Rust session FFI 2–3 + ios-shell UIView 呈现 2） |
| **A2**（渲染调优：分辨率/顶点着色/缓存） | A1 之后，按 HUD 数据 | 1–3 人日 |
| **Plan B**（直接 Metal PICA 后端） | v1 不做；只在"MoltenVK 出问题且必须 60fps"时评估，放 I5 | 3–6 周起（见 §5） |

**Plan A 的主要风险**：MoltenVK 被 Khronos 标记弃用（仍推荐用于 iOS）、
iOS 上没有官方 Vulkan loader 需自嵌 framework、金属驱动/扩展差异要真机验证、
readback 成本、首次 pipeline 编译卡顿、上游无 iOS 支持需自带补丁。

## 1. 上游 Zakuro Vulkan 路径事实（读代码）

> 依据：`fearkov/zakuro` main（2026-11-12，version 0.2.32，
> `recomp-abi` = `Cargo.lock` 的 `df82e6e3`，与 [`PERF.md`](PERF.md) §6 一致）。
> 克隆在 `/tmp/zakuro-upstream`（不提交），文件行号以该 main 为准。

### 1.1 渲染器在依赖树里，且默认就是"软件 + 可选硬件"

`crates/zakuro-gpu/Cargo.toml`：

```toml
[features]
default = ["jit"]                      # Cranelift shader JIT，iOS 构建被关掉
opengl  = ["dep:glow"]
vulkan  = ["dep:ash", "dep:ash-window", "dep:naga"]
jit     = [ ... cranelift ... ]
```

`crates/zakuro-core/Cargo.toml:14`：

```toml
zakuro-gpu = { workspace = true, features = ["vulkan"] }
```

- 也就是说 **只要链接 `zakuro-core`，Vulkan 后端代码就在**；`scripts/build-zakuro-ios.sh`
  把 workspace 的 `zakuro-gpu` 设成 `default-features = false` 只关 `jit`。
- Vulkan 渲染器的 SPIR-V 是**仓库里预先编译好的**
  （`crates/zakuro-gpu/shaders/*.spv`，`include_bytes!` 进二进制），构建 iOS 包
  不需要 glslang/MoltenVK 工具链。
- PICA 顶点着色器在运行期由 **`naga`（纯 Rust，CPU）** 翻译成 SPIR-V
  （`raster/hardware.rs:35` 起、`translates`），没有可执行内存，**不违反 no-JIT**。
- `shades`（顶点着色是否在 GPU 上跑）默认按
  `device_type != INTEGRATED_GPU` 判断（`raster/hardware.rs:1711`）：**iPhone 是
  integrated，所以默认顶点着色在 CPU 上**（与软件渲染器同一份 PICA 顶点路径，
  且没有 shader JIT，走解释执行）。真机要用 `ZAKURO_GPU_SHADERS=1` 对比，
  否则容易把"顶点在 CPU"误算成"Metal 没加速"（本任务的
  `zk_set_hardware_option("gpu_shaders", "1")` 就是为这个准备的）。

### 1.2 `Config`：硬件渲染是三个字段的事

`crates/zakuro-core/src/lib.rs:38` 起：

| 字段 | 默认 | 作用 |
|---|---|---|
| `hardware_renderer: bool` | `false` | 为 `true` 时 loader 尝试 Vulkan 渲染器；失败**自动回退软件**并打 warn |
| `device: Option<Arc<SharedDevice>>` | `None` | presenter 与渲染器共享的 Vulkan device；无 presenter 时留 `None`，渲染器自建 device |
| `resolution: u32` | `1` | 内部渲染倍率（1 = 400×240） |
| `interpolate: bool` | `false` | 插帧，需要 presenter 共享 device（v1 不用） |
| `texture_packs: bool` | `true` | 纹理包，需要硬件渲染器（iOS 当前 FFI 固定 `false`） |

`crates/zakuro-core/src/loader.rs:202`（loader 自动接线）：

```rust
if system.config.hardware_renderer {
    match system.gpu.enable_hardware_renderer(
        system.config.resolution, system.config.device.clone(), Some(title.program_id()),
    ) {
        Ok(name) => log::info!("drawing on {name} through Vulkan"),
        Err(error) => log::warn!("{error}, drawing in software"),
    }
}
```

- `zk_create` 只要把 `config.hardware_renderer` 设成 `true`，再不用写任何
  "初始化 GPU"的代码：loader 负责建 device、失败回退、日志。
- `config.device = None` 时走 `Hardware::with_device(Arc::new(own_device()?), false, kept)`：
  **自建 device，`direct = false`**（`crates/zakuro-gpu/src/lib.rs:667`）。

### 1.3 渲染器与呈现是两条独立的路

`crates/zakuro-gpu/src/lib.rs`：

| API | 行 | 说明 |
|---|---|---|
| `Gpu::enable_hardware_renderer(scale, device, title)` | 667 | 建 `Hardware`；返回 GPU 名字（"Apple M… at 1x, …"） |
| `Gpu::draws_on_gpu()` | 692 | 是否真的在 GPU 上画 |
| `Gpu::shows_directly()` | 711 | 屏幕是否能由 presenter 从 GPU image 直接显示（`direct`） |
| `Gpu::scale()` | 799 | 当前内部倍率 |
| `Gpu::screen_image(screen)` / `Gpu::scaled_picture(screen)` | — | 给 presenter 的 GPU image / 回读成 `Vec<u8>` |

`crates/zakuro-core/src/lib.rs`：

| API | 行 | 说明 |
|---|---|---|
| `System::read_screen_scaled(screen)` | 1050 | 呈现用：优先 GPU 回读（`scaled_picture`），否则 CPU framebuffer |
| `System::read_screen(screen)` | 1183 | **`zk_read_screen` 用的就是它**：纯 CPU 路径 |
| `System::read_screen_at` | 1188 | 先 `sync_gpu(base, len)` 把 GPU 画的东西回写到 guest 内存，再读 |
| `System::gpu_screen(screen)` | 1094 | 给"共享 device 的 presenter"直接显示的 `GpuScreen` |

**关键**：`zk_read_screen` 走 `read_screen` → `read_screen_at` → `sync_gpu`
→ `Hardware::prepare_read`（GPU→CPU 回读），所以**开启硬件渲染器后，
现有 `zk_read_screen` 语义不变**，只是回读变贵（见 §4.1）。A0 能成立就是靠这个。

### 1.4 Presenter（只有 A1 才需要）

`crates/zakuro-gpu/src/backend/mod.rs:356` 的 `Presenter` trait：
`present(top, bottom, right, overlay) -> Result<(), PresentError>`、
`resize`、`set_layout`、`set_orientation`、`set_top_width`、`set_scaling`、
`set_stereo`。`ScreenImage { width, height, pixels, gpu: Option<GpuScreen> }`
（`backend/mod.rs:12`）——`gpu: Some(..)` 时呈现器从 GPU image 直接画，
`pixels` 为空。

`crates/zakuro-gpu/src/backend/vulkan.rs:140`：

```rust
pub fn new(window: &(impl HasDisplayHandle + HasWindowHandle), size: (u32, u32))
    -> Result<VulkanPresenter, PresentError>
```

- 内部：`ash_window::enumerate_required_extensions(display)` →
  `ash_window::create_surface(..)` → `pick_device(instance, surface_instance, surface)`
  → 若 `can_render` 成立则 `render_device(..., &[VK_KHR_swapchain])`，
  **渲染器和 presenter 共用一个 `SharedDevice`**（`shared_device()` 公开，
  `backend/vulkan.rs:607`）→ swapchain、render pass、present pipeline。
- 桌面 App 的接线在 `crates/zakuro/src/present.rs:235`（`create_vulkan`）和
  `crates/zakuro/src/lib.rs:1740` 的 `present()`：先
  `shown(&mut system, Screen::Top)`（`gpu_screen` 优先，否则 `read_screen_scaled`），
  再 `backend.present(ScreenImage{...}, ...)`。
- **iOS 的 surface 创建不是问题**：`ash-window 0.13` 有 iOS 分支
  （`RawWindowHandle::UiKit(window)` → `raw_window_metal::uikit::metal_layer_from_handle`
  → `vkCreateMetalSurfaceEXT`，`VkMetalSurfaceCreateInfoEXT.pLayer = CAMetalLayer*`）。
  见 §3.5。旧的 `VK_MVK_ios_surface` / `vkCreateIOSSurfaceMVK`
  （`VkIOSSurfaceCreateInfoMVK.pView = UIView*`）已被 MoltenVK 标为 **obsolete**，
  不要用。

### 1.5 iOS 缺口清单（这是全部）

| # | 缺口 | 现状 | 修法 |
|---|---|---|---|
| 1 | `instance::entry()` 不认 iOS 的 MoltenVK | `crates/zakuro-gpu/src/instance.rs`：macOS 有 `.app/Frameworks` + Homebrew 路径；iOS 只有 `dlopen("libvulkan.dylib")` | §8 的 20 行补丁（读 `ZAKURO_VULKAN_LIBRARY` + `@executable_path/Frameworks/MoltenVK.framework/MoltenVK`） |
| 2 | App 里没有 MoltenVK 二进制 | —— | ios-shell 在 `ios/app` 里嵌入/链接（§6.3），**不提交到仓库** |
| 3 | `config.hardware_renderer` 固定 `false` | `src/lib.rs` 的 `zk_create` | 本分支已改为可开关（§7） |
| 4 | （只有 A1）没有 iOS presenter / UIView 入口 | presenter 只接 winit 的 raw handle | 本文件 §2.2 的 session FFI 设计；ui 侧加 `UIView`（ios-shell） |

Vulkan device/instance 的功能要求、MoltenVK 对应支持见 §3.6。

## 2. iOS 宿主需要提供什么

分两级：**A0 = 只换渲染器**，**A1 = 连呈现一起换**。

### 2.1 A0：只换渲染器（最小真机验证）

| 需要 | 由谁提供 | 备注 |
|---|---|---|
| 可加载的 MoltenVK | ios/app（embed 动态 framework 或链接静态库）+ 构建产物放 `build/`（gitignore） | 见 §3.3；不提交二进制 |
| 告诉 Zakuro MoltenVK 在哪 | 上游补丁 + `ZAKURO_VULKAN_LIBRARY`（可选） | 默认 `@executable_path/Frameworks/MoltenVK.framework/MoltenVK` 即可（Xcode 默认 rpath） |
| 打开硬件渲染 | 编译期 `ZAKURO_IOS_HARDWARE=1`（本分支已实现，**无需 Swift 代码**），或运行时 `zk_set_hardware_renderer(1)` | §7 |
| 呈现 | **不需要新东西**：现有 `zk_read_screen` + `CGImage` + SwiftUI | 回读变贵，HUD 的 read top/bottom 会上升 |
| CAMetalLayer / VkSurface / swapchain | **不需要** | A1 才要 |

A0 的数据流：

```text
guest 命令列表 ── CPU 解析/顶点(解释 PICA shader) ── 上传 ── Metal (MoltenVK)
                                                          │
     guest 内存 framebuffer ←── GPU→CPU 回读(direct=false) ┘
                │
     zk_read_screen ── CGImage ── SwiftUI（不变）
```

### 2.2 A1：presenter（GPU→GPU 呈现）

A1 = 把 A0 最后的"回读 → CGImage"换成"Metal swapchain 直接显示"。iOS 宿主需要：

1. **一个 `UIView`**：它的 layer 是 `CAMetalLayer`（或让 `raw-window-metal`
   自己加一层 `CAMetalLayer` sublayer）。`UIView` 必须在 window 里、尺寸为
   想要的画面区域。Swift 侧把 `UIView` 指针交给 FFI（`Unmanaged.passUnretained(view).toOpaque()`）。
2. **drawable 尺寸**：像素尺寸（`bounds.size * UIScreen.nativeScale`），
   由 Swift 传给 Rust；缩放/旋转时更新。
3. **present 节奏**：`CADisplayLink`（60/120Hz）或 free-run 线程；
   每跑完一帧调 `zk_present`；`VulkanPresenter` 默认 FIFO（等 vblank），
   也可用 `ZAKURO_PRESENT_MODE=mailbox|immediate`（本分支
   `zk_set_hardware_option("present_mode", …)` 可在加载前设置）。
4. **生命周期**：App 进后台停止 present（或至少停止提交）；回前台重建
   swapchain/尺寸；`zk_destroy` 时先释放 presenter 再释放 System（device 是共享的）。
5. **Rust 侧新增**（设计，不在本分支实现；不改现有签名）：

```c
/* 创建 presenter：内部 = ash Entry + VkInstance + VkSurface(来自 UIView 的
 * CAMetalLayer) + 物理设备 + VkDevice(与渲染器共享) + swapchain + present 管线。
 * 失败返回 NULL，原因见 zk_last_error。 */
void       *zk_presenter_create(void *ui_view, uint32_t width, uint32_t height);
void        zk_presenter_resize(void *presenter, uint32_t width, uint32_t height);
void        zk_presenter_destroy(void *presenter);
/* 用 presenter 的设备创建 System（Config.device = presenter 的 SharedDevice，
 * Config.hardware_renderer = true，direct = true，屏幕不再回读）。 */
void       *zk_create_presented(const char *rom, const char *data_dir, void *presenter);
/* 把上一帧显示到 CAMetalLayer；0 成功，-1 无 presenter，-2 surface 过期需重建。 */
int32_t     zk_present(void *system, void *presenter);
const char *zk_presenter_status(void *presenter);
```

Rust 内部要点（已在代码里确认可行）：
- `VulkanPresenter::new(&handle, (w, h))` 的 `handle` 用本 crate 里的小类型实现
  `HasDisplayHandle`（`RawDisplayHandle::UiKit(UiKitDisplayHandle::new())`）+
  `HasWindowHandle`（`RawWindowHandle::UiKit(UiKitWindowHandle::new(NonNull::from(view)))`）；
  `ash-window` 会替我们建 CAMetalLayer（若 view 的 layer 不是 CAMetalLayer）并
  调 `vkCreateMetalSurfaceEXT`。
- `presenter.shared_device()` → `Config.device = Some(shared)`；loader 的
  `enable_hardware_renderer(.., Some(device), ..)` 会以 `direct = true` 建渲染器，
  于是 `System::gpu_screen()` 返回 `GpuScreen`，`zk_present` 用
  `ScreenImage { pixels: &[], gpu: Some(..) }` 调 `presenter.present(..)`。
  读屏/呈现成本从"0.66MB/帧 GPU→CPU + CGImage"变成"一次 swapchain 提交"。
- 复用 presenter 的 3D/stereo/overlay/插帧能力是免费的（`set_stereo` 等）。

## 3. MoltenVK 评估

### 3.1 版本、许可、生命周期

| 项 | 值 | 依据 |
|---|---|---|
| 最新 release | **v1.4.2**（2026-07-20 发布，GitHub 2026-07-24 published） | GitHub releases / `Docs/Whats_New.md` |
| Vulkan 版本 | 1.4 核心（1.4.0 起）；Zakuro 只需 1.3 | `Whats_New.md` |
| 运行时最低系统 | **iOS 15**（1.4.2 起提高到 15）；本项目 iOS 16 目标 ✓ | `Docs/MoltenVK_Runtime_UserGuide.md` §Build and Runtime Requirements；framework Info.plist `MinimumOSVersion 15.0` |
| 平台切片 | `MoltenVK-ios.tar` 只有 **ios-arm64（真机）**，没有模拟器切片；模拟器要用 `MoltenVK-all.tar` | 包内 `Info.plist` |
| 许可 | **Apache-2.0**（Brenwill Workshop Ltd.） | 包内 `LICENSE` |
| 维护状态 | **Khronos 已弃用 MoltenVK**（README caution），但明确"iOS 仍推荐 MoltenVK"，社区 best-effort 维护 | MoltenVK README |
| 构建 SDK | v1.4.2 的 framework Info.plist：`DTXcode 26.5` / `iphoneos 26.5`；1.2.10 起支持 Xcode 16 / iOS 18 SDK | framework Info.plist / `Whats_New.md` |

**弃用对项目的含义**：不阻塞（MIT/Apache 生态里 Vulkan-on-Metal 在 iOS 上只有
MoltenVK 一条现成路；KosmicKrisp 只面向 Apple Silicon macOS）；但要在
`THIRD_PARTY`/`NOTICE` 记录版本与来源，并固定版本 + SHA256（§3.2）。长期
（I5）若要求"无第三方渲染栈"，才考虑 Plan B。

**Xcode 兼容风险**：macOS VM 目前是 Xcode 16.4 / iOS 18.5 SDK。v1.4.2 是用
Xcode 26.5 构建的；链接一个更新 SDK 构建的 framework 通常没问题（部署目标
15.0 ≤ 16.0），但不能保证。选项：
1. 先直接试 v1.4.2（推荐，一步到位）；
2. 若链接报错/运行异常，退到 **v1.4.0 或 v1.3.x**（Xcode 16 时代构建，
   Vulkan 1.3 已够用；不要低于 1.3.0，否则缺 Vulkan 1.3 核心特性）；
3. 或由 Lead 决定升级 VM 的 Xcode（AGENTS.md 规则 9：不擅自改 VM）。

### 3.2 包内容与体积（v1.4.2，`MoltenVK-ios.tar` 实测）

下载：<https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-ios.tar>
（34,535,424 字节；SHA256
`b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1`）

| 内容 | 路径（解包后） | 大小 | 用途 |
|---|---|---|---|
| 静态库 | `MoltenVK/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a` | **6,952,224 B ≈ 6.80 MiB** | 静态链接进 App（推荐长期） |
| 动态 framework | `MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework/MoltenVK` | **4,822,128 B ≈ 4.60 MiB** | embed + 运行时 `dlopen`（推荐 spike） |
| 头文件 | `MoltenVK/MoltenVK/include/`（Vulkan + MoltenVK） | 22 MiB | 只构建期用；本项目的纯 Rust 链接**用不到** |
| 文档/许可 | `MoltenVK/Docs/`、`MoltenVK/LICENSE` | 小 | 归档/归属 |
| 动态库 install name | `@rpath/MoltenVK.framework/MoltenVK`（Mach-O `LC_ID_DYLIB` 实测） | — | 决定 rpath 写法 |

- 静态库只导出 `vkGetInstanceProcAddr` 等符号（`MVK_HIDE_VULKAN_SYMBOLS`
  默认隐藏其余 `vk*`，但 `vkGetInstanceProcAddr` 始终静态可见）——这对
  "静态链接 + `ash::Entry::from_static_fn`"是必要前提。
- IPA 体积影响：动态 ≈ **+4.6 MiB**（framework 里还有一个 `Info.plist`）；
  静态 ≈ **+6.8 MiB**（`-dead_strip` 后略小）。当前 IPA 85MB（含 ROM/AOT），
  占比可接受。
- **不提交二进制**：下载到 `build/third_party/moltenvk/`（`build/` 已 gitignore），
  或 CI 临时目录；`THIRD_PARTY`/`NOTICE` 只写版本、URL、SHA256、许可证。

### 3.3 静态 vs 动态（spike 选动态，长期可静态）

| | 动态 framework（**A0 spike 推荐**） | 静态库（长期候选） |
|---|---|---|
| 集成 | ios/app embed `MoltenVK.framework`，Xcode 自动加 `LD_RUNPATH_SEARCH_PATHS = @executable_path/Frameworks` | ios/app `OTHER_LDFLAGS` 加 `-lMoltenVK -lc++` + `-framework Metal/Foundation/QuartzCore/CoreGraphics/IOSurface/UIKit` |
| 加载 | 补丁里 `Entry::load_from("@executable_path/Frameworks/MoltenVK.framework/MoltenVK")` | 需补丁**再扩一段**：`Entry::from_static_fn(StaticFn{ vkGetInstanceProcAddr })`（直接 `extern "C"` 引用会强制所有 iOS 构建链接 MoltenVK，所以建议加 `ios-static-moltenvk` feature，见 §8.3 备注） |
| 侧载签名 | Sideloadly/AltStore 会重签 embedded frameworks（常见做法；需真机验证一次） | 无额外签名对象，最稳 |
| 体积 | +4.6 MiB | +6.8 MiB |
| 升级 MoltenVK | 替换 framework 即可，不必重链 Rust 静态库 | 要重链 App |
| 风险 | framework 嵌入/签名、rpath 配错 | 补丁更复杂；链接 flags 多 |

**结论**：A0 用动态 framework（补丁已验证、改动最小）；如果真机上 framework
签名/rpath 出问题，再切静态（届时补丁加 ~15 行 + feature）。

### 3.4 Rust `ash` 怎么加载 MoltenVK

`ash 0.38.0+1.3.281`（Zakuro 用，`features = ["loaded", "std"]`）：

| 方式 | API | iOS 上可行？ |
|---|---|---|
| 默认 | `Entry::load()` | ❌ iOS 的 `LIB_PATH = "libvulkan.dylib"`，bare name `dlopen` **看不到 App 的 Frameworks 目录**（这是 iOS 与 macOS 的差异，DXVK iOS 补丁里也有同样结论） |
| 指定路径 | `Entry::load_from("@executable_path/Frameworks/MoltenVK.framework/MoltenVK")` | ✅ `@executable_path` / `@rpath` / 绝对路径都可以（App 内） |
| 静态链接 | `Entry::from_static_fn(StaticFn{ get_instance_proc_addr: vkGetInstanceProcAddr })` | ✅ MoltenVK 静态库保证导出 `vkGetInstanceProcAddr` |
| 编译期链接 | `Entry::linked()`（ash `linked` feature） | ⚠️ 可行但会把链接依赖强加给所有构建，不推荐 |

所以最小补丁就是给 `instance::entry()` 加两条 iOS 候选路径 + 一个
`ZAKURO_VULKAN_LIBRARY` 覆盖（§8），**不需要改 ash、不需要 Vulkan loader**：
iOS 上直接把 MoltenVK 当作"Vulkan 实现"用（不做 loader 层），instance 创建时
`VK_KHR_portability_enumeration` 逻辑上游已有（`instance::new`，PR #26 加的），
device 的 `VK_KHR_portability_subset` 上游也已有（`instance::portability_subset`）。

### 3.5 从 CAMetalLayer 建 VkSurface（A1，步骤）

推荐 `VK_EXT_metal_surface`（`vkCreateMetalSurfaceEXT`）；旧的
`VK_MVK_ios_surface`/`vkCreateIOSSurfaceMVK` 已被标 obsolete。

1. **Swift/UIKit**：准备 `UIView`（`UIViewRepresentable`/`UIViewController.view`），
   `view.isOpaque = true`；把指针和像素尺寸传给 Rust。
2. **Rust（ash-window 已经做好）**：
   ```rust
   // raw-window-handle 的 UiKit handle 就是 UIView 指针：
   let handle = RawWindowHandle::UiKit(UiKitWindowHandle::new(
       NonNull::new(ui_view).expect("non-null UIView")));
   // ash-window 内部：raw-window-metal 取出/新建 CAMetalLayer（设委托、contentScale），
   // 再 VkMetalSurfaceCreateInfoEXT { p_layer: &*layer } → vkCreateMetalSurfaceEXT。
   let display = RawDisplayHandle::UiKit(UiKitDisplayHandle::new());
   let extensions = ash_window::enumerate_required_extensions(display)?; // surface + metal_surface
   let surface = unsafe { ash_window::create_surface(&entry, &instance, display, handle, None)? };
   ```
   需要 instance 扩展：`VK_KHR_surface` + `VK_EXT_metal_surface`
   （`enumerate_required_extensions` 自动给）；可选
   `VK_KHR_portability_enumeration` + `ENUMERATE_PORTABILITY_KHR`（上游已处理）。
3. **CAMetalLayer 要求**：`frame/bounds` 跟随 view；`contentsScale = UIScreen.nativeScale`；
   `drawableSize = bounds * scale`（像素）；MoltenVK 建议 **`CAMetalLayer.delegate =
   UIView`**，让 swapchain/刷新时序正确（`raw-window-metal` 只在自建 layer 时
   设部分属性，`delegate` 由使用方设）。若自己建 layer 并赋给 view，
   用 `view.layerClass = CAMetalLayer.self`（或 `layer = CAMetalLayer()`）。
4. **device 扩展**：presenter 与渲染器共享 device，需要 `VK_KHR_swapchain` +
   `VK_KHR_push_descriptor` + `portability_subset`（若列出）+ 渲染器原有
   `VK_EXT_extended_dynamic_state3`/`2`（若支持）。这些上游 `render_device`
   已处理，**不需要我们写**。
5. **swapchain**：extent 取 drawable 尺寸；present mode FIFO（默认，等 vblank）
   或 mailbox；`VK_ERROR_OUT_OF_DATE_KHR`/尺寸变化时重建（`VulkanPresenter`
   的 `stale`/`resize` 已实现，A1 只需转发 UIView 尺寸）。

### 3.6 MoltenVK vs 渲染器的功能/扩展要求

`crates/zakuro-gpu/src/raster/hardware.rs:5619` 的 `render_device` 会要求：

| 要求 | 级别 | MoltenVK 支持 | 备注 |
|---|---|---|---|
| Vulkan 1.3 核心：dynamic rendering、synchronization2、pipeline creation cache control | device features13 | ✅（1.4.x = Vulkan 1.4；1.3.0 起 1.3 核心） | 必须，低于 1.3.0 的 MoltenVK 不行 |
| `VK_KHR_push_descriptor` | 必须 | ✅ 文档列出 | 必须 |
| `VK_KHR_swapchain` | presenter 用 | ✅ | A1 |
| `VK_EXT_metal_surface` + `VK_KHR_surface` | presenter 用 | ✅ | A1；或老的 `VK_MVK_ios_surface`（obsolete） |
| `VK_KHR_portability_enumeration/subset` | 需要时 | ✅ | 上游已处理 |
| graphics+compute 队列族（`can_render`） | 必须 | ✅（Metal 单队列族） | 必须 |
| 深度格式 `D24S8` 或 `D32_SFLOAT_S8` blit | 必须 | ✅ | Apple GPU 支持 D32S8 fallback（上游已实现） |
| `depthClamp` 设备特性 | 必须（`render_device` 硬要求 `depth_clamp(true)`） | ✅（release notes 有 depthClamp 修复；tvOS 曾缺） | **真机验证点**：若 `vkCreateDevice` 返回 `FEATURE_NOT_PRESENT`，会回退软件；届时上游补丁把 depthClamp 改为按查询结果可选（~5 行） |
| `logicOp` | 可选 | ❌ 官方 release 未启用（需要 `MVK_USE_METAL_PRIVATE_API` 构建） | 少数用逻辑运算的游戏可能画面不对；v1 接受 |
| `extended_dynamic_state3`（blend 动态） | 可选（不支持则静态 blend） | ✅ | 性能路径 |
| `extended_dynamic_state2`（logic op） | 可选 | ✅（但 logicOp 本身没有） | — |
| pipeline statistics query | 可选（`ZAKURO_GPU_TIMES` 诊断） | ❌ 不支持 | 只影响诊断，不影响渲染 |
| 几何着色器 | 不需要 | — | 上游对几何着色器 draw 回退 CPU 路径 |

结论：**渲染器要的功能 MoltenVK 基本都有**，最需要真机确认的是 `depthClamp`
和实际驱动 bug；任何 device 创建失败都会被 loader 捕获并回退软件，不会崩。

### 3.7 许可与归属

| 组件 | 许可 | 归属处理 |
|---|---|---|
| MoltenVK | **Apache-2.0** | 与项目 Apache-2.0 兼容；`THIRD_PARTY`/`NOTICE` 记录版本/URL/SHA256/LICENSE；不提交二进制 |
| MoltenVK 内含 SPIRV-Cross、Vulkan headers | Apache-2.0（随包） | 保留包内 `LICENSE`/`Docs` 归档即可 |
| `ash` / `ash-window` | MIT OR Apache-2.0 | 已在依赖树（非新增），Cargo 生态正常归属 |
| `raw-window-metal` / `raw-window-handle` / `cocoa` / `objc` | MIT OR Apache-2.0（Zlib for rwh） | 同上，仅 A1 链接路径用 |
| Zakuro 补丁 | MIT（上游） | 优先向 `fearkov/zakuro` 提 PR；本地补丁在 handoff 记录 |

**不要**从 Azahar/Citra 粘 GPL 代码（AGENTS.md 规则 6）；GLSL/TEV 语义只作参考。

## 4. Plan A 设计

### 4.1 A0：渲染器 offload，保留 CPU 回读呈现

**改动清单**（按写者）：

| # | 改动 | 写者 | 文件 |
|---|---|---|---|
| 1 | 上游 `instance::entry()` iOS 分支（§8） | runtime-ffi（本分支给出补丁；实际打在 `third_party/zakuro`） | `crates/zakuro-gpu/src/instance.rs` |
| 2 | `Config.hardware_renderer` 可开关 + 诊断 FFI | runtime-ffi（**本分支已实现**，§7） | `ios/zakuro-ios/src/lib.rs` |
| 3 | App 嵌入/链接 MoltenVK + 出包 | ios-shell / Lead | `ios/app/project.yml`（+ 可选 `ios/ZakuroBridge.h` 声明） |
| 4 | 真机 A/B 数据（软件 vs 硬件） | Lead/qa | `docs/qa/` |

**数据流**：见 §2.1。

**预期收益**（必须先测 `zk_perf` 拆分再下结论）：

- 软件 PICA200 的 host 时间（`zk_perf` 的 `gpu` 字段）包括：命令列表解析、
  顶点着色（解释 PICA shader）、光栅化、纹理解码、TEV 组合、display transfer。
  硬件路径把这些中的**像素/纹理/组合/传输**交给 Metal，CPU 只保留命令解析、
  顶点着色（默认还在 CPU，见 §1.1）和上传。
- 以当前 `run 22.6ms` 为基线，若 `gpu` 占 `run` 的 **50–70%**，A0 后 run
  有机会降到 **10–16ms**（44 fps 的帧上限会先被 I3-T9 的 free-run 打开，
  再看是否接近 60）；新增成本是每帧 **0.66 MiB** 的 GPU→CPU 回读
  （400×240×4 + 320×240×4 = 691,200 B；60fps ≈ 41 MB/s）+ 同步等待，
  以及首次 pipeline 编译。
- 若 `gpu` 占比 **< 40%**，A0 收益有限（瓶颈在 CPU 解释/HLE），应先按
  PERF.md §4.3 处理 `non-gpu` 部分，而不是继续投入渲染器。
- 硬件路径 **不会**降低顶点着色成本（iPhone 默认 `shades=false`）；
  `zk_set_hardware_option("gpu_shaders","1")` 可切换并对比。

**首帧/卡顿风险**：`hardware.rs` 的 pipeline 缓存在桌面写到系统缓存目录；
iOS 上 `pipeline_cache()` 走 `$HOME/.cache/zakuro/pipelines/<title>.bin`
（`raster/hardware.rs:550`），App 沙盒 HOME 下可写，但**审核/清缓存/首次运行**
时缓存为空 → 第一次遇到新 draw 组合要在线编译 SPIR-V→MSL pipeline，
可能出现前几秒卡顿。缓解：预热（进游戏前空跑若干帧）、缓存路径改 `Library/Caches`
（上游改动，记 TODO）、或 A0 只作为实验包。

**工作量**：上游补丁 + 本分支代码已完成（本任务）；VM 上还需 1–2 人日出包/真机。

**验收标准（A0）**：

1. `zk_create` 日志出现 `zk[INFO] drawing on … through Vulkan`（MoltenVK/Metal
   设备名）且无 `drawing in software`；
2. `zk_perf` 的 `AOT active`、`interpreted %` 不变（渲染器切换不影响 AOT）；
3. 同场景 HUD `run` 相比软件包下降 ≥20%（否则记录数据并停止投入）；
4. 画面正确（与软件包肉眼对比，允许轻微驱动差异；不允许黑屏/花屏）；
5. 20 分钟 soak 不崩、不热崩、内存无持续增长；
6. 关闭开关（软件包）行为与改动前完全一致（回归）。

### 4.2 A1：GPU→GPU 呈现（CAMetalLayer + swapchain）

**价值**：去掉每帧 0.66MiB 回读与同步、降低呈现延迟；解锁 3D 立体/插帧/
纹理包/overlay 等 presenter 能力；让 fps 不再受 CPU 回读抖动影响。

**改动清单**：

| # | 改动 | 写者 |
|---|---|---|
| 1 | `zk_presenter_*` / `zk_create_presented` / `zk_present` session FFI（§2.2） | runtime-ffi |
| 2 | `UIView` + CAMetalLayer 容器、present 循环、尺寸/后台生命周期 | ios-shell |
| 3 | `ios/ZakuroBridge.h` 新原型 | ios-shell |
| 4 | 把 `zk_run_frame` 与 `zk_present` 串在同一 runtime 串行队列 | runtime-ffi + ios-shell |
| 5 | 真机验证 + 回归 | Lead/qa |

**工作量**：Rust 侧 2–3 人日（presenter 包装 + 共享 device + 生命周期 + 错误码），
ios-shell 2 人日（UIView 呈现 + CADisplayLink/free-run + 后台处理）。

**风险**：swapchain resize/旋转、后台/前台切换、App 生命周期与 `zk_destroy`
顺序（presenter 的 device 必须在 System 之后释放）、iOS 上 MoltenVK 的
`VK_ERROR_OUT_OF_DATE` 处理；这些 `VulkanPresenter` 已有实现，但 iOS 的
layer 尺寸/屏幕旋转是新的。

**验收标准**：画面无撕裂/闪烁；旋转/后台恢复正确；HUD `read top/bottom`
消失或 ≈0（不再回读）；fps 不低于 A0；soak 通过。

### 4.3 A2：渲染调优（A1 之后）

- `Config.resolution = 2`（内部 800×480）→ 画面更清晰，GPU 负载上升，用 HUD 决定；
- 顶点着色 GPU 化（`zk_set_hardware_option("gpu_shaders","1")`）与 CPU 化对比；
- pipeline 缓存预热/容量（`MOST_PIPELINE_BYTES = 64 MiB`）；
- 纹理包/3D 立体/插帧（presenter 能力，iOS 侧 UI 开关）。

## 5. Plan B：直接 Metal PICA 兼容层（v1 不做）

**是什么**：在 `zakuro-gpu` 里新增一个 Metal 渲染后端（替换/并列
`raster/hardware.rs` 的 Vulkan 实现）和 Metal 呈现，不经过 MoltenVK。
PICA200 语义（TEV 组合器、纹理格式/采样、光照表、雾、proctex、深度/混合/
逻辑运算）参考 **Pocket Native 的 GLES 3.1 渲染器（MIT）** 与
Citra/Azahar 的 GLSL **语义**（只参考，不复制代码）。

**两条子路线**：

- **B1：Metal 渲染后端**（对齐 `hardware.rs` 的结构：pipeline cache、
  per-draw uniform/push 常量、顶点格式、纹理格式映射、display transfer compute、
  TEV→MSL fragment）。工作量 3–6 周；风险是 TEV/光照/格式长尾回归，
  且要维护 Vulkan/Metal 两套后端（或彻底替换 Vulkan，桌面端也要回归）。
- **B2：AOT shader**（把 PICA 顶点/片段着色在构建期翻译成 MSL/metallib，
  用 3dsrecomp/工具链离线生成；运行期只剩参数绑定）。可与 B1 组合，
  额外 2–4 周；收益是去掉运行期 naga 翻译和首帧编译。

**预期收益**：相对 MoltenVK，主要省掉 Vulkan→Metal 的翻译层开销
（draw 提交 CPU 成本，经验值 5–20%），以及摆脱"MoltenVK 已弃用"的维护风险；
**不会**把 GPU 渲染本身变快多少（最终都是 Metal）。对当前 22.6ms 的瓶颈，
先做 Plan A 就能知道 GPU 路径的收益上限，Plan B 的增量通常小于 A。

**风险**：三周以上的工期、TEV/纹理/光照精度回归、双后端维护、
per-game 兼容矩阵重跑、无现成 iOS Metal 渲染器可抄（Pocket Native 是 GLES；
nxnative/S2Arm 的 Metal 呈现层可参考但非 PICA 渲染器）。

**结论**：v1 不做；若 I5 要做"去 MoltenVK + 极致性能"，按 B1→B2 立项，
并保留 Plan A 作为回退。**不要**现在从零写 Metal PICA 模拟器（任务背景已明确）。

**GLES 3.1 路线（Pocket Native 引擎）为什么不是首选**：iOS 的 OpenGL ES 已
弃用、未来可能移除；Pocket Native engine 是 ABI 7 的整套 fork（RECOMP.md
§0.5.2 已评估），切换成本大于 MoltenVK 补丁；其渲染器语义可作为 Plan B 的参考。

## 6. 最小 spike 计划（Lead 在 macOS VM + 真机执行）

> 本任务不做 macOS/xcodebuild（规则：VM 由 Lead 操作）。以下是可直接照抄的步骤。

### 6.1 S0：本分支已完成的验证（Linux，无需 VM/设备）

| 检查 | 命令 | 结果 |
|---|---|---|
| 默认构建 iOS 目标 | `cargo check -p zakuro-ios --target aarch64-apple-ios`（crate 拷入 Zakuro workspace，`ZAKURO_LINKED_PROGRAM_ID` 可选） | ✅ 通过（本次 1m03s，含 ash/naga/ash-window iOS 依赖编译） |
| `linked` feature | 同上 `--features linked` | ✅ 通过 |
| 上游 iOS 补丁可编译 | 打 §8 补丁后 `cargo check -p zakuro-ios --target aarch64-apple-ios` | ✅ 通过（`#[cfg(target_os="ios")]` 分支真实编译） |
| host 单测（默认） | `cargo test -p zakuro-ios --lib` | ✅ 20 passed / 1 ignored（`hardware_probe_makes_a_device`，需 host Vulkan） |
| host 单测（linked） | `ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 cargo test -p zakuro-ios --lib --features linked` | ✅ 23 passed / 1 ignored |
| 格式 | `cargo fmt -p zakuro-ios -- --check` | ✅（Zakuro workspace rustfmt 配置） |
| MoltenVK 二进制 | 未下载、未提交 | ✅ 仓库只有文本 |

### 6.2 S1：VM 上先验证 MoltenVK 能建 device（不出 IPA、不接设备）

目的：把"MoltenVK 加载/链接问题"与"iOS 真机问题"分开。

```bash
# 1) 本分支 + 上游 checkout（确保 main ≥ 2026-11-05，含 PR #26 的 instance 模块）
cd /mnt/f/project/3dapple      # 或 VM 上的仓库路径
git fetch && git checkout agent/runtime-ffi/I3-T10
scripts/build-zakuro-ios.sh     # 会 clone/patch third_party/zakuro（不提交）

# 2) 打 §8 的 iOS 补丁（third_party/zakuro 是本地目录，脚本不会覆盖已有 checkout）
#    在仓库根目录执行：
git -C third_party/zakuro apply ios/zakuro-ios/patches/0001-vulkan-on-ios.patch

# 3) 本 crate 拷进 workspace（脚本已做），跑 host 单测 + MoltenVK 探针
cd /mnt/f/project/3dapple
cp -R ios/zakuro-ios third_party/zakuro/crates/zakuro-ios
cd third_party/zakuro
brew install molten-vk vulkan-loader 2>/dev/null || true   # 若 VM 上没有
cargo test -p zakuro-ios --lib                             # 期望 20 passed / 1 ignored
cargo test -p zakuro-ios --lib -- --ignored hardware_probe_makes_a_device
# 期望：ok；若非 0，看 stderr 的 "zk_hardware_probe: no Vulkan device: …"
#（这一条走 macOS 的 MoltenVK 加载路径，证明 ash + SharedDevice 代码本身没问题）
```

### 6.3 S2：VM 上出 A0 IPA（**不改 Swift 代码**）

1. **准备 MoltenVK**（不提交）：

```bash
mkdir -p build/third_party/moltenvk
cd build/third_party/moltenvk
curl -LO https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-ios.tar
shasum -a 256 MoltenVK-ios.tar   # 期望 b5d947b1…78c1
tar xf MoltenVK-ios.tar
# 动态（推荐 spike）：MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework
# 静态（备选）：    MoltenVK/MoltenVK/static/MoltenVK.xcframework
```

2. **ios/app 链接 MoltenVK**（写者 ios-shell；最小 spike 也可由 Lead 手改）：
   - 动态：把 `MoltenVK.xcframework` 加进 target 的
     *Frameworks, Libraries, and Embedded Content*，选 **Embed & Sign**；
     Xcode 默认 `LD_RUNPATH_SEARCH_PATHS = @executable_path/Frameworks` 即可。
     XcodeGen 写法（示意，最终以 ios-shell 的 project.yml 为准）：
     ```yaml
     dependencies:
       - framework: ../../build/third_party/moltenvk/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework
         embed: true
         codeSign: true
     ```
   - 静态（备选）：`OTHER_LDFLAGS` 追加
     `-L$(SRCROOT)/../../build/third_party/moltenvk/MoltenVK/MoltenVK/static/MoltenVK.xcframework/ios-arm64
      -lMoltenVK -lc++ -framework Metal -framework Foundation -framework QuartzCore
      -framework CoreGraphics -framework IOSurface -framework UIKit`；
     同时需要 §8.3 的静态加载扩展（**未验证**，spike 不建议）。
3. **打开硬件渲染**（二选一，都不需要 Swift 代码）：
   - 推荐：`ZAKURO_LINKED_PROGRAM_ID=0004000000055E00 ZAKURO_IOS_HARDWARE=1 \
     cargo build -p zakuro-ios --release --features linked --target aarch64-apple-ios`
     （本实现在 `zk_create` 里用 `option_env!("ZAKURO_IOS_HARDWARE")` 读取；
     取值 `1`/`on`/`true`/`yes`）；
   - 或 App 启动时调 `zk_set_hardware_renderer(1)`（需要 ios-shell 在 bridging
     header 加原型，见 §7.3）。
4. **出包**：`scripts/build-game-ipa.sh <game>` 照旧；IPA 里应含
   `Frameworks/MoltenVK.framework`（动态方案）或体积 +6.8MiB（静态方案）。
5. **先验链接**：`nm -g App.app/App | grep zk_hardware` 应看到新符号；
   `otool -L App.app/App | grep -i moltenvk` 静态方案没有、动态方案有一行。

### 6.4 S3：真机最小验证（A0）

1. 装 IPA，`idevicesyslog` 抓日志：
   ```bash
   idevicesyslog | grep -E 'zk_create|zk_hardware|zk\[|zk_perf|drawing on|MoltenVK' | tee i3t10-a0.log
   ```
2. 期望看到（顺序不严格）：
   - `zk_hardware_probe: a Vulkan device was made`（若 App 调了 probe）；
   - `zk[INFO] drawing on Apple … through Vulkan`（loader 的日志，设备名来自 MoltenVK）；
   - `zk_create: the 3D draws on the host GPU through Vulkan (MoltenVK over Metal on iOS) at 1x; …`
   - **没有** `zk[WARN] … drawing in software`。
3. 稳定场景记录一条 `zk_perf` 行（第 2–3 个窗口），抄出 `run/frame avg`、
   `gpu`、`non-gpu`、`read top/bottom`、`cpu %`、`interpreted %`、`draws/xfr/fills`。
4. A/B：同一 ROM、同一场景，换软件包（`ZAKURO_IOS_HARDWARE` 不设）复测，
   填 `docs/qa/i3-aot-pokemon-y.md` 的表格（不加游戏截图）。
5. 若失败：
   - `zk_hardware_probe == -1` → 看 `no Vulkan device: …` 文本：通常是
     framework 没进 IPA（`otool -L`/`ls Frameworks`）、rpath 错、或签名被重签坏；
   - `probe == 0` 但 `drawing in software` → `vkCreateDevice`/管线失败，看
     `zk[WARN]`（可能是 depthClamp/扩展问题，记下来，回退软件不崩）；
   - 黑屏/花屏 → 记录游戏/场景，回退软件包，把日志给 runtime-ffi；
     不要继续投入，先确认是硬件渲染 emulation 差异还是 MoltenVK 驱动问题。

### 6.5 验收清单（交给 Lead）

- [ ] S1：VM 上 host 单测 + `hardware_probe_makes_a_device` 通过；
- [ ] S2：`cargo build --features linked` + `ZAKURO_IOS_HARDWARE=1` 成功，IPA 打出；
- [ ] S3：真机日志有 `drawing on … through Vulkan`，无 `drawing in software`；
- [ ] HUD：软件包 vs 硬件包 `run`/`gpu`/`non-gpu`/`read` 数据写入 qa 文档；
- [ ] 画面正确、20 分钟 soak 通过、内存/温度无异常；
- [ ] 软件包回归：不开开关时行为与 I3-T9 完全一致；
- [ ] `git status` 干净（MoltenVK tar/framework/IPA 不进仓库）。

## 7. 本分支新增的 FFI（已实现并验证编译）

> 位置：`ios/zakuro-ios/src/lib.rs`。**没有改任何现有 `zk_*` 签名**；
> 新函数只在 `zk_create` 的 `Config.hardware_renderer` 处接入。`README.md`
> 已同步（函数表、错误契约、构建开关）。

### 7.1 C 原型（追加到 `ios/ZakuroBridge.h`，ios-shell 维护）

```c
int32_t     zk_hardware_probe(void);
int32_t     zk_set_hardware_renderer(int32_t enabled);
int32_t     zk_set_vulkan_library(const char *path);
int32_t     zk_set_hardware_option(const char *name, const char *value);
const char *zk_hardware_status(void *system);
```

### 7.2 行为

| 函数 | 说明 |
|---|---|
| `zk_hardware_probe()` | 像 `zk_create` 那样建一个 Vulkan device 再丢掉：0 = 能建（MoltenVK 已加载且可用），-1 = 不能（原因在 `zk_last_error` + stderr）。不需要 ROM，`zk_hardware_status(NULL)` 会报告它。用于 spike 的"MoltenVK 到底能不能用"先验 |
| `zk_set_hardware_renderer(enabled)` | 下一次 `zk_create` 起是否把 3D 画在宿主 GPU 上；0 = 软件。进程级；已加载的 System 不受影响。返回 0 |
| `zk_hardware_status(system)` | 一行状态：GPU/Vulkan 名称与倍率、请求了但回退、或纯软件。`system == NULL` 时报告上次 probe。指针归库所有，同 `zk_recompiled_status` 契约 |
| `zk_set_vulkan_library(path)` | 设置 `ZAKURO_VULKAN_LIBRARY`（给 §8 补丁用），指向 App 里 MoltenVK framework/dylib 的路径（`@executable_path/...` 或绝对路径）。0/-1 |
| `zk_set_hardware_option(name, value)` | 渲染器的环境开关白名单（NULL/空 = 取消）：`gpu_shaders`、`cpu_shaders`、`interpret_shaders`、`copy_screens`、`present_mode`、`gpu_times`、`wait_for_shaders`、`static_blend`、`float_depth`、`depth_blits`。必须在 `zk_create` 前调用，0/-1 |

**构建期开关**：`ZAKURO_IOS_HARDWARE=1`（`option_env!`）让新库默认开硬件渲染，
这样 A0 真机包**完全不用改 Swift**；正式发版不要设它，由 App 设置页调用
`zk_set_hardware_renderer`。

### 7.3 Swift 侧（ios-shell 若要运行时开关/状态）

```swift
// 加载 ROM 前
_ = zk_set_hardware_renderer(1)          // 或 0 回退软件
let status = String(cString: zk_hardware_status(nil))   // 启动页可显示
// 每秒/每帧
if let status = zk_hardware_status(system) { hudLine = String(cString: status) }
```

## 8. 需要上游 Zakuro 的补丁（已验证编译）

### 8.1 为什么必须打

`crates/zakuro-gpu/src/instance.rs` 的 `entry()` 是 Zakuro 唯一加载 Vulkan
实现的地方。macOS 的 MoltenVK 查找是上游 PR #26（2026-11-05 合入）加的；
iOS 分支不存在，`ash::Entry::load()` 在 iOS 上等于 `dlopen("libvulkan.dylib")`，
必然失败 → 硬件渲染器永远回退软件。

### 8.2 补丁（`crates/zakuro-gpu/src/instance.rs`，20 行）

```diff
diff --git a/crates/zakuro-gpu/src/instance.rs b/crates/zakuro-gpu/src/instance.rs
@@
-//! the system's Vulkan library and an instance of it, on any host, macOS's
-//! included, where Vulkan is MoltenVK over Metal and only shows up to an
+//! the system's Vulkan library and an instance of it, on any host, macOS's and
+//! iOS's included, where Vulkan is MoltenVK over Metal and only shows up to an
@@
 const MACOS_LIBRARIES: [&str; 4] = […];
 
+/// where an iOS app keeps MoltenVK: as a framework it embeds, whose install
+/// name is `@rpath/MoltenVK.framework/MoltenVK`, or as a dylib of its own.
+/// `ZAKURO_VULKAN_LIBRARY` names another path first.
+#[cfg(target_os = "ios")]
+const IOS_LIBRARIES: [&str; 2] = [
+    "@executable_path/Frameworks/MoltenVK.framework/MoltenVK",
+    "@rpath/libMoltenVK.dylib",
+];
+
@@ pub(crate) fn entry() -> Result<ash::Entry, ash::LoadingError> {
+    // a path the app chose wins: an iOS host points at the MoltenVK it
+    // embeds with it, and a mac at a copy the list below does not name
+    if let Some(path) = std::env::var_os("ZAKURO_VULKAN_LIBRARY") {
+        // SAFETY: a Vulkan library at a path of its own
+        if let Ok(entry) = unsafe { ash::Entry::load_from(&path) } {
+            return Ok(entry);
+        }
+    }
     // SAFETY: loads the system's Vulkan library, which is the documented way
     // to start
     let error = match unsafe { ash::Entry::load() } {
@@
     #[cfg(target_os = "macos")]
     for path in MACOS_LIBRARIES { … }
+    #[cfg(target_os = "ios")]
+    for path in IOS_LIBRARIES {
+        // SAFETY: as above, a Vulkan library at a path of its own
+        if let Ok(entry) = unsafe { ash::Entry::load_from(path) } {
+            return Ok(entry);
+        }
+    }
     Err(error)
 }
```

完整可应用的 diff 已随本分支提交：
[`patches/0001-vulkan-on-ios.patch`](patches/0001-vulkan-on-ios.patch)
（在仓库根目录 `git -C third_party/zakuro apply ios/zakuro-ios/patches/0001-vulkan-on-ios.patch`）。
**本任务已验证**：打了这段补丁后
`cargo check -p zakuro-ios --target aarch64-apple-ios` 通过（iOS 分支真实编译）。

**建议同时向上游提 PR**：与 PR #26 同一模式（"让 macOS 的 MoltenVK 查找也认
iOS"），上游作者已接受过一次同类改动，合并后可去掉本地补丁。

### 8.3 静态链接 MoltenVK 的扩展（备选，未验证）

若 A0/后续决定静态链接，补丁再加一个 Cargo feature + 静态入口：

```rust
// zakuro-gpu/Cargo.toml: [features] ios-static-moltenvk = []
#[cfg(all(target_os = "ios", feature = "ios-static-moltenvk"))]
pub(crate) fn static_entry() -> ash::Entry {
    unsafe extern "C" {
        // MoltenVK 的静态库始终导出它，即使其他 vk* 被 MVK_HIDE_VULKAN_SYMBOLS 隐藏
        fn vkGetInstanceProcAddr(
            instance: vk::Instance,
            name: *const std::ffi::c_char,
        ) -> vk::PFN_vkVoidFunction;
    }
    unsafe {
        ash::Entry::from_static_fn(vk::StaticFn {
            get_instance_proc_addr: vkGetInstanceProcAddr,
        })
    }
}
```

并在 `entry()` 最前面 `#[cfg(all(target_os="ios", feature="ios-static-moltenvk"))]
{ return Ok(static_entry()); }`。需要 App 侧链接 `libMoltenVK.a` + 系统框架
（§3.3）。**这条没在真机验证过，spike 不要用。**

## 9. 风险与缓解

| # | 风险 | 可能性/影响 | 缓解 |
|---|---|---|---|
| R1 | 上游 `main` 漂移，补丁/API 失效 | 中/中 | 补丁只碰 `instance.rs` 一个函数；`ZAKURO_REF` 固定 commit；build script 已记录 |
| R2 | macOS VM 的 Xcode 16.4 链接 MoltenVK 1.4.2（Xcode 26.5 构建）失败 | 中/中 | 先试 1.4.2；失败换 1.4.0/1.3.x（≥1.3.0）或升级 Xcode（Lead 决定） |
| R3 | iOS 上 `depthClamp` 或其它 device feature 被 MoltenVK 拒绝 | 低/低 | device 创建失败 → loader 自动回退软件、不崩；日志可见；必要时上游把 depthClamp 改可选（~5 行） |
| R4 | 动态 framework 侧载被重签坏/rpath 错 | 中/中 | `otool -L` 检查；`ZAKURO_VULKAN_LIBRARY` 指绝对路径兜底；再不行改静态 |
| R5 | 首次运行 pipeline 编译卡顿（缓存空） | 高/低 | 记 QA；预热帧；后续把缓存路径改 `Library/Caches`（上游 TODO） |
| R6 | 硬件渲染 emulation 差异导致画面错误 | 中/中 | 保留软件包；`zk_set_hardware_renderer(0)` 运行时回退；逐游戏记录 |
| R7 | readback 抵消收益（`sync_gpu` 等 GPU） | 低/中 | 先测 HUD read；A1 消掉；或降低内部分辨率/降低 fps 上限换稳定 |
| R8 | MoltenVK 弃用/停止更新 | 高/低（短期） | 固定版本；I5 评估 Plan B 作为替代；不阻塞 v1 |
| R9 | IPA 体积/审核 | 低/无 | 侧载不审核；+4.6/6.8MiB 可接受 |
| R10 | 与 AOT/帧循环互相影响（首帧/长帧） | 低/中 | A0 只换渲染器，帧循环语义不变；free-run（I3-T9）继续用 |

## 10. 决策建议与下一步

**决策树**：

```text
先抓一条稳态 zk_perf（软件包）
 ├─ AOT interpreting / interpreted% 高 → 先修 AOT（RECOMP.md），不碰渲染器
 ├─ gpu 占 run < 40% → 先优化 non-gpu / 呈现（PERF.md §4.3），A0 不急
 └─ gpu 占 run ≥ 40% → 做 A0（2 天内可出数据）
      ├─ run 降 ≥20% 且画面/soak 正常 → A0 进主线的可选开关；按需做 A1
      ├─ 收益一般但画面正常 → 保留 A0 实验开关，先做 HUD/CPU 优化；A1 视 3D/纹理包需求
      └─ MoltenVK/驱动问题多 → 回软件，记录 issue；Plan B 进 I5 评估
```

**给 Lead 的立即动作（按顺序）**：

1. 决定是否接受"上游补丁 + ios-shell 链接 MoltenVK"的改动（本文件 §8 + §6.3）；
2. 在 VM 上跑 S1（半天）：host 单测 + `hardware_probe_makes_a_device`，
   确认 MoltenVK 能建 device；
3. 让 ios-shell 在 `ios/app` 里 embed `MoltenVK.framework`（动态），
   `ios/ZakuroBridge.h` 加 §7.1 的原型（可选，spike 不需要）；
4. 用 `ZAKURO_IOS_HARDWARE=1` 出 A0 IPA，真机按 §6.4 采集数据；
5. 数据回填 `docs/qa/i3-aot-pokemon-y.md`，据此决定 A1 是否立项。

## 附录 A：关键文件索引（上游 main，2026-11-12）

| 文件 | 内容 |
|---|---|
| `crates/zakuro-core/src/lib.rs:38` | `Config`（`hardware_renderer`/`device`/`resolution`/`interpolate`） |
| `crates/zakuro-core/src/lib.rs:1050`/`1094`/`1183` | `read_screen_scaled` / `gpu_screen` / `read_screen`（`zk_read_screen` 用的） |
| `crates/zakuro-core/src/loader.rs:202` | loader 自动 `enable_hardware_renderer` + 软件回退 |
| `crates/zakuro-gpu/src/lib.rs:667`/`692`/`711`/`799` | `enable_hardware_renderer` / `draws_on_gpu` / `shows_directly` / `scale` |
| `crates/zakuro-gpu/src/device.rs:10`/`27` | `SharedDevice` / `SharedDevice::new()` |
| `crates/zakuro-gpu/src/instance.rs` | Vulkan 库查找（**iOS 缺口**，§8 补丁） |
| `crates/zakuro-gpu/src/raster/hardware.rs:550`/`1577`/`1711`/`5609`/`5619`/`5714` | pipeline cache 路径 / `with_device` / `shades` 默认 / `can_render` / `render_device` / `own_device` |
| `crates/zakuro-gpu/src/backend/mod.rs:12`/`356` | `ScreenImage` / `Presenter` trait |
| `crates/zakuro-gpu/src/backend/vulkan.rs:140`/`425`/`607` | `VulkanPresenter::new` / swapchain / `shared_device` |
| `crates/zakuro/src/present.rs:235` | 桌面 `create_vulkan`（A1 的参考接线） |
| `crates/zakuro-gpu/shaders/*.spv` | 预编译 SPIR-V（构建期 `include_bytes!`） |

## 附录 B：实测数据（本任务，2026-11-12）

| 项 | 值 |
|---|---|
| 上游 main | `fearkov/zakuro` 0.2.32 / `recomp-abi` `df82e6e3`（与 PERF.md 一致） |
| `cargo check -p zakuro-ios --target aarch64-apple-ios` | ✅ ~63 s（首次，含 ash/ash-window/naga 的 iOS 依赖编译） |
| 同 + `--features linked` | ✅ |
| 打 §8 补丁后再 check | ✅ |
| host 单测（默认 / linked） | 20 passed +1 ignored / 23 passed +1 ignored |
| MoltenVK-ios.tar v1.4.2 | 34,535,424 B，SHA256 `b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1` |
| `libMoltenVK.a`（ios-arm64） | 7,132,224 B（6.80 MiB），`ar t` 1 个 prelink 对象 |
| 动态 `MoltenVK.framework/MoltenVK` | 4,822,128 B（4.60 MiB），`LC_ID_DYLIB = @rpath/MoltenVK.framework/MoltenVK` |
| framework `MinimumOSVersion` | 15.0（构建：Xcode 26.5 / iphoneos 26.5） |

## 附录 C：参考

- MoltenVK v1.4.2 release：<https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.2>
- MoltenVK 运行指南（安装/静态动态/系统框架/最低系统）：`Docs/MoltenVK_Runtime_UserGuide.md`（随包）
- MoltenVK 支持的扩展列表：同上 §Supported Extensions
- Zakuro PR #26（macOS 上的 MoltenVK，2026-11-05 合入）：
  <https://github.com/fearkov/zakuro/pull/26>
- ash（`Entry::load`/`load_from`/`from_static_fn`）：<https://docs.rs/ash/0.38.0>
- ash-window（iOS/`RawWindowHandle::UiKit` → `vkCreateMetalSurfaceEXT`）：
  <https://github.com/ash-rs/ash>
- 类似 iOS 经验（非本项目代码，仅参考"bare-name dlopen 看不到 App Frameworks"）：
  DXVK iOS 补丁 <https://github.com/ammaarreshi/Generals-Mac-iOS-iPad/blob/master/Patches/dxvk-ios.patch>
- Pocket Native（Plan B 的 PICA→GLES 语义参考，MIT）：
  <https://github.com/whovian64/pocket-native>
- 项目内：[`PERF.md`](PERF.md)、[`RECOMP.md`](RECOMP.md)、
  [`README.md`](README.md)、[`../app/README.md`](../app/README.md)、
  [`docs/pocket-native.md`](../../docs/pocket-native.md)、
  [`docs/qa/i3-aot-pokemon-y.md`](../../docs/qa/i3-aot-pokemon-y.md)
