#!/usr/bin/env bash
# scripts/smoke/1473-agent-list-iso-state-fallback.sh — Issue #1473.
#
# From inside an isolated agent UID, `agb agent list` rendered EVERY agent
# as `stopped` because the state column probes tmux directly
# (bridge_agent_is_active -> bridge_tmux_session_exists -> `tmux
# has-session`). tmux servers are per-UID, so an iso UID cannot reach the
# controller's socket and every probe falsely reads "absent".
#
# Fix (two parts):
#   A. The daemon (controller UID) publishes a world-readable (0644)
#      all-agent aggregate `${BRIDGE_STATE_DIR}/agents-aggregate.tsv` each
#      heartbeat tick — agent / active / activity_state / updated_at, NO
#      secrets, atomic write (mktemp -> chmod -> mv).
#   B. bridge_agent_is_active + bridge_agent_activity_state fall back to
#      that aggregate when the live tmux probe misses AND we are NOT the
#      controller (the aggregate is owned by a different UID). On the
#      controller the live probe stays authoritative (no shared-mode
#      regression, no trusting a stale aggregate over a fresh probe).
#
# Test matrix:
#   T1. Writer publishes the aggregate at 0644 with the exact header and
#       lists ALL registered agents (active AND stopped) with the correct
#       active column, mirroring the live tmux-probe result.
#   T2. The aggregate carries NO secret/identifying columns (no session,
#       workdir, channel id, token, or path) — content-boundary that
#       justifies the 0644 mode.
#   T3. With the tmux probe forced to miss and the non-controller gate
#       forced true, bridge_agent_is_active returns ACTIVE from the
#       aggregate and bridge_agent_activity_state returns the aggregate's
#       state token (not the misleading "working" tmux-ladder fallthrough
#       and not "stopped").
#   T4. Shared-mode / controller no-regression: when the aggregate is
#       owned by the SAME UID as the reader (the controller writes it as
#       itself), the should-consult gate is FALSE, so a genuinely-stopped
#       agent (probe miss) reads inactive even though the aggregate marks a
#       DIFFERENT agent active. The controller never flips a fresh probe.
#   T5. Graceful daemon-down: with NO aggregate present, the should-consult
#       gate is false and bridge_agent_is_active for a probe-miss agent
#       returns inactive without error (historical behavior preserved).
#   T6. Stale aggregate (daemon stopped publishing): a controller-owned but
#       OLD aggregate is NOT consulted (the mtime freshness gate flips
#       false), so an iso UID does not report agents live off an
#       indefinitely-stale snapshot; a freshly-touched file IS consulted.
#   T7. Broken-launch quarantine: the writer publishes
#       `quarantine-broken-launch` (NOT `stopped`) for a marked agent — the
#       daemon-side state fn alone drops that signal — and the iso fallback
#       surfaces it from the aggregate even when the local marker is gone.
#
# Footgun #11: no `<<PY`/`<<EOF` heredoc-stdin to a subprocess; the
# in-process harness is a `bash -c '...'` string with function overrides
# defined AFTER sourcing bridge-lib.sh.

set -euo pipefail

SMOKE_NAME="1473-agent-list-iso-state-fallback"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

A1="alpha"   # live (probe true)
A2="bravo"   # live (probe true)
A3="charlie" # stopped (probe false)

write_roster_fixture() {
  # Three static agents. Distinct session names so a per-agent probe stub
  # can decide each agent's live state independently.
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_ADMIN_AGENT_ID=${A1}
# BEGIN AGENT BRIDGE MANAGED ROLE: ${A1}
bridge_add_agent_id_if_missing ${A1}
BRIDGE_AGENT_DESC["${A1}"]='alpha role'
BRIDGE_AGENT_ENGINE["${A1}"]='claude'
BRIDGE_AGENT_SESSION["${A1}"]='sess-${A1}'
BRIDGE_AGENT_WORKDIR["${A1}"]='${BRIDGE_AGENT_HOME_ROOT}/${A1}'
BRIDGE_AGENT_SOURCE["${A1}"]="static"
BRIDGE_AGENT_LAUNCH_CMD["${A1}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["${A1}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${A1}

# BEGIN AGENT BRIDGE MANAGED ROLE: ${A2}
bridge_add_agent_id_if_missing ${A2}
BRIDGE_AGENT_DESC["${A2}"]='bravo role'
BRIDGE_AGENT_ENGINE["${A2}"]='claude'
BRIDGE_AGENT_SESSION["${A2}"]='sess-${A2}'
BRIDGE_AGENT_WORKDIR["${A2}"]='${BRIDGE_AGENT_HOME_ROOT}/${A2}'
BRIDGE_AGENT_SOURCE["${A2}"]="static"
BRIDGE_AGENT_LAUNCH_CMD["${A2}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["${A2}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${A2}

# BEGIN AGENT BRIDGE MANAGED ROLE: ${A3}
bridge_add_agent_id_if_missing ${A3}
BRIDGE_AGENT_DESC["${A3}"]='charlie role'
BRIDGE_AGENT_ENGINE["${A3}"]='claude'
BRIDGE_AGENT_SESSION["${A3}"]='sess-${A3}'
BRIDGE_AGENT_WORKDIR["${A3}"]='${BRIDGE_AGENT_HOME_ROOT}/${A3}'
BRIDGE_AGENT_SOURCE["${A3}"]="static"
BRIDGE_AGENT_LAUNCH_CMD["${A3}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["${A3}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${A3}
EOF
  mkdir -p \
    "$BRIDGE_AGENT_HOME_ROOT/$A1" \
    "$BRIDGE_AGENT_HOME_ROOT/$A2" \
    "$BRIDGE_AGENT_HOME_ROOT/$A3"
}

# Run a snippet with bridge-lib.sh sourced in-process. $1 is bash code
# appended AFTER the source line, so it can override probe functions and
# call the writer/reader. The harness pins the same BRIDGE_* env this
# smoke's bridge home exports so the aggregate path resolves under the
# isolated root.
# bridge-lib.sh sources neither bridge-daemon.sh nor bridge-agent.sh, so
# the two activity_state computations the fix touches live outside the
# in-process harness. Extract BOTH into a standalone file the harness
# sources (pattern mirrors
# scripts/smoke/1178-helper-contract-daemon-supp.sh::extract_helper):
#   - bridge_agent_heartbeat_activity_state (bridge-daemon.sh): the
#     function the WRITER prefers in the daemon context (its real primary
#     caller). Exercises the same per-agent state path the daemon uses.
#   - bridge_agent_activity_state (bridge-agent.sh): the CLI function an
#     iso agent calls via `agb agent list`; it carries the #1473 iso
#     aggregate fallback under test in T3/T4/T5.
# All of bridge_agent_activity_state's other dependencies
# (bridge_agent_broken_launch_file, the tmux probes, picker_blocked, the
# aggregate helpers) live in libs bridge-lib.sh already sources.
STATE_FN_FILE=""
extract_state_fns() {
  STATE_FN_FILE="$SMOKE_TMP_ROOT/state-fns.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    awk '/^bridge_agent_heartbeat_activity_state\(\) \{/,/^\}/' \
      "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    printf '%s\n' ''
    awk '/^bridge_agent_activity_state\(\) \{/,/^\}/' \
      "$SMOKE_REPO_ROOT/bridge-agent.sh"
  } >"$STATE_FN_FILE"
  grep -q '^bridge_agent_heartbeat_activity_state()' "$STATE_FN_FILE" \
    || smoke_fail "extract: bridge_agent_heartbeat_activity_state not found in bridge-daemon.sh"
  grep -q '^bridge_agent_activity_state()' "$STATE_FN_FILE" \
    || smoke_fail "extract: bridge_agent_activity_state not found in bridge-agent.sh"
}

harness() {
  local body="$1"
  # Invoke the SAME Bash 4+ binary that runs this smoke ($BASH), NOT a bare
  # `bash` — on macOS a bare `bash` resolves to /bin/bash 3.2, and
  # bridge-lib.sh's top-of-file Bash-4+ guard would `exec` a re-run into a
  # candidate Bash 4+ shell *targeting bridge-lib.sh itself* (BASH_SOURCE[1]
  # is unset under `bash -c`), which sources the lib with no body and exits
  # 0 — so the harness body would silently never run.
  #
  # `set +e` first to clear any errexit the parent leaked via an exported
  # SHELLOPTS (the smoke runs under `set -e`); sourcing bridge-lib.sh runs
  # startup validation that can return non-zero benignly. The functions
  # under test return their own status, which the body checks.
  local _bash_bin="${BASH:-/usr/bin/env bash}"
  BRIDGE_SCRIPT_DIR="$SMOKE_REPO_ROOT" \
  SMOKE_STATE_FN_FILE="$STATE_FN_FILE" \
    "$_bash_bin" -c '
      set +e
      set -uo pipefail
      BRIDGE_SCRIPT_DIR="'"$SMOKE_REPO_ROOT"'"
      export BRIDGE_SCRIPT_DIR
      source "$BRIDGE_SCRIPT_DIR/bridge-lib.sh" >/dev/null 2>&1
      # Sourcing bridge-lib.sh does NOT auto-load the roster; call it
      # explicitly (cache-disabled so the fixture roster is re-read) so the
      # BRIDGE_AGENT_* associative arrays + BRIDGE_AGENT_IDS are populated.
      BRIDGE_ROSTER_CACHE_DISABLE=1 bridge_load_roster >/dev/null 2>&1 || true
      # Provide the daemon-side activity_state function the writer prefers.
      # bridge-lib.sh sources neither bridge-daemon.sh nor bridge-agent.sh,
      # so without this the writer would emit the `unknown` sentinel.
      if [[ -n "${SMOKE_STATE_FN_FILE:-}" && -f "${SMOKE_STATE_FN_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${SMOKE_STATE_FN_FILE}"
      fi
      '"$body"'
    '
}

# Force-true / force-false / mixed tmux probe overrides as a code prelude
# the harness body can prepend. Each redefines bridge_tmux_session_exists
# AFTER the source so the stub wins over the library definition.
probe_mixed_prelude='
bridge_tmux_session_exists() {
  case "$1" in
    sess-'"$A1"'|sess-'"$A2"') return 0 ;;   # alpha + bravo live
    *) return 1 ;;                            # charlie stopped
  esac
}
'

probe_all_miss_prelude='
bridge_tmux_session_exists() { return 1; }
'

test_t1_writer_publishes_all_agents_0644() {
  write_roster_fixture
  harness "$probe_mixed_prelude"'
    bridge_write_agents_aggregate_state
  '

  local agg="$BRIDGE_STATE_DIR/agents-aggregate.tsv"
  smoke_assert_file_exists "$agg" "T1: aggregate published"

  # Mode 0644 (the world-readable contract that lets an iso UID read it).
  local mode
  if [[ "$(uname)" == "Darwin" ]]; then
    mode="$(stat -f '%Lp' "$agg")"
  else
    mode="$(stat -c '%a' "$agg")"
  fi
  smoke_assert_eq "644" "$mode" "T1: aggregate is mode 0644"

  # Exact header line.
  local header
  header="$(head -n 1 "$agg")"
  smoke_assert_eq "agent	active	activity_state	updated_at" "$header" \
    "T1: aggregate header columns"

  # ALL three agents present (active AND stopped) — the active-only roster
  # would have dropped charlie, which is exactly the iso-view regression.
  smoke_assert_eq "3" "$(awk 'NR>1' "$agg" | wc -l | tr -d ' ')" \
    "T1: aggregate lists all 3 registered agents (not active-only)"

  # active column mirrors the tmux-probe result: alpha=1 bravo=1 charlie=0.
  smoke_assert_eq "1" "$(awk -F'\t' -v a="$A1" '$1==a{print $2}' "$agg")" "T1: alpha active=1"
  smoke_assert_eq "1" "$(awk -F'\t' -v a="$A2" '$1==a{print $2}' "$agg")" "T1: bravo active=1"
  smoke_assert_eq "0" "$(awk -F'\t' -v a="$A3" '$1==a{print $2}' "$agg")" "T1: charlie active=0"

  # activity_state is a non-empty enum token; charlie (probe miss) is stopped.
  smoke_assert_eq "stopped" "$(awk -F'\t' -v a="$A3" '$1==a{print $3}' "$agg")" \
    "T1: charlie activity_state=stopped"

  # updated_at non-empty for every row.
  local empty_ts
  empty_ts="$(awk -F'\t' 'NR>1 && ($4=="" || $4=="-"){c++} END{print c+0}' "$agg")"
  smoke_assert_eq "0" "$empty_ts" "T1: every row has a non-empty updated_at"
}

test_t2_no_secrets_in_aggregate() {
  write_roster_fixture
  harness "$probe_mixed_prelude"'
    bridge_write_agents_aggregate_state
  '
  local agg="$BRIDGE_STATE_DIR/agents-aggregate.tsv"

  # The session names + workdirs are the most obvious would-be leaks. They
  # are present in the roster but MUST NOT appear in the aggregate.
  smoke_assert_not_contains "$(cat "$agg")" "sess-$A1" "T2: no session id leaks into aggregate"
  smoke_assert_not_contains "$(cat "$agg")" "$BRIDGE_AGENT_HOME_ROOT" "T2: no workdir/path leaks into aggregate"

  # Exactly 4 columns per data row — a 5th column would mean an extra
  # (potentially sensitive) field crept in.
  local bad_cols
  bad_cols="$(awk -F'\t' 'NR>1 && NF!=4{c++} END{print c+0}' "$agg")"
  smoke_assert_eq "0" "$bad_cols" "T2: every data row has exactly 4 columns"

  # Source-level guard: the writer function body must not emit any of the
  # forbidden column accessors. Grep the writer block in bridge-state.sh.
  local writer_body
  writer_body="$(awk '/^bridge_write_agents_aggregate_state\(\)/{f=1} f{print} f&&/^}/{exit}' \
    "$SMOKE_REPO_ROOT/lib/bridge-state.sh")"
  for forbidden in bridge_agent_session bridge_agent_workdir bridge_agent_session_id \
      bridge_agent_channels bridge_agent_discord bridge_agent_notify_target; do
    smoke_assert_not_contains "$writer_body" "$forbidden" \
      "T2: writer does not emit $forbidden into the aggregate"
  done
}

test_t3_iso_fallback_reads_active_and_state() {
  write_roster_fixture
  # Seed an aggregate that marks alpha active=working, charlie active=0.
  # Then force the tmux probe to MISS for everything (the iso blindness)
  # and force the non-controller gate true. bridge_agent_is_active must
  # report alpha ACTIVE from the aggregate, and bridge_agent_activity_state
  # must report alpha's aggregate state token ("working"), NOT "stopped"
  # and NOT the misleading tmux-ladder "working" fallthrough.
  local agg="$BRIDGE_STATE_DIR/agents-aggregate.tsv"
  printf 'agent\tactive\tactivity_state\tupdated_at\n' >"$agg"
  printf '%s\t1\tworking\t2026-06-01T00:00:00+00:00\n' "$A1" >>"$agg"
  printf '%s\t0\tstopped\t2026-06-01T00:00:00+00:00\n' "$A3" >>"$agg"
  chmod 0644 "$agg"

  local out
  out="$(harness "$probe_all_miss_prelude"'
    # Simulate the non-controller (iso) reader: the real gate compares file
    # owner UID to id -u, which are equal under a single-UID smoke. Override
    # to assert the consult path.
    bridge_agents_aggregate_should_consult() { return 0; }

    if bridge_agent_is_active "'"$A1"'"; then echo "ALPHA_ACTIVE=yes"; else echo "ALPHA_ACTIVE=no"; fi
    echo "ALPHA_STATE=$(bridge_agent_activity_state "'"$A1"'")"
    if bridge_agent_is_active "'"$A3"'"; then echo "CHARLIE_ACTIVE=yes"; else echo "CHARLIE_ACTIVE=no"; fi
    echo "CHARLIE_STATE=$(bridge_agent_activity_state "'"$A3"'")"
  ')"

  smoke_assert_contains "$out" "ALPHA_ACTIVE=yes" "T3: iso fallback reports alpha active from aggregate"
  smoke_assert_contains "$out" "ALPHA_STATE=working" "T3: iso fallback reports alpha aggregate state token"
  smoke_assert_contains "$out" "CHARLIE_ACTIVE=no" "T3: iso fallback reports stopped agent inactive"
  smoke_assert_contains "$out" "CHARLIE_STATE=stopped" "T3: iso fallback reports stopped agent's state"
}

test_t4_controller_no_regression() {
  write_roster_fixture
  # The aggregate (owned by THIS uid — the controller-equivalent) marks
  # alpha active. With the tmux probe forced to miss for everything and the
  # REAL should-consult gate (owner == id -u -> false), alpha must read
  # INACTIVE: the controller trusts its fresh probe, never the aggregate.
  local agg="$BRIDGE_STATE_DIR/agents-aggregate.tsv"
  printf 'agent\tactive\tactivity_state\tupdated_at\n' >"$agg"
  printf '%s\t1\tworking\t2026-06-01T00:00:00+00:00\n' "$A1" >>"$agg"
  chmod 0644 "$agg"

  local out
  out="$(harness "$probe_all_miss_prelude"'
    # Confirm the real gate is false when owner == self (controller case).
    if bridge_agents_aggregate_should_consult; then echo "GATE=consult"; else echo "GATE=skip"; fi
    if bridge_agent_is_active "'"$A1"'"; then echo "ALPHA_ACTIVE=yes"; else echo "ALPHA_ACTIVE=no"; fi
    echo "ALPHA_STATE=$(bridge_agent_activity_state "'"$A1"'")"
  ')"

  smoke_assert_contains "$out" "GATE=skip" "T4: same-UID owner -> should_consult is false (controller)"
  smoke_assert_contains "$out" "ALPHA_ACTIVE=no" "T4: controller trusts fresh probe-miss over stale aggregate"
  smoke_assert_contains "$out" "ALPHA_STATE=stopped" "T4: controller activity_state stays stopped on probe miss"
}

test_t5_graceful_daemon_down() {
  write_roster_fixture
  # No aggregate file at all (daemon never ran / is down).
  rm -f "$BRIDGE_STATE_DIR/agents-aggregate.tsv"

  local out
  out="$(harness "$probe_all_miss_prelude"'
    if bridge_agents_aggregate_should_consult; then echo "GATE=consult"; else echo "GATE=skip"; fi
    if bridge_agent_is_active "'"$A1"'"; then echo "ALPHA_ACTIVE=yes"; else echo "ALPHA_ACTIVE=no"; fi
    echo "ALPHA_STATE=$(bridge_agent_activity_state "'"$A1"'")"
    echo "RC=$?"
  ')"

  smoke_assert_contains "$out" "GATE=skip" "T5: missing aggregate -> should_consult is false"
  smoke_assert_contains "$out" "ALPHA_ACTIVE=no" "T5: probe-miss + no aggregate -> inactive (historical)"
  smoke_assert_contains "$out" "ALPHA_STATE=stopped" "T5: probe-miss + no aggregate -> stopped (no error)"
}

test_t6_stale_aggregate_not_consulted() {
  write_roster_fixture
  # An aggregate that exists + is "controller-owned" (we spoof a different
  # owner UID) but is OLD: once the daemon stops publishing, an iso UID
  # must NOT keep trusting an indefinitely-stale snapshot (#1473 codex r1
  # gate 5). The freshness ceiling is mtime-based, so we age the file with
  # `touch -t` well past the default 3× heartbeat-interval ceiling.
  local agg="$BRIDGE_STATE_DIR/agents-aggregate.tsv"
  printf 'agent\tactive\tactivity_state\tupdated_at\n' >"$agg"
  printf '%s\t1\tworking\t2020-01-01T00:00:00+00:00\n' "$A1" >>"$agg"
  chmod 0644 "$agg"
  # Age the file to 2020 so any reasonable ceiling treats it as stale.
  touch -t 202001010000 "$agg"

  # Spoof a controller-owned file (owner UID != id -u) so only the
  # freshness gate decides. With a STALE file the gate must be false; with
  # a FRESH file (mtime=now) the gate must be true — proving freshness, not
  # the owner check, is what flips it.
  local out
  out="$(harness "$probe_all_miss_prelude"'
    bridge_marker_stat_uid() { printf "%s" "$(( $(id -u) + 1 ))"; }
    if bridge_agents_aggregate_should_consult; then echo "STALE_GATE=consult"; else echo "STALE_GATE=skip"; fi
    if bridge_agent_is_active "'"$A1"'"; then echo "STALE_ACTIVE=yes"; else echo "STALE_ACTIVE=no"; fi
    # Now refresh the file mtime and re-check: same owner spoof, fresh file.
    touch "'"$agg"'"
    if bridge_agents_aggregate_should_consult; then echo "FRESH_GATE=consult"; else echo "FRESH_GATE=skip"; fi
    if bridge_agent_is_active "'"$A1"'"; then echo "FRESH_ACTIVE=yes"; else echo "FRESH_ACTIVE=no"; fi
  ')"

  smoke_assert_contains "$out" "STALE_GATE=skip" "T6: stale controller-owned aggregate is NOT consulted"
  smoke_assert_contains "$out" "STALE_ACTIVE=no" "T6: stale aggregate -> agent reads inactive (no false-live)"
  smoke_assert_contains "$out" "FRESH_GATE=consult" "T6: fresh controller-owned aggregate IS consulted"
  smoke_assert_contains "$out" "FRESH_ACTIVE=yes" "T6: fresh aggregate -> agent reads active"
}

test_t7_broken_launch_quarantine_published() {
  write_roster_fixture
  # Quarantine charlie via the broken-launch marker (the #1317-B signal).
  # The aggregate writer must publish `quarantine-broken-launch` for it
  # (NOT `stopped`) — the daemon-side state fn alone would have dropped the
  # signal — and the iso fallback must surface that token.
  mkdir -p "$BRIDGE_STATE_DIR/agents/$A3"
  : >"$BRIDGE_STATE_DIR/agents/$A3/broken-launch"

  harness "$probe_mixed_prelude"'
    bridge_write_agents_aggregate_state
  '
  local agg="$BRIDGE_STATE_DIR/agents-aggregate.tsv"
  smoke_assert_eq "quarantine-broken-launch" \
    "$(awk -F'\t' -v a="$A3" '$1==a{print $3}' "$agg")" \
    "T7: writer publishes quarantine-broken-launch for the marked agent"

  # Now REMOVE the marker, then test the iso fallback. On a real iso UID
  # the controller-owned broken-launch marker of ANOTHER agent is not
  # readable, so bridge_agent_activity_state's own marker short-circuit
  # would miss it — the quarantine signal must come from the published
  # aggregate. Removing the local marker here forces exactly that path:
  # the fallback must surface the aggregate's token, not a live marker read.
  rm -f "$BRIDGE_STATE_DIR/agents/$A3/broken-launch"
  local out
  out="$(harness "$probe_all_miss_prelude"'
    bridge_agents_aggregate_should_consult() { return 0; }
    echo "CHARLIE_STATE=$(bridge_agent_activity_state "'"$A3"'")"
  ')"
  smoke_assert_contains "$out" "CHARLIE_STATE=quarantine-broken-launch" \
    "T7: iso fallback surfaces quarantine-broken-launch from the aggregate (not stopped)"
}

main() {
  smoke_require_cmd bash
  smoke_require_cmd awk
  smoke_setup_bridge_home "$SMOKE_NAME"
  extract_state_fns

  smoke_run "T1: writer publishes all agents at 0644"        test_t1_writer_publishes_all_agents_0644
  smoke_run "T2: aggregate carries no secrets"               test_t2_no_secrets_in_aggregate
  smoke_run "T3: iso fallback reads active + state"          test_t3_iso_fallback_reads_active_and_state
  smoke_run "T4: controller no-regression (no stale flip)"   test_t4_controller_no_regression
  smoke_run "T5: graceful daemon-down"                       test_t5_graceful_daemon_down
  smoke_run "T6: stale aggregate is not consulted"           test_t6_stale_aggregate_not_consulted
  smoke_run "T7: broken-launch quarantine published"         test_t7_broken_launch_quarantine_published
  smoke_log "passed"
}

main "$@"
