#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
BRIDGE_HOME_DEFAULT="${HOME}/.agent-bridge"
BRIDGE_HOME_TARGET="$BRIDGE_HOME_DEFAULT"
LABEL_DEFAULT="ai.agent-bridge.daemon"
LABEL="$LABEL_DEFAULT"
PLIST_PATH=""
LOG_PATH=""
APPLY=0
LOAD=0
BASH_PATH=""

usage() {
  cat <<EOF
Usage: $0 [--bridge-home <dir>] [--label <launchd-label>] [--plist <path>] [--log-path <path>] [--apply] [--load]

Without --apply, prints the LaunchAgent plist.
With --apply, writes the plist to ~/Library/LaunchAgents (or --plist target).
With --load, also bootstraps and kickstarts the LaunchAgent after writing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge-home)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      BRIDGE_HOME_TARGET="$2"
      shift 2
      ;;
    --label)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      LABEL="$2"
      shift 2
      ;;
    --plist)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      PLIST_PATH="$2"
      shift 2
      ;;
    --log-path)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      LOG_PATH="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --load)
      APPLY=1
      LOAD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[error] unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "$PLIST_PATH" ]] || PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
[[ -n "$LOG_PATH" ]] || LOG_PATH="$BRIDGE_HOME_TARGET/state/launchagent.log"
for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  BASH_PATH="$candidate"
  break
done

if [[ -z "$BASH_PATH" ]]; then
  echo "[error] bash not found" >&2
  exit 1
fi

PLIST_CONTENT="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${BASH_PATH}</string>
    <string>${BRIDGE_HOME_TARGET}/bridge-daemon.sh</string>
    <string>run</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${BRIDGE_HOME_TARGET}</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>BRIDGE_HOME</key>
    <string>${BRIDGE_HOME_TARGET}</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>${LOG_PATH}</string>

  <key>StandardErrorPath</key>
  <string>${LOG_PATH}</string>
</dict>
</plist>
EOF
)"

if [[ $APPLY -eq 0 ]]; then
  printf 'plist_path: %s\n' "$PLIST_PATH"
  printf 'bridge_home: %s\n' "$BRIDGE_HOME_TARGET"
  printf 'log_path: %s\n\n' "$LOG_PATH"
  printf '%s\n' "$PLIST_CONTENT"
  exit 0
fi

mkdir -p "$(dirname "$PLIST_PATH")" "$(dirname "$LOG_PATH")"
printf '%s\n' "$PLIST_CONTENT" >"$PLIST_PATH"
echo "[info] wrote LaunchAgent plist: $PLIST_PATH"

# Issue #590 r2: persist the launchd config so bridge-lib.sh can resolve the
# correct log path under custom --label/--plist/--log-path installs without
# guessing. The marker doubles as the "we are launchd-managed" signal.
LAUNCHAGENT_CONFIG_PATH="$BRIDGE_HOME_TARGET/state/launchagent.config"
mkdir -p "$(dirname "$LAUNCHAGENT_CONFIG_PATH")"
{
  printf 'BRIDGE_LAUNCHAGENT_LABEL=%q\n' "$LABEL"
  printf 'BRIDGE_LAUNCHAGENT_PLIST=%q\n'  "$PLIST_PATH"
  printf 'BRIDGE_LAUNCHAGENT_LOG=%q\n'    "$LOG_PATH"
} >"$LAUNCHAGENT_CONFIG_PATH"
chmod 0600 "$LAUNCHAGENT_CONFIG_PATH"
echo "[info] wrote launchagent config: $LAUNCHAGENT_CONFIG_PATH"

if [[ $LOAD -eq 1 ]]; then
  launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$PLIST_PATH"
  launchctl enable "gui/$UID/$LABEL" >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$UID/$LABEL"
  echo "[info] loaded LaunchAgent: $LABEL"
  echo "[info] inspect with: launchctl print gui/$UID/$LABEL"
fi

echo "[info] bridge_home: $BRIDGE_HOME_TARGET"
echo "[info] log_path: $LOG_PATH"
echo "[info] plist_path: $PLIST_PATH"
