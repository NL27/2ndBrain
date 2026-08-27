---
env: production
tags: [overnight]
---
# Offer privacy

Build `offer_privacy.py` only under `/Users/Shared/2nd-Brain-Night`. Keeper: later it checks booking cards so others see times only — no titles, who, or emails.

Goal: pass times-only fixtures; fail cards that leak a title, attendee, or email.

Done when:
- `python3 -m pytest` exits 0
- Fixtures in this worktree (do not scan the live vault for this job): `ok-times.md`, `leak-title.md`, `leak-email.md`
- `python3 offer_privacy.py dir/` exits 0 on only-ok files; non-zero on leaks; report kinds (`title` / `email` / `attendee`) not the leaked text
- `PATCH.md` says how to run this on `Notes/Calendar/offer-*.md` after you promote it. Do not edit the real repo. Do not git push.

When Done when is met: `eval.json` with `overall` ≥ 4 and `"continue": false`. The runner must take `04-system-improvements.md` next. Do not start it yourself.

Do not: sudo, new LaunchAgent, MCP edits, read local.env, git push, invent a new mission.
