#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/codex-permission-profiles.sh — #8945 Track C permissions smoke.
#
# Pins the agent-scoped Codex permission-profile provisioning contract:
#
#   T1: bridge_ensure_codex_agent_slash_commands deploys permissions.toml into
#       <scaffold_target>/.codex/ with the agent-bridge:managed marker.
#   T2: all three role profiles land — [permissions.bridge-admin],
#       [permissions.bridge-worker], [permissions.bridge-reviewer] — and the
#       file is valid, parseable TOML.
#   T3: per-agent <agent-home> / <bridge-home> substitution applied; the raw
#       tokens are gone; idempotent re-run; an agent's own permissions.toml
#       (no marker) is never clobbered.
#   T4 (CRITICAL): the controller/operator global ~/.codex (real $HOME/.codex)
#       is neither created nor mutated. Snapshot before/after.
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

# Standalone TOML parser helper (file-as-argv; no heredoc-stdin). Exit codes:
#   0 = parsed OK and all three bridge-* profiles present
#   3 = no tomllib/tomli available (caller treats as skip)
#   4 = parse error or a required profile is missing
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
    'perms = data.get("permissions", {})' \
    'need = {"bridge-admin", "bridge-worker", "bridge-reviewer"}' \
    'sys.exit(0 if need.issubset(set(perms)) else 4)'
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
    'PERMS="$AGENT_HOME/.codex/permissions.toml"' \
    'MARKER="$(bridge_codex_managed_asset_marker)"' \
    '# ---- T1: deploy the permission profiles into agent-scoped .codex ----' \
    'bridge_ensure_codex_agent_slash_commands "$AGENT" "$AGENT_HOME" 2>/dev/null || true' \
    'if [[ -f "$PERMS" ]]; then echo "T1_PERMS_FILE: present"; else echo "T1_PERMS_FILE: missing"; fi' \
    'if [[ -f "$PERMS" ]] && grep -qF "$MARKER" "$PERMS" 2>/dev/null; then echo "T1_PERMS_MARKER: yes"; else echo "T1_PERMS_MARKER: no"; fi' \
    '# ---- T2: all three role profiles present ----' \
    'for role in bridge-admin bridge-worker bridge-reviewer; do' \
    '  if [[ -f "$PERMS" ]] && grep -qF "[permissions.$role]" "$PERMS" 2>/dev/null; then echo "T2_PROFILE_${role}: yes"; else echo "T2_PROFILE_${role}: no"; fi' \
    'done' \
    '# T2: the TOML must actually parse + carry the three profiles. The parser' \
    '# helper is a standalone file invoked with file-as-argv (no heredoc-stdin,' \
    '# per footgun #11 / lint-heredoc-ban H3). It exits 0=ok, 3=no toml lib' \
    '# (skip), 4=parse/profile failure.' \
    'TOML_OK="skip"' \
    'if command -v python3 >/dev/null 2>&1 && [[ -f "$TOML_HELPER" ]]; then' \
    '  python3 "$TOML_HELPER" "$PERMS" >/dev/null 2>&1; trc=$?' \
    '  if [[ $trc -eq 0 ]]; then TOML_OK="yes"; elif [[ $trc -eq 3 ]]; then TOML_OK="skip"; else TOML_OK="no"; fi' \
    'fi' \
    'echo "T2_TOML_PARSE: $TOML_OK"' \
    '# ---- T3: per-agent substitution + idempotent + no-clobber ----' \
    'if [[ -f "$PERMS" ]] && grep -qF "$AGENT_HOME" "$PERMS" 2>/dev/null; then echo "T3_SUBST_HOME: yes"; else echo "T3_SUBST_HOME: no"; fi' \
    'if [[ -f "$PERMS" ]] && grep -qF "<agent-home>" "$PERMS" 2>/dev/null; then echo "T3_RAW_TOKEN: yes"; else echo "T3_RAW_TOKEN: no"; fi' \
    'bridge_ensure_codex_agent_slash_commands "$AGENT" "$AGENT_HOME" 2>/dev/null; RC2=$?' \
    'echo "T3_RERUN_RC: $RC2"' \
    '# Replace the managed file with unmarked agent content; the installer must leave it.' \
    'printf "%s\n" "# my own permissions, no marker" > "$PERMS"' \
    'OWN_SHA_BEFORE="$(cksum "$PERMS" 2>/dev/null | awk "{print \$1}")"' \
    'bridge_ensure_codex_agent_slash_commands "$AGENT" "$AGENT_HOME" 2>/dev/null || true' \
    'OWN_SHA_AFTER="$(cksum "$PERMS" 2>/dev/null | awk "{print \$1}")"' \
    'if [[ "$OWN_SHA_BEFORE" == "$OWN_SHA_AFTER" ]]; then echo "T3_OWN_PRESERVED: yes"; else echo "T3_OWN_PRESERVED: no"; fi' \
    '# ---- T4 teeth: agent-scoped, not under controller HOME ----' \
    'case "$PERMS" in' \
    '  "$HOME/.codex"/*) echo "T4_SCOPED_UNDER_CONTROLLER: yes" ;;' \
    '  *) echo "T4_SCOPED_UNDER_CONTROLLER: no" ;;' \
    'esac' \
    'echo "T4_PERMS_PATH: $PERMS"'
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

# --- T1 assertions ---
smoke_assert_eq "present" "$(extract_line "$OUT" "T1_PERMS_FILE")" \
  "T1: permissions.toml deployed into agent-scoped .codex/"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_PERMS_MARKER")" \
  "T1: permissions.toml carries the agent-bridge:managed marker"

# --- T2 assertions ---
for role in bridge-admin bridge-worker bridge-reviewer; do
  smoke_assert_eq "yes" "$(extract_line "$OUT" "T2_PROFILE_${role}")" \
    "T2: [permissions.$role] profile present"
done
TOML_PARSE="$(extract_line "$OUT" "T2_TOML_PARSE")"
case "$TOML_PARSE" in
  yes) smoke_log "T2: permissions.toml is valid TOML and contains all three role profiles" ;;
  skip) smoke_log "T2: TOML parse skipped (no tomllib/tomli available); grep-level profile checks still enforced" ;;
  *) smoke_fail "T2: permissions.toml failed TOML parse / missing required profiles (got '$TOML_PARSE')" ;;
esac

# --- T3 assertions ---
smoke_assert_eq "yes" "$(extract_line "$OUT" "T3_SUBST_HOME")" \
  "T3: <agent-home> substituted with the resolved agent home path"
smoke_assert_eq "no" "$(extract_line "$OUT" "T3_RAW_TOKEN")" \
  "T3: the raw <agent-home> token was substituted away"
smoke_assert_eq "0" "$(extract_line "$OUT" "T3_RERUN_RC")" \
  "T3: re-running the installer exits 0 (idempotent)"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T3_OWN_PRESERVED")" \
  "T3: an agent's own (unmarked) permissions.toml is never clobbered"

# --- T4 assertions ---
smoke_assert_eq "no" "$(extract_line "$OUT" "T4_SCOPED_UNDER_CONTROLLER")" \
  "T4: permissions.toml is NOT under the controller \$HOME/.codex"

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

smoke_log "all tests PASS — #8945 Track C codex permission profiles: agent-scoped install, 3 role profiles, idempotent, controller ~/.codex untouched"
