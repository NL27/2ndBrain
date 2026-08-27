#!/usr/bin/env python3
"""Connect a vault to Obsidian: register it, install community plugins, configure them.

Plugin IDs are resolved against Obsidian's official community registry rather
than hardcoded, so a renamed or moved plugin is reported instead of silently
installing nothing.
"""
from __future__ import annotations

import argparse
import json
import secrets
import shutil
import time
import urllib.error
import urllib.request
from pathlib import Path

REGISTRY_URL = (
    "https://raw.githubusercontent.com/obsidianmd/obsidian-releases"
    "/master/community-plugins.json"
)

# Display name -> preferred plugin id. The id is a hint: if it is missing from
# the registry we fall back to matching on the name, so a re-id'd plugin still
# resolves.
WANTED: list[tuple[str, str]] = [
    ("AI Providers", "ai-providers"),
    ("Advanced Tables", "table-editor-obsidian"),
    ("Advanced URI", "obsidian-advanced-uri"),
    ("Calendar", "calendar"),
    ("Dataview", "dataview"),
    ("Full Calendar", "obsidian-full-calendar"),
    ("Homepage", "homepage"),
    ("Kanban", "obsidian-kanban"),
    ("Keep the Rhythm", "keep-the-rhythm"),
    ("Linter", "obsidian-linter"),
    ("Local GPT", "local-gpt"),
    ("Natural Language Dates", "nldates-obsidian"),
    ("Omnisearch", "omnisearch"),
    ("Outliner", "obsidian-outliner"),
    ("Periodic Notes", "periodic-notes"),
    ("QuickAdd", "quickadd"),
    ("Readability Score", "readability-score"),
    ("Reading Time", "obsidian-reading-time"),
    ("Recent Files", "recent-files-obsidian"),
    ("Remaining reading time", "remaining-reading-time"),
    ("Reminder", "obsidian-reminder-plugin"),
    ("Remember cursor position", "remember-cursor-position"),
    ("Soundscapes", "soundscapes"),
    ("Tag Wrangler", "tag-wrangler"),
    ("Tasks", "obsidian-tasks-plugin"),
    ("Templater", "templater-obsidian"),
]

OBSIDIAN_PREFS = Path.home() / "Library/Application Support/obsidian/obsidian.json"


def fetch(url: str, timeout: int = 60) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "2ndBrain-setup"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


# --- vault registration ----------------------------------------------------


def register_vault(vault: Path) -> str:
    """Add the vault to Obsidian's vault list, leaving existing vaults alone."""
    prefs: dict = {}
    if OBSIDIAN_PREFS.is_file():
        try:
            prefs = json.loads(OBSIDIAN_PREFS.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            prefs = {}

    vaults = prefs.setdefault("vaults", {})
    target = str(vault)
    for key, entry in vaults.items():
        if entry.get("path") == target:
            return f"already registered ({key})"

    # Obsidian keys vaults by a random 16-hex id.
    key = secrets.token_hex(8)
    vaults[key] = {"path": target, "ts": int(time.time() * 1000)}
    OBSIDIAN_PREFS.parent.mkdir(parents=True, exist_ok=True)
    OBSIDIAN_PREFS.write_text(json.dumps(prefs), encoding="utf-8")
    return f"registered as {key}"


# --- plugin installation ---------------------------------------------------


def load_registry() -> list[dict]:
    return json.loads(fetch(REGISTRY_URL).decode("utf-8"))


def resolve(registry: list[dict], name: str, preferred_id: str) -> dict | None:
    by_id = {entry["id"]: entry for entry in registry}
    if preferred_id in by_id:
        return by_id[preferred_id]
    for alt in {"obsidian-full-calendar": ("obsidian-full-calendar-remastered",)}.get(
        preferred_id, ()
    ):
        if alt in by_id:
            return by_id[alt]
    wanted = name.casefold().strip()
    for entry in registry:
        if entry.get("name", "").casefold().strip() == wanted:
            return entry
    return None


def install_plugin(vault: Path, entry: dict) -> tuple[str, str]:
    """Drop manifest.json / main.js / styles.css into .obsidian/plugins/<id>/.

    Returns the id Obsidian will actually load, which is not always the id in
    the registry: Calendar's latest release, for instance, ships a manifest
    declaring `calendar-beta`. Obsidian refuses to load a plugin whose folder
    name disagrees with its manifest, so we follow the manifest.
    """
    plugin_id = entry["id"]
    repo = entry["repo"]
    target = vault / ".obsidian" / "plugins" / plugin_id
    if (target / "main.js").is_file() and (target / "manifest.json").is_file():
        try:
            manifest = json.loads((target / "manifest.json").read_text())
            return manifest.get("id") or plugin_id, manifest.get("version", "?")
        except (json.JSONDecodeError, OSError):
            pass
    target.mkdir(parents=True, exist_ok=True)
    base = f"https://github.com/{repo}/releases/latest/download"

    # main.js and manifest.json are mandatory for a plugin to load; styles.css
    # is optional and plenty of plugins ship without one.
    for filename in ("manifest.json", "main.js"):
        try:
            (target / filename).write_bytes(fetch(f"{base}/{filename}"))
        except urllib.error.HTTPError as exc:
            if filename == "manifest.json":
                # Some releases omit the manifest; the branch copy is equivalent.
                raw = f"https://raw.githubusercontent.com/{repo}/HEAD/manifest.json"
                try:
                    (target / filename).write_bytes(fetch(raw))
                    continue
                except urllib.error.HTTPError:
                    pass
            raise RuntimeError(f"{filename} -> HTTP {exc.code}") from exc

    try:
        (target / "styles.css").write_bytes(fetch(f"{base}/styles.css"))
    except urllib.error.HTTPError:
        pass

    try:
        manifest = json.loads((target / "manifest.json").read_text())
        version = manifest.get("version", "?")
        actual_id = manifest.get("id") or plugin_id
    except (json.JSONDecodeError, OSError):
        return plugin_id, "?"

    if actual_id != plugin_id:
        renamed = target.parent / actual_id
        if renamed.exists():
            shutil.rmtree(renamed)
        target.rename(renamed)

    return actual_id, version


# --- configuration ---------------------------------------------------------


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def merge_json(path: Path, updates: dict) -> None:
    """Update keys without discarding settings the user already changed."""
    current: dict = {}
    if path.is_file():
        try:
            current = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            current = {}
    current.update(updates)
    write_json(path, current)


def configure(vault: Path, installed: list[str], omlx: str, ollama: str) -> None:
    config = vault / ".obsidian"

    def plugin_dir(*candidates: str) -> Path | None:
        """Resolve a settings path by id, tolerating suffixes like `-beta`."""
        for candidate in candidates:
            for plugin_id in installed:
                if plugin_id == candidate or plugin_id.startswith(f"{candidate}-"):
                    return config / "plugins" / plugin_id
        return None

    merge_json(
        config / "app.json",
        {
            "attachmentFolderPath": "Attachments",
            "newFileLocation": "folder",
            "newFileFolderPath": "Inbox",
            "alwaysUpdateLinks": True,
            "useMarkdownLinks": False,
            "showUnsupportedFiles": True,
            # Keep the agent skill docs out of search, graph and quick switcher.
            "userIgnoreFilters": ["Agent Skills/"],
        },
    )

    write_json(config / "community-plugins.json", installed)

    if target := plugin_dir("periodic-notes"):
        merge_json(
            target / "data.json",
            {
                "showGettingStartedBanner": False,
                "hasMigratedDailyNoteSettings": True,
                "hasMigratedWeeklyNoteSettings": True,
                "daily": {
                    "enabled": True,
                    "format": "YYYY-MM-DD",
                    "folder": "Daily",
                    "template": "Templates/Daily",
                },
                "weekly": {
                    "enabled": True,
                    "format": "gggg-[W]ww",
                    "folder": "Daily/Weekly",
                    "template": "",
                },
            },
        )

    if target := plugin_dir("calendar"):
        merge_json(
            target / "data.json",
            {"shouldConfirmBeforeCreate": False, "weekStart": "monday", "showWeeklyNote": True},
        )

    if target := plugin_dir("obsidian-tasks-plugin"):
        merge_json(
            target / "data.json",
            {"globalFilter": "", "setDoneDate": True, "autoSuggestInEditor": True},
        )

    if target := plugin_dir("templater-obsidian"):
        merge_json(
            target / "data.json",
            {
                "templates_folder": "Templates",
                "trigger_on_file_creation": True,
                "enable_folder_templates": False,
            },
        )

    if target := plugin_dir("omnisearch"):
        merge_json(
            target / "data.json",
            {"ignoreDiacritics": True, "PDFIndexing": True, "ignorePattern": "Agent Skills/*"},
        )

    # Local, private inference: both endpoints are OpenAI-compatible.
    if target := plugin_dir("ai-providers"):
        merge_json(
            target / "data.json",
            {
                "providers": [
                    {
                        "id": "omlx-local",
                        "name": "oMLX (local)",
                        "type": "openai",
                        "url": omlx,
                        "apiKey": "",
                    },
                    {
                        "id": "ollama-local",
                        "name": "Ollama (local)",
                        "type": "ollama",
                        "url": ollama,
                        "apiKey": "",
                    },
                ]
            },
        )

    if target := plugin_dir("local-gpt"):
        merge_json(
            target / "data.json",
            {
                "defaultProvider": "ollama",
                "providers": {
                    "ollama": {"url": ollama, "model": "qwen3.5:4b"},
                },
            },
        )

    # Dataview JS can run code from notes — vault text is untrusted (prompt-injection-guard).
    if target := plugin_dir("dataview"):
        merge_json(
            target / "data.json",
            {
                "enableDataviewJs": False,
                "enableInlineDataviewJs": False,
                "enableInlineDataview": True,
                "warnOnEmptyResult": True,
            },
        )

    if target := plugin_dir("obsidian-full-calendar"):
        merge_json(
            target / "data.json",
            {
                "calendarSources": [
                    {
                        "type": "local",
                        "color": "#0A84FF",
                        "name": "Private",
                        "directory": "Notes/Calendar/private",
                    },
                    {
                        "type": "local",
                        "color": "#FF453A",
                        "name": "Professional",
                        "directory": "Notes/Calendar/professional",
                    },
                    {"type": "dailynote", "color": "#8E8E93", "heading": "Log"},
                ]
            },
        )

    if target := plugin_dir("nldates-obsidian"):
        merge_json(
            target / "data.json",
            {"autosuggestToggleLink": True, "autocompleteTriggerPhrase": "@"},
        )

    if target := plugin_dir("homepage"):
        merge_json(
            target / "data.json",
            {
                "openOnStartup": True,
                "hasRibbonIcon": True,
                "openMode": "Replace all open notes",
                "value": "Notes/Dashboard",
                "kind": "file",
            },
        )

    if target := plugin_dir("obsidian-linter"):
        merge_json(target / "data.json", {"lintOnSave": False, "displayChanged": True})

    if target := plugin_dir("obsidian-reminder-plugin"):
        merge_json(
            target / "data.json",
            {"reminderTime": "09:00", "useSystemNotification": True},
        )

    if target := plugin_dir("recent-files-obsidian"):
        merge_json(target / "data.json", {"maxLength": 50, "omitFolders": ["Agent Skills"]})


DAILY_TEMPLATE = """---
created: <% tp.date.now("YYYY-MM-DD") %>
tags: [daily]
---
# <% tp.date.now("dddd, D MMMM YYYY") %>

## Focus

## Due today or sooner

```tasks
not done
due before <% tp.date.now("YYYY-MM-DD", 1) %>
sort by due
```

## Overdue

```tasks
not done
due before <% tp.date.now("YYYY-MM-DD") %>
sort by due
```

## Captured today

Everything the app filed today, by tag: [[#capture]]

## Notes

## Log
"""

OVERNIGHT_TEMPLATE = """---
env: production
tags: [overnight]
---
# <% tp.file.title %>

Goal in one sentence.

Done when:

Do not: git push, new MCP, secrets, vault zip.
"""

EVENT_PRIVATE = """---
title: <% tp.file.title %>
allDay: false
date: <% tp.date.now("YYYY-MM-DD") %>
startTime: 18:00
endTime: 19:00
type: single
calendar: private
tags: [calendar, private]
---
Location:

Who (only if they may join):
"""

EVENT_PROFESSIONAL = """---
title: <% tp.file.title %>
allDay: false
date: <% tp.date.now("YYYY-MM-DD") %>
startTime: 09:00
endTime: 09:30
type: single
calendar: professional
tags: [calendar, work]
---
Busy block for work. Title stays on this Mac.
"""

DASHBOARD = """---
tags: [dashboard]
---
# Dashboard

Local graph. Queries do not use Dataview JS.

## Due

```tasks
not done
due before in 7 days
sort by due
```

## Overnight queue

```dataview
LIST FROM "Notes/Overnight/queue"
```

## Standing mission

[[Notes/Overnight/standing-mission]]

## Last night

![[Notes/Overnight/last-run]]

## Calendars

- Private (blue): `Notes/Calendar/private`
- Professional (red): `Notes/Calendar/professional`
- Apple Calendar talks to local CalDAV — see [[Notes/Calendar/CalDAV]]
"""


def write_if_missing(path: Path, body: str) -> None:
    if path.is_file():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")


def write_templates(vault: Path) -> None:
    write_if_missing(vault / "Templates" / "Daily.md", DAILY_TEMPLATE)
    write_if_missing(vault / "Templates" / "Overnight job.md", OVERNIGHT_TEMPLATE)
    write_if_missing(vault / "Templates" / "Event private.md", EVENT_PRIVATE)
    write_if_missing(vault / "Templates" / "Event professional.md", EVENT_PROFESSIONAL)
    write_if_missing(vault / "Notes" / "Dashboard.md", DASHBOARD)
    (vault / "Notes" / "Calendar" / "private").mkdir(parents=True, exist_ok=True)
    (vault / "Notes" / "Calendar" / "professional").mkdir(parents=True, exist_ok=True)


# --- entry point -----------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vault", required=True)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--omlx", default="http://127.0.0.1:8000/v1")
    parser.add_argument("--ollama", default="http://127.0.0.1:11434/v1")
    args = parser.parse_args()

    vault = Path(args.vault).expanduser()
    plugins_dir = vault / ".obsidian" / "plugins"

    if args.check:
        present = sorted(p.name for p in plugins_dir.glob("*") if p.is_dir())
        registered = False
        if OBSIDIAN_PREFS.is_file():
            try:
                prefs = json.loads(OBSIDIAN_PREFS.read_text(encoding="utf-8"))
                registered = any(
                    entry.get("path") == str(vault)
                    for entry in prefs.get("vaults", {}).values()
                )
            except json.JSONDecodeError:
                pass
        print(f"registered={registered} plugins={len(present)}/{len(WANTED)}")
        for name in present:
            print(f"  have {name}")
        return 0 if registered and len(present) >= len(WANTED) else 1

    print(f"vault: {register_vault(vault)}")

    registry = load_registry()
    print(f"registry: {len(registry)} community plugins")

    installed: list[str] = []
    unresolved: list[str] = []
    failed: list[str] = []

    for name, preferred_id in WANTED:
        entry = resolve(registry, name, preferred_id)
        if entry is None:
            unresolved.append(name)
            print(f"  UNRESOLVED  {name}")
            continue
        try:
            plugin_id, version = install_plugin(vault, entry)
        except Exception as exc:  # noqa: BLE001 - report and keep going
            failed.append(f"{name} ({exc})")
            print(f"  FAILED      {name}: {exc}")
            continue
        installed.append(plugin_id)
        note = "" if plugin_id == entry["id"] else f" (manifest id, registry says {entry['id']})"
        print(f"  installed   {plugin_id} {version}  [{entry['repo']}]{note}")

    configure(vault, installed, args.omlx, args.ollama)
    write_templates(vault)

    print(f"enabled {len(installed)}/{len(WANTED)} plugins")
    if unresolved:
        print("unresolved: " + ", ".join(unresolved))
    if failed:
        print("failed: " + ", ".join(failed))
    return 0 if not unresolved and not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
