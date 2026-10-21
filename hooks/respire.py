#!/usr/bin/env python3
# respire —— respire(rsrs) × Qoder 记忆插件（hook 端单入口）
# 与 Dim 版 respire-dimcode 同一思路：SessionStart 注简则、UserPromptSubmit 每轮召回、Stop 存储检查。
# 用法: python3 respire.py <SessionStart|UserPromptSubmit|Stop>   （事件 JSON 走 stdin）
# 铁律: fail-open —— 任何异常 → 空 stdout、exit 0（协议里即「无决策、放行」），绝不 exit 2。
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time

VERSION = "0.6.2"

# 超时窗（秒）：须盖住 rsrs runtime 冷启动（实测 doctor 模型加载 7s+），否则首轮静默、热后即灵
RECALL_T = 14
PROBE_T = 10
STORE_T = 18
LOG_MAX = 256 * 1024  # hook.log 超此整文件清轮

DEFAULTS = {
    "rsrs": "",                 # respire 引擎（rsrs）路径；空 = 自动探测
    "recall_threshold": 0.0,    # 召回下限，0=默认关（rsrs 直出）：skip 门管无关、limit 限流、标题档廉价；设正数才启用过滤
    "recall_limit": 5,          # 取前 N 条
    "min_prompt_chars": 2,      # 过短不检索（1 字才跳；2 字起即查，rsrs 自带 skip 门、本地 100–400ms）
    "session_rules": True,      # SessionStart 是否注入用法简则
    "budget_chars": 1500,       # 单轮注入总字数预算
    "log": True,                # hook.log 轻量留痕（每事件一行，复盘时灵时不灵的抓手）
    "enabled": True,           # 总开关：false=记忆层全线静默（Dim 插件页亦可逐组件关 hook）
    "store_nudge_every": 1,     # Stop 存储检查节流：1=每轮、N=每 N 轮一次、0=关闭（每轮=多一轮模型小调用）
    "skip_prefixes": [          # 命中这些前缀的 prompt 视为宿主内部提示，不召回也不落库（Qoder 等会给自动化任务写 Recap）
        "你正在为 Qoder 任务监控编写简短的会话 Recap",
        "你正在为 Qoder",
        "You are writing a brief session recap for Qoder",
        "You are writing a short session recap for Qoder",
    ],
}

# 显式落库前缀：prompt 以「记：」等开头 → 直接入库并回执
STORE_PREFIX = re.compile(r"^(?:记|存|记录|记住|remember|store)\s*[:：]\s*", re.I)
# 本轮跳过召回
SKIP_PREFIX = re.compile(r"^(?:/nomem|#nomem)\b")
# Dim 技能指认前缀：$skill: 名称 后才是真任务——技能名会词面污染召回 query，须剥掉
SKILL_PREFIX = re.compile(r"^\$\s*skill\s*:\s*\S+\s*", re.I)

RULES = """【respire memory layer · attached】This session is backed by the local respire (rsrs) memory store; data is encrypted locally and synced to the cloud (account registration and login are outside this layer, see rsrs.rs).
1. Recall before answering: rsrs recall "project name + keywords" (--json for structured output, --titles for id+title only); on errors or anomalies, recall using the original error text first.
2. Store when wrapping up: rsrs remember "content" --title "fact sentence" --importance important (judge first, store immediately: similar items return candidates, decide before sending). **title is the facade for recall and dedup — extract a complete fact sentence of "subject + action + result" from the content; never use a topic label, never truncate mid-phrase**; when the prompt starts with "记：" this layer stores it first as a fallback — if the receipt includes a provisional title and short id, **extract a more precise fact sentence and replace it with rsrs retitle <short-id> --title**.
3. Automatic recall is injected with each prompt; **if no recall was injected, the hits are off-topic, or the topic involves an earlier project, error, agreement, or date, recall again with different wording before answering (try synonyms, hypernyms, and English equivalents, one route each), and call it visibly**; do not repeat only when the injected hits are truly relevant. Prefix /nomem to disable automatic recall for this turn.
4. Never put passwords, ID numbers, phone numbers, card numbers, or private keys into memory bodies or query terms — record only where they are stored. The library is encrypted, but a leaked key exposes everything.
5. Sync with rsrs sync (autosync is on), check state with rsrs status, read the full workflow with rsrs prompt; see the respire skill for advanced usage."""

NO_RSRS = """【respire · engine missing】The plugin is ready; only the engine is missing. Install it now on the user's behalf, without waiting:
  npm i -g @rsrsai/cli@latest
(If global writes are denied, first try: npm config set prefix ~/.npm-global && npm i -g @rsrsai/cli@latest)
Then run rsrs --version to confirm — this layer probes every turn and resumes recall and "记：" storage within the same session.
Next steps to guide (mention them in passing): rsrs status checks login state; if signed out, ask the user to register at https://rsrs.rs, then run rsrs register --user <name> on this machine (the user sets a login password of at least 8 characters; **never invent a super password and never pass --super** — the system generates an A3-… recovery code and prints it prominently; **copy and keep it**, or the memory cannot be unlocked on any device); use rsrs login for routine login; the semantic model is optional — for better recall run rsrs model install && rsrs model activate m3. If a custom super password was entered by mistake, run rsrs super-reset to reissue an A3 code."""

LOGIN_NUDGE = """Note: respire is not signed in on this machine — memory stays local, does not sync, and does not cross devices. Guide the user: register at rsrs.rs, then run rsrs register (the user sets the login password; **the super password is a system-generated A3-… recovery code — never invent one, and keep it safe**); for routine login you may run rsrs login --oauth --no-open and give the authorization link to the user."""

EMPTY_NUDGE = """Note: the local respire memory store is empty — there is nothing to recall; silent automatic recall is expected, not a failure. Guide the user: store a fact with "记：<fact>", or have the agent first rsrs remember existing project agreements, error lessons, and key conclusions; existing rules and memory can be imported in one pass — have the agent read ~/AGENTS.md, project AGENTS.md files, ~/.dimcode/v2/skills/*/SKILL.md and hooks.json, extract facts, and store them one by one (excluding passwords, ID numbers, card numbers). Recall has content only after the store is populated."""

NO_MODEL = """Note: the respire semantic model (BGE-M3) is not installed — the lexical tier is active. **Fully usable**: registration, login, sync, and recall do not depend on the model. For better results install it: rsrs model install downloads about 1.1GB, then rsrs model activate m3 builds the index and switches recall to the semantic tier (you may run these; indexing can run in the background)."""

PROBE_FAIL = """Note: respire status probe failed (rsrs status did not respond) — if this is a new machine that has never registered, guide the user to register at rsrs.rs and run rsrs register (first device); otherwise the runtime may still be cold-starting, so an empty first recall may resolve after a moment. If it persists, run rsrs doctor, diagnose, and report to the user."""


_REDACT = [
    (re.compile(r"(?i)(password|passwd|pwd|密码|口令)\s*[:=：]\s*\S+"), r"\1=[REDACTED]"),
    (re.compile(r"\b(sk|ghp|gho|github_pat|AKIA|xox)[A-Za-z0-9_-]{8,}\b"), "[REDACTED]"),
    (re.compile(r"\b\d{11,19}\b"), "[NUM]"),
]


def redact(s: str) -> str:
    """日志脱敏：口令式赋值、token 前缀、11-19 位长数字（手机/卡号）。
    日志只用于诊断，绝不落明文凭据。"""
    try:
        for pat, rep in _REDACT:
            s = pat.sub(rep, s)
    except Exception:
        pass
    return s


def data_dir() -> str:
    """Qoder 分配的插件数据目录；本地开发未设时回退到脚本目录。"""
    d = os.environ.get("QODER_PLUGIN_DATA", "")
    if d:
        try:
            os.makedirs(d, exist_ok=True)
            return d
        except Exception:
            pass
    return os.path.dirname(os.path.abspath(__file__))


def log_event(cfg: dict, event: str, outcome: str, detail: str = "", ms=None):
    """轻量留痕：hook.log 单行 JSONL、超 256KB 整文件清轮；日志失败绝不影响主链。
    config log:false 关闭。字段：ts/ev/out/ms（耗时毫秒）/d（摘要）。"""
    if not cfg.get("log", True):
        return
    try:
        path = os.environ.get("RESPITE_LOG") or os.path.join(data_dir(), "hook.log")
        try:
            if os.path.exists(path) and os.path.getsize(path) > LOG_MAX:
                os.remove(path)
        except Exception:
            pass
        rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "ev": event, "out": outcome}
        if ms is not None:
            rec["ms"] = int(ms)
        if detail:
            rec["d"] = redact(detail)[:160]
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass


def _typed(val, ref) -> bool:
    if isinstance(ref, bool):
        return isinstance(val, bool)
    if isinstance(ref, (int, float)):
        return isinstance(val, (int, float)) and not isinstance(val, bool)
    return isinstance(val, type(ref))


def load_config() -> dict:
    cfg = dict(DEFAULTS)
    candidates = [os.environ.get("RESPITE_CONFIG") or "",
                  os.path.join(data_dir(), "respire.config.json"),
                  os.path.join(os.path.dirname(os.path.abspath(__file__)), "respire.config.json")]
    for path in candidates:
        if not path:
            continue
        try:
            with open(path, encoding="utf-8") as f:
                doc = json.load(f)
            if isinstance(doc, dict):
                for key, ref in DEFAULTS.items():
                    if key in doc and _typed(doc[key], ref):
                        cfg[key] = doc[key]
            break
        except Exception:
            continue  # 配置缺失/损坏 → 用默认值，绝不拦
    return cfg


def find_rsrs(cfg: dict):
    home = os.path.expanduser("~")
    cands = [cfg.get("rsrs") or "", os.environ.get("RESPITE_RSRS") or "",
             os.environ.get("RESPIRE_BIN") or "",
             shutil.which("respire") or "",
             shutil.which("rsrs") or "",
             f"{home}/.local/bin/respire", f"{home}/.local/bin/rsrs",
             f"{home}/.rsrs/bin/rsrs", "/usr/bin/respire", "/usr/bin/rsrs"]
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def run_rsrs(bin_path: str, args: list, timeout: int):
    # rsrs 的 --json 模式下进度写 stderr，capture 须分离，只解析 stdout
    return subprocess.run([bin_path] + args, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=timeout)


def extract_title(content: str) -> str:
    """无 LLM 下尽量抽完整事实句：整句优先 → 退到分隔符 → 绝不在词中硬截（上限 70 字）。
    引擎不代抽题（retitle --title 必填），抽毕由回执引导 agent 用 retitle 精修。"""
    s = re.sub(r"\s+", " ", content.strip())
    if not s:
        return ""
    m = re.match(r"^(.{6,}?[。！？!?])", s)          # 第一个 ≥6 字的完整句
    if m:
        return m.group(1)[:70].strip()
    head = s[:70]
    cuts = [head.rfind(c) for c in "，；、,;"]        # 退到分隔符，不切半词
    cut = max(cuts)
    if cut >= 20:
        return head[:cut + 1].rstrip("，,；; ").strip()
    return head                                       # 无标点长串才落到 70 字上界


def do_store(bin_path: str, content: str, cfg: dict) -> str:
    """显式落库：判后即存三态——ok 直写 / pending 给候选待决 / 其余为失败，皆回执不静默。"""
    if not content:
        log_event(cfg, "store", "empty_content")
        return ""
    title = extract_title(content) or "respire quick store"
    t0 = time.time()
    try:
        r = run_rsrs(bin_path, ["remember", content, "--title", title,
                                "--importance", "important", "--json"], STORE_T)
    except Exception as e:
        log_event(cfg, "store", "timeout_or_error", f"{type(e).__name__}: {e}", (time.time() - t0) * 1000)
        return "【respire · store】respire timed out; run rsrs remember manually to verify whether it was written."
    ms = (time.time() - t0) * 1000
    try:
        doc = json.loads(r.stdout) if r.stdout else {}
    except Exception:
        doc = {}
    if not isinstance(doc, dict):
        doc = {}
    status = str(doc.get("status") or "")
    if status == "ok":
        sid = str((doc.get("summary") or {}).get("id") or "")
        log_event(cfg, "store", "ok", sid[:8], ms)
        tail = f" ({sid[:8]})" if sid else ""
        return (f"【respire · stored】Saved: {title}{tail}. The title is a rule-based provisional one — "
                "extract a complete \"subject + action + result\" fact sentence from the content and "
                f"replace it with rsrs retitle {sid[:8]} --title (title is the facade for recall and dedup).")
    if status == "pending":
        # 判后即存判定疑似重复/可挂靠，未写入（written:false）——转述候选，模型接续决断
        log_event(cfg, "store", "pending", f"cand={len(doc.get('items') or [])}", ms)
        lines = ["【respire · store pending】respire judged this item similar to existing memory; nothing was written. Candidates:"]
        for it in (doc.get("items") or [])[:5]:
            if isinstance(it, dict):
                lines.append(f"- [{it.get('name', '?')}] {it.get('value', '')}")
        lines.append("Decide: to attach, rerun rsrs remember with the same text --parent <id>; if it is genuinely independent, add --force to write it directly.")
        return "\n".join(lines)
    errs = doc.get("errors") or []
    msg = json.dumps(errs, ensure_ascii=False)[:200] if errs else f"status={status or r.returncode}"
    log_event(cfg, "store", "fail", msg, ms)
    return f"【respire · store failed】respire did not accept it: {msg}"


def do_recall(bin_path: str, prompt: str, cfg: dict) -> str:
    """每轮召回：--titles 标题档（respire 设计——只注分数＋短 id＋标题，正文由 agent rsrs show <id> 按需取）。
    rsrs 自带相关性门（无关→skip 零命中），本层再按阈值滤掉碰瓷命中。"""
    t0 = time.time()
    try:
        r = run_rsrs(bin_path, ["recall", prompt, "--limit",
                                str(int(cfg["recall_limit"])), "--titles", "--json"], RECALL_T)
    except Exception as e:
        log_event(cfg, "recall", "timeout_or_error", f"{type(e).__name__}", (time.time() - t0) * 1000)
        return ""
    ms = (time.time() - t0) * 1000
    if r.returncode != 0:
        log_event(cfg, "recall", "rc_nonzero", f"rc={r.returncode} {r.stderr[:80] if r.stderr else ''}", ms)
        return ""
    try:
        doc = json.loads(r.stdout)
    except Exception:
        log_event(cfg, "recall", "parse_error", (r.stdout or "")[:80], ms)
        return ""
    if not isinstance(doc, dict) or doc.get("status") not in ("ok", "skip"):
        log_event(cfg, "recall", "status_fail", str(doc.get("status") if isinstance(doc, dict) else "?"), ms)
        return ""  # fail 静默（fail-open）；skip = 自带门判为无关
    details = doc.get("details") or []
    if not isinstance(details, list):
        log_event(cfg, "recall", "bad_details", "", ms)
        return ""
    thr = float(cfg["recall_threshold"])   # 0=直出不过滤；噪音边界交给 rsrs 自带 skip 门＋limit＋标题档
    keep = []
    max_score = 0.0
    for d in details:
        if not isinstance(d, dict):
            continue
        score = d.get("score")
        if isinstance(score, (int, float)):
            max_score = max(max_score, float(score))
        if isinstance(score, (int, float)) and float(score) >= thr:
            keep.append((float(score), d))
        if len(keep) >= int(cfg["recall_limit"]):
            break
    if not keep:
        log_event(cfg, "recall",
                  "skip" if doc.get("status") == "skip" else "below_thr",
                  f"max={max_score:.3f} thr={thr:g} q={prompt[:40]}", ms)
        return ""
    budget = int(cfg["budget_chars"])
    lines, used = [], 90  # 90 留给头行上界，砍点据此提前
    for score, d in keep:
        title = str(d.get("title") or "").strip() or "(untitled)"
        eid = str(d.get("id") or "")[:8]
        stale = " →superseded" if d.get("superseded_by") else ""
        line = f"- [{score:.2f}] {title}（{eid}）{stale}"
        if lines and used + len(line) + 1 > budget:
            break
        lines.append(line)
        used += len(line) + 1
    if not lines:
        log_event(cfg, "recall", "budget_empty", "", ms)
        return ""
    gate = f"threshold {thr:g}, " if thr > 0 else "rsrs direct, "
    head = (f"【respire · auto-recall】matched {len(lines)} item(s) ({gate}title tier; "
            "read bodies on demand with rsrs show <short-id>; scores are relevance, not confidence):")
    log_event(cfg, "recall", "hit", f"n={len(lines)} max={max_score:.3f} q={prompt[:40]}", ms)
    return "\n".join([head] + lines)


def probe_status(bin_path: str):
    """SessionStart 一次 status 三态共用（登录态＋库量＋探测成败；开销实测热态约 190ms）。
    返回 (logged, total, probe_ok)：logged True/False/None；total int/None；
    probe_ok False=status 未回（冷启动/异常），注入 PROBE_FAIL 段。
    后门：RESPITE_FAKE_LOGGED_OUT=1 / RESPITE_FAKE_EMPTY=1 / RESPITE_FAKE_PROBE_FAIL=1。"""
    fake_out = os.environ.get("RESPITE_FAKE_LOGGED_OUT") == "1"
    fake_empty = os.environ.get("RESPITE_FAKE_EMPTY") == "1"
    if os.environ.get("RESPITE_FAKE_PROBE_FAIL") == "1":
        log_event(DEFAULTS, "probe", "fake_fail")
        return (None, None, False)
    t0 = time.time()
    try:
        r = run_rsrs(bin_path, ["status", "--json"], PROBE_T)
        doc = json.loads(r.stdout) if r.stdout else {}
        if not isinstance(doc, dict) or doc.get("status") != "ok":
            log_event(DEFAULTS, "probe", "status_not_ok",
                      str(doc.get("status") if isinstance(doc, dict) else "?"),
                      (time.time() - t0) * 1000)
            return (None, None, False)
        summ = doc.get("summary") or {}
        sess = summ.get("session") or {}
        logged = bool(sess.get("has_token")) and bool(sess.get("user"))
        total = summ.get("local_total")
        total = int(total) if isinstance(total, int) else None
    except Exception as e:
        log_event(DEFAULTS, "probe", "error", f"{type(e).__name__}: {e}",
                  (time.time() - t0) * 1000)
        return (None, None, False)
    ms = (time.time() - t0) * 1000
    if fake_out:
        logged = False
    if fake_empty:
        total = 0
    log_event(DEFAULTS, "probe", "ok", f"logged={logged} total={total}", ms)
    return (logged, total, True)


def check_model():
    """语义模型态（SessionStart 专用）：~/.rsrs/models/bge-m3 目录存在即已装（stat 零开销）。
    未装时引擎自带词面回退（源码 indexed==0 → lexical_only），即未配嵌入的引擎效果。
    RESPITE_FAKE_NO_MODEL=1 为自测后门。"""
    if os.environ.get("RESPITE_FAKE_NO_MODEL") == "1":
        return False
    try:
        return os.path.isdir(os.path.expanduser("~/.rsrs/models/bge-m3"))
    except Exception:
        return None  # 探测失败不打扰


STORE_NUDGE = ("Memory check (automatic, once): do only one thing — if this turn produced new **facts, decisions, "
               "agreements, lessons, or pitfalls**, store them one by one with rsrs remember (--importance important; "
               "titles as \"subject + action + result\" fact sentences; on dedup candidates, decide to attach with --parent "
               "or force with --force first); if this turn was just Q&A or chat with no new facts, end directly and do not "
               "repeat the answer. End after storing or when nothing needs storing.")


def on_stop(data: dict, cfg: dict, engine) -> str:
    """Stop 存储检查：干完活的存储提示（block+reason 续跑一轮）。
    规范防循环：续跑轮 stdin 带 stop_hook_active=true → 放行。"""
    if data.get("stop_hook_active") is True:
        log_event(cfg, "stop", "active_skip")
        return ""
    if not engine:
        return ""
    every = int(cfg.get("store_nudge_every", 1))
    if every <= 0:
        return ""
    try:  # 节流计数（失败则不拦）
        state = os.environ.get("RESPITE_NUDGE_STATE") or os.path.join(
            data_dir(), ".nudge_counter")
        n = 0
        try:
            with open(state, encoding="utf-8") as f:
                n = int((f.read() or "0").strip())
        except Exception:
            n = 0
        n += 1
        with open(state, "w", encoding="utf-8") as f:
            f.write(str(n))
        if n % every != 0:
            log_event(cfg, "stop", "every_skip", f"n={n} every={every}")
            return ""
    except Exception:
        pass
    try:  # 近 10 分钟本层已落库过 → 不再催（记忆活跃）
        logp = os.environ.get("RESPITE_LOG") or os.path.join(data_dir(), "hook.log")
        now = time.time()
        if os.path.exists(logp):
            with open(logp, encoding="utf-8", errors="replace") as f:
                for ln in f.readlines()[-50:]:
                    try:
                        r = json.loads(ln)
                    except Exception:
                        continue
                    if r.get("ev") == "store" and r.get("out") == "ok":
                        try:
                            ts = time.mktime(time.strptime(r.get("ts", ""), "%Y-%m-%dT%H:%M:%S"))
                        except Exception:
                            continue
                        if now - ts < 600:
                            log_event(cfg, "stop", "stored_recent_skip")
                            return ""
    except Exception:
        pass
    log_event(cfg, "stop", "nudge")
    # Qoder 的 Stop 支持阻塞：decision=deny 等价 exit 2，把 reason 交回模型续跑一轮。
    return json.dumps({"decision": "deny", "reason": STORE_NUDGE}, ensure_ascii=False)


def on_prompt(data: dict, cfg: dict, engine) -> str:
    prompt = data.get("prompt")
    if not isinstance(prompt, str):
        log_event(cfg, "prompt", "bad_prompt", "非字符串")
        return ""
    prompt = prompt.strip()
    if not prompt or SKIP_PREFIX.match(prompt):
        log_event(cfg, "prompt", "nomem_or_empty", prompt[:40])
        return ""
    for pat in (cfg.get("skip_prefixes") or []):   # 宿主内部提示（如 Qoder Recap）白名单：不召回不落库
        if isinstance(pat, str) and pat and prompt[:len(pat)].lower() == pat.lower():
            log_event(cfg, "prompt", "internal_skip", pat)
            return ""
    m = STORE_PREFIX.match(prompt)
    if m:
        rest = prompt[m.end():].strip()
        if not engine:
            log_event(cfg, "store", "engine_missing", prompt[:40])
            return NO_RSRS
        return do_store(engine, rest, cfg)
    if len(prompt) < int(cfg["min_prompt_chars"]):
        log_event(cfg, "prompt", "too_short", prompt[:40])
        return ""
    if not engine:
        log_event(cfg, "recall", "engine_missing", prompt[:40])
        return ""
    query = SKILL_PREFIX.sub("", prompt).strip() or prompt  # 技能指认轮剥前缀，防技能名污染 query
    return do_recall(engine, query, cfg)


def main() -> None:
    try:
        event = (sys.argv[1] if len(sys.argv) > 1 else "") or os.environ.get("QODER_HOOK_EVENT", "") or os.environ.get("DIM_HOOK_EVENT", "")
        try:
            # 事件 JSON 恒为 UTF-8；Windows 非 UTF-8 区域（如 cp1252）下 read() 会按本地码页误解码
            raw = "" if sys.stdin.isatty() else sys.stdin.buffer.read().decode("utf-8", "replace")
        except Exception:
            try:
                raw = "" if sys.stdin.isatty() else sys.stdin.read()
            except Exception:
                raw = ""
        try:
            data = json.loads(raw) if raw.strip() else {}
        except Exception:
            data = {}
        if not isinstance(data, dict):
            data = {}
        if not event:
            event = str(data.get("hook_event_name") or "")
    except Exception:
        data, event = {}, ""

    try:
        cfg = load_config()
        if not cfg.get("enabled", True):        # 总开关：关闭=全线静默（管理器档）
            log_event(cfg, event or "unknown", "disabled")
            raise SystemExit(0)
        engine = find_rsrs(cfg)
        if event == "SessionStart":
            if not cfg["session_rules"]:
                out = ""
            elif not engine:
                out = NO_RSRS
                log_event(cfg, "session", "engine_missing")
            else:
                out = RULES
                logged, total, probe_ok = probe_status(engine)  # 一次 status：登录＋库量＋成败
                segs = []
                if not probe_ok:
                    out += "\n" + PROBE_FAIL          # 探测失败可见（冷启动/异常）
                    segs.append("probe_fail")
                else:
                    if logged is False:                # 仅未登录才附引导，已登录零打扰
                        out += "\n" + LOGIN_NUDGE
                        segs.append("login")
                    if total is not None and total < 10:   # 仅空库首日才附引导
                        out += "\n" + EMPTY_NUDGE
                        segs.append("empty")
                if check_model() is False:             # 仅缺模型才附装法，已装零打扰
                    out += "\n" + NO_MODEL
                    segs.append("no_model")
                log_event(cfg, "session", "ok", "segs=" + (",".join(segs) or "none"))
        elif event == "UserPromptSubmit":
            out = on_prompt(data, cfg, engine)
        elif event == "Stop":
            out = on_stop(data, cfg, engine)
        else:
            out = ""
    except Exception as e:
        out = ""  # fail-open——但必须留痕，否则「时灵时不灵」无从复盘
        try:
            log_event(DEFAULTS, event or "unknown", "fatal", f"{type(e).__name__}: {e}")
        except Exception:
            pass

    if out:
        try:
            buf = getattr(sys.stdout, "buffer", None)
            if buf is None:
                sys.stdout.write(out)
                sys.stdout.flush()
            else:
                buf.write(out.encode("utf-8"))
                buf.flush()
        except Exception:
            pass
    sys.exit(0)  # 恒 exit 0：纯文本 stdout 即 additionalContext，无文本即无决策


if __name__ == "__main__":
    main()
