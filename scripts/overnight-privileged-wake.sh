#!/usr/bin/env bash
# Root half of overnight-ctl start: install runner, Cline native binary, perms, kickstart.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYS_RUNNER="/Library/Application Support/SecondBrain/sandbox/overnight-run.sh"
SYS_DIR="/Library/Application Support/SecondBrain/sandbox"
PROD="/Users/Shared/2nd-Brain-Night"
DEV="/Users/Shared/2nd-Brain-Dev"
INTERACTIVE="${SECONDBRAIN_INTERACTIVE_USER:-$(stat -f '%Su' /dev/console 2>/dev/null)}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "overnight-privileged-wake.sh must run as root" >&2
  exit 1
fi

mkdir -p "$SYS_DIR"
cp -f "$HERE/overnight-run.sh" "$SYS_RUNNER"
chmod 755 "$SYS_RUNNER"
SB="$HERE/../Resources/sandbox"
[[ -f "$SB/secondbrain-agent.sb" ]] || SB="$HERE"
[[ -f "$SB/secondbrain-agent.sb" ]] && cp -f "$SB/secondbrain-agent.sb" "$SB/secondbrain-dev.sb" "$SYS_DIR/" 2>/dev/null || true

NATIVE="@cline/cli-darwin-arm64"
[[ "$(uname -m)" == "x86_64" ]] && NATIVE="@cline/cli-darwin-x64"
if command -v npm >/dev/null; then
  npm install -g cline "$NATIVE" --include=optional >&2 || true
fi

cline_src=""
for c in /opt/homebrew/bin/cline "$(npm prefix -g 2>/dev/null)/bin/cline"; do
  [[ -x "$c" ]] || continue
  cline_src="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$c")"
  [[ -x "$cline_src" ]] && break
  cline_src=""
done
if [[ -n "$cline_src" ]]; then
  mkdir -p /usr/local/bin
  ln -sfn "$cline_src" /usr/local/bin/cline
  for user in secondbrain-agent secondbrain-dev; do
    [[ -d "/Users/$user" ]] || continue
    mkdir -p "/Users/$user/.local/bin"
    ln -sfn "$cline_src" "/Users/$user/.local/bin/cline"
    chown -R "$user:staff" "/Users/$user/.local"
  done
fi

/usr/sbin/createhomedir -c -u secondbrain-agent >/dev/null 2>&1 || true
/usr/sbin/createhomedir -c -u secondbrain-dev >/dev/null 2>&1 || true
mkdir -p /Users/secondbrain-agent /Users/secondbrain-dev
chown -R secondbrain-agent:staff /Users/secondbrain-agent
chown -R secondbrain-dev:staff /Users/secondbrain-dev
chmod 700 /Users/secondbrain-agent /Users/secondbrain-dev

mkdir -p "$PROD/logs" "$PROD/state" "$PROD/queue/failed" "$DEV/logs" "$DEV/state"
chown -R "$INTERACTIVE:secondbrain" "$PROD/logs" "$PROD/state" "$PROD/queue" 2>/dev/null || true
chmod 770 "$PROD" "$PROD/logs" "$PROD/state" "$PROD/queue" "$PROD/queue/failed" 2>/dev/null || true
chmod g+rw "$PROD/logs"/* "$PROD/queue/failed"/* 2>/dev/null || true
chown secondbrain-agent:secondbrain "$PROD/logs"/overnight.*.log "$PROD/logs"/activity.jsonl "$PROD/logs"/cline-* 2>/dev/null || true
chmod 664 "$PROD/logs"/overnight.*.log "$PROD/logs"/activity.jsonl 2>/dev/null || true

launchctl kickstart -k system/com.dao.secondbrain.overnight 2>/dev/null || true
launchctl kickstart -k system/com.dao.secondbrain.overnight-dev 2>/dev/null || true
