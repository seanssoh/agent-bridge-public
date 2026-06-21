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
    # The cron agent (run-target) — the #2041/#2042 non-iso branch needs it to
    # tell an admin-targeted (working) text row from a legacy `<admin>-dev`
    # codex-pair text row (which cannot exec a bash payload, #833). An agent id
    # never contains a tab/newline (slug). Empty when the list shape omits it.
    job_agent = j.get("agent") or j.get("execution", {}).get("agent") or ""
    if not isinstance(job_agent, str):
        job_agent = ""
    # Tab-separated: a job id never contains a tab/newline (slug + hex token).
    sys.stdout.write("%s\t%s\t%s\n" % (job_id, kind, job_agent))
sys.exit(0)
PY
  if "$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron list --json >"$list_tmp" 2>/dev/null; then
    out="$(python3 "$script_tmp" "$list_tmp" 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

# Returns 0 iff a SHELL-kind picker-sweep cron would be ACCEPTED for this admin
# run-as-agent on this host — i.e. the exact gate `bridge_cron_validate_shell_
# run_config` (bridge-cron.sh) applies before a `cron create --kind shell`:
#
#   shell-kind is accepted  ⟺  run-as resolves to the controller UID
#                              OR the agent has effective linux-user iso (iso v2)
#
# This is the SAME platform/iso predicate the rest of the code gates iso-only
# behavior with — NOT a hard-coded `uname` check. On a non-iso install (macOS
# or any host where the admin neither resolves to the controller UID nor has
# iso v2 effective) this returns non-zero, and the caller registers the
# supported TEXT-kind picker-sweep instead of looping on a create the CLI will
# always reject (#2041 / #2042).
#
# The iso half delegates to `bridge_agent_linux_user_isolation_effective`
# (lib/bridge-agents.sh) directly. The controller-UID half mirrors
# `bridge_cron_shell_run_as_is_controller` (bridge-cron.sh) line-for-line —
# that function lives in the root CLI script, which init does NOT source, so we
# reproduce its 3-line UID resolution here rather than add a fragile cross-file
# function dependency. Keep the two in sync if either changes.
_bridge_init_picker_sweep_shell_kind_supported() {
  local admin_agent="$1"
  [[ -n "$admin_agent" ]] || return 1

  # Controller-UID branch (the #833/#1052 controller-direct shape): the
  # run-as-agent's roster os_user (or, when absent, the agent name) resolves to
  # a UID equal to the controller's own. No iso v2 required — the runner
  # executes the script directly as the controller.
  local os_user current_uid target_uid
  os_user="$(bridge_agent_os_user "$admin_agent" 2>/dev/null || printf '')"
  [[ -n "$os_user" ]] || os_user="$admin_agent"
  current_uid="$(id -u 2>/dev/null || printf '')"
  target_uid="$(id -u "$os_user" 2>/dev/null || printf '')"
  if [[ -n "$current_uid" && -n "$target_uid" && "$current_uid" == "$target_uid" ]]; then
    return 0
  fi

  # iso v2 branch: isolation_mode==linux-user + Linux host + resolved os_user.
  if declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$admin_agent" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Register the TEXT-kind picker-sweep cron — the supported form on a non-iso /
# macOS host where `--kind shell` is structurally unavailable (#2041 / #2042).
# This is the legacy text payload form (#833 predecessor): the cron runner wraps
# the payload in `claude -p` / `codex exec`, so a disposable cron CHILD (NOT the
# live interactive session — so it is not itself blocked by the picker the sweep
# clears) runs `bash $BRIDGE_HOME/scripts/picker-sweep.sh`. scripts/picker-sweep.sh
# reads the BRIDGE_PICKER_SWEEP_* env the payload carries. Targets the admin so
# no codex pair is required; an upgraded host where #2042 confirmed text-kind
# works already runs this shape. `$BRIDGE_HOME` is expanded by the cron runner at
# dispatch time, so the registration text carries the literal `$BRIDGE_HOME`.
#
# Captures the CLI's stderr (no `2>&1` swallow — #2041): on a real failure the
# reason is surfaced so a genuine error is distinguishable from the expected
# non-iso path. Returns the CLI exit status.
_bridge_init_picker_sweep_register_text_kind() {
  local agent_bridge_cli="$1"
  local admin_agent="$2"
  local err_tmp=""
  err_tmp="$(mktemp 2>/dev/null)" || err_tmp=""
  local payload
  payload="BRIDGE_PICKER_SWEEP_ENABLED=1 BRIDGE_PICKER_SWEEP_SELF=${admin_agent} BRIDGE_PICKER_SWEEP_NOTIFY=${admin_agent} bash \$BRIDGE_HOME/scripts/picker-sweep.sh"
  # `if ! cmd; then` keeps this errexit-safe (init runs the registration under
  # `set -euo pipefail` from the bridge-upgrade.sh backfill — a bare `cmd; rc=$?`
  # would abort the function on a non-zero create before the diagnostic +
  # tempfile cleanup). stderr is captured to the tmpfile (or /dev/null when
  # mktemp failed) instead of being swallowed (#2041).
  if "$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron create \
      --agent "$admin_agent" \
      --schedule "*/10 * * * *" \
      --title "picker-sweep" \
      --payload "$payload" >/dev/null 2>"${err_tmp:-/dev/null}"; then
    [[ -n "$err_tmp" ]] && rm -f -- "$err_tmp"
    printf '[init] picker-sweep cron registered (*/10 * * * *, text-kind, agent=%s, self/notify=%s) — shell-kind unavailable on this host (non-iso / no controller-UID run-as)\n' "$admin_agent" "$admin_agent" >&2
    return 0
  fi
  local reason=""
  [[ -n "$err_tmp" && -s "$err_tmp" ]] && reason="$(tr '\n' ' ' <"$err_tmp" 2>/dev/null)"
  [[ -n "$err_tmp" ]] && rm -f -- "$err_tmp"
  printf '[init] picker-sweep cron registration failed (text-kind, agent=%s) — operator can register manually per OPERATIONS.md%s\n' \
    "$admin_agent" "$([[ -n "$reason" ]] && printf ': %s' "$reason")" >&2
  return 1
}

# Idempotent + migrating: registers the picker-sweep bridge-native cron as a
# SHELL-kind controller-direct job when no shell-kind `picker-sweep` job is
# already present, deleting any legacy TEXT-kind job first. Failures are
# non-fatal — init must not be blocked by cron registration plumbing.
#
# PLATFORM/ISO-AWARE (#2041 / #2042): shell-kind is only registered when this
# host accepts it (iso v2 effective OR run-as resolves to the controller UID —
# `_bridge_init_picker_sweep_shell_kind_supported`). On a non-iso / macOS host
# where `--kind shell` is structurally rejected, the desired/converged form is
# the TEXT-kind cron: a pre-existing text-kind row is the converged state (skip,
# NO re-`failed` line every upgrade), and a fresh install registers text-kind.
# This is a platform BRANCH, not a blanket revert — the iso/Linux shell-kind
# path is unchanged.
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
  # #2041/#2042 non-iso branch state: is an ADMIN-targeted text row already
  # present (the working/converged form), and the non-admin (legacy `<admin>-dev`
  # codex-pair) text row ids that must be migrated off rather than treated as
  # converged.
  local admin_text_seen=0 noniso_legacy_ids=() noniso_legacy_titleonly=0
  enum_lines="$(_bridge_init_picker_sweep_enumerate "$agent_bridge_cli")"
  local _line _id _rest _kind _agent
  while IFS= read -r _line; do
    # Split on the FIRST tab WITHOUT IFS whitespace-stripping. `IFS=$'\t' read`
    # would strip a *leading* tab, so an id-less `\t<kind>\t<agent>` row (older
    # `cron list` shape / mock without ids) collapses the kind into _id and the
    # id-less leave/warn path below goes dead (codex #1919 r1 finding). Parameter
    # expansion preserves the empty id field. Line shape is `<id>\t<kind>\t<agent>`
    # (the agent field added for #2041/#2042; absent on a legacy 2-field line, in
    # which case _agent is empty).
    _id="${_line%%$'\t'*}"
    _rest="${_line#*$'\t'}"
    _kind="${_rest%%$'\t'*}"
    if [[ "$_rest" == *$'\t'* ]]; then
      _agent="${_rest#*$'\t'}"
    else
      _agent=""
    fi
    [[ -n "$_kind" || -n "$_id" ]] || continue
    if [[ "$_kind" == "shell" ]]; then
      shell_seen=1
      continue
    fi
    # Any non-shell row (text, or unknown legacy) is a migration target for the
    # shell-kind path (Case A/B below).
    if [[ -n "$_id" ]]; then
      legacy_ids+=("$_id")
    else
      # No id surfaced (older list shape / mock without ids) — the id-less
      # leave/warn path (a title delete is ambiguous once a shell row coexists).
      legacy_titleonly=1
    fi
    # #2041/#2042: for the NON-iso branch, a text row TARGETING THE ADMIN is the
    # working/converged form; a row targeting anything else (legacy `<admin>-dev`
    # codex pair) is broken and must be migrated, not skipped.
    if [[ "$_agent" == "$admin_agent" ]]; then
      admin_text_seen=1
    elif [[ -n "$_id" ]]; then
      noniso_legacy_ids+=("$_id")
    else
      noniso_legacy_titleonly=1
    fi
  done <<< "$enum_lines"

  # PLATFORM/ISO BRANCH (#2041 / #2042). On a host that does NOT accept
  # `--kind shell` (non-iso / macOS, where the admin neither resolves to the
  # controller UID nor has iso v2 effective), the shell-kind create is
  # STRUCTURALLY rejected by the CLI every time. The pre-#2041 code attempted it
  # unconditionally, swallowed the rejection, and re-logged `failed` on EVERY
  # upgrade without ever converging (#2042) — and on a fresh non-iso install left
  # the host with NO working picker-sweep (#2041). Here the supported/converged
  # form is the ADMIN-targeted TEXT-kind cron instead:
  #   - a shell-kind row somehow exists (host migrated off iso) → fall through to
  #     Case A below, which keeps it and cleans up legacy (harmless).
  #   - an ADMIN-targeted text row already exists → that IS the converged state.
  #     Skip (idempotent; NO `failed` line — the #2042 fix). Any coexisting
  #     legacy `<admin>-dev` codex-pair text row(s) are removed by id.
  #   - only a legacy `<admin>-dev` text row exists (codex pair CANNOT exec a
  #     bash payload — #833) → register the working admin text row FIRST, then
  #     remove the legacy row(s) by id (recreate-first, same #1916 ordering).
  #   - no row at all → register the admin text-kind cron (the #2041 fix: a
  #     working job instead of a silent no-op).
  if [[ "$shell_seen" -ne 1 ]] \
      && ! _bridge_init_picker_sweep_shell_kind_supported "$admin_agent"; then
    if [[ "$admin_text_seen" -eq 1 ]]; then
      # Converged: a working admin-targeted text row is present. Clean up any
      # coexisting legacy codex-pair text row(s) by id (precise — the create is
      # skipped, so there is no recreate-first ordering concern here).
      _bridge_init_picker_sweep_remove_legacy_by_id "$agent_bridge_cli" "${noniso_legacy_ids[@]:-}"
      if [[ "$noniso_legacy_titleonly" -eq 1 ]]; then
        printf '[init] picker-sweep cron migrate — legacy id-less non-admin text-kind row remains (cannot title-delete alongside the admin row); operator can remove it manually per OPERATIONS.md\n' >&2
      fi
      printf '[init] picker-sweep cron already registered (text-kind, admin-targeted) — skip; --kind shell is unavailable on this host (non-iso / no controller-UID run-as), so admin text-kind is the supported converged form (no re-migration)%s\n' \
        "$([[ "${#noniso_legacy_ids[@]}" -gt 0 ]] && printf ' (removed %s legacy non-admin row(s))' "${#noniso_legacy_ids[@]}")" >&2
      return 0
    fi
    # No working admin text row yet. Register it FIRST; on success remove any
    # legacy `<admin>-dev` text row(s) by id (recreate-first — never strand the
    # host with zero working picker-sweep, the #1916 invariant).
    if _bridge_init_picker_sweep_register_text_kind "$agent_bridge_cli" "$admin_agent"; then
      _bridge_init_picker_sweep_remove_legacy_by_id "$agent_bridge_cli" "${noniso_legacy_ids[@]:-}"
      if [[ "$noniso_legacy_titleonly" -eq 1 ]]; then
        printf '[init] picker-sweep cron migrate — legacy id-less non-admin text-kind row remains (cannot title-delete alongside the new admin row); operator can remove it manually per OPERATIONS.md\n' >&2
      fi
    fi
    return 0
  fi

  # #1916 FAIL-SAFE migration ordering (recreate-first / verify-before-delete).
  # The legacy text-kind row is deleted ONLY after a shell-kind row is confirmed
  # present — never the old delete-then-recreate, where a failed re-register
  # (observed on a v0.16.12 cm-prod upgrade: the create raced the daemon-restart
  # window) stranded the host with ZERO picker-sweep crons. Deletes are BY ID
  # (precise; never touches a shell row), so create-first + delete-after stays
  # unambiguous even while a legacy text row and the new shell row briefly
  # coexist.

  # Case A: a shell-kind row already exists → migration already complete on a
  # prior pass. Safe to remove any coexisting legacy text-kind rows now.
  if [[ "$shell_seen" -eq 1 ]]; then
    _bridge_init_picker_sweep_remove_legacy_by_id "$agent_bridge_cli" "${legacy_ids[@]:-}"
    if [[ "$legacy_titleonly" -eq 1 ]]; then
      # An id-less legacy row cannot be title-deleted while a shell row also
      # exists (`cron delete picker-sweep` matches both → ambiguous). Leave it
      # rather than risk deleting the working shell row; warn for the operator.
      printf '[init] picker-sweep cron migrate — legacy id-less text-kind row remains (cannot title-delete alongside the shell row); operator can remove it manually per OPERATIONS.md\n' >&2
    fi
    printf '[init] picker-sweep cron already registered (shell-kind) — skip%s\n' \
      "$([[ "${#legacy_ids[@]}" -gt 0 ]] && printf ' (removed %s legacy row(s))' "${#legacy_ids[@]}")" >&2
    return 0
  fi

  # Case B: no shell-kind row → register it FIRST, then delete the legacy
  # text-kind row(s) ONLY after the shell row is confirmed present.
  #
  # The run-as-agent is the admin (resolves to the controller UID), so the cron
  # runner executes scripts/picker-sweep.sh directly as the controller —
  # engine-independent, no codex pair, no self-recursion. `$BRIDGE_HOME` in
  # --script is expanded by the CLI at registration time (resolve_shell_script).
  # The knobs are carried as SCRIPT_-prefixed env (the shell runner rejects
  # BRIDGE_-prefixed payload env); scripts/picker-sweep.sh reads
  # SCRIPT_PICKER_SWEEP_* as fallbacks.
  #
  # Stderr is captured (#2041): on this branch the host DOES accept shell-kind
  # (we gated above), so a non-zero create here is a REAL failure (daemon-restart
  # race, jobs-file lock, …) — surface its reason rather than swallow it. The
  # `if ! cmd; then` form keeps this errexit-safe: init runs the registration
  # under `set -euo pipefail` (bridge-upgrade.sh picker-sweep backfill), where a
  # bare `cmd; rc=$?` would abort the function on a non-zero create before the
  # fail-safe diagnostic + tempfile cleanup. stderr goes to the tmpfile (or
  # /dev/null when mktemp failed).
  local _shell_err_tmp=""
  _shell_err_tmp="$(mktemp 2>/dev/null)" || _shell_err_tmp=""
  if ! "$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron create \
      --kind shell \
      --agent "$admin_agent" \
      --run-as-agent "$admin_agent" \
      --schedule "*/10 * * * *" \
      --title "picker-sweep" \
      --script '$BRIDGE_HOME/scripts/picker-sweep.sh' \
      --script-env "SCRIPT_PICKER_SWEEP_ENABLED=1" \
      --script-env "SCRIPT_PICKER_SWEEP_SELF=${admin_agent}" \
      --script-env "SCRIPT_PICKER_SWEEP_NOTIFY=${admin_agent}" >/dev/null 2>"${_shell_err_tmp:-/dev/null}"; then
    local _shell_reason=""
    [[ -n "$_shell_err_tmp" && -s "$_shell_err_tmp" ]] && _shell_reason="$(tr '\n' ' ' <"$_shell_err_tmp" 2>/dev/null)"
    [[ -n "$_shell_err_tmp" ]] && rm -f -- "$_shell_err_tmp"
    # FAIL-SAFE: the shell-kind register failed → do NOT delete any legacy row.
    # The host keeps its existing (text-kind) picker-sweep; the next upgrade pass
    # retries the migration. This is the #1916 fix — no window with neither.
    if [[ "${#legacy_ids[@]}" -gt 0 || "$legacy_titleonly" -eq 1 ]]; then
      printf '[init] picker-sweep cron registration failed — legacy text-kind job LEFT IN PLACE so the host keeps a working picker-sweep; the next upgrade retries the shell-kind migration%s\n' \
        "$([[ -n "$_shell_reason" ]] && printf ': %s' "$_shell_reason")" >&2
    else
      printf '[init] picker-sweep cron registration failed — operator can register manually per OPERATIONS.md%s\n' \
        "$([[ -n "$_shell_reason" ]] && printf ': %s' "$_shell_reason")" >&2
    fi
    return 0
  fi
  [[ -n "$_shell_err_tmp" ]] && rm -f -- "$_shell_err_tmp"
  printf '[init] picker-sweep cron registered (*/10 * * * *, shell-kind, run-as=%s, self/notify=%s)\n' "$admin_agent" "$admin_agent" >&2

  # Verify-before-delete: re-enumerate and confirm the shell row is actually
  # present before removing the legacy text-kind row(s). A create that returned 0
  # but did not commit (the suspected daemon-restart race) must NOT trigger the
  # legacy delete — leaving the legacy row is the safe direction.
  if ! _bridge_init_picker_sweep_shell_present "$agent_bridge_cli"; then
    printf '[init] picker-sweep cron migrate — shell-kind not confirmed after create; legacy text-kind job LEFT IN PLACE (verify-before-delete); next upgrade retries\n' >&2
    return 0
  fi

  # Shell row confirmed present → safe to remove the legacy text-kind row(s).
  _bridge_init_picker_sweep_remove_legacy_by_id "$agent_bridge_cli" "${legacy_ids[@]:-}"
  if [[ "$legacy_titleonly" -eq 1 ]]; then
    # See Case A: a post-create title delete is ambiguous (legacy + new shell
    # share the title). Leave the id-less legacy row + warn rather than risk the
    # shell row.
    printf '[init] picker-sweep cron migrate — legacy id-less text-kind row remains (cannot title-delete alongside the new shell row); operator can remove it manually per OPERATIONS.md\n' >&2
  fi
  return 0
}

# Delete each legacy picker-sweep row BY ID (precise — never touches a shell-kind
# row). Non-fatal: a delete failure leaves the broken row behind but must not
# block init — we warn and continue. Called by the migration ONLY after a
# shell-kind row is confirmed present (#1916 recreate-first ordering).
_bridge_init_picker_sweep_remove_legacy_by_id() {
  local agent_bridge_cli="$1"; shift
  local _legacy_id
  for _legacy_id in "$@"; do
    [[ -n "$_legacy_id" ]] || continue
    if "$BRIDGE_BASH_BIN" "$agent_bridge_cli" cron delete "$_legacy_id" >/dev/null 2>&1; then
      printf '[init] picker-sweep cron migrate — removed legacy text-kind (codex-pair) job id=%s\n' "$_legacy_id" >&2
    else
      printf '[init] picker-sweep cron migrate — could not remove legacy text-kind job id=%s (left in place)\n' "$_legacy_id" >&2
    fi
  done
}

# Returns 0 iff at least one SHELL-kind picker-sweep job is registered. Used by
# the migration's verify-before-delete step (#1916). Matches with a `case` glob
# on the captured output — NOT a `<<<` here-string or `< <()` process
# substitution (both trip lint-heredoc-ban H3), and NOT a `| grep -q` pipe
# (a pipefail SIGPIPE could false-negative, the #1813 class).
_bridge_init_picker_sweep_shell_present() {
  local agent_bridge_cli="$1" _out
  _out="$(_bridge_init_picker_sweep_enumerate "$agent_bridge_cli")"
  # enumerate emits one `<id>\t<kind>\t<agent>` line per picker-sweep job; kind is
  # exactly "text" or "shell". The kind is always followed by a tab (the agent
  # field, possibly empty), so glob for the `\tshell\t` token. Wrap with newlines
  # so every line (including the last, whose trailing newline `$()` stripped) is
  # bounded. NOT a `<<<` here-string / `< <()` process substitution (both trip
  # lint-heredoc-ban H3), and NOT a `| grep -q` pipe (a pipefail SIGPIPE could
  # false-negative, the #1813 class).
  case $'\n'"$_out"$'\n' in
    *$'\tshell\t'*) return 0 ;;
  esac
  return 1
}
