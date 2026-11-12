# 20 分钟 Soak 检查清单

> 适用：iOS 真机、单款 ROM、无 CPU JIT 的 AOT / 解释器构建。20 分钟不崩是 I3 / I4 的最低稳定性门槛（AGENTS.md §3.1）。
> 记录格式见 [`README.md`](README.md) §3；结果回填到当次记录（如 [`i3-aot-pokemon-y.md`](i3-aot-pokemon-y.md)）§3.7。
> 原则：**只记文字指标**；日志 / 截图留在本地（`logs/`、`build/`、`IPA/` 已忽略），不入库。

## 0. 前置条件（不满足先修，不要硬跑）

- [ ] **构建核对**：`sha256sum <ipa>` = 记录值；bundle id 正确；构建提交已知。
- [ ] **AOT 状态已知**：状态行 `AOT: …` + syslog `[3ds2apple] AOT linked=…`；
      解释器包应为 `interpreter shell`（判读见 i3 记录 §4）。
- [ ] **ROM 匹配**：title ID = linked program id（Pokémon Y `0004000000055E00`）；
      region / 版本一致；无 update / DLC（当前 FFI 只跑基础 ROM，RECOMP.md §6）。
- [ ] **设备 / 系统**：iPhone 14 Pro Max / iOS 26.7.2（换设备必须注明型号与系统）。
- [ ] **电量 ≥80% 且不充电**（避免充电发热干扰热测试；必须充电时在记录里注明）。
- [ ] 低电量模式**关闭**；自动锁定 ≥5 min 或临时"永不"；亮度 / 原彩固定。
- [ ] 关闭其他 App；通知 / 来电静音（避免打断 soak）。
- [ ] 起始手感温度正常（凉 / 温，不烫）；室温（可选）。
- [ ] 可用存储 ≥5 GB（ROM 副本 + `Documents/data`）。
- [ ] 日志已开：`idevicesyslog | tee logs/soak-<date>.log`（本地，不提交）。
- [ ] 崩溃基线：`idevicecrashreport -e logs/crash-before/`。
- [ ] 记录前先 **Unload 再 Load**（干净状态；`frames` 从 0 开始计）。

## 1. 时间线（必做）

| 时间 | 动作 | 期望 | 记录 |
|---|---|---|---|
| T+0 | Load ROM，等首帧，读状态行 | `Loaded: …`；fps / frames 有值；`last: completed`；`AOT: …`；`audio: on` | fps、frames、AOT、audio |
| T+0–5 | 连续运行固定场景（开场 / 标题，不操作） | fps 稳定，无 red card | 每 60 s 记一次 `frames` 算 fps_avg |
| T+5 | 读状态行 | 同上 | fps、frames |
| T+5 | **后台切换**：上滑回桌面 / 切别的 App 10 s 再回来 | 返回显示 "Runtime stopped"（有意设计），不崩；后台期间无音频 | 是否崩溃 / 是否静音 |
| T+6 | **Load last** 恢复 | 恢复出画；fps 重新计（frames 归零） | pass / fail |
| T+7 | **Mute / Unmute ×3** | 立即静音 / 恢复；Unmute 不重放旧声音；不崩 | pass / fail |
| T+8 | **Unload → Load last** | 画面清空 → 重新加载成功；无卡键 | pass / fail |
| T+8 | 读状态行（重载后） | `last: completed` | fps、frames |
| T+10 | 读状态行 | 无衰减 / 衰减幅度 | fps、frames |
| T+12 | （可选）手柄热插拔、隐藏 / 显示 overlay | "Controller: …" 出现 / 消失；无卡键 | pass / fail |
| T+15 | 读状态行 | 同上；记录温度手感 | fps、frames、温度、audio |
| T+20 | 结束前读状态行；Unload | 不崩溃；Unload 成功清屏 | fps、frames、AOT、audio |
| T+20 | 杀 App 重开 → Load last | 恢复成功，不崩 | pass / fail |

## 2. 全程观察项（随时记，失败立刻标注时间点）

- [ ] `last:` 始终是 `completed`（`faulted` / `bad handle` / red card = fail）。
- [ ] fps 无骤降 / 停更（状态行 fps 停更 = 帧循环卡死）。
- [ ] 音频：断音模式（间隔 / 时长）；Mute 后彻底静音；Unload / 后台后无声。
- [ ] 上下屏持续刷新，无黑屏 / 花屏 / 错位（只写文字描述，**不截图入库**）。
- [ ] 输入：无卡键；隐藏 overlay 后按键释放；触摸仍可点。
- [ ] 设备温度：手感（凉 / 温 / 热 / 烫）+ fps 是否同步下降（热降频迹象）。
- [ ] 内存：syslog 无 `jetsam` / `memorystatus` / `low memory` 杀进程；App 不闪退。
  - RSS 可选：Xcode → Instruments（需 Xcode 与设备直连 macOS）；做不到时记
    `n/a（无 RSS 读数）`，用行为观察代替。
  - 建议后续由 ios-shell 在诊断日志里输出 `phys_footprint`（I4 前）。
- [ ] 中途没有开启充电 / 低电量模式（会改变热与性能行为）；如开启必须注明。

## 3. 数据表（填完贴进当次记录）

| T (min) | fps（状态行） | frames | fps_avg（Δframes/Δt） | audio | AOT | 温度手感 | 备注 |
|---|---|---|---|---|---|---|---|
| T+0 | | 0 | — | | | | Load 成功 |
| T+5 | | | | | | | |
| T+10 | | | | | | | |
| T+15 | | | | | | | |
| T+20 | | | | | | | 结束 |

- fps_avg 只在**同一次加载内**计算（重载 / Unload 后 `frames` 归零，重新起算）。
- 没有逐帧计时 HUD 时，1% low 记 `n/a`；不要用 fps 抖动冒充。
- 期间若发生后台 / Unload / 重载，在"备注"标注，并在其后重新起算 fps_avg。

## 4. 通过标准（全部满足才 `pass`）

- [ ] 20 分钟无 crash、无 force-quit、无 red card。
- [ ] `last: completed`（或正常 `exited`）贯穿全程；无 `faulted` / `bad handle`。
- [ ] 后台切换 → Load last 通过。
- [ ] Unload → Load last 通过；无卡键。
- [ ] Mute / Unmute 通过；Unload / 后台后无音频残留。
- [ ] 无 jetsam / 低内存杀进程。
- [ ] 性能衰减有界：T+20 的 fps_avg **不低于** T+5 的 70%（暂定热降频容差，I3 结束前可调；
      低于则记 `fail` 并附温度 / fps 曲线，由 Lead 判定是否可接受）。
- [ ] 结论与证据一致（无证据 = `pending`，不是 `pass`）。

## 5. 失败判读

| 症状 | 可能原因 | 要抓的证据 |
|---|---|---|
| 状态行 `last: faulted` / red card | `zk_run_frame` 返回 -1 / -2（CPU fault / 句柄失效） | syslog `frame loop ending` + `zk_last_error` 文本；最后 fps / frames |
| 完全卡死无响应 | 单帧超长（软件渲染 / HLE）或死锁 | 最后状态行读数；syslog 最后 50 行 |
| App 闪退 | 内存（jetsam）/ 崩溃 | `idevicecrashreport` 报告摘要（本地路径）；崩溃前 fps / 温度 |
| fps 骤降 | 热降频 / 后台未恢复 / AOT 回退？ | 温度手感、AOT 状态行、syslog、时间点 |
| 音频残留 / 爆音 | 音频生命周期 bug | `audio:` 状态、操作序列、syslog audio 行 |
| 输入失效 / 卡键 | 输入类问题 | 操作序列，交 ios-shell |
| 加载失败 | ROM / 存储 / 句柄 | `zk_last_error` 文本、剩余存储 |

## 6. 收尾

- [ ] 停 `idevicesyslog`；`idevicecrashreport -e logs/crash-after/`。
- [ ] 对比 `crash-before/` 与 `crash-after/`；有新增报告 → 本次记 `fail`，报告留本地并写摘要。
- [ ] 从日志摘 AOT / loader / audio / frame loop 行（去掉 UDID / 用户名）写入记录"崩溃 / 日志"。
- [ ] 填记录 §3.7 / §3.8：结论 + 复测条件；更新游戏记录文件（如 i3 记录 §2 / §6）。
- [ ] 本地日志 / 截图不入库；确认 `git status` 干净。

## 7. 后续（I4 复用）

- 每款游戏 / 每个重要构建至少跑 1 次 20 min soak；10 款矩阵按 [README.md](README.md) §3 记录。
- 若热降频 / 内存成为瓶颈：热 → iOS 侧降分辨率 / 渲染器优化任务；
  内存 → ios-shell（HUD / 缓冲复用）或 runtime-ffi（RSS 诊断）提 issue。
