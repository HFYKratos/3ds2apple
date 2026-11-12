# QA：设备验收记录

> 写者：qa-compat（写作用域 `docs/qa/`） · 建立：2026-11-12 · 适用：I1–I4 真机验收
> 目标：用**可复现的文字指标**记录每个构建 / 每款游戏的真机表现，供 Lead 验收、回归对比与 issue 归因。

## 1. 硬性规则

- 本目录只放**纯文本指标与日志摘要**。禁止提交：ROM、解密密钥、BIOS/系统文件、字体、游戏资源、生成的 C、IPA、静态库、游戏画面截图（AGENTS.md §2.1）。
- 禁止出现：Apple ID / 密码、设备 UDID、签名证书、含用户名的本机绝对路径（AGENTS.md §2.3）。
- 允许出现：IPA 文件名、**SHA256**、bundle id、ROM title ID / product code（元数据）、状态行原文、日志摘要、git 提交 SHA。
- 日志 / 截图只留在本地（`logs/`、`build/`、`IPA/` 均被 `.gitignore` 忽略）；给 Lead 看的截图走会话内传递，**不入库**。
- **结论必须有证据**。没有读数写 `pending` / `n/a` 并注明原因；不猜数字，不用瞬时 fps 抖动冒充 1% low。

## 2. 文件组织

| 文件 | 内容 |
|---|---|
| [`README.md`](README.md) | 本文件：记录格式、指标定义、采集命令、回填步骤 |
| [`soak-checklist.md`](soak-checklist.md) | 20 分钟 soak + 生命周期检查清单（I3 起每款复用） |
| `i<迭代>-<主题>.md` / `i<迭代>-<主题>-<游戏>.md` | 单次 / 单游戏验收记录，例如 [`i3-aot-pokemon-y.md`](i3-aot-pokemon-y.md) |

- 命名：全小写、连字符。
- 一次构建 / 一次验收一份记录；新数据追加"更新记录"或新小节，**不覆盖历史数字**（历史是回归基线）。

## 3. 记录格式（必填字段）

### 3.1 元信息

| 字段 | 示例 | 说明 |
|---|---|---|
| 日期 | 2026-11-12 | 本地日期 |
| 设备 / 系统 | iPhone 14 Pro Max / iOS 26.7.2 | 换设备必须写明 |
| 测试者 | 用户名 / Lead | 谁在真机上操作 |
| 场景 | 开场固定画面 / 语言选择 | **必填**，性能只允许同场景比较 |
| 对照 | 解释器基线 `ad237e6d…` | 本次对比对象 |

### 3.2 构建（Build）

- IPA 文件名、体积、**SHA256（64 位小写十六进制）**、bundle id。
- 链接形态：`interpreter shell`（`zk_linked_code()==0`）或 `linked AOT` + program id（`ZAKURO_LINKED_PROGRAM_ID`）。
- 构建提交（git SHA）；recomp 版本（3dsrecomp rev、ABI / generation，见 [RECOMP.md](../../ios/zakuro-ios/RECOMP.md) §5）。
- 安装方式（Sideloadly / AltStore）。注意：签名会改动可执行文件，**IPA 的 SHA256 只标识构建产物**，不标识设备上的二进制。

### 3.3 AOT 状态（AOT 构建必填）

| 证据 | 位置 | 例子 |
|---|---|---|
| 状态行原文 | App 状态行 | `AOT: linked, active` / `linked, interpreting` / `interpreter shell` / `?` |
| 诊断日志 | `idevicesyslog` | `[3ds2apple] AOT linked=1 recompiled=1 program=0x0004000000055E00 status=linked, active` |
| loader 日志 | `idevicesyslog` | 成功：`running the recompiled code linked in, N entry points, M modules`；回退：三类 warning（RECOMP.md §4） |

判读表见 [`i3-aot-pokemon-y.md`](i3-aot-pokemon-y.md) §4；**`linked, interpreting` 时的 fps 不是 AOT 数据**。

### 3.4 ROM

- 游戏名、文件名（`ROM/` 本地，不提交）、title ID（16 hex）、product code、region / 版本、update / DLC（当前 iOS FFI 只跑基础 ROM，应为"无"）。
- 不同 region / 版本 title ID 不同，内置代码会被拒并回退解释器（RECOMP.md §6）。

### 3.5 性能

| 指标 | 采集方式 | 口径 |
|---|---|---|
| 场景 | 人眼记录 | 必须与对照构建相同 |
| fps | App 状态行 | 0.5 s 窗瞬时 emulated 帧率 |
| fps_avg | 计帧法：两次读状态行 `frames`，`Δframes / Δ秒`（窗口 ≥60 s） | **无 HUD 时的主要性能证据** |
| 1% low | 待逐帧计时 HUD / 日志 | 无 HUD 时写 `n/a (HUD pending)`，不得估算 |
| 帧时间 avg / max | 待性能 HUD（各阶段毫秒） | 有 HUD 后填 |

### 3.6 音频

`audio: on|off|muted|failed` + 卡顿分级（0 无 / 1 偶发 / 2 频繁 / 3 持续）+ Mute/Unmute + Unload/后台是否静音。卡顿机制见 [i3-aot-pokemon-y.md](i3-aot-pokemon-y.md) §5。

### 3.7 稳定性

- 20 分钟 soak：结果 + 数据表（引用 [`soak-checklist.md`](soak-checklist.md)）。
- 后台切换、Unload / Load last、Mute、`last:` 值。
- 崩溃数、日志摘要（只摘 AOT / loader / audio / frame loop 行，去掉 UDID / 用户名）。

### 3.8 结论

状态词：

| 词 | 含义 |
|---|---|
| `pending` | 数据不足，等待真机结果 |
| `pass` | 满足验收，**且有证据** |
| `fail` | 不满足验收（崩溃 / 回退 / 指标不达标） |
| `blocked` | 被外部条件卡住（缺 ROM、缺构建、缺 HUD） |
| `n/a` | 本迭代不要求，或无法测量（写明原因） |

- `pass` 必须有状态行原文 / 日志行 / 数据表格支撑。
- 结论与上次不同时，写清楚"改了什么"（构建变更 / 场景变更 / 设备变更）。
- 需要复测时写清 **复测条件 + 责任人**。

### 3.9 复制模板

```md
### YYYY-MM-DD · <构建名> · <游戏>

- 设备：iPhone 14 Pro Max / iOS 26.7.2
- 构建：`<name>.ipa`，SHA256 `<64hex>`，bundle `com.kratos.3ds2apple.<game>`，提交 `<git sha>`
- 链接形态：linked AOT（program `0004000000055E00`）/ interpreter shell
- ROM：Pokémon Y（`Pokemon Y.cci`，自有不入库），title ID `0004000000055E00`，
  product code `CTR-P-EK2A`，region / 版本：<…>，update / DLC：无
- AOT：状态行 `<原文>`；syslog `AOT linked=… recompiled=… program=…`；
  loader `<running the recompiled code linked in … | 回退 warning>`
- 场景：<开场固定画面 / 语言选择 / 标题>
- 性能：fps `<状态行值>`；fps_avg `<Δframes/Δt>`；1% low `n/a (HUD pending)`
- 音频：`audio: <on/off/muted/failed>`；卡顿 `<0–3>`；mute `<pass/fail>`；
  Unload / 后台静音 `<pass/fail>`
- soak：20 min `<pass/fail>`；T+0/5/10/15/20 数据见 checklist §3；
  后台切换 `<pass/fail>`；Unload / Load last `<pass/fail>`
- 崩溃 / 日志：无 crash；syslog 摘要 `<…>`
- 结论：`<pending/pass/fail>`；复测条件：`<…>`
- 问题 / 下一步：<…>
```

## 4. 指标定义与陷阱

- **fps**：App 状态行 0.5 s 窗的 emulated 帧率；仅用于同场景、同构建、同窗口比较。
- **fps_avg**：`Δframes / Δt`，比瞬时 fps 稳；**重载 / Unload 后 frames 归零**，必须重新起算。
- **1% low**：帧时间分布最慢 1% 帧的平均帧时间（换算 fps），需要逐帧计时；当前 HUD 未上线时一律 `n/a`。
- **音频卡顿 ≠ 音频 bug**：模拟速度低于实时时，音频按 emulated 秒生成、按墙钟消费，必然欠载；先看 fps（见 i3 记录 §5）。
- **不可比的情况**：不同场景 / 不同音频开关 / 不同 ROM 版本 / 充电与不充电 / 冷机与热机。遇到就分开记录，不要合并成一个"平均 fps"。

## 5. 快速采集（设备 USB 接 Windows / Linux）

```bash
# 实时日志（含 App NSLog 与 Zakuro stderr）；本地落盘，不提交
idevicesyslog | tee logs/soak-$(date +%Y%m%d-%H%M).log

# 只抓关键行（另开一个终端）
idevicesyslog | grep -E --line-buffered \
  "\[3ds2apple\] AOT|recompiled code linked in|interpreting everything|could not use the code linked in|functions changed since|audio (started|session failed|engine failed)|frame loop"

# 崩溃报告（前后对比；只把摘要/文件路径写进文档）
idevicecrashreport -e logs/crash-after/
```

- 日志、截图只放本地 `logs/` / `build/` / `IPA/`（均被忽略）；入库的只有筛选后的摘要。
- 摘要里去掉 UDID、Apple ID、用户名路径（AGENTS.md §2.3）。

## 6. Lead 回填用户结果的最小步骤

1. 收到 IPA：`sha256sum` 核对与构建记录一致，记 bundle id、体积。
2. 收到状态行原文（截图 / 口述）：原样抄进"性能"和"AOT"字段（如 `26 fps · 1,482 frames · last: completed`、`AOT: linked, interpreting`）。
3. 收到 syslog：只留 §5 grep 出来的行，贴到"崩溃 / 日志"。
4. 按 [`soak-checklist.md`](soak-checklist.md) 跑 / 记录 20 min（用户操作、Lead 记录均可）。
5. 填"结论"：`pass` 必须有证据；不确定就 `pending`，并写复测条件。
6. 更新 [`i3-aot-pokemon-y.md`](i3-aot-pokemon-y.md) 的数据表与更新记录；新构建另起小节，不覆盖旧数字。

## 7. 相关文档

- [`../../AGENTS.md`](../../AGENTS.md)：硬性规则、质量门、命令速查
- [`../milestones.md`](../milestones.md)：各迭代真机验收记录与构建 SHA
- [`../integration.md`](../integration.md)：C ABI（`zk_linked_code` / `zk_recompiled` 等）
- [`../../ios/app/README.md`](../../ios/app/README.md)：状态行、帧循环、音频与 troubleshooting
- [`../../ios/zakuro-ios/RECOMP.md`](../../ios/zakuro-ios/RECOMP.md)：§4 运行期日志、§7 性能预期、§8.3 真机验收

## 8. 更新记录

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-11-12 | 建立目录：记录格式、指标定义、采集命令、回填步骤 | qa-compat |
