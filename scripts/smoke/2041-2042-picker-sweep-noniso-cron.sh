#!/usr/bin/env bash
# scripts/smoke/2041-2042-picker-sweep-noniso-cron.sh — Issues #2041 + #2042.
#
# The default picker-sweep cron (#833) registers as a SHELL-kind controller-direct
# job. That form is only ACCEPTED on a host where `--kind shell` resolves a
# controller UID (iso v2 effective, OR the run-as-agent resolves to the
# controller's own UID). On a NON-iso / macOS install the admin agent satisfies
# neither, so the CLI rejects every `cron create --kind shell` attempt. The
# pre-fix code swallowed that rejection and:
#   - #2041 — left a fresh non-iso install with NO working picker-sweep (silent
#     no-op, generic "register manually" line, no reason surfaced).
#   - #2042 — re-attempted the shell-kind MIGRATION + re-logged `failed` on
#     EVERY upgrade, never converging (the legacy text-kind job stayed in place
#     but the failure line recurred indefinitely).
#
# The fix makes registration PLATFORM/ISO-AWARE (the same predicate the rest of
# the code gates iso behavior with — `bridge_cron_shell_run_as_is_controller`
# OR `bridge_agent_linux_user_isolation_effective`, reproduced as
# `_bridge_init_picker_sweep_shell_kind_supported`). This smoke pins:
#   1. NON-ISO + fresh install → a WORKING text-kind picker-sweep is registered
#      (NOT a silent no-op, NOT a `failed` line).
#   2. NON-ISO + text-kind already present (the upgraded-host case) → converged:
#      no create, no `failed`, no re-migration. IDEMPOTENT across repeated
#      "upgrades" (a 2nd run is byte-for-byte the same — no re-`failed`).
#   3. SHELL-SUPPORTED host (run-as resolves to the controller UID) → shell-kind
#      STILL registers (the iso/Linux path is UNCHANGED — platform branch, not a
#      blanket revert).
#   4. MUTATION proof: the platform predicate itself returns false for the
#      non-iso admin and true for the controller-UID admin. Reverting the
#      branch (no longer consulting it) routes non-iso back into the shell-kind
#      path, where the shim's create is rejected → the re-`failed` regression.
#
# Footgun #11 / lint-heredoc-ban: this smoke feeds NO heredoc to a subprocess,
# uses NO here-string, and NO `cat <<EOF`. The CLI shim, JSON fixtures, and
# driver are all written with printf and `source`d / executed by path.

set -euo pipefail

SMOKE_NAME="2041-2042-picker-sweep-noniso-cron"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# A non-iso admin: an agent id with NO roster os_user that is NOT an OS user on
# this host, so `id -u <admin>` fails and the agent has no effective iso. This
# is exactly the macOS/non-iso shape of #2041/#2042 (admin 'patch' is not an OS
# user). The 'noniso-' prefix + smoke pid makes a collision with a real account
# effectively impossible on CI.
NONISO_ADMIN="noniso-sweep-$$"
# A controller-UID admin: the current login user name resolves to the current
# UID, so the controller-direct shell shape is accepted (no iso v2 required).
# This deterministically exercises the shell-kind branch on macOS AND Linux CI.
CTRL_ADMIN="$(id -un 2>/dev/null || printf '')"

# Run the picker-sweep registration helper against a stateful recorder shim.
#   $1 = scenario tag (temp-dir suffix)
#   $2 = admin agent id (drives the platform predicate)
#   $3 = initial cron state: empty | text   (text = a legacy/working text-kind row)
# Echoes the helper's combined stdout+stderr, then the recorded CRON LOG between
# __CRONLOG__ / __ENDCRONLOG__ markers (one `create …` / `delete …` line per
# invocation, in call order).
run_register_probe() {
  local tag="$1" admin="$2" initial="$3"
  # $4 (optional) = "fail-shell": make a controller-UID SHELL-kind create FAIL
  # even on a shell-supported host (fault injection for the #1916/#2041 fail-safe
  # + the set -e safety of the diagnostic path).
  local fault="${4:-}"
  local probe_dir
  probe_dir="$(mktemp -d "$SMOKE_TMP_ROOT/2041-$tag.XXXXXX")"

  local state_json="$probe_dir/state.json"
  local shell_json="$probe_dir/shell.json"
  local cron_log="$probe_dir/cron.log"
  local roster_local="$probe_dir/agent-roster.local.sh"
  local cli="$probe_dir/agent-bridge"
  local driver="$probe_dir/driver.sh"
  : >"$cron_log"

  # Text rows carry the cron `agent` so the enumerate can tell an ADMIN-targeted
  # (working) row from a legacy `<admin>-dev` codex-pair row (#2041/#2042 codex
  # finding a). TEXT_ADMIN = the converged working form; TEXT_LEGACY = the broken
  # codex-pair row a pre-#833 upgraded host carries (must be migrated off).
  # JSON string values need literal double-quotes (NOT `%q`, which is shell
  # quoting). The admin id is a `[A-Za-z0-9-]` slug, so no JSON escaping needed.
  local TEXT_ADMIN
  TEXT_ADMIN="$(printf '{"id":"txtA","title":"picker-sweep","agent":"%s","payload":{"kind":"text"}}' "$admin")"
  local TEXT_LEGACY
  TEXT_LEGACY="$(printf '{"id":"txtL","title":"picker-sweep","agent":"%s","payload":{"kind":"text"}}' "${admin}-dev")"
  local SHELL
  SHELL="$(printf '{"id":"sh1","title":"picker-sweep","agent":"%s","payload":{"kind":"shell"}}' "$admin")"
  case "$initial" in
    empty)       printf '{"jobs":[]}\n' >"$state_json" ;;
    text-admin)  printf '{"jobs":[%s]}\n' "$TEXT_ADMIN" >"$state_json" ;;
    text-legacy) printf '{"jobs":[%s]}\n' "$TEXT_LEGACY" >"$state_json" ;;
    *)           smoke_fail "unknown initial state: $initial" ;;
  esac
  # Post-successful-shell-create state (the controller-UID scenario): the shell
  # row is present so verify-before-delete confirms it.
  printf '{"jobs":[%s]}\n' "$SHELL" >"$shell_json"

  # Recorder CLI shim (bash). `cron list` = cat current state. `cron create`:
  #   - a SHELL-kind create (argv contains "--kind shell") FAILS on a non-iso
  #     host exactly like the real CLI (rc=1, emits the iso rejection to stderr);
  #     this is the structural rejection the platform branch must avoid.
  #     On a controller-UID host the shim accepts it (rc=0) and swaps state to
  #     show the shell row.
  #   - a TEXT-kind create (no "--kind shell") always succeeds (rc=0) and swaps
  #     state to show the text row.
  # `cron delete` = log. Stateful so verify-before-delete sees the new row.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'STATE=%q\n' "$state_json"
    printf 'SHELLJSON=%q\n' "$shell_json"
    printf 'CRONLOG=%q\n' "$cron_log"
    printf 'TEXTROW=%q\n' "$TEXT_ADMIN"
    printf 'CTRL_OK=%q\n' "$( [[ "$admin" == "$CTRL_ADMIN" && -n "$CTRL_ADMIN" ]] && printf 1 || printf 0 )"
    printf 'FAIL_SHELL=%q\n' "$( [[ "$fault" == "fail-shell" ]] && printf 1 || printf 0 )"
    printf '%s\n' 'args="$*"'
    printf '%s\n' 'if [[ "$1" == "cron" && "$2" == "list" ]]; then cat "$STATE"; exit 0; fi'
    printf '%s\n' 'if [[ "$1" == "cron" && "$2" == "create" ]]; then'
    printf '%s\n' '  printf "create %s\n" "$args" >> "$CRONLOG"'
    printf '%s\n' '  if [[ "$args" == *"--kind shell"* ]]; then'
    printf '%s\n' '    if [[ "$CTRL_OK" != "1" || "$FAIL_SHELL" == "1" ]]; then'
    printf '%s\n' '      printf "[error] --kind shell create rejected/failed (injected or non-iso).\n" >&2'
    printf '%s\n' '      exit 1'
    printf '%s\n' '    fi'
    printf '%s\n' '    cp "$SHELLJSON" "$STATE"; exit 0'
    printf '%s\n' '  fi'
    printf '%s\n' '  printf "{\"jobs\":[%s]}\n" "$TEXTROW" > "$STATE"; exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [[ "$1" == "cron" && "$2" == "delete" ]]; then printf "delete %s\n" "$args" >> "$CRONLOG"; exit 0; fi'
    printf '%s\n' 'exit 0'
  } >"$cli"
  chmod +x "$cli"

  # Roster with a real admin record so the helper's bridge_agent_exists gate
  # passes (it checks BRIDGE_AGENT_SESSION). No os_user / isolation_mode is set,
  # so the agent is non-iso; the controller-UID resolution is purely by name.
  {
    printf 'bridge_add_agent_id_if_missing %q\n' "$admin"
    printf 'BRIDGE_AGENT_SESSION[%q]=%q\n' "$admin" "$admin"
  } >"$roster_local"

  # Driver: source the REAL bridge-lib.sh + the registration lib, prime the
  # roster, then call the helper under `set -euo pipefail` — the EXACT errexit
  # posture bridge-upgrade.sh's picker-sweep backfill runs it in (the inner
  # subshell at bridge-upgrade.sh sets `set -euo pipefail` before sourcing +
  # calling the helper). A `cmd; rc=$?` create that aborts under set -e would
  # therefore skip the diagnostic + tempfile cleanup — this driver catches that.
  # The trailing `|| true` mirrors how the caller disarms the helper's own return
  # for the harness, WITHOUT disabling set -e inside the helper body.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf 'export BRIDGE_ROSTER_LOCAL_FILE=%q\n' "$roster_local"
    printf 'export BRIDGE_BASH_BIN=%q\n' "$BRIDGE_BASH_BIN_FALLBACK"
    printf 'source %q\n' "$SMOKE_REPO_ROOT/bridge-lib.sh"
    printf 'source %q\n' "$SMOKE_REPO_ROOT/lib/bridge-init-default-crons.sh"
    printf '%s\n' 'bridge_load_roster >/dev/null 2>&1 || true'
    printf 'bridge_init_register_default_picker_sweep %q %q || true\n' "$cli" "$admin"
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

# Directly probe the platform predicate (the mutation anchor). Sources the lib
# + roster and reports the predicate's exit status for an admin.
probe_predicate() {
  local admin="$1"
  local probe_dir roster_local driver
  probe_dir="$(mktemp -d "$SMOKE_TMP_ROOT/2041-pred.XXXXXX")"
  roster_local="$probe_dir/agent-roster.local.sh"
  driver="$probe_dir/driver.sh"
  {
    printf 'bridge_add_agent_id_if_missing %q\n' "$admin"
    printf 'BRIDGE_AGENT_SESSION[%q]=%q\n' "$admin" "$admin"
  } >"$roster_local"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf 'export BRIDGE_ROSTER_LOCAL_FILE=%q\n' "$roster_local"
    printf 'source %q\n' "$SMOKE_REPO_ROOT/bridge-lib.sh"
    printf 'source %q\n' "$SMOKE_REPO_ROOT/lib/bridge-init-default-crons.sh"
    printf '%s\n' 'bridge_load_roster >/dev/null 2>&1 || true'
    printf 'if _bridge_init_picker_sweep_shell_kind_supported %q; then printf SUPPORTED; else printf UNSUPPORTED; fi\n' "$admin"
  } >"$driver"
  "$BRIDGE_BASH_BIN_FALLBACK" "$driver" 2>/dev/null || true
  rm -rf -- "$probe_dir"
}

# Scenario 1 (#2041): non-iso fresh install → text-kind registered, no failure.
assert_noniso_fresh_registers_text_kind() {
  local out log
  out="$(run_register_probe noniso-fresh "$NONISO_ADMIN" empty)"
  log="$(probe_cron_log "$out")"

  smoke_assert_contains "$log" "create" \
    "noniso-fresh: a cron create must be attempted (no silent no-op — #2041)"
  smoke_assert_not_contains "$log" "--kind shell" \
    "noniso-fresh: a non-iso host must NOT attempt the rejected shell-kind create"
  smoke_assert_contains "$out" "registered (*/10 * * * *, text-kind" \
    "noniso-fresh: a WORKING text-kind picker-sweep must be registered"
  smoke_assert_not_contains "$out" "registration failed" \
    "noniso-fresh: no failure line — the host now has a working picker-sweep (#2041)"
}

# Scenario 2 (#2042): non-iso upgraded host with the WORKING admin-targeted text
# row already present → converged. No create, no delete, NO `failed` line; and
# the 2nd "upgrade" is identical (idempotent — never re-logs `failed`).
assert_noniso_text_present_converges_idempotent() {
  local out1 log1 out2 log2
  out1="$(run_register_probe noniso-up1 "$NONISO_ADMIN" text-admin)"
  log1="$(probe_cron_log "$out1")"

  smoke_assert_not_contains "$log1" "create" \
    "noniso-upgrade: an existing admin text-kind row is the converged form — must NOT re-create"
  smoke_assert_not_contains "$log1" "delete" \
    "noniso-upgrade: must NOT delete the working admin text-kind row"
  smoke_assert_contains "$out1" "already registered (text-kind, admin-targeted)" \
    "noniso-upgrade: helper must log the converged admin text-kind skip"
  smoke_assert_not_contains "$out1" "registration failed" \
    "noniso-upgrade: NO 'failed' line on a host that structurally can't run shell-kind (#2042)"

  # Idempotency: a 2nd "upgrade" pass must behave identically — still converged,
  # still no `failed` line (the perpetual re-fail #2042 reported).
  out2="$(run_register_probe noniso-up2 "$NONISO_ADMIN" text-admin)"
  log2="$(probe_cron_log "$out2")"
  smoke_assert_not_contains "$log2" "create" \
    "noniso-upgrade-rerun: still converged on the 2nd upgrade (no create)"
  smoke_assert_not_contains "$out2" "registration failed" \
    "noniso-upgrade-rerun: still NO 'failed' line on the 2nd upgrade (idempotent convergence — #2042)"
}

# Scenario 2b (#2041/#2042 codex finding a): non-iso upgraded host carrying ONLY
# the legacy `<admin>-dev` codex-pair text row (which CANNOT exec a bash payload
# — #833). That row must NOT be treated as converged: the helper registers the
# working ADMIN text row FIRST, then removes the legacy row by id (recreate-first,
# never strands the host). A 2nd upgrade (now the admin row is present) converges.
assert_noniso_legacy_codexpair_row_migrates() {
  local out1 log1 out2 log2
  out1="$(run_register_probe noniso-leg1 "$NONISO_ADMIN" text-legacy)"
  log1="$(probe_cron_log "$out1")"

  smoke_assert_contains "$log1" "create" \
    "noniso-legacy: a legacy codex-pair text row is NOT converged — the working admin row must be created"
  smoke_assert_not_contains "$log1" "--kind shell" \
    "noniso-legacy: a non-iso host must NOT attempt the rejected shell-kind create"
  smoke_assert_contains "$out1" "registered (*/10 * * * *, text-kind" \
    "noniso-legacy: the working admin text-kind row must be registered"
  smoke_assert_contains "$log1" "delete txtL" \
    "noniso-legacy: the legacy codex-pair row (txtL) must be removed by id AFTER the admin row is created"
  smoke_assert_not_contains "$out1" "registration failed" \
    "noniso-legacy: no failure line — the migration installs a working picker-sweep"

  # Recreate-FIRST ordering: the create line must precede the delete line.
  local create_ln delete_ln
  create_ln="$(printf '%s\n' "$log1" | grep -n '^create ' | head -n1 | cut -d: -f1 || true)"
  delete_ln="$(printf '%s\n' "$log1" | grep -n '^delete ' | head -n1 | cut -d: -f1 || true)"
  [[ -n "$create_ln" && -n "$delete_ln" ]] || smoke_fail "noniso-legacy: expected both a create and a delete line; log: $log1"
  [[ "$create_ln" -lt "$delete_ln" ]] || smoke_fail \
    "noniso-legacy: create (line $create_ln) must precede delete (line $delete_ln) — recreate-first, never strand. Log: $log1"
}

# Scenario 3 (regression guard): a controller-UID admin → shell-kind STILL
# registers. The iso/controller path is UNCHANGED by the platform branch.
assert_controller_uid_registers_shell_kind() {
  if [[ -z "$CTRL_ADMIN" ]]; then
    smoke_log "skip: controller-UID shell-kind case (could not resolve login user via id -un)"
    return 0
  fi
  local out log
  out="$(run_register_probe ctrl-fresh "$CTRL_ADMIN" empty)"
  log="$(probe_cron_log "$out")"

  smoke_assert_contains "$log" "--kind shell" \
    "controller-uid: the shell-kind cron must STILL be registered (iso/Linux path unchanged)"
  smoke_assert_contains "$out" "registered (*/10 * * * *, shell-kind" \
    "controller-uid: helper must log the shell-kind registration"
  smoke_assert_not_contains "$out" "registration failed" \
    "controller-uid: shell-kind create succeeds when run-as resolves to the controller UID"
}

# Scenario 3b (codex finding b/f — set -e safety): controller-UID admin + a
# FAILING shell-kind create, run under `set -euo pipefail` (the upgrade backfill
# posture). The helper must still reach + emit the fail-safe diagnostic (and not
# abort at the create line), proving the `if ! cmd; then` form is errexit-safe.
assert_shell_create_failure_is_set_e_safe() {
  if [[ -z "$CTRL_ADMIN" ]]; then
    smoke_log "skip: set -e fail-safe case (could not resolve login user via id -un)"
    return 0
  fi
  local out log
  out="$(run_register_probe ctrl-fault "$CTRL_ADMIN" empty fail-shell)"
  log="$(probe_cron_log "$out")"

  smoke_assert_contains "$log" "--kind shell" \
    "set-e-safe: the shell-kind create must be attempted"
  smoke_assert_contains "$out" "registration failed" \
    "set-e-safe: a FAILED shell-kind create must still emit the fail-safe diagnostic (not abort under set -e before it)"
  smoke_assert_not_contains "$out" "registered (*/10 * * * *, shell-kind" \
    "set-e-safe: a failed create must NOT log success"
}

# Scenario 4 (MUTATION anchor): the platform predicate is what distinguishes the
# two paths. It must be UNSUPPORTED for the non-iso admin (→ text-kind) and
# SUPPORTED for the controller-UID admin (→ shell-kind). Reverting the branch
# (no longer consulting this predicate) sends the non-iso admin back into the
# shell-kind create the shim rejects → the #2042 re-`failed` regression.
assert_platform_predicate_discriminates() {
  local noniso_verdict ctrl_verdict
  noniso_verdict="$(probe_predicate "$NONISO_ADMIN")"
  smoke_assert_eq "UNSUPPORTED" "$noniso_verdict" \
    "predicate: a non-iso admin (no os_user, not an OS user, no iso) must be shell-kind UNSUPPORTED"

  if [[ -n "$CTRL_ADMIN" ]]; then
    ctrl_verdict="$(probe_predicate "$CTRL_ADMIN")"
    smoke_assert_eq "SUPPORTED" "$ctrl_verdict" \
      "predicate: a controller-UID admin (run-as resolves to current UID) must be shell-kind SUPPORTED"
  else
    smoke_log "skip: controller-UID predicate case (could not resolve login user)"
  fi
}

main() {
  smoke_require_cmd grep
  smoke_require_cmd sed
  # Full isolated BRIDGE_HOME: the driver sources bridge-lib.sh and calls
  # bridge_load_roster / bridge_agent_exists, which need a clean BRIDGE_HOME +
  # BRIDGE_ROSTER_FILE (same pattern as the #1916 sibling smoke).
  smoke_setup_bridge_home "$SMOKE_NAME"
  : "${BRIDGE_BASH_BIN_FALLBACK:=bash}"
  export BRIDGE_BASH_BIN_FALLBACK

  smoke_run "non-iso fresh install → working text-kind picker-sweep registered (#2041)" \
    assert_noniso_fresh_registers_text_kind
  smoke_run "non-iso upgrade (admin text present) → converged, no re-failed, idempotent (#2042)" \
    assert_noniso_text_present_converges_idempotent
  smoke_run "non-iso legacy codex-pair text row only → migrate to admin row, recreate-first" \
    assert_noniso_legacy_codexpair_row_migrates
  smoke_run "controller-UID admin → shell-kind still registers (iso path unchanged)" \
    assert_controller_uid_registers_shell_kind
  smoke_run "failed shell-kind create under set -euo pipefail → fail-safe diagnostic (set -e safe)" \
    assert_shell_create_failure_is_set_e_safe
  smoke_run "platform predicate discriminates non-iso vs controller-UID (mutation anchor)" \
    assert_platform_predicate_discriminates

  smoke_log "all #2041/#2042 platform-aware picker-sweep registration checks pass"
}

main "$@"
