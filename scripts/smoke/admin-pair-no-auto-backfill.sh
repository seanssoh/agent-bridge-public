#!/usr/bin/env bash
# scripts/smoke/admin-pair-no-auto-backfill.sh — Issue #4769 (reverts #517).
#
# Locks the post-revert contract that the `<admin>-dev` codex pair is NOT
# auto-registered by bridge-init.sh or bridge-upgrade.sh, that
# BRIDGE_ADMIN_AGENT_ID is only ever written by the explicit
# `agent-bridge setup admin <agent>` path, and that the removed feature's
# symbols (`bridge_ensure_admin_codex_pair`, `lib/bridge-admin-pair.sh`,
# the `inject-admin-pair-block` subcommand) have no remaining call sites.
#
# Cases:
#   C1: --admin patch resolves to admin=patch via `bridge-init.sh
#       --dry-run` (text dashboard); no `agent create <name>-dev` call
#       site exists in any init/upgrade source path that would register
#       a sibling. (--json is intentionally NOT used here — see the
#       runtime-probe note below.)
#   C2: --admin unset, no BRIDGE_ADMIN_AGENT_ID → init dry-run resolves
#       to literal `patch` (no longer `admin`).
#   C3: --admin manager (operator-named) resolves to admin=manager;
#       same no-sibling-create source guarantee as C1.
#   C4: grep-lint — removed bash + python symbols are absent from
#       tracked source. Catches re-introduction of
#       `bridge_ensure_admin_codex_pair`, `bridge_admin_pair_*`,
#       `lib/bridge-admin-pair.sh`, `render_admin_pair_block`,
#       `cmd_inject_admin_pair_block`, `inject-admin-pair-block`
#       subcommand, `MANAGED_PAIR_*` markers, plus the
#       bridge-init.sh fallback-default literal `:-patch` invariant.
#   C5: The post-upgrade advisory helper short-circuits when the host
#       does not match the auto-created admin/admin-dev pattern, fires
#       once on a matching host, writes an idempotency marker so the
#       second call is silent, honors BRIDGE_ADMIN_PAIR_ADVISORY=force
#       (re-emit) and =0 (hard-suppress), and emits a plan line in
#       --dry-run.
#
# Runtime probes for C1-C3 use `bridge-init.sh --dry-run` (text
# dashboard, NOT --json) rather than a full non-dry-run init for three
# reasons:
#   1. The dry-run path exercises the same argument resolution and
#      fallback logic that a real init takes, prints the resolved
#      admin id on the `admin_agent:` line, and is mutation-free.
#   2. A non-dry-run init on this repo's macOS host hits the Bash
#      5.3.9 `heredoc_write` deadlock (footgun #11) in the
#      `bridge-agent.sh create` chain, AND bridge-init.sh's
#      host-profile saver writes to $HOME/.agent-bridge regardless of
#      BRIDGE_HOME (a pre-existing bridge-init.sh bug, out of scope
#      for #4769). The dry-run path avoids both.
#   3. `--json` ALSO trips footgun #11 in `bridge_init_emit_json`
#      (bridge-init.sh:57 — `python3 - … <<'PY'` heredoc-stdin). The
#      text dashboard uses `cat <<EOF` and is deadlock-safe. The
#      text envelope has the same `admin_agent: <value>` field we
#      need to assert.
#
# The combination of "dry-run resolves admin id correctly" + "no
# `agent create <name>-dev` call site exists anywhere in init/upgrade"
# + "the C4 grep-lint catches reintroduction of the removed helpers"
# fully encodes the no-auto-backfill contract.

set -euo pipefail

SMOKE_NAME="admin-pair-no-auto-backfill"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

assert_shell_symbols_removed() {
  local hits
  # Search the tracked shell + python source surface for any remaining
  # call to the deleted helper or source of the deleted module. This
  # smoke must self-exclude (it names the removed symbols on purpose).
  if hits="$(grep -rn \
        --exclude-dir=state \
        --exclude=admin-pair-no-auto-backfill.sh \
        -e 'bridge_ensure_admin_codex_pair' \
        -e 'bridge_admin_pair_name' \
        -e 'bridge_admin_pair_managed_block' \
        -e 'lib/bridge-admin-pair\.sh' \
        "$SMOKE_REPO_ROOT/lib" \
        "$SMOKE_REPO_ROOT/scripts" \
        "$SMOKE_REPO_ROOT"/bridge-*.sh \
        "$SMOKE_REPO_ROOT"/bridge-*.py 2>/dev/null)"; then
    smoke_fail $'removed bash symbols still referenced:\n'"$hits"
  fi
}

assert_python_symbols_removed() {
  local hits
  if hits="$(grep -rn \
        --exclude-dir=state \
        --exclude=admin-pair-no-auto-backfill.sh \
        -e 'render_admin_pair_block' \
        -e 'cmd_inject_admin_pair_block' \
        -e 'inject-admin-pair-block' \
        -e 'MANAGED_PAIR_START' \
        -e 'MANAGED_PAIR_END' \
        "$SMOKE_REPO_ROOT/lib" \
        "$SMOKE_REPO_ROOT/scripts" \
        "$SMOKE_REPO_ROOT"/bridge-*.sh \
        "$SMOKE_REPO_ROOT"/bridge-*.py 2>/dev/null)"; then
    smoke_fail $'removed python symbols still referenced:\n'"$hits"
  fi
}

assert_init_fallback_is_patch() {
  local line
  line="$(grep -n '^admin_agent="\${BRIDGE_ADMIN_AGENT_ID' "$SMOKE_REPO_ROOT/bridge-init.sh" | head -n 1)"
  [[ -n "$line" ]] || smoke_fail "bridge-init.sh admin_agent fallback line not found"
  smoke_assert_contains "$line" ':-patch' \
    "bridge-init.sh admin_agent default fallback must resolve to patch (got: $line)"
  smoke_assert_not_contains "$line" ':-admin}' \
    "bridge-init.sh admin_agent fallback must NOT resolve to literal admin"
}

assert_advisory_helper_short_circuits() {
  # Load just the helper and probe its no-action paths. The function is
  # defined in bridge-upgrade.sh but is read-only and does not require
  # the rest of the upgrader to be sourced.
  local advisory_output
  advisory_output="$(BRIDGE_UPGRADE_PATH="$SMOKE_REPO_ROOT/bridge-upgrade.sh" \
    "$BRIDGE_BASH_BIN_FALLBACK" -c '
      set -euo pipefail
      # Extract the function body to a temp file so we do not run the
      # rest of bridge-upgrade.sh (which expects a full target-root +
      # CLI arg context). Heredoc-stdin is avoided (footgun #11).
      tmp="$(mktemp)"
      trap "rm -f -- \"$tmp\"" EXIT
      awk "/^bridge_upgrade_emit_admin_pair_advisory\\(\\) {/, /^}/" \
        "$BRIDGE_UPGRADE_PATH" >"$tmp"
      # shellcheck disable=SC1090
      source "$tmp"

      target="$(mktemp -d)"
      mkdir -p "$target/agents/patch" "$target/state"
      # admin_id != admin → short-circuit BEFORE filesystem check, so
      # the patch-only directory must produce zero advisory output.
      out_patch="$(bridge_upgrade_emit_admin_pair_advisory "$target" "patch" "0" 2>&1)"
      [[ -z "$out_patch" ]] || { printf "patch-host produced advisory: %s\n" "$out_patch" >&2; exit 1; }

      # admin_id=admin but admin-dev/ absent → short-circuit
      mkdir -p "$target/agents/admin"
      out_no_dev="$(bridge_upgrade_emit_admin_pair_advisory "$target" "admin" "0" 2>&1)"
      [[ -z "$out_no_dev" ]] || { printf "no-dev host produced advisory: %s\n" "$out_no_dev" >&2; exit 1; }

      # admin_id=admin AND admin-dev/ present → advisory fires (first time only)
      mkdir -p "$target/agents/admin-dev"
      out_match="$(bridge_upgrade_emit_admin_pair_advisory "$target" "admin" "0" 2>&1)"
      [[ "$out_match" == *"ADVISORY"* ]] \
        || { printf "match host missing advisory: %s\n" "$out_match" >&2; exit 1; }
      [[ "$out_match" == *"retire admin-dev"* ]] \
        || { printf "match host missing retire recipe: %s\n" "$out_match" >&2; exit 1; }
      [[ "$out_match" == *"setup admin patch"* ]] \
        || { printf "match host missing setup recipe: %s\n" "$out_match" >&2; exit 1; }
      [[ "$out_match" == *"will not repeat"* ]] \
        || { printf "match host missing idempotency note: %s\n" "$out_match" >&2; exit 1; }
      [[ -f "$target/state/admin-pair-advisory-acknowledged.ts" ]] \
        || { printf "advisory did not write acknowledged marker\n" >&2; exit 1; }

      # Second call with marker present → silent (idempotency)
      out_repeat="$(bridge_upgrade_emit_admin_pair_advisory "$target" "admin" "0" 2>&1)"
      [[ -z "$out_repeat" ]] \
        || { printf "second call must be silent, got: %s\n" "$out_repeat" >&2; exit 1; }

      # BRIDGE_ADMIN_PAIR_ADVISORY=force re-emits even when marker exists
      out_force="$(BRIDGE_ADMIN_PAIR_ADVISORY=force \
        bridge_upgrade_emit_admin_pair_advisory "$target" "admin" "0" 2>&1)"
      [[ "$out_force" == *"ADVISORY"* ]] \
        || { printf "force mode failed to re-emit: %s\n" "$out_force" >&2; exit 1; }

      # BRIDGE_ADMIN_PAIR_ADVISORY=0 hard-suppresses
      rm -f "$target/state/admin-pair-advisory-acknowledged.ts"
      out_off="$(BRIDGE_ADMIN_PAIR_ADVISORY=0 \
        bridge_upgrade_emit_admin_pair_advisory "$target" "admin" "0" 2>&1)"
      [[ -z "$out_off" ]] \
        || { printf "hard-suppress mode emitted advisory: %s\n" "$out_off" >&2; exit 1; }

      # dry_run=1 prints a plan line, no probe
      out_dry="$(bridge_upgrade_emit_admin_pair_advisory "$target" "admin" "1" 2>&1)"
      [[ "$out_dry" == *"plan: advise"* ]] \
        || { printf "dry-run missing plan line: %s\n" "$out_dry" >&2; exit 1; }

      rm -rf -- "$target"
      printf "advisory-helper-OK\n"
    ')" || smoke_fail "advisory helper probe failed: $advisory_output"
  smoke_assert_contains "$advisory_output" "advisory-helper-OK" \
    "advisory helper short-circuit + match + idempotency cases must all pass"
}

# Invoke bridge-init.sh in --dry-run --json mode against an isolated
# BRIDGE_HOME. Returns the JSON envelope on stdout (one envelope per
# line of legitimate output). The dry-run path:
#   - Is mutation-free (no agents/, no roster writes, no host-profile
#     scribbling).
#   - Resolves --admin / BRIDGE_ADMIN_AGENT_ID / fallback exactly the
#     same way a non-dry-run init does.
#   - Exits with the resolved configuration in JSON.
admin_pair_runtime_dry_run_text() {
  local label="$1"
  shift
  local bridge_home
  bridge_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-bridge-${label}.XXXXXX")/.agent-bridge"
  mkdir -p "$bridge_home"
  local out=""
  local budget="${BRIDGE_SMOKE_INIT_TIMEOUT:-45}"
  # bridge-init.sh accepts only `claude` or `codex` as --engine values.
  # `codex` is on PATH in the supported smoke-test environments (the
  # operator's macOS dev box, the Ubuntu 24.04 CI host, the Linux
  # production server). The dry-run path never invokes the engine
  # binary; it just gates with `command -v <engine>`.
  #
  # Text output (NOT --json) is used here because bridge-init.sh's
  # `bridge_init_emit_json` helper (line 57) uses `python3 - … <<'PY'`
  # heredoc-stdin which trips the Bash 5.3.9 `heredoc_write` deadlock
  # (footgun #11) on some hosts. The text path uses `cat <<EOF` for
  # the dashboard render and is deadlock-safe. The text envelope has
  # the same admin id we need to assert ("admin_agent: <value>").
  #
  # The `timeout` wrapper bounds the call so a host that nevertheless
  # hits a different heredoc deadlock degrades to "no output" rather
  # than blocking the smoke indefinitely.
  # DEBUG (temp, not for merge): capture stderr to a per-call file so the CI
  # log shows why bridge-init.sh exits early on Linux when admin-pair smoke
  # fails with '<missing-from-dry-run-output>'. Stdout still flows through
  # the function so the parser is unchanged; stderr lands in a tmp file
  # whose tail we echo to stderr post-run for CI capture.
  local stderr_capture
  stderr_capture="$(mktemp "${TMPDIR:-/tmp}/bridge-init-stderr-${label}.XXXXXX")"
  out="$(timeout --kill-after=5s "${budget}s" \
        env -u BRIDGE_ADMIN_AGENT_ID \
            BRIDGE_HOME="$bridge_home" \
            bash -x "$SMOKE_REPO_ROOT/bridge-init.sh" \
              --skip-channel-setup --skip-validate --skip-send-test \
              --dry-run \
              --engine codex \
              "$@" 2>"$stderr_capture")" || true
  local rc=$?
  printf '\n=== DEBUG: bridge-init.sh stderr trace (label=%s, rc=%s) ===\n' "$label" "$rc" >&2
  tail -n 80 "$stderr_capture" >&2 || true
  printf '=== END DEBUG (label=%s) ===\n\n' "$label" >&2
  rm -f "$stderr_capture"
  rm -rf -- "$(dirname "$bridge_home")"
  printf '%s' "$out"
}

# Extract the resolved admin agent id from the text dry-run dashboard.
admin_pair_runtime_admin_field() {
  local envelope="$1"
  local v
  v="$(printf '%s\n' "$envelope" | grep -E '^admin_agent: ' | head -n 1 | sed 's/^admin_agent: //')"
  if [[ -z "$v" ]]; then
    printf '<missing-from-dry-run-output>'
  else
    printf '%s' "$v"
  fi
}

# Source-level guarantee: there must be no `agent create <name>-dev`
# call site in any tracked init/upgrade/lib path. The C4 grep-lint
# above catches reintroduction of the removed helper functions; this
# guard additionally catches any new code path that hand-rolls a
# sibling-dev registration call.
admin_pair_runtime_assert_no_sibling_create_calls() {
  local hits=""
  # Match `agent create <name>-dev` only in CODE positions (not in
  # `# ... ` line comments or inside docstrings). Three shapes:
  #   - literal: `agent create patch-dev`
  #   - variable: `agent create "$admin"-dev`
  #   - parameter expansion: `agent create "${admin}-dev"`
  # Pre-filter via grep -v '^[[:space:]]*#' to strip comment lines —
  # the function-body comments in lib/bridge-isolation-v2-migrate.sh
  # legitimately describe the recipe operators run by hand and must
  # not trigger this guard.
  local files=(
    "$SMOKE_REPO_ROOT/bridge-init.sh"
    "$SMOKE_REPO_ROOT/bridge-upgrade.sh"
    "$SMOKE_REPO_ROOT"/lib/bridge-*.sh
  )
  if hits="$(grep -nE \
        'agent create [^"#]*-dev|agent create "?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?-dev' \
        "${files[@]}" 2>/dev/null \
        | grep -vE ':[[:space:]]*#')"; then
    [[ -n "$hits" ]] && smoke_fail $'unexpected `agent create <name>-dev` call site (issue #4769 contract):\n'"$hits"
  fi
}

assert_c1_patch_named_init_no_backfill() {
  local envelope admin
  envelope="$(admin_pair_runtime_dry_run_text c1 --admin patch)"
  admin="$(admin_pair_runtime_admin_field "$envelope")"
  smoke_assert_eq "patch" "$admin" \
    "C1: --admin patch resolves to admin=patch in init dry-run (got: $admin)"
  admin_pair_runtime_assert_no_sibling_create_calls
}

assert_c2_unset_admin_id_falls_back_to_patch() {
  local envelope admin
  # No --admin flag; BRIDGE_ADMIN_AGENT_ID unset by env -u in helper.
  envelope="$(admin_pair_runtime_dry_run_text c2)"
  admin="$(admin_pair_runtime_admin_field "$envelope")"
  smoke_assert_eq "patch" "$admin" \
    "C2: unset admin id falls back to literal 'patch' in init dry-run (got: $admin)"
}

assert_c3_operator_named_admin_no_sibling() {
  local envelope admin
  envelope="$(admin_pair_runtime_dry_run_text c3 --admin manager)"
  admin="$(admin_pair_runtime_admin_field "$envelope")"
  smoke_assert_eq "manager" "$admin" \
    "C3: --admin manager resolves to admin=manager in init dry-run (got: $admin)"
  admin_pair_runtime_assert_no_sibling_create_calls
}

main() {
  smoke_require_cmd grep
  smoke_require_cmd python3
  : "${BRIDGE_BASH_BIN_FALLBACK:=bash}"
  export BRIDGE_BASH_BIN_FALLBACK

  smoke_setup_bridge_home "$SMOKE_NAME"

  # C4 first (cheap grep-lint runs in <100ms; catches re-introduction
  # before the runtime cases burn temp dirs).
  smoke_run "C4a: removed bash symbols absent from tracked source" assert_shell_symbols_removed
  smoke_run "C4b: removed python symbols absent from tracked source" assert_python_symbols_removed
  smoke_run "C4c: bridge-init.sh fallback default resolves to patch" assert_init_fallback_is_patch

  # C1-C3 runtime probes via bridge-init.sh --dry-run (text dashboard,
  # NOT --json; --json trips bridge_init_emit_json footgun #11).
  smoke_run "C1: --admin patch dry-run resolves admin=patch + no sibling-create call site" \
    assert_c1_patch_named_init_no_backfill
  smoke_run "C2: unset admin id dry-run falls back to 'patch' (not 'admin')" \
    assert_c2_unset_admin_id_falls_back_to_patch
  smoke_run "C3: --admin manager dry-run resolves admin=manager + no sibling-create call site" \
    assert_c3_operator_named_admin_no_sibling

  # C5: post-upgrade advisory helper contract + idempotency.
  smoke_run "C5: post-upgrade advisory helper short-circuits + idempotency marker" \
    assert_advisory_helper_short_circuits
  smoke_log "passed"
}

main "$@"
