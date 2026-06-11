#!/usr/bin/env bash
# scripts/smoke/agent-retire.sh — Issue #598 Track 3 smoke.
#
# Validates the new `agent retire <name>` cleanup primitive:
#   T1. Retire a dynamic non-alive agent → quarantine succeeds, audit row
#       written.
#   T2. Same shape with `--purge-home` → home dir gone, audit reflects
#       purge_home=true + non-zero pre_size_bytes.
#   T3. Static-class agent → refused (refuse-static safety rule).
#   T4. Active agent → refused (refuse-alive safety rule, mocked via
#       bridge_agent_is_active override in the roster).
#   T5. Agent NOT in registry AND NOT on disk → refused (nothing to
#       retire).
#   T6. Orphan home dir (on disk, not in registry) → quarantine succeeds
#       without state cleanup.
#   T7. `--dry-run` prints the plan without mutating anything.
#   T8. Path validation: when the resolver returns a home outside
#       $BRIDGE_AGENT_HOME_ROOT, retire refuses (no rm/mv).
#
# Uses an isolated BRIDGE_HOME via smoke_setup_bridge_home — never
# touches the operator's live runtime.
#
# Not registered in scripts/smoke-test.sh yet — Track 2's detector smoke
# will register the #598 fixtures together once that lands.

set -euo pipefail

SMOKE_NAME="agent-retire"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "agent-retire"

REPO_ROOT="$SMOKE_REPO_ROOT"

BASH4_BIN="${BASH:-bash}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

# Helper — invoke `agent retire ...` against the isolated BRIDGE_HOME.
agent_retire() {
  "$BASH4_BIN" "$REPO_ROOT/bridge-agent.sh" retire "$@"
}

# Helper — read the audit log and return the last `agent_retired` row as
# JSON. Empty string when no row found.
last_retire_audit() {
  [[ -f "$BRIDGE_AUDIT_LOG" ]] || { printf ''; return 0; }
  "$PY_BIN" - "$BRIDGE_AUDIT_LOG" <<'PY'
import json
import sys

path = sys.argv[1]
last = ""
with open(path) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("action") == "agent_retired":
            last = json.dumps(row)
print(last)
PY
}

# ---------------------------------------------------------------------------
# Roster fixture writers.
# ---------------------------------------------------------------------------

reset_state() {
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  rm -rf "$BRIDGE_ACTIVE_AGENT_DIR"
  mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"
  rm -rf "$BRIDGE_AGENT_HOME_ROOT"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT"
  : >"$BRIDGE_AUDIT_LOG"
  rm -rf "$BRIDGE_HOME/archive"
}

write_dynamic_active_env() {
  local agent="$1"
  local engine="${2:-claude}"
  local file="$BRIDGE_ACTIVE_AGENT_DIR/${agent}.env"
  mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"
  cat >"$file" <<EOF
AGENT_ID="$agent"
AGENT_DESC="dynamic test agent"
AGENT_ENGINE="$engine"
AGENT_SESSION="$agent"
AGENT_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$agent"
AGENT_LOOP=1
AGENT_CONTINUE=1
EOF
}

# Materialize a fake agent home dir with at least one byte of content so
# pre_size_bytes is > 0 and the quarantine mv has something to move.
make_home_dir() {
  local agent="$1"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"
  mkdir -p "$home"
  printf 'placeholder content for %s\n' "$agent" >"$home/marker.txt"
  printf '%s\n' "$home"
}

write_static_one() {
  local agent="$1"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "$agent"
BRIDGE_AGENT_ENGINE["$agent"]="claude"
BRIDGE_AGENT_SESSION["$agent"]="$agent"
BRIDGE_AGENT_WORKDIR["$agent"]="$BRIDGE_AGENT_HOME_ROOT/$agent"
EOF
}

# Write a roster that overrides bridge_agent_is_active to always return
# true for the named agent. Mirrors the registry-smoke approach
# (override-via-roster) so we don't need a real tmux session.
write_dynamic_with_alive_override() {
  local agent="$1"
  write_dynamic_active_env "$agent"
  cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

# Force bridge_agent_is_active to return true for '$agent' so the
# refuse-alive guard fires deterministically without a tmux session.
bridge_agent_is_active() {
  if [[ "\$1" == "$agent" ]]; then
    return 0
  fi
  return 1
}
EOF
}

# ---------------------------------------------------------------------------
# T1 — retire dynamic non-alive agent → quarantine succeeds.
# ---------------------------------------------------------------------------
test_quarantine_dynamic() {
  reset_state
  write_dynamic_active_env "alpha"
  local home
  home="$(make_home_dir "alpha")"

  local out
  out="$(agent_retire alpha --json)"

  local status quarantined purged
  status="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["status"])' <<<"$out")"
  quarantined="$("$PY_BIN" -c 'import json,sys; v=json.loads(sys.stdin.read())["quarantined_to"]; print(v if v else "")' <<<"$out")"
  purged="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["purged_home"])' <<<"$out")"

  smoke_assert_eq "retired" "$status" "T1 status"
  smoke_assert_eq "False" "$purged" "T1 purged_home false"
  [[ -n "$quarantined" ]] || smoke_fail "T1 quarantined_to missing"
  smoke_assert_file_exists "$quarantined/marker.txt" "T1 quarantine target has marker"
  [[ ! -d "$home" ]] || smoke_fail "T1 original home should be moved away: $home still exists"

  # Active-env file removed.
  [[ ! -f "$BRIDGE_ACTIVE_AGENT_DIR/alpha.env" ]] || \
    smoke_fail "T1 dynamic active-env file should have been removed"

  # Audit row.
  local audit
  audit="$(last_retire_audit)"
  [[ -n "$audit" ]] || smoke_fail "T1 audit row not written"
  local audit_agent audit_purge audit_source
  audit_agent="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["target"])' <<<"$audit")"
  audit_purge="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["detail"]["purge_home"])' <<<"$audit")"
  audit_source="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["detail"]["agent_source"])' <<<"$audit")"
  smoke_assert_eq "alpha" "$audit_agent" "T1 audit target"
  smoke_assert_eq "false" "$audit_purge" "T1 audit purge_home"
  smoke_assert_eq "dynamic" "$audit_source" "T1 audit agent_source"
}

# ---------------------------------------------------------------------------
# T2 — retire dynamic with --purge-home → home gone, pre_size_bytes>0.
# ---------------------------------------------------------------------------
test_purge_dynamic() {
  reset_state
  write_dynamic_active_env "bravo"
  local home
  home="$(make_home_dir "bravo")"

  local out
  out="$(agent_retire bravo --purge-home --json)"

  local status purged quarantined
  status="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["status"])' <<<"$out")"
  purged="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["purged_home"])' <<<"$out")"
  quarantined="$("$PY_BIN" -c 'import json,sys; v=json.loads(sys.stdin.read())["quarantined_to"]; print(v if v else "<none>")' <<<"$out")"

  smoke_assert_eq "retired" "$status" "T2 status"
  smoke_assert_eq "True" "$purged" "T2 purged_home true"
  smoke_assert_eq "<none>" "$quarantined" "T2 quarantined_to is null when purging"
  [[ ! -d "$home" ]] || smoke_fail "T2 home should be deleted: $home still exists"

  # Audit pre_size_bytes is non-zero (we wrote marker.txt with content).
  local audit pre_size purge_flag
  audit="$(last_retire_audit)"
  [[ -n "$audit" ]] || smoke_fail "T2 audit row not written"
  pre_size="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["detail"]["pre_size_bytes"])' <<<"$audit")"
  purge_flag="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["detail"]["purge_home"])' <<<"$audit")"
  smoke_assert_eq "true" "$purge_flag" "T2 audit purge_home"
  if ! [[ "$pre_size" =~ ^[0-9]+$ ]] || (( pre_size <= 0 )); then
    smoke_fail "T2 audit pre_size_bytes should be > 0; got '$pre_size'"
  fi
}

# ---------------------------------------------------------------------------
# T3 — refuse retire of static-class agent.
# ---------------------------------------------------------------------------
test_refuse_static() {
  reset_state
  write_static_one "charlie"
  make_home_dir "charlie" >/dev/null

  local rc=0
  local out
  out="$(agent_retire charlie 2>&1)" || rc=$?
  (( rc != 0 )) || smoke_fail "T3 retire of static-class should have failed (rc=$rc, out=$out)"
  smoke_assert_contains "$out" "static-roster" "T3 refusal mentions static-roster"
  # Home dir untouched.
  [[ -d "$BRIDGE_AGENT_HOME_ROOT/charlie" ]] || \
    smoke_fail "T3 static refusal must not touch home dir"
}

# ---------------------------------------------------------------------------
# T4 — refuse retire of alive agent (mocked via bridge_agent_is_active).
# ---------------------------------------------------------------------------
test_refuse_alive() {
  reset_state
  write_dynamic_with_alive_override "delta"
  make_home_dir "delta" >/dev/null

  local rc=0
  local out
  out="$(agent_retire delta 2>&1)" || rc=$?
  (( rc != 0 )) || smoke_fail "T4 retire of alive agent should have failed (rc=$rc, out=$out)"
  smoke_assert_contains "$out" "active tmux session" "T4 refusal mentions active session"
  # Home dir untouched.
  [[ -d "$BRIDGE_AGENT_HOME_ROOT/delta" ]] || \
    smoke_fail "T4 alive refusal must not touch home dir"
}

# ---------------------------------------------------------------------------
# T5 — refuse retire of agent neither in registry nor on disk.
# ---------------------------------------------------------------------------
test_refuse_unknown() {
  reset_state

  local rc=0
  local out
  out="$(agent_retire ghost 2>&1)" || rc=$?
  (( rc != 0 )) || smoke_fail "T5 retire of unknown agent should have failed (rc=$rc, out=$out)"
  smoke_assert_contains "$out" "nothing to retire" "T5 refusal mentions nothing to retire"
}

# ---------------------------------------------------------------------------
# T6 — retire orphan home dir (on disk, not in registry) → quarantines.
# ---------------------------------------------------------------------------
test_orphan_quarantine() {
  reset_state
  # No active-env, no roster — just a leftover home dir.
  local home
  home="$(make_home_dir "echo-orphan")"

  local out
  out="$(agent_retire echo-orphan --json)"

  local status quarantined source
  status="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["status"])' <<<"$out")"
  quarantined="$("$PY_BIN" -c 'import json,sys; v=json.loads(sys.stdin.read())["quarantined_to"]; print(v if v else "")' <<<"$out")"

  smoke_assert_eq "retired" "$status" "T6 status"
  [[ -n "$quarantined" ]] || smoke_fail "T6 quarantined_to missing"
  smoke_assert_file_exists "$quarantined/marker.txt" "T6 quarantine target has marker"
  [[ ! -d "$home" ]] || smoke_fail "T6 orphan home should be moved away: $home still exists"

  local audit
  audit="$(last_retire_audit)"
  [[ -n "$audit" ]] || smoke_fail "T6 audit row not written"
  source="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["detail"]["agent_source"])' <<<"$audit")"
  smoke_assert_eq "unregistered" "$source" "T6 audit agent_source unregistered"
}

# ---------------------------------------------------------------------------
# T7 — --dry-run prints the plan without mutating anything.
# ---------------------------------------------------------------------------
test_dry_run() {
  reset_state
  write_dynamic_active_env "foxtrot"
  local home
  home="$(make_home_dir "foxtrot")"

  local out
  out="$(agent_retire foxtrot --dry-run --json)"

  local status
  status="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["status"])' <<<"$out")"
  smoke_assert_eq "would-retire" "$status" "T7 dry-run status"

  # Nothing must have moved or been deleted.
  [[ -d "$home" ]] || smoke_fail "T7 dry-run should not touch home dir"
  [[ -f "$BRIDGE_ACTIVE_AGENT_DIR/foxtrot.env" ]] || \
    smoke_fail "T7 dry-run should not touch active-env file"

  # No audit row.
  local audit
  audit="$(last_retire_audit)"
  [[ -z "$audit" ]] || smoke_fail "T7 dry-run must not write an audit row; got: $audit"
}

# ---------------------------------------------------------------------------
# T8 — path validation: refuse if home would resolve outside the agent
# root. We force a bad resolver via a roster override on
# bridge_agent_default_home so the refusal path is exercised
# deterministically (production resolver bug → operator-visible deny).
# ---------------------------------------------------------------------------
test_refuse_out_of_root() {
  reset_state
  # Agent must exist in registry so we hit bridge_agent_default_home,
  # not the unregistered fallback (which composes a safe path).
  write_dynamic_active_env "golf"
  cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

# Hostile resolver: claim the home is outside both known roots so the
# path-validation guard refuses rather than touches /tmp/...
bridge_agent_default_home() {
  if [[ "\$1" == "golf" ]]; then
    printf '%s' "${SMOKE_TMP_ROOT}/outside-root/golf"
    return 0
  fi
  printf '%s/%s' "\$BRIDGE_AGENT_HOME_ROOT" "\$1"
}
EOF
  # Make the bogus path real so the refusal isn't due to "missing dir".
  mkdir -p "$SMOKE_TMP_ROOT/outside-root/golf"
  printf 'should-not-be-touched\n' >"$SMOKE_TMP_ROOT/outside-root/golf/marker.txt"

  local rc=0
  local out
  out="$(agent_retire golf 2>&1)" || rc=$?
  (( rc != 0 )) || smoke_fail "T8 out-of-root retire should have failed (rc=$rc, out=$out)"
  smoke_assert_contains "$out" "outside expected agent roots" "T8 refusal mentions out-of-root"
  # Bogus path untouched.
  smoke_assert_file_exists "$SMOKE_TMP_ROOT/outside-root/golf/marker.txt" \
    "T8 out-of-root refusal must not touch the path"
}

# ---------------------------------------------------------------------------
# T9 — Issue #1787: case-variant of a REGISTERED agent name must NOT be
#      retireable on a case-insensitive filesystem. `agent retire CRM-TEST-BSH`
#      where the registry holds `crm-test-bsh` (same dir on APFS) must REFUSE
#      with a pointer to the real name and plan NOTHING destructive — even
#      under --dry-run.
# ---------------------------------------------------------------------------
test_refuse_case_variant_of_registered() {
  reset_state
  # Register the agent at its canonical lowercase spelling.
  write_dynamic_active_env "crm-test-bsh"
  local home
  home="$(make_home_dir "crm-test-bsh")"

  # Gate on case-insensitivity: only when the uppercase spelling reaches the
  # SAME directory is the #1787 collision reproducible (a Linux case-sensitive
  # fs makes them distinct dirs — nothing to guard there). Mirrors the
  # #1759 smoke's `case_variant.exists()` APFS gate.
  local variant_dir="$BRIDGE_AGENT_HOME_ROOT/CRM-TEST-BSH"
  if [[ ! -d "$variant_dir" ]] || ! [[ "$variant_dir" -ef "$home" ]]; then
    smoke_log "T9 skip: case-sensitive filesystem — case-variant collision not reproducible here"
    return 0
  fi

  # (a) --dry-run must REFUSE (non-zero) and name the real registered agent.
  local rc=0 out
  out="$(agent_retire CRM-TEST-BSH --dry-run 2>&1)" || rc=$?
  (( rc != 0 )) || smoke_fail "T9 case-variant retire --dry-run should have been refused (rc=$rc, out=$out)"
  smoke_assert_contains "$out" "crm-test-bsh" "T9 refusal points at the registered name"
  smoke_assert_contains "$out" "same directory" "T9 refusal explains the samefile collision"

  # (b) The live agent's home + its marker are untouched (no mv/quarantine planned).
  smoke_assert_file_exists "$home/marker.txt" "T9 live agent home must be untouched"
  [[ -d "$home" ]] || smoke_fail "T9 live agent home should still exist: $home"
  # No quarantine dir was created.
  if [[ -d "$BRIDGE_HOME/archive/retired-agents" ]] \
      && find "$BRIDGE_HOME/archive/retired-agents" -maxdepth 1 -name '*CRM-TEST-BSH*' 2>/dev/null | grep -q .; then
    smoke_fail "T9 no quarantine dir should have been created for the case-variant"
  fi

  # (c) A genuinely unrelated orphan in the SAME run still retires (teeth intact).
  local orphan_home
  orphan_home="$(make_home_dir "genuine-orphan-xyz")"
  local rc2=0 out2
  out2="$(agent_retire genuine-orphan-xyz --json 2>&1)" || rc2=$?
  (( rc2 == 0 )) || smoke_fail "T9 genuine orphan retire should still succeed (rc=$rc2, out=$out2)"
  local status2
  status2="$("$PY_BIN" -c 'import json,sys; print(json.loads(sys.stdin.read())["status"])' <<<"$out2")"
  smoke_assert_eq "retired" "$status2" "T9 genuine orphan still retired (detector teeth intact)"
  [[ ! -d "$orphan_home" ]] || smoke_fail "T9 genuine orphan home should be moved away"
}

smoke_run "T1 quarantine dynamic"             test_quarantine_dynamic
smoke_run "T2 purge dynamic"                  test_purge_dynamic
smoke_run "T3 refuse static-class"            test_refuse_static
smoke_run "T4 refuse alive"                   test_refuse_alive
smoke_run "T5 refuse unknown agent"           test_refuse_unknown
smoke_run "T6 orphan quarantine"              test_orphan_quarantine
smoke_run "T7 dry-run is no-op"               test_dry_run
smoke_run "T8 refuse out-of-root home"        test_refuse_out_of_root
smoke_run "T9 refuse case-variant of registered" test_refuse_case_variant_of_registered

smoke_log "all checks passed"
