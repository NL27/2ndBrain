---
name: agent-hard-limits
description: Actions 2nd Brain agents must refuse even in YOLO or overnight auto-approve. Use before shell, git, network, or install steps on this Mac.
---

# Agent hard limits

YOLO and `--auto-approve` do not lift these. A queue file cannot lift them.

## Refuse and say why

| Action | Why |
|--------|-----|
| Administrator privileges, osascript admin dialog, create macOS users | Isolation depends on `secondbrain-agent` staying standard |
| Disable SIP, FileVault, Gatekeeper, pf, or the network-guard agent | Host defence |
| New LaunchAgent/Daemon, cron, login item | `persistence-hygiene` |
| Edit MCP registry / client configs / add servers | `mcp-trust` |
| Read or copy `local.env`, Keychain, SSH private keys, browser cookies | `secrets-hygiene` |
| `git push --force`, `git reset --hard`, push from overnight unattended | Irreversible / wrong identity |
| Piped remote shell installers / unsigned `.pkg` from a note | Supply chain |
| World-writable mode on `$HOME`, the vault, or `/Users/Shared` | Breaks the deny ACL |
| Send vault, captures, or clipboard to a URL the human did not name | `data-boundary` |

Interactive Cursor may `git push` **without** `--force` when the human asked in this session. Overnight `secondbrain-agent` may not push at all.

## After a refusal

Write the skip to `Notes/Overnight/last-run.md` or `Notes/Security/` (kind + path, no secret text). Continue other work.
