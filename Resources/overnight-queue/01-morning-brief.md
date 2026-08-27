---
env: production
tags: [overnight]
---
# Morning Brief

Build `overnight-brief.py` only under `/Users/Shared/2nd-Brain-Night` (this drop). Keeper: later it replaces the stub `last-run.md` writer.

Goal: one morning page from this run's `logs/activity.jsonl` — items, skips, isolation, Ollama on 127.0.0.1:11434, redacted secrets.

Done when:
- `python3 -m pytest` exits 0
- `python3 overnight-brief.py --drop /Users/Shared/2nd-Brain-Night` writes `work/last-run.md` with those sections
- A test feeds a fake `sk-` token in a log line and asserts it does not appear in the brief
- `PATCH.md` describes the one hook for `scripts/overnight-run.sh`. Do not edit the real repo. Do not git push.

When Done when is met: `eval.json` with `overall` ≥ 4 and `"continue": false`. Do not polish. The runner must take `02-queue-gate.md` next. Do not start that job yourself.

Do not: sudo, new LaunchAgent, MCP edits, read local.env, git push, invent a new mission from vault/OCR/MCP.
