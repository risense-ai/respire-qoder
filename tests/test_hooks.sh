#!/usr/bin/env bash
# respire self-test -- feeds stdin event JSON and asserts branch by branch.
# rsrs has no data-dir isolation (runtime singleton plus a global client.json), so the default
# read-only branches never touch the store; --store enables the write probe (writes to the real
# store, asserts the receipt, then cleans up with rsrs forget).
# Without an rsrs engine (e.g. the three-platform CI) the real-store branches record SKIP; the
# stub state machine, credential guard and pure-function suites need no engine and always run.
set -u
export PYTHONUTF8=1  # the GitHub Windows runner's python defaults to cp1252 and would fail printing on non-ASCII asserts
export MSYS2_ENV_CONV_EXCL='PROMPT_VAL'  # MSYS rewrites even env values like "/nomem ..." into Windows paths -- exempt the prompt var only
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# PY3 detection: prefer python3 (unix/CI), fall back to python / py (windows-latest bash has no
# python3 shim); the WindowsApps store placeholder can be found by command -v yet exits at once --
# run each candidate for real and take the first working interpreter.
PY3=""
for _c in python3 python py; do
  _p="$(command -v "$_c" 2>/dev/null || true)"
  if [ -n "$_p" ] && "$_p" -c 'import sys' >/dev/null 2>&1; then PY3="$_p"; break; fi
done
if [ -z "$PY3" ]; then echo "SKIP: no usable python interpreter found."; exit 1; fi

# Non-ASCII literals that the runtime matchers must still recognise are produced here from
# \u escapes, so this file stays pure ASCII while the behaviour under test is unchanged.
STORE_TRIGGER="$("$PY3" -c 'print("\u8bb0\uff1a", end="")')"
RECAP_TRIGGER="$("$PY3" -c 'print("\u4f60\u6b63\u5728\u4e3a Qoder \u4efb\u52a1\u76d1\u63a7\u7f16\u5199\u7b80\u77ed\u7684\u4f1a\u8bdd Recap", end="")')"
QUERY_RECALL="$("$PY3" -c 'print("rsrs \u4fe1\u5c01 JSON \u7ed3\u6784\u89e3\u6790\u53d6\u54ea\u5c42", end="")')"
FULLWIDTH_BAR="$("$PY3" -c 'print("\uff5c", end="")')"
ZH_SECRET_LABEL="$("$PY3" -c 'print("\u6570\u636e\u5e93\u5bc6\u7801", end="")')"
DEDUP_PROMPT="$("$PY3" -c 'print("1memory \u66f4\u540d respire\uff1a\u5438\u5373\u5b58\u547c\u5373\u53d6\uff0c\u6750\u6599\u5168\u7ebf\u6539\uff08\u590d\u8ff0\u65e2\u6709\u6761\u76ee\u89e6\u53d1\u5224\u91cd\u5f85\u51b3\uff09", end="")')"
SENT_PROMPT="$("$PY3" -c 'print("\u8bf7\u89e3\u91ca\u4e00\u4e0b fusion gate \u600e\u4e48\u5de5\u4f5c", end="")')"

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
  echo "NOTE: no rsrs engine found -- real-store read/write probe branches are skipped, the stub state-machine suite still runs."
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# State dir base: Windows python cannot resolve MSYS /tmp (the latch would land on the current
# drive root), so cygpath -m converts to a mixed path; fake paths that contain a file component
# (the not-a-dir blocking case) cannot be converted whole -- convert $TMP only and append at the call site.
TMPBASE="$(cygpath -m "$TMP" 2>/dev/null || printf '%s' "$TMP")"
TURNBASE="$TMPBASE/turnstate"
CFG_ON="$TMP/config-on.json"
echo '{"session_rules": true}' > "$CFG_ON"
CFG_OFF="$TMP/config-off.json"
echo '{"session_rules": false}' > "$CFG_OFF"

# run <event> [prompt] [config] [session]
# The prompt travels in the PROMPT_VAL env var -- MSYS converts "/nomem ..." argv into a Windows
# path but leaves env values alone.
run() {
  local ev="$1" pr="${2-}" cfg="${3:-$CFG_ON}" sess="${4:-selftest}"
  PROMPT_VAL="$pr" "$PY3" - "$ev" "$sess" <<'PY' | PROMPT_VAL="$pr" RESPITE_CONFIG="$cfg" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" RESPITE_TURN_STATE="$TURNBASE" RESPITE_CONSOLIDATE_STATE="$TMP/consolidate.json" "$PY3" "$ROOT/hooks/respire.py" "$ev"
import json, os, sys
ev, sess = sys.argv[1], sys.argv[2]
pr = os.environ.get("PROMPT_VAL", "")
d = {"hook_event_name": ev, "cwd": "/tmp", "session_id": sess}
if ev == "UserPromptSubmit":
    d["prompt"] = pr
sys.stdout.buffer.write(json.dumps(d, ensure_ascii=False).encode("utf-8"))  # write UTF-8 straight to buffer: the Windows default code page would mangle non-ASCII
PY
}

check() {   # check <name> <actual-output> <mode: nonempty|empty|has:xxx|hasnt:xxx>
  local name="$1" got="$2" want="$3" ok=0
  case "$want" in
    nonempty) [ -n "$got" ] && ok=1 ;;
    empty)   [ -z "$got" ] && ok=1 ;;
    hasnt:*) printf '%s' "$got" | grep -qF -e "${want#hasnt:}" && ok=0 || ok=1 ;;
    has:*) printf '%s' "$got" | grep -qF -e "${want#has:}" && ok=1 ;;
  esac
  if [ "$ok" = 1 ]; then
    PASS=$((PASS+1)); echo "PASS  $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL  $name  want[$want] got[$(printf '%s' "$got" | head -c 200)]"
  fi
}

# ---- Portable engine stub (implemented in python; Windows goes through a .cmd wrapper because a
# ---- bash-script stub cannot be exec'd there -- WinError 193)
# Modes: remember -> rem_ok / rem_warn / rem_pend / rem_silent / rem_slow / rem_showbad /
#        rem_showarr / rem_showstr; list -> fresh / stale / list_fail (STUB_LIST controls it
#        independently); recall -> one fixed hit.
# rem_showarr/rem_showstr: show returns an ok envelope but details is a non-empty array/string
# (review round #2 bad-details counterexamples).
# On POSIX it is copied and chmod'ed as an executable -- the first line must carry a python3
# shebang or subprocess exec fails with "Exec format error" on Linux CI.
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
    # Millisecond UTC -- the real CLI envelope is millisecond precision (...926Z); truncating to
    # whole seconds would misjudge "write later than prompt".
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
elif sub == "review":
    # T1-1 due-check stub: STUB_DUE="" -> nothing due (existing tests stay footer-free),
    # "hit" -> 3 due, "fail" -> fail envelope, "error" -> nonzero exit (all fail-open).
    due = os.environ.get("STUB_DUE", "")
    if due == "error":
        sys.exit(1)
    if due == "fail":
        print(json.dumps({"command": "review", "status": "fail", "summary": {"saved": False},
                          "items": [], "errors": ["stub decode review snapshot"],
                          "details": {"code": "review_failed", "saved": False}}))
        sys.exit(0)
    n = 3 if due == "hit" else 0
    print(json.dumps({"command": "review", "status": "ok",
                      "summary": {"due_count": n, "saved": False}, "items": [],
                      "details": {"due": [{"id": "a" * 16, "due_reasons": ["unverified"]}] * n}}))
elif sub == "resort":
    # T1-2 consolidate trigger stub: "" -> counter 0 (skip), "hit"/"audit_error" -> above
    # threshold (the latter fails only at the audit step), "weekly" -> nonzero below
    # threshold, "error" -> nonzero rc (fail-open).
    tidy = os.environ.get("STUB_TIDY", "")
    if tidy == "error":
        sys.exit(1)
    if tidy in ("hit", "audit_error"):
        count = int(os.environ.get("STUB_TIDY_COUNT", "40"))
    elif tidy == "weekly":
        count = int(os.environ.get("STUB_TIDY_COUNT", "5"))
    else:
        count = int(os.environ.get("STUB_TIDY_COUNT", "0"))
    thr = int(os.environ.get("STUB_TIDY_THR", "30"))
    print(json.dumps({"command": "resort", "status": "warn" if count >= thr else "ok",
                      "summary": {"count": count, "threshold": thr}}))
elif sub == "audit":
    # T1-2 fire-time audit stub: "audit_error" -> nonzero rc after a successful fire.
    if os.environ.get("STUB_TIDY", "") == "audit_error":
        sys.exit(1)
    print(json.dumps({"command": "audit", "status": "ok",
                      "summary": {"orphans": 2, "invalid_importance": 0,
                                  "same_title_groups": 1, "truncated_titles": 0,
                                  "max_depth": 7, "hot_untyped": 5,
                                  "skill_template_gaps": 3, "total_active": 111}}))
elif sub == "status":
    # T-A1 session probe stub: a healthy status envelope so probe_status returns probe_ok=True
    # and the SessionStart four-way split reaches the model_status + sync branches.
    # STUB_SYNC=off -> remote_configured false (cloud-sync-off note expected);
    # default/anything else -> remote_configured true + has_token (synced, no note).
    sync_off = os.environ.get("STUB_SYNC", "") == "off"
    print(json.dumps({"command": "status", "status": "ok",
                      "summary": {"session": {"has_token": not sync_off, "user": "stub-user"},
                                  "remote_configured": not sync_off,
                                  "local_total": 10}}))
elif sub == "model":
    # T-A1 session model-readiness stub: "" -> a present variant (no model note injected),
    # "missing" -> no variant present (RULES_NO_MODEL note), "error" -> garbage on stdout
    # (model_status must fail-open: no note, no crash).
    ms = os.environ.get("STUB_MODEL", "")
    if ms == "missing":
        print(json.dumps({"command": "model.engine", "status": "ok",
                          "summary": {"variants": [{"name": "quantized", "state": "invalid_size"},
                                                  {"name": "fp16", "state": "missing"}]}}))
    elif ms == "error":
        print("garbage not json")
    else:
        print(json.dumps({"command": "model.engine", "status": "ok",
                          "summary": {"variants": [{"name": "quantized", "state": "present"},
                                                  {"name": "fp16", "state": "invalid_size"}]}}))
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
# store_nudge_every pinned to 1: these cases assert the per-request nudge contract itself;
# the shipped default throttle (every 4th Stop) has its own case further down (P1-1).
printf '{"session_rules": true, "rsrs": "%s", "store_nudge_every": 1}' "$STUB_ENGINE" > "$CFG_STUB"

# run_stub <event> <stdin-json> [STUB_MODE] [STUB_LIST] [session] [STUB_DUE] [STUB_TIDY]
# STUB_DUE (6th arg) drives the T1-1 review stub: "" (default) = nothing due, hit / fail / error.
# STUB_TIDY (7th arg) drives the T1-2 resort/audit stub: "" (default) = tidy counter 0 (nothing
# to consolidate), "hit" = counter above threshold (STUB_TIDY_COUNT/THR override the numbers),
# "weekly" = nonzero counter below threshold, "error" = nonzero rc, "audit_error" = fire then
# the audit call fails.
run_stub() {
  local ev="$1" payload="$2" sm="${3:-ok}" sl="${4:-}" sess="${5:-selftest}" sd="${6:-}" st="${7:-}" sb="${8:-}"
  printf '%s' "$payload" | STUB_MODE="$sm" STUB_LIST="$sl" STUB_DUE="$sd" STUB_TIDY="$st" STUB_MODEL="$sb" RESPITE_TEST_FAST=1 \
    RESPITE_CONFIG="$CFG_STUB" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" \
    RESPITE_TURN_STATE="$TURNBASE" RESPITE_CONSOLIDATE_STATE="$TMP/consolidate.json" "$PY3" "$ROOT/hooks/respire.py" "$ev"
}
STOP_JSON='{"hook_event_name": "Stop", "stop_hook_active": false, "session_id": "selftest"}'
reset_state() { rm -rf "$TMP/turnstate" "$TMP/nudge" "$TMP/consolidate.json"; }

# ---- Explicit prefixes stay pending; legacy receipt helper coverage is in test_receipts.py. ----
FACT="fixed stub fact sentence one."
reset_state
for mode in rem_ok rem_warn rem_pend rem_silent rem_slow rem_showbad rem_show_badarr rem_show_strdet; do
  out=$(run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"$STORE_TRIGGER$FACT\", \"session_id\": \"selftest\"}" "$mode")
  check "prefix pending ($mode)" "$out" "has:store pending"
  check "prefix not written ($mode)" "$out" "has:nothing was written"
  check "prefix policy ($mode)" "$out" "has:rsrs prompt"
  check "prefix candidate bodies ($mode)" "$out" "has:rsrs show"
  check "prefix placement order ($mode)" "$out" "has:update > merge > attach > new"
  check "prefix parent required ($mode)" "$out" "has:remain pending"
done

# ---- Stop store check (new contract: fail-open + request-level receipt + one-shot latch; each
# ---- scenario gets a fresh state)
stop_case() {  # stop_case <STUB_LIST>: reset, then a single Stop, output in OUT_STOP
  reset_state
  OUT_STOP="$(run_stub Stop "$STOP_JSON" ok "${1:-stale}")"
}
stop_case stale
check "Stop nudges when no receipt exists (deny)" "$OUT_STOP" 'has:"decision": "deny"'
check "Stop prompt includes the store instruction" "$OUT_STOP" "has:rsrs remember"
check "Stop blocking output parses as JSON" "$(printf '%s' "$OUT_STOP" | "$PY3" -c '
import json,sys
d=json.loads(sys.stdin.read())
print("OK" if d.get("decision")=="deny" and "rsrs remember" in d.get("reason","") else "BAD")')" "has:OK"
reset_state
run_stub Stop "$STOP_JSON" ok stale >/dev/null
check "second Stop for the same request is allowed by the one-shot latch (host sent no active)" "$(run_stub Stop "$STOP_JSON" ok stale)" "empty"
reset_state
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "next real question", "session_id": "selftest"}' ok >/dev/null
check "a new request re-arms the latch and still nudges" "$(run_stub Stop "$STOP_JSON" ok stale)" 'has:"decision": "deny"'
stop_case list_fail
check "bad list envelope no longer affects Stop (no engine query)" "$OUT_STOP" 'has:"decision": "deny"'
stop_case list_dead
check "dead list process no longer affects Stop (no engine query)" "$OUT_STOP" 'has:"decision": "deny"'
stop_case fresh
check "engine write without a request receipt still nudges (no cross-turn suppression)" "$OUT_STOP" 'has:"decision": "deny"'
reset_state
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "turn with engine store", "session_id": "selftest"}' ok >/dev/null
# Review fix: Stop no longer queries the engine -- an engine-side write (unattributable to a
# session) no longer suppresses, and there is no list-failure continuation path.
check "engine write later than the prompt no longer suppresses (attribution removed)" "$(run_stub Stop "$STOP_JSON" ok fresh)" 'has:"decision": "deny"'
NUDGE_N0="$(grep -c '"ev": "stop", "out": "nudge"' "$TMP/hook.log" 2>/dev/null)"; NUDGE_N0="${NUDGE_N0:-0}"
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "arm single nudge count", "session_id": "selftest"}' ok >/dev/null
run_stub Stop "$STOP_JSON" ok fresh >/dev/null
NUDGE_N1="$(grep -c '"ev": "stop", "out": "nudge"' "$TMP/hook.log" 2>/dev/null)"; NUDGE_N1="${NUDGE_N1:-0}"
check "Stop makes no engine query (single nudge)" "$( [ $((NUDGE_N1 - NUDGE_N0)) = 1 ] && echo ONE || echo MANY )" "has:ONE"
# State dir blocked by a same-name file -> cannot take the latch -> allow (never deny without a
# lock); a fake path cannot be converted whole with cygpath -- convert $TMP and append.
rm -rf "$TMP/not-a-dir"; printf 'x' > "$TMP/not-a-dir"
reset_state
check "unwritable state dir allows (never deny without a lock)" "$(printf '%s' '{"hook_event_name": "Stop", "stop_hook_active": false, "session_id": "selftest"}' | RESPITE_CONFIG="$CFG_STUB" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" RESPITE_TURN_STATE="$TMPBASE/not-a-dir/sub" "$PY3" "$ROOT/hooks/respire.py" Stop)" "empty"
rm -f "$TMP/not-a-dir"
# The latch has no TTL: a 25-hour-old latch is still held, only a new prompt re-arms it.
reset_state
run_stub Stop "$STOP_JSON" ok stale >/dev/null
OLDLATCH="$(ls "$TMP"/turnstate/.latch_* 2>/dev/null | head -1)"
if [ -n "$OLDLATCH" ]; then printf '{"ts": 100}' > "$OLDLATCH"; fi
check "a 25-hour-old latch is still held (no TTL)" "$( [ -n "$OLDLATCH" ] && out="$(run_stub Stop "$STOP_JSON" ok stale)" && [ -z "$out" ] && echo HELD || echo LOST )" "has:HELD"
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "re-arm after aged latch", "session_id": "selftest"}' ok >/dev/null
check "after a new request re-arms it, it can nudge again" "$(run_stub Stop "$STOP_JSON" ok stale)" 'has:"decision": "deny"'
# /nomem only skips recall; it is still a new request (re-arms the latch).
reset_state
run_stub Stop "$STOP_JSON" ok stale >/dev/null
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "/nomem skip recall only", "session_id": "selftest"}' ok >/dev/null
check "/nomem turn re-arms the latch" "$(run_stub Stop "$STOP_JSON" ok stale)" 'has:"decision": "deny"'
check "one-shot latch leaves a trail" "$(grep -q 'once_latch_skip' "$TMP/hook.log" && echo YES)" "has:YES"
# Internal prompts do not re-arm (review round #1): the Qoder Recap whitelist prefix (built into
# DEFAULTS) is not a new real request -- sequence: real request -> Stop deny -> internal Recap in
# the same session (host sent no stop_hook_active) -> Stop no longer denies.
reset_state
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "real question before internal recap", "session_id": "selftest"}' ok >/dev/null
check "sequence: Stop nudges after the real request" "$(run_stub Stop "$STOP_JSON" ok stale)" 'has:"decision": "deny"'
# Payload hoisted into a variable: bash 3.2 (macOS /bin/bash) mis-parses \" escapes inside a
# double-quoted "$( ... )" and shatters the call into extra words -- keep \" only in plain
# double-quoted strings, never nested inside "..."$(...)"..." (DUE_JSON pattern).
RECAP_JSON="{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"$RECAP_TRIGGER. Return one JSON only\", \"session_id\": \"selftest\"}"
RECAP_OUT="$(run_stub UserPromptSubmit "$RECAP_JSON" ok)"
check "sequence: internal Recap is skipped with no output" "$RECAP_OUT" "empty"
check "sequence: Stop does not deny again after the internal Recap (not re-armed)" "$(run_stub Stop "$STOP_JSON" ok stale)" "empty"
reset_state
STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"$STORE_TRIGGER$FACT\", \"session_id\": \"sessA\"}" rem_ok >/dev/null
check "another session's disk record does not suppress this session (latch isolation)" "$(run_stub Stop "$STOP_JSON" ok stale)" 'has:"decision": "deny"'
# ---- Review round #3 (behaviour): a per-session state file st_<sid>.json isolates A and B ----
# After the final decision the state file is a diagnostic trail only: neither A's nor B's disk
# record suppresses any Stop (bias to nudging); A/B isolation still comes from the per-session
# latch plus per-session state file (B's write never touches A's file).
reset_state
STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"$STORE_TRIGGER$FACT\", \"session_id\": \"sessA\"}" rem_ok >/dev/null
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "A asks a new question", "session_id": "sessA"}' ok >/dev/null
STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"$STORE_TRIGGER$FACT\", \"session_id\": \"sessB\"}" rem_ok >/dev/null
check "B's write does not suppress A's new turn (A/B isolation)" "$(run_stub Stop '{"hook_event_name": "Stop", "stop_hook_active": false, "session_id": "sessA"}' ok stale)" 'has:"decision": "deny"'
check "B's own disk record does not suppress B either (suppression cancelled)" "$(run_stub Stop '{"hook_event_name": "Stop", "stop_hook_active": false, "session_id": "sessB"}' ok stale)" 'has:"decision": "deny"'
reset_state
STUB_TITLE="$FACT" STUB_CONTENT="$FACT" run_stub UserPromptSubmit "{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"$STORE_TRIGGER$FACT\", \"session_id\": \"selftest\"}" rem_ok >/dev/null
check "Stop still denies after a successful store (disk suppression cancelled)" "$(run_stub Stop "$STOP_JSON" ok stale)" 'has:"decision": "deny"'
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "new turn after store", "session_id": "selftest"}' ok >/dev/null
check "the next turn is not suppressed by the previous successful write (should nudge)" "$(run_stub Stop "$STOP_JSON" ok stale)" 'has:"decision": "deny"'
CFG_NUDGE0="$TMP/config-nudge0.json"
echo '{"store_nudge_every": 0}' > "$CFG_NUDGE0"
check "Stop throttle off is silent" "$(printf '%s' '{"hook_event_name": "Stop", "stop_hook_active": false, "session_id": "selftest"}' | RESPITE_CONFIG="$CFG_NUDGE0" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" RESPITE_TURN_STATE="$TURNBASE" "$PY3" "$ROOT/hooks/respire.py" Stop)" "empty"
# P1-1 default throttle: with no store_nudge_every in the config the shipped default (4) makes
# the Stop nudge fire only on every 4th real Stop -- the first three are silent, the fourth
# denies (the throttle runs before the latch, so skips never consume it).
CFG_NUDGE_DEF="$TMP/config-nudgedefault.json"
printf '{"session_rules": true, "rsrs": "%s"}' "$STUB_ENGINE" > "$CFG_NUDGE_DEF"
reset_state
nudge_default() {
  printf '%s' "$STOP_JSON" | STUB_MODE=ok STUB_LIST=stale RESPITE_TEST_FAST=1 \
    RESPITE_CONFIG="$CFG_NUDGE_DEF" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" \
    RESPITE_TURN_STATE="$TURNBASE" "$PY3" "$ROOT/hooks/respire.py" Stop
}
check "default throttle: 1st Stop is silent" "$(nudge_default)" "empty"
check "default throttle: 2nd Stop is silent" "$(nudge_default)" "empty"
check "default throttle: 3rd Stop is silent" "$(nudge_default)" "empty"
check "default throttle: 4th Stop nudges" "$(nudge_default)" 'has:"decision": "deny"'
CFG_OFFE="$TMP/config-disabled.json"
echo '{"enabled": false}' > "$CFG_OFFE"
check "enabled=false silences everything" "$(run SessionStart "" "$CFG_OFFE")" "empty"
check "enabled=false stores silently too" "$(run UserPromptSubmit "$STORE_TRIGGER should not be stored when disabled" "$CFG_OFFE")" "empty"
# Engine-missing branch: inject by monkeypatching find_rsrs to None (a real machine cannot produce
# "every path missing").
# ROOTM is a mixed path -- Windows python cannot resolve MSYS /d/...
ROOTM="$(cygpath -m "$ROOT" 2>/dev/null || printf '%s' "$ROOT")"
run_engineless() {
  # Task-43: a missing CLI reaches the engine-bootstrap spawn decision (marker-gated).
  # RESPITE_TEST_FAST=1 is the hook's own backdoor: the SessionStart branch records the
  # verdict and never forks, so this is safe for a suite with no network; the fork itself
  # is exercised by run_enginefork below. Isolated RSRS_DATA_DIR keeps every marker out of
  # the real ~/.rsrs (this function runs 6+ times across E1-E3).
  ROOT_HOOK="$ROOTM" "$PY3" - <<'PY'
import io, os, sys, importlib.util, subprocess
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.find_rsrs = lambda cfg: None
class PopenBlocked(Exception):
    pass
real_popen = subprocess.Popen
def spy(*a, **k):
    argv = a[0] if a else []
    if any(str(x) == "--engine-setup" for x in argv):
        with open(os.environ["ENG_POPOUT"], "w", encoding="utf-8") as f:
            f.write("blocked")
        raise PopenBlocked
    return real_popen(*a, **k)
subprocess.Popen = spy
m.subprocess.Popen = spy
sys.argv = ["respire.py", "SessionStart"]
sys.stdin = io.StringIO('{"hook_event_name":"SessionStart"}')
# The real spawn path never raises, but an O_EXCL lock can make engine_spawn return
# "running" (a leftover from a previous case) -- record the verdict for diagnostics and
# keep the session note flowing; spawn evidence always comes from the DIRECT call below.
saved = sys.stdout
out = io.StringIO()
sys.stdout = out
try:
    m.main()
except SystemExit:
    pass
except BaseException:
    import traceback
    traceback.print_exc(file=sys.stderr)
sys.stdout = saved
try:
    print("ENGINESTATE=%s" % m.engine_spawn_state(m.load_config()))
except BaseException:
    print("ENGINESTATE=unknown")
print(out.getvalue(), end="")
PY
}
# Isolated home for the engine-bootstrap assertions: spawn evidence + marker idempotence.
# export first: the python heredocs read ENG_ARGS/ENG_POPOUT from os.environ, so the
# variables must be exported BEFORE the first call (a later export would be too late).
ENG_HOME="$TMP/engine-home-$RANDOM$RANDOM"
mkdir -p "$ENG_HOME"
ENG_ARGS="$ENG_HOME/spawn-argv.txt"
ENG_POPOUT="$ENG_HOME/spawn-blocked.txt"
export ENG_ARGS ENG_POPOUT
# E3 marker cases call run_enginefork directly from the parent shell; run_engineless_env's
# export lives inside a $(...) subshell and does not reach them. Export the isolation root
# here so _engine_paths() (via _granite_home/RSRS_DATA_DIR) reads the isolated markers.
export RSRS_DATA_DIR="$ENG_HOME"
eng_reset() {
  rm -f "$ENG_ARGS" "$ENG_POPOUT" "$ENG_HOME"/engine-setup.done "$ENG_HOME"/engine-setup.failed \
        "$ENG_HOME"/engine-setup.lock "$ENG_HOME"/engine-setup.log
  : > "$ENG_POPOUT"
}
eng_spawned() { [ -s "$ENG_ARGS" ] && grep -q -- "--engine-setup" "$ENG_ARGS" && echo YES || echo NO; }
eng_blocked() { [ -s "$ENG_POPOUT" ] && grep -q blocked "$ENG_POPOUT" && echo YES || echo NO; }
# run_enginefork: one DIRECT engine_spawn call with subprocess.Popen stubbed: records the
# argv and aborts before any real fork (the suite must never actually run npm).
run_enginefork() {
  # NOTE: this heredoc must NOT carry an env prefix -- the isolation vars are exported by
  # run_engineless_env; a prefix assignment on the bash FUNCTION call would not reach the
  # heredoc interpreter's environment on every shell.
  ROOT_HOOK="$ROOTM" "$PY3" - <<'PY'
import os, sys, importlib.util, subprocess
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.find_rsrs = lambda cfg: None
class PopenBlocked(Exception):
    """Sentinel: abort right after the stubbed fork so the spawn evidence survives."""
real_popen = subprocess.Popen
def spy(*a, **k):
    argv = a[0] if a else []
    if any(str(x) == "--engine-setup" for x in argv):
        with open(os.environ["ENG_ARGS"], "w", encoding="utf-8") as f:
            f.write(" ".join(map(str, argv)))
        raise PopenBlocked
    return real_popen(*a, **k)
subprocess.Popen = spy
m.subprocess.Popen = spy
# A stale-lock case seeds a DEAD-pid lock that engine_spawn's O_EXCL cannot overwrite; clear
# it first so the retry path can be observed. The live-lock case sets ENG_KEEP_LOCK=1 so its
# seeded LIVE lock is preserved and read as "running".
if os.environ.get("ENG_KEEP_LOCK") != "1":
    try:
        os.remove(m._engine_paths()["lock"])
    except OSError:
        pass
state = ""
try:
    state = m.engine_spawn(m.load_config())
except PopenBlocked:
    state = "start"       # the sentinel fires after the fork decision: that IS start
except BaseException:
    import traceback
    traceback.print_exc(file=sys.stderr)
print("STATE=%s" % state)
PY
}
run_engineless_env() {
  # run_engineless has no env prefix (it must stay a bare function call for $(...) capture);
  # the isolation vars are exported instead -- every process in this shell then sees them.
  RSRS_DATA_DIR="$ENG_HOME"
  RESPITE_LOG="$ENG_HOME/hook.log"
  export RSRS_DATA_DIR RESPITE_LOG
  run_engineless
}
# ---- E1: the four NO_RSRS checks, plus the fork evidence and the bootstrap log ----
eng_reset
# SessionStart runs FIRST: any engine-setup fork it attempts is intercepted by the
# PopenBlocked sentinel (ENG_POPOUT), so the suite never runs npm; the note assertions
# do not depend on spawn evidence -- the clean fork is driven by run_enginefork below.
OUT_ENG="$(run_engineless_env)"
check "engine missing injects the install command" "$OUT_ENG" "has:Install it with"
check "guidance forbids inventing a super password" "$OUT_ENG" "has:never pass --super"
check "guidance asks the user to keep the recovery code" "$OUT_ENG" "has:copy and keep it"
check "engine missing includes the next configuration step" "$OUT_ENG" "has:rsrs register"
check "engine-missing SessionStart offers the bootstrap worker (fork intercepted)" \
  "$(eng_blocked)" "has:YES"
# the DIRECT call must still fork on the clean path: reset first (the SessionStart case
# left its own lock/argv behind), then drive one engine_spawn with the stubbed Popen.
eng_reset
FORK_OUT="$(run_enginefork)"
check "engine missing forks the bootstrap worker (task-43)" "$(eng_spawned)" "has:YES"
check "engine spawn reports the start verdict" "$FORK_OUT" "has:STATE=start"
check "engine bootstrap spawn writes its own log" "$( [ -f "$ENG_HOME/engine-setup.log" ] && echo YES || echo NO )" "has:YES"
# ---- E2: the NO_RSRS text advertises the 2.x channel, never the stale @latest line ----
check "NO_RSRS tells the user to install the 2.x dev channel" "$OUT_ENG" "has:rsrs-cli@dev"
check "NO_RSRS never advertises the stale @latest channel" "$OUT_ENG" "hasnt:rsrs-cli@latest"
check "NO_RSRS says the plugin installs the CLI in the background" "$OUT_ENG" "has:installing the CLI for you in the background"
# ---- E3: marker idempotence -- .done / .failed / live lock / stale lock ----
# Each case seeds its markers FIRST and then runs ONE direct engine_spawn call; the marker
# must return its verdict with no fork (eng_spawned must stay NO), a stale lock must retry
# (reach the fork, which the stub records). run_enginefork clears any leftover lock AFTER
# the state check would have run... see its comment: it clears the lock first, so a
# previous case's lock cannot mask the seeded marker (the marker check runs before the
# lock check, and the lock is gone by then).
eng_reset
printf seeded > "$ENG_HOME/engine-setup.done"
FORK_OUT="$(run_enginefork)"
check "engine: a .done marker never respawns the worker" "$(eng_spawned)" "has:NO"
check "engine: a .done marker reports the done verdict" "$FORK_OUT" "has:STATE=done"
eng_reset
printf seeded > "$ENG_HOME/engine-setup.failed"
FORK_OUT="$(run_enginefork)"
check "engine: a .failed marker never respawns the worker" "$(eng_spawned)" "has:NO"
check "engine: a .failed marker reports the failed verdict" "$FORK_OUT" "has:STATE=failed"
eng_reset
printf '%s' "$$" > "$ENG_HOME/engine-setup.lock"
export ENG_KEEP_LOCK=1
FORK_OUT="$(run_enginefork)"
unset ENG_KEEP_LOCK
check "engine: a live lock never respawns the worker" "$(eng_spawned)" "has:NO"
check "engine: a live lock reports the running verdict" "$FORK_OUT" "has:STATE=running"
eng_reset
printf 999999 > "$ENG_HOME/engine-setup.lock"
FORK_OUT="$(run_enginefork)"
check "engine: a stale lock retries (fresh pid check, not terminal)" "$(eng_spawned)" "has:YES"
check "engine: a stale lock falls through to the start verdict" "$FORK_OUT" "has:STATE=start"
# ---- E3b: every hook-driven SessionStart is intercepted (no real npm from the suite) ----
# A marker-free engine-missing session must reach the fork offer (the sentinel records it)
# while never leaving real evidence of an executed install: only the DIRECT engine_spawn
# above actually drives the stubbed path cleanly.
eng_reset
OUT_ENG="$(run_engineless_env)"
check "engine-missing SessionStart offers the bootstrap worker (hook path)" \
  "$(eng_blocked)" "has:YES"
eng_reset   # leave the isolated home clean for anything after this block
# ---- F1-F4: task-51 -- repair a broken/stale CLI (isolated fake HOME, no real npm) ----
# Each case runs in its own F-home with its own find_rsrs stub, so the real machine state
# (~/.rsrs/bin/rsrs present or not) can never change the verdict. Popen is stubbed: the
# SessionStart fork is intercepted (PopenBlocked) and the worker's npm/verify calls are
# simulated, so nothing real ever runs. Exports are set BEFORE the first call.
F_HOME="$TMP/repair-home-$RANDOM$RANDOM"
mkdir -p "$F_HOME"
ENG_ARGS="$F_HOME/spawn-argv.txt"
ENG_POPOUT="$F_HOME/spawn-blocked.txt"
export ENG_ARGS ENG_POPOUT
f_reset() {
  rm -f "$ENG_ARGS" "$ENG_POPOUT" "$F_HOME"/engine-setup.done "$F_HOME"/engine-setup.failed \
        "$F_HOME"/engine-setup.lock "$F_HOME"/engine-setup.log "$F_HOME"/hook.log \
        "$F_HOME"/cargo/bin/rsrs "$F_HOME"/rsrs/bin/rsrs "$F_HOME"/oldbin/rsrs \
        "$F_HOME"/npm-global/bin/rsrs
  : > "$ENG_POPOUT"
}
f_spawned() { [ -s "$ENG_ARGS" ] && grep -q -- "--engine-setup" "$ENG_ARGS" && echo YES || echo NO; }
# F_SESSION <scenario>: one SessionStart with a scripted find_rsrs + version output.
# scenario old1x = found engine reports 1.x (stale build); scenario new2x = reports 2.x.
# Scenario old1x also plants a dangling PATH link (fake cargo) to mirror the real break.
f_session() {
  local scen="$1"
  SCEN="$scen" F_HOME="$F_HOME" ROOT_HOOK="$ROOTM" "$PY3" - <<'PY'
import io, os, sys, importlib.util, subprocess, traceback
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
home = os.environ["F_HOME"]
scen = os.environ["SCEN"]
# --- scripted environment: PATH carries only a fake cargo dir (no real rsrs) ---
cargo = os.path.join(home, "cargo", "bin")
os.makedirs(cargo, exist_ok=True)
dangling = os.path.join(cargo, "rsrs")
if os.path.lexists(dangling):
    os.remove(dangling)
if scen == "old1x":
    os.symlink(os.path.join(home, "deleted-target"), dangling)   # dangling on purpose
    os.environ["PATH"] = cargo + os.pathsep + os.environ.get("PATH", "")
else:
    os.environ["PATH"] = cargo + os.pathsep + "/usr/bin:/bin"    # no rsrs anywhere in PATH
# --- fake engine binaries: real files, version scripted by name ---
old_engine = os.path.join(home, "oldbin", "rsrs")
os.makedirs(os.path.dirname(old_engine), exist_ok=True)
open(old_engine, "w").write("#!/bin/sh\necho respire/rsrs 1.0.19\n")
os.chmod(old_engine, 0o755)
if scen == "new2x":
    ok = os.path.join(cargo, "rsrs")
    if os.path.lexists(ok):
        os.remove(ok)
    open(ok, "w").write("#!/bin/sh\necho rsrs 2.0.0-dev.18\n")
    os.chmod(ok, 0o755)
    m.find_rsrs = lambda cfg: ok
else:
    m.find_rsrs = lambda cfg: old_engine
# --- Popen stub: intercept the SessionStart fork, never let npm run ---
class PopenBlocked(Exception):
    pass
real_popen = subprocess.Popen
def spy(*a, **k):
    argv = a[0] if a else []
    if any(str(x) == "--engine-setup" for x in argv):
        with open(os.environ["ENG_ARGS"], "w", encoding="utf-8") as f:
            f.write(" ".join(map(str, argv)))
        with open(os.environ["ENG_POPOUT"], "w", encoding="utf-8") as f:
            f.write("blocked")
        raise PopenBlocked
    return real_popen(*a, **k)
subprocess.Popen = spy
m.subprocess.Popen = spy
sys.argv = ["respire.py", "SessionStart"]
sys.stdin = io.StringIO('{"hook_event_name":"SessionStart"}')
saved = sys.stdout
out = io.StringIO()
sys.stdout = out
try:
    m.main()
except (SystemExit, PopenBlocked):
    pass
except BaseException:
    traceback.print_exc(file=sys.stderr)
sys.stdout = saved
print(out.getvalue(), end="")
PY
}
# ---- F1: broken PATH + stale 1.x engine -> SessionStart must take the repair branch ----
f_reset
OUT_F1="$(f_session old1x)"
check "F1 broken-PATH+1x engine still shows the install guidance" "$OUT_F1" "has:Install it with"
check "F1 broken-PATH+1x engine offers the bootstrap worker" \
  "$( [ -s "$ENG_POPOUT" ] && grep -q blocked "$ENG_POPOUT" && echo YES || echo NO )" "has:YES"
check "F1 dangling PATH link was present before the worker ran" \
  "$( [ -L "$F_HOME/cargo/bin/rsrs" ] && [ ! -e "$F_HOME/cargo/bin/rsrs" ] && echo YES || echo NO )" "has:YES"
# ---- F2: a healthy 2.x CLI in PATH -> no repair (regression) ----
f_reset
OUT_F2="$(f_session new2x)"
check "F2 healthy 2.x CLI never offers the bootstrap worker" \
  "$( [ -s "$ENG_ARGS" ] && grep -q -- '--engine-setup' "$ENG_ARGS" && echo YES || echo NO )" "has:NO"
check "F2 healthy 2.x CLI injects the normal guidance (not NO_RSRS)" \
  "$OUT_F2" "hasnt:Install it with"
# ---- F3: engine_setup_main must NOT early-exit on a stale 1.x CLI ----
# The old code wrote .done(already-present) as soon as find_rsrs found anything; with a
# 1.x binary it must fall through, run npm, and only then verify + write .done(version).
f_reset
OUT_F3="$(F_HOME="$F_HOME" ROOT_HOOK="$ROOTM" "$PY3" - <<'PY'
import io, os, sys, importlib.util, traceback
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
home = os.environ["F_HOME"]
os.environ["RSRS_DATA_DIR"] = home              # keep all engine-setup markers in the F-home
# cli_needs_repair now takes a PATH-dangling shortcut BEFORE probing --version. A CI PATH
# may contain a dangling rsrs, which would skip the pre-flight probe and desync the fake_run
# call counter (verify would wrongly get the 1.x answer). Stub shutil.which so "npm" resolves
# (engine_setup_main needs it) while "rsrs" is never found -- a deterministic PATH on every
# host, independent of what npm/PATH the runner happens to provide.
_real_which = m.shutil.which
m.shutil.which = lambda name, *a, **k: ("/usr/bin/npm" if name == "npm" else None)
# Keep the real PATH free of any dangling rsrs (which would short-circuit cli_needs_repair
# before its version probe); npm is supplied by the which-stub above, not by PATH.
os.environ["PATH"] = os.path.dirname(sys.executable) + os.pathsep + "/usr/bin:/bin"
# engine_setup_main builds its npm --prefix from expanduser("~"), NOT from RSRS_DATA_DIR.
# Point "~" at the isolated home so the npm target and the verify target coincide; on a
# clean CI HOME there is no real ~/.npm-global/bin/rsrs, so without this the verify fails.
m.os.path.expanduser = lambda p: home if p in ("~", "") else p
old_engine = os.path.join(home, "oldbin", "rsrs")
os.makedirs(os.path.dirname(old_engine), exist_ok=True)
open(old_engine, "w").write("#!/bin/sh\necho respire/rsrs 1.0.19\n")
os.chmod(old_engine, 0o755)
m.find_rsrs = lambda cfg: old_engine          # stale 1.x found -> must NOT early-exit
# F3's contract is "a stale CLI must NOT early-exit; reinstall then verify". Express the
# stale verdict directly instead of relying on how many --version probes cli_needs_repair
# makes (that count varies with PATH/which across hosts). cli_needs_repair itself is covered
# by F5. Every --version here is a post-install verify and returns the healthy 2.x.
m.cli_needs_repair = lambda cfg, eng: True
calls = []
def fake_run(cmd, **kw):
    calls.append(" ".join(map(str, cmd)))
    class R:
        pass
    r = R()
    r.returncode = 0
    if cmd and str(cmd[0]).endswith("npm"):
        r.stdout, r.stderr = "added 1 package", ""
        target = os.path.join(home, ".npm-global", "bin", "rsrs")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        open(target, "w").write("#!/bin/sh\necho rsrs 2.0.0-dev.18\n")
        os.chmod(target, 0o755)
    else:
        r.stdout, r.stderr = "rsrs 2.0.0-dev.18", ""
    return r
m.subprocess.run = fake_run
saved = sys.stdout
out = io.StringIO()
sys.stdout = out
try:
    rc = m.engine_setup_main()
except BaseException:
    sys.stdout = saved
    traceback.print_exc(file=sys.stderr)
    raise
sys.stdout = saved
done = os.path.join(home, "engine-setup.done")
content = open(done, encoding="utf-8").read() if os.path.exists(done) else "<none>"
print("RC=%s" % rc)
print("DONE=%s" % content.strip())
print("NPM_RAN=%s" % ("YES" if any("npm" in c for c in calls) else "NO"))
print("CALLED_PREFIX=%s" % ("YES" if any("--prefix" in c for c in calls) else "NO"))
print("WORKER_OUT=%s" % out.getvalue().strip().replace("\n", " | "))
PY
)"
check "F3 stale 1.x does NOT early-exit (no already-present .done)" \
  "$OUT_F3" "hasnt:already-present"
check "F3 worker keeps going: .done records the installed 2.x version" \
  "$OUT_F3" "has:version=rsrs 2.0.0-dev.18"
check "F3 worker actually ran npm with --prefix" \
  "$OUT_F3" "has:CALLED_PREFIX=YES"
check "F3 worker exit code is 0" "$OUT_F3" "has:RC=0"
# ---- F4: the worker heals a dangling PATH link (real symlink + real fs) ----
f_reset
mkdir -p "$F_HOME/cargo/bin" "$F_HOME/npm-global/bin"
ln -s "$F_HOME/deleted-target" "$F_HOME/cargo/bin/rsrs"      # dangling, like ~/.cargo/bin/rsrs
printf '#!/bin/sh\necho rsrs 2.0.0-dev.18\n' > "$F_HOME/npm-global/bin/rsrs"
chmod +x "$F_HOME/npm-global/bin/rsrs"
PATH="$F_HOME/cargo/bin:$PATH" F_HOME="$F_HOME" ROOT_HOOK="$ROOTM" "$PY3" - <<'PY'
import os, sys, importlib.util
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
target = os.path.join(os.environ["F_HOME"], "npm-global", "bin", "rsrs")
m._repair_broken_path_links(target)            # the helper the worker calls after install
PY
check "F4 dangling cargo link now resolves to the new CLI" \
  "$( [ -L "$F_HOME/cargo/bin/rsrs" ] && [ -e "$F_HOME/cargo/bin/rsrs" ] && readlink "$F_HOME/cargo/bin/rsrs" | grep -q npm-global/bin/rsrs && echo YES || echo NO )" "has:YES"
check "F4 the healed link is executable (agent shell can run it)" \
  "$( [ -x "$F_HOME/cargo/bin/rsrs" ] && echo YES || echo NO )" "has:YES"
# ---- F5: cli_needs_repair itself (unit level, every branch) ----
f_reset
REPAIR_OUT="$(F_HOME="$F_HOME" ROOT_HOOK="$ROOTM" "$PY3" - <<'PY'
import os, sys, importlib.util
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
home = os.environ["F_HOME"]
cargo = os.path.join(home, "cargo", "bin")
os.makedirs(cargo, exist_ok=True)
os.environ["PATH"] = cargo + os.pathsep + "/usr/bin:/bin"      # no healthy rsrs in PATH
print("NONE_ENGINE=%s" % m.cli_needs_repair({}, None))        # engine None -> True
# A DANGLING rsrs symlink in PATH is the only PATH signal that means repair is due.
dangling = os.path.join(cargo, "rsrs")
os.symlink(os.path.join(home, "deleted-target"), dangling)
print("BROKEN_PATH=%s" % m.cli_needs_repair({}, "/bin/true"))  # dangling link -> True
# Plain absence of rsrs in PATH is fine (CLI may be explicitly configured via cfg/env).
os.remove(dangling)
print("ABSENT_PATH=%s" % m.cli_needs_repair({}, "/bin/true"))  # no link, no version -> False
old = os.path.join(home, "oldbin", "rsrs")
os.makedirs(os.path.dirname(old), exist_ok=True)
open(old, "w").write("#!/bin/sh\necho respire/rsrs 1.0.19\n"); os.chmod(old, 0o755)
print("OLD_1X=%s" % m.cli_needs_repair({}, old))              # 1.x -> True
open(old, "w").write("#!/bin/sh\necho rsrs 2.0.0-dev.18\n")    # now a healthy 2.x
ok = os.path.join(cargo, "rsrs")
open(ok, "w").write("#!/bin/sh\necho rsrs 2.0.0-dev.18\n"); os.chmod(ok, 0o755)
print("NEW_2X=%s" % m.cli_needs_repair({}, old))              # no dangling link + 2.x -> False
open(old, "w").write("#!/bin/sh\necho nothing parseable\n")
print("UNPARSABLE=%s" % m.cli_needs_repair({}, old))          # fail-open -> False
def boom(*a, **k):
    raise RuntimeError("probe exploded")
m.run_rsrs = boom
print("RAISED=%s" % m.cli_needs_repair({}, old))              # fail-open -> False
PY
)"
check "F5 engine None is needs-repair" "$REPAIR_OUT" "has:NONE_ENGINE=True"
check "F5 dangling PATH rsrs symlink is needs-repair" "$REPAIR_OUT" "has:BROKEN_PATH=True"
check "F5 absent rsrs in PATH is NOT needs-repair (explicit CLI ok)" "$REPAIR_OUT" "has:ABSENT_PATH=False"
check "F5 stale 1.x engine is needs-repair" "$REPAIR_OUT" "has:OLD_1X=True"
check "F5 healthy 2.x CLI is NOT needs-repair" "$REPAIR_OUT" "has:NEW_2X=False"
check "F5 unparsable version fails open (no guess)" "$REPAIR_OUT" "has:UNPARSABLE=False"
check "F5 probe exception fails open (never blocks SessionStart)" "$REPAIR_OUT" "has:RAISED=False"
# ---- E4: granite defers to engine-setup when the CLI is missing (no .failed marker) ----
if [ -n "$ROOTM" ] && "$PY3" -c 'import importlib.util' 2>/dev/null; then
  gdefer() {
    local home="$TMP/granite-defer-$RANDOM$RANDOM"
    mkdir -p "$home"
    RSRS_DATA_DIR="$home" RESPITE_LOG="$home/hook.log" "$PY3" - <<'PY'
import io, os, sys, importlib.util
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.find_rsrs = lambda cfg: None     # a machine with no CLI: the DEFER branch must win
home = m._granite_home()
p = m._granite_paths()
open(p["lock"], "w").write(str(os.getpid()))
out = io.StringIO()
sys.stdout = out
try:
    rc = m.granite_setup_main()
finally:
    sys.stdout = sys.__stdout__
print("RC=%s FAILED=%s LOCK=%s DONE=%s" % (
    rc, os.path.exists(p["failed"]), os.path.exists(p["lock"]), os.path.exists(p["done"])))
print(out.getvalue().strip())
PY
  }
  GD_OUT="$(ROOT_HOOK="$ROOTM" gdefer)"
  check "granite defers cleanly when the CLI is missing (no .failed marker)" "$GD_OUT" "has:RC=0 FAILED=False LOCK=False"
  check "granite defers with an explicit reason in the trail" "$GD_OUT" "has:[granite-setup] DEFER:"
fi
# ---- A+C session guidance: three-way SessionStart split (runtime down / no model / all good).
# The runtime-down and all-good paths need a real `status` envelope, so they are injected by
# monkeypatching probe_status; model_status goes through the stub engine above (STUB_MODEL).
SS_JSON='{"hook_event_name":"SessionStart"}'
run_probe_fail() {
  ROOT_HOOK="$ROOTM" "$PY3" - <<'PY'
import io, os, sys, importlib.util
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.find_rsrs = lambda cfg: "rsrs-stub"
m.probe_status = lambda b: (None, None, False, None)
sys.argv = ["respire.py", "SessionStart"]
sys.stdin = io.StringIO('{"hook_event_name":"SessionStart"}')
try:
    m.main()
except SystemExit:
    pass
PY
}
check "runtime down injects the runtime-start guidance" "$(run_probe_fail)" "has:rsrs runtime start"
check "runtime down keeps the rules" "$(run_probe_fail)" "has:respire memory discipline"
check "runtime down still tells the agent the store is not empty" "$(run_probe_fail)" "has:do not assume the memory store is empty"
OUT_SS_MODELMISS="$(printf '%s' "$SS_JSON" | STUB_MODE=ok STUB_MODEL=missing RESPITE_TEST_FAST=1 \
  RESPITE_CONFIG="$CFG_STUB" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" \
  RESPITE_TURN_STATE="$TURNBASE" RESPITE_CONSOLIDATE_STATE="$TMP/consolidate.json" "$PY3" "$ROOT/hooks/respire.py" SessionStart)"
check "no model variant injects the lexical-mode note" "$OUT_SS_MODELMISS" "has:no model"
check "no model note keeps the rules" "$OUT_SS_MODELMISS" "has:respire memory discipline"
check "no model note does not push an install" "$OUT_SS_MODELMISS" "hasnt:you should install"
OUT_SS_MODELPRESENT="$(printf '%s' "$SS_JSON" | STUB_MODE=ok STUB_MODEL=present RESPITE_TEST_FAST=1 \
  RESPITE_CONFIG="$CFG_STUB" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" \
  RESPITE_TURN_STATE="$TURNBASE" RESPITE_CONSOLIDATE_STATE="$TMP/consolidate.json" "$PY3" "$ROOT/hooks/respire.py" SessionStart)"
check "a present model variant injects no model note" "$OUT_SS_MODELPRESENT" "hasnt:no model"
check "a present model variant still injects the rules" "$OUT_SS_MODELPRESENT" "has:respire memory discipline"
OUT_SS_MODELERR="$(printf '%s' "$SS_JSON" | STUB_MODE=ok STUB_MODEL=error RESPITE_TEST_FAST=1 \
  RESPITE_CONFIG="$CFG_STUB" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" \
  RESPITE_TURN_STATE="$TURNBASE" RESPITE_CONSOLIDATE_STATE="$TMP/consolidate.json" "$PY3" "$ROOT/hooks/respire.py" SessionStart)"
check "a broken model envelope fails open (rules only, no note)" "$OUT_SS_MODELERR" "hasnt:no model"
check "a broken model envelope still injects the rules" "$OUT_SS_MODELERR" "has:respire memory discipline"
# ---- Sync-off fourth segment: remote_configured=false (STUB_SYNC=off) -> cloud-sync note;
# synced envelope -> no note; probe failure -> no sync note (status untrusted); model-missing
# + sync-off stacks both notes.
OUT_SS_SYNCOFF="$(printf '%s' "$SS_JSON" | STUB_MODE=ok STUB_SYNC=off STUB_MODEL=present RESPITE_TEST_FAST=1 \
  RESPITE_CONFIG="$CFG_STUB" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" \
  RESPITE_TURN_STATE="$TURNBASE" RESPITE_CONSOLIDATE_STATE="$TMP/consolidate.json" "$PY3" "$ROOT/hooks/respire.py" SessionStart)"
check "sync off injects the cloud-sync note" "$OUT_SS_SYNCOFF" "has:cloud sync off"
check "sync off note keeps the rules" "$OUT_SS_SYNCOFF" "has:respire memory discipline"
check "sync off note does not claim the store is broken" "$OUT_SS_SYNCOFF" "has:local-only use is fully supported"
check "sync off with model present injects no model note" "$OUT_SS_SYNCOFF" "hasnt:no model"
OUT_SS_SYNCON="$(printf '%s' "$SS_JSON" | STUB_MODE=ok STUB_MODEL=present RESPITE_TEST_FAST=1 \
  RESPITE_CONFIG="$CFG_STUB" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" \
  RESPITE_TURN_STATE="$TURNBASE" RESPITE_CONSOLIDATE_STATE="$TMP/consolidate.json" "$PY3" "$ROOT/hooks/respire.py" SessionStart)"
check "synced session injects no cloud-sync note" "$OUT_SS_SYNCON" "hasnt:cloud sync off"
check "synced session still injects the rules" "$OUT_SS_SYNCON" "has:respire memory discipline"
OUT_SS_PROBEFAIL="$(printf '%s' "$SS_JSON" | STUB_MODE=ok STUB_SYNC=off RESPITE_TEST_FAST=1 \
  RESPITE_CONFIG="$CFG_STUB" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" \
  RESPITE_TURN_STATE="$TURNBASE" RESPITE_CONSOLIDATE_STATE="$TMP/consolidate.json" \
  RESPITE_FAKE_PROBE_FAIL=1 "$PY3" "$ROOT/hooks/respire.py" SessionStart)"
check "probe failure does not inject the cloud-sync note" "$OUT_SS_PROBEFAIL" "hasnt:cloud sync off"
check "probe failure still injects the runtime-down note" "$OUT_SS_PROBEFAIL" "has:rsrs runtime start"
OUT_SS_STACK="$(printf '%s' "$SS_JSON" | STUB_MODE=ok STUB_SYNC=off STUB_MODEL=missing RESPITE_TEST_FAST=1 \
  RESPITE_CONFIG="$CFG_STUB" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" \
  RESPITE_TURN_STATE="$TURNBASE" RESPITE_CONSOLIDATE_STATE="$TMP/consolidate.json" "$PY3" "$ROOT/hooks/respire.py" SessionStart)"
check "model missing and sync off stack both notes" "$OUT_SS_STACK" "has:no model"
check "model missing and sync off stack both notes (sync)" "$OUT_SS_STACK" "has:cloud sync off"
check "stacked notes keep the rules" "$OUT_SS_STACK" "has:respire memory discipline"
if [ "$HAVE_RSRS" = 1 ]; then

  out=$(run UserPromptSubmit "$QUERY_RECALL")
  check "a relevant prompt triggers recall" "$out" "nonempty"
  check "injection is the title tier with no body" "$out" "hasnt:$FULLWIDTH_BAR"
  check "default output has no threshold gate" "$out" "has:rsrs direct"
  check "recall header matches the item count" "$(printf '%s' "$out" | "$PY3" -c '
import re,sys
s=sys.stdin.read(); head=s.split("\n",1)[0]
n=sum(1 for l in s.split("\n") if l.startswith("- ["))
m=re.search(r"matched (\d+)",head)
print("OK" if m and int(m.group(1))==n else "BAD")')" "has:OK"
else
  echo "SKIP  real-store read-only branches (no rsrs engine: probe-failure section and 5 recall-injection checks)"
fi

check "an irrelevant prompt injects nothing (engine skip gate, deterministic stub)" "$(run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "kitchen recipe banana bread", "session_id": "selftest"}' rec_skip)" "empty"
check "a single-character prompt is skipped" "$(run UserPromptSubmit "k")" "empty"
check "/nomem turns recall off" "$(run UserPromptSubmit "/nomem rsrs envelope structure")" "empty"
# ---- T1-1 due-check: the footer appears only when review --due has items; every failure path
# ---- and every non-real turn stays silent (counts only, never ids or titles) ----
DUE_JSON='{"hook_event_name": "UserPromptSubmit", "prompt": "a normal keyword prompt for due testing", "session_id": "selftest"}'
check "due footer appears when review reports due items" "$(run_stub UserPromptSubmit "$DUE_JSON" ok "" "" hit)" "has:【respire · due】3 条待复核"
DUE_KW_JSON='{"hook_event_name": "UserPromptSubmit", "prompt": "due footer keyword probe fusion gate", "session_id": "selftest"}'
check "due footer is the last injected line after the recall block" "$(run_stub UserPromptSubmit "$DUE_KW_JSON" ok "" "" hit | "$PY3" -c 'import sys
lines = sys.stdin.read().rstrip("\n").split("\n")
print("OK" if lines and lines[-1].startswith("【respire · due】") and any("auto-recall" in l for l in lines) else "BAD")')" "has:OK"
run_stub UserPromptSubmit "$DUE_JSON" ok "" "" hit >/dev/null
check "due hit is logged with its reason code" "$(grep -q '"ev": "due", "out": "hit"' "$TMP/hook.log" && echo YES || echo NO)" "has:YES"
check "no due footer when nothing is due" "$(run_stub UserPromptSubmit "$DUE_JSON" ok)" "hasnt:【respire · due】"
check "a failing review envelope fails open (no footer)" "$(run_stub UserPromptSubmit "$DUE_JSON" ok "" "" fail)" "hasnt:【respire · due】"
check "a dead review process fails open (no footer)" "$(run_stub UserPromptSubmit "$DUE_JSON" ok "" "" error)" "hasnt:【respire · due】"
check "/nomem turns stay due-free even when items are due" "$(run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "/nomem skip recall only", "session_id": "selftest"}' ok "" "" hit)" "hasnt:【respire · due】"
STORE_DUE_JSON="{\"hook_event_name\": \"UserPromptSubmit\", \"prompt\": \"$STORE_TRIGGER$FACT\", \"session_id\": \"selftest\"}"
check "store-prefix turns stay due-free even when items are due" "$(run_stub UserPromptSubmit "$STORE_DUE_JSON" ok "" "" hit)" "hasnt:【respire · due】"
CFG_NODUE="$TMP/config-nodue.json"
printf '{"session_rules": true, "rsrs": "%s", "due_check": false}' "$STUB_ENGINE" > "$CFG_NODUE"
check "due_check=false silences the due-check" "$(printf '%s' "$DUE_JSON" | STUB_MODE=ok STUB_DUE=hit RESPITE_TEST_FAST=1 RESPITE_CONFIG="$CFG_NODUE" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" RESPITE_TURN_STATE="$TURNBASE" RESPITE_CONSOLIDATE_STATE="$TMP/consolidate.json" "$PY3" "$ROOT/hooks/respire.py" UserPromptSubmit)" "hasnt:【respire · due】"
check "the example config documents due_check" "$(cat "$ROOT/hooks/respire.config.example.json")" "has:due_check"
# ---- T1-2 low-frequency consolidation trigger (local phase): log-only and model-free --
# ---- it never injects, the throttle/cooldown live in a state file, every failure path
# ---- stays quiet, and /nomem, store-prefix and disabled-config turns never consult it ----
CONS_JSON='{"hook_event_name": "UserPromptSubmit", "prompt": "consolidate keywords probe turn", "session_id": "selftest"}'
: > "$TMP/hook.log"; rm -f "$TMP/consolidate.json"
OUT_CONS="$(run_stub UserPromptSubmit "$CONS_JSON" ok "" selftest "" hit)"
check "threshold counter fires the consolidate trigger" "$(grep -aq '"ev": "consolidate", "out": "fire"' "$TMP/hook.log" && echo YES || echo NO)" "has:YES"
check "fire reason is threshold with counter numbers" "$(grep -aq 'reason=threshold count=40 thr=30' "$TMP/hook.log" && echo YES || echo NO)" "has:YES"
check "fire runs a local audit and logs its counts" "$(grep -aq '"ev": "consolidate", "out": "audit"' "$TMP/hook.log" && grep -aq 'orphans=2' "$TMP/hook.log" && grep -aq 'skill_template_gaps=3' "$TMP/hook.log" && echo YES || echo NO)" "has:YES"
check "redact keeps skill fields but still masks sk- tokens" "$("$PY3" -c '
import sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOTM"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
keep = m.redact("skill_template_gaps=619 failing_skills=0") == "skill_template_gaps=619 failing_skills=0"
mask = "[REDACTED]" in m.redact("key=sk-abcdef123456 and ghp_abcdefgh123456")
print("OK" if keep and mask else "BAD")')" "has:OK"
check "consolidate never injects a marker into the turn" "$OUT_CONS" "hasnt:respire · tidy"
check "consolidate never injects a footer line" "$OUT_CONS" "hasnt:待巩固"
check "a fire turn still delivers the recall block" "$OUT_CONS" "has:auto-recall"
: > "$TMP/hook.log"; rm -f "$TMP/consolidate.json"
run_stub UserPromptSubmit "$CONS_JSON" ok "" selftest "" "" >/dev/null
check "zero counter skips (logged as zero, never fires)" "$(grep -aq '"ev": "consolidate", "out": "zero"' "$TMP/hook.log" && ! grep -aq '"out": "fire"' "$TMP/hook.log" && echo YES || echo NO)" "has:YES"
: > "$TMP/hook.log"
# Seed with bash printf, not python -c: native Windows python cannot open the inline MSYS
# /tmp path (the hook's env-var path is converted for native children, inline code is not).
printf '{"last_check_ms": %s000}' "$(date +%s)" > "$TMP/consolidate.json"
run_stub UserPromptSubmit "$CONS_JSON" ok "" selftest "" hit >/dev/null
check "a fresh check timestamp throttles the counter call entirely" "$(grep -aq '"ev": "consolidate"' "$TMP/hook.log" && echo NO || echo YES)" "has:YES"
: > "$TMP/hook.log"
printf '{"last_check_ms": 0, "last_fire_ms": 0}' > "$TMP/consolidate.json"
run_stub UserPromptSubmit "$CONS_JSON" ok "" selftest "" weekly >/dev/null
check "weekly fallback fires for a nonzero sub-threshold counter" "$(grep -aq 'reason=weekly count=5 thr=30' "$TMP/hook.log" && echo YES || echo NO)" "has:YES"
: > "$TMP/hook.log"; rm -f "$TMP/consolidate.json"
run_stub UserPromptSubmit "$CONS_JSON" ok "" selftest "" error >/dev/null
check "a dead resort process fails open (no fire)" "$(grep -aq '"out": "status_' "$TMP/hook.log" && ! grep -aq '"out": "fire"' "$TMP/hook.log" && echo YES || echo NO)" "has:YES"
: > "$TMP/hook.log"; rm -f "$TMP/consolidate.json"
OUT_AUD="$(run_stub UserPromptSubmit "$CONS_JSON" ok "" selftest "" audit_error)"
check "fire is logged even when the audit call fails" "$(grep -aq '"out": "fire"' "$TMP/hook.log" && echo YES || echo NO)" "has:YES"
check "a failed audit logs its reason code, not counts" "$(grep -aq '"out": "audit_parse"' "$TMP/hook.log" && ! grep -aq '"out": "audit"' "$TMP/hook.log" && echo YES || echo NO)" "has:YES"
check "a failed audit still injects nothing" "$OUT_AUD" "hasnt:respire · tidy"
: > "$TMP/hook.log"; rm -f "$TMP/consolidate.json"
run_stub UserPromptSubmit '{"hook_event_name": "UserPromptSubmit", "prompt": "/nomem skip consolidate too", "session_id": "selftest"}' ok "" selftest "" hit >/dev/null
run_stub UserPromptSubmit "$STORE_DUE_JSON" ok "" selftest "" hit >/dev/null
check "/nomem and store-prefix turns never consult the counter" "$(grep -aq '"ev": "consolidate"' "$TMP/hook.log" && echo NO || echo YES)" "has:YES"
CFG_NOCONS="$TMP/config-nocons.json"
printf '{"session_rules": true, "rsrs": "%s", "consolidate_check": false}' "$STUB_ENGINE" > "$CFG_NOCONS"
: > "$TMP/hook.log"; rm -f "$TMP/consolidate.json"
printf '%s' "$CONS_JSON" | STUB_MODE=ok STUB_TIDY=hit RESPITE_TEST_FAST=1 RESPITE_CONFIG="$CFG_NOCONS" RESPITE_LOG="$TMP/hook.log" RESPITE_NUDGE_STATE="$TMP/nudge" RESPITE_TURN_STATE="$TURNBASE" RESPITE_CONSOLIDATE_STATE="$TMP/consolidate.json" "$PY3" "$ROOT/hooks/respire.py" UserPromptSubmit >/dev/null
check "consolidate_check=false silences the trigger" "$(grep -aq '"ev": "consolidate"' "$TMP/hook.log" && echo NO || echo YES)" "has:YES"
check "the example config documents consolidate_check" "$(cat "$ROOT/hooks/respire.config.example.json")" "has:consolidate_check"
# ---- Suspected-credential guard: the credential value is assembled at run time (no complete
# ---- literal in the source, so a pre-release static scan has no false positive); the engine stub
# ---- logs every call.
# The stub engine is a python script: a bash stub cannot be CreateProcess'd on Windows, so "the
# stub never ran" and "the guard blocked it" would be indistinguishable and the zero-call
# assertion would pass falsely; on Windows wrap it in .cmd (an extensionless shim cannot be run by
# cmd.exe, fall back to py.exe/python.exe), on Unix use it directly.
SYN_SECRET="sk-""q7xkwm2vbnr8tzc41p9e"
STUB_SPY="$TMP/rsrs-spy"
SPY_LOG="$(cygpath -m "$TMP" 2>/dev/null || printf '%s' "$TMP")/spy.log"
cat > "$STUB_SPY" <<PY
#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
try:  # append one line per call (all arguments): used by the zero-call count and the "no credential literal reached the stub" check
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
# Convert the stub path to Windows form (native python does not know POSIX temp dirs; leave as-is
# where cygpath is unavailable).
SPY_PATH="$(cygpath -m "$SPY_RUN" 2>/dev/null || printf '%s' "$SPY_RUN")"
CFG_SPY="$TMP/config-spy.json"
echo '{"session_rules": true, "rsrs": "'"$SPY_PATH"'"}' > "$CFG_SPY"
calls_n() { [ -f "$TMP/spy.log" ] && wc -l < "$TMP/spy.log" | tr -d '[:space:]' || echo 0; }
# T1-1/T1-2: review --due and the resort/audit consolidate check are sanctioned local per-turn
# calls on real turns; the sentence/credential checks below count engine calls EXCEPT those so
# a raw-prompt leak can never be masked by maintenance.
calls_n_noreview() { [ -f "$TMP/spy.log" ] && grep -avE '^(review|resort|audit)( |$)' "$TMP/spy.log" | wc -l | tr -d '[:space:]' || echo 0; }

# Positive control first (SKIP is not allowed): the same spy is called once for real with ordinary
# input -- the stub really ran, the call was recorded and its valid JSON was injected; if the
# control fails the whole credential-guard group is marked FAIL (a dead stub is not a blocked
# guard, never a false pass).
N0="$(calls_n)"
spy_out="$(run UserPromptSubmit "$QUERY_RECALL" "$CFG_SPY")"
check "ordinary input still reaches the engine stub" "$( [ "$(calls_n)" -gt "$N0" ] && echo YES || echo NO )" "has:YES"
check "ordinary input still injects recall" "$spy_out" "has:auto-recall"
check "positive control: the stub's own output parses as JSON" "$(printf '%s\n' 'positive control probe' | "$PY3" "$STUB_SPY" recall probe --titles --json | "$PY3" -c 'import json,sys
print("OK" if json.load(sys.stdin).get("status") == "ok" else "BAD")' 2>/dev/null)" "has:OK"
check "positive control: the recall count comes from the stub" "$spy_out" "has:matched 1 item(s)"
check "positive control: the recall entry is the stub's canned one" "$spy_out" "has:[0.90] spy"
check "positive control: the call is recorded as recall" "$(grep -aqE '^recall( |$)' "$TMP/spy.log" 2>/dev/null && echo YES || echo NO)" "has:YES"
# Hybrid recall (defer_sentence): a sentence-shaped prompt must never reach the engine; the hook
# injects the keyword-distillation directive instead and the agent compiles the keywords.
N_SENT="$(calls_n_noreview)"
sent_out="$(run UserPromptSubmit "$SENT_PROMPT" "$CFG_SPY")"
check "a sentence-shaped prompt injects the keyword directive" "$sent_out" "has:recall pending"
check "the directive tells the agent to distill keywords first" "$sent_out" "has:distill 3-5 keywords"
check "a sentence-shaped prompt never queries the engine (review excluded)" "$( [ "$(calls_n_noreview)" = "$N_SENT" ] && echo SAME || echo CALLED )" "has:SAME"
check "the deferral is logged with its reason code" "$(grep -aq '"out": "defer_sentence"' "$TMP/hook.log" && echo YES || echo NO)" "has:YES"
check "a keyword-shaped prompt still recalls synchronously" "$(run UserPromptSubmit "$QUERY_RECALL" "$CFG_SPY")" "has:auto-recall"

SPY_ALIVE=1
[ "$(calls_n)" -gt "$N0" ] || SPY_ALIVE=0
grep -aqE '^recall( |$)' "$TMP/spy.log" 2>/dev/null || SPY_ALIVE=0
printf '%s' "$spy_out" | grep -aqF "auto-recall" || SPY_ALIVE=0

if [ "$SPY_ALIVE" = 1 ]; then
  N1="$(calls_n)"
  out=$(run UserPromptSubmit "api_key = $SYN_SECRET please store" "$CFG_SPY")
  check "a suspected credential is not sent to the engine" "$out" "has:contains a credential"
  check "the synthetic credential is not in the injected output" "$(printf '%s' "$out" | grep -qF -- "$SYN_SECRET" && echo LEAK || echo SAFE)" "has:SAFE"
  check "the synthetic credential is not in the log" "$(grep -aqF -- "$SYN_SECRET" "$TMP/hook.log" 2>/dev/null && echo LEAK || echo SAFE)" "has:SAFE"
  check "a credential hit logs the reason code only" "$(grep -a '"out": "secret_skip"' "$TMP/hook.log" | grep -q '"d"' && echo HASDETAIL || echo CODEONLY)" "has:CODEONLY"
  check "the engine stub never saw the credential input" "$(grep -aqF -- "$SYN_SECRET" "$TMP/spy.log" 2>/dev/null && echo GOT || echo CLEAN )" "has:CLEAN"
  check "the engine stub saw no call for that turn" "$( [ "$(calls_n)" = "$N1" ] && echo SAME || echo CALLED )" "has:SAME"
else
  echo "FAIL  positive control did not observe the engine stub really running -- the credential-guard group is unverified and the 6 checks below do not count as passing"
  for _nm in credential-not-sent credential-not-injected credential-not-logged reason-code-only stub-no-credential stub-no-call; do
    FAIL=$((FAIL+1)); echo "FAIL  $_nm (dead spy, group unverified)"
  done
fi
check "a suspected credential is not stored" "$(run UserPromptSubmit "$STORE_TRIGGER$ZH_SECRET_LABEL = hunter2u")" "has:contains a credential"
check "Qoder internal Recap prompts skip recall" "$(run UserPromptSubmit "$RECAP_TRIGGER.\nReturn one JSON only")" "empty"
check "the internal prefix whitelist is configurable" "$(cat "$ROOT/hooks/respire.config.example.json")" "has:skip_prefixes"
if [ "$HAVE_RSRS" = 1 ]; then
  check "a skill-identification turn strips the prefix and still recalls" "$(run UserPromptSubmit '$skill: bihen '"$QUERY_RECALL")" "has:auto-recall"
else
  echo "SKIP  skill-identification prefix strip still recalls (no rsrs engine; recall injection needs the real store)"
fi
check "bad stdin is silent" "$(printf 'not-json{{{' | RESPITE_CONFIG="$CFG_ON" "$PY3" "$ROOT/hooks/respire.py" UserPromptSubmit)" "empty"
check "an unknown event is silent" "$(run PreToolUse "rsrs envelope")" "empty"

# ---- title rule extraction (pure function, zero pollution; ROOTM is a mixed path -- Windows
# ---- python cannot resolve MSYS /d/...)
check "whole sentence is preferred" "$("$PY3" -c '
import sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOTM"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t=m.extract_title("respire \u63d2\u4ef6\u8def\u5f84\u8fc1\u81f3 memocap \u4e0b\u3002\u540e\u7eed\u4ee5\u4ed3\u5e93\u4e3a\u51c6\u3002")
print("OK" if t=="respire \u63d2\u4ef6\u8def\u5f84\u8fc1\u81f3 memocap \u4e0b\u3002" else "BAD:"+t)')" "has:OK"
check "no full stop falls back to a separator without splitting a word" "$("$PY3" -c '
import sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOTM"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t=m.extract_title("\u8fd9\u662f\u4e00\u6761\u6ca1\u6709\u53e5\u53f7\u7684\u957f\u4e8b\u5b9e\u53e5\uff0c\u8bb2\u6e05\u695a\u4f55\u65f6\u8c01\u505a\u4e86\u4ec0\u4e48\u4e8b\uff0c\u4ee5\u53ca\u7ed3\u679c\u5982\u4f55\uff0c\u540e\u9762\u8fd8\u6709\u522b\u7684\u5185\u5bb9")
print("OK" if "\u8bb2\u6e05\u695a\u4f55\u65f6\u8c01\u505a\u4e86\u4ec0\u4e48\u4e8b\uff0c" in t else "BAD:"+t)')" "has:OK"
# ---- Hybrid recall: sentence vs keyword shape (pure function, no engine) ----
check "keyword-shaped prompt stays synchronous" "$("$PY3" -c '
import sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOTM"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("OK" if not m.looks_like_sentence("respire fusion attention gate pool") else "BAD")')" "has:OK"
check "sentence-shaped prompt defers (the agent distils keywords)" "$(P="$SENT_PROMPT" "$PY3" -c '
import os,sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOTM"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("OK" if m.looks_like_sentence(os.environ["P"]) else "BAD")')" "has:OK"
check "a long unbroken run defers" "$("$PY3" -c '
import sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOTM"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("OK" if m.looks_like_sentence("abcdefghijklmnopqrstuvwxyz1234567890") else "BAD")')" "has:OK"
check "a long run stays within 70 chars" "$("$PY3" -c '
import sys,importlib.util
spec=importlib.util.spec_from_file_location("r","'"$ROOTM"'/hooks/respire.py"); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("OK" if len(m.extract_title("\u9ed8"*200))<=70 else "BAD")')" "has:OK"

# ---- Review round #3 (barrier) plus review 4 final: deterministic interleaving -- the shared-map
# ---- read-modify-write rollback is eliminated (per-session st_<sid>.json)
# Interleaving: A had prompt_ts=1/store_ts=2 from the previous turn; after B reads its state and
# before it writes back (os.replace barrier injected), A receives a new real request
# (prompt_ts=3). With the old shared map, B's stale full snapshot would restore A to
# store_ts>=prompt_ts and wrongly suppress; with independent files B writes only st_B and A's st_A
# cannot be touched. After the final decision disk-receipt suppression is cancelled: turn_stored is
# always False, so the assertion never depends on any disk record suppressing (bias to nudging);
# the state file is a diagnostic trail only and the rollback guarantee no longer involves suppression.
BARRIER_OUT=$(BARRIER_DIR="$TMPBASE/barrier" ROOT_HOOK_M="$ROOTM" "$PY3" - <<'PY'
import importlib.util, os, time
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK_M"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
os.environ["RESPITE_TURN_STATE"] = os.environ["BARRIER_DIR"]
os.makedirs(os.environ["BARRIER_DIR"], exist_ok=True)
now = time.time()
# A's previous turn: prompt early, store later (the old receipt looked "stored and fresh")
m._state_update("sessA", {"prompt_ts": now - 200.0})
m._state_update("sessA", {"store_ts": now - 100.0, "store_req_ts": now - 150.0})
# Deterministic barrier: A's new real request lands at the moment B writes its state back (just
# before the rename reaches disk).
bpath = os.path.abspath(m._state_path("sessB"))
real_replace, fired = os.replace, [False]
def replace_barrier(src, dst):
    if os.path.abspath(dst) == bpath and not fired[0]:
        fired[0] = True
        m._state_update("sessA", {"prompt_ts": now})  # A's new real request lands inside B's write-back window
    return real_replace(src, dst)
os.replace = replace_barrier
try:
    m._state_update("sessB", {"store_ts": now, "store_req_ts": now - 50.0})  # B writes its own state (the old implementation wrote the whole shared map back)
finally:
    os.replace = real_replace
checks = [
    m._state_load("sessA").get("prompt_ts") == now,  # A's prompt_ts was not rolled back by B's stale snapshot
    not m.turn_stored("sessA"),                      # suppression cancelled (review 4 final): a disk record never suppresses
    m._state_load("sessB").get("store_ts") == now,   # B's concurrent update was not lost
]
# Late-completing old request: the write began before the new prompt and finished after it -- also
# never suppresses (final decision: no disk record suppresses).
m._state_update("sessA", {"store_ts": now + 1.0, "store_req_ts": now - 300.0})
checks.append(not m.turn_stored("sessA"))
print("OK" if all(checks) else "BAD:%r" % (checks,))
PY
)
check "barrier interleaving: independent files are not rolled back by a stale snapshot" "$BARRIER_OUT" "has:OK"

# ---- Write probe (enabled explicitly with --store; writes the real store, asserts, then forgets)
if [ "$WITH_STORE" = 1 ] && [ "$HAVE_RSRS" = 1 ]; then
  # The content must be semantically unrelated to the whole store: a purely random meaningless
  # string (domain words like "probe/test/memory" collide at 30%+ similarity and go pending).
  MARK="zq$(date +%s)$RANDOM kw7f2 random meaningless marker"
  out=$(run UserPromptSubmit "$STORE_TRIGGER$MARK")
  check "explicit prefix writes nothing" "$out" "has:nothing was written"
  check "explicit prefix stays pending" "$out" "has:store pending"
  check "explicit prefix names the parent requirement" "$out" "has:--parent"
  # A restated entry takes the same path: the hook does not write, so nothing needs cleanup.
  out=$(run UserPromptSubmit "$STORE_TRIGGER$DEDUP_PROMPT")
  check "restated entry also stays pending" "$out" "has:store pending"
  check "restated entry was not written" "$out" "has:nothing was written"
elif [ "$WITH_STORE" = 1 ]; then
  echo "SKIP  write probe (no rsrs engine found, cannot write the real store)"
else
  echo "SKIP  write probe (read-only by default; add --store to write the real store and auto-forget)"
fi

# ---- task-31: granite-311m-r2 automatic setup (respire.py:1002-1282) ----------------------
# The worker is NEVER forked here: RESPITE_TEST_FAST=1 makes granite_spawn_state return
# "no_engine" unless RESPITE_GRANITE_SPAWN=1 is also set, and RSRS_DATA_DIR points the
# granite state (done/failed/lock/log) at a per-case temp dir instead of the real ~/.rsrs.
# The trigger is model_status returning False (respire.py:2332): the no-model backdoor is
# RESPITE_FAKE_NO_MODEL=1, the present verdict comes from the STUB_MODEL=missing engine stub.
if [ -n "$ROOTM" ] && "$PY3" -c 'import importlib.util' 2>/dev/null; then
  GFALL=0
  GS_LOG=""
  GRANITE_HOME=""
  GS_STATE=""   # granite_spawn_state monkeypatched into the hook; records the verdict
  GS_ARGS=""    # argv captured by the stub Popen: empty == no worker ever forked
  GS_CTR=""     # same dir as GS_ARGS, one file per spawn attempt (the counter)

  # gs_reset: fresh isolated RSRS_DATA_DIR + clean counters. No marker is pre-seeded here
  # (gs_seed_* do that per idempotence case), so the decision starts on the no-marker path.
  gs_reset() {
    GS_HOME="$TMP/granite-home-$RANDOM$RANDOM"
    mkdir -p "$GS_HOME"
    : > "$GS_HOME/hook.log"
    # derive the spawn-record paths FIRST, then clear every marker and record of this
    # fresh home: an uninitialised first gs_reset used to rm nothing (GS_ARGS empty) and
    # let the previous case's state file leak into this one.
    GS_STATE="$GS_HOME/spawn-state.txt"
    GS_ARGS="$GS_HOME/spawn-argv.txt"
    GS_CTR="$GS_HOME/spawn-count.txt"
    rm -f "$GS_HOME"/granite-setup.done "$GS_HOME"/granite-setup.lock \
          "$GS_HOME"/granite-setup.failed "$GS_HOME"/granite-setup.log \
          "$GS_STATE" "$GS_ARGS" "$GS_CTR"
  }

  # gs_seed_done / gs_seed_lock <pid> / gs_seed_failed: pre-place a terminal marker so the
  # idempotence cases can assert "no second spawn".
  gs_seed_done()   { printf 'seeded' > "$GS_HOME/granite-setup.done"; }
  gs_seed_failed() { printf 'seeded' > "$GS_HOME/granite-setup.failed"; }
  gs_seed_lock()   { printf '%s' "$1" > "$GS_HOME/granite-setup.lock"; }
  gs_state() { cat "$GS_STATE" 2>/dev/null || echo missing; }

  # gs_run <model-verdict> [extra-env ...]: one SessionStart through the real hook with the
  # granite spawn intercepted: granite_spawn_state is monkeypatched to record the verdict
  # and return "no_engine" (so nothing forks), and subprocess.Popen is patched so only the
  # --granite-setup fork is stubbed to record its argv (real engine calls stay real).
  # Output lands in GS_OUT; whether the fork happened is NOT inferred from GS_OUT -- under
  # the stub fork Popen raises PopenBlocked before the record is flushed, so spawn evidence
  # always comes from GS_ARGS/GS_CTR, and the note assertions come from GS_OUT.
  gs_run() {
    local mver="$1"; shift
    GS_OUT="$(ROOT_HOOK="$ROOTM" RSRS_DATA_DIR="$GS_HOME" RESPITE_LOG="$GS_HOME/hook.log" \
      RESPITE_CONFIG="$CFG_STUB" STUB_MODEL="$mver" STUB_MODE=ok \
      STUB_ARGS="$GS_ARGS" STUB_CTR="$GS_CTR" STUB_STATE="$GS_STATE" \
      RESPITE_TEST_FAST=1 "$@" "$PY3" - <<'PY'
import io, os, sys, importlib.util, subprocess
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
real_state, real_popen = m.granite_spawn_state, subprocess.Popen
class PopenBlocked(Exception):
    """Abort right after the stubbed fork: the granite path stays fail-open (SystemExit
    would also abort main and skip the rules record, masking the verdict)."""
def spy_state(cfg):
    v = real_state(cfg)
    with open(os.environ["STUB_STATE"], "w", encoding="utf-8") as f:
        f.write(v)
    return "no_engine"          # test backdoor: record the verdict, never fork the worker
def spy_popen(*a, **k):
    argv = a[0] if a else []
    if not any(str(x) == "--granite-setup" for x in argv):
        return real_popen(*a, **k)     # only the granite fork is stubbed
    with open(os.environ["STUB_CTR"], "a", encoding="utf-8") as f:
        f.write("spawn\n")
    with open(os.environ["STUB_ARGS"], "w", encoding="utf-8") as f:
        f.write(" ".join(map(str, argv)))
    raise PopenBlocked         # sentinel: abort the hook before the record is flushed
m.granite_spawn_state, subprocess.Popen = spy_state, spy_popen
sys.argv = ["respire.py", "SessionStart"]
sys.stdin = io.StringIO('{"hook_event_name":"SessionStart"}')
try:
    m.main()
except SystemExit:
    pass
except PopenBlocked:
    pass
PY
)"
  }

  # gs_spawn: spawn evidence. Under RESPITE_TEST_FAST=1 the real worker must NOT fork (that
  # would be a 300MB download), so the hook's own guard returns "no_engine" first and no
  # fork happens -- gs_state is the "no marker + not running" decision (see gs_reset docs),
  # while gs_spawned/gs_count record whether a --granite-setup process was ever attempted.
  gs_spawned() { [ -s "$GS_ARGS" ] && grep -q -- "--granite-setup" "$GS_ARGS" && echo YES || echo NO; }
  gs_count() { [ -f "$GS_CTR" ] && wc -l < "$GS_CTR" | tr -d '[:space:]' || echo 0; }
  gs_mark_log() { [ -f "$GS_HOME/granite-setup.log" ] && echo YES || echo NO; }
  # Every case runs under RESPITE_TEST_FAST=1 + an empty RSRS_DATA_DIR: under the test
  # fast-path the worker can only fail fast (no model files present), so it must never
  # download: no model file may appear anywhere in the isolated home.
  gs_no_download() {
    if find "$GS_HOME" -type f \( -name '*.onnx' -o -name 'tokenizer.json' -o -name '*.part' \) 2>/dev/null | grep -q .; then
      echo LEAK
    else echo CLEAN; fi
  }

  # ---- G1: no present model -> RULES_NO_MODEL (granite-setup.log mentioned) + spawn decision ----
  gs_reset
  gs_run "missing"              # STUB_MODEL=missing -> no variant present -> model_status False
  OUT_GRAN="$GS_OUT"
  check "granite: no-model session keeps the rules" "$OUT_GRAN" "has:respire memory discipline"
  check "granite: no-model session announces the background setup" "$OUT_GRAN" "has:granite-setup.log"
  check "granite: no-model session names the 300MB default model" "$OUT_GRAN" "has:granite-311m"
  # No marker + no live lock -> the decision is "no_engine" under RESPITE_TEST_FAST=1
  # (respire.py:1079: the fast-path guard returns before the real fork, so no 300MB
  # download can start from a test). The .done/.failed/.live-lock verdicts are covered
  # by G4/G5/G8 below; "start" without the guard is not reachable from this suite.
  check "granite: no-marker session reaches the spawn decision" "$(cat "$GS_STATE" 2>/dev/null || echo missing)" "has:no_engine"
  check "granite: no-model session never actually forks under RESPITE_TEST_FAST" "$(gs_spawned)" "has:NO"
  check "granite: no-model session creates no setup log without a fork" "$(gs_mark_log)" "has:NO"

  # ---- G2: a present model -> no note, no spawn ----
  gs_reset
  gs_run "present"
  check "granite: present model session never mentions the setup log" "$GS_OUT" "hasnt:granite-setup.log"
  check "granite: present model session keeps the rules" "$GS_OUT" "has:respire memory discipline"
  check "granite: present model session never reaches the spawn branch" "$(cat "$GS_STATE" 2>/dev/null || echo missing)" "hasnt:start"
  check "granite: present model session forks no worker" "$(gs_spawned)" "has:NO"
  check "granite: present model session creates no setup log" "$(gs_mark_log)" "has:NO"

  # ---- G3: model_status None (malformed envelope, fail-open) -> no granite at all ----
  gs_reset
  gs_run "error"
  check "granite: model-status failure never mentions the setup log" "$GS_OUT" "hasnt:granite-setup.log"
  check "granite: model-status failure never reaches the spawn branch" "$(cat "$GS_STATE" 2>/dev/null || echo missing)" "hasnt:start"
  check "granite: model-status failure forks no worker" "$(gs_spawned)" "has:NO"

  # ---- G4: .done marker -> terminal, no respawn ----
  gs_reset; gs_seed_done
  gs_run "missing"
  check "granite: a .done marker keeps the note truthful" "$GS_OUT" "has:granite-setup.log"
  check "granite: a .done marker is terminal (state=done)" "$(cat "$GS_STATE" 2>/dev/null || echo missing)" "has:done"
  check "granite: a .done marker never respawns the worker" "$(gs_spawned)" "has:NO"

  # ---- G5: a live lock (worker pid alive) -> already running, no second spawn ----
  gs_reset
  if gs_seed_lock "$$"; then
    gs_run "missing"
    check "granite: a live lock is reported as running" "$(cat "$GS_STATE" 2>/dev/null || echo missing)" "has:running"
    check "granite: a live lock never respawns the worker" "$(gs_spawned)" "has:NO"
  else
    echo "FAIL  granite: could not seed the live-lock marker (cannot verify the running case)"
    GFALL=1
  fi

  # ---- G6: a dead/stale lock must NOT stop a retry (stale != terminal) ----
  # A dead pid in the lock is treated as stale: the decision is the plain no-marker path
  # ("no_engine" under the fast-path guard), never done/failed/running.
  gs_reset; gs_seed_lock 999999
  gs_run "missing"
  check "granite: a stale lock is not terminal (decision still the no-marker path)" "$(cat "$GS_STATE" 2>/dev/null || echo missing)" "has:no_engine"
  check "granite: a stale lock never blocks under the fast-path guard" "$(gs_spawned)" "has:NO"

  # ---- G7: worker download-failure branch -- isolated RSRS_DATA_DIR, no download ----
  # The fetches cannot resolve the pinned 300MB files, so every mirror fails fast and
  # granite_setup_main must write .failed, remove the lock and log the reason without
  # raising. RSRS_DATA_DIR isolates all granite state; nothing touches the real ~/.rsrs.
  # Task-43: a CLI-less machine now takes the DEFER branch instead of failing, so this
  # failure-branch driver injects the engine (find_rsrs -> stub path) and stubs urlopen to
  # die at once: the download must fail exactly as before, independently of the DEFER path.
  gfail_noengine_dl() {
    local home="$TMP/granite-fail-$RANDOM$RANDOM"
    mkdir -p "$home"
    RSRS_DATA_DIR="$home" RESPITE_LOG="$home/hook.log" "$PY3" - <<'PY'
import io, os, sys, importlib.util, urllib.request
from urllib.error import URLError
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.find_rsrs = lambda cfg: "/stub/rsrs"     # engine present: the failure branch, not DEFER
def dead_urlopen(url, timeout=None):
    raise URLError("mirror down (test stub)")
urllib.request.urlopen = dead_urlopen      # module-level (respire resolves it from globals)
m.urllib.request.urlopen = dead_urlopen
home = m._granite_home()
# the worker clears the lock on success and on failure; seed one so the removal is observable
open(os.path.join(home, "granite-setup.lock"), "w").write(str(os.getpid()))
with open(os.path.join(home, "granite-setup.log"), "w", encoding="utf-8"):
    pass
out = io.StringIO()
sys.stdout = out
try:
    rc = m.granite_setup_main()
finally:
    sys.stdout = sys.__stdout__
print("RC=%s FAILED=%s LOCK=%s" % (
    rc, os.path.exists(os.path.join(home, "granite-setup.failed")),
    os.path.exists(os.path.join(home, "granite-setup.lock"))))
print(out.getvalue().strip())
PY
  }
  # The worker's own capture handle is redirected by the hook at spawn time; here we are
  # driving granite_setup_main directly, so the printed trail becomes stdout of gfail.
  # The engine is explicitly absent (the DEFER branch owns a CLI-less machine) and the
  # download mirror is stubbed to die at once: the failure contract below is the download
  # branch, while the DEFER contract has its own isolated check (E4).
  GF_OUT="$(ROOT_HOOK="$ROOTM" gfail_noengine_dl)"
  GF_HOME=""
  # locate the isolated granite home this run just used (one dir; no markers were pre-seeded)
  for _d in "$TMP"/granite-fail-*; do
    [ -d "$_d" ] || continue
    GF_HOME="$_d"   # newest run last; overwrite until the failed marker shows up
    if [ -f "$_d/granite-setup.failed" ]; then GF_HOME="$_d"; break; fi
  done
  case "$GF_OUT" in
    *"RC=1 FAILED=True LOCK=False"*) ;;
    *) GFALL=1 ;;
  esac
  check "granite: download failure writes the .failed marker and clears the lock" "$GF_OUT" "has:RC=1 FAILED=True LOCK=False"
  check "granite: download failure keeps the reason in the setup log" "$GF_OUT" "has:[granite-setup] FAILED:"
  check "granite: download failure leaves no half-published model file" \
    "$( [ -n "$GF_HOME" ] && find "$GF_HOME/models" -type f 2>/dev/null | grep -q . && echo LEFTOVER || echo CLEAN )" "has:CLEAN"
  check "granite: no model file was ever downloaded in the failing run" \
    "$( [ -n "$GF_HOME" ] && find "$GF_HOME" -type f \( -name '*.onnx' -o -name 'tokenizer.json' -o -name '*.part' \) 2>/dev/null | grep -q . && echo LEAK || echo CLEAN )" "has:CLEAN"

  # ---- G8: .failed marker -> terminal, never respawned ----
  gs_reset; gs_seed_failed
  gs_run "missing"
  check "granite: a .failed marker is terminal (state=failed)" "$(cat "$GS_STATE" 2>/dev/null || echo missing)" "has:failed"
  check "granite: a .failed marker never respawns the worker" "$(gs_spawned)" "has:NO"
  check "granite: a .failed marker creates no new setup log" "$(gs_mark_log)" "has:NO"

  check "granite: session hook never downloaded any model file" "$(gs_no_download)" "has:CLEAN"
  [ "$GFALL" = 0 ] || { FAIL=$((FAIL+1)); echo "FAIL  granite: worker failure branch (marker/log contract)"; }

  # ---- G9: the download really goes through urllib (regression: an invented `rsrs fetch`
  # ---- subcommand made every real setup fail; this must FAIL if the worker shells out ----)
  # urlopen is monkeypatched to stream the pinned SIZE for each file (random bytes: the
  # worker's real sha256 check then rejects them on purpose, so no 300MB download can ever
  # complete here), run_rsrs records every engine argv, and the outcome line proves which
  # path the download took: URLS>=2 + FETCH=False + no "unrecognized subcommand".
  # If respire.py ever goes back to `rsrs fetch`, FETCH flips to True and this FAILs.
  gsuccess() {
    local home="$TMP/granite-ok-$RANDOM$RANDOM"
    mkdir -p "$home"
    ROOT_HOOK="$ROOTM" RSRS_DATA_DIR="$home" RESPITE_LOG="$home/hook.log" "$PY3" - <<'PY'
import hashlib, io, os, sys, importlib, importlib.util, subprocess, types, urllib.request
from urllib.error import URLError
spec = importlib.util.spec_from_file_location("respire", os.path.join(os.environ["ROOT_HOOK"], "hooks", "respire.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
calls, argvs = [], []
# Serve the pinned SIZE for whatever file the URL asks for (bytes stay random: the real
# sha256 comparison must fail, which keeps the test offline and download-proof).
class FakeResp:
    def __init__(self, payload, url):
        self._it = iter([payload]); self.url = url
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def read(self, n=-1):
        return next(self._it, b"")
def fake_urlopen(url, timeout=None):
    calls.append(url)
    for rel, size, sha in m.GRANITE_FILES:
        if url.endswith("/" + rel):
            # FIRST mirror serves the right size; later mirrors die at once so the
            # fallback chain terminates after exactly one urlopen per file (URLS=2).
            if "hf-mirror.com/" in url:
                return FakeResp(os.urandom(size), url)
            raise URLError("mirror down (test stub)")
    raise AssertionError("unexpected url: %r" % (url,))
urllib.request.urlopen = fake_urlopen
# module-level lookups inside respire.py resolve against its globals: patch there
m.urllib.request.urlopen = fake_urlopen
class FakeCompleted:
    returncode = 0
    stdout = '{"status": "ok"}'
    stderr = ""
def fake_run_rsrs(bin_path, args, timeout):
    argvs.append([bin_path] + list(args))
    return FakeCompleted()
m.run_rsrs = fake_run_rsrs
# The worker must see a CLI present or it DEFERRs ("engine-setup owns it") before any
# download. A CI runner has no rsrs, so inject one; run_rsrs is stubbed above, so the fake
# binary is never executed. This keeps the download path deterministic on every host.
m.find_rsrs = lambda cfg: "rsrs-stub"
p = m._granite_paths()
os.makedirs(p["home"], exist_ok=True)
open(p["lock"], "w").write(str(os.getpid()))
with open(p["log"], "w", encoding="utf-8"):
    pass
out = io.StringIO()
sys.stdout = out
try:
    rc = m.granite_setup_main()
finally:
    sys.stdout = sys.__stdout__
fetch_argv = any("fetch" in a for argv in argvs for a in argv)
# urlopen calls in call order: first mirror per file, then the fallback mirrors. A urllib
# worker always starts with the first mirror and reaches >=2 calls (one per file when the
# first mirror answers, or mirror-chain when it dies); a `rsrs fetch` worker records 0.
first_ok = bool(calls) and "hf-mirror.com/" in calls[0]
print("RC=%s URLS=%d FETCH=%s DONE=%s FAILED=%s FIRST=%s" % (
    rc, len(calls), fetch_argv, os.path.exists(p["done"]), os.path.exists(p["failed"]),
    first_ok))
print("RUNS=%d" % len(argvs))
print(out.getvalue().strip())
PY
  }
  GS_OK_OUT="$(ROOT_HOOK="$ROOTM" gsuccess)"
  # FIRST=True + URLS>=2: the first mirror answers and every later mirror dies at once, so
  # a urllib worker starts at hf-mirror.com and calls urlopen at least twice before the
  # real sha256 check fails closed; a `rsrs fetch` worker calls urlopen zero times
  # (FIRST=False, URLS=0) -> this FAILs.
  case "$GS_OK_OUT" in
    "RC=1 URLS="*[2-9]*" FETCH=False DONE=False FAILED=True FIRST=True"*) ;;
    *) GFALL=1 ;;
  esac
  check "granite: download goes through urllib (first mirror answered, >=2 urlopen calls)" "$GS_OK_OUT" "has:URLS=3 FETCH=False"
  check "granite: no argv ever carried an rsrs fetch subcommand" "$GS_OK_OUT" "has:FETCH=False"
  check "granite: the urllib path never reaches a CLI fetch error" "$GS_OK_OUT" "hasnt:unrecognized subcommand"
  check "granite: sha-mismatched random bytes fail closed (.failed, no .done)" "$GS_OK_OUT" "has:RC=1 URLS=3 FETCH=False DONE=False FAILED=True FIRST=True"
  [ "$GFALL" = 0 ] || { FAIL=$((FAIL+1)); echo "FAIL  granite: urllib download path (G9 regression guard)"; }
else
  echo "SKIP  granite auto-setup group (importlib unavailable on this interpreter)"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
