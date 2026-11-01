# Changelog

## 0.6.13 — 2026-11-01

- Reject invalid write IDs and mismatched/non-string read-back fields; preserve committed receipts without retries.


## 0.6.12 — 2026-11-01 · 复审第四轮终案：取消磁盘凭证免催

### Changed

- **`turn_stored` 恒 False（复核④终案）**：跨事件（UserPromptSubmit→Stop 为两个独立 hook 进程）不存在「写磁盘即不依赖文件操作成功」的当前请求身份——同会话 `_state_update`（load→patch→rename）的读改写交错可回滚新 prompt/generation：旧 `mark_store` 读取后暂停 → 新 `mark_prompt` 提交 → 旧写 `os.replace` 落盘 → 旧凭证复活，Stop 误免催新轮。四轮复审逐个证伪各加锁/屏障方案后，按复审建议**取消该免催优化**（同已合并的 zcode/dimcode 终案）：Stop 唯一的防重依据回归 **latch 语义**（Stop nudge 时 O_EXCL 创建、下一次真实 prompt 删除——「已催过」由锁存在性判定，不依赖任何读到的旧磁盘凭证）。`on_stop` 删除 `turn_stored` 调用分支（latch_claim 后直接 nudge deny）。**「记：」成功回执仍诚实输出给模型**；状态文件（`st_<sid>.json`）保留作诊断轨迹，不再影响 Stop 决策。副作用：每请求 Stop 至多催一次（原本有凭证时免催的轮次现在会催——模型回执已说明已存，会直接结束，无额外引擎调用）。

### Fixed

- 测试：翻转所有依赖磁盘凭证免催的断言——「记：成功后本轮凭证免催」改为「记：成功后 Stop 仍 deny（免催已取消）」，B 会话本轮凭证只免催自己改为同向催存断言；屏障交错测试保留（状态文件隔离仍防回滚，断言恒不因磁盘凭证免催）；`stored_turn_skip` 留痕断言随分支删除。

## 0.6.11 — 2026-11-01 · 复审第二轮整改（三项 P2）

### Fixed

- **内部提示不得重新武装收尾锁（轮#1）**：`on_prompt` 改序——空检查 → `/nomem`（照旧 mark，只跳召回）→ `skip_prefixes` 内部白名单（命中直接 return，**不 mark**——Qoder Recap 等宿主内部事件不算新真实请求，不删除一次收尾锁）→ `mark_prompt` → 其余。「真实请求 → Stop deny → 同会话内部 Recap → Stop」在宿主未带 `stop_hook_active` 时不再二次 deny。
- **readback 坏 details 防护（轮#2）**：`show` 回读的 `details` 先做 `isinstance(dict)` 检查——非空数组/字符串等坏信封局部降级 `unavailable`，保留 Saved 回执与禁止重发约束；核验段整体 try 兜底，任何回读异常绝不再外抛吞掉已经成功的写回执。
- **共享 map 读改写交错根除（轮#3）**：`turn_map.json` 单文件共享 map 改为**每会话独立状态文件 `st_<sid>.json`**（temp+rename 原子替换）——会话只写自己的文件，B 会话的旧快照写回不可能把 A 恢复成旧 `store_ts>=prompt_ts` 误免催；并发 A/B 更新互不丢失（文件级隔离）。写回执增记**写请求起始时刻 `store_req_ts`**：始于本轮 prompt 之前的写不归属本轮——旧请求延迟完成不再污染新请求的免催判定。陈旧会话文件只按数量收敛（≤128，不按时间失效），丢失只损失免催优化。
- `.gitignore` 增 `st_*.json`（旧 `turn_map.json` 保留兼容遗留文件）；README 行为表同步（内部提示不重武装、独立状态文件、回执绑定写请求世代）。

### Changed

- 测试：新增内部 Recap 序列（deny→Recap→不再 deny）、坏 details 两态反例（数组/字符串，Saved 回执保留＋降级 unavailable）、跨会话隔离（B 写不免催 A 新轮）、确定性屏障交错（B 写回窗口内 A 新 prompt：A 的 prompt_ts 不回滚、旧 store 不免催、B 更新不丢失、旧请求延迟完成回执不免催新轮）。

## 0.6.10 — 2026-11-01 · 维护者复审整改（复核#1~#5＋测试可靠性 blocker）

### Fixed

- **一次收尾锁重构（复核#1）**：`.store_turn` 单文件状态改为**每会话独立锁文件**（`O_CREAT|O_EXCL` 原子独占——并发 Stop 只有一个能落锁；锁无 TTL，25 小时后仍占用，只有新真实 prompt 删除重新武装，A→B→A 会话交错不丢锁）；无法落锁（状态目录不可写等）一律放行——绝不无锁 deny。prompt_ts/store_ts 存于尽力维护的 per-session map（`turn_map.json`，temp+rename 原子替换，仅按数量收敛），map 失败只损失免催优化，不影响一次上限保证。
- **畸形回执不再误报确定未写（复核#2）**：仅 `fail` 是白名单明确拒绝态、断言未接受；`ok`/`warn` 缺有效 id（hex/uuid 白名单校验）、非 dict summary（类型防护不抛异常）、未知 status、坏信封/超时一律归 **unknown**（只读核实指引＋禁止重发，绝不输出「did not accept」）。
- **unknown 核查共享 hook 预算（复核#3）**：remember/回读/只读核实共用同一截止时间（`RESPITE_HOOK_BUDGET_S`，默认 20s，预留 2.5s 输出余量）——慢坏回执后剩余不足直接 unknown，不再追加引擎调用，回执必能在宿主窗内输出。
- **回读全量核验（复核#4）**：`show` 回读须 id 相等＋标题相等＋**完整正文**相等才称 verified；错 id、40 字符后内容漂移→mismatch 如实标注；非 dict details 类型防护不外抛，保留已写回执。
- **免催凭证可归属化（复核#5）**：移除「全库最新写入时间晚于本轮 prompt 即免催」（无法归属会话，B 会话写入会误免催 A）；**Stop 不再发起任何引擎查询**；`/nomem` 仍算新请求（mark 前移重新武装收尾锁），只跳召回。

### Changed

- **测试可靠性 blocker 整改（CI 必跑）**：stub_engine.py 补 `#!/usr/bin/env python3` shebang（POSIX 侧 cp+chmod 直接 exec，无 shebang 在 Linux 报 Exec format error）；补 `CFG_OFFE` 定义（set -u 下未定义即整脚本中止）；`RESPITE_TURN_STATE` 全部走 `cygpath -m` 混合路径 `TURNBASE`（Windows python 解析不了 MSYS `/tmp`，锁会落到错误盘符）；PY3 探测 python3→python→py 逐个**实跑校验**（windows-latest 无 python3 shim；WindowsApps 商店占位能被 command -v 命中但一跑即退）；无 rsrs 引擎时真库分支记 SKIP、桩状态机/凭据守卫/纯函数套件照常执行；修「召回头行与条数一致」遍历字符串未分行导致的恒 BAD 断言；场景更新至新契约（引擎写入不免催、查库坏信封/死进程不影响 Stop、单次 nudge 零引擎查询、25 小时锁占用、新请求//nomem 重武装、跨会话凭证、状态目录不可写放行）。bash 75/0（真库）/69/0（CI 无引擎，SKIP 显式列出）。
- **CI 接入**：`ci-release.yml` 三平台 check job 新增 `Behavior suite (stubbed engine)` 步骤实跑 `bash tests/test_hooks.sh`——此前 CI 只跑 validate/credential_guard/release，状态机测试从未被执行。
- README 行为表同步（原子锁/免催可归属/不查引擎/缺 id 归 unknown/全量回读/共享预算）；`.gitignore` 增一次收尾锁与 turn map 状态文件。

## 0.6.9 — 审计整改：写结果状态机＋Stop fail-open＋请求级免催凭证（QD-01~QD-04）

### Fixed

- **QD-01 Stop fail-open**：查库 `list` 失败/超时/坏信封/死进程时直接放行，不再 deny——记忆层故障不得强迫主任务续跑。
- **QD-02 未知写结果只读核实**：超时/坏回执/无输出归为 **unknown**——回执明令「`rsrs list`/`rsrs show` 只读核实、禁止重发 remember」（旧文案「手动 rsrs remember 核实」有重复写风险）；秒回坏回执自动 `list` 核对并报告可能已写（附只读 id）。`warn`+有效 id 是**已写入带警告**，如实回执不误报失败。
- **QD-03 快存回执闭环**：ok/warn 后 `show` 写后回读核验（R11）；pending 保留候选短 id 与引擎建议动作全量（改＞并＞挂＞存，§7.2）；`.store_turn` 请求级免催凭证取代「近 10 分钟任意写入」跨轮抑制；一次收尾锁（宿主未带 `stop_hook_active` 时同一请求至多 deny 一次）。
- **QD-04 SKILL.md 信封文档修正**：标题档是 `details[].id/title`，嵌套 `entry` 是 `show`/`chain` 信封——修文档不改可用解析；remember 行同步 warn=已写不重发契约。

### Changed

- 测试：bash 套件换可移植 python 引擎桩＋场景复位＋状态机断言（54/9 → 72/0，--store 75/0）；`PROMPT_VAL` env 传 prompt（修 MSYS `/nomem` 路径转换与 heredoc CJK 码页乱码两个 Windows 伪故障——同修已回移植 zcode/dimcode 套件）；`RESPITE_TEST_FAST`/`RESPITE_TURN_STATE` 测试后门；README 行为表同步；`.gitignore` 增 `.store_turn`。
