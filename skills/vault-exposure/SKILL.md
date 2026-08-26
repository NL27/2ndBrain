---
name: vault-exposure
description: Keep the 2nd Brain vault off iCloud Desktop, shared folders, AirDrop, and zip exports. Use when moving the vault, enabling iCloud Drive, Time Machine, or sharing captures.
---

# Vault exposure

`~/Desktop/2nd Brain` holds screenshots, OCR, recordings, and notes. Treat it as local-only.

## Must stay off the public internet

- Do not put the vault in iCloud Desktop & Documents. If Desktop is iCloud-synced, tell the human to turn that off or move the vault to a non-synced folder and update `SECOND_BRAIN_VAULT`.
- Do not AirDrop, Messages, or email a zip of the vault.
- Do not share the folder in Finder, Dropbox, Google Drive, or git (the **app** repo is not the vault).
- Do not add the vault as a public Obsidian Publish / Sync remote unless the human opts in knowing captures go with it.

## Backups

Time Machine of an encrypted Mac (FileVault) is fine. Unencrypted disk images or a USB copy of `Captures/` are not. Do not copy `mcp/local.env` into a backup zip.

## Capture hygiene

Password-manager windows and 1Password still photograph as PNGs. Crop tight or disable “File Captures into the Vault” for that shot. Load `secrets-hygiene`.
