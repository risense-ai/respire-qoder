# Changelog

## 0.6.9 — 审计整改：写结果状态机＋Stop fail-open＋请求级免催凭证（QD-01~QD-04）

### Fixed

- **QD-01 Stop fail-open**：查库 `list` 失败/超时/坏信封/死进程时直接放行，不再 deny——记忆层故障不得强迫主任务续跑。
- **QD-02 未知写结果只读核实**：超时/坏回执/无输出归为 **unknown**——回执明令「`rsrs list`/`rsrs show` 只读核实、禁止重发 remember」（旧文案「手动 rsrs remember 核实」有重复写风险）；秒回坏回执自动 `list` 核对并报告可能已写（附只读 id）。`warn`+有效 id 是**已写入带警告**，如实回执不误报失败。
- **QD-03 快存回执闭环**：ok/warn 后 `show` 写后回读核验（R11）；pending 保留候选短 id 与引擎建议动作全量（改＞并＞挂＞存，§7.2）；`.store_turn` 请求级免催凭证取代「近 10 分钟任意写入」跨轮抑制；一次收尾锁（宿主未带 `stop_hook_active` 时同一请求至多 deny 一次）。
- **QD-04 SKILL.md 信封文档修正**：标题档是 `details[].id/title`，嵌套 `entry` 是 `show`/`chain` 信封——修文档不改可用解析；remember 行同步 warn=已写不重发契约。

### Changed

- 测试：bash 套件换可移植 python 引擎桩＋场景复位＋状态机断言（54/9 → 72/0，--store 75/0）；`PROMPT_VAL` env 传 prompt（修 MSYS `/nomem` 路径转换与 heredoc CJK 码页乱码两个 Windows 伪故障——同修已回移植 zcode/dimcode 套件）；`RESPITE_TEST_FAST`/`RESPITE_TURN_STATE` 测试后门；README 行为表同步；`.gitignore` 增 `.store_turn`。
