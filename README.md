# respire-qoder

> 吸即存，呼即取——给 Qoder 装上 respire 本地加密记忆。

`respire-qoder` 是 Dim 版 [respire-dimcode](https://github.com/risense-ai/respire-dimcode) 的 Qoder 移植：用 Qoder 的插件钩子，把 [respire 引擎（CLI 名 rsrs）](https://www.npmjs.com/package/@rsrsai/cli) 挂进 agent 循环——每轮标题档自动召回、「记：」一前缀即落库、收尾做一次存储检查。本地优先、端侧加密、云端 LWW 同步。

插件本身不含引擎，也不带自定义安装脚本；引擎缺失时会在会话内把安装命令交给 agent 代跑。

## 不装模型完全可用（降级是一等公民）

- **注册、登录、同步、召回全不依赖端侧模型**——装完插件即可用，未装模型时引擎自动走词面档。
- BGE-M3（约 1.1GB）是**纯可选增强**：想要更好的语义召回再 `rsrs model install && rsrs model activate m3`。插件检测到未装只提示一句，装与不装都不报错、不拦路。

## 安装

### 1. Qoder 插件

直接按目录安装：

```bash
qoder plugins install /absolute/path/to/respire-qoder
```

或按市场安装（本仓自带 `.qoder-plugin/marketplace.json`）：

```bash
qoder plugins marketplace add /absolute/path/to/respire-qoder
qoder plugins install respire-qoder@risense
```

装完在会话里执行 `/plugins reload`，或重启会话。Qoder Desktop 也可在插件设置里从本地目录安装；桌面版与 CLI 共用同一套插件目录与清单。

### 2. 引擎（缺失时 agent 可代装）

```bash
npm i -g @rsrsai/cli@latest
rsrs --version
```

无全局写权限时先试：

```bash
npm config set prefix ~/.npm-global
npm i -g @rsrsai/cli@latest
```

插件每轮实时探测引擎；装好**同会话内**即恢复召回与「记：」落库。

### 3. 注册登录（首次）

去 [rsrs.rs](https://rsrs.rs) 注册 → 本机 `rsrs register`。日常 `rsrs login` 浏览器授权；autosync 常开，`rsrs sync` 手动同步，`rsrs status` 查态。

## 装上后发生什么

| 时机 | 行为 |
| --- | --- |
| `SessionStart` | 注入记忆层简则（何时翻忆、如何落库、红线）；一次探测三态——未登录附注册引导、库空（<10 条）附首日存料引导、缺语义模型附**可选**装法；常态零打扰 |
| `UserPromptSubmit` | 自动 `rsrs recall --titles`：标题档注入，只给分数＋8 位短 id＋标题，正文由 agent `rsrs show <id>` 按需取；默认直出不过滤，噪音边界＝引擎 skip 门＋limit 5＋标题档 |
| prompt 以「记：」「存：」「remember:」开头 | 直接 `rsrs remember … --importance important` 落库并回执；判为相似时不写入、转述候选（`--parent` 挂靠或 `--force` 直写）由模型决断；回执要求模型抽「主语＋动作＋结果」事实句并 `retitle` 替换暂拟题 |
| `Stop` | 存储检查：`decision: deny` 续跑一轮，提示把本轮新的**事实/决定/约定/教训/踩坑**分条存入；`stop_hook_active=true` 时放行，防循环；`store_nudge_every` 节流；近 10 分钟已落库过则不再催 |
| `/nomem` 前缀 | 本轮跳过召回 |
| `$skill: 名称` 前缀 | 召回前剥除，防技能名词面污染 query |
| `skills/respire` | 按需加载的完整操作法；动作全由钩子驱动 |

## 与 Dim 版的差异

| 项 | Dim 版 | Qoder 版 |
| --- | --- | --- |
| 清单 | `.codex-plugin/plugin.json` | `.qoder-plugin/plugin.json` |
| 插件根占位符 | `${CLAUDE_PLUGIN_ROOT}` | `${QODER_PLUGIN_ROOT}` |
| 配置/日志目录 | 插件 `hooks/` | `QODER_PLUGIN_DATA`，无则回退 `hooks/` |
| Stop 阻塞 | `{"decision":"block"}` | `{"decision":"deny"}`（Qoder 文档语义） |
| 市场 | `dim plugin marketplace` | Qoder 本地目录安装或市场 |
| 引擎 | respire（rsrs CLI） | 同左 |

## 调优（可选）

配置优先级：

1. `RESPITE_CONFIG` 环境变量
2. `$QODER_PLUGIN_DATA/respire.config.json`
3. `<插件根>/hooks/respire.config.json`

从 example 复制即可：

```bash
cp hooks/respire.config.example.json hooks/respire.config.json
```

| 字段 | 默认 | 含义 |
| --- | --- | --- |
| `rsrs` | `""` | 引擎路径；空 = 自动探测（`RESPIRE_BIN` → PATH 的 `respire`/`rsrs` → `~/.local/bin` → `~/.rsrs/bin`） |
| `recall_threshold` | `0.0` | 召回下限；0=默认关（引擎直出），设正数才过滤 |
| `recall_limit` | `5` | 取前 N 条 |
| `min_prompt_chars` | `2` | 1 字才跳，2 字起即查 |
| `session_rules` | `true` | 是否注入 SessionStart 简则；若你已用 `rsrs inject` 往 `~/.qoder/rules` 写过 respire 全文，建议设 `false` 防双份注入 |
| `budget_chars` | `1500` | 单轮注入总预算 |
| `enabled` | `true` | 总开关：false=全线静默 |
| `store_nudge_every` | `1` | Stop 节流：1=每轮、N=每 N 轮、0=关 |
| `log` | `true` | `hook.log` 留痕（超 256KB 清轮） |

其它环境变量：`RESPIRE_BIN`（引擎路径）、`RESPITE_RSRS`（兼容旧名）、`RESPITE_LOG`、`RESPITE_NUDGE_STATE`。

过滤策略：默认不设阈值——三层已框住噪音：引擎 skip 门、limit 5、标题档。漏召代价远大于多看两行标题。

## 验证

```bash
python3 scripts/validate_plugin.py
bash tests/test_hooks.sh
```

直接验钩子（不依赖 Qoder 是否已加载插件）：

```bash
echo '{"hook_event_name":"UserPromptSubmit","prompt":"respire 记忆"}' \
  | python3 hooks/respire.py UserPromptSubmit
```

写探针（会写真实记忆库，用随机无义串并自动 `rsrs forget` 清理）：

```bash
bash tests/test_hooks.sh --store
```

## 设计要点

- **fail-open**：hook 任何异常 → 空 stdout + `exit 0`，永不拦会话；失败必留痕于 `hook.log`
- **纯文本输出**：SessionStart / UserPromptSubmit 的 stdout 即附加上下文，没有误拦面
- **标题档注入**：只回 id/score/title，正文交 `show` 按需拉取
- **判后即存尊重引擎**：落库不带 `--force`，`pending` 候选原样转述给模型决断
- **跨平台回退**：hook 命令带 `python3 || python`；配置与日志写 `QODER_PLUGIN_DATA`
- **包内自检**：结构、清单、hooks 形状、Python 可编译、敏感扫描

## 已知边界

- **召回质量是引擎上限**：用词鸿沟下 BGE-M3 可能漏召真条——简则已约束模型「命中不贴题换词补查」。
- **冷启动窗**：runtime 冷启＋模型加载实测 7s+，故 hook timeout 20s、recall 14s、probe 10s；探测失败时 SessionStart 注入诊断段。
- **未验证项**：本包在 Qoder CLI/Desktop 中的真实加载与 Stop 阻塞效果尚未真机安装验证；钩子脚本本身已用真引擎与假引擎分别跑通。Qoder 插件机制以官方文档为准：<https://docs.qoder.com/zh/cli/plugins-reference>、<https://docs.qoder.com/zh/cli/hooks-reference>。

## License

MIT
