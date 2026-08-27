---
env: production
tags: [overnight]
---
# System improvements

Think about how to improve **this** 2nd Brain stack as it exists: overnight until-stop, production vs development sandboxes, Ollama Qwen, local CalDAV, queue gate, offer privacy, morning brief, vault-out filing, hard limits. Then list tools or hosts it still lacks.

Write only under this drop, then copy keepers to `work/vault-out/Notes/Overnight/ideas/` so the interactive sync can file them into the vault.

Done when `work/vault-out/Notes/Overnight/ideas/system-improvements.md` exists with:
- What already works (facts from this drop: queue files, last-run, Ollama `:11434`, Radicale `:5232` if it answers)
- Concrete improvement ideas (scripts, tests, UX) — each one slice, with a Done when
- Tools it would still need (name, why, whether it is loopback or allowlisted). **Do not install them. Do not add MCP servers, LaunchAgents, or pf rules.** The human decides.
- What you must not recommend: sudo, SIP/FileVault off, git push, secrets in the vault

When the note is written: `eval.json` with `overall` ≥ 4 and `"continue": false`. The runner must take `05-holistic-health.md` next. Do not start the health app in this job. Do not invent a new overnight identity.

Do not: sudo, new LaunchAgent, MCP edits, read local.env, git push, send vault notes to a URL the human did not name.
