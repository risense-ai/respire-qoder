# respire-qoder

> Store on the inhale, recall on the exhale -- memory for Qoder.

Website: <https://rsrs.rs> · Repo: <https://github.com/risense-ai/respire-qoder> · Feedback: [Issues](https://github.com/risense-ai/respire-qoder/issues) · Contribute: [Pull requests](https://github.com/risense-ai/respire-qoder/pulls)

`respire-qoder` uses Qoder's plugin hooks to wire the [respire engine (CLI name rsrs)](https://www.npmjs.com/package/rsrs-cli) into the agent loop: before each answer it recalls existing records from the memory store, a prompt that starts with the store trigger is written, and at the end of a turn a store check reminds the agent to save what it just learned. **Registering and enabling cloud sync is recommended**: run `rsrs register` on this machine to create an account; records sync encrypted to the cloud and `rsrs login` on another device picks them up under the same account. It also works without registering, but records then live only on this machine, and losing the device loses the records.

The plugin contains no engine and no custom install script; when the engine is missing it hands the install command to the agent to run inside the session.

## Data storage safety

1. **Cloud sync recommended**: run `rsrs register` on this machine (you set the login password, and you save the system-generated A3 recovery code); records sync encrypted to the cloud and survive a device change or reinstall. The plugin warns when it detects a logged-out state.
2. **The cloud stores ciphertext only**: records are encrypted locally before upload and the server keeps encrypted records only. Decryption, indexing and retrieval all happen on the device; the server needs no model and never holds an account's decryption key, so the cloud and its operators see ciphertext only.
3. **Works offline or unregistered**: the memory store is local, so recall and writes keep working without network, registration or login. Writes made offline stay in the local queue and are not lost; after you log in they fill in through autosync. Local-only storage is lost with the device, so register and enable sync early.
4. **Enterprises can self-host the sync server**: `respire-server` supports private deployment (Docker Compose + Postgres) and can run entirely offline inside a corporate network. Point the sync endpoint at your own service and data never leaves the corporate network (see "Self-hosting" in respire-docs).

## Works without a model

- Registration, login, sync and recall do not depend on an on-device model. Without one, the engine recalls by literal text matching and remains fully usable.
- The BGE-M3 model (~1.1GB) is an optional install: with it, recall matches semantically and works better. Run `rsrs model install && rsrs model activate m3`; without it the plugin hints once and normal use is unaffected.

## Install

### 1. The Qoder plugin

Install from a directory:

```bash
qoder plugins install /absolute/path/to/respire-qoder
```

Or from the bundled marketplace (the repo ships `.qoder-plugin/marketplace.json`):

```bash
qoder plugins marketplace add /absolute/path/to/respire-qoder
qoder plugins install respire-qoder@risense
```

After installing, run `/plugins reload` in the session or restart the session. Qoder Desktop can also install from a local directory in plugin settings; the desktop app and the CLI share the same plugin directory and manifest.

### 2. The engine (the agent can install it when missing)

```bash
npm i -g rsrs-cli@latest
rsrs --version
```

Without global write permission, try:

```bash
npm config set prefix ~/.npm-global
npm i -g rsrs-cli@latest
```

The plugin probes for the engine every turn; once installed, recall and explicit stores resume within the same session.

### 3. Register and enable cloud sync (recommended, first run)

Run `rsrs register` on this machine: you set the login password and the system generates a recovery code starting with A3 that you must keep, since data cannot be unlocked without it. Registration also logs you in and autosync stays on; afterwards use `rsrs login` for browser authorization, `rsrs sync` for a manual sync and `rsrs status` to inspect state.

The plugin works without this step, but records then stay local only and cannot be recovered after a device change or OS reinstall. When SessionStart detects a logged-out state it injects the registration guidance automatically.

## Behaviour after install

| Moment | Behaviour |
| --- | --- |
| `SessionStart` | Injects the English memory-discipline rules when enabled; no account, empty-store, model or probe hints are injected |
| `UserPromptSubmit` | Runs `rsrs recall --titles` automatically and injects only the score, 8-char short id and title; the agent reads the body on demand with `rsrs show <id>`. No filter threshold by default; noise is bounded in three places: the engine skip gate, limit 20 (A/B-verified against the 1500-char budget), and the title-only injection. **Hybrid recall** (`defer_sentence`, default on): a sentence-shaped prompt (sentence punctuation, question particles, person pronouns, or a long unbroken run) is *not* queried with the raw text -- the hook injects a recall-pending directive instead and the agent distills 3-5 keywords first, so raw sentences never become recall queries; keyword-shaped prompts (space-separated terms) keep the synchronous recall. **Due-check** (`due_check`, default on): the same turn also runs one local `rsrs review --due --json` (in parallel with recall) and appends `【respire · due】N 条待复核` as the last injected line when records are due -- counts only, never ids/titles, no model call, fail-open to no footer; `/nomem`, internal prefixes, credential hits, store-prefix turns and very short prompts stay due-free. **Consolidation trigger** (`consolidate_check`, default on, T1-2 local phase): a shared maintenance thread consults the tidy counter (`rsrs resort --status`) at most once per `consolidate_check_hours` from a state file -- a normal turn is one file read, no subprocess -- and fires when the counter hits the CLI threshold or the weekly fallback elapses with a nonzero count; it then runs one local `rsrs audit` and logs the problem counts to `hook.log`. **Log-only: no model, never `resort --go`, nothing injected** (T1-7 quiet default), fail-open; zero counter always skips |
| prompt starting with the store trigger or `remember:` | Returns pending without any engine write. The body is only the fact to remember, not an engineering task. The model first reads `rsrs prompt`, recalls same-topic candidates, reads bodies with `show`, then decides update > merge > attach > new. A new important record needs a reviewed parent from actual bodies; if none, it stays pending — never guess a parent, force, or downgrade. If an actual write result is unknown, verify read-only and never resend. |
| `Stop` | Store check: `decision: deny` continues for one turn and asks the agent to write this turn's new facts, decisions, agreements and lessons one by one. **At most one nudge per real request**: `stop_hook_active=true` allows, plus this layer's **per-session atomic latch** (`O_CREAT|O_EXCL` exclusive create -- of concurrent Stop calls only one takes the lock; the lock has no TTL and stays held after 25 hours, only a new real prompt deletes it and re-arms it, and a `/nomem` turn also counts as a new request; **host-internal prompts (Qoder Recap whitelist) are not new requests and do not re-arm**, so "real request -> Stop nudge -> internal Recap -> Stop" never nudges twice). **Stop makes no engine call at all**. **Disk-based suppression is cancelled** (final decision): across events (UserPromptSubmit and Stop are two separate hook processes) there is no reliable disk identity for "the current request" -- the explicit-store receipt is still returned honestly but no longer affects the Stop decision; **the only de-dup basis is latch existence** (a new real prompt deletes and re-arms it), so Stop nudges by throttle policy and never suppresses from an old disk record (an explicit store may still be followed by one closing hint; model behaviour after that has not been verified on a live host, and the Stop hook itself never calls the engine). Receipt timestamps live in a **per-session state file `st_<sid>.json`** (temp+rename atomic replace) as a diagnostic trail only: a session writes only its own file, with no shared-map read-modify-write interleaving. **A failed lock (unwritable state dir etc.) always allows**: never deny without a lock -- a memory-layer fault must not block the end of the main task. `store_nudge_every` throttles it (default 4 = every 4th Stop, 1 = every turn, 0 = off, N = every Nth) |
| `/nomem` prefix | Skips recall for this turn |
| `$skill: name` prefix | Stripped before recall so the skill name cannot disturb the recall query |
| `skills/respire` | The full on-demand playbook; every action is driven by the hooks |

## Tuning (optional)

Configuration precedence:

1. `RESPITE_CONFIG` environment variable
2. `$QODER_PLUGIN_DATA/respire.config.json`
3. `<plugin root>/hooks/respire.config.json`

Copy from the example:

```bash
cp hooks/respire.config.example.json hooks/respire.config.json
```

| Field | Default | Meaning |
| --- | --- | --- |
| `rsrs` | `""` | Engine path; empty = auto-detect (`RESPIRE_BIN` -> `respire`/`rsrs` on PATH -> `~/.local/bin` -> `~/.rsrs/bin`) |
| `recall_threshold` | `0.0` | Recall floor; 0 = off by default (raw engine output), a positive value enables filtering |
| `recall_limit` | `20` | Keep the first N hits (A/B-verified: 20 stays inside `budget_chars`, 5 kept only a quarter of the wide recall) |
| `min_prompt_chars` | `2` | 1 char is skipped, 2 chars triggers a query |
| `defer_sentence` | `true` | Hybrid recall: sentence-shaped prompts are not queried with the raw text; the hook injects a directive and the agent distills 3-5 keywords first. `false` restores query-with-raw-prompt for every prompt |
| `session_rules` | `true` | Whether to inject the SessionStart rules; if you already wrote the full respire rules into `~/.qoder/rules` with `rsrs inject`, set `false` to avoid duplicate injection |
| `budget_chars` | `1500` | Total injection budget per turn |
| `enabled` | `true` | Master switch: false = everything silent |
| `store_nudge_every` | `4` | Stop throttle: N = every Nth Stop (default 4, so at most one nudge per ~4 requests), 1 = every turn, 0 = off |
| `due_check` | `true` | T1-1: append `【respire · due】N 条待复核` on real turns whose `rsrs review --due` has items (one local call, counts only, fail-open) |
| `consolidate_check` | `true` | T1-2: low-frequency consolidation trigger -- consult the tidy counter at most every `consolidate_check_hours`, fire on threshold/weekly with a nonzero count, run one local `audit` and log its counts. Log-only: no model, no `resort --go`, nothing injected, fail-open |
| `consolidate_check_hours` | `24` | Minimum hours between `resort --status` counter checks (a normal turn costs one state-file read) |
| `consolidate_week_hours` | `168` | Weekly fallback fire when the counter is nonzero; `0` disables the weekly rule |
| `log` | `true` | `hook.log` trail (cleared above 256KB) |

Other environment variables: `RESPIRE_BIN` (engine path), `RESPITE_RSRS` (legacy name), `RESPITE_LOG`, `RESPITE_NUDGE_STATE`, `RESPITE_TURN_STATE` (latch/receipt state directory), `RESPITE_HOOK_BUDGET_S` (shared write-chain deadline, default 20s).

Filtering policy: no threshold by default. Noise is bounded in three places: the engine skip gate, limit 5, and title-only injection. Missing a genuinely relevant record costs more, so showing two extra title lines is preferred.

## Verification

```bash
python3 scripts/validate_plugin.py
python3 tests/test_credential_guard.py
python3 -m unittest discover -s tests -p test_release.py -v
python3 -m unittest discover -s tests -p test_ab_metrics.py -v
bash tests/test_hooks.sh
```

The first four need no real engine: the guard test uses temporary stubs, config and logs, forces a positive control proving ordinary input really recalls, then proves a credential triggers zero calls and that a dead stub must fail the positive control. CI runs these four on Linux, Windows and macOS. `test_hooks.sh` is the legacy real-engine suite and does not run in CI.

### A/B metrics (T1-6)

`scripts/ab_metrics.py` measures the injection itself. Two modes, both read-only:

```bash
# Summarize the live hook.log trail: recall/due/store/stop/show counts,
# injected chars, latency avg/p95, shows per turn.
python3 scripts/ab_metrics.py log

# Replay a query batch through the hook's own do_recall at several limits
# and print the acceptance table (chars avg/max, over-budget count,
# coverage vs wide recall, latency).
python3 scripts/ab_metrics.py ab --max-queries 50 --queries-file batch.json
```

The batch source is `--queries-file` > the `rsrs query-log` envelope > `q=` fragments in `hook.log`. Every report ends with the 口径 footer: coverage = share of the wide (max-limit) recall kept by this render; good-hit = model self-grade usefulness, **never** evidence that a record is factually true. The module docstring carries the full metric definitions. The T0-1 default switch (5 → 20) was decided from this tool: 0/47 queries over the 1500-char budget after the header-reserve fix, 0.965 coverage, latency unchanged.

### GitHub Actions release

PRs and pushes to main only test and package, never release. Pushing a `vMAJOR.MINOR.PATCH` tag to the main repo makes the workflow verify that the tagged commit belongs to main and that the tag version matches the manifest/hook, then produce a root-level ZIP with `git archive` from that commit. Only the release job gets `contents: write` on the repo `GITHUB_TOKEN`, so no new PAT, OAuth app or repo secret is needed.

To resume an unfinished release for an existing tag: in Actions -> CI and release -> Run workflow choose **main**, and fill in the existing `tag` with its exact 40-char `expected_sha`. For example `v0.6.8` maps to `c969187b085f934b1edce27de25117a8591dc661`. The workflow packages from that tag commit, never moves the tag, never executes code from the old tag, and never treats current main as the old tag's code.

The ZIP comment records the commit SHA; the Release uploads both the ZIP and `SHA256SUMS`. A repeated run only accepts an existing asset with the same provenance marker and an identical SHA256, fills in missing assets and then releases; an unknown provenance, different content or an extra asset stops it, and nothing is overwritten. An interrupted upload may leave a draft to resume. `check` and `package` are read-only by default; fork PRs cannot reach the write release job and the workflow does not use `pull_request_target`.

Isolated tests are not an end-to-end acceptance of a real Qoder host/engine, nor proof that the legacy real-engine suite passes entirely.

Exercise the hook directly (independent of whether Qoder loaded the plugin):

```bash
echo '{"hook_event_name":"UserPromptSubmit","prompt":"respire memory"}' \
  | python3 hooks/respire.py UserPromptSubmit
```

Write probe (writes to the real memory store with a random nonsense string and cleans up via `rsrs forget`):

```bash
bash tests/test_hooks.sh --store
```

## Design notes

- **fail-open for automatic guidance**: guidance errors remain silent and exit 0; identified PreToolUse memory writes deny on guard or parent-verification errors
- **Plain-text output**: SessionStart / UserPromptSubmit stdout is additional context and never mis-blocks a session
- **Titles only**: recall returns id/score/title only; the agent reads bodies on demand with `show`
- **The engine decides writes**: no `--force` on write; `pending` candidates from the engine are relayed as-is for the model to decide
- **Cross-platform fallback**: hook commands use `python3 || python`; config and logs go under `QODER_PLUGIN_DATA`
- **In-package self-check**: structure, manifest, hooks shape, Python compilability, secret scan

## Known limits

- **The first recall is slow**: the first recall after a session starts must boot the engine runtime (and load the semantic model if installed), measured at about 7 seconds. The plugin sets generous timeouts for that (recall 14s, probe 10s, 20s per hook in total) and injects diagnostics at the start of the session when the boot fails. Once the engine is resident, later recalls usually return in well under a second.

## Feedback and contributions

- Repo and source: <https://github.com/risense-ai/respire-qoder>
- Problems or feature ideas: file an [Issue](https://github.com/risense-ai/respire-qoder/issues) with the session scenario and `hook.log` (`QODER_PLUGIN_DATA/hook.log`, cleared above 256KB), which speeds up diagnosis a lot.
- Code or docs contributions: a [Pull request](https://github.com/risense-ai/respire-qoder/pulls) is welcome; keep the existing style and run `python3 scripts/validate_plugin.py` and `bash tests/test_hooks.sh` after changing anything.
- Product issues (engine, account, sync): Issues at <https://github.com/risense-ai/respire> or the website <https://rsrs.rs>.

## License

MIT

### PreToolUse write guard

Real shell redirections are removed before identifying the executable and subcommand; quoted text stays an argument. Every `remember --merge-ids` requires an explicit verified parent, including trivial merges because source importance can be inherited. Before `update --importance important`, the hook reads the target and verifies its existing non-empty parent; attach a root record before promoting it.

Before visible Bash calls, the hook parses literal rsrs remember/update/attach arguments and every command in a sequence. It rejects force bypasses, important creation without a parent, explicit empty or invalid parents, and identified dynamic or wrapped memory writes. Use one explicit literal command when parsing is refused. Non-memory commands and read-only calls remain silent.

A non-empty parent must be an ID that an existing runner can verify with `rsrs --client-only show <id> --json`. Verification has a 16-second total budget inside the 20-second hook timeout; missing runners, errors, malformed receipts and timeouts deny the write and leave placement pending. No runtime is started and the hook never writes memory. Denials contain only static English guidance and exit 0, so the Python fallback cannot swallow them. Automatic guidance still honors the enabled switch; this placement guard remains active while the hook component is installed.

Host-visible `memory_remember`, `memory_update` and `memory_attach` MCP names, including `mcp__<server>__memory_*`, are denied because the hook cannot bind an arbitrary MCP server to the local target profile. Use an explicit rsrs command through the guarded shell instead. This is not a general shell sandbox: aliases, arbitrary external scripts, hidden API calls and tools that do not emit PreToolUse remain outside its visibility. A verified parent exists; the model must still read its full body and judge relevance before writing. Actual model termination and installation behavior require host verification.

### Stop verification boundary

Stop never queries the engine and can deny only once until a new non-internal UserPromptSubmit rearms its session latch. Internal `skip_prefixes` inputs do not rearm it; `/nomem` remains a real input. No undocumented request-ID field is assumed: an older host replaying UserPromptSubmit without a stable request identity is treated as another delivery. Real host event dispatch and model termination have not been independently tested.
