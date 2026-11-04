# Changelog

## 0.6.23 — 2026-11-04

### Fixed

- **Token redaction false positive on `skill*` words**: the `sk|ghp|...` log-redaction rule
  matched any word starting with `sk` plus 8 word chars, so the T1-2 audit field
  `skill_template_gaps` (and prompts mentioning "skill") were logged as `[REDACTED]=619`.
  The rule now carries a `(?!skill)` lookahead; real `sk-`/`ghp_` tokens still mask
  (verified alongside the password and 11-19-digit rules). Live 0.6.22 verification caught it:
  every `ev=consolidate` audit line lost that field.

## 0.6.22 — 2026-11-04

### Added

- **T1-2 low-frequency consolidation trigger (local phase)**: `UserPromptSubmit` consults the
  tidy counter (`rsrs resort --status --json`) at most every `consolidate_check_hours`
  (default 24) from a persistent state file, so a normal turn costs one file read and no
  subprocess. Fires when the counter reaches the CLI threshold (cooldown one check interval)
  or the weekly fallback (`consolidate_week_hours`, default 168) elapses with a nonzero
  count; a zero counter always skips. On fire it runs one local `rsrs audit --json` and logs
  the structured problem counts (`ev=consolidate` reason codes in `hook.log`).
  - **Log-only by design**: no model call, never `resort --go`/`--spec` (candidates belong to
    the later model phase after the two-week dry-run), no injection (T1-7 quiet default),
    fail-open on every error path. The CLI uses rc=2 for warn envelopes, so the envelope is
    parsed regardless of rc.
  - Config: `consolidate_check` (master), `consolidate_check_hours`, `consolidate_week_hours`;
    documented in the example config. The credential-guard sandbox pins
    `consolidate_check: false` to keep its strict single-call audit policy (coverage lives in
    `test_hooks.sh`: threshold/weekly fires, zero skip, throttle, dead process, failed audit,
    /nomem and store-prefix exclusion, config opt-out).

## 0.6.21 — 2026-11-04

### Changed

- **T0-1 recall count raised to 20**: `recall_limit` default 5 → 20 (hook `DEFAULTS`, example
  config, README). Decision came from a live A/B replay of 47 real queries through the hook's
  own `do_recall` (`scripts/ab_metrics.py ab`): limit 20 keeps 0.965 of the wide recall vs
  0.250 at limit 5, with identical latency (avg 1973 ms vs 1996 ms, p95 2760 vs 2588 ms).
- **Budget accounting fix**: `do_recall` reserved a fixed 90 chars for the header although the
  real header is ~140 chars, so renders could reach 1550 chars against the 1500-char budget
  (11/47 queries over before the fix). The reserve is now the header width at `recall_limit`
  (an upper bound for any smaller match count), and the A/B re-run is 0/47 over budget at
  every limit.

### Added

- **T1-6 A/B metrics tool**: `scripts/ab_metrics.py` with two modes -- `log` summarizes
  `hook.log` JSONL (recall/due/store/stop/show events, injected chars, latency p95, shows per
  turn) and `ab` replays a query batch through the hook's own renderer at several limits for
  an acceptance table. 22 offline tests (`tests/test_ab_metrics.py`); the 口径 (metric
  definitions) are documented in the module docstring and printed with every report --
  adoption is never evidence that a record is factually true.
- **Show counting**: `on_pre_tool_use` now logs `show` events (counts only -- no CLI call, no
  ids, no titles) for shell `rsrs show` and MCP `memory_show`, so the T0-1 acceptance metric
  "show次数不升反降或持平" is measurable from `hook.log`.
- **Injected-chars telemetry**: recall `hit` log lines carry `chars=<len>` for the rendered
  injection.

## 0.6.20 — 2026-11-04

### Added

- **Due-check injection (plan T1-1 / WP4-3)**: `UserPromptSubmit` runs one local
  `rsrs review --due --json --limit 100` per real turn -- in parallel with recall, so it adds
  no sequential latency -- and appends `【respire · due】N 条待复核` as the last injected line
  when the store has due records (a full page is reported as `N+`). Counts only, never ids or
  titles; no model call. Every failure path (timeout, nonzero rc, unparseable envelope,
  `status != ok`, empty page) fails open to no footer, and a late thread never hangs the hook.
  `/nomem`, host-internal prefixes, credential hits, store-prefix turns and very short prompts
  return before the check and stay due-free; `due_check: false` disables it (documented in the
  example config).
  - Tests: stub `review` branch (`STUB_DUE=hit/fail/error`), footer presence / last-line /
    log-reason checks, fail-open cases, nomem and store-prefix exclusion, config opt-out; the
    credential-guard sandbox pins `due_check: false` to keep its strict single-call audit
    policy (due-check itself is covered in `test_hooks.sh`).

## 0.6.19 — 2026-11-04

### Changed

- **Stop store-check throttle default (`store_nudge_every` 1 → 4)**: the end-of-work nudge now
  fires on every 4th real Stop instead of every turn (plan P1-1: every 3-5 turns, no per-turn
  model continuation). The throttle runs before the per-session latch, so skipped Stops never
  consume the one-shot latch; `store_nudge_every: 1` restores the old behaviour, `0` stays off.
  Tests pin `1` in the per-request contract cases and add a default-throttle case (three silent
  Stops, the fourth denies).

## 0.6.18 — 2026-11-03

- `do_store` no longer writes an important record by itself. A direct call without a verified
  parent id and a complete fact-sentence title returns store-pending and makes no engine call,
  so the hook cannot mint a loose root or a placeholder title. A reviewed call passes
  `--parent` through.

## 0.6.17 — 2026-11-02

### Changed

- **Hybrid keyword recall (`defer_sentence`, default on)**: a sentence-shaped prompt (sentence
  punctuation, question particles / person pronouns, or a long unbroken run) is no longer queried
  with the raw text. The hook injects a recall-pending directive instead and the agent distills
  3-5 keywords first (SessionStart rule 1 + skill), so raw sentences stop becoming recall
  queries; keyword-shaped prompts (space-separated terms) keep the synchronous
  `rsrs recall --titles`. `defer_sentence: false` restores the old query-with-raw-text behaviour.
  - `looks_like_sentence` matches Chinese sentence particles and person pronouns (via `\u`
    escapes, source stays ASCII), common English sentence starters, and sentence punctuation;
    a run longer than 24 chars with no space is treated as running text.
  - Tests: the irrelevant-prompt case now uses a keyword-shaped query; new checks cover the
    directive injection, the zero engine call for sentences, the `defer_sentence` log reason
    code, synchronous recall for keyword prompts, and three pure-function shape cases.

## 0.6.16 — 2026-11-02

- Normalize redirections before command identification; require verified placement for inherited-importance merges and important updates.

- Add PreToolUse JSON denial for important writes without a verified parent, force bypasses, explicit parent clearing and opaque memory commands.
- Verify literal parents with client-only show, preserve unrelated tools and document the interception boundary.

## 0.6.15 — 2026-11-02

- Remove all non-ASCII (CJK) text from hooks, config, tests, docs and manifests. Behaviour is
  unchanged: patterns that must match Chinese user input or existing Chinese data now use
  `\u` escapes (`STORE_PREFIX` triggers, `SECRET_RE`/`_REDACT` keywords, `skip_prefixes`
  entries, sentence separators in `extract_title`).
- `plugin.json` drops `descriptionZh` (optional field, not read by `validate_plugin.py`) and
  renames `displayName` to `respire Memory`.

- Explicit memory prefixes return pending without any engine write.
- Require engine policy, same-topic candidate bodies, and update > merge > attach > new; new important records need a reviewed reasonable parent, otherwise stay pending without force or importance downgrade.
- Keep actual write receipt unknown/no-retry coverage separate from live prefix checks.

## 0.6.13 — 2026-11-01

- Reject invalid write IDs and mismatched/non-string read-back fields; preserve committed receipts without retries.


## 0.6.12 — 2026-11-01 · Review round 4 final: remove disk-receipt suppression

### Changed

- **`turn_stored` is always False (review 4 final)**: across events (UserPromptSubmit to Stop are two separate hook processes) there is no "current request" identity that can be persisted to disk without depending on a file operation succeeding -- the read-modify-write of `_state_update` (load -> patch -> rename) in the same session can roll back a new prompt/generation: an old `mark_store` reads, pauses -> a new `mark_prompt` commits -> the old write's `os.replace` lands -> the old receipt is resurrected and Stop wrongly skips nudging the new turn. After four review rounds disproved every locking/barrier variant one by one, this suppression optimisation was **removed** on the reviewer's advice (matching the already merged zcode/dimcode final decisions): Stop's only de-dup basis returns to **latch semantics** (created with O_EXCL at Stop nudge time, deleted by the next real prompt -- "already nudged" is decided by lock existence and depends on no stale disk receipt that was read). `on_stop` drops the `turn_stored` branch (nudge deny directly after latch_claim). **A successful explicit-store receipt is still returned honestly to the model**; the state file (`st_<sid>.json`) remains a diagnostic trail and no longer affects the Stop decision. Side effect: Stop nudges at most once per request (turns that were previously suppressed by a receipt are now nudged -- the model receipt already said the fact was stored and it ends directly, with no extra engine call).

### Fixed

- Tests: flipped every assertion that relied on disk-receipt suppression -- "after a successful store the receipt suppresses this turn" became "after a successful store Stop still denies (suppression removed)"; session B's receipt-only-suppresses-itself became an assertion that nudging happens in the same direction; the barrier interleaving test is kept (state-file isolation still prevents rollback, and the assertion never depends on disk-receipt suppression); the `stored_turn_skip` trail assertion is removed with the branch.

## 0.6.11 — 2026-11-01 · Review round 2 fixes (three P2 items)

### Fixed

- **Internal prompts must not re-arm the completion latch (round #1)**: `on_prompt` reorders -- empty check -> `/nomem` (still marks, recall skipped only) -> `skip_prefixes` internal whitelist (return immediately, **no mark** -- host-internal events such as Qoder Recap are not new real requests and do not delete the one-shot latch) -> `mark_prompt` -> everything else. "Real request -> Stop deny -> internal Recap in the same session -> Stop" no longer denies twice when the host does not carry `stop_hook_active`.
- **readback bad-details guard (round #2)**: the `details` of a `show` read-back is type-checked with `isinstance(dict)` first -- a bad envelope such as a non-empty array or string degrades locally to `unavailable`, keeping the Saved receipt and the no-resend constraint; the verification block is wrapped in try so a read-back exception never propagates and swallows an already successful write receipt.
- **Shared-map read-modify-write interleaving eliminated (round #3)**: the single shared `turn_map.json` became a **per-session state file `st_<sid>.json`** (temp+rename atomic replace) -- a session writes only its own file, so session B's stale snapshot can never write back and restore A into an old `store_ts>=prompt_ts` that wrongly suppresses; concurrent A/B updates are never lost (file-level isolation). The write receipt also records the **request start time `store_req_ts`**: a write that started before this turn's prompt does not belong to this turn -- a late-completing old request no longer pollutes the new request's suppression decision. Stale session files are pruned by count only (<=128, no time-based expiry) and losing one only loses the optimisation.
- `.gitignore` adds `st_*.json` (the old `turn_map.json` stays for compatibility); the README behaviour table is updated (internal prompts do not re-arm, independent state files, receipts bound to the write request generation).

### Changed

- Tests: added an internal Recap sequence (deny -> Recap -> no second deny), bad-details counterexamples in both states (array/string, Saved receipt kept plus degraded `unavailable`), cross-session isolation (B's write does not suppress A's new turn), and a deterministic barrier interleaving (A's new prompt inside B's write-back window: A's prompt_ts is not rolled back, the old store does not suppress, B's update is not lost, and a late old-request receipt does not suppress the new turn).

## 0.6.10 — 2026-11-01 · Maintainer review fixes (review #1-#5 plus test-reliability blocker)

### Fixed

- **Completion latch rework (review #1)**: the single `.store_turn` state became a **per-session lock file** (`O_CREAT|O_EXCL` atomic -- of concurrent Stop calls only one takes the lock; the lock has no TTL and stays held after 25 hours, only a new real prompt deletes and re-arms it, and an A->B->A session interleaving does not lose the lock); when the lock cannot be taken (unwritable state dir etc.) always allow -- never deny without a lock. prompt_ts/store_ts live in a best-effort per-session map (`turn_map.json`, temp+rename atomic replace, pruned by count only); a map failure only loses the optimisation and never breaks the at-most-once guarantee.
- **Malformed receipts no longer claim a definite non-write (review #2)**: only `fail` is a whitelisted explicit rejection asserting nothing was accepted; `ok`/`warn` without a valid id (hex/uuid whitelist check), a non-dict summary (type-guarded, no exception), an unknown status, or a bad envelope/timeout all map to **unknown** (read-only verification guidance plus no resend, never printing "did not accept").
- **unknown verification shares the hook budget (review #3)**: remember/read-back/read-only verification share one deadline (`RESPITE_HOOK_BUDGET_S`, default 20s, with 2.5s output headroom) -- after a slow bad receipt the remainder is too small and it goes straight to unknown with no further engine call, so the receipt always lands inside the host window.
- **Full read-back verification (review #4)**: a `show` read-back must have an equal id, an equal title and an **equal full body** to be called verified; a wrong id or content drift past 40 chars -> mismatch, labelled honestly; the non-dict details type guard does not propagate and keeps the written receipt.
- **Attributable suppression receipts (review #5)**: removed "the newest write across the whole store being later than this turn's prompt suppresses the nudge" (it cannot be attributed to a session and B's write would wrongly suppress A); **Stop now issues no engine query at all**; `/nomem` still counts as a new request (mark moved earlier to re-arm the latch) and only skips recall.

### Changed

- **Test-reliability blocker fixes (CI-required)**: `stub_engine.py` gains a `#!/usr/bin/env python3` shebang (the POSIX side cp+chmod execs it directly and Linux reports "Exec format error" without one); `CFG_OFFE` is defined (undefined under `set -u` aborts the whole script); every `RESPITE_TURN_STATE` goes through a `cygpath -m` hybrid path `TURNBASE` (Windows python cannot resolve MSYS `/tmp`, so the lock would land on the wrong drive letter); PY3 detection tries python3 -> python -> py with a **real execution check** each (windows-latest has no python3 shim, and the WindowsApps store placeholder can be found by `command -v` yet exits immediately when run); with no rsrs engine the real-store branch records SKIP while the stub state machine, credential guard and pure-function suites still run; fixed the "recall header matches the item count" assertion which iterated a string without splitting lines and was always BAD; scenarios updated to the new contract (engine writes do not suppress, a bad list envelope/dead process does not affect Stop, a single nudge makes zero engine queries, 25-hour lock hold, new request//nomem re-arm, cross-session receipts, unwritable state dir allows). bash 75/0 (real store) / 69/0 (CI without engine, SKIP listed explicitly).
- **CI wiring**: `ci-release.yml`'s three-platform check job gains a `Behavior suite (stubbed engine)` step that actually runs `bash tests/test_hooks.sh` -- previously CI only ran validate/credential_guard/release and the state-machine tests never executed.
- README behaviour table updated (atomic latch / attributable suppression / no engine query / missing id as unknown / full read-back / shared budget); `.gitignore` gains the completion latch and turn-map state files.

## 0.6.9 — Audit fixes: write-result state machine, Stop fail-open, request-level suppression receipt (QD-01~QD-04)

### Fixed

- **QD-01 Stop fail-open**: when the `list` store query fails, times out, returns a bad envelope or hits a dead process, allow directly instead of denying -- a memory-layer fault must not force the main task to continue.
- **QD-02 read-only verification for unknown write results**: timeout/bad receipt/no output all map to **unknown** -- the receipt explicitly says "verify read-only with `rsrs list`/`rsrs show`, never resend remember" (the old wording "verify manually with rsrs remember" carried a duplicate-write risk); an instant bad receipt triggers an automatic `list` cross-check reporting that it may already be written (with the read-only id). `warn` + a valid id means **written with warnings** and is reported honestly rather than as a failure.
- **QD-03 quick-store receipt closed loop**: after ok/warn, verify with a `show` read-back (R11); pending keeps the candidate short ids and the full set of engine-suggested actions (update > merge > attach > store, 7.2); the `.store_turn` request-level receipt replaces the "any write in the last 10 minutes" cross-turn suppression; the one-shot latch guarantees at most one deny per request when the host does not carry `stop_hook_active`.
- **QD-04 SKILL.md envelope doc fix**: the title tier is `details[].id/title`, the nested `entry` is the `show`/`chain` envelope -- a doc fix that changes no working parsing; the remember row follows the warn=written, no-resend contract.

### Changed

- Tests: the bash suite moved to a portable python engine stub plus scenario reset and state-machine assertions (54/9 -> 72/0, --store 75/0); prompts pass through the `PROMPT_VAL` env var (fixes two Windows pseudo-failures: MSYS `/nomem` path conversion and heredoc CJK code-page mojibake -- the same fix is back-ported to the zcode/dimcode suites); `RESPITE_TEST_FAST`/`RESPITE_TURN_STATE` test backdoors; README behaviour table updated; `.gitignore` gains `.store_turn`.
