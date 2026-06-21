#!/usr/bin/env bash
# scripts/smoke/1916-picker-sweep-migrate-atomic.sh — Issue #1916.
#
# Locks the FAIL-SAFE migration ordering of the picker-sweep shell-kind
# migration (bridge_init_register_default_picker_sweep). The legacy text-kind
# cron must be deleted ONLY AFTER a shell-kind cron is confirmed present, so a
# failed shell-kind re-register (observed on a v0.16.12 cm-prod upgrade: the
# create raced the daemon-restart window) can never strand the host with ZERO
# picker-sweep crons.
#
# Scenarios asserted (the helper sourced from lib/bridge-init-default-crons.sh,
# driven with a stateful recorder CLI shim):
#   1. legacy text-kind present + create SUCCEEDS → shell-kind created FIRST,
#      then legacy deleted (recreate-first ordering; never a window with
#      neither). The shim swaps `cron list` to show the shell row after a
#      successful create so the verify-before-delete step is genuinely exercised.
#   2. legacy text-kind present + create FAILS → legacy is NOT deleted + a
#      "LEFT IN PLACE" warning is emitted (the #1916 regression: no silent loss).
#   3. shell-kind already present (+ a coexisting legacy) → legacy deleted,
#      create SKIPPED (idempotent).
#   4. fresh install (no picker-sweep at all) → shell-kind created, no delete.
#
# Footgun #11 / lint-heredoc-ban: this smoke feeds NO heredoc to a subprocess,
# uses NO here-string, and NO `cat <<EOF`. The CLI shim, JSON fixtures, and
# driver are all written with printf and `source`d / executed by path.

set -euo pipefail

SMOKE_NAME="1916-picker-sweep-migrate-atomic"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# The admin must be one for which `bridge_init_register_default_picker_sweep`
# takes the SHELL-kind path — i.e. shell-kind is supported for it. Since #2041/
# #2042 the helper gates shell-kind on `_bridge_init_picker_sweep_shell_kind_
# supported` (run-as resolves to the controller UID OR iso v2 effective);
# otherwise it registers the TEXT-kind cron instead. A bare "patch" does not
# resolve to an OS UID on a non-iso macOS / CI host, so it would now take the
# text-kind path and this migration-ordering smoke would assert nothing. Use the
# current login user, which resolves to the controller's own UID → the
# controller-direct shell-kind shape this smoke is about. (#2041/#2042 platform
# branch is covered by scripts/smoke/2041-2042-picker-sweep-noniso-cron.sh.)
ADMIN="$(id -un 2>/dev/null || printf 'patch')"

# Run the picker-sweep migration helper against a stateful recorder shim.
#   $1 = scenario tag (temp-dir suffix)
#   $2 = initial cron state: legacy | legacy+shell | empty
#   $3 = fail_create: 1 → `cron create` exits non-zero (fault injection); 0 → ok
# Echoes the helper's combined stdout+stderr, then the recorded CRON LOG between
# __CRONLOG__ / __ENDCRONLOG__ markers (one `create …` / `delete …` line per
# invocation, in call order).
run_migrate_probe() {
  local tag="$1" initial="$2" fail_create="$3"
  local probe_dir
  probe_dir="$(mktemp -d "$SMOKE_TMP_ROOT/1916-$tag.XXXXXX")"

  local state_json="$probe_dir/state.json"
  local shell_json="$probe_dir/shell.json"
  local cron_log="$probe_dir/cron.log"
  local roster_local="$probe_dir/agent-roster.local.sh"
  local cli="$probe_dir/agent-bridge"
  local driver="$probe_dir/driver.sh"
  : >"$cron_log"

  # JSON fixtures match what _bridge_init_picker_sweep_enumerate parses:
  # title=="picker-sweep", payload.kind ∈ {text,shell}, id surfaced.
  local LEGACY='{"id":"leg1","title":"picker-sweep","payload":{"kind":"text"}}'
  local SHELL='{"id":"sh1","title":"picker-sweep","payload":{"kind":"shell"}}'
  # Id-less legacy row (older `cron list` shape / mock without ids): enumerate
  # emits a leading-tab `\ttext` line for it.
  local LEGACY_NOID='{"title":"picker-sweep","payload":{"kind":"text"}}'
  case "$initial" in
    legacy)            printf '{"jobs":[%s]}\n' "$LEGACY" >"$state_json" ;;
    legacy+shell)      printf '{"jobs":[%s,%s]}\n' "$LEGACY" "$SHELL" >"$state_json" ;;
    legacy-noid)       printf '{"jobs":[%s]}\n' "$LEGACY_NOID" >"$state_json" ;;
    legacy-noid+shell) printf '{"jobs":[%s,%s]}\n' "$LEGACY_NOID" "$SHELL" >"$state_json" ;;
    empty)             printf '{"jobs":[]}\n' >"$state_json" ;;
    *)                 smoke_fail "unknown initial state: $initial" ;;
  esac
  # Post-successful-create state (what `cron list` returns after a 0-exit create):
  # the shell row is present so the verify-before-delete step confirms it.
  printf '{"jobs":[%s,%s]}\n' "$LEGACY" "$SHELL" >"$shell_json"

  # Recorder CLI shim (bash): list = cat current state; create = log + (fail or
  # swap state to "shell present"); delete = log. Stateful so a successful create
  # makes the subsequent verify `cron list` show the shell row.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'STATE=%q\n' "$state_json"
    printf 'SHELLJSON=%q\n' "$shell_json"
    printf 'CRONLOG=%q\n' "$cron_log"
    printf 'FAILCREATE=%q\n' "$fail_create"
    printf '%s\n' 'if [[ "$1" == "cron" && "$2" == "list" ]]; then cat "$STATE"; exit 0; fi'
    printf '%s\n' 'if [[ "$1" == "cron" && "$2" == "create" ]]; then'
    printf '%s\n' '  printf "create %s\n" "$*" >> "$CRONLOG"'
    printf '%s\n' '  if [[ "$FAILCREATE" == "1" ]]; then exit 1; fi'
    printf '%s\n' '  cp "$SHELLJSON" "$STATE"; exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [[ "$1" == "cron" && "$2" == "delete" ]]; then printf "delete %s\n" "$*" >> "$CRONLOG"; exit 0; fi'
    printf '%s\n' 'exit 0'
  } >"$cli"
  chmod +x "$cli"

  # Roster with a real admin record so the helper's bridge_agent_exists gate
  # passes (it checks BRIDGE_AGENT_SESSION, not just the id list).
  {
    printf 'bridge_add_agent_id_if_missing %q\n' "$ADMIN"
    printf 'BRIDGE_AGENT_SESSION[%q]=%q\n' "$ADMIN" "$ADMIN"
  } >"$roster_local"

  # Driver: source the REAL bridge-lib.sh + the migration lib, prime the roster,
  # then call the helper exactly as bridge-init.sh does (which invokes it with
  # `|| true`, so no errexit-fatal posture).
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf 'export BRIDGE_ROSTER_LOCAL_FILE=%q\n' "$roster_local"
    printf 'export BRIDGE_BASH_BIN=%q\n' "$BRIDGE_BASH_BIN_FALLBACK"
    printf 'source %q\n' "$SMOKE_REPO_ROOT/bridge-lib.sh"
    printf 'source %q\n' "$SMOKE_REPO_ROOT/lib/bridge-init-default-crons.sh"
    printf '%s\n' 'bridge_load_roster >/dev/null 2>&1 || true'
    printf 'bridge_init_register_default_picker_sweep %q %q\n' "$cli" "$ADMIN"
  } >"$driver"

  "$BRIDGE_BASH_BIN_FALLBACK" "$driver" 2>&1 || true
  printf '__CRONLOG__\n'
  cat "$cron_log"
  printf '__ENDCRONLOG__\n'
  rm -rf -- "$probe_dir"
}

probe_cron_log() {
  printf '%s\n' "$1" | sed -n '/^__CRONLOG__$/,/^__ENDCRONLOG__$/p' | sed '1d;$d'
}

# Scenario 1: legacy present + create OK → recreate-first (create logged before
# delete; legacy then removed; never a neither-window).
assert_migrate_success_is_recreate_first() {
  local out log
  out="$(run_migrate_probe success legacy 0)"
  log="$(probe_cron_log "$out")"

  smoke_assert_contains "$log" "create" \
    "migrate-success: shell-kind cron create must be invoked"
  smoke_assert_contains "$log" "--kind shell" \
    "migrate-success: the create must be the SHELL-kind cron"
  smoke_assert_contains "$log" "delete leg1" \
    "migrate-success: the legacy text-kind row (leg1) must be deleted after create"
  smoke_assert_contains "$out" "picker-sweep cron registered" \
    "migrate-success: helper must log the shell-kind registration"

  # Recreate-FIRST ordering: the create line must precede the delete line.
  local create_ln delete_ln
  create_ln="$(printf '%s\n' "$log" | grep -n '^create ' | head -n1 | cut -d: -f1 || true)"
  delete_ln="$(printf '%s\n' "$log" | grep -n '^delete ' | head -n1 | cut -d: -f1 || true)"
  [[ -n "$create_ln" ]] || smoke_fail "migrate-success: no create line in cron log: $log"
  [[ -n "$delete_ln" ]] || smoke_fail "migrate-success: no delete line in cron log: $log"
  [[ "$create_ln" -lt "$delete_ln" ]] || smoke_fail \
    "migrate-success: create (line $create_ln) must precede delete (line $delete_ln) — recreate-first ordering, never delete-then-recreate. Log: $log"
}

# Scenario 2 (THE regression): legacy present + create FAILS → legacy NOT
# deleted + a LEFT IN PLACE warning. No silent loss of picker-sweep.
assert_migrate_fault_keeps_legacy() {
  local out log
  out="$(run_migrate_probe fault legacy 1)"
  log="$(probe_cron_log "$out")"

  smoke_assert_contains "$log" "create" \
    "migrate-fault: the create must still be attempted"
  smoke_assert_not_contains "$log" "delete" \
    "migrate-fault: a FAILED create must NOT delete the legacy row (no net loss — #1916)"
  smoke_assert_contains "$out" "registration failed" \
    "migrate-fault: helper must log the registration failure"
  smoke_assert_contains "$out" "LEFT IN PLACE" \
    "migrate-fault: helper must warn that the legacy text-kind job is left in place"
}

# Scenario 3: shell already present (+ legacy) → legacy removed, create skipped.
assert_idempotent_removes_legacy_no_create() {
  local out log
  out="$(run_migrate_probe idem legacy+shell 0)"
  log="$(probe_cron_log "$out")"

  smoke_assert_not_contains "$log" "create" \
    "idempotent: a shell row already present must NOT trigger another create"
  smoke_assert_contains "$log" "delete leg1" \
    "idempotent: the coexisting legacy text-kind row must be cleaned up"
  smoke_assert_contains "$out" "already registered (shell-kind)" \
    "idempotent: helper must log the already-registered skip"
}

# Scenario 4: fresh install → create, no delete.
assert_fresh_install_creates_no_delete() {
  local out log
  out="$(run_migrate_probe fresh empty 0)"
  log="$(probe_cron_log "$out")"

  smoke_assert_contains "$log" "--kind shell" \
    "fresh: shell-kind cron must be registered"
  smoke_assert_not_contains "$log" "delete" \
    "fresh: nothing to migrate → no delete"
  smoke_assert_contains "$out" "picker-sweep cron registered" \
    "fresh: helper must log the registration"
}

# Scenario 5 (id-less edge, codex #1919 r1): an id-less legacy row alongside a
# shell row → leave + warn, NEVER a bogus `cron delete text` (the misparse bug
# where `IFS=$'\t' read` collapsed the kind into the id field).
# shellcheck disable=SC2329
assert_idless_legacy_with_shell_leaves_and_warns() {
  local out log
  out="$(run_migrate_probe idless-shell legacy-noid+shell 0)"
  log="$(probe_cron_log "$out")"

  smoke_assert_not_contains "$log" "create" \
    "id-less+shell: a shell row already present must NOT trigger a create"
  smoke_assert_not_contains "$log" "delete" \
    "id-less+shell: no id to target + title-delete ambiguous with the shell row → must NOT delete (no 'cron delete text' misparse)"
  smoke_assert_contains "$out" "legacy id-less text-kind row remains" \
    "id-less+shell: must warn that the id-less legacy row is left in place"
}

# Scenario 6 (id-less edge): an id-less legacy-only row + successful create →
# shell registered, legacy LEFT + warn, NEVER `cron delete text`.
# shellcheck disable=SC2329
assert_idless_legacy_only_create_leaves_and_warns() {
  local out log
  out="$(run_migrate_probe idless-only legacy-noid 0)"
  log="$(probe_cron_log "$out")"

  smoke_assert_contains "$log" "--kind shell" \
    "id-less-only: shell-kind cron must be registered"
  smoke_assert_not_contains "$log" "delete" \
    "id-less-only: no id to delete → must NOT emit 'cron delete text' (the misparse bug)"
  smoke_assert_contains "$out" "picker-sweep cron registered" \
    "id-less-only: helper must log the registration"
  smoke_assert_contains "$out" "legacy id-less text-kind row remains" \
    "id-less-only: must warn that the id-less legacy row is left in place"
}

main() {
  smoke_require_cmd grep
  smoke_require_cmd sed
  # Full isolated BRIDGE_HOME (not just a temp root): the driver sources
  # bridge-lib.sh and calls bridge_load_roster / bridge_agent_exists, which need
  # a clean BRIDGE_HOME + BRIDGE_ROSTER_FILE. Without it the gate silently
  # early-returns on Linux CI (empty cron log) while macOS happened to tolerate
  # it — same env-isolation pattern the admin-pair sibling smoke uses.
  smoke_setup_bridge_home "$SMOKE_NAME"
  : "${BRIDGE_BASH_BIN_FALLBACK:=bash}"
  export BRIDGE_BASH_BIN_FALLBACK

  smoke_run "migrate success → recreate-first (create before delete, no neither-window)" \
    assert_migrate_success_is_recreate_first
  smoke_run "migrate fault → legacy LEFT IN PLACE on failed create (#1916 regression)" \
    assert_migrate_fault_keeps_legacy
  smoke_run "shell already present → legacy removed, create skipped (idempotent)" \
    assert_idempotent_removes_legacy_no_create
  smoke_run "fresh install → shell-kind created, nothing to delete" \
    assert_fresh_install_creates_no_delete
  smoke_run "id-less legacy + shell present → leave + warn (no bogus 'delete text')" \
    assert_idless_legacy_with_shell_leaves_and_warns
  smoke_run "id-less legacy only + create OK → registered, leave + warn (no 'delete text')" \
    assert_idless_legacy_only_create_leaves_and_warns

  smoke_log "all #1916 picker-sweep migration fail-safe ordering checks pass"
}

main "$@"
