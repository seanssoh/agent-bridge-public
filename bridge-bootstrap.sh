#!/usr/bin/env bash
# bridge-bootstrap.sh — AI-native bootstrap wrapper for fresh installs

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Issue #665: arm the fresh-install resolver bypass before sourcing
# bridge-lib.sh. See bridge-init.sh for the rationale and contract — the
# resolver only honors the bypass when classification is
# fresh-install-candidate, so an existing markerless install still trips
# the v0.8.0 fail-fast. The trap clears the bypass on exit so a crashed
# bootstrap does not leave the env in a state that disarms the resolver
# for sibling shells.
_BRIDGE_BOOTSTRAP_BYPASS_NONCE="$(date -u '+%Y%m%dT%H%M%SZ')-$$-${RANDOM}${RANDOM}"
export BRIDGE_LAYOUT_RESOLVER_BYPASS="fresh-install:${_BRIDGE_BOOTSTRAP_BYPASS_NONCE}"
export BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID=$$
trap 'unset BRIDGE_LAYOUT_RESOLVER_BYPASS BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID' EXIT
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
# Issue #1058: managed tmux UX defaults for Claude/Codex TUI sessions.
# shellcheck source=lib/bridge-tmux-ux.sh
source "$SCRIPT_DIR/lib/bridge-tmux-ux.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [bootstrap options...] [init options...]

Bootstrap options:
  --shell <name>          Shell to integrate (default: current shell basename, fallback zsh)
  --rcfile <path>         Override shell rc file target
  --skip-shell-integration
  --skip-tmux-ux           Do not write the managed tmux UX block to ~/.tmux.conf
  --skip-daemon
  --skip-launchagent      Do not install/load the macOS LaunchAgent
  --skip-systemd          Do not install/enable the Linux systemd user unit
  --skip-liveness         Do not install the daemon liveness watcher (issue #265 D)
  --skip-watchdog-silence Do not install the silence watchdog OS unit (issue #800 C)
  --dry-run
  --json

Everything else is forwarded to \`agent-bridge init\`.

Examples:
  $(basename "$0") --admin manager --engine claude --channels plugin:telegram@claude-plugins-official --allow-from 123456789 --default-chat 123456789
  $(basename "$0") --admin manager --engine claude --dry-run --json
EOF
}

bootstrap_shell="${SHELL##*/}"
bootstrap_shell="${bootstrap_shell:-zsh}"
bootstrap_rcfile=""
skip_shell_integration=0
skip_tmux_ux=0
skip_daemon=0
skip_launchagent=0
skip_systemd=0
skip_liveness=0
skip_watchdog_silence=0
dry_run=0
json_mode=0
init_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      bootstrap_shell="$2"
      shift 2
      ;;
    --rcfile)
      [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
      bootstrap_rcfile="$2"
      shift 2
      ;;
    --skip-shell-integration)
      skip_shell_integration=1
      shift
      ;;
    --skip-tmux-ux)
      skip_tmux_ux=1
      shift
      ;;
    --skip-daemon)
      skip_daemon=1
      shift
      ;;
    --skip-launchagent)
      skip_launchagent=1
      shift
      ;;
    --skip-systemd)
      skip_systemd=1
      shift
      ;;
    --skip-liveness)
      skip_liveness=1
      shift
      ;;
    --skip-watchdog-silence)
      skip_watchdog_silence=1
      shift
      ;;
    --dry-run)
      dry_run=1
      init_args+=("$1")
      shift
      ;;
    --json)
      json_mode=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      init_args+=("$1")
      shift
      ;;
  esac
done

case "$bootstrap_shell" in
  zsh|bash) ;;
  *)
    bridge_die "지원하지 않는 shell 입니다: $bootstrap_shell"
    ;;
esac

if [[ -z "$bootstrap_rcfile" ]]; then
  case "$bootstrap_shell" in
    zsh)
      bootstrap_rcfile="$HOME/.zshrc"
      ;;
    bash)
      bootstrap_rcfile="$HOME/.bashrc"
      ;;
  esac
fi

bridge_require_python

shell_status="skipped"
tmux_ux_status="skipped"
daemon_status="skipped"
launchagent_status="skipped"
systemd_status="skipped"
liveness_status="skipped"
watchdog_silence_status="skipped"
next_command="agb admin"
reload_command="source \"$bootstrap_rcfile\" || export PATH=\"\$HOME/.agent-bridge:\$PATH\""
bootstrap_os="${BRIDGE_BOOTSTRAP_OS:-$(uname -s)}"

if [[ $skip_shell_integration -eq 0 ]]; then
  shell_status="planned"
  if [[ $dry_run -eq 0 ]]; then
    shell_args=(--shell "$bootstrap_shell" --apply)
    [[ -n "$bootstrap_rcfile" ]] && shell_args+=(--rcfile "$bootstrap_rcfile")
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/scripts/install-shell-integration.sh" "${shell_args[@]}" >/dev/null
    shell_status="applied"
  fi
fi

# Issue #1058: managed tmux UX defaults. Claude/Codex run inside tmux, and a
# fresh server's stock tmux settings (default-terminal screen, mouse off,
# escape-time 500) degrade the TUI. bridge_setup_tmux_ux writes an idempotent
# managed block to ~/.tmux.conf and is non-fatal by contract — it always
# returns 0, so a tmux/terminfo gap never aborts bootstrap.
if [[ $skip_tmux_ux -eq 0 ]]; then
  tmux_ux_status="planned"
  if [[ $dry_run -eq 0 ]]; then
    bridge_setup_tmux_ux >&2 || true
    tmux_ux_status="applied"
  else
    bridge_setup_tmux_ux --dry-run >&2 || true
  fi
fi

init_json="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-init.sh" "${init_args[@]}" --json)"

if [[ $skip_daemon -eq 0 ]]; then
  daemon_status="planned"
  if [[ $dry_run -eq 0 ]]; then
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-daemon.sh" ensure >/dev/null
    daemon_status="ensured"
  fi
fi

if [[ $skip_launchagent -eq 0 ]]; then
  if [[ "$bootstrap_os" == "Darwin" ]]; then
    launchagent_status="planned"
    if [[ $dry_run -eq 0 ]]; then
      "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/scripts/install-daemon-launchagent.sh" --apply --load >/dev/null
      launchagent_status="loaded"
    fi
  else
    launchagent_status="unsupported"
  fi
fi

if [[ $skip_systemd -eq 0 ]]; then
  if [[ "$bootstrap_os" == "Linux" ]]; then
    systemd_status="planned"
    if [[ $dry_run -eq 0 ]]; then
      "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/scripts/install-daemon-systemd.sh" --apply --enable >/dev/null
      systemd_status="enabled"
    fi
  else
    systemd_status="unsupported"
  fi
fi

# Issue #265 proposal D: install the OS-level liveness watcher alongside the
# daemon plist/unit. Skip if the operator opted out, if the matching daemon
# install was skipped (no point watching a heartbeat that nothing writes), or
# if the platform is unsupported.
if [[ $skip_liveness -eq 0 ]]; then
  case "$bootstrap_os" in
    Darwin)
      if [[ $skip_launchagent -eq 1 ]]; then
        liveness_status="skipped"
      else
        liveness_status="planned"
        if [[ $dry_run -eq 0 ]]; then
          "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/scripts/install-daemon-liveness-launchagent.sh" --apply --load >/dev/null
          liveness_status="loaded"
        fi
      fi
      ;;
    Linux)
      if [[ $skip_systemd -eq 1 ]]; then
        liveness_status="skipped"
      else
        liveness_status="planned"
        if [[ $dry_run -eq 0 ]]; then
          "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/scripts/install-daemon-liveness-systemd.sh" --apply --enable >/dev/null
          liveness_status="enabled"
        fi
      fi
      ;;
    *)
      liveness_status="unsupported"
      ;;
  esac
fi

# Issue #800 Track C: install the silence-watchdog OS unit alongside the
# liveness watcher. The two are sibling recovery layers — liveness checks
# the heartbeat-file mtime on a timer, silence-watchdog reads audit `ts`
# columns from the log and stop+starts the daemon when no tick has been
# written in the threshold window. Both must be canonical OS-managed
# processes; ad-hoc launches from test sessions / worktrees were what
# the issue documented as the recurring failure mode.
if [[ $skip_watchdog_silence -eq 0 ]]; then
  case "$bootstrap_os" in
    Darwin)
      if [[ $skip_launchagent -eq 1 ]]; then
        watchdog_silence_status="skipped"
      else
        watchdog_silence_status="planned"
        if [[ $dry_run -eq 0 ]]; then
          "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/scripts/install-watchdog-silence-launchagent.sh" --apply --load >/dev/null
          watchdog_silence_status="loaded"
        fi
      fi
      ;;
    Linux)
      if [[ $skip_systemd -eq 1 ]]; then
        watchdog_silence_status="skipped"
      else
        watchdog_silence_status="planned"
        if [[ $dry_run -eq 0 ]]; then
          "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/scripts/install-watchdog-silence-systemd.sh" --apply --enable >/dev/null
          watchdog_silence_status="enabled"
        fi
      fi
      ;;
    *)
      watchdog_silence_status="unsupported"
      ;;
  esac

  # Cleanup orphan watchdog instances left behind by prior test sessions
  # before launchd/systemd kickstart claims the canonical slot. This is
  # idempotent — a fresh install with nothing to clean is a no-op.
  if [[ $dry_run -eq 0 && -f "$SCRIPT_DIR/bridge-watchdog-silence.py" ]]; then
    python3 "$SCRIPT_DIR/bridge-watchdog-silence.py" cleanup-orphans >/dev/null 2>&1 || true
  fi
fi

if [[ $json_mode -eq 1 ]]; then
  python3 - "$init_json" "$shell_status" "$bootstrap_shell" "$bootstrap_rcfile" "$daemon_status" "$launchagent_status" "$systemd_status" "$next_command" "$reload_command" "$liveness_status" "$watchdog_silence_status" "$tmux_ux_status" <<'PY'
import json
import sys

init_payload = json.loads(sys.argv[1])
payload = {
    "mode": "bootstrap",
    "shell_integration": {
        "status": sys.argv[2],
        "shell": sys.argv[3],
        "rcfile": sys.argv[4],
    },
    "init": init_payload,
    "daemon": {"status": sys.argv[5]},
    "launchagent": {"status": sys.argv[6]},
    "systemd": {"status": sys.argv[7]},
    "liveness": {"status": sys.argv[10]},
    "watchdog_silence": {"status": sys.argv[11]},
    "tmux_ux": {"status": sys.argv[12]},
    "next_command": sys.argv[8],
    "reload_command": sys.argv[9],
    "handoff_steps": [
        "Close the temporary installer session.",
        f"Run `{sys.argv[9]}` in the terminal if you do not open a fresh shell.",
        f"Run `{sys.argv[8]}`.",
        "Let the admin agent guide the rest of the onboarding.",
    ],
    # Issue #1263 (v0.15.0-beta4 Lane J): structured marker for the
    # opt-in wiki-graph stack. The default on fresh installs is OFF;
    # operators activate via `bootstrap-memory-system.sh --apply` with
    # `BRIDGE_WIKI_GRAPH_ENABLED=1`. The activation command is published
    # here so JSON consumers can surface it in onboarding UI.
    "wiki_graph": {
        "default_enabled": False,
        "activation_command": (
            "BRIDGE_WIKI_GRAPH_ENABLED=1 "
            "bash $BRIDGE_HOME/bootstrap-memory-system.sh --apply"
        ),
        "note": (
            "Optional — provisions the librarian dynamic agent + nine "
            "admin-owned wiki/librarian crons. See #1263."
        ),
    },
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  exit 0
fi

admin_agent="$(python3 - "$init_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1]).get("admin", ""))
PY
)"

echo "== Agent Bridge bootstrap =="
printf 'admin_agent: %s\n' "$admin_agent"
printf 'shell_integration: %s\n' "$shell_status"
printf 'tmux_ux: %s\n' "$tmux_ux_status"
printf 'daemon: %s\n' "$daemon_status"
printf 'launchagent: %s\n' "$launchagent_status"
printf 'systemd: %s\n' "$systemd_status"
printf 'liveness: %s\n' "$liveness_status"
printf 'watchdog_silence: %s\n' "$watchdog_silence_status"
printf 'rc_reload_command: %s\n' "$reload_command"
echo
echo "handoff:"
echo "1. Close the temporary installer session."
echo "2. If you are staying in this terminal, run: $reload_command"
echo "3. Run: $next_command"
echo "4. Let the admin agent guide the rest of the onboarding."
echo
# #1261 (v0.15.0-beta4): OAT registration advisory. The
# controller-credentials fallback (issue #1075) is the default on a
# fresh install and works fine for short demo sessions, but it depends
# on Claude CLI lazy-refreshing the controller's credential file —
# which only happens when the CONTROLLER itself makes an API call. On
# production agent-bridge deployments where the operator's day-to-day
# work happens inside agents (the normal mode), the controller is idle
# and its token expires after the next idle window, propagating a
# stale credential to every agent and 401'ing them all at once
# (~8h on a Max plan). Registering a Claude OAT (setup token) breaks
# the single-point-of-failure: bridge-auth.sh's recover-due + sync
# paths actively check OAT aliveness via /v1/messages ping and refresh
# proactively. The aliveness gate in bridge-auth.py refuses to
# propagate an expired controller credential (#1261), but a fresh
# operator install will still hit the symptom on day 2 unless they
# register the OAT. Flag it now while the operator is still in the
# install loop.
echo "Recommended next step — register a Claude OAuth Setup Token (OAT):"
echo "  bash \"\$BRIDGE_HOME/bridge-auth.sh\" claude-token add \\"
echo "      --id main --stdin --activate --sync --agents all --enable-auto-rotate"
echo
echo "Without an OAT, agent-bridge falls back to copying the controller's"
# shellcheck disable=SC2088  # literal path documentation, not a path that needs expansion
echo "~/.claude/.credentials.json once per hour. Claude CLI only refreshes"
echo "that file when the controller itself makes an API call, so a controller"
echo "idle while agents run will silently propagate an expired token to every"
echo "agent on the next sync. See #1261 / #1075 for the full failure mode."
echo
# Issue #1263 (v0.15.0-beta4 Lane J): wiki-graph + librarian automation
# stack is opt-in. Fresh installs default to OFF — the operator must
# explicitly run `bootstrap-memory-system.sh --apply` (with
# `BRIDGE_WIKI_GRAPH_ENABLED=1` to override the fresh-install default).
# Stderr routing for the advisory; the structured `wiki_graph` field is
# emitted by the JSON variant above. Existing installs that already
# have provisioning state under `state/bootstrap-memory/` are unchanged
# — re-running `bootstrap-memory-system.sh --apply` is a no-op on a
# converged install.
echo "Optional — wiki-graph + librarian automation stack (default off on fresh installs):" >&2
echo "  BRIDGE_WIKI_GRAPH_ENABLED=1 bash \"\$BRIDGE_HOME/bootstrap-memory-system.sh\" --apply" >&2
echo
echo "This provisions the 'librarian' dynamic agent + nine admin-owned crons" >&2
echo "(wiki-mention-scan, wiki-hub-audit, librarian-watchdog, …) that maintain" >&2
echo "the shared memory/ wiki. Skip if you do not want the extra CPU/disk" >&2
echo "footprint. See #1263 for the activation tradeoff." >&2
