---
env: production
tags: [overnight]
---
# Queue gate

Build `queue_gate.py` only under `/Users/Shared/2nd-Brain-Night`. Keeper: later it plugs into `reject_item` so bad jobs never start.

Goal: fail a queue note that is missing `Done when`, contains a secret-shaped token, or tells the agent to force-push or pipe a download into a shell.

Done when:
- `python3 -m pytest` exits 0
- Fixtures in this worktree: one good note, one missing Done when, one with a fake token shaped like an API key, one with a force-push command
- `python3 queue_gate.py path.md` exits 0 only for the good note; others exit non-zero and print a kind (`missing-done-when` / `secret` / `hard-limit`) with no secret text
- `PATCH.md` describes the one hook for `reject_item`. Do not edit the real repo. Do not git push.

When Done when is met: `eval.json` with `overall` ≥ 4 and `"continue": false`. The runner must take `03-offer-privacy.md` next. Do not start it yourself.

Do not: sudo, new LaunchAgent, MCP edits, read local.env, git push, invent a new mission.
