#!/usr/bin/env python3
"""Booking offers, join permission, and calendar optimize — titles never leave this Mac.

Others cannot reach 127.0.0.1. Send them the generated offer card (times only).
When they pick a slot, `accept` writes the real event locally.
Work people get Busy blocks (work-busy). Friends get location only (private-where)
until both you and they accept a join request.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import uuid
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import caldav_lib as C  # noqa: E402

OFFERS = C.SUPPORT / "offers"
JOINS = C.SUPPORT / "joins.json"
VAULT_CAL = C.VAULT / "Notes" / "Calendar"


def load_joins() -> dict:
    if not JOINS.is_file():
        return {"requests": []}
    try:
        return json.loads(JOINS.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"requests": []}


def save_joins(data: dict) -> None:
    C.SUPPORT.mkdir(parents=True, exist_ok=True)
    JOINS.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    JOINS.chmod(0o600)


def work_hours(calendar: str) -> tuple[int, int]:
    if calendar == "professional":
        return 9, 18
    return 10, 22


def propose(calendar: str, mode: str, days: int, choices: int, duration: int,
            window_start: str, window_end: str, date: str) -> dict:
    env = C.credentials()
    user = env.get("CALDAV_USER") or ""
    busy = C.busy_intervals(user)
    tz = C.local_tz()
    now = datetime.now(tz).replace(second=0, microsecond=0)
    slots = []
    if mode == "window":
        day = datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=tz) if date else now.replace(
            hour=0, minute=0
        )
        sh, sm = (int(x) for x in window_start.split(":"))
        eh, em = (int(x) for x in window_end.split(":"))
        cursor = day.replace(hour=sh, minute=sm)
        end = day.replace(hour=eh, minute=em)
        while cursor + timedelta(minutes=duration) <= end:
            finish = cursor + timedelta(minutes=duration)
            if cursor >= now and not C.overlaps(cursor, finish, busy):
                slots.append((cursor, finish))
            cursor += timedelta(minutes=duration)
    else:
        wh, we = work_hours(calendar)
        day = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
        scanned = 0
        while scanned < 14 and len({s[0].date() for s in slots}) < days:
            if day.weekday() >= 5 and calendar == "professional":
                day += timedelta(days=1)
                scanned += 1
                continue
            cursor = day.replace(hour=wh, minute=0)
            end = day.replace(hour=we, minute=0)
            day_slots = []
            while cursor + timedelta(minutes=duration) <= end and len(day_slots) < choices:
                finish = cursor + timedelta(minutes=duration)
                if cursor >= now and not C.overlaps(cursor, finish, busy):
                    day_slots.append((cursor, finish))
                    cursor += timedelta(minutes=duration * 2)
                else:
                    cursor += timedelta(minutes=duration)
            slots.extend(day_slots[:choices])
            day += timedelta(days=1)
            scanned += 1
    offer_id = uuid.uuid4().hex[:10]
    payload = {
        "id": offer_id,
        "calendar": calendar,
        "duration_min": duration,
        "created": now.isoformat(),
        "slots": [
            {
                "id": hashlib.sha256(f"{offer_id}|{a.isoformat()}".encode()).hexdigest()[:8],
                "start": a.isoformat(),
                "end": b.isoformat(),
            }
            for a, b in slots[: days * choices if mode != "window" else 24]
        ],
    }
    OFFERS.mkdir(parents=True, exist_ok=True)
    (OFFERS / f"{offer_id}.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    (OFFERS / f"{offer_id}.json").chmod(0o600)
    card = render_card(payload)
    VAULT_CAL.mkdir(parents=True, exist_ok=True)
    card_path = VAULT_CAL / f"offer-{offer_id}.md"
    card_path.write_text(card, encoding="utf-8")
    return payload | {"card": str(card_path)}


def render_card(offer: dict) -> str:
    lines = [
        "---",
        "tags: [calendar, booking]",
        "---",
        f"# Meeting times ({offer['calendar']})",
        "",
        "These are **times only**. No titles, people, or locations.",
        f"Duration: {offer['duration_min']} minutes. Reply with the slot id you want.",
        "",
    ]
    by_day: dict[str, list] = {}
    for slot in offer["slots"]:
        start = datetime.fromisoformat(slot["start"])
        by_day.setdefault(start.strftime("%A %Y-%m-%d"), []).append(slot)
    for day, slots in by_day.items():
        lines.append(f"## {day}")
        for slot in slots:
            start = datetime.fromisoformat(slot["start"])
            end = datetime.fromisoformat(slot["end"])
            lines.append(
                f"- `{slot['id']}` {start.strftime('%H:%M')}–{end.strftime('%H:%M')} ({start.tzname() or 'local'})"
            )
        lines.append("")
    lines.append(f"Offer `{offer['id']}` — accept with `scripts/caldav-book.py accept --offer {offer['id']} --slot SLOT --title \"…\"`.")
    lines.append("")
    return "\n".join(lines)


def accept(offer_id: str, slot_id: str, title: str, guest: str) -> str:
    path = OFFERS / f"{offer_id}.json"
    if not path.is_file():
        raise SystemExit(f"unknown offer {offer_id}")
    offer = json.loads(path.read_text(encoding="utf-8"))
    slot = next((s for s in offer["slots"] if s["id"] == slot_id), None)
    if not slot:
        raise SystemExit(f"unknown slot {slot_id}")
    env = C.credentials()
    if not env.get("CALDAV_PASSWORD"):
        raise SystemExit("no CalDAV credentials")
    start = datetime.fromisoformat(slot["start"])
    end = datetime.fromisoformat(slot["end"])
    if C.overlaps(start, end, C.busy_intervals(env["CALDAV_USER"])):
        raise SystemExit("slot is no longer free")
    uid = uuid.uuid4().hex
    now = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    attendee = f"ATTENDEE;CN={C.ics_escape(guest)}:mailto:guest@local\r\n" if guest else ""
    body = (
        "BEGIN:VEVENT\r\n"
        f"UID:{uid}\r\nDTSTAMP:{now}\r\n"
        f"DTSTART:{start.astimezone(C.local_tz()).strftime('%Y%m%dT%H%M%S')}\r\n"
        f"DTEND:{end.astimezone(C.local_tz()).strftime('%Y%m%dT%H%M%S')}\r\n"
        f"SUMMARY:{C.ics_escape(title or 'Meeting')}\r\n"
        f"X-2NDBRAIN-CALENDAR:{offer['calendar']}\r\n"
        f"{attendee}"
        "END:VEVENT\r\n"
    )
    base = env["CALDAV_URL"].rstrip("/") + "/"
    C.put_ics(
        f"{base}{offer['calendar']}/{uid}.ics",
        env["CALDAV_USER"],
        env["CALDAV_PASSWORD"],
        C.wrap_vevent(body),
    )
    import subprocess
    subprocess.run([sys.executable, str(HERE / "caldav-sync.py")], check=False)
    return uid


def join_request(uid: str, guest: str) -> None:
    data = load_joins()
    data["requests"].append(
        {
            "event_uid": uid,
            "guest": guest,
            "host_ok": False,
            "guest_ok": False,
            "created": datetime.now().isoformat(),
        }
    )
    save_joins(data)


def join_accept(uid: str, role: str) -> str:
    data = load_joins()
    found = None
    for req in data["requests"]:
        if req.get("event_uid") == uid:
            found = req
            if role == "host":
                req["host_ok"] = True
            else:
                req["guest_ok"] = True
    if not found:
        raise SystemExit("no join request for that event")
    save_joins(data)
    if found["host_ok"] and found["guest_ok"]:
        user = C.credentials().get("CALDAV_USER") or ""
        for ev in C.iter_ics(user, "private"):
            if ev.get("UID") == uid:
                dest = C.SUPPORT / "joins"
                dest.mkdir(parents=True, exist_ok=True)
                src = Path(ev.get("_file") or "")
                if src.is_file():
                    out = dest / f"{uid}-full.ics"
                    out.write_bytes(src.read_bytes())
                    out.chmod(0o600)
                    return f"both accepted — full event at {out} (send only to that person)"
        return "both accepted — full event not found on Private"
    return "recorded — waiting for the other person"


def optimize(apply: bool) -> str:
    env = C.credentials()
    user = env.get("CALDAV_USER") or ""
    events = C.iter_ics(user, "private") + C.iter_ics(user, "professional")
    parsed = []
    for ev in events:
        if not ev.get("DTSTART"):
            continue
        start = C.parse_dt(ev["DTSTART"])
        end = C.parse_dt(ev["DTEND"]) if ev.get("DTEND") else start + timedelta(minutes=30)
        parsed.append((start, end, ev))
    parsed.sort()
    lines = [
        "---",
        "tags: [calendar, optimize]",
        "---",
        "# Calendar optimize",
        "",
        "Meetings with attendees are not auto-moved. Timed tasks can slide into gaps.",
        "",
    ]
    suggestions = 0
    for i in range(len(parsed) - 1):
        a0, a1, ea = parsed[i]
        b0, b1, eb = parsed[i + 1]
        if a1 > b0:
            lines.append(
                f"- Overlap: `{ea.get('SUMMARY', 'Busy')}` ({ea.get('_calendar')}) "
                f"and `{eb.get('SUMMARY', 'Busy')}` ({eb.get('_calendar')}). "
                "Move the flex/task one, keep the meeting."
            )
            suggestions += 1
        gap = (b0 - a1).total_seconds() / 60
        if 15 <= gap < 45:
            lines.append(
                f"- Tight gap ({int(gap)} min) between `{ea.get('SUMMARY', 'Busy')}` and `{eb.get('SUMMARY', 'Busy')}`."
            )
            suggestions += 1
        if gap >= 90 and apply:
            lines.append(f"- Gap of {int(gap)} min could hold a timed task (not applied to meetings).")
            suggestions += 1
    if suggestions == 0:
        lines.append("No overlaps or tight gaps in the local Private/Professional calendars.")
    VAULT_CAL.mkdir(parents=True, exist_ok=True)
    path = VAULT_CAL / "optimize.md"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return str(path)


def main() -> int:
    p = argparse.ArgumentParser(description="Local CalDAV booking and privacy")
    sub = p.add_subparsers(dest="cmd", required=True)

    pr = sub.add_parser("propose", help="Build a sendable times-only offer")
    pr.add_argument("--calendar", choices=("private", "professional"), default="professional")
    pr.add_argument("--mode", choices=("times", "window"), default="times")
    pr.add_argument("--days", type=int, default=3)
    pr.add_argument("--choices", type=int, default=3)
    pr.add_argument("--duration", type=int, default=30)
    pr.add_argument("--start", default="18:00", help="window start HH:MM")
    pr.add_argument("--end", default="20:00", help="window end HH:MM")
    pr.add_argument("--date", default="", help="window date YYYY-MM-DD")

    ac = sub.add_parser("accept", help="Book a chosen slot locally")
    ac.add_argument("--offer", required=True)
    ac.add_argument("--slot", required=True)
    ac.add_argument("--title", default="Meeting")
    ac.add_argument("--guest", default="")

    jr = sub.add_parser("join-request")
    jr.add_argument("--uid", required=True)
    jr.add_argument("--guest", required=True)

    ja = sub.add_parser("join-accept")
    ja.add_argument("--uid", required=True)
    ja.add_argument("--role", choices=("host", "guest"), default="host")

    op = sub.add_parser("optimize")
    op.add_argument("--apply", action="store_true")

    args = p.parse_args()
    if args.cmd == "propose":
        offer = propose(args.calendar, args.mode, args.days, args.choices, args.duration,
                        args.start, args.end, args.date)
        print(f"offer {offer['id']} slots={len(offer['slots'])} card={offer['card']}")
        return 0
    if args.cmd == "accept":
        uid = accept(args.offer, args.slot, args.title, args.guest)
        print(f"booked uid={uid}")
        return 0
    if args.cmd == "join-request":
        join_request(args.uid, args.guest)
        print("join request stored (both must accept before title/who is shared)")
        return 0
    if args.cmd == "join-accept":
        print(join_accept(args.uid, args.role))
        return 0
    print(optimize(args.apply))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
