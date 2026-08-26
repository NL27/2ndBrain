---
name: secrets-hygiene
description: Keep API keys, tokens, passwords, and private keys out of the vault, overnight queue, git, chat, and logs. Use when writing notes, OCR, clipboard, MCP local.env, Cline prompts, or anything that might persist a secret.
---

# Secrets hygiene

A secret that lands in `~/Desktop/2nd Brain` is indexed by engraph, searchable in Obsidian, copied to the overnight drop folder, and readable by any agent with vault access. Treat the vault as **public to every tool on this Mac**.

## Where secrets belong

| Secret | Home | Mode |
|--------|------|------|
| n8n MCP bearer | `~/Library/Application Support/SecondBrain/mcp/local.env` | `600` |
| Cloud API keys | macOS Keychain (`com.dao.secondbrain.ai`) | Keychain |
| Cline keys | `~/.cline/` provider config — not the vault | `600` |
| SSH keys | the SSH folder in the home directory — never copy into Shared or the agent home | `600` |

Never: YAML frontmatter, daily notes, OCR sidecars, `Notes/Overnight/queue/`, `/Users/Shared/2nd-Brain-Night`, git commits, Cline chat, n8n Set nodes, allowlist.json.

## Agent rules

1. If the user pastes a token in chat, use it for the current step then **do not** write it to a file. Tell them to put it in Keychain / `local.env` themselves.
2. Quote logs only after redaction (`Bearer <redacted>`, `sk-…` → `sk-<redacted>`).
3. Do not cat `local.env`, dump Keychain, or copy SSH private keys.
4. Before committing, run `python3 scripts/scan-secrets.py` (repo + vault + drop folder). Fix hits; do not print the matching text.
5. Load `n8n-credentials-and-security-official` for any n8n node that talks to a third party.
6. Load `skill-auditor` before installing a new skill from disk or the internet.
7. Load `security-review` before merge and before an overnight job that touches credentials.

## Captures

The app skips filing OCR and clipboard history when the text looks like a key. Screenshots of password fields still go to the vault as **images** — crop tighter, or turn off “File Captures into the Vault” for that shot.
