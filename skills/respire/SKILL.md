---
name: respire
description: respire (rsrs) local encrypted memory playbook. Automatic per-turn recall is injected with the prompt; **if no injection is present, the hits are off-topic, or the topic involves an earlier project, error, agreement, or date, recall again with different wording (synonyms, hypernyms, English equivalents, one route each); do not repeat only when the injected hits are truly relevant**. Manual recall, remember (judge then store), show/chain to read full text, forget, sync, status; a prompt starting with "记：" is stored directly by the plugin; the "/nomem" prefix disables recall for the turn. Triggers: memory, recall, remember, store memory, forget, sync.
---

# respire · memory playbook

Plugin behavior (Qoder hooks): SessionStart injects a short playbook; every UserPromptSubmit auto-recalls (the engine filters irrelevant queries itself; default is direct output, title tier limited to 5); when a prompt starts with "记：", "存：", or "remember:", the plugin stores it first as a fallback and returns a receipt — **when the receipt includes a provisional title and short id, extract a complete "subject + action + result" sentence from the facts and replace it with `rsrs retitle <short-id> --title` (hard rule; the title is the facade for recall and dedup)**; on Stop, if this turn produced new facts, the plugin nudges once to store; `/nomem` disables recall for the turn.

## Commands

- `rsrs recall "project name + keywords" --limit 5 --json` — **recall before answering, visibly** (an empty injection never means no memory; search manually); on errors, recall by the original error text first; `--titles` returns short id + title only
- `rsrs remember "content" --title "fact sentence" --importance important` — one item per record, judge before storing
- `rsrs show <short-id>` (first 8 chars) reads the full body; `rsrs chain` fetches the whole causal chain
- `rsrs forget <id>` — tombstone delete, propagated by sync
- `rsrs candidates <content>` — pre-store candidate list (merge/attach suggestions)
- `rsrs sync` two-way sync (autosync on); `rsrs status` checks state; `rsrs prompt` prints the full memory workflow
- `rsrs tree/resort/retitle` — maintain the causal tree

## Parsing notes (CLI envelope)

- Every command with `--json` uses one envelope: `status`, `summary`, `items`, `details`, `errors`; **failures also return HTTP 200 with `status:"fail"` and `errors[]`** — check status, not the exit code
- recall scores and entries live in `details[].score` and `details[].entry` (full id; use the first 8 chars as the short id); `items` is only the "score title" line
- Progress goes to stderr; never mix it into JSON with `2>&1`
- remember stores after judgement: `status:"ok"` means written (`summary.id`); `status:"pending"` plus `written:false` means a similar record was found and **nothing was written** — attach with `--parent <id>` or force with `--force`
- The default `trivial` tier goes to the diary area, is excluded from recall and gets its title rewritten to "activity track <date>" — use `--importance important` for factual records

## Red lines

- Never put passwords, ID numbers, phone numbers, card numbers, or private keys into memory bodies or query terms; record only where they are stored — the library is encrypted, but a leaked key exposes everything
- Recall scores are relevance, not confidence; run candidates before storing, prefer edit > merge > store
- Account and sync configuration are outside this plugin: register at rsrs.rs, run `rsrs register` / `rsrs login` locally; the plugin does not handle it
