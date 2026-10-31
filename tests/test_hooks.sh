#!/usr/bin/env bash
# respire 自测 —— 模拟 stdin 事件 JSON，逐分支断言。
# rsrs 无 data-dir 隔离（runtime 单例＋全局 client.json），故默认只读分支不碰库；
# 加 --store 才跑写探针（写真库→回执断言→rsrs forget 自清理）。
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY3="$(command -v python3)"
RSRS="$(command -v rsrs || true)"
[ -z "$RSRS" ] && RSRS="$HOME/.local/bin/rsrs"
[ -z "$RSRS" ] && RSRS="$HOME/.rsrs/bin/rsrs"
PASS=0; FAIL=0
WITH_STORE=0
[ "${1:-}" = "--store" ] && WITH_STORE=1

if [ -z "$RSRS" ] || [ ! -x "$RSRS" ]; then
  echo "SKIP：未找到 rsrs（respire 引擎），无法自测。"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG_ON="$TMP/config-on.json"
echo '{"session_rules": true}' > "$CFG_ON"
CFG_OFF="$TMP/config-off.json"
echo '{"session_rules": false}' > "$CFG_OFF"

# run <event> [prompt] [config]
run() {
  local ev="$1" pr="${2-}" cfg="${3:-$CFG_ON}"
  "$PY3" - "$ev" "$pr" <<'PY' | RESPITE_CONFIG="$cfg" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" "$PY3" "$ROOT/hooks/respire.py" "$ev"
import json, sys
ev, pr = sys.argv[1], sys.argv[2]
d = {"hook_event_name": ev, "cwd": "/tmp", "session_id": "selftest"}
if ev == "UserPromptSubmit":
    d["prompt"] = pr
sys.stdout.write(json.dumps(d, ensure_ascii=False))
PY
}

check() {   # check <名字> <实际输出> <模式: 非空|空|含:xxx|不含:xxx>
  local name="$1" got="$2" want="$3" ok=0
  case "$want" in
    非空) [ -n "$got" ] && ok=1 ;;
    空)   [ -z "$got" ] && ok=1 ;;
    不含:*) printf '%s' "$got" | grep -qF -e "${want#不含:}" && ok=0 || ok=1 ;;
    含:*) printf '%s' "$got" | grep -qF -e "${want#含:}" && ok=1 ;;
  esac
  if [ "$ok" = 1 ]; then
    PASS=$((PASS+1)); echo "PASS  $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL  $name  期望[$want] 实际[$(printf '%s' "$got" | head -c 200)]"
  fi
}

# Stop 节流分支的引擎桩：只回 list --json，fresh=刚落库 / stale=陈旧（真机库随时有人写，不能拿真引擎断言催/不催）
STUB_FRESH="$TMP/rsrs-fresh"; STUB_STALE="$TMP/rsrs-stale"
FRESH_TS="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
cat > "$STUB_FRESH" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = list ] && printf '{"command":"list","status":"ok","details":[{"id":"aaaaaaaaaaaaaaaa","created_at":"$FRESH_TS","updated_at":"$FRESH_TS","title":"fresh","content":"x"}]}'
exit 0
EOF
cat > "$STUB_STALE" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = list ] && printf '{"command":"list","status":"ok","details":[{"id":"bbbbbbbbbbbbbbbb","created_at":"2020-01-01T00:00:00.000Z","updated_at":"2020-01-01T00:00:00.000Z","title":"stale","content":"x"}]}'
exit 0
EOF
chmod +x "$STUB_FRESH" "$STUB_STALE"
CFG_STALE="$TMP/config-stale.json"
echo '{"session_rules": true, "rsrs": "'"$STUB_STALE"'"}' > "$CFG_STALE"
CFG_FRESH="$TMP/config-fresh.json"
echo '{"session_rules": true, "rsrs": "'"$STUB_FRESH"'"}' > "$CFG_FRESH"

# ---- 只读分支（真库查询，不写） ----
check "SessionStart 注入简则" "$(run SessionStart)" "含:respire memory layer"
check "简则点明引擎与同步" "$(run SessionStart)" "含:rsrs register / rsrs login"
check "已登录不带登录引导" "$(run SessionStart)" "不含:not signed in"
check "未登录注入登录引导" "$(RESPITE_FAKE_LOGGED_OUT=1 run SessionStart)" "含:not signed in"
check "未登录引导给出注册与代登法" "$(RESPITE_FAKE_LOGGED_OUT=1 run SessionStart)" "含:rsrs login --oauth --no-open"
check "session_rules=false 静默" "$(run SessionStart "" "$CFG_OFF")" "空"
check "已装模型不带提示" "$(run SessionStart)" "不含:semantic model (BGE-M3) is not installed"
check "缺模型注入装法" "$(RESPITE_FAKE_NO_MODEL=1 run SessionStart)" "含:rsrs model activate m3"
check "缺模型点明词面回退" "$(RESPITE_FAKE_NO_MODEL=1 run SessionStart)" "含:lexical tier"
check "有货库不带空库引导" "$(run SessionStart)" "不含:memory store is empty"
check "空库注入首日引导" "$(RESPITE_FAKE_EMPTY=1 run SessionStart)" "含:memory store is empty"
check "空库引导含导入线索" "$(RESPITE_FAKE_EMPTY=1 run SessionStart)" "含:extract facts"
check "README 载三件事(模型可选)" "$(cat "$ROOT/README.md")" "含:不装模型也可使用"
check "README 载 Qoder 装法" "$(cat "$ROOT/README.md")" "含:qoder plugins install"
check "包内无自定义安装脚本" "$( { [ -e "$ROOT/install.sh" ] || [ -e "$ROOT/uninstall.sh" ]; } && echo PRESENT || echo absent )" "含:absent"
check "探测失败注入冷启诊断段" "$(RESPITE_FAKE_PROBE_FAIL=1 run SessionStart)" "含:status probe failed"
# 日志留痕：任一事件后 hook.log 应有本行
run SessionStart >/dev/null
run SessionStart >/dev/null
# 凭据命中轮只记原因码、不落任何摘要（审计修复）——口令值不得入日志
run UserPromptSubmit "我的密码是 password: hunter2 这算敏感吗" >/dev/null
check "日志脱敏口令" "$(grep -q 'hunter2' "$TMP/hook.log" && echo LEAK || echo SAFE)" "含:SAFE"
# 脱敏机制本身仍在：#nomem 轮仍落 detail，redact 应把口令式赋值打码
run UserPromptSubmit "#nomem passwd: hunter2xk 复盘脱敏" >/dev/null
check "日志脱敏留痕" "$(grep -q 'REDACTED' "$TMP/hook.log" && echo YES)" "含:YES"
check "hook.log 留痕" "$(grep -q '"ev": "session"' "$TMP/hook.log" 2>/dev/null && echo YES)" "含:YES"

# 引擎缺失分支：单元注入 monkeypatch find_rsrs→None（真机造不出「全路径皆缺」）
check "引擎缺失注入装法" "$(ROOT="$ROOT" "$PY3" - <<'PY'
import io, json, os, sys, importlib.util
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT"], "hooks/respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.find_rsrs = lambda cfg: None
sys.argv = ["respire.py", "SessionStart"]
sys.stdin = io.StringIO('{"hook_event_name":"SessionStart"}')
try:
    m.main()
except SystemExit:
    pass
PY
)" "含:npm i -g rsrs-cli"

CFG_OFFE="$TMP/config-disabled.json"
echo '{"enabled": false}' > "$CFG_OFFE"
# 引擎缺失分支：monkeypatch find_rsrs→None（真机造不出全路径皆缺，走单元注入）
run_engineless() {
  ROOT="$ROOT" "$PY3" - <<'PY'
import io, json, os, sys, importlib.util
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT"], "hooks/respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.find_rsrs = lambda cfg: None
sys.argv = ["respire.py", "SessionStart"]
sys.stdin = io.StringIO('{"hook_event_name":"SessionStart"}')
try:
    m.main()
except SystemExit:
    pass
PY
}
# Stop 存储检查：<stop_hook_active>（节流断言一律走 stale 引擎桩，保证「仍催」确定性）
run_stop() {
  "$PY3" - "$1" <<'PY' | RESPITE_CONFIG="$CFG_STALE" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" "$PY3" "$ROOT/hooks/respire.py" Stop
import json, sys
print(json.dumps({"hook_event_name": "Stop", "stop_hook_active": sys.argv[1] == "true"}))
PY
}
check "Stop 存储检查续跑" "$(run_stop false)" '含:"decision": "deny"'
check "Stop 提示含存储指令" "$(run_stop false)" "含:rsrs remember"
check "Stop 防重入放行" "$(run_stop true)" "空"
CFG_NUDGE0="$TMP/config-nudge0.json"
echo '{"store_nudge_every": 0}' > "$CFG_NUDGE0"
run_stop_cfg() {   # $1=config
  local cfg="$1"
  "$PY3" - <<'PY' | RESPITE_CONFIG="$cfg" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" "$PY3" "$ROOT/hooks/respire.py" Stop
import json
print(json.dumps({"hook_event_name": "Stop", "stop_hook_active": False}))
PY
}
check "Stop 节流关闭静默" "$(run_stop_cfg "$CFG_NUDGE0")" "空"
check "Stop 引擎近期落库不催" "$(run_stop_cfg "$CFG_FRESH")" "空"
check "Stop 引擎陈旧落库仍催" "$(run_stop false)" '含:"decision": "deny"'
check "引擎放行留痕 src=engine" "$(grep -q 'stored_recent_skip.*src=engine' "$TMP/hook.log" && echo YES)" "含:YES"
printf '%s\n' '{"ts": "'"$(date +%Y-%m-%dT%H:%M:%S)"'", "ev": "store", "out": "ok", "d": "feed"}' >> "$TMP/hook.log"
check "Stop 已存放行放行" "$(run_stop false)" "空"
check "enabled=false 全线静默" "$(run SessionStart "" "$CFG_OFFE")" "空"
check "enabled=false 落库也静默" "$(run UserPromptSubmit "记：关断时不应落库" "$CFG_OFFE")" "空"
check "引擎缺失注入安装指令" "$(run_engineless)" "含:Install it now on the user's behalf"
check "引导禁自造超级密码" "$(run_engineless)" "含:never pass --super"
check "引导要求保存恢复码" "$(run_engineless)" "含:copy and keep it"
check "引擎缺失含配置下一步" "$(run_engineless)" "含:rsrs register"
check "probe失败含未注册分支" "$(RESPITE_FAKE_PROBE_FAIL=1 run SessionStart)" "含:never registered"

out=$(run UserPromptSubmit "rsrs 信封 JSON 结构解析取哪层")
check "相关 prompt 触发召回" "$out" "非空"
check "注入为标题档无正文" "$out" "不含:｜"
check "默认直出无阈值拦截" "$out" "含:rsrs direct"
check "召回头行与条数一致" "$(printf '%s' "$out" | python3 -c '
import re,sys
s=sys.stdin.read(); head=s.split("\n",1)[0]
n=sum(1 for l in s.split("\n") if l.startswith("- ["))
m=re.search(r"matched (\d+)",head)
print("OK" if m and int(m.group(1))==n else "BAD")')" "含:OK"

check "无关 prompt 不注入" "$(run UserPromptSubmit "今晚吃什么菜好呢")" "空"
check "单字 prompt 跳过" "$(run UserPromptSubmit "嗯")" "空"
check "/nomem 关闭召回" "$(run UserPromptSubmit "/nomem rsrs 信封结构")" "空"
# ---- 疑似凭据守卫：凭据值运行时拼接（源码无完整字面量，分发前静态扫描零误报）；引擎桩登记每次调用 ----
# 桩引擎写成 python 脚本：bash 桩在 Windows 上 CreateProcess 无法执行，「桩没跑」与「守卫拦住」不可区分，
# 零调用断言会假通过；Windows 下包一层 .cmd（无扩展名 shim 解释器 cmd.exe 跑不动，回退 py.exe/python.exe），Unix 直接用。
SYN_SECRET="sk-""q7xkwm2vbnr8tzc41p9e"
STUB_SPY="$TMP/rsrs-spy"
SPY_LOG="$(cygpath -m "$TMP" 2>/dev/null || printf '%s' "$TMP")/spy.log"
cat > "$STUB_SPY" <<PY
#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
try:  # 每次被调追加一行（含全部参数）：供零调用计数断言与「凭据字面量不入桩」检查
    with open("${SPY_LOG}", "a", encoding="utf-8") as f:
        f.write(" ".join(args) + "\n")
except Exception:
    pass
out = {
    "recall": {"command": "recall", "status": "ok",
               "details": [{"id": "cccccccccccccccc", "title": "spy", "score": 0.9}]},
    "remember": {"command": "remember", "status": "ok", "summary": {"id": "dddddddddddddddd"}},
    "list": {"command": "list", "status": "ok", "details": []},
    "status": {"command": "status", "status": "ok",
               "summary": {"session": {"has_token": True, "user": "spy"}, "local_total": 42}},
}.get(args[0] if args else "")
if out is not None:
    print(json.dumps(out))
PY
chmod +x "$STUB_SPY"
if command -v cmd.exe >/dev/null 2>&1; then
  PY3_WIN="$(cygpath -w "$PY3" 2>/dev/null || echo "$PY3")"
  for _cand in py.exe python.exe; do
    _p="$(dirname "$PY3_WIN")/$_cand"
    [ -f "$_p" ] && PY3_WIN="$_p" && break
  done
  if [ ! -f "$PY3_WIN" ] || [ "${PY3_WIN##*.}" != "exe" ]; then
    _py="$(command -v py)"
    [ -n "$_py" ] && PY3_WIN="$(cygpath -w "$_py")"
  fi
  cat > "$TMP/rsrs-spy.cmd" <<WRAP
@echo off
"$PY3_WIN" "%~dp0rsrs-spy" %*
WRAP
  SPY_RUN="$TMP/rsrs-spy.cmd"
else
  SPY_RUN="$STUB_SPY"
fi
# 桩路径转 Windows 形式（native python 不识 POSIX 临时目录；无 cygpath 的环境原样）
SPY_PATH="$(cygpath -m "$SPY_RUN" 2>/dev/null || printf '%s' "$SPY_RUN")"
CFG_SPY="$TMP/config-spy.json"
echo '{"session_rules": true, "rsrs": "'"$SPY_PATH"'"}' > "$CFG_SPY"
calls_n() { [ -f "$TMP/spy.log" ] && wc -l < "$TMP/spy.log" | tr -d '[:space:]' || echo 0; }

# 正向对照先行（不许 SKIP）：同一 spy 先用普通输入真实调用一次——桩真被调、调用入账、
# 桩回有效 JSON 被注入；对照不成立则凭据守卫组整组记 FAIL（桩死≠守卫拦住，绝不假通过）。
N0="$(calls_n)"
spy_out="$(run UserPromptSubmit "rsrs 信封 JSON 结构解析取哪层" "$CFG_SPY")"
check "普通输入照常进引擎桩" "$( [ "$(calls_n)" -gt "$N0" ] && echo YES || echo NO )" "含:YES"
check "普通输入照常注入召回" "$spy_out" "含:auto-recall"
check "正向对照：桩自身输出可解析 JSON" "$(printf '%s\n' '正向对照探针' | "$PY3" "$STUB_SPY" recall 探针 --titles --json | "$PY3" -c 'import json,sys
print("OK" if json.load(sys.stdin).get("status") == "ok" else "BAD")' 2>/dev/null)" "含:OK"
check "正向对照：召回条数来自桩" "$spy_out" "含:matched 1 item(s)"
check "正向对照：召回条目来自桩 canned" "$spy_out" "含:[0.90] spy"
check "正向对照：调用登记为 recall" "$(grep -aqE '^recall( |$)' "$TMP/spy.log" 2>/dev/null && echo YES || echo NO)" "含:YES"

SPY_ALIVE=1
[ "$(calls_n)" -gt "$N0" ] || SPY_ALIVE=0
grep -aqE '^recall( |$)' "$TMP/spy.log" 2>/dev/null || SPY_ALIVE=0
printf '%s' "$spy_out" | grep -aqF "auto-recall" || SPY_ALIVE=0

if [ "$SPY_ALIVE" = 1 ]; then
  N1="$(calls_n)"
  out=$(run UserPromptSubmit "api_key = $SYN_SECRET 存一下" "$CFG_SPY")
  check "疑似凭据不发引擎" "$out" "含:contains a credential"
  check "合成凭据不进注入输出" "$(printf '%s' "$out" | grep -qF -- "$SYN_SECRET" && echo LEAK || echo SAFE)" "含:SAFE"
  check "合成凭据不进日志" "$(grep -aqF -- "$SYN_SECRET" "$TMP/hook.log" 2>/dev/null && echo LEAK || echo SAFE)" "含:SAFE"
  check "凭据命中只记原因码" "$(grep -a '"out": "secret_skip"' "$TMP/hook.log" | grep -q '"d"' && echo HASDETAIL || echo CODEONLY)" "含:CODEONLY"
  check "引擎桩未见凭据输入" "$(grep -aqF -- "$SYN_SECRET" "$TMP/spy.log" 2>/dev/null && echo GOT || echo CLEAN )" "含:CLEAN"
  check "引擎桩未见该轮调用" "$( [ "$(calls_n)" = "$N1" ] && echo SAME || echo CALLED )" "含:SAME"
else
  echo "FAIL  正向对照未观察到引擎桩真实执行——凭据守卫组整组未验证，以下 6 项不计通过"
  for _nm in 疑似凭据不发引擎 合成凭据不进注入输出 合成凭据不进日志 凭据命中只记原因码 引擎桩未见凭据输入 引擎桩未见该轮调用; do
    FAIL=$((FAIL+1)); echo "FAIL  $_nm（spy 死桩，组未验证）"
  done
fi
check "疑似凭据不落库" "$(run UserPromptSubmit "记：数据库密码 = hunter2u")" "含:contains a credential"
check "Qoder 内部 Recap 提示跳过召回" "$(run UserPromptSubmit "你正在为 Qoder 任务监控编写简短的会话 Recap。\n只返回一个 JSON")" "空"
check "内部前缀白名单可配" "$(cat "$ROOT/hooks/respire.config.example.json")" "含:skip_prefixes"
check "技能指认轮剥前缀仍召回" "$(run UserPromptSubmit '$skill: 笔痕 rsrs 信封 JSON 结构解析取哪层')" "含:auto-recall"
check "坏 stdin 静默" "$(printf 'not-json{{{' | RESPITE_CONFIG="$CFG_ON" "$PY3" "$ROOT/hooks/respire.py" UserPromptSubmit)" "空"
check "未知事件静默" "$(run PreToolUse "rsrs 信封")" "空"

# ---- title 规则抽取（纯函数，零污染） ----
check "整句优先取完整句" "$(python3 -c '
import sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOT"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.extract_title("respire 插件路径迁至 memocap 下。后续以仓库为准。"))')" "含:respire 插件路径迁至 memocap 下。"
check "无句号退分隔符不切半词" "$(python3 -c '
import sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOT"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t=m.extract_title("这是一条没有句号的长事实句，讲清楚何时谁做了什么事，以及结果如何，后面还有别的内容")
print(t)')" "含:讲清楚何时谁做了什么事，"
check "长串不超70字" "$(python3 -c '
import sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOT"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(len(m.extract_title("默" * 200)))')" "非空"

# ---- 写探针（--store 显式开启；写真库→断言→forget 清理） ----
if [ "$WITH_STORE" = 1 ]; then
  # 内容须与全库零语义关联：纯随机无义串（域词如「探针/测试/记忆」会撞 30%+ 相似走待决态）
  MARK="zq$(date +%s)$RANDOM kw7f2 随机标记无义串"
  out=$(run UserPromptSubmit "记：$MARK")
  check "落库成功回执" "$out" "含:Saved:"
  check "回执约束AI抽事实句retitle" "$out" "含:rsrs retitle"
  SID=$(printf '%s' "$out" | sed -n 's/.*(\([0-9a-f]\{8\}\))\..*/\1/p')
  check "回执带短 id" "$SID" "非空"
  if [ -n "$SID" ]; then
    rc=$(rsrs forget "$SID" --json 2>/dev/null | jq -r '.status // "err"')
    check "探针清理(status=ok)" "$rc" "含:ok"
  fi
  # 判重待决：复述库中稳定条目（97251289 标题）→ 必撞高相似 → pending 未写入
  out=$(run UserPromptSubmit "记：1memory 更名 respire：吸即存呼即取，材料全线改（复述既有条目触发判重待决）")
  check "判重待决转述候选" "$out" "含:store pending"
  check "待决列出候选与决断法" "$out" "含:--force"
  # 兜底：万一判为直写（库条变更），清掉探针不留垃圾
  if printf '%s' "$out" | grep -qF "Saved:"; then
    BID=$(printf '%s' "$out" | sed -n 's/.*(\([0-9a-f]\{8\}\))\..*/\1/p')
    [ -n "$BID" ] && rsrs forget "$BID" --json >/dev/null 2>&1
    echo "  （注：该条被判直写而非待决，已兜底清理 $BID）"
  fi
else
  echo "SKIP  写探针（默认只读；加 --store 开启，写真库并自动 forget 清理）"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
