---
name: overnight-sandbox
description: Run the autonomous overnight agent inside the secondbrain-agent or secondbrain-dev sandbox, persist state between wake-ups, and resume from the activity log. Use when scheduling night work, recovering a crashed run, or choosing production vs development queues.
---

# Overnight sandbox

Night jobs are **not** the logged-in GUI session. Production and development are different users, drops, and network rules.

| Env | User | Queue | When | Network |
|-----|------|-------|------|---------|
| production | `secondbrain-agent` | `Notes/Overnight/queue/` | 02:00 | allowlist (n8n, GitHub, …) |
| development | `secondbrain-dev` | `Notes/Overnight/dev-queue/` | 02:30 | loopback only |

Frontmatter `env: development` in a production queue file moves it to the dev queue before the run. `environments.json` is the source of truth.

Development **must not** read `/Users/Shared/2nd-Brain-Night`, the vault, or production MCP. It is for testing overnight automation.

## State file

`{drop}/state/current.json` — same fields as before (`runId`, `status`, `queueItem`, …). Each env has its own file.

## Command shape

`overnight-run.sh` selects the env from `SECONDBRAIN_ENV` and prepends hard limits. Do not strip that prefix.

## After the run

Production summary: `Notes/Overnight/last-run.md`. Development: `last-run-dev.md`. **Do not merge to a personal branch unattended.**

## Stop conditions

- Agent user or deny ACL missing → refuse to start, log `isolation_incomplete`.
- Untrusted network event for this user → abort, `failed`.
- Development process with a non-loopback socket → `activity-watch.py` raises `dev-non-loopback`.
