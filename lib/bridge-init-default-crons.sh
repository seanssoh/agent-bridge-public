#!/usr/bin/env bash
# shellcheck shell=bash
# bridge-init-default-crons.sh — fresh-install default cron registrations.
#
# Track D follow-up to #713 / #809, follow-on to #833: a fresh install (server
# OR dev) should not need an extra step to enable the essentials. picker-sweep
# is the first essential we auto-register here. The helper is invoked from
# bridge-init.sh AFTER bridge_host_profile_run returns. Registration is
# unconditional with respect to host_profile — the registered cron payload
# sets BRIDGE_PICKER_SWEEP_ENABLED=1, which overrides the runtime
# host_profile=dev default-skip in scripts/picker-sweep.sh. Operators who
# want the sweep disabled can `agb cron update picker-sweep --disable` after
# init. The helper is intentionally idempotent: re-running init must not
# double-register.
#
# Future essentials (e.g. additional unstick / hygiene crons) belong here too;
# keep each registration in its own function so re-runs can be reasoned about
# independently.

# Idempotent: registers the picker-sweep bridge-native cron when no job named
# `picker-sweep` is already present. Failures are non-fatal — init must not be
# blocked by cron registration plumbing.
#
# Args:
#   $1 = agent-bridge CLI path (the live CLI under $BRIDGE_HOME)
#   $2 = admin agent id (drives BRIDGE_PICKER_SWEEP_SELF + NOTIFY env vars)
#
# Per OPERATIONS.md "picker-sweep utility" §B (Bridge-native cron with a
# Codex target): the cron runner wraps payloads in `claude -p` (or `codex
# exec`), so we target `<admin>-dev` (the codex pair always present after
# bridge-init runs `bridge_ensure_admin_codex_pair`). Targeting the Claude
# admin would route picker-sweep through the very picker it is meant to
# clear — see OPERATIONS.md.
bridge_init_register_default_picker_sweep() {
  local agent_bridge_cli="$1"
  local admin_agent="$2"
  local cron_agent="${admin_agent}-dev"

  if [[ -z "$agent_bridge_cli" || -z "$admin_agent" ]]; then
    printf '[init] picker-sweep cron registration skipped — missing CLI path or admin agent\n' >&2
    return 0
  fi
  if [[ ! -x "$agent_bridge_cli" ]]; then
    printf '[init] picker-sweep cron registration skipped — CLI not executable: %s\n' "$agent_bridge_cli" >&2
    return 0
  fi

  # Idempotency check: list bridge-native crons (text-kind only is fine;
  # picker-sweep is registered as text-kind below) and look for an existing
  # job titled `picker-sweep`. `cron list --json` exits non-zero on a fresh
  # install where jobs.json doesn't exist yet — treat that as "no existing
  # job, proceed to register".
  #
  # Footgun #11 mitigation: route both the CLI's JSON output AND the python
  # script itself via tempfiles rather than piping into a `python3 - <<'PY'`
  # block. Multi-record JSON heredoc-fed to python3 has hit heredoc/here-string
  # deadlocks on the orchestrator host (see #800, HANDOFF_2026-05-08).
  # r1 codex review caught that the initial fix only tempfile'd the JSON output
  # while still using `python3 - <<'PY'` for the script — same deadlock class.
  # r2 fix: write the python script to its own tempfile and exec it.
  local list_tmp="" script_tmp=""
  list_tmp="$(mktemp 2>/dev/null)" || list_tmp=""
  script_tmp="$(mktemp 2>/dev/null)" || script_tmp=""
  # Cleanup both tempfiles on every return path via a RETURN trap. The
  # `rm -f --` form (and quoted paths) is safe even if either tempfile is
  # empty / unset.
  # shellcheck disable=SC2064
  trap "rm -f -- '$list_tmp' '$script_tmp'" RETURN
  if [[ -n "$list_tmp" && -n "$script_tmp" ]]; then
    cat >"$script_tmp" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(2)
jobs = data.get("jobs", data) if isinstance(data, dict) else data
for j in (jobs or []):
    name = (j.get("title") or j.get("name") or "")
    if name == "picker-sweep":
        sys.exit(0)
sys.exit(1)
PY
    if "$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron list --json >"$list_tmp" 2>/dev/null; then
      if python3 "$script_tmp" "$list_tmp" >/dev/null 2>&1; then
        printf '[init] picker-sweep cron already registered — skip\n' >&2
        return 0
      fi
    fi
  fi

  # Register: */10 * * * *, payload runs scripts/picker-sweep.sh with the env
  # contract documented in OPERATIONS.md §B. The payload is a single line
  # exec via the cron runner's text-kind wrapping; `$BRIDGE_HOME` is expanded
  # by the cron runner at dispatch time, not at registration time, so the
  # registration text contains the literal `$BRIDGE_HOME`.
  local payload
  payload="BRIDGE_PICKER_SWEEP_ENABLED=1 BRIDGE_PICKER_SWEEP_SELF=${admin_agent} BRIDGE_PICKER_SWEEP_NOTIFY=${admin_agent} bash \$BRIDGE_HOME/scripts/picker-sweep.sh"

  if "$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron create \
        --agent "$cron_agent" \
        --schedule "*/10 * * * *" \
        --title "picker-sweep" \
        --payload "$payload" >/dev/null 2>&1; then
    printf '[init] picker-sweep cron registered (*/10 * * * *, agent=%s, self/notify=%s)\n' "$cron_agent" "$admin_agent" >&2
  else
    printf '[init] picker-sweep cron registration failed — operator can register manually per OPERATIONS.md\n' >&2
  fi
  return 0
}
