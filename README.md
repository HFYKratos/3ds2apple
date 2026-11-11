# 3ds2apple

把 Nintendo 3DS 游戏以 **AOT 原生方式**带到 iPhone / iPad 的早期项目：游戏代码在构建时从 ARM 翻译为 ARM64，运行时不用 CPU JIT。

当前阶段：**可行性评估 + 执行计划**（Phase 0 尚未开始）。

> 仓库：<https://github.com/HFYKratos/3ds2apple> · 状态：规划中 · 许可：Apache-2.0

- [执行计划 v0.5（2026-11-11）](docs/plan.md)：首发 10 款、无本地 Mac、侧载、开源的落地方案；附录 B 讨论 Windows-only 出包（S2Arm 式）。
- [可行性评估 v0.2](docs/feasibility.md)：3dsrecomp + Zakuro 的通用 AOT 路线、iOS 缺口、工作量与风险。
- [可行性评估 v0.1](docs/feasibility-v0.1.md)：路线 A（Azahar/Cytrus）、B（AOT）、C（反编译）的横向对比。

## 结论摘要

- **可行，底座已经存在**：[3dsrecomp](https://github.com/fearkov/3dsrecomp)（ARM/Thumb/VFP → C 的静态重编译器）+ [Zakuro](https://github.com/fearkov/zakuro)（MIT 的 3DS HLE 运行时，用 AOT 代替 JIT）。
- 3dsrecomp 在测试游戏中约 **99.8% 的指令**由重编译代码执行；Zakuro 当前 **35 款测试游戏，34 款 Playable**。
- **缺的是 iOS 层**：Zakuro 只有 Windows/Linux/macOS；需要 Rust 静态库 + SwiftUI/UIKit + Metal/CoreAudio + 构建管线。估算 MVP 约 **9–14 人月**，产品级 **16–28 人月**。
- **不是 100% "无模拟器"**：CPU 代码是 AOT，但仍有 HLE 服务、GPU 模拟、约 0.2% 指令的解释器兜底。纯 AOT 只能单款（TriAevum）。
- **首发 10 款**：从 Zakuro 兼容表选 10 款（3D Land、MK7、OoT3D、ALBW、Pokémon USUM、MH4U、FE Fates、Kirby、ACNL、Smash），先跑通 1 款再扩。

## 无 Mac 的工作流

1. **Linux/Windows 本地**：跑 Zakuro 桌面版、3dsrecomp、ROM/资源处理、日常开发。
2. **按需云 Mac（1–2 周/批）**：每款游戏的 AOT C 编译 + Xcode 打包 + unsigned IPA；ROM 只临时放在云 Mac，构建后删除。
3. **Windows**：AltStore / SideStore / Sideloadly 签名安装；`idevicesyslog` / 崩溃报告调试。
4. **GitHub Actions（macOS）**：只构建不含游戏数据的通用壳/核心，公开仓库免费；不要把 ROM 传上去。

> **Windows-only 可行吗？** 每款游戏的打包/签名可以 Windows-only（S2Arm 式：预编译壳 + 游戏 dylib + 签名），但 **通用壳仍需 macOS 构建一次**；S2Arm 的壳也是 Mac 出的。3DS 还多一步 C→ARM64，Windows 上要用 `clang` + `ld64.lld` + `rcodesign`，需先做 spike。Metal Developer Tools for Windows 只解决 `.metal → .metallib`，不提供 iOS SDK/UIKit/链接/签名。详见 [plan.md 附录 B](docs/plan.md#附录-bwindows-only-出包s2arm-式可行吗)。

预算：云 Mac **$25–50/月**或 **$1–2/小时**；Apple Developer **$99/年**（10 个 IPA 建议付费）。

## 下一步

1. Phase 0（4–6 周）：Linux 跑通 Zakuro + 3dsrecomp 的 5 款游戏；租 1 小时云 Mac 出第一个 unsigned IPA；Windows 装到 iPhone 14 Pro Max。
2. Phase 1（3–5 个月）：通用 SwiftUI 壳 + `read_screen` → Metal + CoreAudio + GameController；10 款在云 Mac 上批量出 IPA。
3. Phase 2（4–6 个月）：MoltenVK、shader 性能、10 款兼容打磨、UI/存档/中文。

## 仓库结构

```
docs/
  plan.md              执行计划（10 款 / 无本地 Mac）
  feasibility.md       技术可行性（v0.2）
  feasibility-v0.1.md  三条路线横向对比
NOTICE                 版权/商标/无 ROM 声明
THIRD_PARTY.md         计划依赖与参考项目的许可证
CONTRIBUTING.md        贡献指南（禁止 ROM/keys）
LICENSE                Apache-2.0
```

## 许可与声明

- 本仓库自己的代码与文档：**Apache-2.0**。
- 计划使用的 [Zakuro](https://github.com/fearkov/zakuro) 与
  [3dsrecomp](https://github.com/fearkov/3dsrecomp)：**MIT**；见
  [THIRD_PARTY.md](THIRD_PARTY.md)。
- 本仓库**不包含**任何 Nintendo ROM、解密密钥、系统文件、字体或游戏资源。
- 与 Nintendo 无关联；Nintendo 3DS 是 Nintendo Co., Ltd. 的商标。
- 提交前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。