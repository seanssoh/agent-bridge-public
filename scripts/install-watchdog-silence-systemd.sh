#!/usr/bin/env bash
# install-watchdog-silence-systemd.sh — issue #800 Track C
#
# Installs a systemd --user .service that runs bridge-watchdog-silence.py
# from the live install (`$BRIDGE_HOME/bridge-watchdog-silence.py`) under
# Restart=always. Linux sibling of
# scripts/install-watchdog-silence-launchagent.sh.
#
# Unlike the daemon-liveness pair (oneshot + timer), the silence watchdog
# itself runs a long-lived poll loop with its own pidlock, so a plain
# Type=simple Restart=always service is the right shape — there's no need
# for systemd to manage the poll cadence.

set -euo pipefail

BRIDGE_HOME_TARGET="${HOME}/.agent-bridge"
SERVICE_NAME="agent-bridge-watchdog-silence.service"
SERVICE_PATH=""
LOG_PATH=""
APPLY=0
ENABLE=0
PYTHON_PATH=""

# Pass-through env knobs. Empty means use script defaults.
SILENCE_THRESHOLD="${BRIDGE_DAEMON_SILENCE_THRESHOLD_SECONDS:-}"
SILENCE_POLL="${BRIDGE_DAEMON_SILENCE_POLL_INTERVAL_SECONDS:-}"
RESTART_COOLDOWN="${BRIDGE_DAEMON_SILENCE_RESTART_COOLDOWN_SECONDS:-}"

usage() {
  cat <<EOF
Usage: $0 [--bridge-home <dir>] [--service <name>] [--service-path <path>] [--log-path <path>] [--threshold <secs>] [--poll <secs>] [--cooldown <secs>] [--apply] [--enable]

Without --apply, prints the systemd user .service unit file.
With --apply, writes the unit to ~/.config/systemd/user (or --service-path target).
With --enable, also runs systemctl --user daemon-reload and enable --now on the service.

Issue #800 Track C: canonical install of bridge-watchdog-silence.py so the
daemon silent-hang recovery layer runs from a known-good path under
systemd Restart=always.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge-home)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      BRIDGE_HOME_TARGET="$2"
      shift 2
      ;;
    --service)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      SERVICE_NAME="$2"
      shift 2
      ;;
    --service-path)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      SERVICE_PATH="$2"
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
    --enable)
      APPLY=1
      ENABLE=1
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

[[ -n "$SERVICE_PATH" ]] || SERVICE_PATH="$HOME/.config/systemd/user/$SERVICE_NAME"
[[ -n "$LOG_PATH" ]] || LOG_PATH="$BRIDGE_HOME_TARGET/state/systemd-watchdog-silence.log"

for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 "$(command -v python3 2>/dev/null || true)" /usr/bin/python3; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  PYTHON_PATH="$candidate"
  break
done

if [[ -z "$PYTHON_PATH" ]]; then
  echo "[error] python3 not found" >&2
  exit 1
fi

ENV_LINES=()
ENV_LINES+=("Environment=BRIDGE_HOME=${BRIDGE_HOME_TARGET}")
if [[ -n "$SILENCE_THRESHOLD" ]]; then
  ENV_LINES+=("Environment=BRIDGE_DAEMON_SILENCE_THRESHOLD_SECONDS=${SILENCE_THRESHOLD}")
fi
if [[ -n "$SILENCE_POLL" ]]; then
  ENV_LINES+=("Environment=BRIDGE_DAEMON_SILENCE_POLL_INTERVAL_SECONDS=${SILENCE_POLL}")
fi
if [[ -n "$RESTART_COOLDOWN" ]]; then
  ENV_LINES+=("Environment=BRIDGE_DAEMON_SILENCE_RESTART_COOLDOWN_SECONDS=${RESTART_COOLDOWN}")
fi

ENV_BLOCK=$(printf '%s\n' "${ENV_LINES[@]}")

SERVICE_CONTENT="$(cat <<EOF
[Unit]
Description=Agent Bridge Daemon Silence Watchdog (#800 Track C)
After=agent-bridge-daemon.service

[Service]
Type=simple
ExecStart=${PYTHON_PATH} ${BRIDGE_HOME_TARGET}/bridge-watchdog-silence.py run
WorkingDirectory=${BRIDGE_HOME_TARGET}
${ENV_BLOCK}
Restart=always
RestartSec=10
StandardOutput=append:${LOG_PATH}
StandardError=append:${LOG_PATH}

[Install]
WantedBy=default.target
EOF
)"

if [[ $APPLY -eq 0 ]]; then
  printf 'service_path: %s\n' "$SERVICE_PATH"
  printf 'bridge_home: %s\n' "$BRIDGE_HOME_TARGET"
  printf 'log_path: %s\n' "$LOG_PATH"
  printf 'service: %s\n' "$SERVICE_NAME"
  printf 'python_path: %s\n' "$PYTHON_PATH"
  if [[ -n "$SILENCE_THRESHOLD" ]]; then printf 'threshold_seconds: %s\n' "$SILENCE_THRESHOLD"; fi
  if [[ -n "$SILENCE_POLL" ]]; then printf 'poll_seconds: %s\n' "$SILENCE_POLL"; fi
  if [[ -n "$RESTART_COOLDOWN" ]]; then printf 'cooldown_seconds: %s\n' "$RESTART_COOLDOWN"; fi
  printf '\n# %s\n' "$SERVICE_NAME"
  printf '%s\n' "$SERVICE_CONTENT"
  exit 0
fi

mkdir -p "$(dirname "$SERVICE_PATH")" "$(dirname "$LOG_PATH")"
printf '%s\n' "$SERVICE_CONTENT" >"$SERVICE_PATH"
echo "[info] wrote systemd user service: $SERVICE_PATH"

if [[ $ENABLE -eq 1 ]]; then
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "[error] systemctl not found; wrote unit but cannot enable" >&2
    exit 1
  fi
  systemctl --user daemon-reload
  systemctl --user enable --now "$SERVICE_NAME"
  echo "[info] enabled systemd user service: $SERVICE_NAME"
  echo "[info] inspect with: systemctl --user status $SERVICE_NAME"
fi

echo "[info] bridge_home: $BRIDGE_HOME_TARGET"
echo "[info] log_path: $LOG_PATH"
echo "[info] service_path: $SERVICE_PATH"
