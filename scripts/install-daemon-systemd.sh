#!/usr/bin/env bash

set -euo pipefail

BRIDGE_HOME_TARGET="${HOME}/.agent-bridge"
UNIT_NAME="agent-bridge-daemon.service"
SERVICE_PATH=""
LOG_PATH=""
APPLY=0
ENABLE=0
BASH_PATH=""
# Beta20 L2 Variant 3A r4 (codex /tmp/agb-6281-l2-r4-systemd.md): the
# rendered ExecStart can optionally cross the sudo-to-self refresh
# boundary so every systemd-driven daemon start runs through PAM and
# inherits fresh supplementary credentials. Without this, a stale
# systemd-user manager keeps spawning daemons with frozen group sets,
# defeating the r3 ad-hoc sudo restart (Restart=always wins the race).
# Auto-detected: if the daemon-refresh sudoers drop-in is installed
# AND `sudo -n -u <user> -H -- <bash> -c 'id -G'` actually returns
# refreshed groups, the renderer switches to the sudo-wrapped shape.
# Operator overrides:
#   --sudo-self           force sudo-wrapped ExecStart
#   --no-sudo-self        force direct ExecStart (legacy)
#   --controller-user <u> override the named controller user
SUDO_SELF_MODE=""      # "", "force", "force-off"
CONTROLLER_USER=""     # explicit override
SUDO_PATH=""

usage() {
  cat <<EOF
Usage: $0 [--bridge-home <dir>] [--unit <service-name>] [--service-path <path>] [--log-path <path>]
       [--apply] [--enable] [--sudo-self | --no-sudo-self] [--controller-user <user>]

Without --apply, prints the systemd user unit file.
With --apply, writes the unit to ~/.config/systemd/user (or --service-path target).
With --enable, also runs systemctl --user daemon-reload and enable --now.

Beta20 L2 Variant 3A r4 — sudo-wrapped ExecStart:
  Auto-renders sudo-wrapped ExecStart when the daemon-refresh sudoers
  drop-in is present AND sudo+PAM actually refreshes groups. This
  makes every systemd-driven daemon start cross the PAM credential
  refresh boundary so per-agent group memberships added via
  'agent create --isolate' become visible to the daemon without a
  user relogin.

  --sudo-self          Force sudo-wrapped ExecStart even when auto-detect
                       would skip it. Fails the install if the sudoers
                       drop-in is missing or non-functional.
  --no-sudo-self       Force the legacy direct ExecStart (no sudo wrap).
                       Use only if you are intentionally opting out of
                       automatic supp-groups refresh.
  --controller-user U  Pin the named controller user used in the sudo
                       wrapper. Defaults to \$USER / id -un.
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
    --sudo-self)
      SUDO_SELF_MODE="force"
      shift
      ;;
    --no-sudo-self)
      SUDO_SELF_MODE="force-off"
      shift
      ;;
    --controller-user)
      [[ $# -lt 2 ]] && { usage; exit 1; }
      CONTROLLER_USER="$2"
      shift 2
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

# Beta20 L2 Variant 3A r4 — decide whether to render a sudo-wrapped
# ExecStart. Auto-detect: sudoers drop-in present AND
# `sudo -n -u <user> -H -- bash -c id -G` actually refreshes groups.
# Operator override via --sudo-self / --no-sudo-self.
SUDO_SELF_ACTIVE=0
SUDO_SELF_REASON=""
[[ -n "$CONTROLLER_USER" ]] || CONTROLLER_USER="${USER:-$(id -un 2>/dev/null || true)}"

probe_sudo_self_refresh() {
  # rc=0 → sudo+PAM refresh works AND the daemon-refresh sudoers
  # drop-in authorizes this exact command. rc!=0 → sudoers absent /
  # refusing the named user / sudo binary missing.
  #
  # #1228 (v0.15.0-beta4): the prior implementation tried to confirm
  # the drop-in existence via `set -- /etc/sudoers.d/<glob>; [[ -e $1 ]]`.
  # On Debian / Ubuntu / RHEL the controller user cannot `opendir(3)`
  # /etc/sudoers.d/ (mode 750 root:root), so the glob never expanded
  # and the probe returned 1 even when the file objectively existed.
  # Downstream the systemd unit silently shipped with the legacy
  # direct-bash ExecStart, Lane F auto-recovery was effectively dead,
  # and the operator-facing "regenerated (sudo-self) and restarted"
  # message lied about what was actually written.
  #
  # Replacement: ask sudo's policy resolver directly via
  # `sudo -n -ln <exact-command>`. That returns rc=0 iff the user has
  # a matching NOPASSWD policy entry for the EXACT command path + args
  # we plan to run; it does not require readable /etc/sudoers.d/. The
  # original false-positive concern (auto-enabling sudo-self ExecStart
  # because generic "sudo to self" trivially works) is addressed by
  # listing a SPECIFIC fully-qualified command rather than the bare
  # user — generic sudo-to-self does not match this command listing.
  local user="$1"
  local bash="$2"
  [[ -n "$user" && -n "$bash" ]] || return 1

  # Resolve the bridge_home the daemon-refresh sudoers drop-in was
  # rendered for. The sudoers template (see
  # scripts/sudoers-templates/agent-bridge-daemon-refresh.sudo.template)
  # authorizes a specific bash + bridge_home + bridge-daemon.sh path,
  # so the probe must list the same string — anything else (e.g. a
  # different BRIDGE_HOME path) is correctly treated as "drop-in not
  # installed for this install" and falls back to the legacy ExecStart.
  local bridge_home="${BRIDGE_HOME_TARGET:-${BRIDGE_HOME:-$HOME/.agent-bridge}}"
  local refresh_cmd="${bash} ${bridge_home}/bridge-daemon.sh restart --force --internal-reason=group-refresh"
  # shellcheck disable=SC2086  # intentional command-as-args expansion
  if ! sudo -n -ln $refresh_cmd >/dev/null 2>&1; then
    return 1
  fi

  # Defense-in-depth: confirm sudo actually executes a child as the
  # named user (PAM refresh probe). Catches edge cases where the
  # policy is listed but the underlying mechanism is broken
  # (e.g. PAM module misconfigured, audit-only authorization).
  local out=""
  if ! out="$(sudo -n -u "$user" -H -- "$bash" -c 'id -G' 2>/dev/null)"; then
    return 1
  fi
  [[ -n "$out" ]] || return 1
  return 0
}

SUDO_PATH="$(command -v sudo 2>/dev/null || true)"

case "$SUDO_SELF_MODE" in
  force)
    if [[ -z "$SUDO_PATH" ]]; then
      echo "[error] --sudo-self requested but sudo binary not found" >&2
      exit 1
    fi
    if ! probe_sudo_self_refresh "$CONTROLLER_USER" "$BASH_PATH"; then
      echo "[error] --sudo-self requested but sudo+PAM refresh probe failed for user='$CONTROLLER_USER'" >&2
      echo "[error]   Hint: run 'agent-bridge init sudoers daemon-refresh --apply' first" >&2
      exit 1
    fi
    SUDO_SELF_ACTIVE=1
    SUDO_SELF_REASON="forced-via-flag"
    ;;
  force-off)
    SUDO_SELF_ACTIVE=0
    SUDO_SELF_REASON="forced-off-via-flag"
    ;;
  "")
    # Auto-detect. Require sudo binary AND working PAM refresh.
    if [[ -n "$SUDO_PATH" ]] && probe_sudo_self_refresh "$CONTROLLER_USER" "$BASH_PATH"; then
      SUDO_SELF_ACTIVE=1
      SUDO_SELF_REASON="auto-detected-sudoers-refresh-ok"
    else
      SUDO_SELF_REASON="auto-detected-no-sudoers-or-refresh-failed"
    fi
    ;;
esac

if [[ $SUDO_SELF_ACTIVE -eq 1 ]]; then
  # Codex r4 spec exact shape — named user, --preserve-env restricted
  # to the BRIDGE_* set the daemon needs, absolute sudo + absolute bash
  # + absolute bridge_home, exact daemon `run` invocation. The sudoers
  # drop-in installed by `agent-bridge init sudoers daemon-refresh
  # --apply` authorizes this exact command (no wildcards).
  EXEC_START_LINE="ExecStart=${SUDO_PATH} -n -u ${CONTROLLER_USER} -H --preserve-env=BRIDGE_HOME,BRIDGE_STATE_DIR,BRIDGE_LAYOUT_MARKER_DIR,BRIDGE_ROSTER_FILE,BRIDGE_ROSTER_LOCAL_FILE,BRIDGE_TASK_DB,BRIDGE_BASH_BIN -- ${BASH_PATH} ${BRIDGE_HOME_TARGET}/bridge-daemon.sh run"
  REFRESH_MODE_ENV="Environment=BRIDGE_DAEMON_SYSTEMD_REFRESH_MODE=sudo-self"
else
  EXEC_START_LINE="ExecStart=${BASH_PATH} ${BRIDGE_HOME_TARGET}/bridge-daemon.sh run"
  REFRESH_MODE_ENV=""
fi

# Render the unit. The optional refresh-mode env is emitted as a
# separate line only when sudo-self is active so the legacy direct
# unit shape stays byte-equal to the pre-r4 output on hosts that
# explicitly opt out (--no-sudo-self) or lack sudoers.
UNIT_CONTENT="$(
  printf '%s\n' \
    '[Unit]' \
    'Description=Agent Bridge Daemon' \
    'After=network-online.target' \
    'Wants=network-online.target' \
    '' \
    '[Service]' \
    'Type=simple' \
    "$EXEC_START_LINE" \
    "WorkingDirectory=${BRIDGE_HOME_TARGET}" \
    "Environment=BRIDGE_HOME=${BRIDGE_HOME_TARGET}"
  if [[ -n "$REFRESH_MODE_ENV" ]]; then
    printf '%s\n' "$REFRESH_MODE_ENV"
  fi
  printf '%s\n' \
    'Restart=always' \
    'RestartSec=5' \
    '# Without KillMode=process the default control-group mode SIGKILLs every' \
    "# child in the daemon's service cgroup on every restart — tmux servers," \
    '# claude, codex, plugin processes — which makes "stop the daemon" silently' \
    '# mean "kill every running agent on this host." KillMode=process limits the' \
    '# kill to the daemon process itself; agent children stay up across daemon' \
    '# restarts initiated by the upgrader, the silence watchdog, or admin tooling.' \
    '#' \
    '# r4 follow-up: with sudo-wrapped ExecStart the main PID may be `sudo`' \
    '# rather than `bash`. KillMode=process still kills only that one PID;' \
    '# the sudo child (bash bridge-daemon.sh run) exits when its parent sudo' \
    '# terminates, and operator-driven stop via `bash bridge-daemon.sh stop' \
    '# --force` continues to sweep orphaned daemon processes by cmdline.' \
    'KillMode=process' \
    "StandardOutput=append:${LOG_PATH}" \
    "StandardError=append:${LOG_PATH}" \
    '' \
    '[Install]' \
    'WantedBy=default.target'
)"

if [[ $APPLY -eq 0 ]]; then
  printf 'service_path: %s\n' "$SERVICE_PATH"
  printf 'bridge_home: %s\n' "$BRIDGE_HOME_TARGET"
  printf 'log_path: %s\n' "$LOG_PATH"
  printf 'unit: %s\n' "$UNIT_NAME"
  printf 'sudo_self_active: %s\n' "$SUDO_SELF_ACTIVE"
  printf 'sudo_self_reason: %s\n' "$SUDO_SELF_REASON"
  if [[ $SUDO_SELF_ACTIVE -eq 1 ]]; then
    printf 'controller_user: %s\n' "$CONTROLLER_USER"
    printf 'sudo_path: %s\n\n' "$SUDO_PATH"
  else
    printf '\n'
  fi
  printf '%s\n' "$UNIT_CONTENT"
  exit 0
fi

mkdir -p "$(dirname "$SERVICE_PATH")" "$(dirname "$LOG_PATH")"
printf '%s\n' "$UNIT_CONTENT" >"$SERVICE_PATH"
# #1230 (v0.15.0-beta4): logger output goes to stderr — bridge-init.sh
# captures this script's stdout when forwarding through `--json`, and
# log lines on stdout poison bridge-bootstrap.sh's JSON parser. Same
# convention as the bridge_info → stderr fix (#1273) for lib/bridge-core.sh.
echo "[info] wrote systemd user unit: $SERVICE_PATH" >&2
if [[ $SUDO_SELF_ACTIVE -eq 1 ]]; then
  echo "[info] sudo-self ExecStart active (reason=${SUDO_SELF_REASON} user=${CONTROLLER_USER})" >&2
else
  # #1228 (v0.15.0-beta4): when the install drops back to legacy direct
  # ExecStart (sudoers drop-in absent, probe failed, or operator opted
  # out), emit a loud warning + audit row so operators see the structural
  # state instead of the prior silent fallback. The probe fix above
  # eliminates the false-negative on hosts with root-only /etc/sudoers.d/,
  # but legitimate legacy installs (no sudoers drop-in installed) still
  # land here — and they deserve a clear signal that supp-group refresh
  # won't auto-recover.
  echo "[warn] sudo-self ExecStart NOT active (reason=${SUDO_SELF_REASON}) — daemon supplementary-group refresh will NOT cross PAM on restart. Run 'agent-bridge init sudoers daemon-refresh --apply' to enable auto-refresh." >&2
  # Best-effort audit emit — non-fatal on hosts where the audit helper
  # is unavailable (e.g. install-daemon-systemd.sh invoked standalone).
  if command -v bridge_audit_log >/dev/null 2>&1; then
    bridge_audit_log install systemd_unit_legacy_fallback "${CONTROLLER_USER:-unknown}" \
      --detail reason="$SUDO_SELF_REASON" \
      --detail service_path="$SERVICE_PATH" \
      2>/dev/null || true
  fi
fi

if [[ $ENABLE -eq 1 ]]; then
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "[error] systemctl not found; wrote unit but cannot enable it" >&2
    exit 1
  fi
  systemctl --user daemon-reload
  # When the unit is already enabled+active, `enable --now` is a no-op
  # for the runtime — operators expect the apply step to actually pick
  # up the new ExecStart, so we follow with an explicit restart when
  # the service is already active. The systemctl restart on a sudo-
  # wrapped ExecStart is the very mechanism r4's refresh helper relies
  # on, so doing it here at install time is the same code path.
  systemctl --user enable --now "$UNIT_NAME"
  if systemctl --user is-active --quiet "$UNIT_NAME"; then
    systemctl --user restart "$UNIT_NAME"
    echo "[info] restarted active systemd user unit to pick up new ExecStart" >&2
  fi
  echo "[info] enabled systemd user unit: $UNIT_NAME" >&2
  echo "[info] inspect with: systemctl --user status $UNIT_NAME" >&2
fi

echo "[info] bridge_home: $BRIDGE_HOME_TARGET" >&2
echo "[info] log_path: $LOG_PATH" >&2
echo "[info] service_path: $SERVICE_PATH" >&2

# #1228 (v0.15.0-beta4): emit a machine-parseable mode keyword so
# bridge-init.sh can render the operator-facing message accurately
# (sudo-self vs legacy) instead of unconditionally printing
# "regenerated (sudo-self) and restarted" — which lied on every install
# where probe_sudo_self_refresh returned 1 (essentially every Debian /
# Ubuntu / RHEL host before the glob fix above).
if [[ $SUDO_SELF_ACTIVE -eq 1 ]]; then
  echo "mode=sudo-self" >&2
else
  echo "mode=legacy" >&2
fi
