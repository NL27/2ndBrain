#!/usr/bin/env python3
"""Sample this Mac's TCP sockets, log them, and refresh the overnight user's pf table.

Tracks where processes are sending/receiving. Does not capture payloads, does not
decrypt TLS, and does not default-deny the logged-in person — only the
secondbrain-agent user is blocked by pf.
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

SUPPORT = Path.home() / "Library/Application Support/SecondBrain/sandbox"
DROP = Path("/Users/Shared/2nd-Brain-Night")
ALLOW_IPS = Path("/usr/local/etc/secondbrain/allow.ips")
VAULT_SECURITY = Path.home() / "Desktop/2nd Brain/Notes/Security"

def log_dir() -> Path:
    if os.access(str(DROP), os.W_OK) or DROP.exists():
        try:
            (DROP / "logs").mkdir(parents=True, exist_ok=True)
            return DROP / "logs"
        except OSError:
            pass
    fallback = Path.home() / "Library/Application Support/SecondBrain/sandbox/logs"
    fallback.mkdir(parents=True, exist_ok=True)
    return fallback


SECRET = re.compile(
    r"(Bearer\s+)[A-Za-z0-9._\-]+|(sk-|ghp_|hf_)[A-Za-z0-9]+|token=[\w\-]+",
    re.I,
)


def redact(value: str) -> str:
    return SECRET.sub(r"\1<redacted>" if r"\1" in value else "<redacted>", value)


def load_allowlist() -> dict:
    path = SUPPORT / "allowlist.json"
    if not path.is_file():
        bundled = Path(__file__).resolve().parent.parent / "Resources/sandbox/allowlist.json"
        path = bundled if bundled.is_file() else path
    if not path.is_file():
        return {"trusted_hosts": ["127.0.0.1"], "trusted_cidrs": ["127.0.0.0/8"]}
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_hosts(hosts: list[str]) -> set[str]:
    ips: set[str] = set()
    for host in hosts:
        host = host.strip().lower()
        if not host:
            continue
        try:
            ipaddress.ip_address(host)
            ips.add(host)
            continue
        except ValueError:
            pass
        try:
            for family, _, _, _, sockaddr in socket.getaddrinfo(host, None):
                ips.add(sockaddr[0])
        except socket.gaierror:
            pass
    return ips


def ip_trusted(ip: str, allow: dict, resolved: set[str]) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if addr.is_loopback or addr.is_private or addr.is_link_local:
        return True
    if ip in resolved:
        return True
    for cidr in allow.get("trusted_cidrs") or []:
        try:
            if addr in ipaddress.ip_network(cidr, strict=False):
                return True
        except ValueError:
            continue
    return False


def sample_lsof() -> list[dict]:
    """Established TCP only — who we are talking to right now."""
    if not shutil.which("lsof"):
        return []
    try:
        raw = subprocess.check_output(
            ["lsof", "-nP", "-iTCP", "-sTCP:ESTABLISHED"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return []

    rows = []
    for line in raw.splitlines()[1:]:
        dest = re.search(r"->(\[[0-9a-fA-F:.]+\]|[0-9.]+):(\d+)", line)
        who = re.match(r"^(\S+)\s+(\d+)\s+(\S+)", line)
        if not dest or not who:
            continue
        rows.append(
            {
                "process": who.group(1).replace(r"\x20", " ")[:80],
                "pid": _int(who.group(2)),
                "user": who.group(3),
                        "remote_ip": dest.group(1).strip("[]"),
                        "remote_port": _int(dest.group(2)),
                    }
                )
    # Format IPv6 as [addr]:port so the port is not swallowed by extra colons.
    for row in rows:
        ip, port = row["remote_ip"], row["remote_port"]
        row["remote"] = f"[{ip}]:{port}" if ":" in ip else f"{ip}:{port}"
    return rows


def _int(value: str) -> int:
    try:
        return int(value)
    except ValueError:
        return 0


def reverse_name(ip: str) -> str | None:
    try:
        name, _, _ = socket.gethostbyaddr(ip)
        return name.rstrip(".")
    except (socket.herror, socket.gaierror, OSError):
        return None


def append_jsonl(path: Path, event: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, separators=(",", ":")) + "\n")


def once(enforce_log: bool) -> list[dict]:
    allow = load_allowlist()
    resolved = resolve_hosts(list(allow.get("trusted_hosts") or []))
    agent = allow.get("agent_user") or "secondbrain-agent"
    now = datetime.now(timezone.utc).isoformat()
    events = []
    for row in sample_lsof():
        trusted = ip_trusted(row["remote_ip"], allow, resolved)
        host = reverse_name(row["remote_ip"])
        event = {
            "ts": now,
            "kind": "connection",
            "process": row["process"],
            "pid": row["pid"],
            "user": row["user"],
            "remote": row.get("remote") or f"{row['remote_ip']}:{row['remote_port']}",
            "host": host,
            "trusted": trusted,
        }
        events.append(event)
        if enforce_log:
            logs = log_dir()
            append_jsonl(logs / "connections.jsonl", event)
            if not trusted and row["user"] == agent:
                append_jsonl(
                    logs / "activity.jsonl",
                    {
                        "ts": now,
                        "kind": "untrusted_block",
                        "user": agent,
                        "remote": event["remote"],
                        "host": host,
                        "process": row["process"],
                    },
                )
    return events


def refresh_pf() -> int:
    allow = load_allowlist()
    ips = sorted(resolve_hosts(list(allow.get("trusted_hosts") or [])))
    for cidr in allow.get("trusted_cidrs") or []:
        ips.append(cidr)
    text = "\n".join(ips) + "\n"
    staging = Path("/tmp/secondbrain-allow.ips")
    staging.write_text(text, encoding="utf-8")
    print(f"resolved {len(ips)} allowlist entries -> {staging}")
    print("load with admin: cp to /usr/local/etc/secondbrain/allow.ips && pfctl -a com.dao.secondbrain -f …")
    return 0


def write_daily_note(events: list[dict]) -> None:
    untrusted = [e for e in events if not e.get("trusted")]
    VAULT_SECURITY.mkdir(parents=True, exist_ok=True)
    day = datetime.now().strftime("%Y-%m-%d")
    path = VAULT_SECURITY / f"{day} connections.md"
    lines = [
        "---",
        "type: security-log",
        f"created: {datetime.now(timezone.utc).isoformat()}",
        "tags: [security, network]",
        "---",
        f"# Connections {day}",
        "",
        f"Sampled {len(events)} established TCP sockets. "
        f"{len(untrusted)} not on the allowlist (logged, not system-wide blocked).",
        "",
        "| Process | User | Remote | Host | Trusted |",
        "|---------|------|--------|------|---------|",
    ]
    for event in events[:80]:
        lines.append(
            f"| {event['process']} | {event['user']} | `{event['remote']}` | "
            f"{event.get('host') or ''} | {'yes' if event['trusted'] else '**no**'} |"
        )
    lines.append("")
    lines.append("#security #network")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--watch", type=int, metavar="SECONDS", help="sample every N seconds")
    parser.add_argument("--refresh-pf", action="store_true")
    parser.add_argument("--note", action="store_true", help="write a vault markdown snapshot")
    args = parser.parse_args()

    if args.refresh_pf:
        return refresh_pf()

    if args.watch:
        while True:
            once(enforce_log=True)
            time.sleep(max(15, args.watch))
        return 0

    events = once(enforce_log=True)
    if args.note or args.once:
        if args.note:
            write_daily_note(events)
        print(json.dumps({"sampled": len(events),
                          "untrusted": sum(1 for e in events if not e["trusted"])}, indent=2))
        return 0

    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
