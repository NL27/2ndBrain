---
name: overnight-ops
description: Write, route, and review 2nd Brain overnight queue jobs. Use when adding a night task, choosing production vs development, or reading last-run.md in the morning.
---

# Overnight ops

One markdown file = one job. Drop it in the vault; launchd copies it at 01:50.

| Put the file in | Runs as | When | For |
|-----------------|---------|------|-----|
| `Notes/Overnight/queue/` | `secondbrain-agent` | 02:00 | Real work (n8n, allowlisted net) |
| `Notes/Overnight/dev-queue/` | `secondbrain-dev` | 02:30 | Tests only (loopback) |
| `queue/` with `env: development` | moved to dev-queue | 01:50 | Same as dev |

## Queue file shape

```markdown
---
env: production
---
# Short title

Goal in one sentence.
Done when: concrete check (build, workflow id, note path).
Do not: git push, new MCP, secrets, vault zip.
```

Production and development run **until you stop them** (menu **Stop overnight agents**, or `Notes/Overnight/STOP`). A 7-day safety cap remains. 02:00 still starts a session; **Start overnight agents** clears STOP and touches `run-now` (LaunchDaemon WatchPaths after defend has been re-run with admin).

Overnight Cline uses local Ollama: **`qwen2.5-coder:7b`** (code) and **`qwen3.5:4b`** (notes) on `127.0.0.1:11434`. Do not switch to OpenRouter unless the queue file names a cloud model.

Keep `task_plan.md` / `eval.json` **in the Shared worktree**. Production may use `caldav-local` on loopback (Private blue, Professional red; booking cards are times-only).

When one mission cannot be improved, the runner takes the next queue file. If none remain, it refines the last finished mission until you stop.

Optional standing mission: `Notes/Overnight/standing-mission.md` — copied every night, never consumed.

Load first: `thinking-router`, `skill-router`, `autonomous-loop`, `overnight-sandbox`, `agent-hard-limits`. Then only the skills those routers name. Always write the eval contract with `planning-with-files` and `agent-self-evaluation`.

## Morning

Read `Notes/Overnight/last-run.md` (and `last-run-dev.md`). Then `Notes/Security/` if the notification fired. Do not merge or `git push` from the night identity. Promote a successful **dev** pattern to production only when the human says so.
