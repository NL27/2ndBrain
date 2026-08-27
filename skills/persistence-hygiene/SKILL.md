---
name: persistence-hygiene
description: Allow only the known 2nd Brain LaunchAgents and LaunchDaemon. Use when installing login items, launchd plists, cron, or anything that runs after reboot or at 02:00.
---

# Persistence hygiene

Unexpected launchd jobs survive a reboot and outlive a bad overnight run.

## Known labels (only these)

| Label | Kind |
|-------|------|
| `com.dao.secondbrain.network-guard` | LaunchAgent (connection log) |
| `com.dao.secondbrain.overnight-queue` | LaunchAgent (copy queues at 01:50) |
| `com.dao.secondbrain.activity-watch` | LaunchAgent (suspicious activity every 5 min) |
| `com.dao.secondbrain.snitch-keeper` | LaunchAgent + LaunchDaemon (Little Snitch filter every 3h) |
| `com.dao.secondbrain.overnight` | LaunchDaemon (02:00 production) |
| `com.dao.secondbrain.overnight-dev` | LaunchDaemon (02:30 development) |
| `com.dao.secondbrain.radicale` | LaunchAgent (CalDAV on 127.0.0.1:5232) |
| `com.dao.secondbrain.caldav-sync` | LaunchAgent (vault due-tasks → VTODO hourly) |
| 2ⁿᵈ Brain.app Start at Login | SMAppService login item, not launchd |

List: `Resources/sandbox/known-persistence.json`. Check: `python3 scripts/host-integrity.py`.

## Agent rules

1. Do not create LaunchAgents, LaunchDaemons, cron, or login items.
2. Do not `launchctl bootstrap` / `load` except via `defend-setup.sh` / `defend-privileged.sh` when the human is running setup.
3. If you see an extra label matching `secondbrain`, `snapture`, or `dao.secondbrain`, stop overnight work, log path + label in `Notes/Security/`, and tell the human. Do not delete it yourself unless they asked.
4. Uninstall does not remove `secondbrain-agent`; do not invent a new daemon to “replace” it.
