#!/usr/bin/env python3
"""Shared CalDAV helpers for local Radicale. No extra packages."""
from __future__ import annotations

import base64
import json
import os
import re
import ssl
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = Path.home()
SUPPORT = HOME / "Library/Application Support/SecondBrain/radicale"
VAULT = Path(os.environ.get("SECOND_BRAIN_VAULT", str(HOME / "Desktop/2nd Brain")))

CALENDARS = {
    "private": {
        "name": "Private",
        "color": "#0A84FF",  # macOS blue
        "components": ("VEVENT",),
    },
    "professional": {
        "name": "Professional",
        "color": "#FF453A",  # macOS red
        "components": ("VEVENT",),
    },
    "work-busy": {
        "name": "Work (busy)",
        "color": "#FF453A",
        "components": ("VEVENT",),
        "projection": "work",
    },
    "private-where": {
        "name": "Private (where)",
        "color": "#0A84FF",
        "components": ("VEVENT",),
        "projection": "private",
    },
    "tasks": {
        "name": "Tasks",
        "color": "#8E8E93",
        "components": ("VTODO",),
    },
}

CREDS_CANDIDATES = [
    Path(os.environ["SECONDBRAIN_CALDAV_ENV"]) if os.environ.get("SECONDBRAIN_CALDAV_ENV") else None,
    HOME / ".config/secondbrain/caldav.env",
    SUPPORT / "credentials.env",
]


def load_env(path: Path | None) -> dict[str, str]:
    out: dict[str, str] = {}
    if path is None or not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip()
    return out


def credentials() -> dict[str, str]:
    env: dict[str, str] = {}
    for path in CREDS_CANDIDATES:
        env = load_env(path)
        if env.get("CALDAV_PASSWORD"):
            return env
    return {}


def ics_escape(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace(";", "\\;")
        .replace(",", "\\,")
        .replace("\r\n", "\\n")
        .replace("\n", "\\n")
    )


def ics_unescape(text: str) -> str:
    return (
        text.replace("\\n", "\n")
        .replace("\\,", ",")
        .replace("\\;", ";")
        .replace("\\\\", "\\")
    )


def local_tz():
    return datetime.now().astimezone().tzinfo


def auth_header(user: str, password: str) -> str:
    return "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


def request(method: str, url: str, user: str, password: str, data: bytes | None = None,
            content_type: str = "text/calendar; charset=utf-8") -> int:
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", auth_header(user, password))
    if data is not None:
        req.add_header("Content-Type", content_type)
    try:
        if url.startswith("https://"):
            ctx = ssl.create_default_context()
            with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
                return getattr(resp, "status", 200) or 200
        with urllib.request.urlopen(req, timeout=15) as resp:
            return getattr(resp, "status", 200) or 200
    except urllib.error.HTTPError as exc:
        return exc.code


def mkcol(url: str, user: str, password: str, displayname: str, color: str, components: tuple[str, ...]) -> None:
    comps = "".join(f'<C:comp name="{c}"/>' for c in components)
    body = f"""<?xml version="1.0" encoding="utf-8"?>
<D:mkcol xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:ICAL="http://apple.com/ns/ical/">
  <D:set>
    <D:prop>
      <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
      <D:displayname>{displayname}</D:displayname>
      <ICAL:calendar-color>{color}</ICAL:calendar-color>
      <C:supported-calendar-component-set>{comps}</C:supported-calendar-component-set>
    </D:prop>
  </D:set>
</D:mkcol>
""".encode()
    code = request("MKCOL", url, user, password, body, "application/xml")
    if code not in {201, 204, 200, 405, 409, 412, 501}:
        # Empty MKCOL as fallback
        request("MKCOL", url.rstrip("/") + "/", user, password)


def put_ics(url: str, user: str, password: str, payload: bytes) -> None:
    code = request("PUT", url, user, password, payload)
    if code not in {201, 204, 200}:
        raise RuntimeError(f"PUT {code}")


def collection_root() -> Path:
    return SUPPORT / "collections" / "collection-root"


def user_root(user: str) -> Path:
    return collection_root() / user


def write_props(user: str, cal_id: str, displayname: str, color: str) -> None:
    folder = user_root(user) / cal_id
    folder.mkdir(parents=True, exist_ok=True)
    props = {
        "tag": "VCALENDAR",
        "D:displayname": displayname,
        "{http://apple.com/ns/ical/}calendar-color": color,
    }
    (folder / ".Radicale.props").write_text(json.dumps(props), encoding="utf-8")


def unfold(ics: str) -> str:
    return re.sub(r"\r?\n[ \t]", "", ics)


def parse_props(block: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in unfold(block).splitlines():
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        name = key.split(";")[0].upper()
        out[name] = ics_unescape(val.strip())
        if name == "DTSTART" and ";" in key:
            out["_DTSTART_TZ"] = key
        if name == "DTEND" and ";" in key:
            out["_DTEND_TZ"] = key
    return out


def iter_ics(user: str, cal_id: str) -> list[dict[str, str]]:
    folder = user_root(user) / cal_id
    events: list[dict[str, str]] = []
    if not folder.is_dir():
        return events
    for path in folder.glob("*.ics"):
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for match in re.finditer(r"BEGIN:VEVENT\r?\n(.*?)END:VEVENT", text, re.S):
            props = parse_props(match.group(1))
            props["_file"] = str(path)
            props["_calendar"] = cal_id
            events.append(props)
    return events


def parse_dt(value: str, tzinfo=None):
    tzinfo = tzinfo or local_tz()
    zulu = str(value).strip().endswith("Z")
    raw = re.sub(r"[^0-9T]", "", value)
    if len(raw) == 8:
        dt = datetime.strptime(raw, "%Y%m%d")
        return dt.replace(tzinfo=timezone.utc if zulu else tzinfo)
    dt = datetime.strptime(raw[:15], "%Y%m%dT%H%M%S")
    return dt.replace(tzinfo=timezone.utc if zulu else tzinfo)


def busy_intervals(user: str) -> list[tuple[datetime, datetime]]:
    """Events that occupy time: real private + professional VEVENTs, not tasks, not transparent."""
    busy = []
    for cal in ("private", "professional"):
        for ev in iter_ics(user, cal):
            if (ev.get("TRANSP") or "").upper() == "TRANSPARENT":
                continue
            start_s, end_s = ev.get("DTSTART"), ev.get("DTEND")
            if not start_s:
                continue
            start = parse_dt(start_s)
            if end_s:
                end = parse_dt(end_s)
            else:
                end = start + timedelta(minutes=30)
            busy.append((start, end))
    busy.sort()
    return busy


def overlaps(start: datetime, end: datetime, intervals: list[tuple[datetime, datetime]]) -> bool:
    for a, b in intervals:
        if start < b and end > a:
            return True
    return False


def wrap_vevent(body: str) -> bytes:
    return (
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//2nd Brain//caldav//EN\r\n"
        f"{body}"
        "END:VCALENDAR\r\n"
    ).encode()
