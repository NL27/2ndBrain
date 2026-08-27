#!/usr/bin/env bash
# First-install defence: cybersecurity skills, sandbox user, network allowlist,
# activity logs, overnight runner.
#
# Emits STEP|defend|… lines for SetupManager. Creating the macOS user needs an
# admin password — one GUI dialog via osascript.
set -uo pipefail

MODE="install"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# Repo layout: scripts/ + skills/ + Resources/sandbox/
# App bundle: all of those sit next to this script in Contents/Resources.
SKILLS_ROOT="$ROOT/skills"
[[ -d "$SKILLS_ROOT/mac-defend" ]] || SKILLS_ROOT="$HERE/skills"
SANDBOX_SRC="$ROOT/Resources/sandbox"
[[ -f "$SANDBOX_SRC/allowlist.json" ]] || SANDBOX_SRC="$HERE/sandbox"
SUPPORT="$HOME/Library/Application Support/SecondBrain"
SANDBOX_DIR="$SUPPORT/sandbox"
DROP="/Users/Shared/2nd-Brain-Night"
AGENT_USER="secondbrain-agent"
VAULT="${SECOND_BRAIN_VAULT:-$HOME/Desktop/2nd Brain}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift;;
    *) shift;;
  esac
done

emit() { printf 'STEP|%s|%s|%s\n' "$1" "$2" "$3"; }

install_skills() {
  local dest="$HOME/.agents/skills"
  mkdir -p "$dest" "$VAULT/Agent Skills/cybersecurity" "$VAULT/Agent Skills/automation"
  local authored=(
    mac-defend mac-network-guard overnight-sandbox secrets-hygiene data-boundary
    prompt-injection-guard mcp-trust persistence-hygiene vault-exposure agent-hard-limits
    overnight-ops local-first-models vault-cadence caldav-local autonomous-loop
  )
  local name
  for name in "${authored[@]}"; do
    if [[ -f "$SKILLS_ROOT/$name/SKILL.md" ]]; then
      rm -rf "$dest/$name"
      cp -R "$SKILLS_ROOT/$name" "$dest/$name"
    fi
  done
  for name in mac-defend mac-network-guard overnight-sandbox secrets-hygiene data-boundary \
              prompt-injection-guard mcp-trust persistence-hygiene vault-exposure agent-hard-limits; do
    [[ -d "$dest/$name" ]] && ln -sfn "$dest/$name" "$VAULT/Agent Skills/cybersecurity/$name"
  done
  for name in overnight-ops local-first-models vault-cadence caldav-local autonomous-loop; do
    [[ -d "$dest/$name" ]] && ln -sfn "$dest/$name" "$VAULT/Agent Skills/automation/$name"
  done
  # Already on the machine from setup — pin them next to the Mac-defence set
  # so agents looking under cybersecurity/ actually load them.
  for name in security-review skill-auditor n8n-credentials-and-security-official; do
    if [[ -f "$dest/$name/SKILL.md" ]]; then
      ln -sfn "$dest/$name" "$VAULT/Agent Skills/cybersecurity/$name"
    fi
  done
  for name in thinking-router skill-router planning-with-files agent-self-evaluation \
              planning-and-task-breakdown sequential-thinking recall-reasoning coding debugging \
              n8n-error-handling-official n8n-workflow-lifecycle-official n8n-loops-official \
              n8n-agents-official using-n8n-skills-official using-openrouter-model-selection; do
    if [[ -f "$dest/$name/SKILL.md" ]]; then
      ln -sfn "$dest/$name" "$VAULT/Agent Skills/automation/$name"
    fi
  done
  for agent_dir in "$HOME/.cursor/skills" "$HOME/.cline/skills" "$HOME/.roo/skills" "$HOME/.kilocode/skills"; do
    mkdir -p "$agent_dir"
    for name in "${authored[@]}"; do
      [[ -d "$dest/$name" ]] || continue
      rm -rf "$agent_dir/$name"
      cp -R "$dest/$name" "$agent_dir/$name"
    done
  done
}

seed_dirs() {
  mkdir -p "$SANDBOX_DIR" \
    "$VAULT/Notes/Overnight/queue" \
    "$VAULT/Notes/Overnight/dev-queue" \
    "$VAULT/Notes/Security"
  if [[ ! -f "$VAULT/Notes/Overnight/README.md" ]]; then
    cat > "$VAULT/Notes/Overnight/README.md" <<'EOF'
---
tags: [overnight, sandbox]
---
# Overnight queues

## Production (`queue/`)

Runs at 02:00 as `secondbrain-agent`. Allowlisted network. Results: `last-run.md`.

## Development (`dev-queue/`)

Runs at 02:30 as `secondbrain-dev` in a tighter sandbox (loopback only, no n8n/MCP, cannot read the production drop). Use this to test overnight automation. Results: `last-run-dev.md`.

A note in `queue/` with frontmatter `env: development` is moved to `dev-queue/` before the night job.

Do not put secrets in either queue.

Optional: `Notes/Overnight/standing-mission.md` is copied every night and never marked done. Agents run until `Notes/Overnight/STOP` (menu Stop overnight agents).
EOF
  fi
  for f in allowlist.json allowlist-dev.json secondbrain-agent.sb secondbrain-dev.sb \
           environments.json known-persistence.json; do
    [[ -f "$SANDBOX_SRC/$f" ]] && cp -f "$SANDBOX_SRC/$f" "$SANDBOX_DIR/$f"
  done
  for script in network-guard.py overnight-run.sh scan-secrets.py host-integrity.py \
                activity-watch.py little-snitch-keeper.sh overnight-queue-sync.sh \
                overnight-ctl.sh caldav-sync.py caldav-setup.sh caldav_lib.py caldav-book.py; do
    [[ -f "$HERE/$script" ]] && cp -f "$HERE/$script" "$SANDBOX_DIR/$script"
    chmod +x "$SANDBOX_DIR/$script" 2>/dev/null || true
  done
}

install_user_launchagent() {
  local plist="$HOME/Library/LaunchAgents/com.dao.secondbrain.network-guard.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.dao.secondbrain.network-guard</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${SANDBOX_DIR}/network-guard.py</string>
    <string>--watch</string>
    <string>60</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/secondbrain-network-guard.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/secondbrain-network-guard.err</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/com.dao.secondbrain.network-guard" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || launchctl load -w "$plist" 2>/dev/null || true

  local copy_plist="$HOME/Library/LaunchAgents/com.dao.secondbrain.overnight-queue.plist"
  cat > "$copy_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.dao.secondbrain.overnight-queue</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SANDBOX_DIR}/overnight-queue-sync.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>1</integer>
    <key>Minute</key><integer>50</integer>
  </dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SECOND_BRAIN_VAULT</key>
    <string>${VAULT}</string>
  </dict>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/com.dao.secondbrain.overnight-queue" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$copy_plist" 2>/dev/null || launchctl load -w "$copy_plist" 2>/dev/null || true

  local watch_plist="$HOME/Library/LaunchAgents/com.dao.secondbrain.activity-watch.plist"
  cat > "$watch_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.dao.secondbrain.activity-watch</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${SANDBOX_DIR}/activity-watch.py</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/secondbrain-activity-watch.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/secondbrain-activity-watch.err</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/com.dao.secondbrain.activity-watch" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$watch_plist" 2>/dev/null || launchctl load -w "$watch_plist" 2>/dev/null || true

  local snitch_plist="$HOME/Library/LaunchAgents/com.dao.secondbrain.snitch-keeper.plist"
  cat > "$snitch_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.dao.secondbrain.snitch-keeper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SANDBOX_DIR}/little-snitch-keeper.sh</string>
  </array>
  <key>StartInterval</key><integer>10800</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/secondbrain-snitch-keeper.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/secondbrain-snitch-keeper.err</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/com.dao.secondbrain.snitch-keeper" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$snitch_plist" 2>/dev/null || launchctl load -w "$snitch_plist" 2>/dev/null || true
}

maybe_little_snitch() {
  [[ -d "/Applications/Little Snitch.app" ]]
}

maybe_lulu() {
  if [[ -d "/Applications/LuLu.app" ]]; then
    return 0
  fi
  if command -v brew >/dev/null; then
    brew install --cask lulu >&2 || return 1
  else
    return 1
  fi
}

user_exists() {
  dscl . -read "/Users/$AGENT_USER" >/dev/null 2>&1
}

dev_exists() {
  dscl . -read "/Users/secondbrain-dev" >/dev/null 2>&1
}

acl_present() {
  ls -led "$HOME" 2>/dev/null | grep -q "user:$AGENT_USER deny"
}

emit defend checking "Looking for sandbox user, network guard and security skills"

install_skills
seed_dirs
install_user_launchagent

if [[ "$MODE" == "check" ]]; then
  local_ok=1
  [[ -f "$HOME/.agents/skills/mac-defend/SKILL.md" ]] || local_ok=0
  [[ -f "$HOME/.agents/skills/secrets-hygiene/SKILL.md" ]] || local_ok=0
  [[ -f "$HOME/.agents/skills/prompt-injection-guard/SKILL.md" ]] || local_ok=0
  [[ -f "$HOME/.agents/skills/agent-hard-limits/SKILL.md" ]] || local_ok=0
  if user_exists && acl_present && dev_exists; then
    emit defend ok "Production + development sandbox users isolated; activity watch and Little Snitch keeper installed"
    exit 0
  fi
  if user_exists && acl_present; then
    emit defend manual "Production sandbox exists — grant an admin password to add the development overnight user"
    exit 0
  fi
  if (( local_ok )); then
    emit defend manual "Skills ready — grant an admin password in setup to create the isolated overnight user"
    exit 0
  fi
  emit defend failed "Defence pieces are missing"
  exit 1
fi

emit defend installing "Installing cybersecurity skills and connection logger"
install_user_launchagent

# LuLu / Little Snitch are GUI firewalls for the interactive user. Optional.
if maybe_lulu; then
  echo "LuLu installed — approve connections in its menu extra" >&2
fi
if maybe_little_snitch; then
  echo "Little Snitch present — enable Terminal access in Settings → Security so the 3-hour keeper can turn the demo filter back on" >&2
  /bin/bash "$SANDBOX_DIR/little-snitch-keeper.sh" >/dev/null 2>&1 || true
fi
python3 "$SANDBOX_DIR/activity-watch.py" >/dev/null 2>&1 || true

if user_exists && acl_present && dev_exists; then
  emit defend ok "Production + development sandbox users already isolated"
  exit 0
fi

emit defend installing "Creating isolated user $AGENT_USER (admin password required)"
export SECONDBRAIN_INTERACTIVE_USER="$USER"
export SECONDBRAIN_INTERACTIVE_HOME="$HOME"
PRIV="$HERE/defend-privileged.sh"
if osascript <<OSA >/dev/null
do shell script "export SECONDBRAIN_INTERACTIVE_USER='$USER'; export SECONDBRAIN_INTERACTIVE_HOME='$HOME'; /bin/bash '$PRIV'" with administrator privileges
OSA
then
  python3 "$SANDBOX_DIR/network-guard.py" --refresh-pf >/dev/null 2>&1 || true
  if user_exists; then
    emit defend ok "Isolated overnight users (production + development), pf allowlist, activity log, Little Snitch keeper"
    exit 0
  fi
fi

emit defend manual "Admin password was declined — skills and connection logging still run as you; overnight isolation is off until you re-run setup"
exit 0
