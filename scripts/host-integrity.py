#!/usr/bin/env python3
"""Report unexpected launchd jobs and MCP servers that are not in the registry.

Prints path + kind only. Never dumps tokens, env files, or plist ProgramArguments
that might contain secrets.
"""
from __future__ import annotations

import json
import os
import plistlib
import sys
from pathlib import Path

HOME = Path.home()
SUPPORT = HOME / "Library/Application Support/SecondBrain"
VAULT = Path(os.environ.get("SECOND_BRAIN_VAULT", str(HOME / "Desktop/2nd Brain")))
KNOWN_PATHS = [
    Path(__file__).resolve().parent.parent / "Resources/sandbox/known-persistence.json",
    SUPPORT / "sandbox/known-persistence.json",
]


def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def known_persistence() -> dict:
    for p in KNOWN_PATHS:
        data = load_json(p)
        if isinstance(data, dict):
            return data
    return {
        "launch_agents": [
            "com.dao.secondbrain.network-guard",
            "com.dao.secondbrain.overnight-queue",
            "com.dao.secondbrain.activity-watch",
            "com.dao.secondbrain.snitch-keeper",
            "com.dao.secondbrain.radicale",
            "com.dao.secondbrain.caldav-sync",
        ],
        "launch_daemons": [
            "com.dao.secondbrain.overnight",
            "com.dao.secondbrain.overnight-dev",
            "com.dao.secondbrain.snitch-keeper",
        ],
        "label_prefixes_watch": ["com.dao.secondbrain", "com.snapture", "secondbrain"],
    }


def label_from_plist(path: Path):
    try:
        data = plistlib.loads(path.read_bytes())
    except Exception:
        return None
    label = data.get("Label")
    return str(label) if label else None


def watched(label: str, prefixes: list[str]) -> bool:
    low = label.lower()
    return any(low.startswith(p.lower()) or p.lower() in low for p in prefixes)


def icloud_desktop() -> bool:
    from subprocess import run

    r = run(
        ["defaults", "read", "com.apple.finder", "FXICloudDriveDesktop"],
        capture_output=True,
        text=True,
    )
    if r.returncode == 0 and r.stdout.strip().lower() in {"1", "true"}:
        return True
    xa = run(["/usr/bin/xattr", "-l", str(HOME / "Desktop")], capture_output=True, text=True)
    return "icloud" in xa.stdout.lower()


def mcp_ids_from_registry() -> set[str]:
    reg = VAULT / "Agent Skills/mcp/registry.json"
    data = load_json(reg)
    ids: set[str] = set()
    if not isinstance(data, dict):
        return ids
    for row in data.get("n8n_instances") or []:
        if row.get("id"):
            ids.add(str(row["id"]))
    for row in data.get("servers") or []:
        if row.get("id"):
            ids.add(str(row["id"]))
    return ids


def mcp_ids_from_clients() -> dict[str, set[str]]:
    # Only clients 2nd Brain syncs. Cursor's ~/.cursor/mcp.json is out of scope
    # (hand-added servers there are expected).
    paths = {
        "cline-cli": HOME / ".cline/data/settings/cline_mcp_settings.json",
        "cline-ext": HOME
        / "Library/Application Support/Code/User/globalStorage"
        / "saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
        "vscode": HOME / "Library/Application Support/Code/User/mcp.json",
    }
    found: dict[str, set[str]] = {}
    for name, path in paths.items():
        data = load_json(path)
        if not isinstance(data, dict):
            continue
        servers = data.get("mcpServers") or data.get("servers") or data
        if isinstance(servers, dict):
            found[name] = {k for k in servers.keys() if k != "mcpServers"}
    return found


def main() -> int:
    known = known_persistence()
    agents = set(known.get("launch_agents") or [])
    daemons = set(known.get("launch_daemons") or [])
    prefixes = list(known.get("label_prefixes_watch") or [])
    hits = 0

    agent_dir = HOME / "Library/LaunchAgents"
    daemon_dir = Path("/Library/LaunchDaemons")
    present: set[str] = set()
    extras: list[tuple[str, str]] = []

    for folder, expected in ((agent_dir, agents), (daemon_dir, daemons)):
        if not folder.is_dir():
            continue
        for plist in folder.glob("*.plist"):
            label = label_from_plist(plist) or plist.stem
            present.add(label)
            if label in expected:
                continue
            if watched(label, prefixes):
                extras.append((label, str(plist)))

    missing = (agents | daemons) - present
    for label in sorted(missing):
        print(f"missing-persistence  {label}")
    for label, path in extras:
        print(f"unexpected-persistence  {label}  {path}")
        hits += 1

    if icloud_desktop():
        print("vault-icloud-desktop  ~/Desktop may sync to iCloud — vault captures would leave the Mac")

    registry = mcp_ids_from_registry()
    if registry:
        for client, ids in mcp_ids_from_clients().items():
            extra = ids - registry - {"mcpServers", "n8n"}
            for sid in sorted(extra):
                print(f"mcp-hand-added  {client}  {sid}")

    if hits == 0:
        print("host integrity: no unexpected 2nd Brain launchd jobs")
    return 0 if hits == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
