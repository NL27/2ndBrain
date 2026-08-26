#!/usr/bin/env python3
"""Look for suspicious activity on this Mac's 2nd Brain stack.

Scope is this host only. Logs kind + path/process/user — never payloads, env
files, or clipboard. Writes Notes/Security/alerts.jsonl and a daily digest.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
VAULT = Path(os.environ.get("SECOND_BRAIN_VAULT", str(HOME / "Desktop/2nd Brain")))
SECURITY = VAULT / "Notes/Security"
DROP_NIGHT = Path("/Users/Shared/2nd-Brain-Night")
DROP_DEV = Path("/Users/Shared/2nd-Brain-Dev")
SUPPORT = HOME / "Library/Application Support/SecondBrain/sandbox"
AGENT_USERS = {"secondbrain-agent", "secondbrain-dev"}
HERE = Path(__file__).resolve().parent


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def append_jsonl(path: Path, event: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, separators=(",", ":")) + "\n")


def log_event(kind: str, severity: str, **extra) -> dict:
    event = {"ts": now_iso(), "kind": kind, "severity": severity, **extra}
    for drop in (DROP_NIGHT, DROP_DEV):
        logs = drop / "logs"
        if logs.exists() or os.access(str(drop), os.W_OK):
            try:
                logs.mkdir(parents=True, exist_ok=True)
                append_jsonl(logs / "activity.jsonl", event)
            except OSError:
                pass
    SECURITY.mkdir(parents=True, exist_ok=True)
    append_jsonl(SECURITY / "alerts.jsonl", event)
    return event


def run_host_integrity() -> list[dict]:
    script = HERE / "host-integrity.py"
    if not script.is_file():
        script = SUPPORT / "host-integrity.py"
    if not script.is_file():
        return []
    try:
        raw = subprocess.check_output(
            [sys.executable, str(script)],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as exc:
        out = getattr(exc, "output", "") or ""
        raw = out if isinstance(out, str) else ""
    alerts = []
    for line in raw.splitlines():
        if line.startswith("unexpected-persistence"):
            parts = line.split()
            alerts.append(
                log_event(
                    "unexpected-persistence",
                    "critical",
                    label=parts[1] if len(parts) > 1 else "",
                    path=parts[2] if len(parts) > 2 else "",
                )
            )
        elif line.startswith("mcp-hand-added"):
            parts = line.split()
            alerts.append(
                log_event(
                    "mcp-hand-added",
                    "warn",
                    client=parts[1] if len(parts) > 1 else "",
                    server=parts[2] if len(parts) > 2 else "",
                )
            )
        elif line.startswith("vault-icloud-desktop"):
            alerts.append(log_event("vault-icloud-desktop", "warn"))
    return alerts


def isolation_broken() -> list[dict]:
    alerts = []
    owner_file = DROP_NIGHT / ".interactive-user"
    owner = owner_file.read_text(encoding="utf-8").strip() if owner_file.is_file() else ""
    home = Path("/Users") / owner if owner else None
    if home and home.is_dir() and owner:
        acl = subprocess.run(["ls", "-led", str(home)], capture_output=True, text=True, timeout=5)
        text = acl.stdout
        for user in AGENT_USERS:
            if Path(f"/Users/{user}").is_dir() and f"user:{user} deny" not in text:
                alerts.append(
                    log_event("isolation-acl-missing", "critical", user=user, home=str(home))
                )
    return alerts


def agent_untrusted_sockets() -> list[dict]:
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
    alerts = []
    dest_re = re.compile(r"->(\[[0-9a-fA-F:.]+\]|[0-9.]+):(\d+)")
    who_re = re.compile(r"^(\S+)\s+(\d+)\s+(\S+)")
    for line in raw.splitlines()[1:]:
        dest = dest_re.search(line)
        who = who_re.match(line)
        if not dest or not who:
            continue
        user = who.group(3)
        if user not in AGENT_USERS:
            continue
        ip = dest.group(1).strip("[]")
        if ip in {"127.0.0.1", "::1", "localhost"} or ip.startswith("127."):
            continue
        if user == "secondbrain-dev":
            alerts.append(
                log_event(
                    "dev-non-loopback",
                    "critical",
                    user=user,
                    process=who.group(1)[:80],
                    pid=who.group(2),
                    remote_port=dest.group(2),
                )
            )
        # production untrusted is already logged by network-guard; flag agent + off-LAN
        if user == "secondbrain-agent" and not (
            ip.startswith("10.") or ip.startswith("192.168.") or ip.startswith("172.")
        ):
            alerts.append(
                log_event(
                    "agent-untrusted-socket",
                    "warn",
                    user=user,
                    process=who.group(1)[:80],
                    pid=who.group(2),
                    remote_port=dest.group(2),
                )
            )
    return alerts


def unexpected_listeners() -> list[dict]:
    if not shutil.which("lsof"):
        return []
    try:
        raw = subprocess.check_output(
            ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return []
    alerts = []
    who_re = re.compile(r"^(\S+)\s+(\d+)\s+(\S+).*:(\d+)\s+\(LISTEN\)")
    for line in raw.splitlines()[1:]:
        who = who_re.search(line)
        if not who:
            continue
        user = who.group(3)
        if user not in AGENT_USERS:
            continue
        port = who.group(4)
        if port in {"22"}:
            alerts.append(
                log_event(
                    "agent-listener",
                    "critical",
                    user=user,
                    process=who.group(1)[:80],
                    pid=who.group(2),
                    port=port,
                )
            )
    return alerts


def queue_rejects() -> list[dict]:
    alerts = []
    for drop, env in ((DROP_NIGHT, "production"), (DROP_DEV, "development")):
        rejected = drop / "queue" / "rejected"
        if not rejected.is_dir():
            continue
        for path in sorted(rejected.iterdir()):
            if path.suffix not in {".md", ".txt"}:
                continue
            age = datetime.now().timestamp() - path.stat().st_mtime
            if age > 400:
                continue
            alerts.append(
                log_event(
                    "queue-rejected",
                    "warn",
                    env=env,
                    item=path.name,
                )
            )
    return alerts


def write_digest(alerts: list[dict]) -> None:
    SECURITY.mkdir(parents=True, exist_ok=True)
    day = datetime.now().strftime("%Y-%m-%d")
    path = SECURITY / f"{day} activity.md"
    lines = [
        "---",
        "type: security-log",
        f"created: {now_iso()}",
        "tags: [security, activity]",
        "---",
        f"# Activity check {day}",
        "",
        f"{len(alerts)} finding(s) this run (kind + path only).",
        "",
    ]
    if not alerts:
        lines.append("No suspicious 2nd Brain activity in this sample.")
    else:
        lines += ["| Severity | Kind | Detail |", "|----------|------|--------|"]
        for event in alerts[:60]:
            detail = {k: v for k, v in event.items() if k not in {"ts", "kind", "severity"}}
            lines.append(
                f"| {event.get('severity')} | `{event.get('kind')}` | `{json.dumps(detail)}` |"
            )
    lines.append("")
    lines.append("#security #activity")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def notify_critical(alerts: list[dict]) -> None:
    critical = [a for a in alerts if a.get("severity") == "critical"]
    if not critical:
        return
    kinds = ", ".join(sorted({a["kind"] for a in critical}))
    subprocess.run(
        [
            "osascript",
            "-e",
            f'display notification "{kinds}" with title "2nd Brain security" subtitle "Suspicious activity"',
        ],
        capture_output=True,
        timeout=8,
    )


def main() -> int:
    alerts: list[dict] = []
    alerts += run_host_integrity()
    alerts += isolation_broken()
    alerts += agent_untrusted_sockets()
    alerts += unexpected_listeners()
    alerts += queue_rejects()
    write_digest(alerts)
    notify_critical(alerts)
    print(json.dumps({"findings": len(alerts), "critical": sum(1 for a in alerts if a.get("severity") == "critical")}))
    return 0 if not any(a.get("severity") == "critical" for a in alerts) else 1


if __name__ == "__main__":
    raise SystemExit(main())
