---
name: vault-cadence
description: File overnight output and captures into the 2nd Brain vault without polluting Daily notes or leaking secrets. Use when writing Inbox/Notes, updating Daily.md, or asking engraph to reindex.
---

# Vault cadence

The vault is `~/Desktop/2nd Brain`. Obsidian is the graph; VS Code is the folders; engraph is search. Overnight agents write under Shared `work/`, then a **human** (or a queue item that only files) moves keepers into the vault.

## Where things go

| Kind | Path |
|------|------|
| Quick capture | `Inbox/` |
| Lasting note | `Notes/` with tags |
| Day log | `Daily/YYYY-MM-DD.md` (append a short bullet, do not paste logs) |
| Night result | `Notes/Overnight/last-run.md` — already written by the runner |
| Dashboard | `Notes/Dashboard.md` (Dataview + Tasks; no Dataview JS) |
| Private event note | `Notes/Calendar/private/` (blue in Full Calendar) |
| Work event note | `Notes/Calendar/professional/` (red; work sees Busy only on CalDAV) |
| Security | `Notes/Security/` — kind + path only |

## Rules

1. Load `secrets-hygiene` before any write. No tokens in frontmatter.
2. After an external edit, engraph `reindex_file` on that path — do not reindex the whole vault unless asked.
3. Prefer tags the human already uses. Do not invent a second PARA tree.
4. Screenshots of password fields stay images — crop or skip filing (`vault-exposure`).
5. Overnight **development** must not write into the interactive vault.
