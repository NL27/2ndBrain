#!/usr/bin/env python3
"""Turn Cline's auto-approval all the way up ("YOLO mode"), or report its state.

Cline 4.x keeps one state file, ~/.cline/data/globalState.json, shared by the
VS Code extension and the CLI - there is no autoApprovalSettings anywhere in VS
Code's own globalStorage. So this single edit covers both surfaces.

This grants an agent unattended file editing and arbitrary shell execution,
including outside the workspace. That is the point of the mode, but it is worth
being deliberate about: run --check first, and --off to walk it back.
"""
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

STATE = Path.home() / ".cline/data/globalState.json"

# Every gate Cline knows about. False for the two "externally" flags means the
# agent is confined to the workspace; True lets it roam the whole home folder.
FULL = {
    "readFiles": True,
    "readFilesExternally": True,
    "editFiles": True,
    "editFilesExternally": True,
    "executeSafeCommands": True,
    "executeAllCommands": True,
    "useBrowser": True,
    "useMcp": True,
}

SAFE = {
    "readFiles": True,
    "readFilesExternally": False,
    "editFiles": False,
    "editFilesExternally": False,
    "executeSafeCommands": True,
    "executeAllCommands": False,
    "useBrowser": False,
    "useMcp": True,
}


def load() -> dict:
    if not STATE.is_file():
        raise SystemExit(f"Cline state not found: {STATE}")
    return json.loads(STATE.read_text(encoding="utf-8"))


def show(state: dict) -> None:
    settings = state.get("autoApprovalSettings") or {}
    actions = settings.get("actions") or {}
    print(f"enabled     : {settings.get('enabled')}")
    print(f"maxRequests : {settings.get('maxRequests')}")
    for key in FULL:
        print(f"  {key:22} {actions.get(key)}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="report, change nothing")
    parser.add_argument("--off", action="store_true", help="restore conservative defaults")
    parser.add_argument("--max-requests", type=int, default=1000)
    args = parser.parse_args()

    state = load()

    if args.check:
        show(state)
        return 0

    settings = state.setdefault("autoApprovalSettings", {})
    actions = dict(SAFE if args.off else FULL)

    # Keep a copy the first time we touch this, so the original is recoverable.
    backup = STATE.with_suffix(".json.pre-yolo")
    if not backup.exists():
        shutil.copy2(STATE, backup)
        print(f"backed up -> {backup}")

    settings["enabled"] = True
    settings["actions"] = actions
    settings["maxRequests"] = 20 if args.off else args.max_requests
    settings.setdefault("favorites", [])
    settings["version"] = settings.get("version", 15)

    STATE.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    print("auto-approval " + ("reset to safe defaults" if args.off else "set to YOLO"))
    show(state)
    print(
        "\nReload the VS Code window (Cmd+Shift+P -> Developer: Reload Window) "
        "for the extension to pick this up."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
