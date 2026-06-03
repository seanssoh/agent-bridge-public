#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/codex-permission-profiles.sh — #8945 Track C permissions smoke.
#
# Pins the agent-scoped Codex permission-profile provisioning contract. The
# profiles ship as REAL Codex config-profile files: `codex -p, --profile <name>`
# layers $CODEX_HOME/<name>.config.toml on top of the base user config (verified
# against codex-cli 0.135.0). So the file Codex actually loads is
# `bridge-<role>.config.toml` — NOT a standalone `permissions.toml` (which Codex
# ignores). This smoke asserts the real profile files are installed:
#
#   T1: bridge_ensure_codex_agent_slash_commands deploys the three role profile
#       files — bridge-reviewer.config.toml, bridge-worker.config.toml,
#       bridge-admin.config.toml — into <scaffold_target>/.codex/ each carrying
#       the agent-bridge:managed marker.
#   T2: each profile file is valid, parseable TOML and carries a recognized
#       `sandbox_mode` (read-only for reviewer, workspace-write for worker/admin)
#       — i.e. real config Codex layers, not an inert `[permissions.*]` table.
#       The driver also asserts NO inert `permissions.toml` is shipped.
#   T3: per-agent <agent-home> / <bridge-home> substitution applied; the raw
#       tokens are gone; idempotent re-run; an agent's own <role>.config.toml
#       (no marker) is never clobbered.
#   T4 (CRITICAL): the controller/operator global ~/.codex ($HOME/.codex) is
#       neither created nor mutated (proven via a pinned clean FAKE_HOME).
#
# Footgun #11 / lint-heredoc-ban H3: driver emitted via printf-to-file; loops
# read from temp files (no heredoc-stdin, no process substitution).

set -uo pipefail

SMOKE_NAME="codex-permission-profiles"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# --- T4 controller ~/.codex isolation ---
# We pin a clean, quiet HOME the test fully owns (the operator's real ~/.codex
# is live and churns concurrently, which would false-fail a snapshot). Proving
# this controlled $HOME/.codex is never created is a faithful proof of the
# agent-scoped-not-controller contract — see codex-slash-commands.sh for the
# full rationale.
FAKE_HOME="$SMOKE_TMP_ROOT/fake-controller-home"
mkdir -p "$FAKE_HOME"
CONTROLLER_CODEX="$FAKE_HOME/.codex"
SNAP_BEFORE="$SMOKE_TMP_ROOT/controller-codex-before.txt"
snapshot_controller_codex() {
  local out="$1"
  : >"$out"
  if [[ -e "$CONTROLLER_CODEX" ]]; then
    printf 'EXISTS\n' >>"$out"
    find "$CONTROLLER_CODEX" -print0 2>/dev/null \
      | sort -z \
      | while IFS= read -r -d '' p; do
          local m
          m="$(stat -c '%Y' "$p" 2>/dev/null || stat -f '%m' "$p" 2>/dev/null || printf '?')"
          printf '%s\t%s\n' "$m" "$p" >>"$out"
        done
  else
    printf 'ABSENT\n' >>"$out"
  fi
}
snapshot_controller_codex "$SNAP_BEFORE"

# --- driver ---
DRIVER_DIR="$SMOKE_TMP_ROOT/driver"
mkdir -p "$DRIVER_DIR"
DRIVER="$DRIVER_DIR/driver.sh"

# Standalone TOML parser helper (file-as-argv; no heredoc-stdin).
# Usage: toml-parse.py <profile.config.toml> <expected_sandbox_mode>
# Exit codes:
#   0 = parsed OK and top-level sandbox_mode == expected
#   3 = no tomllib/tomli available (caller treats as skip)
#   4 = parse error, missing sandbox_mode, or wrong sandbox_mode
TOML_HELPER="$DRIVER_DIR/toml-parse.py"
write_toml_helper() {
  local out="$1"
  : >"$out"
  local line
  for line in \
    'import sys' \
    'try:' \
    '    import tomllib as t' \
    'except Exception:' \
    '    try:' \
    '        import tomli as t' \
    '    except Exception:' \
    '        sys.exit(3)' \
    'try:' \
    '    with open(sys.argv[1], "rb") as fh:' \
    '        data = t.load(fh)' \
    'except Exception:' \
    '    sys.exit(4)' \
    'expected = sys.argv[2] if len(sys.argv) > 2 else None' \
    'mode = data.get("sandbox_mode")' \
    'if mode is None:' \
    '    sys.exit(4)' \
    'if expected is not None and mode != expected:' \
    '    sys.exit(4)' \
    'sys.exit(0)'
  do
    printf '%s\n' "$line" >>"$out"
  done
}
write_toml_helper "$TOML_HELPER"

write_driver() {
  local out="$1"
  : >"$out"
  local line
  for line in \
    '#!/usr/bin/env bash' \
    'set -uo pipefail' \
    'cd "$REPO_ROOT"' \
    'SCRIPT_DIR="$REPO_ROOT"' \
    'source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1' \
    'declare -F bridge_ensure_codex_agent_slash_commands >/dev/null 2>&1 || { echo "DRIVER_FAIL: bridge_ensure_codex_agent_slash_commands not loaded"; exit 91; }' \
    'declare -F bridge_codex_managed_asset_marker >/dev/null 2>&1 || { echo "DRIVER_FAIL: bridge_codex_managed_asset_marker not loaded"; exit 92; }' \
    'AGENT="probe-codex"' \
    'AGENT_HOME="$BRIDGE_AGENT_ROOT_V2/$AGENT/home"' \
    'mkdir -p "$AGENT_HOME"' \
    'CODEX_DIR="$AGENT_HOME/.codex"' \
    'MARKER="$(bridge_codex_managed_asset_marker)"' \
    '# ---- T1: deploy the three REAL <role>.config.toml profile files ----' \
    'bridge_ensure_codex_agent_slash_commands "$AGENT" "$AGENT_HOME" 2>/dev/null || true' \
    '# expected sandbox_mode per role: reviewer=read-only, worker/admin=workspace-write.' \
    'for role in bridge-reviewer bridge-worker bridge-admin; do' \
    '  f="$CODEX_DIR/$role.config.toml"' \
    '  if [[ -f "$f" ]]; then echo "T1_PROFILE_${role}: present"; else echo "T1_PROFILE_${role}: missing"; fi' \
    '  if [[ -f "$f" ]] && grep -qF "$MARKER" "$f" 2>/dev/null; then echo "T1_MARKER_${role}: yes"; else echo "T1_MARKER_${role}: no"; fi' \
    'done' \
    '# T1: there must be NO inert permissions.toml shipped (Codex would ignore it).' \
    'if [[ -e "$CODEX_DIR/permissions.toml" ]]; then echo "T1_NO_INERT_PERMS: present"; else echo "T1_NO_INERT_PERMS: absent"; fi' \
    '# ---- T2: each profile is valid TOML with the right sandbox_mode ----' \
    '# The parser helper is a standalone file invoked file-as-argv (no heredoc-' \
    '# stdin, per footgun #11 / lint-heredoc-ban H3). exit 0=ok, 3=no toml lib' \
    '# (skip), 4=parse/sandbox_mode failure.' \
    'for spec in "bridge-reviewer read-only" "bridge-worker workspace-write" "bridge-admin workspace-write"; do' \
    '  role="${spec%% *}"; want="${spec##* }"' \
    '  f="$CODEX_DIR/$role.config.toml"' \
    '  TOML_OK="skip"' \
    '  if command -v python3 >/dev/null 2>&1 && [[ -f "$TOML_HELPER" && -f "$f" ]]; then' \
    '    python3 "$TOML_HELPER" "$f" "$want" >/dev/null 2>&1; trc=$?' \
    '    if [[ $trc -eq 0 ]]; then TOML_OK="yes"; elif [[ $trc -eq 3 ]]; then TOML_OK="skip"; else TOML_OK="no"; fi' \
    '  fi' \
    '  echo "T2_TOML_${role}: $TOML_OK"' \
    '  # grep-level sandbox_mode assertion (always enforced, even when parse skips).' \
    '  if [[ -f "$f" ]] && grep -qE "^sandbox_mode = \"$want\"" "$f" 2>/dev/null; then echo "T2_MODE_${role}: yes"; else echo "T2_MODE_${role}: no"; fi' \
    'done' \
    '# ---- T3: per-agent substitution + idempotent + no-clobber ----' \
    'WORKER="$CODEX_DIR/bridge-worker.config.toml"' \
    'ADMIN="$CODEX_DIR/bridge-admin.config.toml"' \
    '# worker has <agent-home>; admin has <agent-home> AND <bridge-home>.' \
    'if [[ -f "$WORKER" ]] && grep -qF "$AGENT_HOME" "$WORKER" 2>/dev/null; then echo "T3_SUBST_HOME: yes"; else echo "T3_SUBST_HOME: no"; fi' \
    'if grep -qF "<agent-home>" "$CODEX_DIR"/bridge-*.config.toml 2>/dev/null; then echo "T3_RAW_AGENT_TOKEN: yes"; else echo "T3_RAW_AGENT_TOKEN: no"; fi' \
    'if grep -qF "<bridge-home>" "$CODEX_DIR"/bridge-*.config.toml 2>/dev/null; then echo "T3_RAW_BRIDGE_TOKEN: yes"; else echo "T3_RAW_BRIDGE_TOKEN: no"; fi' \
    'bridge_ensure_codex_agent_slash_commands "$AGENT" "$AGENT_HOME" 2>/dev/null; RC2=$?' \
    'echo "T3_RERUN_RC: $RC2"' \
    '# Replace a managed profile with unmarked agent content; the installer must leave it.' \
    'printf "%s\n" "# my own profile, no marker" > "$WORKER"' \
    'OWN_SHA_BEFORE="$(cksum "$WORKER" 2>/dev/null | awk "{print \$1}")"' \
    'bridge_ensure_codex_agent_slash_commands "$AGENT" "$AGENT_HOME" 2>/dev/null || true' \
    'OWN_SHA_AFTER="$(cksum "$WORKER" 2>/dev/null | awk "{print \$1}")"' \
    'if [[ "$OWN_SHA_BEFORE" == "$OWN_SHA_AFTER" ]]; then echo "T3_OWN_PRESERVED: yes"; else echo "T3_OWN_PRESERVED: no"; fi' \
    '# ---- T4 teeth: agent-scoped, not under controller HOME ----' \
    'case "$CODEX_DIR" in' \
    '  "$HOME/.codex"|"$HOME/.codex"/*) echo "T4_SCOPED_UNDER_CONTROLLER: yes" ;;' \
    '  *) echo "T4_SCOPED_UNDER_CONTROLLER: no" ;;' \
    'esac' \
    'echo "T4_CODEX_DIR: $CODEX_DIR"'
  do
    printf '%s\n' "$line" >>"$out"
  done
  chmod +x "$out"
}

extract_line() {
  local out="$1"
  local key="$2"
  printf '%s\n' "$out" | sed -n "s/^$key: //p" | head -n 1
}

write_driver "$DRIVER"

smoke_log "T1-T4: agent-scoped Codex permission profiles (controller ~/.codex untouched)"

OUT="$(
  REPO_ROOT="$REPO_ROOT" \
  DRIVER_TMP_DIR="$DRIVER_DIR" \
  TOML_HELPER="$TOML_HELPER" \
  HOME="$FAKE_HOME" \
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
  BRIDGE_SHARED_DIR="$BRIDGE_SHARED_DIR" \
  BRIDGE_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
  BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
  BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
  BRIDGE_AGENT_HOME_ROOT="$BRIDGE_AGENT_HOME_ROOT" \
  BRIDGE_LAYOUT="v2" \
  BRIDGE_DATA_ROOT="$BRIDGE_DATA_ROOT" \
  BRIDGE_SHARED_ROOT="$BRIDGE_SHARED_ROOT" \
  BRIDGE_AGENT_ROOT_V2="$BRIDGE_AGENT_ROOT_V2" \
  BRIDGE_CONTROLLER_STATE_ROOT="$BRIDGE_CONTROLLER_STATE_ROOT" \
  BRIDGE_RUNTIME_ROOT="$BRIDGE_RUNTIME_ROOT" \
  BRIDGE_HOOKS_DIR="$BRIDGE_HOOKS_DIR" \
  BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
  "$BRIDGE_BASH" "$DRIVER" 2>&1
)"
RC=$?

if [[ $RC -ne 0 ]]; then
  smoke_fail "driver exited rc=$RC. output:
$OUT"
fi

# --- T1 assertions: the three real <role>.config.toml files land, marked ---
for role in bridge-reviewer bridge-worker bridge-admin; do
  smoke_assert_eq "present" "$(extract_line "$OUT" "T1_PROFILE_${role}")" \
    "T1: $role.config.toml deployed into agent-scoped .codex/ (the file 'codex -p $role' loads)"
  smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_MARKER_${role}")" \
    "T1: $role.config.toml carries the agent-bridge:managed marker"
done
smoke_assert_eq "absent" "$(extract_line "$OUT" "T1_NO_INERT_PERMS")" \
  "T1: NO inert permissions.toml shipped (Codex never reads it; -p loads <name>.config.toml)"

# --- T2 assertions: each profile is valid TOML with the right sandbox_mode ---
for spec in "bridge-reviewer read-only" "bridge-worker workspace-write" "bridge-admin workspace-write"; do
  role="${spec%% *}"; want="${spec##* }"
  TOML_PARSE="$(extract_line "$OUT" "T2_TOML_${role}")"
  case "$TOML_PARSE" in
    yes) smoke_log "T2: $role.config.toml is valid TOML with sandbox_mode='$want'" ;;
    skip) smoke_log "T2: $role.config.toml TOML parse skipped (no tomllib/tomli); grep-level sandbox_mode check still enforced" ;;
    *) smoke_fail "T2: $role.config.toml failed TOML parse or sandbox_mode != '$want' (got '$TOML_PARSE')" ;;
  esac
  smoke_assert_eq "yes" "$(extract_line "$OUT" "T2_MODE_${role}")" \
    "T2: $role.config.toml declares sandbox_mode = \"$want\""
done

# --- T3 assertions ---
smoke_assert_eq "yes" "$(extract_line "$OUT" "T3_SUBST_HOME")" \
  "T3: <agent-home> substituted with the resolved agent home path"
smoke_assert_eq "no" "$(extract_line "$OUT" "T3_RAW_AGENT_TOKEN")" \
  "T3: the raw <agent-home> token was substituted away in all profiles"
smoke_assert_eq "no" "$(extract_line "$OUT" "T3_RAW_BRIDGE_TOKEN")" \
  "T3: the raw <bridge-home> token was substituted away in all profiles"
smoke_assert_eq "0" "$(extract_line "$OUT" "T3_RERUN_RC")" \
  "T3: re-running the installer exits 0 (idempotent)"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T3_OWN_PRESERVED")" \
  "T3: an agent's own (unmarked) <role>.config.toml is never clobbered"

# --- T4 assertions ---
smoke_assert_eq "no" "$(extract_line "$OUT" "T4_SCOPED_UNDER_CONTROLLER")" \
  "T4: the installed .codex profile tree is NOT under the controller \$HOME/.codex"

SNAP_AFTER="$SMOKE_TMP_ROOT/controller-codex-after.txt"
snapshot_controller_codex "$SNAP_AFTER"
if ! diff -q "$SNAP_BEFORE" "$SNAP_AFTER" >/dev/null 2>&1; then
  smoke_fail "T4 CRITICAL: controller \$HOME/.codex changed during the agent scaffold!
--- before ---
$(cat "$SNAP_BEFORE")
--- after ---
$(cat "$SNAP_AFTER")"
fi
smoke_log "T4 CRITICAL: controller \$HOME/.codex unchanged (snapshot identical before/after)"

smoke_log "all tests PASS — #8945 Track C codex permission profiles: 3 real <role>.config.toml files (codex -p bridge-<role>), valid sandbox_mode, no inert permissions.toml, idempotent, controller ~/.codex untouched"
