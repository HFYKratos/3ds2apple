# iOS 集成：Zakuro 静态库

## 状态

- [x] `zakuro-core` 在 `aarch64-apple-ios` 上 `cargo check` 通过
- [x] `libzakuro_ios.a` 构建成功（Release，约 52 MB）
- [x] Cranelift shader JIT 已在 workspace 层关闭（iOS 不允许可执行内存）
- [ ] 链接进 SwiftUI App
- [ ] ROM 导入 + `zk_create`
- [ ] 帧循环 + 上下屏显示
- [ ] 音频 + 触摸/手柄输入
- [ ] 3dsrecomp 代码链接

## 构建

需要 macOS + Xcode + Rust：

```bash
rustup target add aarch64-apple-ios
scripts/build-zakuro-ios.sh
```

脚本会：

1. clone `fearkov/zakuro`（默认 `main`，可用 `ZAKURO_DIR` / `ZAKURO_REF` 覆盖）；
2. 在 workspace 里加入 `crates/zakuro-ios`；
3. 把 `zakuro-gpu` 的 workspace 依赖设为 `default-features = false`，关闭 `jit`；
4. `cargo build -p zakuro-ios --release --target aarch64-apple-ios`；
5. 把 `libzakuro_ios.a` 复制到 `build/ios/`。

> `build/` 已在 `.gitignore` 中，静态库不进仓库。

## C ABI

头文件由 Swift bridging header 手写；函数签名见
[`ios/zakuro-ios/src/lib.rs`](../ios/zakuro-ios/src/lib.rs)。

| 函数 | 作用 |
|---|---|
| `zk_create(rom, data_dir)` | 加载解密后的 `.3ds` / `.cci`，返回不透明 `System*`；失败返回 NULL |
| `zk_run_frame(sys)` | 跑一帧；0 完成，1 退出，-1 fault，-2 空指针 |
| `zk_screen_width/height(which)` | 0=上屏 400×240，1=下屏 320×240 |
| `zk_read_screen(sys, which, out, cap)` | 读 RGBA8；返回完整字节数（可能大于 cap） |
| `zk_take_audio(sys, out, cap)` | 读 interleaved stereo `i16`；返回帧数 |
| `zk_set_input(sys, buttons, cx, cy, touch, tx, ty)` | 3DS HID 位掩码、圆盘摇杆、触摸 |
| `zk_destroy(sys)` | 释放 |

`buttons` 使用 3DS HID 位布局（`PadState`）：A=1<<0、B=1<<1、Select=1<<2、
Start=1<<3、Right=1<<4、Left=1<<5、Up=1<<6、Down=1<<7、R=1<<8、L=1<<9、
X=1<<10、Y=1<<11、ZL=1<<14、ZR=1<<15。

## Swift 侧注意

- 所有 `zk_*` 调用必须串行（建议专用 `DispatchQueue`），`System` 不是线程安全的。
- `zk_create` 可能耗时数秒，放在后台队列；成功后主线程更新 UI。
- ROM 从 `UIDocumentPicker` 选入后复制到 App 的 `Documents/roms/`，再把绝对路径传给
  `zk_create`。
- 首版用 `zk_read_screen` + `CGImage` 显示；后续再上 Metal 纹理。
- 音频采样率以 `zakuro-core` 的 `AUDIO_SAMPLE_RATE` 为准（3DS DSP 常见 32730 Hz），
  首版可先不出声，避免音频线程拖慢帧循环。

## 已知风险

- `libzakuro_ios.a` 链接时可能需要额外系统框架（`Security`、`CoreFoundation` 等），
  以链接器报错为准。
- 静态库 52 MB，App 体积会明显增大；后续可 `strip`/`-dead_strip`。
- ROM 的版本/更新/DLC 需要与 3dsrecomp 生成的代码匹配；首版先用「无重编译、纯解释器」
  验证画面，再接 3dsrecomp。