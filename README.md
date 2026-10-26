# respire-qoder

> 吸即存，呼即取——给 Qoder 装上记忆层。

官网：<https://rsrs.rs> · 仓库：<https://github.com/risense-ai/respire-qoder> · 反馈与建议：[Issues](https://github.com/risense-ai/respire-qoder/issues) · 贡献代码：[Pull requests](https://github.com/risense-ai/respire-qoder/pulls)

`respire-qoder` 用 Qoder 的插件钩子，把 [respire 引擎（CLI 名 rsrs）](https://www.npmjs.com/package/@rsrsai/cli) 挂进 agent 循环：每轮回答前召回记忆库里已有的记录，prompt 以「记：」开头即写入，一轮结束时提醒 agent 存下刚学到的东西。**推荐注册并开启云同步**：到 [rsrs.rs](https://rsrs.rs) 注册后记录加密同步上云，在另一台设备登录同一账号即可取用；不注册也能用，但记录只存本机，设备丢了记录也就没了。

插件本身不含引擎，也不带自定义安装脚本；引擎缺失时会在会话内把安装命令交给 agent 代跑。

## 数据存储安全

1. **云同步是主路径**：去 [rsrs.rs](https://rsrs.rs) 注册后本机 `rsrs register` / `rsrs login`，记忆端到端加密上云，换设备、重装、换工具都不丢——推荐所有用户开启，插件检测到未登录会主动提示注册。
2. **同步到云端的是密文**：记录在本地加密后才上传，服务端只存加密记录；解密、索引、检索全在设备端完成，服务端不需要模型、也拿不到账户解密密钥——云端与运维方可见的只有密文。
3. **断网/未注册也能用**：记忆库是本机本地库，不联网、不注册、不登录时召回与落库照常；离线期间的写入留在本地队列不丢，联网登录后随 autosync 自动补同步。但本机存储会随设备丢失而丢掉记录，请尽快注册开启同步。
4. **企业可自建同步服务器**：服务端 `respire-server` 支持私有化部署（Docker Compose + Postgres），可整套架在企业内网离线运行，把同步端点指向自建服务即可，数据不出企业网络（部署步骤见 respire-docs《自托管》）。

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

### 3. 注册并开启云同步（推荐，首次）

去 [rsrs.rs](https://rsrs.rs) 注册 → 本机 `rsrs register`（首设备需本人设密码）。日常 `rsrs login` 浏览器授权；autosync 常开，`rsrs sync` 手动同步，`rsrs status` 查态。

不做这一步插件也能用，但记录只存本机：换设备、重装系统后取不到。SessionStart 探测到未登录时会自动注入注册引导，照做即可。

## 装上后发生什么

| 时机 | 行为 |
| --- | --- |
| `SessionStart` | 注入记忆层简则（何时翻忆、如何落库、红线）；一次探测三态——未登录附注册引导、库空（<10 条）附首日存料引导、缺语义模型附**可选**装法；常态零打扰 |
| `UserPromptSubmit` | 自动 `rsrs recall --titles`：标题档注入，只给分数＋8 位短 id＋标题，正文由 agent `rsrs show <id>` 按需取；默认直出不过滤，噪音边界＝引擎 skip 门＋limit 5＋标题档 |
| prompt 以「记：」「存：」「remember:」开头 | 直接 `rsrs remember … --importance important` 落库并回执；判为相似时不写入、转述候选（`--parent` 挂靠或 `--force` 直写）由模型决断；回执要求模型抽「主语＋动作＋结果」事实句并 `retitle` 替换暂拟题 |
| `Stop` | 存储检查：`decision: deny` 续跑一轮，提示把本轮新的**事实/决定/约定/教训/踩坑**分条存入；`stop_hook_active=true` 时放行，防循环；`store_nudge_every` 节流；近 10 分钟本库有过落库（问引擎 `list` 取最近 `updated_at`，覆盖 agent 直接 `rsrs remember`）则不再催 |
| `/nomem` 前缀 | 本轮跳过召回 |
| `$skill: 名称` 前缀 | 召回前剥除，防技能名词面污染 query |
| `skills/respire` | 按需加载的完整操作法；动作全由钩子驱动 |

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

- **首次召回稍慢**：会话开始后的第一次召回需要拉起引擎 runtime（装有语义模型时还要加载模型），实测 7 秒上下——慢在引擎冷启动，不在插件；插件按此设了宽松超时（recall 14s、probe 10s、单次 hook 总 20s），拉不起来时会在会话开头注入一条诊断提示。此后引擎常驻，后续召回通常秒回。

## 反馈与贡献

- 仓库与源码：<https://github.com/risense-ai/respire-qoder>
- 遇到问题、有功能建议：提 [Issue](https://github.com/risense-ai/respire-qoder/issues)，附会话场景与 `hook.log`（`QODER_PLUGIN_DATA/hook.log`，超 256KB 自动清轮）能大幅加速定位。
- 想贡献代码或文档：欢迎提 [Pull request](https://github.com/risense-ai/respire-qoder/pulls)，保持与现有风格一致，改动后跑一遍 `python3 scripts/validate_plugin.py` 与 `bash tests/test_hooks.sh`。
- 产品本身的问题（引擎、账号、同步）：<https://github.com/risense-ai/respire> 的 Issues，或官网 <https://rsrs.rs>。

## License

MIT
