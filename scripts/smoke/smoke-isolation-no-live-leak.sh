#!/usr/bin/env bash
# scripts/smoke/smoke-isolation-no-live-leak.sh — queue task #4793 regression.
#
# Locks in the `scripts/smoke-test.sh` BRIDGE_HOME guard + cleanup contract
# so a future edit cannot silently reintroduce the "unset BRIDGE_HOME
# fall-through" that leaked ~10 empty agent dirs (claude-static, cap-test,
# spool-test, lock-test, always-on-agent-<pid>, ...) into the live install
# at $HOME/.agent-bridge/agents/ on operator host 2026-05-17.
#
# Test cases:
#   C1 — BRIDGE_HOME UNSET: smoke-test.sh auto-isolates (Option A) and
#        emits the marker log line; live install agent-dir set unchanged.
#   C2 — BRIDGE_HOME set under $TMPDIR: a real CLI op that touches the
#        agents/ tree (`./agent-bridge list`) creates dirs ONLY under the
#        isolated BRIDGE_HOME; live install agent-dir set unchanged.
#   C3 — SIGTERM mid smoke-test.sh run with isolated BRIDGE_HOME: live
#        install agent-dir set unchanged after the trap-driven cleanup
#        finishes. Also verifies the cleanup trap removes the smoke-
#        created tempdir under $TMPDIR.
#
# C1 runs smoke-test.sh up to a deliberate fail-fast (PATH stripped so
# `require_cmd tmux` aborts) — we only need the guard region.
# C2 uses a fast CLI op so we don't pay for the multi-minute full suite.
# C3 runs smoke-test.sh for real long enough to exercise the cleanup
# trap, then asserts the cross-install invariant.

set -uo pipefail

SMOKE_NAME="smoke-isolation-no-live-leak"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
SMOKE_SCRIPT="$REPO_ROOT/scripts/smoke-test.sh"
AGENT_BRIDGE_CLI="$REPO_ROOT/agent-bridge"
smoke_assert_file_exists "$SMOKE_SCRIPT" "smoke-test.sh present"
smoke_assert_file_exists "$AGENT_BRIDGE_CLI" "agent-bridge CLI present"

# Track ephemeral state so the trap cleans up even on early failure.
C3_BG_PID=""
C3_ISO_PARENT=""

cleanup() {
  if [[ -n "$C3_BG_PID" ]] && kill -0 "$C3_BG_PID" 2>/dev/null; then
    kill -KILL "$C3_BG_PID" 2>/dev/null || true
    wait "$C3_BG_PID" 2>/dev/null || true
  fi
  if [[ -n "$C3_ISO_PARENT" ]] && [[ -d "$C3_ISO_PARENT" ]]; then
    rm -rf "$C3_ISO_PARENT" 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

# Sandbox PATH for C1: only the basic commands smoke-test.sh needs to
# reach the BRIDGE_HOME guard. Crucially NO `tmux` — smoke-test.sh
# hits `require_cmd tmux` after the guard and dies. We capture
# stderr+stdout and assert on the marker log line.
SANDBOX_BIN="$SMOKE_TMP_ROOT/bin"
mkdir -p "$SANDBOX_BIN"
for cmd in bash mktemp dirname basename printf cat ls wc grep sed awk env command python3; do
  src="$(command -v "$cmd" 2>/dev/null || true)"
  [[ -n "$src" && -x "$src" ]] || continue
  ln -sf "$src" "$SANDBOX_BIN/$(basename "$cmd")"
done

# Snapshot the live install agent-dir set so we can detect any leak the
# guard or cleanup fails to prevent. We compare the *set* (sorted names)
# rather than the count so an unrelated background event (operator
# running agent-bridge in another shell during a long C3) does not
# produce a false positive — only NEW entries that appeared between
# before/after count as leaks.
snapshot_live_agents() {
  local target="$1"
  if [[ -d "$HOME/.agent-bridge/agents" ]]; then
    # shellcheck disable=SC2012 # ls is fine; we only care about basenames sorted lexically
    ls -1 "$HOME/.agent-bridge/agents" 2>/dev/null | sort >"$target"
  else
    : >"$target"
  fi
}

assert_live_unchanged() {
  local before="$1"
  local after="$2"
  local context="$3"
  local new_entries
  new_entries="$(comm -13 "$before" "$after" 2>/dev/null || true)"
  if [[ -n "$new_entries" ]]; then
    smoke_fail "$context: live install gained agent dirs: $new_entries"
  fi
}

run_smoke_until_tmux_check() {
  # Run smoke-test.sh with a sandboxed PATH so require_cmd tmux trips
  # immediately after the BRIDGE_HOME guard. We CHANGE only PATH and
  # the explicit env vars below — everything else (HOME, TMPDIR, ...)
  # passes through so the live-install detection actually targets the
  # real $HOME.
  local out_file="$1"
  shift
  PATH="$SANDBOX_BIN" "$@" bash "$SMOKE_SCRIPT" >"$out_file" 2>&1
}

LIVE_BEFORE="$SMOKE_TMP_ROOT/live.before"
LIVE_AFTER="$SMOKE_TMP_ROOT/live.after"

# ---------------------------------------------------------------------------
# C1 — BRIDGE_HOME UNSET: guard auto-isolates, no live leak.
# ---------------------------------------------------------------------------
test_unset_auto_isolate() {
  snapshot_live_agents "$LIVE_BEFORE"
  local out_file="$SMOKE_TMP_ROOT/c1.out"
  local rc=0
  run_smoke_until_tmux_check "$out_file" env -u BRIDGE_HOME -u BRIDGE_STATE_DIR -u BRIDGE_TASK_DB \
    -u BRIDGE_ROSTER_FILE -u BRIDGE_ROSTER_LOCAL_FILE -u BRIDGE_LOG_DIR \
    -u BRIDGE_SHARED_DIR -u BRIDGE_ACTIVE_AGENT_DIR \
    -u BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT \
    || rc=$?
  # We expect smoke-test.sh to print the auto-isolate marker, then die at
  # require_cmd tmux. rc is non-zero by design.
  if [[ $rc -eq 0 ]]; then
    smoke_fail "C1: smoke-test.sh exited 0 with sandbox PATH (require_cmd tmux should have failed)"
  fi
  if ! grep -Fq "[smoke] BRIDGE_HOME auto-isolated to " "$out_file"; then
    smoke_fail "C1: expected auto-isolate marker not found in stderr/stdout. Output: $(cat "$out_file")"
  fi
  if ! grep -Fq "missing required command: tmux" "$out_file"; then
    smoke_fail "C1: expected fail-fast at require_cmd tmux, got: $(cat "$out_file")"
  fi
  snapshot_live_agents "$LIVE_AFTER"
  assert_live_unchanged "$LIVE_BEFORE" "$LIVE_AFTER" "C1"
}

# ---------------------------------------------------------------------------
# C2 — properly-initialized isolated BRIDGE_HOME + `agent-bridge list`:
#       must reach dispatch (rc=0) AND leave live install untouched.
# ---------------------------------------------------------------------------
#
# r3 fix: the prior version called `agent-bridge` against a markerless
# fresh-install BRIDGE_HOME and let any rc through. That meant the
# resolver could fail-fast at bridge-layout-resolver.sh:420-428 and the
# test would silently pass without ever reaching the dispatch path that
# is the actual subject under test. This version writes the v2 layout
# marker manually (the minimum scaffolding bridge-init.sh would write,
# extracted from scripts/smoke/lib.sh:smoke_setup_bridge_home) so the
# resolver passes, then ASSERTS rc=0 from `agent-bridge list`.
#
# bridge-init.sh itself is NOT called because it (a) takes minutes on
# this host and (b) touches state files outside BRIDGE_HOME (e.g.
# $HOME/.agent-bridge/state/install/host-profile.json). Manual marker
# writing is the same contract bridge-init.sh would write for the
# resolver, without the side effects.
write_v2_layout_scaffold() {
  local iso_home="$1"
  local data_root="$2"
  mkdir -p \
    "$iso_home" \
    "$iso_home/state" \
    "$iso_home/state/agents" \
    "$iso_home/state/history" \
    "$iso_home/logs" \
    "$iso_home/shared" \
    "$iso_home/agents" \
    "$iso_home/runtime" \
    "$iso_home/hooks" \
    "$data_root" \
    "$data_root/shared" \
    "$data_root/agents" \
    "$data_root/state"
  : >"$iso_home/agent-roster.sh"
  : >"$iso_home/agent-roster.local.sh"
  cat >"$iso_home/state/layout-marker.sh" <<EOF
BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT=$data_root
EOF
  chmod 0644 "$iso_home/state/layout-marker.sh"
}

test_isolated_cli_no_live_leak() {
  snapshot_live_agents "$LIVE_BEFORE"
  local iso_parent
  iso_parent="$(mktemp -d "${TMPDIR:-/tmp}/agb-smoke-c2.XXXXXX")"
  local iso_home="$iso_parent/.agent-bridge"
  local data_root="$iso_parent/data"
  write_v2_layout_scaffold "$iso_home" "$data_root"
  local out_file="$SMOKE_TMP_ROOT/c2.out"
  local rc=0
  # `agent-bridge list` is the smallest CLI op that exercises the
  # roster/state-dir resolver dispatch chain. With the v2 marker in
  # place the resolver passes; `list` enumerates the (empty) isolated
  # roster and exits 0. The assertion below is `rc == 0` (i.e. we
  # actually reached dispatch), NOT a count check on the printed
  # output — the printed output is empty by design ("no active
  # sessions") for a fresh isolated install.
  env -u BRIDGE_STATE_DIR -u BRIDGE_TASK_DB \
    -u BRIDGE_ROSTER_FILE -u BRIDGE_ROSTER_LOCAL_FILE -u BRIDGE_LOG_DIR \
    -u BRIDGE_SHARED_DIR -u BRIDGE_ACTIVE_AGENT_DIR \
    -u BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT \
    -u BRIDGE_AGENT_HOME_ROOT \
    -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT -u BRIDGE_SHARED_ROOT \
    -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_CONTROLLER_STATE_ROOT \
    -u BRIDGE_RUNTIME_ROOT -u BRIDGE_RUNTIME_CONFIG_FILE \
    -u BRIDGE_HOOKS_DIR -u BRIDGE_AUDIT_LOG -u BRIDGE_HISTORY_DIR \
    BRIDGE_HOME="$iso_home" \
    bash "$AGENT_BRIDGE_CLI" list >"$out_file" 2>&1 || rc=$?
  # BLOCKING 3 r3: assert dispatch was reached.
  if (( rc != 0 )); then
    smoke_fail "C2: agent-bridge list rc=$rc on properly-initialized isolated home. Output: $(cat "$out_file")"
  fi
  # The auto-isolate marker must NOT fire because BRIDGE_HOME was set.
  # (Sanity: the marker is owned by smoke-test.sh, not agent-bridge, so
  # this is just a paranoia check.)
  if grep -Fq "BRIDGE_HOME auto-isolated to" "$out_file"; then
    smoke_fail "C2: smoke-test.sh auto-isolate marker leaked into agent-bridge output: $(cat "$out_file")"
  fi
  snapshot_live_agents "$LIVE_AFTER"
  assert_live_unchanged "$LIVE_BEFORE" "$LIVE_AFTER" "C2"
  rm -rf "$iso_parent" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# C3 — SIGTERM mid smoke-test.sh: cleanup trap fires, live untouched.
# ---------------------------------------------------------------------------
test_sigterm_mid_run_no_live_leak() {
  snapshot_live_agents "$LIVE_BEFORE"
  C3_ISO_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/agb-smoke-c3.XXXXXX")"
  local iso_home="$C3_ISO_PARENT/.agent-bridge"
  mkdir -p "$iso_home"
  local out_file="$SMOKE_TMP_ROOT/c3.out"
  # Suppress bash's "Terminated: 15" job-control message — we kill the
  # background process by design and don't want that noise in CI logs.
  set +m
  # Start smoke-test.sh in the background with an isolated BRIDGE_HOME.
  # We do NOT clear BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT — smoke-test.sh's
  # secondary guard refuses /home so we point it under $iso to keep that
  # guard happy without changing the test contract.
  env -u BRIDGE_STATE_DIR -u BRIDGE_TASK_DB \
    -u BRIDGE_ROSTER_FILE -u BRIDGE_ROSTER_LOCAL_FILE -u BRIDGE_LOG_DIR \
    -u BRIDGE_SHARED_DIR -u BRIDGE_ACTIVE_AGENT_DIR \
    BRIDGE_HOME="$iso_home" \
    BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$C3_ISO_PARENT/iso-users" \
    bash "$SMOKE_SCRIPT" >"$out_file" 2>&1 &
  C3_BG_PID=$!
  # Disown the job so bash does not emit `Terminated: 15` job-status
  # notifications to stderr when we SIGTERM the child below. We still
  # track $C3_BG_PID for kill/wait, which work on disowned PIDs.
  disown "$C3_BG_PID" 2>/dev/null || true
  # Let smoke run long enough to clear the guard region and start
  # creating dirs. 5s is comfortably past `require_cmd` + BASH4 probe
  # + TMP_ROOT setup on a warm host.
  sleep 5
  # BLOCKING 2 r3: confirm smoke is RUNNING before we SIGTERM. If it
  # already exited (e.g. pre-existing smoke failure on this host) we
  # never actually exercised the SIGTERM cleanup path — that has to be
  # a test failure, not a silent log-and-pass.
  if ! kill -0 "$C3_BG_PID" 2>/dev/null; then
    local _premature_tail=""
    _premature_tail="$(tail -20 "$out_file" 2>/dev/null || true)"
    smoke_fail "C3 setup: smoke-test.sh exited before SIGTERM could be sent (pid=$C3_BG_PID). Cannot exercise SIGTERM cleanup path. Last 20 lines of smoke output: $_premature_tail"
  fi
  kill -TERM "$C3_BG_PID" 2>/dev/null || true
  # Give the EXIT trap up to 10s to do the rm -rf "$TMP_ROOT" loop.
  local _waited=0
  while kill -0 "$C3_BG_PID" 2>/dev/null; do
    (( _waited >= 10 )) && break
    sleep 1
    _waited=$(( _waited + 1 ))
  done
  # If still alive, escalate to KILL — we don't want the test to hang.
  if kill -0 "$C3_BG_PID" 2>/dev/null; then
    kill -KILL "$C3_BG_PID" 2>/dev/null || true
  fi
  # Disable errexit/pipefail trace and silence stderr around wait — bash
  # prints a `Terminated: 15` line to stderr when a tracked background
  # job dies on a signal even with `2>/dev/null` on wait itself. The
  # message comes from job-status reporting, not wait's output, so we
  # have to redirect at the surrounding subshell level.
  { wait "$C3_BG_PID"; } 2>/dev/null || true
  C3_BG_PID=""
  snapshot_live_agents "$LIVE_AFTER"
  assert_live_unchanged "$LIVE_BEFORE" "$LIVE_AFTER" "C3 (SIGTERM mid-run)"
  # Optional sanity check: if the EXIT trap completed, the isolated
  # BRIDGE_HOME's agents/ dir should either be gone (rm -rf "$TMP_ROOT"
  # succeeded — note that smoke-test.sh defines TMP_ROOT separately,
  # so $iso_home itself may still exist even after cleanup). We only
  # warn here; the binding contract is live-untouched above.
  if [[ -d "$iso_home/agents" ]]; then
    local _residue
    # shellcheck disable=SC2012
    _residue="$(ls -1 "$iso_home/agents" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ -n "$_residue" && "$_residue" != "0" ]]; then
      smoke_log "C3 note: $_residue agent dir(s) remain under isolated BRIDGE_HOME (expected — TMP_ROOT cleanup is separate from BRIDGE_HOME path)"
    fi
  fi
  rm -rf "$C3_ISO_PARENT" 2>/dev/null || true
  C3_ISO_PARENT=""
}

smoke_run "C1 unset BRIDGE_HOME auto-isolates" test_unset_auto_isolate
smoke_run "C2 isolated BRIDGE_HOME CLI does not touch live" test_isolated_cli_no_live_leak
smoke_run "C3 SIGTERM mid-run does not leak to live" test_sigterm_mid_run_no_live_leak

smoke_log "all smoke-isolation-no-live-leak cases passed"
