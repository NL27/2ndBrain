---
name: mac-network-guard
description: Track where this Mac's 2nd Brain stack sends and receives traffic, compare it to the trusted-host allowlist, and block untrusted destinations for the overnight sandbox user. Use when connections look wrong, when adding a trusted host, or when overnight jobs talk to the network.
---

# Network guard

Scope is **this Mac**. Sample listening and established sockets; do not capture payloads.

## Sources of truth

- Allowlist: `~/Library/Application Support/SecondBrain/sandbox/allowlist.json`
- Live sample: `python3 …/scripts/network-guard.py --once`
- Rolling log: `/Users/Shared/2nd-Brain-Night/logs/connections.jsonl`
- Agent-only block: pf anchor `com.dao.secondbrain` (user `secondbrain-agent`)

## Trust decision

A destination is trusted when it matches a hostname, IP, or CIDR in the allowlist, or it is loopback. Everything else is `untrusted`.

Interactive apps (Safari, Cursor) may talk to hosts that are not on the allowlist — **log them, do not pf-block the whole Mac**. Only the overnight users are default-deny. `secondbrain-dev` is loopback-only (`allowlist-dev.json`).

Little Snitch (if installed) is turned back **on** every 3 hours by `little-snitch-keeper.sh` because demo mode disables the filter after 3h. That is the same action as the status menu, not a license bypass. Enable Little Snitch → Settings → Security → Allow access via Terminal so the CLI path works.

## Adding a host

1. Confirm the human wants it trusted.
2. Append the hostname to `allowlist.json` `trusted_hosts`.
3. Run `network-guard.py --refresh-pf` (admin password once) so the agent table updates.
4. Do not paste secrets into the allowlist file.

## Reading a log line

```json
{"ts":"...","pid":123,"process":"cline","user":"secondbrain-agent","remote":"203.0.113.9:443","host":"evil.example","trusted":false}
```

If `user` is `secondbrain-agent` and `trusted` is false, the connection should have been blocked. If it was not, the pf anchor is missing — load `mac-defend` and repair isolation before the next overnight run.
