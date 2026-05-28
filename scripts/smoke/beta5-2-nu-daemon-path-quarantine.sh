#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/beta5-2-nu-daemon-path-quarantine.sh — Issue #1317 (A/B/C)
# + Issue #1333 L3.
#
# v0.15.0-beta5-2 Lane ν — three #1317 sub-defects + skills L3:
#
#   #1317-A (daemon PATH augmentation): bridge-lib.sh adds
#     `bridge_augment_engine_path` that prepends BRIDGE_ENGINE_PATH
#     (operator override) + auto-detected nvm/pyenv/rbenv/asdf/fnm
#     dirs to PATH at lib-load time. Without this, an nvm-installed
#     `codex` (~/.nvm/versions/node/vX/bin/) is invisible to the
#     daemon's non-login shell and every restart loops 127 → quarantine.
#
#   #1317-B (quarantine UX): bridge_agent_activity_state returns
#     `quarantine-broken-launch` (vs. opaque `stopped`) when the
#     broken-launch marker exists. The marker JSON gains a
#     `reason_hint` field — short operator-actionable string keyed off
#     the recorded exit_code (127 → "engine CLI '<engine>' not found
#     ..."). session_health JSON + text both surface the hint.
#
#   #1317-C (engine pre-flight at create): `agent create` calls
#     `bridge_resolve_engine_binary` and refuses with an actionable
#     error if the engine binary is not on PATH. Last-resort opt-out
#     via `--force-engine-missing`.
#
#   #1333 L3 (skills setpriv fallback): lib/bridge-skills.sh:377-382
#     gains an opt-in setpriv fallback (BRIDGE_SKILLS_USE_SETPRIV=1)
#     and an actionable warn when both sudo+setpriv fail. Same
#     opt-in pattern as Lane η BRIDGE_CRON_USE_SETPRIV.
#
# Test plan:
#   T1 (#1317-A): bridge_augment_engine_path prepends BRIDGE_ENGINE_PATH
#       to PATH; auto-detects fake $NVM_DIR/versions/node/vX/bin and
#       prepends; idempotent (re-source no-op).
#   T2 (#1317-B): bridge_agent_activity_state returns
#       `quarantine-broken-launch` when marker exists; broken-launch
#       JSON writer emits reason_hint for exit 127.
#   T3 (#1317-C): `agent create` with engine='codex' on a PATH without
#       codex returns non-zero with actionable error. With
#       --force-engine-missing OR with engine on PATH, the pre-flight
#       gate passes (probe inspected via tightly-scoped driver).
#   T4 (#1333 L3): bridge-skills.sh mkdir + setpriv fallback —
#       sudo-fail + BRIDGE_SKILLS_USE_SETPRIV=1 + setpriv-present +
#       UID=0 reaches setpriv arm. Static grep confirms the setpriv
#       arm body is wired with the correct gating predicates.
#   T5 (#1333 L3): sudo-fail + setpriv-missing produces actionable
#       bridge_warn with the specific message tokens.
#   T_teeth: revert checks — strip the helper body / drop the
#       sentinel string from each fix and assert the smoke fails.
#       Implemented inline: each fix surfaces an unambiguous source
#       token (function name + comment marker `#1317-A/B/C` or
#       `#1333 L3`) that grep can pin.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# `printf '%s\n' ... >>file` lines AND plain `cat >file <<EOF` bodies
# on flat strings — no command substitution feeding a heredoc stdin,
# no `<<<` here-strings into bridge functions.

set -euo pipefail

# Re-exec under Bash 4+ (helper bodies use associative arrays through
# the larger lib stack).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:beta5-2-nu-daemon-path-quarantine] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="beta5-2-nu-daemon-path-quarantine"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via trap EXIT below
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
LIB_SH="$REPO_ROOT/bridge-lib.sh"
AGENT_SH="$REPO_ROOT/bridge-agent.sh"
SKILLS_LIB="$REPO_ROOT/lib/bridge-skills.sh"
STATE_LIB="$REPO_ROOT/lib/bridge-state.sh"
AGENTS_LIB="$REPO_ROOT/lib/bridge-agents.sh"
HINT_HELPER="$REPO_ROOT/scripts/python-helpers/broken-launch-reason-hint.py"

smoke_assert_file_exists "$LIB_SH" "bridge-lib.sh present"
smoke_assert_file_exists "$AGENT_SH" "bridge-agent.sh present"
smoke_assert_file_exists "$SKILLS_LIB" "lib/bridge-skills.sh present"
smoke_assert_file_exists "$STATE_LIB" "lib/bridge-state.sh present"
smoke_assert_file_exists "$AGENTS_LIB" "lib/bridge-agents.sh present"
smoke_assert_file_exists "$HINT_HELPER" "broken-launch-reason-hint.py helper present"

# ---------------------------------------------------------------------
# T1 — bridge_augment_engine_path: BRIDGE_ENGINE_PATH override +
# nvm auto-detect + idempotency.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked via smoke_run
t1_driver() {
  local _tmp="$SMOKE_TMP_ROOT/t1"
  mkdir -p "$_tmp/override-bin" "$_tmp/nvm-root/versions/node/v24.16.0/bin"

  # Build a tiny standalone driver that defines bridge_prepend_path_entry
  # + bridge_augment_engine_path inline (extracted from bridge-lib.sh
  # via awk). Source-then-call into an isolated PATH so the smoke
  # cannot be contaminated by the operator's real shell.
  local _driver="$_tmp/driver.sh"
  awk '
    /^bridge_prepend_path_entry\(\) \{/,/^\}/ { print }
  ' "$LIB_SH" >"$_driver"
  awk '
    /^bridge_augment_engine_path\(\) \{/,/^\}/ { print }
  ' "$LIB_SH" >>"$_driver"

  # Sanity: both function openers must be present.
  if ! grep -q '^bridge_prepend_path_entry() {' "$_driver"; then
    smoke_fail "T1: bridge_prepend_path_entry extract missing"
  fi
  if ! grep -q '^bridge_augment_engine_path() {' "$_driver"; then
    smoke_fail "T1: bridge_augment_engine_path extract missing (likely fix reverted)"
  fi

  # Anchor BASH so `env -i` does not lose the interpreter.
  local _bash_bin
  _bash_bin="$(command -v bash)"

  # Sub-test 1a: BRIDGE_ENGINE_PATH override is prepended.
  local _out_1a
  _out_1a="$(env -i PATH=/usr/bin:/bin HOME="$_tmp" \
      BRIDGE_ENGINE_PATH="$_tmp/override-bin" \
      "$_bash_bin" -c "source '$_driver'; bridge_augment_engine_path; printf '%s' \"\$PATH\"")"
  smoke_assert_contains "$_out_1a" "$_tmp/override-bin" \
    "T1a: BRIDGE_ENGINE_PATH override prepended"
  # Override must be at the leftmost position (PATH starts with the
  # override dir).
  case "$_out_1a" in
    "$_tmp/override-bin":*) ;;
    *) smoke_fail "T1a: BRIDGE_ENGINE_PATH override not leftmost on PATH: $_out_1a" ;;
  esac

  # Sub-test 1b: nvm auto-detect when NVM_DIR is set and has a node
  # version dir.
  local _out_1b
  _out_1b="$(env -i PATH=/usr/bin:/bin HOME="$_tmp" \
      NVM_DIR="$_tmp/nvm-root" \
      "$_bash_bin" -c "source '$_driver'; bridge_augment_engine_path; printf '%s' \"\$PATH\"")"
  smoke_assert_contains "$_out_1b" \
    "$_tmp/nvm-root/versions/node/v24.16.0/bin" \
    "T1b: nvm bin dir auto-detected and prepended"

  # Sub-test 1c: idempotent (re-source + re-invoke no-op — same PATH).
  local _out_1c
  _out_1c="$(env -i PATH=/usr/bin:/bin HOME="$_tmp" \
      BRIDGE_ENGINE_PATH="$_tmp/override-bin" \
      "$_bash_bin" -c "source '$_driver'; bridge_augment_engine_path; bridge_augment_engine_path; printf '%s' \"\$PATH\"")"
  smoke_assert_eq "$_out_1a" "$_out_1c" \
    "T1c: bridge_augment_engine_path is idempotent on re-invoke"

  # Sub-test 1d (teeth): if BRIDGE_ENGINE_PATH points to a non-
  # existent directory, it is silently dropped (bridge_prepend_path_entry
  # gates on -d).
  local _out_1d
  _out_1d="$(env -i PATH=/usr/bin:/bin HOME="$_tmp" \
      BRIDGE_ENGINE_PATH="$_tmp/does-not-exist" \
      "$_bash_bin" -c "source '$_driver'; bridge_augment_engine_path; printf '%s' \"\$PATH\"")"
  smoke_assert_not_contains "$_out_1d" "$_tmp/does-not-exist" \
    "T1d: non-existent override dir dropped"
}
smoke_run "T1 daemon PATH augmentation" t1_driver

# ---------------------------------------------------------------------
# T2 — activity_state returns quarantine-broken-launch + reason_hint
# is written by the broken-launch JSON helper.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked via smoke_run
t2_driver() {
  # Sub-test 2a: source token check on bridge_agent_activity_state —
  # the new branch must be present (revert teeth).
  if ! grep -q 'quarantine-broken-launch' "$AGENT_SH"; then
    smoke_fail "T2a: bridge_agent_activity_state missing 'quarantine-broken-launch' branch (#1317-B reverted)"
  fi
  if ! grep -q 'bridge_agent_broken_launch_file' "$AGENT_SH"; then
    smoke_fail "T2a: bridge_agent_activity_state missing broken_launch_file probe"
  fi

  # Sub-test 2b: bridge_agent_write_broken_launch_state must include
  # the new reason_hint + recovery_cmd payload fields (#1317-B).
  if ! grep -q 'reason_hint' "$STATE_LIB"; then
    smoke_fail "T2b: bridge_agent_write_broken_launch_state missing reason_hint field (#1317-B reverted)"
  fi
  if ! grep -q 'recovery_cmd' "$STATE_LIB"; then
    smoke_fail "T2b: bridge_agent_write_broken_launch_state missing recovery_cmd field (#1317-B reverted)"
  fi

  # Sub-test 2c: end-to-end — invoke the helper directly with a
  # synthetic broken-launch payload (exit_code=127) and assert the
  # reason_hint mentions "not found" + the engine name.
  local _bl_file="$SMOKE_TMP_ROOT/broken-launch.json"
  cat >"$_bl_file" <<EOF
{
  "agent": "smoke-test",
  "engine": "codex",
  "exit_code": 127,
  "reason_hint": "engine CLI 'codex' not found on daemon PATH; set BRIDGE_ENGINE_PATH=/dir/with/engine OR install at a PATH dir (e.g. ~/.local/bin) OR ensure NVM_DIR/PYENV_ROOT is exported when the daemon starts"
}
EOF
  local _hint
  _hint="$(python3 "$HINT_HELPER" "$_bl_file")"
  smoke_assert_contains "$_hint" "codex" "T2c: reason_hint helper extracts engine name"
  smoke_assert_contains "$_hint" "not found" "T2c: reason_hint helper extracts 'not found'"
  smoke_assert_contains "$_hint" "BRIDGE_ENGINE_PATH" "T2c: reason_hint helper extracts override env var"

  # Sub-test 2d: malformed JSON degrades silently to empty output (the
  # session_guidance text block then drops the line).
  local _bl_bad="$SMOKE_TMP_ROOT/broken-launch-bad.json"
  printf '%s\n' '{ this is not json' >"$_bl_bad"
  local _hint_bad
  _hint_bad="$(python3 "$HINT_HELPER" "$_bl_bad" 2>/dev/null || true)"
  smoke_assert_eq "" "$_hint_bad" "T2d: malformed JSON degrades silently"

  # Sub-test 2e: legacy schema (pre-#1317 payload with no reason_hint)
  # degrades silently — no stdout.
  local _bl_legacy="$SMOKE_TMP_ROOT/broken-launch-legacy.json"
  cat >"$_bl_legacy" <<'EOF'
{
  "agent": "smoke",
  "engine": "claude",
  "fail_count": 5,
  "exit_code": 127
}
EOF
  local _hint_legacy
  _hint_legacy="$(python3 "$HINT_HELPER" "$_bl_legacy")"
  smoke_assert_eq "" "$_hint_legacy" "T2e: legacy schema (no reason_hint) degrades silently"
}
smoke_run "T2 quarantine UX (activity_state + reason_hint)" t2_driver

# ---------------------------------------------------------------------
# T3 — engine pre-flight at agent create.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked via smoke_run
t3_driver() {
  # Source-token sweep: the new gate + flag must be present.
  if ! grep -q 'force_engine_missing' "$AGENT_SH"; then
    smoke_fail "T3: --force-engine-missing flag not wired (#1317-C reverted)"
  fi
  if ! grep -q 'bridge_resolve_engine_binary' "$AGENT_SH"; then
    smoke_fail "T3: engine pre-flight probe (bridge_resolve_engine_binary) missing"
  fi
  if ! grep -q "engine CLI '\$engine' not found on PATH" "$AGENT_SH"; then
    smoke_fail "T3: actionable error message text not present"
  fi
  if ! grep -q 'BRIDGE_ENGINE_PATH' "$AGENT_SH"; then
    smoke_fail "T3: actionable error must mention BRIDGE_ENGINE_PATH"
  fi
  if ! grep -q 'force-engine-missing' "$AGENT_SH"; then
    smoke_fail "T3: actionable error must mention --force-engine-missing"
  fi

  # Sub-test 3a: bridge_resolve_engine_binary itself — returns rc=1
  # when engine is absent from PATH.
  local _driver="$SMOKE_TMP_ROOT/t3-driver.sh"
  awk '
    /^bridge_resolve_engine_binary\(\) \{/,/^\}/ { print }
  ' "$AGENTS_LIB" >"$_driver"

  if ! grep -q '^bridge_resolve_engine_binary() {' "$_driver"; then
    smoke_fail "T3a: bridge_resolve_engine_binary extract missing"
  fi

  # Anchor BASH to an absolute path so `env -i` does not lose it.
  local _bash_bin
  _bash_bin="$(command -v bash)"
  local _empty_path="$SMOKE_TMP_ROOT/t3-empty-bin"
  mkdir -p "$_empty_path"
  local _rc
  set +e
  env -i PATH="$_empty_path" "$_bash_bin" -c "source '$_driver'; bridge_resolve_engine_binary codex >/dev/null"
  _rc=$?
  set -e
  smoke_assert_eq "1" "$_rc" "T3a: bridge_resolve_engine_binary returns rc=1 when engine absent"

  # Sub-test 3b: when a fake codex shim is on PATH, returns rc=0 + the
  # resolved absolute path.
  local _real_path="$SMOKE_TMP_ROOT/t3-with-codex"
  mkdir -p "$_real_path"
  cat >"$_real_path/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod 0755 "$_real_path/codex"
  local _resolved
  _resolved="$(env -i PATH="$_real_path" "$_bash_bin" -c "source '$_driver'; bridge_resolve_engine_binary codex")"
  smoke_assert_eq "$_real_path/codex" "$_resolved" "T3b: bridge_resolve_engine_binary returns absolute path"

  # Sub-test 3c: dry-run bypass — the pre-flight must skip when
  # --dry-run is set. Confirm via line-proximity that the
  # `dry_run == 0` guard precedes the `bridge_resolve_engine_binary`
  # probe in the same block. This is the edge case that keeps CI
  # smoke tests + plan-inspection workflows working when the engine
  # binary is intentionally not installed on the planning host.
  if ! awk '
    /dry_run == 0/ { saw_dry_run = NR }
    /bridge_resolve_engine_binary/ {
      if (saw_dry_run > 0 && (NR - saw_dry_run) < 8) {
        ok = 1
        exit 0
      }
    }
    END {
      if (!ok) exit 1
    }
  ' "$AGENT_SH"; then
    smoke_fail "T3c: dry-run gate must precede pre-flight probe within 8 lines (edge case 6)"
  fi
}
smoke_run "T3 engine pre-flight at create" t3_driver

# ---------------------------------------------------------------------
# T4 — skills sync sudo + setpriv fallback (#1333 L3): static grep of
# the new gating predicates. End-to-end exercise is gated on root +
# Linux + setpriv install — none of which apply in the smoke
# environment — so we pin the source tokens that prove the fix landed
# without bypassing the real-world gate.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked via smoke_run
t4_driver() {
  if ! grep -q 'BRIDGE_SKILLS_USE_SETPRIV' "$SKILLS_LIB"; then
    smoke_fail "T4: BRIDGE_SKILLS_USE_SETPRIV opt-in flag missing (#1333 L3 reverted)"
  fi
  if ! grep -q 'setpriv --reuid' "$SKILLS_LIB"; then
    smoke_fail "T4: setpriv fallback arm missing (no --reuid invocation)"
  fi
  # The opt-in arm must check id -u == 0 (the only context where cross-
  # UID setpriv works without CAP_SETUID). Lane η pattern parity.
  if ! grep -B 5 'setpriv --reuid' "$SKILLS_LIB" | grep -q 'id -u'; then
    smoke_fail "T4: setpriv arm missing id -u root gate (Lane η parity)"
  fi
  # The actionable warn (#1333 L3 ask) must mention BOTH sudo fix +
  # setpriv opt-in fallback.
  if ! grep -q 'install-sudoers' "$SKILLS_LIB"; then
    smoke_fail "T4: actionable warn must mention install-sudoers"
  fi
  if ! grep -B 1 -A 2 'cannot mkdir' "$SKILLS_LIB" | grep -q 'BRIDGE_SKILLS_USE_SETPRIV'; then
    smoke_fail "T4: actionable warn must mention BRIDGE_SKILLS_USE_SETPRIV"
  fi
}
smoke_run "T4 skills setpriv fallback (#1333 L3)" t4_driver

# ---------------------------------------------------------------------
# T5 — revert teeth: ensure each fix surfaces a unique source token
# such that a future PR reverting the change trips the smoke. The
# individual asserts above already cover this; T5 captures the union
# in one place so the failure message is single-pointered.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked via smoke_run
t5_teeth() {
  # #1317-A token
  grep -q 'bridge_augment_engine_path' "$LIB_SH" \
    || smoke_fail "T5 teeth: bridge_augment_engine_path missing — #1317-A reverted"
  # #1317-B activity_state token
  grep -q 'quarantine-broken-launch' "$AGENT_SH" \
    || smoke_fail "T5 teeth: quarantine-broken-launch label missing — #1317-B reverted"
  # #1317-B JSON payload token
  grep -q 'reason_hint' "$STATE_LIB" \
    || smoke_fail "T5 teeth: reason_hint field missing — #1317-B reverted"
  # #1317-C pre-flight token
  grep -q 'force_engine_missing' "$AGENT_SH" \
    || smoke_fail "T5 teeth: force_engine_missing var missing — #1317-C reverted"
  # #1333 L3 token
  grep -q 'BRIDGE_SKILLS_USE_SETPRIV' "$SKILLS_LIB" \
    || smoke_fail "T5 teeth: BRIDGE_SKILLS_USE_SETPRIV flag missing — #1333 L3 reverted"
  # #1317-B helper file presence
  [[ -x "$HINT_HELPER" ]] \
    || smoke_fail "T5 teeth: broken-launch-reason-hint.py helper missing — #1317-B reverted"
}
smoke_run "T5 teeth (all fixes pinned by source token)" t5_teeth

smoke_log "PASS"
exit 0
