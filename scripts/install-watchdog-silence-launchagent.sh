#!/usr/bin/env bash
# install-watchdog-silence-launchagent.sh — issue #800 Track C
#
# Installs a macOS LaunchAgent that runs bridge-watchdog-silence.py from the
# live install (`$BRIDGE_HOME/bridge-watchdog-silence.py`) under launchd
# KeepAlive. Sibling of ai.agent-bridge.daemon-liveness — see
# scripts/install-daemon-liveness-launchagent.sh for the parallel pattern.
#
# Why a separate plist:
#   The silence watchdog is the second-line recovery layer for daemon
#   silent-hangs (issue #265). Before this script existed, the watchdog was
#   only ever launched ad-hoc out of test sessions / worktrees — every one
#   of those instances permanently bound DAEMON_SCRIPT to a now-deleted
#   path and could not recover the live daemon. A canonical KeepAlive
#   process under launchd ensures the recovery layer survives reboots,
#   crashes, and operator session churn without operator intervention.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
BRIDGE_HOME_DEFAULT="${HOME}/.agent-bridge"
BRIDGE_HOME_TARGET="$BRIDGE_HOME_DEFAULT"
LABEL_DEFAULT="ai.agent-bridge.watchdog-silence"
LABEL="$LABEL_DEFAULT"
PLIST_PATH=""
LOG_PATH=""
APPLY=0
LOAD=0
BASH_PATH=""
PYTHON_PATH=""

# Pass-through env knobs. Empty means "let the script use its built-in
# default" so we don't lock the operator into a value here.
SILENCE_THRESHOLD="${BRIDGE_DAEMON_SILENCE_THRESHOLD_SECONDS:-}"
SILENCE_POLL="${BRIDGE_DAEMON_SILENCE_POLL_INTERVAL_SECONDS:-}"
RESTART_COOLDOWN="${BRIDGE_DAEMON_SILENCE_RESTART_COOLDOWN_SECONDS:-}"

usage() {
  cat <<EOF
Usage: $0 [--bridge-home <dir>] [--label <launchd-label>] [--plist <path>] [--log-path <path>] [--threshold <secs>] [--poll <secs>] [--cooldown <secs>] [--apply] [--load]

Without --apply, prints the LaunchAgent plist for the silence watchdog.
With --apply, writes the plist to ~/Library/LaunchAgents (or --plist target).
With --load, also bootstraps and kickstarts the LaunchAgent after writing.

Issue #800 Track C: canonical install of bridge-watchdog-silence.py so the
daemon silent-hang recovery layer runs from a known-good path under
launchd KeepAlive, instead of accumulating orphan instances from worktrees
and temp dirs that get deleted.
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
    --threshold)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      SILENCE_THRESHOLD="$2"
      shift 2
      ;;
    --poll)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      SILENCE_POLL="$2"
      shift 2
      ;;
    --cooldown)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      RESTART_COOLDOWN="$2"
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

for v in "$SILENCE_THRESHOLD" "$SILENCE_POLL" "$RESTART_COOLDOWN"; do
  [[ -z "$v" ]] && continue
  [[ "$v" =~ ^[0-9]+$ ]] || { echo "[error] integer env knob got non-integer value: $v" >&2; exit 1; }
done

[[ -n "$PLIST_PATH" ]] || PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
[[ -n "$LOG_PATH" ]] || LOG_PATH="$BRIDGE_HOME_TARGET/state/watchdog-silence.log"

for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  BASH_PATH="$candidate"
  break
done

if [[ -z "$BASH_PATH" ]]; then
  echo "[error] bash not found" >&2
  exit 1
fi

for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 2>/dev/null || true)" /usr/bin/python3; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  PYTHON_PATH="$candidate"
  break
done

if [[ -z "$PYTHON_PATH" ]]; then
  echo "[error] python3 not found" >&2
  exit 1
fi

# We point ProgramArguments at $BRIDGE_HOME_TARGET/bridge-watchdog-silence.py
# (the deployed live-install copy), not the source checkout, so an `agb
# upgrade` that lays down a new script body is picked up on the next launchd
# respawn without re-editing the plist.
ENV_LINES=()
ENV_LINES+=("    <key>BRIDGE_HOME</key>")
ENV_LINES+=("    <string>${BRIDGE_HOME_TARGET}</string>")
if [[ -n "$SILENCE_THRESHOLD" ]]; then
  ENV_LINES+=("    <key>BRIDGE_DAEMON_SILENCE_THRESHOLD_SECONDS</key>")
  ENV_LINES+=("    <string>${SILENCE_THRESHOLD}</string>")
fi
if [[ -n "$SILENCE_POLL" ]]; then
  ENV_LINES+=("    <key>BRIDGE_DAEMON_SILENCE_POLL_INTERVAL_SECONDS</key>")
  ENV_LINES+=("    <string>${SILENCE_POLL}</string>")
fi
if [[ -n "$RESTART_COOLDOWN" ]]; then
  ENV_LINES+=("    <key>BRIDGE_DAEMON_SILENCE_RESTART_COOLDOWN_SECONDS</key>")
  ENV_LINES+=("    <string>${RESTART_COOLDOWN}</string>")
fi

ENV_BLOCK=$(printf '%s\n' "${ENV_LINES[@]}")

PLIST_CONTENT="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${PYTHON_PATH}</string>
    <string>${BRIDGE_HOME_TARGET}/bridge-watchdog-silence.py</string>
    <string>run</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${BRIDGE_HOME_TARGET}</string>

  <key>EnvironmentVariables</key>
  <dict>
${ENV_BLOCK}
  </dict>

  <key>KeepAlive</key>
  <true/>

  <key>RunAtLoad</key>
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
  printf 'log_path: %s\n' "$LOG_PATH"
  printf 'label: %s\n' "$LABEL"
  printf 'python_path: %s\n' "$PYTHON_PATH"
  if [[ -n "$SILENCE_THRESHOLD" ]]; then printf 'threshold_seconds: %s\n' "$SILENCE_THRESHOLD"; fi
  if [[ -n "$SILENCE_POLL" ]]; then printf 'poll_seconds: %s\n' "$SILENCE_POLL"; fi
  if [[ -n "$RESTART_COOLDOWN" ]]; then printf 'cooldown_seconds: %s\n' "$RESTART_COOLDOWN"; fi
  printf '\n'
  printf '%s\n' "$PLIST_CONTENT"
  exit 0
fi

mkdir -p "$(dirname "$PLIST_PATH")" "$(dirname "$LOG_PATH")"
printf '%s\n' "$PLIST_CONTENT" >"$PLIST_PATH"
echo "[info] wrote LaunchAgent plist: $PLIST_PATH"

if [[ $LOAD -eq 1 ]]; then
  launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$PLIST_PATH"
  launchctl enable "gui/$UID/$LABEL" >/dev/null 2>&1 || true
  launchctl kickstart "gui/$UID/$LABEL"
  echo "[info] loaded LaunchAgent: $LABEL"
  echo "[info] inspect with: launchctl print gui/$UID/$LABEL"
fi

echo "[info] bridge_home: $BRIDGE_HOME_TARGET"
echo "[info] log_path: $LOG_PATH"
echo "[info] plist_path: $PLIST_PATH"

# Reference unused for shellcheck — REPO_ROOT is kept for parity with the
# sibling installers in case future work needs source-checkout discovery.
: "${REPO_ROOT}"
