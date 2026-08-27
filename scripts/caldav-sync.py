#!/usr/bin/env python3
"""Ensure Private (blue) + Professional (red) calendars, sync vault tasks, project privacy views.

Tasks without a clock time are VTODO and do not occupy busy time.
Tasks with `due:` and `at:` become timed events on the tagged calendar.
"""
from __future__ import annotations

import hashlib
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import caldav_lib as C  # noqa: E402

TASK_RE = re.compile(
    r"^- \[ \] (.+)$",
    re.M,
)
DUE_RE = re.compile(r"\bdue[:\s]+(\d{4}-\d{2}-\d{2})\b", re.I)
AT_RE = re.compile(r"\bat[:\s]+(\d{1,2}:\d{2})\b", re.I)
CAL_RE = re.compile(r"\bcalendar[:\s]+(private|professional|work)\b", re.I)


def which_calendar(title: str) -> str:
    tagged = CAL_RE.search(title)
    if tagged:
        name = tagged.group(1).lower()
        return "professional" if name in {"professional", "work"} else "private"
    if re.search(r"#(work|professional)\b", title, re.I):
        return "professional"
    return "private"


def strip_meta(title: str) -> str:
    title = CAL_RE.sub("", title)
    title = DUE_RE.sub("", title)
    title = AT_RE.sub("", title)
    title = re.sub(r"#(work|professional|private)\b", "", title, flags=re.I)
    return re.sub(r"\s+", " ", title).strip()[:180]


def collect_tasks() -> list[dict]:
    found: list[dict] = []
    for folder in ("Daily", "Inbox", "Notes"):
        root = C.VAULT / folder
        if not root.is_dir():
            continue
        for path in root.rglob("*.md"):
            if any(p in path.parts for p in ("Overnight", "Security", "Captures", "Calendar")):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for match in TASK_RE.finditer(text):
                raw = match.group(1).strip()
                due = DUE_RE.search(raw)
                at = AT_RE.search(raw)
                item = {
                    "title": strip_meta(raw) or "Task",
                    "due": due.group(1) if due else "",
                    "at": at.group(1) if at else "",
                    "calendar": which_calendar(raw),
                }
                found.append(item)
    uniq, seen = [], set()
    for item in found:
        key = (item["title"], item["due"], item["at"], item["calendar"])
        if key in seen:
            continue
        seen.add(key)
        uniq.append(item)
    return uniq[:300]


def wrap_vtodo(uid: str, title: str, due: str) -> bytes:
    now = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    due_line = f"DUE;VALUE=DATE:{due.replace('-', '')}\r\n" if due else ""
    return (
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//2nd Brain//caldav//EN\r\n"
        "BEGIN:VTODO\r\n"
        f"UID:{uid}\r\nDTSTAMP:{now}\r\n{due_line}"
        f"SUMMARY:{C.ics_escape(title)}\r\nSTATUS:NEEDS-ACTION\r\n"
        "TRANSP:TRANSPARENT\r\n"
        "END:VTODO\r\nEND:VCALENDAR\r\n"
    ).encode()


def event_ics(uid: str, title: str, start: datetime, end: datetime, calendar: str) -> bytes:
    now = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    fmt = "%Y%m%dT%H%M%S"
    body = (
        "BEGIN:VEVENT\r\n"
        f"UID:{uid}\r\nDTSTAMP:{now}\r\n"
        f"DTSTART:{start.strftime(fmt)}\r\nDTEND:{end.strftime(fmt)}\r\n"
        f"SUMMARY:{C.ics_escape(title)}\r\n"
        f"X-2NDBRAIN-CALENDAR:{calendar}\r\n"
        "END:VEVENT\r\n"
    )
    return C.wrap_vevent(body)


def projection_ics(src: dict, kind: str) -> bytes | None:
    if (src.get("TRANSP") or "").upper() == "TRANSPARENT":
        return None
    start, end = src.get("DTSTART"), src.get("DTEND")
    if not start:
        return None
    uid = hashlib.sha256(f"{kind}|{src.get('UID', start)}".encode()).hexdigest()[:32]
    now = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    dtend = f"DTEND:{end}\r\n" if end else ""
    if kind == "work":
        summary = "Busy"
        extra = "CLASS:CONFIDENTIAL\r\n"
    else:
        summary = "Busy"
        loc = src.get("LOCATION") or ""
        extra = f"LOCATION:{C.ics_escape(loc)}\r\n" if loc else ""
        extra += "CLASS:PRIVATE\r\n"
    body = (
        "BEGIN:VEVENT\r\n"
        f"UID:{uid}\r\nDTSTAMP:{now}\r\nDTSTART:{start}\r\n{dtend}"
        f"SUMMARY:{summary}\r\nTRANSP:OPAQUE\r\n{extra}"
        "END:VEVENT\r\n"
    )
    return C.wrap_vevent(body)


def ensure(env: dict[str, str]) -> str:
    base = env.get("CALDAV_URL", "").rstrip("/") + "/"
    user = env.get("CALDAV_USER", "")
    password = env.get("CALDAV_PASSWORD", "")
    C.mkcol(base, user, password, user, "#8E8E93", ("VEVENT", "VTODO"))
    for cal_id, meta in C.CALENDARS.items():
        url = f"{base}{cal_id}/"
        C.mkcol(url, user, password, meta["name"], meta["color"], meta["components"])
        C.write_props(user, cal_id, meta["name"], meta["color"])
    return base


def project_views(env: dict[str, str], base: str) -> int:
    user, password = env["CALDAV_USER"], env["CALDAV_PASSWORD"]
    n = 0
    for ev in C.iter_ics(user, "professional"):
        payload = projection_ics(ev, "work")
        if not payload:
            continue
        uid = hashlib.sha256(f"work|{ev.get('UID', '')}".encode()).hexdigest()[:32]
        try:
            C.put_ics(f"{base}work-busy/{uid}.ics", user, password, payload)
            n += 1
        except Exception as exc:
            print(f"caldav-sync project work: {type(exc).__name__}")
    for ev in C.iter_ics(user, "private"):
        payload = projection_ics(ev, "private")
        if not payload:
            continue
        uid = hashlib.sha256(f"where|{ev.get('UID', '')}".encode()).hexdigest()[:32]
        try:
            C.put_ics(f"{base}private-where/{uid}.ics", user, password, payload)
            n += 1
        except Exception as exc:
            print(f"caldav-sync project private: {type(exc).__name__}")
    return n


def sync_tasks(env: dict[str, str], base: str) -> tuple[int, int]:
    user, password = env["CALDAV_USER"], env["CALDAV_PASSWORD"]
    todos = events = 0
    tz = C.local_tz()
    for item in collect_tasks():
        uid = hashlib.sha256(
            f"{item['title']}|{item['due']}|{item['at']}|{item['calendar']}".encode()
        ).hexdigest()[:32]
        if item["due"] and item["at"]:
            hour, minute = item["at"].split(":")
            day = datetime.strptime(item["due"], "%Y-%m-%d").replace(
                hour=int(hour), minute=int(minute), tzinfo=tz
            )
            end = day + timedelta(minutes=30)
            url = f"{base}{item['calendar']}/{uid}.ics"
            try:
                C.put_ics(url, user, password, event_ics(uid, item["title"], day, end, item["calendar"]))
                events += 1
            except Exception as exc:
                print(f"caldav-sync event skip: {type(exc).__name__}")
            continue
        # VTODO — does not occupy busy time
        url = f"{base}tasks/{uid}.ics"
        try:
            C.put_ics(url, user, password, wrap_vtodo(uid, item["title"], item["due"]))
            todos += 1
        except Exception as exc:
            print(f"caldav-sync todo skip: {type(exc).__name__}")
    return todos, events


def main() -> int:
    env = C.credentials()
    if not env.get("CALDAV_PASSWORD"):
        print("caldav-sync: no credentials.env")
        return 0
    try:
        base = ensure(env)
    except Exception as exc:
        print(f"caldav-sync ensure: {type(exc).__name__}")
        return 0
    todos, events = sync_tasks(env, base)
    projected = project_views(env, base)
    print(f"caldav-sync: {todos} task(s), {events} timed task(s), {projected} privacy block(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
