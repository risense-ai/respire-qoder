#!/usr/bin/env python3
"""T1-6 A/B and metrics for the respire-qoder memory hook (plan: respire外围工具).

Two modes:

  log   Parse hook.log (one JSON object per line: ts/ev/out/ms/d) into a summary
        table: event counts, recall latency/items, show counts with per-turn
        attribution, due/store/stop outcomes.
  ab    Replay a fixed batch of historical queries at several recall limits
        through the hook's own ``do_recall`` (identical rendering and budget),
        and print a comparison table plus an acceptance verdict. The batch can
        be dumped to a file and reloaded, so the same queries are repeatable.

口径 (metric definitions -- read before citing numbers):

- 注入字符 injected chars: ``len()`` of the exact text ``do_recall`` returns
  (header + item lines), counted in Unicode scalars -- what the model sees.
- items: rendered ``- [score] title（id）`` lines in that text.
- 命中 coverage: reference ids = the same query recalled directly at the
  largest limit (raw CLI output, before the budget trim). coverage@k =
  |rendered ids at k ∩ reference| / |reference|. It measures how much of the
  wide recall the narrow render keeps -- a retrieval-coverage number, not a
  correctness judgement.
- 采纳 adoption: query-log good/bad marks are the model's self-grade of which
  candidates it used. Adoption measures usefulness to the agent; it is NEVER
  evidence that a record is factually true. Reported separately as
  ``good-hit`` with its marked-query count; ``n/a`` when nothing is marked.
- 延迟 latency: wall time of the replayed recall (includes CLI start-up);
  live per-turn latency comes from hook.log ``ms`` fields instead.
- show 次数 (log mode): ``show`` events from PreToolUse. A "turn" is the
  window [this recall event, next recall event); a show inside the window
  counts toward that turn. No PostToolUse hook exists, so show duration is
  not measured -- counts only.

Standard library only; no network, no writes to the memory store (replay is
recall-only). Exit code is always 0: this is a diagnostic, not a gate.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK_PATH = os.path.join(REPO_ROOT, "hooks", "respire.py")

#: ``- [3.49] title（78aab969）`` / optional `` →superseded`` suffix.
_ID_RE = re.compile(r"（([0-9a-fA-F]{8})）")
_ITEM_RE = re.compile(r"^- \[\d")
#: query-log detail value: ``<ts> <query> cand=<ids> adopted=<..> good=<..> bad=<..>``
_QUERY_LOG_RE = re.compile(
    r"^(\S+)\s+(.*?)\s+cand=([^\s]*)\s+adopted=([^\s]*)\s+good=([^\s]*)\s+bad=([^\s]*)$"
)
_FIELD_RE = re.compile(r"\b(n|max|chars|every)=(-?\d+)")


# --------------------------------------------------------------------------- #
# hook.log parsing
# --------------------------------------------------------------------------- #

def load_hook_events(path):
    """Read hook.log JSONL. Returns ``(events, skipped)``; unreadable file -> ([], -1)."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except OSError:
        return [], -1
    events, skipped = [], 0
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except (ValueError, TypeError):
            skipped += 1
            continue
        if isinstance(rec, dict) and isinstance(rec.get("ev"), str):
            events.append(rec)
        else:
            skipped += 1
    return events, skipped


def detail_fields(detail):
    """``n=5 max=5.209`` -> ``{"n": 5, "max": "5.209"}`` (numeric where easy)."""
    out = {}
    for key, raw in _FIELD_RE.findall(str(detail or "")):
        out[key] = int(raw)
    return out


def _ts(event):
    return str(event.get("ts") or "")


def aggregate_log(events):
    """Counts, recall stats, due/store/stop breakdowns and show-per-turn attribution."""
    agg = {
        "by_out": {},
        "recall_hit": [],       # dicts with n/ms/chars/q
        "due_hit": [],
        "store": {},
        "stop": {},
        "shows": [],            # (ts, src)
        "span": (None, None),
    }
    for event in events:
        key = (event.get("ev"), event.get("out"))
        agg["by_out"][key] = agg["by_out"].get(key, 0) + 1
        ev = event.get("ev")
        stamp = _ts(event)
        if agg["span"][0] is None or stamp < agg["span"][0]:
            agg["span"] = (stamp, agg["span"][1])
        if agg["span"][1] is None or stamp > agg["span"][1]:
            agg["span"] = (agg["span"][0], stamp)
        fields = detail_fields(event.get("d"))
        if ev == "recall" and event.get("out") == "hit":
            detail = str(event.get("d") or "")
            at = detail.find(" q=")
            agg["recall_hit"].append({
                "ts": stamp,
                "n": fields.get("n"),
                "chars": fields.get("chars"),
                "ms": event.get("ms"),
                "q": detail[at + 3:].strip() if at >= 0 else "",
            })
        elif ev == "due" and event.get("out") == "hit":
            agg["due_hit"].append({"ts": stamp, "ms": event.get("ms"), "d": event.get("d")})
        elif ev == "store":
            out = str(event.get("out"))
            agg["store"][out] = agg["store"].get(out, 0) + 1
        elif ev == "stop":
            out = str(event.get("out"))
            agg["stop"][out] = agg["stop"].get(out, 0) + 1
        elif ev == "show":
            src = "mcp" if "mcp" in str(event.get("d") or "") else "shell"
            agg["shows"].append((stamp, src))
    agg["turns"] = _turn_windows(events)
    return agg


def _turn_windows(events):
    """Recall-event timestamps as turn starts (for show attribution)."""
    return sorted(_ts(e) for e in events if e.get("ev") == "recall")


def shows_per_turn(agg):
    """Average/max shows per recall-turn window; windows with no recall -> global avg."""
    starts = agg["turns"]
    shows = [ts for ts, _ in agg["shows"]]
    if not starts:
        total = len(shows)
        return {"turns": 0, "shows": total, "avg": None, "max": None}
    counts = [0] * len(starts)
    for stamp in shows:
        # last turn start <= stamp
        index = None
        for i, start in enumerate(starts):
            if start <= stamp:
                index = i
            else:
                break
        if index is not None:
            counts[index] += 1
    return {
        "turns": len(starts),
        "shows": len(shows),
        "avg": round(sum(counts) / len(counts), 2),
        "max": max(counts),
    }


def _pct(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * (len(ordered) - 1)))]


def format_log_report(agg, skipped, path):
    lines = [f"== hook.log summary: {path} =="]
    if agg["span"][0]:
        lines.append(f"span: {agg['span'][0]} .. {agg['span'][1]} (skipped lines: {skipped})")
    lines.append("")
    lines.append("event counts (ev/out):")
    for (ev, out), count in sorted(agg["by_out"].items(), key=lambda kv: (-kv[1], str(kv[0]))):
        lines.append(f"  {ev or '?'}/{out or '?'}: {count}")
    hits = agg["recall_hit"]
    if hits:
        ns = [h["n"] for h in hits if h["n"] is not None]
        mss = [h["ms"] for h in hits if isinstance(h["ms"], (int, float))]
        chars = [h["chars"] for h in hits if h["chars"] is not None]
        lines.append("")
        lines.append(
            "recall hits: n={} items avg={} ms avg={} p95={}".format(
                len(hits),
                round(sum(ns) / len(ns), 2) if ns else "?",
                round(sum(mss) / len(mss)) if mss else "?",
                _pct(mss, 0.95) if mss else "?",
            )
        )
        if chars:
            lines.append(
                f"injected chars avg={round(sum(chars) / len(chars))} max={max(chars)} "
                "(chars= field present)"
            )
        else:
            lines.append("injected chars: n/a (log written before chars= existed; use `ab` mode)")
    if agg["due_hit"]:
        mss = [d["ms"] for d in agg["due_hit"] if isinstance(d["ms"], (int, float))]
        lines.append(
            f"due hits: {len(agg['due_hit'])} ms avg="
            f"{round(sum(mss) / len(mss)) if mss else '?'}"
        )
    per_turn = shows_per_turn(agg)
    lines.append(
        "shows: {} (shell/mcp split in d) | turns={} avg/turn={} max/turn={}".format(
            per_turn["shows"], per_turn["turns"], per_turn["avg"], per_turn["max"]
        )
    )
    if agg["store"]:
        lines.append("store: " + ", ".join(f"{k}={v}" for k, v in sorted(agg["store"].items())))
    if agg["stop"]:
        lines.append("stop: " + ", ".join(f"{k}={v}" for k, v in sorted(agg["stop"].items())))
    lines.append("")
    lines.append(
        "口径: turn = [recall event, next recall event); shows counted per window; "
        "latency only from hook-side ms; adoption is usefulness to the agent, "
        "never fact confidence."
    )
    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# query batch sources
# --------------------------------------------------------------------------- #

def parse_query_log_value(value):
    """One ``query-log`` detail value -> dict or None."""
    match = _QUERY_LOG_RE.match(str(value or "").strip())
    if not match:
        return None
    stamp, query, cand, adopted, good, bad = match.groups()

    def ids(raw):
        return [part for part in str(raw or "").split(",") if part and part != "-"]

    return {
        "ts": stamp,
        "query": query.strip(),
        "candidates": ids(cand),
        "adopted": ids(adopted),
        "good": ids(good),
        "bad": ids(bad),
    }


def parse_query_log_doc(doc):
    """Full ``rsrs query-log --json`` envelope -> list of query dicts.

    The text rows live in ``items`` (``name="query"``); ``details`` is the
    structured side-channel (candidates as full uuids) and only carries a
    ``value`` string on older builds -- accept either shape.
    """
    out = []
    if not isinstance(doc, dict):
        return out
    for item in doc.get("items") or []:
        if not isinstance(item, dict) or item.get("name") != "query":
            continue
        parsed = parse_query_log_value(item.get("value"))
        if parsed and parsed["query"]:
            out.append(parsed)
    if out:
        return out
    for item in doc.get("details") or []:
        if not isinstance(item, dict):
            continue
        parsed = parse_query_log_value(item.get("value"))
        if parsed and parsed["query"]:
            out.append(parsed)
    return out


def queries_from_hook_log(events):
    """Fallback batch: ``q=`` fragments from recall-hit details (truncated at 40 chars)."""
    batch = []
    seen = set()
    for event in events:
        if event.get("ev") != "recall" or event.get("out") != "hit":
            continue
        detail = str(event.get("d") or "")
        index = detail.find(" q=")
        query = detail[index + 3:].strip() if index >= 0 else ""
        if query and query not in seen:
            seen.add(query)
            batch.append({"ts": _ts(event), "query": query, "candidates": [],
                          "adopted": [], "good": [], "bad": []})
    return batch


def default_log_path():
    explicit = os.environ.get("RESPITE_LOG") or ""
    if explicit:
        return explicit
    data = os.environ.get("QODER_PLUGIN_DATA") or ""
    if data:
        return os.path.join(data, "hook.log")
    return os.path.join(REPO_ROOT, "hooks", "hook.log")


# --------------------------------------------------------------------------- #
# A/B replay
# --------------------------------------------------------------------------- #

def render_ids(text):
    """8-char ids present in the injected title lines, in order, deduped."""
    out = []
    for match in _ID_RE.finditer(str(text or "")):
        value = match.group(1).lower()
        if value not in out:
            out.append(value)
    return out


def count_items(text):
    return sum(1 for line in str(text or "").splitlines() if _ITEM_RE.match(line))


def _id_in(haystack_ids, full_or_short):
    target = str(full_or_short or "").lower()
    short = target[:8]
    return any(item == target or item == short or target.startswith(item)
               for item in haystack_ids)


def run_ab(batch, limits, render_fn, ref_fn, budget):
    """Replay every query at every limit.

    ``render_fn(query, limit) -> (text, ms)``; ``ref_fn(query) -> [ids]``.
    Returns ``{"per_limit": {...}, "rows": [...]}`` -- rows are per query x
    limit with raw numbers so tests can assert exact values.
    """
    rows = []
    for entry in batch:
        query = entry["query"]
        reference = list(ref_fn(query) or [])
        marked = [gid for gid in (entry.get("good") or [])]
        for limit in limits:
            text, ms = render_fn(query, limit)
            ids = render_ids(text)
            chars = len(text)
            covered = sum(1 for rid in reference if _id_in(ids, rid))
            rows.append({
                "query": query,
                "limit": limit,
                "chars": chars,
                "items": count_items(text),
                "ms": ms,
                "over_budget": chars > budget,
                "coverage": (covered / len(reference)) if reference else None,
                "good_marked": len(marked),
                "good_hit": (1 if any(_id_in(ids, gid) for gid in marked) else 0)
                if marked else None,
                "ids": ids,
            })
    per_limit = {}
    for limit in limits:
        subset = [row for row in rows if row["limit"] == limit]
        if not subset:
            continue
        chars = [row["chars"] for row in subset]
        mss = [row["ms"] for row in subset]
        cov = [row["coverage"] for row in subset if row["coverage"] is not None]
        marked_rows = [row for row in subset if row["good_marked"]]
        per_limit[limit] = {
            "queries": len(subset),
            "chars_avg": round(sum(chars) / len(chars)),
            "chars_max": max(chars),
            "over_budget": sum(1 for row in subset if row["over_budget"]),
            "items_avg": round(sum(row["items"] for row in subset) / len(subset), 2),
            "coverage_avg": round(sum(cov) / len(cov), 3) if cov else None,
            "ms_avg": round(sum(mss) / len(mss)),
            "ms_p95": _pct(mss, 0.95),
            "good_marked": len(marked_rows),
            "good_hits": sum(row["good_hit"] for row in marked_rows if row["good_hit"]),
        }
    return {"per_limit": per_limit, "rows": rows}


def acceptance_verdict(per_limit, budget):
    """Plan T0-1 gates: every query within budget; coverage reported, not gated."""
    lines = []
    for limit, stats in sorted(per_limit.items()):
        ok = stats["over_budget"] == 0
        lines.append(
            "limit {}: chars avg={} max={} over-budget={}/{} -> {}".format(
                limit, stats["chars_avg"], stats["chars_max"],
                stats["over_budget"], stats["queries"], "PASS" if ok else "FAIL",
            )
        )
    worst = max((s["over_budget"] for s in per_limit.values()), default=0)
    lines.append(
        "verdict: injected text within {} chars for every query -> {}".format(
            budget, "PASS" if worst == 0 else "FAIL (fix rendering/budget before raising the default)"
        )
    )
    lines.append(
        "口径: coverage = share of the wide (max-limit) recall kept by this render; "
        "good-hit = model self-grade usefulness, not fact confidence."
    )
    return lines


def format_ab_report(result, limits, budget, source_note):
    per_limit = result["per_limit"]
    lines = [f"== T0-1 A/B replay ({source_note}) =="]
    header = f"{'metric':<28}" + "".join(f"| limit {k:<12}" for k in limits)
    lines.append(header)
    lines.append("-" * len(header))

    def row(label, key, fmt=str):
        cells = []
        for k in limits:
            stats = per_limit.get(k, {})
            value = stats.get(key)
            cells.append("n/a" if value is None else fmt(value))
        lines.append(f"{label:<28}" + "".join(f"| {c:<16}" for c in cells))

    row("queries", "queries")
    row("injected chars avg", "chars_avg")
    row("injected chars max", "chars_max")
    row("over budget (>{} chars)".format(budget), "over_budget")
    row("items avg", "items_avg")
    row("coverage vs wide recall", "coverage_avg",
        lambda v: f"{v:.3f}")
    row("latency avg ms", "ms_avg")
    row("latency p95 ms", "ms_p95")
    row("queries with good marks", "good_marked")
    row("good-hit (adoption)", "good_hits")
    lines.append("")
    lines.extend(acceptance_verdict(per_limit, budget))
    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# live wiring (imports hooks/respire.py for identical rendering)
# --------------------------------------------------------------------------- #

def load_hook_module():
    spec = importlib.util.spec_from_file_location("respire_hook_metrics", HOOK_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load hook module at {HOOK_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_live_fns(hook, limits):
    """(render_fn, ref_fn) against the real rsrs CLI -- recall only, no writes."""
    cfg = hook.load_config()
    cfg = dict(cfg)
    cfg["log"] = False           # replay must not touch the live hook.log
    bin_path = hook.find_rsrs(cfg)
    if not bin_path:
        raise RuntimeError("rsrs engine not found (config rsrs= / PATH)")
    max_limit = max(limits)
    reference_cache = {}

    def render_fn(query, limit):
        one = dict(cfg)
        one["recall_limit"] = limit
        started = time.time()
        text = hook.do_recall(bin_path, query, one)
        return text, round((time.time() - started) * 1000)

    def ref_fn(query):
        if query in reference_cache:
            return reference_cache[query]
        ids = []
        try:
            result = hook.run_rsrs(
                bin_path,
                ["recall", query, "--limit", str(max_limit), "--titles", "--json"],
                hook.RECALL_T,
            )
            doc = json.loads(result.stdout) if result.stdout else {}
            for detail in (doc.get("details") or []) if isinstance(doc, dict) else []:
                if isinstance(detail, dict) and isinstance(detail.get("id"), str):
                    ids.append(detail["id"][:8].lower())
        except Exception:
            ids = []
        reference_cache[query] = ids
        return ids

    return render_fn, ref_fn


def load_batch(args, hook):
    """Query batch from --queries-file, query-log, or hook.log (in that preference)."""
    if args.queries_file:
        with open(args.queries_file, "r", encoding="utf-8") as handle:
            batch = json.load(handle)
        if not isinstance(batch, list):
            raise ValueError("queries file must be a JSON list")
        return batch, f"file {args.queries_file}"
    if args.source == "query-log":
        result = hook.run_rsrs(hook.find_rsrs(hook.load_config()) or "",
                               ["query-log", "--limit", str(max(1, args.max_queries)),
                                "--json"], hook.RECALL_T)
        doc = json.loads(result.stdout) if result.stdout else {}
        batch = parse_query_log_doc(doc)
        if batch:
            return batch[:args.max_queries], f"query-log, {len(batch)} entries"
    events, _ = load_hook_events(default_log_path())
    batch = queries_from_hook_log(events)
    return batch[:args.max_queries], f"hook.log q= fragments, {len(batch)} entries"


def cmd_ab(args):
    hook = load_hook_module()
    limits = [int(part) for part in str(args.limits).split(",") if part.strip()]
    limits = sorted({max(1, value) for value in limits})
    batch, source_note = load_batch(args, hook)
    if not batch:
        print("no queries available (query-log empty and hook.log has no recall hits)")
        return 0
    if args.dump:
        with open(args.dump, "w", encoding="utf-8") as handle:
            json.dump(batch, handle, ensure_ascii=False, indent=1)
        source_note += f"; dumped to {args.dump}"
    render_fn, ref_fn = make_live_fns(hook, limits)
    result = run_ab(batch, limits, render_fn, ref_fn, args.budget)
    print(format_ab_report(result, limits, args.budget, source_note))
    if args.rows:
        print("\nper-query rows (query, limit, chars, items, ms, coverage):")
        for row in result["rows"]:
            cov = "n/a" if row["coverage"] is None else f"{row['coverage']:.3f}"
            print(f"  [{row['limit']}] chars={row['chars']} items={row['items']} "
                  f"ms={row['ms']} cov={cov} q={row['query'][:60]}")
    return 0


def cmd_log(args):
    path = args.path or default_log_path()
    events, skipped = load_hook_events(path)
    if skipped == -1:
        print(f"cannot read {path}")
        return 0
    agg = aggregate_log(events)
    print(format_log_report(agg, skipped, path))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="ab_metrics",
        description="T1-6: hook.log summary and recall-limit A/B replay (read-only).",
    )
    sub = parser.add_subparsers(dest="mode")
    log_parser = sub.add_parser("log", help="summarize hook.log events")
    log_parser.add_argument("--path", default=None, help="hook.log path (default: plugin data dir)")
    ab_parser = sub.add_parser("ab", help="replay queries at several recall limits")
    ab_parser.add_argument("--limits", default="5,20", help="comma-separated limits (default 5,20)")
    ab_parser.add_argument("--max-queries", type=int, default=50, help="batch cap (default 50)")
    ab_parser.add_argument("--source", choices=("query-log", "hooklog"), default="query-log",
                           help="batch source when no --queries-file (default query-log)")
    ab_parser.add_argument("--queries-file", default=None, help="replay a dumped batch (repeatable)")
    ab_parser.add_argument("--dump", default=None, help="write the batch to this JSON file")
    ab_parser.add_argument("--budget", type=int, default=1500, help="injection budget (default 1500)")
    ab_parser.add_argument("--rows", action="store_true", help="also print per-query rows")
    args = parser.parse_args(argv)
    if args.mode == "log":
        return cmd_log(args)
    if args.mode == "ab":
        return cmd_ab(args)
    parser.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
