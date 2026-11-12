# I3 · Pokémon Y：AOT 对比与性能记录

> 状态：**pending**（AOT 是否真的生效待诊断包确认） · 建立：2026-11-12 · 设备：iPhone 14 Pro Max / iOS 26.7.2
> 记录格式见 [`README.md`](README.md) · 构建来源：[`../milestones.md`](../milestones.md)、[`RECOMP.md`](../../ios/zakuro-ios/RECOMP.md) §4 / §7 / §8.3

## 1. 结论速览（截至 2026-11-12 12:00）

- **解释器基线：26 fps**（I3-T1 真机验收；状态行原文 `26 fps · 1,482 frames · last: completed`）。
- **AOT 包：28 fps**（+2 fps，+8%），音频明显卡顿。这是一个**旧 AOT 包**，App 里还没有 AOT 状态行，
  因此**无法确认 3dsrecomp 生成代码是否真的在执行**。
- **新 AOT 诊断包**（SHA256 `2487dde4…`，bundle `com.kratos.3ds2apple.pokemon-y`，构建提交 `61dd949`）
  状态行新增 `AOT: linked, active | linked, interpreting` 行；用户安装中，结果待回填（§8）。
- 在 AOT 状态确认前：**28 fps 不能作为"AOT 性能"归档**，也不能用来评价 3dsrecomp 收益。
- 26 → 28 fps 的对比本身也还不成立（场景 / 构建差异，见 §3）。
- 音频卡顿在 28 fps 下有明确机制解释（模拟速度 < 实时 → 音频欠载），属预期现象，见 §5。

## 2. 构建与测量记录

| 构建 | 用途 | IPA SHA256 | 体积 | bundle | 构建提交 | 状态 |
|---|---|---|---|---|---|---|
| `3ds2apple-I3T1.ipa` | 解释器基线（无音频） | `ad237e6d906a08716f822ac76ab45c79a93736ac51f43f66e00860b0508cfb7f` | 2.3 MB | `com.kratos.3ds2apple` | 未记录（I3-T1 合并后） | 已验收：26 fps |
| `3ds2apple-I3T4-audio.ipa` | 解释器 + 音频链路 | `23dee490088fbc939711fcc84fffb600330ed4684959871dbd337a4ddae3200b` | 2.3 MB | `com.kratos.3ds2apple` | 未记录 | 已验收；断音属预期 |
| `pokemon-y-AOT.ipa`（旧） | AOT 首次真机对比 | `bb15392cbb2a01671edd4c54453ce39521e5af6a09989504cc59411b4e7360ad` | 85 MB | `com.kratos.3ds2apple.pokemon-y` | 未记录（早于 `61dd949`） | 用户实测 28 fps；AOT 状态未知 |
| `pokemon-y-AOT.ipa`（诊断包） | 确认 AOT 是否生效 | `2487dde4510e4b105f10342d5ddc779b4b6cb47b6ab19dc57008789ddeb7c054` | 88,478,232 B | `com.kratos.3ds2apple.pokemon-y` | `61dd949` | **安装中（2026-11-12）**，待回填 |

说明：

- 本仓库 `IPA/pokemon-y-AOT.ipa` 当前内容 = **诊断包**，本地 `sha256sum` 与用户报告值一致，
  `Info.plist` 的 `CFBundleIdentifier` = `com.kratos.3ds2apple.pokemon-y`（已核对）。
- 旧基线包 `bb15392c…` 的文件已被覆盖；若要复测旧基线，需要重新构建。
- 构建来源（RECOMP.md §3 / §5）：3dsrecomp 固定 rev `df82e6e`（ABI **5** / generation **5**）→
  489 个 C 文件 ≈ 635 MiB → `librecomp.a` 283 MB → `libgame.a`；linked `libzakuro_ios.a` 的
  `ZAKURO_LINKED_PROGRAM_ID=0004000000055E00`；App 链接顺序 `-lzakuro_ios -lgame`。
- 诊断包在旧 AOT 包基础上只多了 AOT 状态行（提交 `61dd949`），输入 / 音频已在其中。

## 3. 测量口径（为什么 26 vs 28 还不能直接相减）

- 26 fps 的场景：语言选择 → 开场（I3-T1 验收，累计 1,482 帧）。
- 28 fps 的场景：**未记录**（Lead 转述用户实测，未附状态行 / 构建号）。
- 两个包不同：26 fps 基线包**没有音频**；AOT 包含输入 + 音频，音频线程和主线程发布可能影响帧节奏。
- 因此必须按同一场景、同一操作、同一窗口复测后再比较：

  | 要求 | 值 |
  |---|---|
  | 场景 | 建议停在开场固定画面（不操作） |
  | 窗口 | ≥60 s 计帧法：`fps_avg = Δframes / Δ秒` |
  | 对照 | 解释器包与 AOT 包各测一次；同设备、同亮度、同充电状态 |

- **1% low / 帧时间 avg-max**：当前 App 只有 0.5 s 窗瞬时 fps，没有逐帧计时，记 `n/a`。
  待 I3-T6 性能 HUD（各阶段毫秒）与 I3-T5 FFI 帧计时（`zk_run_frame` 耗时等）合并后再补。

## 4. AOT 状态判读表（装诊断包后照此填）

| 状态行原文 | 配套 syslog 证据 | 含义 | 28 fps 算 AOT 数据？ | 下一步 |
|---|---|---|---|---|
| `AOT: linked, active` | `AOT linked=1 recompiled=1 program=0x0004000000055E00`；loader：`running the recompiled code linked in, N entry points, M modules` | 生成代码正在执行 | **是** | 进 §7 Q2：为何只 +8%；要 HUD 分阶段耗时 |
| `AOT: linked, interpreting` | loader 三类 warning 之一：title ID 不符 / ABI 不符（built for version V, this is 5）/ update 改动函数 | 回退解释器 | **否**（28 fps 是解释器数据） | 查 ROM title ID / region / 版本与 ABI；交 runtime-ffi / build-infra；**不按性能问题处理** |
| `AOT: interpreter shell` | 无 linked 符号 | 装成了纯解释器包 | 否 | 核对 bundle / SHA / 安装来源，重装 linked 包 |
| `AOT: ?` | 无 | 尚未加载，或诊断未执行 | 否 | 先 Load ROM，再读状态行与 syslog |

- 三类回退 warning 的原文与判读见 [`RECOMP.md`](../../ios/zakuro-ios/RECOMP.md) §4。
- 状态行来源：`ios/app/Sources/ROMSession.swift` 的 `AOTStatus`
  （`interpreter shell` / `linked, interpreting` / `linked, active` / `?`）。
- 诊断日志格式：`[3ds2apple] AOT linked=%d recompiled=%d program=0x%016llx status=%@`。
- 采集命令（Windows / Linux，设备 USB 连接）：

  ```bash
  idevicesyslog | grep -E --line-buffered \
    "\[3ds2apple\] AOT|recompiled code linked in|interpreting everything|could not use the code linked in|functions changed since"
  ```

## 5. 音频卡顿的当前解释（先别当 bug 修）

- 28 fps ≈ 46.7% 实时速度（按 60 fps 游戏算）→ 每墙钟秒只生成约 0.47 s 的 32730 Hz 音频 →
  ring buffer 欠载 → 短静音间隙。
- 机制见 [`ios/app/README.md`](../../ios/app/README.md) 的 Audio (I3-T4) 与
  "Why it can sound choppy before 3dsrecomp"；状态行 `audio: on` 表示引擎本身正常。
- 结论：这是**速度问题的必然结果**，不是音频缓冲 / 线程 bug。只有以下情况才按音频 bug 追：
  fps 已接近 60 仍持续断音 / 爆音、`audio: failed`、Unload 或切后台后仍有声音。
- 待记录：卡顿分级（0 无 / 1 偶发 / 2 频繁 / 3 持续）、Mute / Unmute 是否即时、
  Unload / 后台是否彻底静音。

## 6. 待补数据（按优先级）

| # | 字段 | 现状 | 来源 | 阻塞 |
|---|---|---|---|---|
| 1 | AOT 状态行原文（`linked, active` / `interpreting` / `interpreter shell`） | pending | 用户装诊断包后读状态行 | — |
| 2 | syslog AOT / loader 行 | pending | `idevicesyslog` grep（§4） | — |
| 3 | 同场景解释器 vs AOT 的 fps / fps_avg | pending | 按 §3 重测 | — |
| 4 | 1% low、帧时间 avg / max | pending | 性能 HUD / FFI 计时 | I3-T6 HUD、I3-T5 FFI |
| 5 | 20 分钟 soak | pending | [`soak-checklist.md`](soak-checklist.md) | — |
| 6 | 内存 / 热降频观察 | pending | 行为观察（可选 RSS） | 见 checklist §2 |
| 7 | 音频卡顿分级 | pending | 听感记录 | — |

## 7. 开放问题（给 Lead / 用户）

- **Q1（最高优先级）AOT 是否真的在执行？** 诊断包状态行 + syslog。
  若为 `linked, interpreting`，则 28 fps 与 AOT 无关，先修回退原因。
- **Q2 若 `linked, active`：为何只比解释器高 8%？** CPU 释放后瓶颈应转移，候选：
  软件 PICA200 顶点 / 光栅、`zk_read_screen` + CGImage 呈现、音频 pump、主线程发布。
  需要 I3-T6 HUD 分阶段毫秒 + I3-T5 帧计时定位（RECOMP.md §7 也预期瓶颈会转向 GPU）。
- **Q3 26 与 28 fps 是否同场景 / 同窗口？** 不同则对比无效，需按 §3 重测。
- **Q4 两个包除诊断行外还有哪些差异？** 28 fps 实测时音频是否已启用？会影响帧节奏对比。
- **Q5 音频卡顿严重度（0–3）与可接受阈值？** 是否需要"AOT 后仍卡顿就改音频时钟同步"的决策点。
- **Q6 20 分钟是否热降频？** fps 是否随设备温度下降（见 checklist）。

## 8. 用户结果回填区（待填，Lead 直接粘贴）

```md
- 构建：<IPA 名 / SHA256 / bundle / 安装方式>
- 状态行原文：<例如 28 fps · 1,234 frames · last: completed · audio: on · AOT: linked, interpreting>
- syslog 行：<[3ds2apple] AOT linked=… / running the recompiled code linked in …；如有回退，贴 warning>
- 场景：<停在哪个画面、是否操作>
- fps_avg：<60 s 计帧结果>
- 音频：卡顿分级 <0–3>；Mute/Unmute <pass/fail>；Unload/后台静音 <pass/fail>
- soak：<见 checklist §3 数据表；结论 pass/fail>
- 崩溃 / 异常：<无 / 描述>
- 结论：<pending / pass / fail>；复测条件：<…>
```

回填后请同步更新 §2 状态列、§6 现状列和 §9 更新记录。

## 9. 更新记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-11-12 | 建文件：解释器 26 fps / AOT 28 fps / 音频卡顿；诊断包 SHA 与本地校验；AOT 状态待回填 | qa-compat |
