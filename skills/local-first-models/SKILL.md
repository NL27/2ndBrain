---
name: local-first-models
description: Prefer on-Mac models (oMLX, Ollama) for overnight and vault work; use OpenRouter only when the human asked or local inference cannot do the job. Use when choosing a Cline/OpenRouter profile or sending text to a model.
---

# Local-first models

This Life OS is local-first. Cloud is a fallback, not the default for night jobs.

| Job | Where |
|-----|--------|
| Overnight **development** | Loopback only — oMLX `:8000` / Ollama `:11434` |
| Overnight **production** | Local first; OpenRouter only if the queue file names it |
| Interactive Cursor | Pinned free OpenRouter or local; load `using-openrouter-model-selection` |
| Clipboard / captures | Never to a cloud model unless the human named that file (`data-boundary`) |

## Rules

1. Do not attach the vault, `local.env`, or `Captures/` to a cloud prompt.
2. If local inference is down, write that in `last-run.md` and stop — do not silently switch to a cloud model overnight.
3. Production may call n8n MCP (workflow JSON, credential **IDs**). That is not an excuse to dump notes into OpenRouter.
4. Load `openrouter-models` only when comparing cloud models the human asked for.
