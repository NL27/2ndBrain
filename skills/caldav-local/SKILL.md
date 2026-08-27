---
name: caldav-local
description: Use the 2nd Brain Radicale CalDAV server on 127.0.0.1:5232. Use when creating calendar events, booking slots, Private vs Professional calendars, or syncing vault tasks.
---

# Local CalDAV

Calendar lives on **this Mac** (Radicale). Not Google. Cloud n8n cannot reach `127.0.0.1`. Others book via a **times-only** offer card, not a public Calendly URL.

| | |
|--|--|
| URL | `http://127.0.0.1:5232/` |
| Setup | `scripts/caldav-setup.sh` |
| Password | `~/Library/Application Support/SecondBrain/radicale/credentials.env` (mode 600) |
| Sync | `python3 scripts/caldav-sync.py` |
| Book / join / optimize | `python3 scripts/caldav-book.py` |

## Calendars

| Collection | Colour | Share view |
|------------|--------|------------|
| `private` | blue `#0A84FF` | Friends see `private-where` (location only, summary Busy) |
| `professional` | red `#FF453A` | Work sees `work-busy` (Busy only, no title) |
| `tasks` | grey | VTODO — does **not** occupy busy time |

Timed vault tasks (`due: YYYY-MM-DD` **and** `at: HH:MM`) become events on Private or Professional (`#work` / `calendar: professional`). A due date alone stays a task and does not move meetings.

## Booking

`propose --mode times --days 3 --choices 3` or `propose --mode window --start 18:00 --end 20:00`. Send `Notes/Calendar/offer-….md`. `accept` writes the real event locally, then refreshes Busy/where projections.

Join: `join-request` then both `join-accept --role host` and `--role guest`. Until both accept, do not share title or attendees. Work busy never gains a title.

`optimize` writes suggestions. Do not auto-move events that have attendees.

Overnight **production** may create events on loopback. Overnight **development** must not. Never paste `CALDAV_PASSWORD` into the vault, queue, or n8n. Load `data-boundary`.
