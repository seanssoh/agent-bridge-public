#!/usr/bin/env bash
# scripts/install-handoffd-systemd.sh — render/install a systemd-user unit
# for the A2A receiver daemon (`bridge-handoffd.py serve`).
#
# Issue #1262 Gap 1 (v0.15.0-beta4 Lane I, 2026-05-27): the A2A receiver
# daemon ships as a manual lifecycle script (bridge-handoff-daemon.sh
# start|stop|restart|tick) with no auto-install pathway. Operators who
# enable A2A at install time still have to hand-craft a systemd unit (or
# remember to invoke the tick from cron), which means every fresh A2A
# install starts in a configured-but-not-running state until the operator
# notices.
#
# Mirror of scripts/install-daemon-systemd.sh, narrowed to the receiver
# lifecycle:
#   - Without --apply: prints the rendered unit to stdout.
#   - With --apply: writes to ~/.config/systemd/user/agb-handoffd.service.
#   - With --enable: also runs systemctl --user daemon-reload + enable --now.
#
# All log lines go to stderr — bridge-init.sh captures this script's stdout
# when forwarding through `--json`, and log lines on stdout poison
# bridge-bootstrap.sh's JSON parser (same #1230 convention as
# install-daemon-systemd.sh).

set -euo pipefail

BRIDGE_HOME_TARGET="${HOME}/.agent-bridge"
UNIT_NAME="agb-handoffd.service"
SERVICE_PATH=""
LOG_PATH=""
APPLY=0
ENABLE=0
SOURCE_DIR=""

usage() {
  cat <<EOF
Usage: $0 [--bridge-home <dir>] [--source-dir <dir>] [--unit <service-name>]
       [--service-path <path>] [--log-path <path>] [--apply] [--enable]

Without --apply, prints the systemd user unit file (to stdout).
With --apply, writes the unit to ~/.config/systemd/user (or --service-path
target).
With --enable, also runs systemctl --user daemon-reload and enable --now.

Source-dir defaults to the directory holding this script's parent (i.e.
the source checkout root). Pass --source-dir explicitly if invoking from
outside the checkout (e.g. from the live runtime where the rendered
ExecStart needs to point at the recorded source root).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge-home)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      BRIDGE_HOME_TARGET="$2"
      shift 2
      ;;
    --source-dir)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      SOURCE_DIR="$2"
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
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SOURCE_DIR" ]]; then
  SOURCE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fi
if [[ ! -f "$SOURCE_DIR/bridge-handoffd.py" ]]; then
  echo "[error] --source-dir does not contain bridge-handoffd.py: $SOURCE_DIR" >&2
  exit 1
fi

# Default service path to systemd-user directory.
if [[ -z "$SERVICE_PATH" ]]; then
  SERVICE_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UNIT_NAME"
fi
if [[ -z "$LOG_PATH" ]]; then
  LOG_PATH="$BRIDGE_HOME_TARGET/logs/a2a-handoffd.log"
fi

# Resolve a python3 path the unit can use. Falling back to /usr/bin/env is
# the safest — systemd-user inherits PATH from the operator's login shell,
# but `env` ensures we don't pin a specific interpreter that might not
# exist on minimal hosts.
PYTHON_BIN="$(command -v python3 || true)"
if [[ -z "$PYTHON_BIN" ]]; then
  PYTHON_BIN="/usr/bin/env python3"
fi

CONFIG_PATH="$BRIDGE_HOME_TARGET/handoff.local.json"

# Unit content. The receiver's `serve --detach` would race with
# systemd's own pid tracking, so we explicitly DROP `--detach` for the
# systemd-managed path — systemd is the lifecycle owner, not nohup.
# The receiver still writes a pidfile for the bridge-a2a CLI to consult,
# but the unit's Type=simple keeps systemd in charge of restart/stop.
UNIT_CONTENT="$(cat <<EOF
[Unit]
Description=Agent Bridge A2A handoff receiver
Documentation=https://github.com/SYRS-AI/agent-bridge-public/blob/main/docs/a2a-cross-bridge.md
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
Environment=BRIDGE_HOME=$BRIDGE_HOME_TARGET
ExecStart=$PYTHON_BIN $SOURCE_DIR/bridge-handoffd.py serve --config $CONFIG_PATH --pidfile $BRIDGE_HOME_TARGET/state/handoff/handoffd.pid
Restart=on-failure
RestartSec=5
StandardOutput=append:$LOG_PATH
StandardError=append:$LOG_PATH

[Install]
WantedBy=default.target
EOF
)"

if [[ $APPLY -eq 0 ]]; then
  # Print rendered unit to stdout (operator can redirect / inspect).
  printf 'bridge_home: %s\n' "$BRIDGE_HOME_TARGET" >&2
  printf 'source_dir: %s\n' "$SOURCE_DIR" >&2
  printf 'log_path: %s\n' "$LOG_PATH" >&2
  printf 'unit: %s\n' "$UNIT_NAME" >&2
  printf '%s\n' "$UNIT_CONTENT"
  exit 0
fi

mkdir -p "$(dirname "$SERVICE_PATH")" "$(dirname "$LOG_PATH")"
printf '%s\n' "$UNIT_CONTENT" >"$SERVICE_PATH"
echo "[info] wrote A2A handoffd systemd user unit: $SERVICE_PATH" >&2

if [[ $ENABLE -eq 1 ]]; then
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "[error] systemctl not found; wrote unit but cannot enable it" >&2
    exit 1
  fi
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT_NAME"
  echo "[info] enabled systemd user unit: $UNIT_NAME" >&2
  echo "[info] inspect with: systemctl --user status $UNIT_NAME" >&2
fi

echo "[info] bridge_home: $BRIDGE_HOME_TARGET" >&2
echo "[info] log_path: $LOG_PATH" >&2
echo "[info] service_path: $SERVICE_PATH" >&2
echo "mode=systemd-user" >&2
