#!/usr/bin/env bash
# scripts/smoke/admin-pair-server-auto-provision.sh — Issue #1052 / #1053.
#
# Locks the RESTORED contract (reconsidering #4769, which had reverted #517):
# the `<admin>-dev` codex pair IS auto-provisioned at install time — but ONLY
# when the codex CLI is present AND the resolved host profile is `server`.
#
# Gate matrix asserted here (`bridge_init_provision_admin_codex_pair`):
#   - host_profile=server + codex present + pair absent → `agent create
#     <admin>-dev --engine codex --always-on …` is invoked exactly once.
#   - host_profile=server + codex present + pair already in roster → no
#     `agent create` (idempotent — re-running bootstrap is a no-op).
#   - host_profile=dev   + codex present → NO `agent create` (the dev profile
#     stays admin-only by design; the dev advisory prints the manual recipe).
#   - host_profile=server + codex absent → NO `agent create` (claude admin
#     runs solo; onboarding note that pair-programming is unavailable).
#   - `<admin>` is derived install-relatively (`manager` → `manager-dev`).
#
# Method: the helper `bridge_init_provision_admin_codex_pair` is sourced from
# lib/bridge-init-codex-pair.sh in isolation and probed directly with stubbed
# dependency functions (`bridge_resolve_engine_cli`, `bridge_agent_exists`,
# `bridge_agent_workdir`, `bridge_agent_default_home`) and a recorder CLI shim
# in place of the real `agent-bridge` binary. The shim appends its argv to a
# log file; the smoke asserts on that log. This exercises the exact gate logic
# a real `bridge-init.sh` run takes (it calls this same function) without
# needing a full non-dry-run init — which would trip the macOS host-profile
# saver bug and the Bash 5.3.9 heredoc deadlocks in the create chain.
#
# Footgun #11 / lint-heredoc-ban: this smoke does NOT feed any heredoc to a
# subprocess, use a here-string, or a process substitution. The probe driver
# is written to a tempfile and `source`d; the CLI shim is written with printf.
#
# C-grep: a source-level guard additionally asserts the helper is wired into
# bridge-init.sh AFTER host-profile resolution and BEFORE the picker-sweep
# cron registration, so the pair exists before the cron that targets it.

set -euo pipefail

SMOKE_NAME="admin-pair-server-auto-provision"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Run the codex-pair provisioning helper in an isolated subshell with stubbed
# dependencies. Echoes the recorded `agent create` argv log (one line per
# invocation, empty when the helper made no create call) on stdout, and the
# helper's own stderr diagnostics interleaved.
#
# Args:
#   $1 = label (temp-dir prefix)
#   $2 = admin agent id
#   $3 = host profile (`server` | `dev` | "")
#   $4 = codex-present flag (1 = codex on PATH, 0 = absent)
#   $5 = pair-exists flag    (1 = `<admin>-dev` already in roster, 0 = absent)
run_provision_probe() {
  local label="$1" admin="$2" profile="$3" codex_present="$4" pair_exists="$5"
  local probe_dir
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-bridge-${label}.XXXXXX")"

  local create_log="$probe_dir/agent-create.log"
  : >"$create_log"

  # Recorder CLI shim — stands in for the live `agent-bridge` binary. Appends
  # its full argv to the log so the smoke can assert exactly one (or zero)
  # `agent create` invocation and inspect the flags. Exit 0 (create succeeds).
  local cli_shim="$probe_dir/agent-bridge"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' \
    "$create_log" >"$cli_shim"
  chmod +x "$cli_shim"

  # Probe driver: stub the helper's dependency functions, source the helper,
  # call it. Written to a tempfile and sourced (no heredoc-to-subprocess).
  local driver="$probe_dir/driver.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf 'BRIDGE_BASH_BIN=%q\n' "$BRIDGE_BASH_BIN_FALLBACK"
    # Stub: codex detection — only `codex` resolves, and only when present.
    printf 'CODEX_PRESENT=%q\n' "$codex_present"
    printf '%s\n' 'bridge_resolve_engine_cli() {'
    printf '%s\n' '  if [[ "$1" == "codex" && "$CODEX_PRESENT" == "1" ]]; then'
    printf '%s\n' '    printf "/usr/bin/codex"'
    printf '%s\n' '  fi'
    printf '%s\n' '}'
    # Stub: roster existence — `<admin>-dev` present only when pair_exists=1.
    printf 'PAIR_EXISTS=%q\n' "$pair_exists"
    printf 'PAIR_NAME=%q\n' "${admin}-dev"
    printf '%s\n' 'bridge_agent_exists() {'
    printf '%s\n' '  [[ "$1" == "$PAIR_NAME" && "$PAIR_EXISTS" == "1" ]]'
    printf '%s\n' '}'
    # Stub: workdir resolution — admin has a known workdir.
    printf '%s\n' 'bridge_agent_workdir() { printf "/tmp/admin-workdir"; }'
    printf '%s\n' 'bridge_agent_default_home() { printf "/tmp/%s-home" "$1"; }'
    # Stub: roster cache refresh — no-op here (this isolated probe does not
    # source bridge-lib.sh; the dedicated first-run ordering probe below
    # exercises the REAL cache machinery).
    printf '%s\n' 'bridge_roster_cache_invalidate() { :; }'
    printf '%s\n' 'bridge_load_roster() { :; }'
    printf 'source %q\n' "$SMOKE_REPO_ROOT/lib/bridge-init-codex-pair.sh"
    printf 'bridge_init_provision_admin_codex_pair %q %q %q\n' \
      "$cli_shim" "$admin" "$profile"
  } >"$driver"

  # shellcheck disable=SC1090
  "$BRIDGE_BASH_BIN_FALLBACK" "$driver" 2>&1 || true
  # Emit the recorded create-call log (may be empty) as a final marker block.
  printf '__CREATE_LOG_START__\n'
  cat "$create_log"
  printf '__CREATE_LOG_END__\n'
  rm -rf -- "$probe_dir"
}

# Extract the recorded `agent create` argv lines from a probe's output.
probe_create_log() {
  local out="$1"
  printf '%s\n' "$out" | sed -n '/^__CREATE_LOG_START__$/,/^__CREATE_LOG_END__$/p' \
    | sed '1d;$d'
}

# First-run ORDERING probe — exercises the real sequence a server install
# takes: bridge_init_provision_admin_codex_pair (creates `<admin>-dev`, which
# mutates agent-roster.local.sh) immediately followed by
# bridge_init_register_default_picker_sweep (gates on `bridge_agent_exists
# <admin>-dev`). Both helpers run in ONE sourced process against the REAL
# roster machinery from bridge-lib.sh — so the parent's in-memory roster cache
# is genuinely stale after the child create unless the provisioning helper
# invalidates + reloads it. This is what catches the codex r1 BLOCKING finding
# (stale cache → picker-sweep skipped on first run).
#
# The CLI shim genuinely mutates `agent-roster.local.sh` on `agent create`
# (appending the `bridge_add_agent_id_if_missing` line a real create writes),
# and records `cron create` invocations to a log. The smoke then asserts the
# picker-sweep cron WAS registered (gate passed = cache was refreshed) and
# that the "not in roster" skip message did NOT fire.
#
# Echoes the helper diagnostics, then a marker block with the recorded
# `cron create` log.
run_ordering_probe() {
  local admin="$1"
  local probe_dir
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-bridge-ordering.XXXXXX")"
  local cron_log="$probe_dir/cron-create.log"
  : >"$cron_log"

  # Isolated roster file: starts with the admin only (the pre-create state a
  # first-run init reaches after the admin `agent create`).
  #
  # #1888 r2 (codex BLOCKING finding 2): register a REAL admin record, not just
  # the id. `bridge_agent_exists` checks BRIDGE_AGENT_SESSION[<id>] (not
  # BRIDGE_AGENT_IDS), so a bare `bridge_add_agent_id_if_missing patch` left the
  # picker-sweep `bridge_agent_exists patch` gate failing
  # (`admin agent patch not in roster`). Write the BRIDGE_AGENT_SESSION entry the
  # admin `agent create` actually persists so the gate sees a real admin.
  local roster_local="$probe_dir/agent-roster.local.sh"
  {
    printf 'bridge_add_agent_id_if_missing %q\n' "$admin"
    printf 'BRIDGE_AGENT_SESSION[%q]=%q\n' "$admin" "$admin"
  } >"$roster_local"

  # CLI shim: handles the two subcommands the helpers invoke.
  #   - `agent create <name> …` → append a roster block that registers the
  #     agent the way a real `agent create` does (id + BRIDGE_AGENT_SESSION,
  #     the map `bridge_agent_exists` actually checks), so the on-disk roster
  #     genuinely changes and the parent cache goes stale until reloaded.
  #   - `cron list --json`      → empty job list (fresh install).
  #   - `cron create …`        → record the invocation; this is the assertion
  #     surface — it only runs if the picker-sweep `bridge_agent_exists` gate
  #     passed, i.e. the cache was refreshed.
  local cli_shim="$probe_dir/agent-bridge"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'ROSTER_LOCAL=%q\n' "$roster_local"
    printf 'CRON_LOG=%q\n' "$cron_log"
    printf '%s\n' 'if [[ "$1" == "agent" && "$2" == "create" ]]; then'
    printf '%s\n' '  printf "bridge_add_agent_id_if_missing %q\\nBRIDGE_AGENT_SESSION[%q]=%q\\n" "$3" "$3" "$3" >> "$ROSTER_LOCAL"'
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [[ "$1" == "cron" && "$2" == "list" ]]; then'
    printf '%s\n' '  printf "{\\"jobs\\":[]}\\n"'
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [[ "$1" == "cron" && "$2" == "create" ]]; then'
    printf '%s\n' '  printf "%s\\n" "$*" >> "$CRON_LOG"'
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'exit 0'
  } >"$cli_shim"
  chmod +x "$cli_shim"

  # Driver: source the real bridge-lib.sh (real bridge_load_roster /
  # bridge_agent_exists / bridge_roster_cache_invalidate) + both helper libs,
  # pre-load the roster (cache now has admin only), then run the two helpers
  # in sequence exactly as bridge-init.sh does.
  local driver="$probe_dir/driver.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf 'export BRIDGE_ROSTER_LOCAL_FILE=%q\n' "$roster_local"
    # codex must resolve as present so the provisioning helper proceeds.
    printf 'export PATH=%q\n' "$probe_dir/bin:$PATH"
    printf 'source %q\n' "$SMOKE_REPO_ROOT/bridge-lib.sh"
    printf 'source %q\n' "$SMOKE_REPO_ROOT/lib/bridge-init-codex-pair.sh"
    printf 'source %q\n' "$SMOKE_REPO_ROOT/lib/bridge-init-default-crons.sh"
    # Prime the parent cache BEFORE the create — this is the stale-cache setup.
    printf '%s\n' 'bridge_load_roster >/dev/null 2>&1 || true'
    printf 'bridge_init_provision_admin_codex_pair %q %q server\n' \
      "$cli_shim" "$admin"
    printf 'bridge_init_register_default_picker_sweep %q %q\n' \
      "$cli_shim" "$admin"
  } >"$driver"

  # codex CLI stub on PATH so bridge_resolve_engine_cli resolves it.
  mkdir -p "$probe_dir/bin"
  printf '#!/bin/sh\nexit 0\n' >"$probe_dir/bin/codex"
  chmod +x "$probe_dir/bin/codex"

  # shellcheck disable=SC1090
  "$BRIDGE_BASH_BIN_FALLBACK" "$driver" 2>&1 || true
  printf '__CRON_LOG_START__\n'
  cat "$cron_log"
  printf '__CRON_LOG_END__\n'
  rm -rf -- "$probe_dir"
}

probe_cron_log() {
  local out="$1"
  printf '%s\n' "$out" | sed -n '/^__CRON_LOG_START__$/,/^__CRON_LOG_END__$/p' \
    | sed '1d;$d'
}

assert_server_codex_present_provisions() {
  local out log
  out="$(run_provision_probe server-go manager server 1 0)"
  log="$(probe_create_log "$out")"
  [[ -n "$log" ]] || smoke_fail "server+codex: expected an 'agent create' invocation, got none. Helper output: $out"
  local count
  count="$(printf '%s\n' "$log" | grep -c 'agent create' || true)"
  smoke_assert_eq "1" "$count" \
    "server+codex: expected exactly one 'agent create' invocation (got $count)"
  smoke_assert_contains "$log" "agent create manager-dev" \
    "server+codex: pair name must be derived install-relatively (<admin>-dev)"
  smoke_assert_contains "$log" "--engine codex" \
    "server+codex: pair must be created with --engine codex"
  smoke_assert_contains "$log" "--always-on" \
    "server+codex: pair must be created --always-on (permanent admin pair)"
  smoke_assert_contains "$out" "codex-pair auto-provisioned" \
    "server+codex: helper must log the auto-provision action"
}

assert_server_codex_present_idempotent() {
  local out log
  out="$(run_provision_probe server-idem manager server 1 1)"
  log="$(probe_create_log "$out")"
  smoke_assert_eq "" "$log" \
    "server+codex+pair-exists: re-running must NOT create a duplicate (got: $log)"
  smoke_assert_contains "$out" "already provisioned" \
    "server+codex+pair-exists: helper must log the idempotent skip"
}

assert_dev_profile_admin_only() {
  local out log
  out="$(run_provision_probe dev-only patch dev 1 0)"
  log="$(probe_create_log "$out")"
  smoke_assert_eq "" "$log" \
    "dev profile: must NOT auto-create the codex pair even when codex present (got: $log)"
  smoke_assert_contains "$out" "server-only" \
    "dev profile: helper must log that auto-provisioning is server-only"
}

assert_server_codex_absent_solo() {
  local out log
  out="$(run_provision_probe server-solo patch server 0 0)"
  log="$(probe_create_log "$out")"
  smoke_assert_eq "" "$log" \
    "server+codex-absent: must NOT create the pair when codex CLI is missing (got: $log)"
  smoke_assert_contains "$out" "codex CLI not found" \
    "server+codex-absent: helper must log that codex is unavailable"
  smoke_assert_contains "$out" "runs solo" \
    "server+codex-absent: helper must note the claude admin runs solo"
}

# First-run ordering: server+codex → `<admin>-dev` created AND the picker-sweep
# cron registered in the SAME run. Catches the stale-parent-roster-cache bug
# (codex r1 BLOCKING): the provisioning helper must invalidate + reload the
# parent's roster cache after the child `agent create`, or the immediately
# following picker-sweep `bridge_agent_exists` gate sees stale state and skips.
#
# #1888 r2 (codex BLOCKING finding 2): picker-sweep is now a SHELL-kind
# controller-direct cron run-as the ADMIN (resolves to the controller UID) — NOT
# a TEXT-kind dispatch to the `<admin>-dev` codex pair (a codex cron-subagent
# cannot exec a bash payload). Assert the new contract: `--kind shell --agent
# patch --run-as-agent patch` carrying the SCRIPT_PICKER_SWEEP_* env.
assert_first_run_provisions_and_registers_cron() {
  local out cron_log
  out="$(run_ordering_probe patch)"
  cron_log="$(probe_cron_log "$out")"
  smoke_assert_contains "$out" "codex-pair auto-provisioned" \
    "first-run ordering: provisioning helper must create the pair"
  smoke_assert_not_contains "$out" "picker-sweep cron skipped" \
    "first-run ordering: picker-sweep must NOT skip — stale roster cache means the provisioning helper failed to refresh it"
  [[ -n "$cron_log" ]] || smoke_fail "first-run ordering: picker-sweep cron was not registered in the same run (stale-cache regression). Helper output: $out"
  smoke_assert_contains "$cron_log" "picker-sweep" \
    "first-run ordering: registered cron must be the picker-sweep job"
  smoke_assert_contains "$cron_log" "--kind shell" \
    "first-run ordering: picker-sweep cron must be SHELL-kind (controller-direct, engine-independent)"
  smoke_assert_contains "$cron_log" "--agent patch" \
    "first-run ordering: picker-sweep cron must target the admin (controller UID), not the codex pair"
  smoke_assert_contains "$cron_log" "--run-as-agent patch" \
    "first-run ordering: picker-sweep shell cron must run-as the admin (resolves to controller UID)"
  smoke_assert_contains "$cron_log" "SCRIPT_PICKER_SWEEP_ENABLED=1" \
    "first-run ordering: picker-sweep shell cron must carry SCRIPT_PICKER_SWEEP_ENABLED=1"
  smoke_assert_not_contains "$cron_log" "--agent patch-dev" \
    "first-run ordering: picker-sweep cron must NOT dispatch to the <admin>-dev codex pair (unrunnable text-kind)"
}

# Source-level guard: the provisioning helper must refresh the parent's roster
# cache after a successful create (the #848 child-mutation pattern), or the
# picker-sweep registration that follows skips on a stale cache.
assert_helper_refreshes_roster_cache() {
  local helper="$SMOKE_REPO_ROOT/lib/bridge-init-codex-pair.sh"
  grep -q 'bridge_roster_cache_invalidate' "$helper" \
    || smoke_fail "lib/bridge-init-codex-pair.sh: must call bridge_roster_cache_invalidate after the child create"
  grep -q 'bridge_load_roster' "$helper" \
    || smoke_fail "lib/bridge-init-codex-pair.sh: must call bridge_load_roster after invalidating the cache"
}

# Source-level guard: the helper must be wired into bridge-init.sh AFTER
# host-profile resolution and BEFORE the picker-sweep cron registration —
# otherwise the picker-sweep cron (which targets `<admin>-dev`) registers
# before the pair exists and skips.
assert_init_wires_helper_before_picker_sweep() {
  local init="$SMOKE_REPO_ROOT/bridge-init.sh"
  local provision_line profile_line picker_line
  provision_line="$(grep -n 'bridge_init_provision_admin_codex_pair "' "$init" | head -n 1 | cut -d: -f1)"
  profile_line="$(grep -n 'host_profile_chosen="\$(bridge_host_profile_run' "$init" | head -n 1 | cut -d: -f1)"
  picker_line="$(grep -n 'bridge_init_register_default_picker_sweep "' "$init" | head -n 1 | cut -d: -f1)"
  [[ -n "$provision_line" ]] || smoke_fail "bridge-init.sh: codex-pair provisioning call site not found"
  [[ -n "$profile_line" ]] || smoke_fail "bridge-init.sh: host-profile resolution call site not found"
  [[ -n "$picker_line" ]] || smoke_fail "bridge-init.sh: picker-sweep registration call site not found"
  (( provision_line > profile_line )) \
    || smoke_fail "bridge-init.sh: codex-pair provisioning ($provision_line) must run AFTER host-profile resolution ($profile_line)"
  (( provision_line < picker_line )) \
    || smoke_fail "bridge-init.sh: codex-pair provisioning ($provision_line) must run BEFORE picker-sweep registration ($picker_line)"
}

# Source-level guard: the helper must use bridge_resolve_engine_cli for codex
# detection (non-fatal) and NOT bridge_init_require_command (which would abort
# init when codex is absent).
assert_helper_uses_nonfatal_codex_detection() {
  local helper="$SMOKE_REPO_ROOT/lib/bridge-init-codex-pair.sh"
  grep -q 'bridge_resolve_engine_cli codex' "$helper" \
    || smoke_fail "lib/bridge-init-codex-pair.sh: must detect codex via bridge_resolve_engine_cli"
  # Inspect CODE lines only — the rationale comment legitimately names
  # bridge_init_require_command to explain why it is NOT used.
  if grep -vE '^[[:space:]]*#' "$helper" | grep -q 'bridge_init_require_command'; then
    smoke_fail "lib/bridge-init-codex-pair.sh: must NOT use bridge_init_require_command (absent codex must be non-fatal)"
  fi
}

# Upgrade-time advisory contract (carried over from the prior smoke): the
# `bridge_upgrade_emit_admin_pair_advisory` helper still warns operators whose
# host carries the LEGACY auto-created literal-`admin`/`admin-dev` pair (the
# pre-#934 shape) to retire it. That advisory is orthogonal to the install-time
# server-only provisioning above and must keep working. Probe its no-action +
# match + idempotency paths by extracting just the function body (no full
# upgrader context, no heredoc-stdin).
assert_upgrade_advisory_helper_short_circuits() {
  local advisory_output
  advisory_output="$(BRIDGE_UPGRADE_PATH="$SMOKE_REPO_ROOT/bridge-upgrade.sh" \
    "$BRIDGE_BASH_BIN_FALLBACK" -c '
      set -euo pipefail
      tmp="$(mktemp)"
      trap "rm -f -- \"$tmp\"" EXIT
      awk "/^bridge_upgrade_emit_admin_pair_advisory\\(\\) {/, /^}/" \
        "$BRIDGE_UPGRADE_PATH" >"$tmp"
      # shellcheck disable=SC1090
      source "$tmp"

      target="$(mktemp -d)"
      mkdir -p "$target/agents/patch" "$target/state"
      out_patch="$(bridge_upgrade_emit_admin_pair_advisory "$target" "patch" "0" 2>&1)"
      [[ -z "$out_patch" ]] || { printf "patch-host produced advisory: %s\n" "$out_patch" >&2; exit 1; }

      mkdir -p "$target/agents/admin"
      out_no_dev="$(bridge_upgrade_emit_admin_pair_advisory "$target" "admin" "0" 2>&1)"
      [[ -z "$out_no_dev" ]] || { printf "no-dev host produced advisory: %s\n" "$out_no_dev" >&2; exit 1; }

      mkdir -p "$target/agents/admin-dev"
      out_match="$(bridge_upgrade_emit_admin_pair_advisory "$target" "admin" "0" 2>&1)"
      [[ "$out_match" == *"ADVISORY"* ]] \
        || { printf "match host missing advisory: %s\n" "$out_match" >&2; exit 1; }
      [[ -f "$target/state/admin-pair-advisory-acknowledged.ts" ]] \
        || { printf "advisory did not write acknowledged marker\n" >&2; exit 1; }

      out_repeat="$(bridge_upgrade_emit_admin_pair_advisory "$target" "admin" "0" 2>&1)"
      [[ -z "$out_repeat" ]] \
        || { printf "second call must be silent, got: %s\n" "$out_repeat" >&2; exit 1; }

      out_force="$(BRIDGE_ADMIN_PAIR_ADVISORY=force \
        bridge_upgrade_emit_admin_pair_advisory "$target" "admin" "0" 2>&1)"
      [[ "$out_force" == *"ADVISORY"* ]] \
        || { printf "force mode failed to re-emit: %s\n" "$out_force" >&2; exit 1; }

      rm -f "$target/state/admin-pair-advisory-acknowledged.ts"
      out_off="$(BRIDGE_ADMIN_PAIR_ADVISORY=0 \
        bridge_upgrade_emit_admin_pair_advisory "$target" "admin" "0" 2>&1)"
      [[ -z "$out_off" ]] \
        || { printf "hard-suppress mode emitted advisory: %s\n" "$out_off" >&2; exit 1; }

      out_dry="$(bridge_upgrade_emit_admin_pair_advisory "$target" "admin" "1" 2>&1)"
      [[ "$out_dry" == *"plan: advise"* ]] \
        || { printf "dry-run missing plan line: %s\n" "$out_dry" >&2; exit 1; }

      rm -rf -- "$target"
      printf "advisory-helper-OK\n"
    ')" || smoke_fail "upgrade advisory helper probe failed: $advisory_output"
  smoke_assert_contains "$advisory_output" "advisory-helper-OK" \
    "upgrade advisory helper short-circuit + match + idempotency cases must all pass"
}

main() {
  smoke_require_cmd grep
  smoke_require_cmd sed
  smoke_require_cmd awk
  : "${BRIDGE_BASH_BIN_FALLBACK:=bash}"
  export BRIDGE_BASH_BIN_FALLBACK

  smoke_setup_bridge_home "$SMOKE_NAME"

  smoke_run "server + codex present → pair auto-provisioned (engine=codex, always-on)" \
    assert_server_codex_present_provisions
  smoke_run "server + codex present + pair exists → idempotent (no duplicate create)" \
    assert_server_codex_present_idempotent
  smoke_run "dev profile → admin-only (no auto-create even with codex present)" \
    assert_dev_profile_admin_only
  smoke_run "server + codex absent → claude admin runs solo (no pair)" \
    assert_server_codex_absent_solo
  smoke_run "first-run ordering → pair created AND picker-sweep cron registered in one run" \
    assert_first_run_provisions_and_registers_cron
  smoke_run "bridge-init.sh wires helper after profile resolution, before picker-sweep" \
    assert_init_wires_helper_before_picker_sweep
  smoke_run "helper refreshes parent roster cache after the child create (#848 pattern)" \
    assert_helper_refreshes_roster_cache
  smoke_run "helper uses non-fatal codex detection (bridge_resolve_engine_cli)" \
    assert_helper_uses_nonfatal_codex_detection
  smoke_run "upgrade-time legacy-pair advisory still short-circuits + idempotent" \
    assert_upgrade_advisory_helper_short_circuits

  smoke_log "passed"
}

main "$@"
