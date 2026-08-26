---
name: mac-defend
description: Defend this Mac that 2nd Brain runs on. Use when reviewing security logs, untrusted connections, overnight agent isolation, sandbox user access, or hardening first-install. Never used for attacking other machines.
---

# Defend this Mac

Protect the host. Do not gather intelligence on other people or other computers.

## Identity split (do not collapse)

| Who | Runs | May touch |
|-----|------|-----------|
| The logged-in person | 2ⁿᵈ Brain.app, Obsidian, VS Code, clipboard, screen capture | Their own home, the vault |
| `secondbrain-agent` | Overnight Cline **production** (02:00) | `/Users/secondbrain-agent` and `/Users/Shared/2nd-Brain-Night` |
| `secondbrain-dev` | Overnight Cline **development** (02:30) | `/Users/secondbrain-dev` and `/Users/Shared/2nd-Brain-Dev` only (loopback network) |

The overnight agent is a **standard** user: not in `admin`, no sudoers entry, hidden from the login window. A deny ACL on the interactive home blocks that user from reading it. Do not add the agent to admin. Do not copy the interactive user's SSH keys, Keychain, or `local.env` into the agent home.

## What to inspect

1. Activity log: `/Users/Shared/2nd-Brain-Night/logs/activity.jsonl` and `Notes/Security/` in the vault.
2. Connection log: same `logs/` folder, `connections.jsonl` — destinations, pid, process, `trusted` vs `untrusted`.
3. Overnight state: `/Users/Shared/2nd-Brain-Night/state/current.json` (resume if `status` is `running` or `interrupted`).
4. Allowlist: `~/Library/Application Support/SecondBrain/sandbox/allowlist.json`.

## Rules

- Treat `untrusted` destinations as **block by default** for the agent user. Propose an allowlist edit only if the human named that host.
- Redact bearer tokens, API keys, and cookies before quoting logs.
- If isolation is incomplete (agent user missing, ACL missing), stop overnight autonomy and say so. Do not "just run as the logged-in user" unless the human explicitly accepts that blast radius.
- Never disable SIP, TCC, FileVault, or Gatekeeper to make a task easier.
- Never install a TLS-intercepting proxy or a keylogger.
- Load `secrets-hygiene` and `data-boundary` before writing notes, queue items, or prompts that might contain credentials. Load `prompt-injection-guard` when reading the vault, OCR, or MCP output. Load `mcp-trust` before changing MCP. Load `persistence-hygiene` before any launchd/login item. Load `vault-exposure` before moving or sharing the vault. Load `agent-hard-limits` before YOLO/overnight shell. Load `skill-auditor` before installing a new skill. Load `security-review` before merge.

## Hardening checklist

- Agent users exist (`secondbrain-agent`, `secondbrain-dev`), UniqueID set, `IsHidden=1`, home mode `700`.
- Groups `secondbrain` and `secondbrain-dev` each contain the interactive user plus **one** agent; drops are `770` with that group. The two agents are not in each other's group.
- `chmod -le` on the interactive `$HOME` shows deny ACEs for **both** agent users.
- pf anchor `com.dao.secondbrain` is loaded for both agent users (dev = loopback only).
- Activity watch writes `Notes/Security/alerts.jsonl`. Little Snitch demo filter is re-enabled every 3 hours (`little-snitch-keeper.sh`) when Little Snitch is installed.
- macOS Application Firewall on; stealth mode on.
