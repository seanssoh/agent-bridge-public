#!/usr/bin/env bash

set -euo pipefail

BRIDGE_HOME_TARGET="${HOME}/.agent-bridge"
UNIT_NAME="agent-bridge-daemon.service"
SERVICE_PATH=""
LOG_PATH=""
APPLY=0
ENABLE=0
BASH_PATH=""

usage() {
  cat <<EOF
Usage: $0 [--bridge-home <dir>] [--unit <service-name>] [--service-path <path>] [--log-path <path>] [--apply] [--enable]

Without --apply, prints the systemd user unit file.
With --apply, writes the unit to ~/.config/systemd/user (or --service-path target).
With --enable, also runs systemctl --user daemon-reload and enable --now.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge-home)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      BRIDGE_HOME_TARGET="$2"
      shift 2
      ;;
    --unit)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      UNIT_NAME="$2"
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

[[ -n "$SERVICE_PATH" ]] || SERVICE_PATH="$HOME/.config/systemd/user/$UNIT_NAME"
[[ -n "$LOG_PATH" ]] || LOG_PATH="$BRIDGE_HOME_TARGET/state/systemd-daemon.log"

for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)" /bin/bash; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  BASH_PATH="$candidate"
  break
done

if [[ -z "$BASH_PATH" ]]; then
  echo "[error] bash not found" >&2
  exit 1
fi

UNIT_CONTENT="$(cat <<EOF
[Unit]
Description=Agent Bridge Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BASH_PATH} ${BRIDGE_HOME_TARGET}/bridge-daemon.sh run
WorkingDirectory=${BRIDGE_HOME_TARGET}
Environment=BRIDGE_HOME=${BRIDGE_HOME_TARGET}
Restart=always
RestartSec=5
# Without KillMode=process the default control-group mode SIGKILLs every
# child in the daemon's service cgroup on every restart — tmux servers,
# claude, codex, plugin processes — which makes "stop the daemon" silently
# mean "kill every running agent on this host." KillMode=process limits the
# kill to the daemon process itself; agent children stay up across daemon
# restarts initiated by the upgrader, the silence watchdog, or admin tooling.
KillMode=process
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
  printf 'unit: %s\n\n' "$UNIT_NAME"
  printf '%s\n' "$UNIT_CONTENT"
  exit 0
fi

mkdir -p "$(dirname "$SERVICE_PATH")" "$(dirname "$LOG_PATH")"
printf '%s\n' "$UNIT_CONTENT" >"$SERVICE_PATH"
echo "[info] wrote systemd user unit: $SERVICE_PATH"

if [[ $ENABLE -eq 1 ]]; then
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "[error] systemctl not found; wrote unit but cannot enable it" >&2
    exit 1
  fi
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT_NAME"
  echo "[info] enabled systemd user unit: $UNIT_NAME"
  echo "[info] inspect with: systemctl --user status $UNIT_NAME"
fi

echo "[info] bridge_home: $BRIDGE_HOME_TARGET"
echo "[info] log_path: $LOG_PATH"
echo "[info] service_path: $SERVICE_PATH"
