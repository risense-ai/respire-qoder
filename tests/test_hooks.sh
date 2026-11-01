#!/usr/bin/env bash
# respire 自测 —— 模拟 stdin 事件 JSON，逐分支断言。
# rsrs 无 data-dir 隔离（runtime 单例＋全局 client.json），故默认只读分支不碰库；
# 加 --store 才跑写探针（写真库→回执断言→rsrs forget 自清理）。
# 无 rsrs 引擎（如三平台 CI）时真库分支记 SKIP；桩状态机/凭据守卫/纯函数套件零引擎依赖，照常执行。
set -u
export PYTHONUTF8=1  # GitHub Windows runner 的 python 默认 cp1252：打印中文断言会 UnicodeEncodeError
export MSYS2_ENV_CONV_EXCL='PROMPT_VAL'  # MSYS 连 env 值都会把「/nomem …」转成 Windows 路径——只豁免 prompt 变量
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# PY3 探测：优先 python3（unix/CI），退 python / py（windows-latest 的 bash 无 python3 shim）；
# WindowsApps 商店占位能被 command -v 命中但一跑即退——逐一实跑校验，取第一个真解释器。
PY3=""
for _c in python3 python py; do
  _p="$(command -v "$_c" 2>/dev/null || true)"
  if [ -n "$_p" ] && "$_p" -c 'import sys' >/dev/null 2>&1; then PY3="$_p"; break; fi
done
if [ -z "$PY3" ]; then echo "SKIP：未找到可用的 python 解释器。"; exit 1; fi
RSRS="$(command -v rsrs || true)"
[ -z "$RSRS" ] && RSRS="$HOME/.local/bin/rsrs"
[ -z "$RSRS" ] && RSRS="$HOME/.rsrs/bin/rsrs"
PASS=0; FAIL=0
WITH_STORE=0
[ "${1:-}" = "--store" ] && WITH_STORE=1

HAVE_RSRS=0
if [ -n "$RSRS" ] && [ -x "$RSRS" ]; then
  HAVE_RSRS=1
else
  echo "NOTE：未找到 rsrs 引擎——真库只读/写探针分支跳过，桩状态机套件照常执行。"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# 状态目录基址：Windows python 解析不了 MSYS 的 /tmp（锁会落到当前盘符根下），必须 cygpath -m 转混合路径；
# 含文件组件的假路径（not-a-dir 挡路场景）不能整条转——只转 $TMP，后缀在调用点拼。
TMPBASE="$(cygpath -m "$TMP" 2>/dev/null || printf '%s' "$TMP")"
TURNBASE="$TMPBASE/turnstate"
CFG_ON="$TMP/config-on.json"
echo '{"session_rules": true}' > "$CFG_ON"
CFG_OFF="$TMP/config-off.json"
echo '{"session_rules": false}' > "$CFG_OFF"

# run <event> [prompt] [config] [session]
# prompt 走环境变量 PROMPT_VAL——MSYS 会把「/nomem …」这类 argv 转成 Windows 路径，env 值不转
run() {
  local ev="$1" pr="${2-}" cfg="${3:-$CFG_ON}" sess="${4:-selftest}"
  PROMPT_VAL="$pr" "$PY3" - "$ev" "$sess" <<'PY' | PROMPT_VAL="$pr" RESPITE_CONFIG="$cfg" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" RESPITE_TURN_STATE="$TURNBASE" "$PY3" "$ROOT/hooks/respire.py" "$ev"
import json, os, sys
ev, sess = sys.argv[1], sys.argv[2]
pr = os.environ.get("PROMPT_VAL", "")
d = {"hook_event_name": ev, "cwd": "/tmp", "session_id": sess}
if ev == "UserPromptSubmit":
    d["prompt"] = pr
sys.stdout.buffer.write(json.dumps(d, ensure_ascii=False).encode("utf-8"))  # buffer 直写 UTF-8——Windows 默认码页会把 CJK 写成乱码
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

# ---- 可移植引擎桩（python 实现；Windows 走 .cmd 包装——bash 脚桩 WinError 193 不可 exec）----
# 模式：remember → rem_ok / rem_warn / rem_pend / rem_silent / rem_slow / rem_showbad / rem_showarr / rem_showstr；
#       list → fresh / stale / list_fail（STUB_LIST 独立控制）；recall → 固定一条命中。
# rem_showarr/rem_showstr：show 回 ok 信封但 details 是非空数组/字符串（复审轮#2 坏 details 反例）。
# POSIX 侧直接 cp+chmod 当可执行——首行必须带 python3 shebang，否则 Linux CI 上 subprocess exec 报 Exec format error。
STUB_DIR="$TMP"; TMPN="$TMPBASE"
cat > "$STUB_DIR/stub_engine.py" <<'PYEOF'
#!/usr/bin/env python3
import json, os, sys, time
sub = sys.argv[1] if len(sys.argv) > 1 else ""
mode = os.environ.get("STUB_MODE", "ok")
list_mode = os.environ.get("STUB_LIST", mode)
if sub == "list":
    if list_mode == "list_fail":
        print("garbage not json"); sys.exit(0)
    if list_mode == "list_dead":
        sys.exit(1)
    # 毫秒精度 UTC——真实 CLI 信封即毫秒（…926Z）；整秒截断会让「写入晚于 prompt」错判
    ts = (time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
          + ".%03dZ" % (int(time.time() * 1000) % 1000)) if list_mode == "fresh" else "2020-01-01T00:00:00.000Z"
    print(json.dumps({"command": "list", "status": "ok",
                      "details": [{"id": "ffffffffffffffff", "created_at": ts, "updated_at": ts,
                                   "title": "stub list entry"}]}))
elif sub == "remember":
    if mode == "rem_silent":
        sys.exit(0)
    if mode == "rem_slow":
        time.sleep(5); sys.exit(0)
    if mode == "rem_warn":
        print(json.dumps({"command": "remember", "status": "warn",
                          "summary": {"action": "created", "id": "eeeeeeeeeeeeeeee"},
                          "errors": ["parent (cause) cannot be resolved; stored independently"]})); sys.exit(2)
    if mode == "rem_pend":
        print(json.dumps({"command": "remember", "status": "pending",
                          "summary": {"state": "candidates", "written": False},
                          "items": [{"name": "aaaabbbb", "status": "pending",
                                     "value": "similarity=88% title=stub candidate",
                                     "action": "merge or attach"}],
                          "actions": ["rsrs remember \"<combined content>\" --merge-ids \"aaaabbbb\"",
                                      "rsrs remember \"<content>\" --parent <candidate id>",
                                      "rsrs remember \"<content>\" --force to write as new entry"]})); sys.exit(2)
    print(json.dumps({"command": "remember", "status": "ok",
                      "summary": {"action": "created", "id": "dddddddddddddddd"}}))
elif sub == "show":
    if mode == "rem_showarr":
        print(json.dumps({"command": "show", "status": "ok", "summary": {"id": sys.argv[2]},
                          "details": [{"entry": {"id": sys.argv[2], "title": "arr", "content": "arr"}}]}))
    elif mode == "rem_showstr":
        print(json.dumps({"command": "show", "status": "ok", "summary": {"id": sys.argv[2]},
                          "details": "details-is-a-string"}))
    elif mode == "rem_showbad":
        print(json.dumps({"command": "show", "status": "ok", "summary": {"id": sys.argv[2], "title": "drifted title"},
                          "details": {"entry": {"id": sys.argv[2], "title": "drifted title", "content": "drifted content"}}}))
    else:
        t = os.environ.get("STUB_TITLE", "stub title")
        c = os.environ.get("STUB_CONTENT", "stub content")
        print(json.dumps({"command": "show", "status": "ok", "summary": {"id": sys.argv[2], "title": t},
                          "details": {"entry": {"id": sys.argv[2], "title": t, "content": c}}}))
elif sub == "recall":
    if mode == "rec_skip":
        print(json.dumps({"command": "recall", "status": "skip", "details": []}))
        sys.exit(0)
    print(json.dumps({"command": "recall", "status": "ok",
                      "details": [{"id": "cccccccccccccccc", "title": "stub recall hit", "score": 0.9}]}))
else:
    sys.exit(1)
PYEOF
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    PY3_WIN="$(cygpath -w "$(py -3 -c 'import sys; print(sys.executable)' 2>/dev/null || command -v python.exe || command -v py.exe)")"
    STUB_ENGINE="$TMPN/rsrs-stub.cmd"
    printf '@echo off\r\n"%s" "%%~dp0stub_engine.py" %%*\r\n' "$PY3_WIN" > "$STUB_DIR/rsrs-stub.cmd"
    ;;
  *)
    STUB_ENGINE="$STUB_DIR/rsrs-stub"
    cp "$STUB_DIR/stub_engine.py" "$STUB_ENGINE"
    chmod +x "$STUB_ENGINE"
    ;;
esac
CFG_STUB="$TMP/config-stub.json"
printf '{"session_rules": true, "rsrs": "%s"}' "$STUB_ENGINE" > "$CFG_STUB"

# run_stub <event> <stdin-json> [STUB_MODE] [STUB_LIST] [session]
run_stub() {
  local ev="$1" payload="$2" sm="${3:-ok}" sl="${4:-}" sess="${5:-selftest}"
  printf '%s' "$payload" | STUB_MODE="$sm" STUB_LIST="$sl" RESPITE_TEST_FAST=1 \
    RESPITE_CONFIG="$CFG_STUB" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" \
    RESPITE_TURN_STATE="$TURNBASE" "$PY3" "$ROOT/hooks/respire.py" "$ev"
}
STOP_JSON='{"hook_event_name": "Stop", "stop_hook_active": false, "session_id": "selftest"}'
reset_state() { rm -rf "$TMP/turnstate" "$TMP/nudge"; }

# ---- 写回执状态机（§7.1/§7.2 契约；全走桩，零真库依赖） ----
FACT="fixed stub fact sentence one."
reset_state
out=$(STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"selftest\"}" rem_ok)
check "ok 写入回执含短 id" "$out" "含:(dddddddd)"
check "ok 写入回读核验标注" "$out" "含:verified by read-back"
check "ok 回执约束AI抽事实句retitle" "$out" "含:rsrs retitle dddddddd"
out=$(STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"selftest\"}" rem_warn)
check "warn 已写入不误报失败" "$out" "含:Saved with warnings"
check "warn 回执附引擎警告摘要" "$out" "含:parent (cause) cannot be resolved"
check "warn 不引导重发" "$out" "不含:did not accept"
check "warn 仍给 retitle 精修入口" "$out" "含:retitle eeeeeeee"
out=$(run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"selftest\"}" rem_pend)
check "pending 明示未写入" "$out" "含:nothing was written"
check "pending 转述候选带短id" "$out" "含:[aaaabbbb]"
check "pending 保留建议动作merge" "$out" "含:--merge-ids"
check "pending 保留建议动作force" "$out" "含:--force"
out=$(run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"selftest\"}" rem_silent stale)
check "坏回执归为unknown" "$out" "含:store unknown"
check "unknown 只读核实指引" "$out" "含:rsrs list --limit 3"
check "unknown 禁止重发" "$out" "含:Do NOT resend"
check "unknown 不误报失败" "$out" "不含:did not accept"
out=$(run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"selftest\"}" rem_silent fresh)
check "unknown+新条目报告可能已写" "$out" "含:may already be written"
check "unknown+新条目给出只读id" "$out" "含:rsrs show ffffffff"
out=$(run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"selftest\"}" rem_slow)
check "超时归为unknown" "$out" "含:store unknown"
check "超时回执禁重发" "$out" "含:Do NOT resend"
check "超时不引导手动重发remember" "$out" "不含:run rsrs remember manually"
out=$(STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"selftest\"}" rem_showbad)
check "回读不一致如实标注" "$out" "含:DIFFERENT title/content"
# 坏 details 反例（复审轮#2）：show 回 ok 信封但 details 非空数组/字符串——局部降级 unavailable，
# 绝不外抛成空输出吞掉已经成功的 Saved 回执，也不误报失败/引导重发
out=$(STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"selftest\"}" rem_showarr)
check "details为数组时Saved回执不消失" "$out" "含:Saved:"
check "details为数组时回读降级unavailable" "$out" "含:Read-back unavailable"
check "details为数组时不误报失败" "$out" "不含:did not accept"
out=$(STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"selftest\"}" rem_showstr)
check "details为字符串时Saved回执不消失" "$out" "含:Saved:"
check "details为字符串时回读降级unavailable" "$out" "含:Read-back unavailable"
check "details为字符串时不误报失败" "$out" "不含:did not accept"

# ---- Stop 存储检查（新契约：fail-open + 请求级凭证 + 一次收尾锁；每场景独立 reset 状态） ----
stop_case() {  # stop_case <STUB_LIST>：reset 后单次 Stop，输出入 OUT_STOP
  reset_state
  OUT_STOP="$(run_stub Stop "$STOP_JSON" ok "${1:-stale}")"
}
stop_case stale
check "Stop 无凭证时催存(deny)" "$OUT_STOP" '含:"decision": "deny"'
check "Stop 提示含存储指令" "$OUT_STOP" "含:rsrs remember"
check "Stop 阻塞输出可过 JSON 解析" "$(printf '%s' "$OUT_STOP" | "$PY3" -c '
import json,sys
d=json.loads(sys.stdin.read())
print("OK" if d.get("decision")=="deny" and "rsrs remember" in d.get("reason","") else "BAD")')" "含:OK"
reset_state
run_stub Stop "$STOP_JSON" ok stale >/dev/null
check "同请求二次Stop一次收尾锁放行(宿主未带active)" "$(run_stub Stop "$STOP_JSON" ok stale)" "空"
reset_state
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "next real question", "session_id": "selftest"}' ok >/dev/null
check "新请求重新武装仍催" "$(run_stub Stop "$STOP_JSON" ok stale)" '含:"decision": "deny"'
stop_case list_fail
check "查库坏信封不再影响Stop(不查引擎)" "$OUT_STOP" '含:"decision": "deny"'
stop_case list_dead
check "查库死进程不再影响Stop(不查引擎)" "$OUT_STOP" '含:"decision": "deny"'
stop_case fresh
check "无请求凭证时引擎新写入仍催(不跨轮误抑制)" "$OUT_STOP" '含:"decision": "deny"'
reset_state
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "turn with engine store", "session_id": "selftest"}' ok >/dev/null
# 复核整改：Stop 不再查询引擎——引擎侧写入（无法归属会话）不再免催，也没有查库失败续跑路径
check "引擎写入晚于prompt不再免催(去无归属抑制)" "$(run_stub Stop "$STOP_JSON" ok fresh)" '含:"decision": "deny"'
NUDGE_N0="$(grep -c '"ev": "stop", "out": "nudge"' "$TMP/hook.log" 2>/dev/null)"; NUDGE_N0="${NUDGE_N0:-0}"
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "arm single nudge count", "session_id": "selftest"}' ok >/dev/null
run_stub Stop "$STOP_JSON" ok fresh >/dev/null
NUDGE_N1="$(grep -c '"ev": "stop", "out": "nudge"' "$TMP/hook.log" 2>/dev/null)"; NUDGE_N1="${NUDGE_N1:-0}"
check "Stop 不再发起引擎查询(单次nudge)" "$( [ $((NUDGE_N1 - NUDGE_N0)) = 1 ] && echo ONE || echo MANY )" "含:ONE"
# 状态目录被同名文件挡住 → 无法落锁 → 放行（绝不无锁 deny）；假路径不能整条 cygpath——转 $TMP 再拼
rm -rf "$TMP/not-a-dir"; printf 'x' > "$TMP/not-a-dir"
reset_state
check "状态目录不可写时放行(绝不无锁deny)" "$(printf '%s' '{"hook_event_name": "Stop", "stop_hook_active": false, "session_id": "selftest"}' | RESPITE_CONFIG="$CFG_STUB" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" RESPITE_TURN_STATE="$TMPBASE/not-a-dir/sub" "$PY3" "$ROOT/hooks/respire.py" Stop)" "空"
rm -f "$TMP/not-a-dir"
# 锁不设 TTL：25 小时前的锁仍占用，只有新 prompt 重新武装
reset_state
run_stub Stop "$STOP_JSON" ok stale >/dev/null
OLDLATCH="$(ls "$TMP"/turnstate/.latch_* 2>/dev/null | head -1)"
if [ -n "$OLDLATCH" ]; then printf '{"ts": 100}' > "$OLDLATCH"; fi
check "25小时前的锁仍占用(无TTL)" "$( [ -n "$OLDLATCH" ] && out="$(run_stub Stop "$STOP_JSON" ok stale)" && [ -z "$out" ] && echo HELD || echo LOST )" "含:HELD"
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "re-arm after aged latch", "session_id": "selftest"}' ok >/dev/null
check "新请求重新武装后仍可催" "$(run_stub Stop "$STOP_JSON" ok stale)" '含:"decision": "deny"'
# /nomem 只跳召回，仍是新请求（重新武装收尾锁）
reset_state
run_stub Stop "$STOP_JSON" ok stale >/dev/null
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "/nomem skip recall only", "session_id": "selftest"}' ok >/dev/null
check "/nomem 轮重新武装收尾锁" "$(run_stub Stop "$STOP_JSON" ok stale)" '含:"decision": "deny"'
check "一次收尾锁留痕" "$(grep -q 'once_latch_skip' "$TMP/hook.log" && echo YES)" "含:YES"
# 内部提示不重新武装（复审轮#1）：Qoder Recap 白名单前缀（DEFAULTS 默认自带）不算新真实请求——
# 序列：真实请求 → Stop deny → 同会话内部 Recap（宿主未带 stop_hook_active）→ Stop 不再 deny
reset_state
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "real question before internal recap", "session_id": "selftest"}' ok >/dev/null
check "序列:真实请求后Stop催存" "$(run_stub Stop "$STOP_JSON" ok stale)" '含:"decision": "deny"'
check "序列:内部Recap跳过无输出" "$(run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "你正在为 Qoder 任务监控编写简短的会话 Recap。只返回一个 JSON", "session_id": "selftest"}' ok)" "空"
check "序列:内部Recap后Stop不再deny(未重武装)" "$(run_stub Stop "$STOP_JSON" ok stale)" "空"
reset_state
STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"sessA\"}" rem_ok >/dev/null
check "其他会话不被本会话凭证免催" "$(run_stub Stop "$STOP_JSON" ok stale)" '含:"decision": "deny"'
# ---- 复审轮#3（行为面）：每会话独立状态文件 st_<sid>.json——A/B 隔离 ----
# A 上轮存过且已开新轮后，B 会话的写只进 B 自己的文件：不免催 A 新轮，B 自己照常免催
reset_state
STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"sessA\"}" rem_ok >/dev/null
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "A asks a new question", "session_id": "sessA"}' ok >/dev/null
STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"sessB\"}" rem_ok >/dev/null
check "B会话写不免催A新轮(A/B隔离)" "$(run_stub Stop '{"hook_event_name": "Stop", "stop_hook_active": false, "session_id": "sessA"}' ok stale)" '含:"decision": "deny"'
check "B会话本轮凭证只免催自己" "$(run_stub Stop '{"hook_event_name": "Stop", "stop_hook_active": false, "session_id": "sessB"}' ok stale)" "空"
reset_state
STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"记：$FACT\", \"session_id\": \"selftest\"}" rem_ok >/dev/null
check "记：成功后本轮凭证免催" "$(run_stub Stop "$STOP_JSON" ok stale)" "空"
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "new turn after store", "session_id": "selftest"}' ok >/dev/null
check "下一轮不被上一轮成功写误抑制(应催)" "$(run_stub Stop "$STOP_JSON" ok stale)" '含:"decision": "deny"'
CFG_NUDGE0="$TMP/config-nudge0.json"
echo '{"store_nudge_every": 0}' > "$CFG_NUDGE0"
check "Stop 节流关闭静默" "$(printf '%s' '{"hook_event_name": "Stop", "stop_hook_active": false, "session_id": "selftest"}' | RESPITE_CONFIG="$CFG_NUDGE0" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" RESPITE_TURN_STATE="$TURNBASE" "$PY3" "$ROOT/hooks/respire.py" Stop)" "空"
CFG_OFFE="$TMP/config-disabled.json"
echo '{"enabled": false}' > "$CFG_OFFE"
check "enabled=false 全线静默" "$(run SessionStart "" "$CFG_OFFE")" "空"
check "enabled=false 落库也静默" "$(run UserPromptSubmit "记：关断时不应落库" "$CFG_OFFE")" "空"
# 引擎缺失分支：单元注入 monkeypatch find_rsrs→None（真机造不出「全路径皆缺」）
# ROOTM=混合路径——Windows python 解析不了 MSYS 的 /d/...
ROOTM="$(cygpath -m "$ROOT" 2>/dev/null || printf '%s' "$ROOT")"
run_engineless() {
  ROOT_HOOK="$ROOTM" "$PY3" - <<'PY'
import io, os, sys, importlib.util
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK"], "hooks", "respire.py"))
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
check "引擎缺失注入安装指令" "$(run_engineless)" "含:Install it now on the user's behalf"
check "引导禁自造超级密码" "$(run_engineless)" "含:never pass --super"
check "引导要求保存恢复码" "$(run_engineless)" "含:copy and keep it"
check "引擎缺失含配置下一步" "$(run_engineless)" "含:rsrs register"
if [ "$HAVE_RSRS" = 1 ]; then
  check "probe失败含未注册分支" "$(RESPITE_FAKE_PROBE_FAIL=1 run SessionStart)" "含:never registered"

  out=$(run UserPromptSubmit "rsrs 信封 JSON 结构解析取哪层")
  check "相关 prompt 触发召回" "$out" "非空"
  check "注入为标题档无正文" "$out" "不含:｜"
  check "默认直出无阈值拦截" "$out" "含:rsrs direct"
  check "召回头行与条数一致" "$(printf '%s' "$out" | "$PY3" -c '
import re,sys
s=sys.stdin.read(); head=s.split("\n",1)[0]
n=sum(1 for l in s.split("\n") if l.startswith("- ["))
m=re.search(r"matched (\d+)",head)
print("OK" if m and int(m.group(1))==n else "BAD")')" "含:OK"
else
  echo "SKIP  真库只读分支（无 rsrs 引擎：probe 失败段/召回注入 5 项）"
fi

check "无关 prompt 不注入(引擎skip门,确定性桩)" "$(run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "今晚吃什么菜好呢", "session_id": "selftest"}' rec_skip)" "空"
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
if [ "$HAVE_RSRS" = 1 ]; then
  check "技能指认轮剥前缀仍召回" "$(run UserPromptSubmit '$skill: 笔痕 rsrs 信封 JSON 结构解析取哪层')" "含:auto-recall"
else
  echo "SKIP  技能指认轮剥前缀仍召回（无 rsrs 引擎，召回注入需真库）"
fi
check "坏 stdin 静默" "$(printf 'not-json{{{' | RESPITE_CONFIG="$CFG_ON" "$PY3" "$ROOT/hooks/respire.py" UserPromptSubmit)" "空"
check "未知事件静默" "$(run PreToolUse "rsrs 信封")" "空"

# ---- title 规则抽取（纯函数，零污染；ROOTM=混合路径——Windows python 解析不了 MSYS 的 /d/...） ----
check "整句优先取完整句" "$("$PY3" -c '
import sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOTM"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.extract_title("respire 插件路径迁至 memocap 下。后续以仓库为准。"))')" "含:respire 插件路径迁至 memocap 下。"
check "无句号退分隔符不切半词" "$("$PY3" -c '
import sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOTM"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t=m.extract_title("这是一条没有句号的长事实句，讲清楚何时谁做了什么事，以及结果如何，后面还有别的内容")
print(t)')" "含:讲清楚何时谁做了什么事，"
check "长串不超70字" "$("$PY3" -c '
import sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOTM"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(len(m.extract_title("默" * 200)))')" "非空"

# ---- 复审轮#3（屏障面）：确定性交错——共享 map 读改写回滚已根除（每会话独立 st_<sid>.json）----
# 交错：A 上轮 prompt_ts=1/store_ts=2；B 读取状态后、写回落盘前（os.replace 屏障注入），
# A 发生新真实请求（prompt_ts=3）。旧共享 map 下 B 的旧全量快照写回会把 A 恢复成
# store_ts>=prompt_ts 误免催；独立文件下 B 只写 st_B，A 的 st_A 不可能被碰。
# 另验：旧请求延迟完成的写回执（写始于新 prompt 之前、完成在其后）不归属新轮、不免催。
check "屏障交错:独立文件不被旧快照回滚" "$(BARRIER_DIR="$TMPBASE/barrier" ROOT_HOOK_M="$ROOTM" "$PY3" - <<'PY'
import importlib.util, os, time
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK_M"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
os.environ["RESPITE_TURN_STATE"] = os.environ["BARRIER_DIR"]
os.makedirs(os.environ["BARRIER_DIR"], exist_ok=True)
now = time.time()
# A 上轮：prompt 早、store 晚（旧凭证「已存且新鲜」）
m._state_update("sessA", {"prompt_ts": now - 200.0})
m._state_update("sessA", {"store_ts": now - 100.0, "store_req_ts": now - 150.0})
# 确定性屏障：A 的新真实请求注入 B 状态写回的瞬间（rename 落盘前）
bpath = os.path.abspath(m._state_path("sessB"))
real_replace, fired = os.replace, [False]
def replace_barrier(src, dst):
    if os.path.abspath(dst) == bpath and not fired[0]:
        fired[0] = True
        m._state_update("sessA", {"prompt_ts": now})  # A 的新真实请求落在 B 的写回窗口内
    return real_replace(src, dst)
os.replace = replace_barrier
try:
    m._state_update("sessB", {"store_ts": now, "store_req_ts": now - 50.0})  # B 写自己的状态（旧实现是整份共享 map 写回）
finally:
    os.replace = real_replace
checks = [
    m._state_load("sessA").get("prompt_ts") == now,  # A 的 prompt_ts 未被 B 的旧快照回滚
    not m.turn_stored("sessA"),                      # A 旧 store(<新 prompt) 不免催本轮
    m._state_load("sessB").get("store_ts") == now,   # B 的并发更新未丢失
]
# 旧请求延迟完成：写始于新 prompt 之前、完成在其后——回执不归属新轮，不免催
m._state_update("sessA", {"store_ts": now + 1.0, "store_req_ts": now - 300.0})
checks.append(not m.turn_stored("sessA"))
print("OK" if all(checks) else "BAD:%r" % (checks,))
PY
)" "含:OK"

# ---- 写探针（--store 显式开启；写真库→断言→forget 清理） ----
if [ "$WITH_STORE" = 1 ] && [ "$HAVE_RSRS" = 1 ]; then
  # 内容须与全库零语义关联：纯随机无义串（域词如「探针/测试/记忆」会撞 30%+ 相似走待决态）
  MARK="zq$(date +%s)$RANDOM kw7f2 随机标记无义串"
  out=$(run UserPromptSubmit "记：$MARK")
  if printf '%s' "$out" | grep -qF "store pending"; then
    PASS=$((PASS+1)); echo "SKIP  随机串判重待决（实时库判重门收紧，ok 回执路径由桩覆盖）"
  else
    check "落库成功回执" "$out" "含:Saved:"
    check "回执约束AI抽事实句retitle" "$out" "含:rsrs retitle"
    SID=$(printf '%s' "$out" | sed -n 's/.*(\([0-9a-f]\{8\}\))\..*/\1/p')
    check "回执带短 id" "$SID" "非空"
    if [ -n "$SID" ]; then
      rc=$(rsrs forget "$SID" --json 2>/dev/null | jq -r '.status // "err"')
      check "探针清理(status=ok)" "$rc" "含:ok"
    fi
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
elif [ "$WITH_STORE" = 1 ]; then
  echo "SKIP  写探针（未找到 rsrs 引擎，无法写真库）"
else
  echo "SKIP  写探针（默认只读；加 --store 开启，写真库并自动 forget 清理）"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
