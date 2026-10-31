# respire-qoder

> 吸即存，呼即取——给 Qoder 装上记忆层。

官网：<https://rsrs.rs> · 仓库：<https://github.com/risense-ai/respire-qoder> · 反馈与建议：[Issues](https://github.com/risense-ai/respire-qoder/issues) · 贡献代码：[Pull requests](https://github.com/risense-ai/respire-qoder/pulls)

`respire-qoder` 用 Qoder 的插件钩子，把 [respire 引擎（CLI 名 rsrs）](https://www.npmjs.com/package/rsrs-cli) 挂进 agent 循环：每轮回答前召回记忆库里已有的记录，prompt 以「记：」开头即写入，一轮结束时提醒 agent 存下刚学到的东西。**推荐注册并开启云同步**：本机执行 `rsrs register` 注册账号，记录加密同步上云，在另一台设备 `rsrs login` 登录同一账号即可取用；不注册也能用，但记录只存本机，设备丢了记录也就没了。

插件本身不含引擎，也不带自定义安装脚本；引擎缺失时会在会话内把安装命令交给 agent 代跑。

## 数据存储安全

1. **推荐开启云同步**：本机 `rsrs register` 注册账号（本人设登录密码，保存系统生成的 A3 恢复码），记录加密同步到云端，换设备、重装后仍可取用。插件检测到未登录时会提示。
2. **云端只存密文**：记录在本地加密后才上传，服务端只保存加密记录。解密、索引、检索都在设备端完成，服务端不需要模型，也拿不到账户解密密钥，云端和运维方看到的只有密文。
3. **断网/未注册也能用**：记忆库是本机本地库，不联网、不注册、不登录时召回与写入照常；离线期间的写入留在本地队列不丢，联网登录后随 autosync 自动补同步。但本机存储会随设备丢失而丢掉记录，请尽快注册开启同步。
4. **企业可自建同步服务器**：服务端 `respire-server` 支持私有化部署（Docker Compose + Postgres），可整套架在企业内网离线运行，把同步端点指向自建服务即可，数据不出企业网络（部署步骤见 respire-docs《自托管》）。

## 不装模型也可使用

- 注册、登录、同步、召回都不依赖端侧模型。未装模型时，引擎按字面文本匹配召回，功能完整可用。
- BGE-M3 模型（约 1.1GB）为可选安装：装上后召回按语义匹配，效果更好。执行 `rsrs model install && rsrs model activate m3`；未装时插件只提示一次，不影响正常使用。

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
npm i -g rsrs-cli@latest
rsrs --version
```

无全局写权限时先试：

```bash
npm config set prefix ~/.npm-global
npm i -g rsrs-cli@latest
```

插件每轮实时探测引擎；装好后同一会话内即恢复召回与「记：」写入。

### 3. 注册并开启云同步（推荐，首次）

本机执行 `rsrs register` 注册账号：本人设登录密码，系统生成 A3 开头的恢复码，须保存好，丢失后数据无法解开。注册完成后即已登录，autosync 常开；之后在本机 `rsrs login` 浏览器授权登录，`rsrs sync` 手动同步，`rsrs status` 查看状态。

不做这一步插件也能用，但记录只存本机：换设备、重装系统后取不到。SessionStart 探测到未登录时会自动注入注册引导，照做即可。

## 安装后的行为

| 时机 | 行为 |
| --- | --- |
| `SessionStart` | 注入记忆使用规则（何时召回、如何写入、限制）；一次探测，三种提示：未登录附注册引导，记忆库为空（<10 条）附首日使用引导，缺语义模型附可选安装说明；配置齐全时不提示 |
| `UserPromptSubmit` | 自动执行 `rsrs recall --titles`，只注入分数＋8 位短 id＋标题，正文由 agent 用 `rsrs show <id>` 按需读取。默认不设过滤阈值，噪音由三处控制：引擎 skip 门、limit 5、标题形式注入 |
| prompt 以「记：」「存：」「remember:」开头 | 直接 `rsrs remember … --importance important` 写入并回执；引擎判为相似时不写入，把候选原样转述给模型决定（`--parent` 挂靠或 `--force` 直写）；回执要求模型抽「主语＋动作＋结果」事实句并 `retitle` 替换暂拟题 |
| `Stop` | 存储检查：`decision: deny` 续跑一轮，提示把本轮新的事实、决定、约定、教训分条写入；`stop_hook_active=true` 时放行，防止循环；`store_nudge_every` 节流；近 10 分钟本库有过写入（问引擎 `list` 取最近 `updated_at`，覆盖 agent 直接 `rsrs remember`）则本轮不再提示 |
| `/nomem` 前缀 | 本轮跳过召回 |
| `$skill: 名称` 前缀 | 召回前剥除，避免技能名干扰召回查询 |
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
| `session_rules` | `true` | 是否注入 SessionStart 规则；若你已用 `rsrs inject` 往 `~/.qoder/rules` 写过 respire 全文，建议设 `false` 避免重复注入 |
| `budget_chars` | `1500` | 单轮注入总预算 |
| `enabled` | `true` | 总开关：false=全线静默 |
| `store_nudge_every` | `1` | Stop 节流：1=每轮、N=每 N 轮、0=关 |
| `log` | `true` | `hook.log` 留痕（超 256KB 清轮） |

其它环境变量：`RESPIRE_BIN`（引擎路径）、`RESPITE_RSRS`（兼容旧名）、`RESPITE_LOG`、`RESPITE_NUDGE_STATE`。

过滤策略：默认不设阈值。噪音由三处控制：引擎 skip 门、limit 5、标题形式注入。漏掉真正相关的记录代价更高，所以宁可多显示两行标题。

## 验证

```bash
python3 scripts/validate_plugin.py
python3 tests/test_credential_guard.py
python3 -m unittest discover -s tests -p test_release.py -v
bash tests/test_hooks.sh
```

前三项不需要真实引擎：守卫测试使用临时桩、配置和日志，强制验证普通输入确实召回，再验证凭据零调用，以及死桩必须使正向对照失败。CI 在 Linux、Windows、macOS 运行这三项。`test_hooks.sh` 是旧的真实引擎套件，不在 CI 中运行。

### GitHub Actions 发布

PR 和 main 推送仅测试、打包，不发布。向主仓推送 `vMAJOR.MINOR.PATCH` 标签后，工作流验证标签提交属于 main、标签版本与 manifest/hook 一致，从该提交 `git archive` 生成根目录 ZIP。发布 job 才获得仓库 `GITHUB_TOKEN` 的 `contents: write`，无需新增 PAT、OAuth 或仓库 secret。

恢复一个已有标签的未完成发布：在 Actions → CI and release → Run workflow 中选择 **main**，填写已有 `tag` 与其精确 40 位提交 `expected_sha`。例如 `v0.6.8` 对应 `c969187b085f934b1edce27de25117a8591dc661`。工作流从该标签提交打包，不移动标签、不执行旧标签中的代码，也不把当前 main 当作旧标签代码。

ZIP 注释记录提交 SHA；Release 同时上传 ZIP 和 `SHA256SUMS`。重复执行只接受来源标记相同且 SHA256 一致的已有资产，补齐缺失资产后发布；遇到未知来源、不同内容或额外资产即停止，绝不覆盖。上传中断时可能保留待恢复的草稿。`check` 和 `package` 默认只读；fork PR 不能进入写发布 job，工作流不使用 `pull_request_target`。

隔离测试不等于真实 Qoder 宿主/引擎端到端验收，也不证明旧真实引擎套件全部通过。

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

- **fail-open**：hook 出现任何异常时输出空内容并 `exit 0`，不中断会话；异常写入 `hook.log`
- **纯文本输出**：SessionStart / UserPromptSubmit 的 stdout 即附加上下文，不会误拦截会话
- **只注入标题**：召回结果只给 id/score/title，正文由 agent 用 `show` 按需读取
- **写入判断交给引擎**：写入时不带 `--force`，引擎返回的 `pending` 候选原样转述给模型决定
- **跨平台回退**：hook 命令带 `python3 || python`；配置与日志写 `QODER_PLUGIN_DATA`
- **包内自检**：结构、清单、hooks 形状、Python 可编译、敏感扫描

## 已知边界

- **首次召回较慢**：会话开始后的第一次召回需要启动引擎 runtime（安装了语义模型时还要加载模型），实测约 7 秒。插件按此设了宽松超时（recall 14s、probe 10s、单次 hook 总 20s），启动失败时在会话开头注入诊断信息。引擎启动后常驻，后续召回通常秒级返回。

## 反馈与贡献

- 仓库与源码：<https://github.com/risense-ai/respire-qoder>
- 遇到问题、有功能建议：提 [Issue](https://github.com/risense-ai/respire-qoder/issues)，附会话场景与 `hook.log`（`QODER_PLUGIN_DATA/hook.log`，超 256KB 自动清轮）能大幅加速定位。
- 想贡献代码或文档：欢迎提 [Pull request](https://github.com/risense-ai/respire-qoder/pulls)，保持与现有风格一致，改动后跑一遍 `python3 scripts/validate_plugin.py` 与 `bash tests/test_hooks.sh`。
- 产品本身的问题（引擎、账号、同步）：<https://github.com/risense-ai/respire> 的 Issues，或官网 <https://rsrs.rs>。

## License

MIT
