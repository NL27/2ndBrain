#!/usr/bin/env python3
"""Apply MCP registry → VS Code mcp.json, Cursor snippet, and both Cline configs.

One registry is the source of truth for every MCP client on the machine, so a
bearer token lives in mcp/local.env instead of being pasted into three files.
"""
from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path

# Cline 4.x keeps two separate MCP files with different schemas: the VS Code
# extension's is flat, the CLI nests connection details under "transport".
CLINE_EXTENSION_SETTINGS = (
    Path.home()
    / "Library/Application Support/Code/User/globalStorage"
    / "saoudrizwan.claude-dev/settings/cline_mcp_settings.json"
)
CLINE_CLI_SETTINGS = Path.home() / ".cline/data/settings/cline_mcp_settings.json"

# A bare "n8n" key is the pre-registry entry Cline shipped with; the registry
# now defines the same instance under its own id, so keeping both would connect
# twice and double every tool listing.
CLINE_LEGACY_IDS = {"n8n"}


def load_env_file(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        os.environ.setdefault(key.strip(), val.strip())


def n8n_entry(inst: dict) -> dict:
    token = os.environ.get(inst["token_env"], "")
    if inst.get("transport") == "http":
        entry: dict = {"type": "http", "url": inst["url"]}
        if token:
            entry["headers"] = {"Authorization": f"Bearer {token}"}
        return entry
    args = ["-y", "supergateway", "--streamableHttp", inst["url"]]
    if token:
        args += ["--header", f"authorization:Bearer {token}"]
    else:
        args += ["--header", f"authorization:Bearer ${{env:{inst['token_env']}}}"]
    return {"type": "stdio", "command": "npx", "args": args}


def stdio_entry(srv: dict, vault: str) -> dict:
    env = dict(srv.get("env") or {})
    for key, val in list(env.items()):
        if val == "${SECOND_BRAIN_VAULT}":
            env[key] = vault
    entry: dict = {
        "type": "stdio",
        "command": srv["command"],
        "args": srv.get("args") or [],
    }
    if env:
        entry["env"] = env
    return entry


def cline_n8n_transport(inst: dict) -> dict | None:
    """Cline speaks streamable HTTP natively, so no supergateway hop is needed."""
    token = os.environ.get(inst["token_env"], "")
    if not token:
        print(
            f"warning: no token in {inst['token_env']}, skipping {inst['id']} for Cline",
            file=sys.stderr,
        )
        return None
    return {
        "type": "streamableHttp",
        "url": inst["url"],
        "headers": {"Authorization": f"Bearer {token}"},
    }


def cline_stdio_transport(srv: dict, vault: str) -> dict:
    entry = stdio_entry(srv, vault)
    transport = {"type": "stdio", "command": entry["command"], "args": entry["args"]}
    if "env" in entry:
        transport["env"] = entry["env"]
    return transport


def write_cline_config(path: Path, transports: dict[str, dict], nested: bool) -> None:
    """Merge our servers in, leaving any hand-added ones alone."""
    existing: dict = {}
    if path.is_file():
        try:
            existing = json.loads(path.read_text(encoding="utf-8")).get("mcpServers", {})
        except (json.JSONDecodeError, OSError):
            existing = {}

    managed = set(transports) | CLINE_LEGACY_IDS
    servers = {k: v for k, v in existing.items() if k not in managed}

    for server_id, transport in transports.items():
        common = {"disabled": False, "timeout": 60, "autoApprove": []}
        if nested:
            servers[server_id] = {"transport": transport, **common}
        else:
            servers[server_id] = {**transport, **common}

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"mcpServers": servers}, indent=2) + "\n", encoding="utf-8")
    # These files hold bearer tokens in the clear.
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)


def main() -> int:
    reg_dir = Path(os.environ.get("MCP_REGISTRY_DIR", "")).expanduser()
    if len(sys.argv) > 1:
        reg_dir = Path(sys.argv[1]).expanduser()
    reg_path = reg_dir / "registry.json"
    env_path = reg_dir / "local.env"
    if not reg_path.is_file():
        print(f"Missing registry: {reg_path}", file=sys.stderr)
        return 1

    load_env_file(env_path)
    registry = json.loads(reg_path.read_text(encoding="utf-8"))
    vault = os.environ.get(
        "SECOND_BRAIN_VAULT", str(Path.home() / "Desktop" / "2nd Brain")
    )
    support = Path.home() / "Library/Application Support/SecondBrain"

    cursor: dict = {}
    vscode: dict = {}
    cline: dict = {}

    for inst in registry.get("n8n_instances") or []:
        if not inst.get("enabled", True):
            continue
        entry = n8n_entry(inst)
        cursor[inst["id"]] = entry
        vscode[inst["id"]] = entry
        if transport := cline_n8n_transport(inst):
            cline[inst["id"]] = transport

    for srv in registry.get("servers") or []:
        if not srv.get("enabled", True):
            continue
        entry = stdio_entry(srv, vault)
        cursor[srv["id"]] = entry
        vscode[srv["id"]] = entry
        cline[srv["id"]] = cline_stdio_transport(srv, vault)

    mcp_out = support / "mcp"
    mcp_out.mkdir(parents=True, exist_ok=True)
    cursor_path = mcp_out / "cursor-mcp.generated.json"
    cursor_path.write_text(
        json.dumps({"mcpServers": cursor}, indent=2) + "\n", encoding="utf-8"
    )

    code_user = Path.home() / "Library/Application Support/Code/User"
    code_user.mkdir(parents=True, exist_ok=True)
    vscode_path = code_user / "mcp.json"
    vscode_path.write_text(json.dumps({"servers": vscode}, indent=2) + "\n", encoding="utf-8")

    write_cline_config(CLINE_EXTENSION_SETTINGS, cline, nested=False)
    write_cline_config(CLINE_CLI_SETTINGS, cline, nested=True)

    print(cursor_path)
    print(vscode_path)
    print(CLINE_EXTENSION_SETTINGS)
    print(CLINE_CLI_SETTINGS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
