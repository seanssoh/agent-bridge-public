#!/usr/bin/env bash
# shellcheck shell=bash
# bridge-init-default-crons.sh — fresh-install default cron registrations.
#
# Track D follow-up to #713 / #809, follow-on to #833 / #1052: a fresh install
# should not need an extra step to enable the essentials. picker-sweep is the
# first essential we auto-register here. The helper is invoked from
# bridge-init.sh AFTER bridge_host_profile_run returns.
#
# SHELL-KIND, CONTROLLER-DIRECT (this is the #833/#1052 fix). The previous
# design registered picker-sweep as a TEXT-kind cron dispatched to the codex
# pair `<admin>-dev`. But a Codex cron-subagent CANNOT execute a bash payload
# (its final response schema is JSON-only with no exec result channel), so the
# sweep never ran on a server install with a codex pair and every 10-min slot
# emitted an unrunnable cron → unclaimed → watchdog alarm. We now register a
# SHELL-kind cron whose run-as-agent is the ADMIN (which resolves to the
# controller UID), so the cron runner executes scripts/picker-sweep.sh DIRECTLY
# as the controller (`env -i ... script`, no UID drop, engine-independent). No
# codex pair is required, so the old `<admin>-dev` existence gate is gone — the
# only requirement is an admin agent.
#
# The shell-kind cron runner runs the script under `env -i` and rejects
# BRIDGE_-prefixed payload env (it requires POLL_/SCRIPT_ prefixes — see
# bridge-cron.py SHELL_PAYLOAD_ENV_PREFIXES), so we carry the knobs as
# SCRIPT_PICKER_SWEEP_{ENABLED,SELF,NOTIFY}; scripts/picker-sweep.sh reads those
# as fallbacks for the BRIDGE_PICKER_SWEEP_* vars. SCRIPT_PICKER_SWEEP_ENABLED=1
# overrides the runtime host_profile=dev default-skip so the sweep still runs on
# a dev host. Operators who want the sweep disabled can
# `agb cron update picker-sweep --disable` after init.
#
# The helper is idempotent (re-running init must not double-register) AND
# migrates: if a legacy TEXT-kind picker-sweep job is present (the broken
# codex-pair form on an upgraded install), it is deleted and re-registered as
# shell-kind so the fix reaches already-installed hosts.
#
# Future essentials (e.g. additional unstick / hygiene crons) belong here too;
# keep each registration in its own function so re-runs can be reasoned about
# independently.

# Enumerate EVERY registered job titled `picker-sweep` as `<id>\t<kind>` lines
# (one per matched job). Prints nothing when there is no job / the list is
# unavailable. Drives the idempotency-vs-migrate decision.
#
# #1888 r2 (codex BLOCKING finding 3): native cron dedups on `(agent, title)`,
# NOT title alone (bridge-cron.py build_native_create), so an upgraded/partially
# repaired host can legitimately hold BOTH a legacy `patch-dev/picker-sweep`
# (text) AND a fixed `patch/picker-sweep` (shell) row at once. The old probe
# only inspected the FIRST matching job and the migration deleted BY TITLE —
# which `bridge-cron.py` rejects as ambiguous once two same-title rows coexist
# (`multiple jobs matched exactly`). We therefore enumerate by id+kind so the
# caller can delete the legacy text row(s) BY ID and leave any correct shell row
# intact. The `id` is required for the by-id delete; jobs without an id (older
# list shapes / mock fixtures) fall back to a stable empty id and are matched on
# title only — the caller still deletes the title in that single-row case.
#
# Footgun #11: route the CLI JSON through a tempfile and the probe python
# through its own tempfile rather than a heredoc-stdin pipe.
_bridge_init_picker_sweep_enumerate() {
  local agent_bridge_cli="$1"
  local list_tmp="" script_tmp="" out=""
  list_tmp="$(mktemp 2>/dev/null)" || return 0
  script_tmp="$(mktemp 2>/dev/null)" || { rm -f -- "$list_tmp"; return 0; }
  # shellcheck disable=SC2064
  trap "rm -f -- '$list_tmp' '$script_tmp'" RETURN
  cat >"$script_tmp" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
jobs = data.get("jobs", data) if isinstance(data, dict) else data
for j in (jobs or []):
    if not isinstance(j, dict):
        continue
    name = (j.get("title") or j.get("name") or "")
    if name != "picker-sweep":
        continue
    payload = j.get("payload") or {}
    kind = ""
    if isinstance(payload, dict):
        kind = payload.get("kind") or ""
    if not kind:
        kind = j.get("payload_kind") or "text"
    job_id = j.get("id") or ""
    # Tab-separated: a job id never contains a tab/newline (slug + hex token).
    sys.stdout.write("%s\t%s\n" % (job_id, kind))
sys.exit(0)
PY
  if "$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron list --json >"$list_tmp" 2>/dev/null; then
    out="$(python3 "$script_tmp" "$list_tmp" 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

# Idempotent + migrating: registers the picker-sweep bridge-native cron as a
# SHELL-kind controller-direct job when no shell-kind `picker-sweep` job is
# already present, deleting any legacy TEXT-kind job first. Failures are
# non-fatal — init must not be blocked by cron registration plumbing.
#
# Args:
#   $1 = agent-bridge CLI path (the live CLI under $BRIDGE_HOME)
#   $2 = admin agent id (run-as-agent for the controller-direct shell cron;
#        also drives SCRIPT_PICKER_SWEEP_SELF + NOTIFY env vars)
bridge_init_register_default_picker_sweep() {
  local agent_bridge_cli="$1"
  local admin_agent="$2"

  if [[ -z "$agent_bridge_cli" || -z "$admin_agent" ]]; then
    printf '[init] picker-sweep cron registration skipped — missing CLI path or admin agent\n' >&2
    return 0
  fi
  if [[ ! -x "$agent_bridge_cli" ]]; then
    printf '[init] picker-sweep cron registration skipped — CLI not executable: %s\n' "$agent_bridge_cli" >&2
    return 0
  fi

  # Require an admin agent in the roster (the run-as-agent for the
  # controller-direct shell cron). No codex pair is needed any more — the old
  # `<admin>-dev` existence gate is gone. On the common path the admin always
  # exists by the time init reaches here.
  if ! bridge_agent_exists "$admin_agent" 2>/dev/null; then
    printf '[init] picker-sweep cron skipped — admin agent %s not in roster\n' "$admin_agent" >&2
    return 0
  fi

  # Idempotency + migration. Enumerate EVERY job titled picker-sweep (id+kind):
  #   - a shell-kind row exists → already on the fixed cron. Delete any legacy
  #     text-kind row(s) BY ID (a coexisting pair leaves a dangling unrunnable
  #     job + makes `cron delete picker-sweep` ambiguous), then skip the create
  #     (idempotent).
  #   - only text-kind row(s) exist → legacy broken codex-pair cron from an
  #     upgraded install. Delete each BY ID, then fall through to register the
  #     shell-kind row (migration).
  #   - no row → fresh install (or list unavailable); register.
  #
  # #1888 r2 (codex BLOCKING finding 3): delete BY ID, not by title. Native cron
  # permits two same-title rows (different agents), so once a legacy text and a
  # fixed shell row coexist, `cron delete picker-sweep` errors with
  # `multiple jobs matched exactly`. Deleting the specific legacy id removes only
  # the broken row and keeps the shell row, and the whole pass stays idempotent.
  # `cron list --json` exits non-zero on a fresh install where jobs.json does not
  # exist yet — the enumerate treats that as "no job, proceed".
  local enum_lines shell_seen=0 legacy_ids=() legacy_titleonly=0
  enum_lines="$(_bridge_init_picker_sweep_enumerate "$agent_bridge_cli")"
  local _id _kind
  while IFS=$'\t' read -r _id _kind; do
    [[ -n "$_kind" || -n "$_id" ]] || continue
    if [[ "$_kind" == "shell" ]]; then
      shell_seen=1
      continue
    fi
    # Any non-shell row (text, or unknown legacy) is a migration target.
    if [[ -n "$_id" ]]; then
      legacy_ids+=("$_id")
    else
      # No id surfaced (older list shape / mock without ids) — fall back to a
      # title-scoped delete, which is only unambiguous when this is the sole row.
      legacy_titleonly=1
    fi
  done <<< "$enum_lines"

  # Remove every legacy non-shell row by its id (precise; never touches a shell
  # row). Non-fatal: a delete failure leaves the broken row behind but must not
  # block init — we warn and continue.
  local _legacy_id
  for _legacy_id in "${legacy_ids[@]:-}"; do
    [[ -n "$_legacy_id" ]] || continue
    if "$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron delete "$_legacy_id" >/dev/null 2>&1; then
      printf '[init] picker-sweep cron migrate — removed legacy text-kind (codex-pair) job id=%s\n' "$_legacy_id" >&2
    else
      printf '[init] picker-sweep cron migrate — could not remove legacy text-kind job id=%s; shell-kind re-register may be skipped\n' "$_legacy_id" >&2
    fi
  done
  # Title-only fallback for an id-less single legacy row (no shell row present,
  # so a title delete is unambiguous).
  if [[ "$legacy_titleonly" -eq 1 && "$shell_seen" -eq 0 && "${#legacy_ids[@]}" -eq 0 ]]; then
    if "$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron delete picker-sweep >/dev/null 2>&1; then
      printf '[init] picker-sweep cron migrate — removed legacy text-kind (codex-pair) job (by title)\n' >&2
    else
      printf '[init] picker-sweep cron migrate — could not remove legacy text-kind job; shell-kind re-register may be skipped\n' >&2
    fi
  fi

  if [[ "$shell_seen" -eq 1 ]]; then
    printf '[init] picker-sweep cron already registered (shell-kind) — skip%s\n' \
      "$([[ "${#legacy_ids[@]}" -gt 0 ]] && printf ' (removed %s legacy row(s))' "${#legacy_ids[@]}")" >&2
    return 0
  fi

  # Register the SHELL-kind controller-direct cron. The run-as-agent is the
  # admin (resolves to the controller UID), so the cron runner executes
  # scripts/picker-sweep.sh directly as the controller — engine-independent, no
  # codex pair, no self-recursion. `$BRIDGE_HOME` in --script is expanded by the
  # CLI at registration time (resolve_shell_script). The knobs are carried as
  # SCRIPT_-prefixed env (the shell runner rejects BRIDGE_-prefixed payload env);
  # scripts/picker-sweep.sh reads SCRIPT_PICKER_SWEEP_* as fallbacks.
  if "$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron create \
        --kind shell \
        --agent "$admin_agent" \
        --run-as-agent "$admin_agent" \
        --schedule "*/10 * * * *" \
        --title "picker-sweep" \
        --script '$BRIDGE_HOME/scripts/picker-sweep.sh' \
        --script-env "SCRIPT_PICKER_SWEEP_ENABLED=1" \
        --script-env "SCRIPT_PICKER_SWEEP_SELF=${admin_agent}" \
        --script-env "SCRIPT_PICKER_SWEEP_NOTIFY=${admin_agent}" >/dev/null 2>&1; then
    printf '[init] picker-sweep cron registered (*/10 * * * *, shell-kind, run-as=%s, self/notify=%s)\n' "$admin_agent" "$admin_agent" >&2
  else
    printf '[init] picker-sweep cron registration failed — operator can register manually per OPERATIONS.md\n' >&2
  fi
  return 0
}
