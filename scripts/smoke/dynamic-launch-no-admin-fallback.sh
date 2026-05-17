#!/usr/bin/env bash
# scripts/smoke/dynamic-launch-no-admin-fallback.sh — task #4813 regression.
#
# `agent-bridge --claude --name <new-dynamic-name> --no-attach` must
# create a new dynamic worker named `<new-dynamic-name>` regardless of
# whether the cwd's project_root happens to host a static role for the
# same engine. Before this fix, the non-TTY branch of the project-static
# candidate dispatch silently defaulted `SPAWN_PREFERENCE=wake` whenever
# `STATIC_CANDIDATES` contained exactly one entry, and then woke that
# static role instead of the operator's named dynamic worker:
#
#   $ agent-bridge --claude --name shopicode --no-attach
#   [info] 새 dynamic worker 'shopicode' 대신 정적 역할 'patch'를 깨웁니다.
#   [info] 세션 'patch'이 이미 실행 중입니다.
#
# The operator's explicit `--name shopicode` was dropped on the floor.
# The workaround was to spawn from a workdir outside the project (where
# STATIC_CANDIDATES is empty), which makes the normal in-project dynamic
# spawn UX painful enough that operators stopped using it.
#
# After the fix: the non-TTY default is `shared` (the operator gets a new
# dynamic worker on the current checkout). `--prefer wake` / `--prefer
# new` are still honored for operators who explicitly want the static
# wake or an isolated worktree. The TTY interactive picker is unchanged.
#
# Strategy: drive the actual `agent-bridge` wrapper end-to-end inside an
# isolated `BRIDGE_HOME`. The dispatch decision under test prints the
# hijack marker `대신 정적 역할 'patch'를 깨웁니다` BEFORE invoking
# `start_static_agent` (agent-bridge:1141). Downstream
# `bridge-daemon.sh ensure` + `bridge-start.sh patch` will hang in the
# smoke environment (no live daemon, no real tmux); we don't care — we
# bound each invocation with `timeout` and assert on the hijack
# marker's presence/absence. The assertion is deterministic because
# the marker is printed at the dispatch decision point, well before
# any downstream call could time out.
#
# Three cases asserted (all `--no-attach`, which is the production
# invocation shape from the bug report):
#   C1: admin static role present + spawn `--name new-dynamic-xyz` →
#       must NOT emit the hijack marker.
#   C2: BRIDGE_ADMIN_AGENT_ID unset + same spawn → same result. The
#       admin-fallback hypothesis from the brief is pinned here so a
#       future patch that couples admin-fallback to dispatch cannot
#       silently regress this case.
#   C3: tasks.db ghost row for the dynamic name + same spawn → still
#       must NOT emit the hijack marker. The dispatch path does not
#       consult tasks.db.
#
# Positive control: `--prefer wake` (operator opted in) MUST still
# emit the hijack marker — confirms the fix only removed the silent
# default, not the operator-opt-in path.

set -uo pipefail

SMOKE_NAME="dynamic-launch-no-admin-fallback"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  # r6 (codex PR #955 r5, P1 BLOCKING): r5 invoked
  # `bridge-daemon.sh stop --force` here, but cmd_stop calls
  # `bridge_daemon_all_pids` (lib/bridge-state.sh:3264-3292) which
  # pgrep-sweeps every same-user `bridge-daemon.sh run$` process
  # regardless of BRIDGE_HOME. The operator's live daemon (against
  # `~/.agent-bridge`) and this smoke's temp daemon (against
  # `SMOKE_TMP_ROOT/bridge-home`) BOTH match — calling `stop --force`
  # from the smoke would kill the operator's live daemon. That is
  # strictly worse than the r4 leak it was meant to fix (a stale temp
  # daemon is harmless; killing the live daemon mid-session is not).
  #
  # r6: bypass `bridge-daemon.sh stop` entirely. Kill ONLY the temp
  # tree's pids by reading them directly from their pid files. The pid
  # paths are derived from BRIDGE_STATE_DIR (smoke_setup_bridge_home
  # pins that to the temp root), so this is guaranteed scoped to the
  # temp tree — the operator's live daemon is provably untouched.
  #
  # Cover daemon.pid (which `cmd_stop` would have killed) and
  # silence-watchdog.pid (which `cmd_stop` killed via
  # `bridge_stop_silence_watchdog`). The Linux setsid-detached daemon
  # survives the 15s `timeout` wrapper exit, so we must STOP both
  # before smoke_cleanup_temp_root deletes BRIDGE_HOME.
  #
  # Guard on BRIDGE_STATE_DIR in case cleanup fires before
  # smoke_setup_bridge_home ran (early-exit path); the script runs
  # with `set -u`, so any unset reference here would itself crash
  # cleanup.
  if [[ -n "${BRIDGE_STATE_DIR:-}" && -d "${BRIDGE_STATE_DIR:-}" ]]; then
    local _pid_file _pid _i
    for _pid_file in \
      "${BRIDGE_DAEMON_PID_FILE:-$BRIDGE_STATE_DIR/daemon.pid}" \
      "$BRIDGE_STATE_DIR/silence-watchdog.pid"; do
      [[ -f "$_pid_file" ]] || continue
      _pid="$(cat "$_pid_file" 2>/dev/null || true)"
      if [[ -n "$_pid" && "$_pid" =~ ^[0-9]+$ ]] && kill -0 "$_pid" 2>/dev/null; then
        kill "$_pid" 2>/dev/null || true
        # TERM-then-KILL with a 1s grace window (5 × 200ms polls). The
        # daemon's signal handler should exit promptly; the KILL is the
        # safety net for the silence-watchdog if it has wedged.
        for _i in 1 2 3 4 5; do
          kill -0 "$_pid" 2>/dev/null || break
          sleep 0.2
        done
        kill -KILL "$_pid" 2>/dev/null || true
      fi
    done
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# r4 (codex PR #955 r3, P1 BLOCKING): smoke_setup_bridge_home re-exports
# the BRIDGE_HOME-derived paths it sets, but does not pre-unset other
# BRIDGE_* env vars that the caller's shell may already have exported
# from the live Agent Bridge install (e.g. when this smoke is run from
# an `agb`-managed agent session). Inherited values like
# BRIDGE_DAEMON_PID_FILE, BRIDGE_WORKTREE_ROOT, BRIDGE_DAEMON_LOG, etc.
# would still point at the operator's live `~/.agent-bridge` paths even
# though BRIDGE_HOME itself is now the temp root. agent-bridge →
# bridge-daemon.sh ensure consults BRIDGE_DAEMON_PID_FILE and would
# touch the live daemon.pid (cleanup, repair, or even kill of the
# operator's running daemon). Pin every derived path to the temp tree
# by unsetting first — the smoke library's subsequent `export` calls
# then take effect from a clean slate, and any path the library does
# not explicitly set falls back to its bridge-lib.sh default rooted at
# BRIDGE_HOME (which we have now pointed at the temp root).
#
# Keep this list in sync with `bridge_reject_ephemeral_controller_env_for_agent_env`
# in lib/bridge-agents.sh — that function enumerates every BRIDGE_*
# path the runtime materially depends on, so any new entry there is
# also a potential live-state leak vector here.
unset \
  BRIDGE_HOME \
  BRIDGE_ROSTER_FILE \
  BRIDGE_ROSTER_LOCAL_FILE \
  BRIDGE_STATE_DIR \
  BRIDGE_LAYOUT_MARKER_DIR \
  BRIDGE_ACTIVE_AGENT_DIR \
  BRIDGE_HISTORY_DIR \
  BRIDGE_WORKTREE_META_DIR \
  BRIDGE_ACTIVE_ROSTER_TSV \
  BRIDGE_ACTIVE_ROSTER_MD \
  BRIDGE_DAEMON_PID_FILE \
  BRIDGE_DAEMON_LOG \
  BRIDGE_DAEMON_CRASH_LOG \
  BRIDGE_TASK_DB \
  BRIDGE_PROFILE_STATE_DIR \
  BRIDGE_CRON_STATE_DIR \
  BRIDGE_CRON_HOME_DIR \
  BRIDGE_WORKTREE_ROOT \
  BRIDGE_AGENT_HOME_ROOT \
  BRIDGE_RUNTIME_ROOT \
  BRIDGE_RUNTIME_SCRIPTS_DIR \
  BRIDGE_RUNTIME_SKILLS_DIR \
  BRIDGE_RUNTIME_SHARED_DIR \
  BRIDGE_RUNTIME_SHARED_TOOLS_DIR \
  BRIDGE_RUNTIME_SHARED_REFERENCES_DIR \
  BRIDGE_RUNTIME_MEMORY_DIR \
  BRIDGE_RUNTIME_CREDENTIALS_DIR \
  BRIDGE_RUNTIME_SECRETS_DIR \
  BRIDGE_RUNTIME_CONFIG_FILE \
  BRIDGE_HOOKS_DIR \
  BRIDGE_SHARED_DIR \
  BRIDGE_TASK_NOTE_DIR \
  BRIDGE_LOG_DIR \
  BRIDGE_DATA_ROOT \
  BRIDGE_SHARED_ROOT \
  BRIDGE_AGENT_ROOT_V2 \
  BRIDGE_CONTROLLER_STATE_ROOT \
  BRIDGE_LAUNCHAGENT_LOG \
  BRIDGE_AUDIT_LOG \
  BRIDGE_LAYOUT
# Intentionally NOT unsetting BRIDGE_ADMIN_AGENT_ID here: that is an
# identifier (not a derived path) and C2 below specifically exercises
# the "explicitly unset in a subshell" shape. Pre-unsetting it would
# collapse C1 and C2 into the same case and weaken C1's
# inherited-from-controller-session coverage.

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Pick a Bash 4+ binary for the wrapper invocation. The wrapper re-execs
# itself on Bash 3, but routing via the right interpreter up front
# matches existing smokes (dynamic-agent-shared-mode-workdir.sh).
BASH4_BIN="${BRIDGE_BASH_BIN:-${BASH:-bash}}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

# The smoke must not touch the live operator install. `BRIDGE_DAEMON_LOG`
# is the one path that the resolver pulls from
# `$BRIDGE_STATE_DIR/launchagent.config` (bridge-lib.sh:196-218) when
# present, but `smoke_setup_bridge_home` already gives us an empty
# `BRIDGE_STATE_DIR`, so the resolver falls through to
# `$BRIDGE_STATE_DIR/daemon.log` — fully isolated. Pin the daemon log
# path explicitly anyway so a future bridge-lib change that adds a new
# launchagent-config lookup cannot leak the live daemon path.
export BRIDGE_DAEMON_LOG="$BRIDGE_STATE_DIR/daemon.log"

# Bound every wrapper invocation. The dispatch decision under test
# prints its marker line BEFORE the downstream daemon/start hang, so
# the timeout is just a safety net to keep the smoke deterministic
# even if a future agent-bridge change inserts a blocking call upstream
# of the marker line (which would itself be a regression worth
# catching).
INVOKE_TIMEOUT_SECONDS=15

# Resolve `timeout` portably. Homebrew's coreutils on macOS exposes
# the binary as `gtimeout`; existing smokes (e.g.
# skill-render-no-help-recursion.sh, 835-static-admin-launch.sh) walk
# this same fallback. Without it, an unconditional `timeout` call
# returns "command not found" rc before the wrapper runs, which
# causes the negative cases to pass on a shell error (smoke_assert_not_contains
# trivially succeeds against empty output) and the positive control
# to fail — silent green smoke on macOS dev hosts. Falls back to a
# bare invocation if neither binary is on PATH; a downstream hang
# would manifest as a smoke timeout from the test runner, which is
# strictly better than the silent-pass failure mode.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

# r3 (codex PR #955 r2): when neither timeout nor gtimeout is available
# (e.g. default macOS without coreutils), skip the smoke entirely instead
# of running agent-bridge unbounded. The negative cases drive paths that
# can hang after the dispatch decision, so an unbounded fallback would
# stall scripts/smoke-test.sh forever. Skipping is strictly safer than
# silent-pass — operators see the explicit message and install coreutils
# (brew install coreutils) to enable the smoke.
if [[ -z "$TIMEOUT_BIN" ]]; then
  smoke_log "SKIP: neither \`timeout\` nor \`gtimeout\` available (install via \`brew install coreutils\` on macOS) — smoke requires a portable timeout to bound runaway agent-bridge invocations safely"
  exit 0
fi

# ----------------------------------------------------------------------
# Fixture project + static `patch` roster entry.
# ----------------------------------------------------------------------

FAKE_PROJECT="$SMOKE_TMP_ROOT/fake-project"
mkdir -p "$FAKE_PROJECT"
# Initialize as a git repo so `bridge_project_root_for_path` returns the
# project root unambiguously (the production code path the bug fires on
# always involves a git project — the operator was in
# ~/Projects/agent-bridge-public when they hit the bug).
( cd "$FAKE_PROJECT" && git init --quiet >/dev/null 2>&1 ) || \
  smoke_fail "git init failed in $FAKE_PROJECT"

# Resolve the canonical project path the way `agent-bridge` does (line
# 1053 + `bridge_project_root_for_path`): `cd … && pwd -P` then
# `git rev-parse --show-toplevel`. The static-role workdir must match
# this exact path so `bridge_static_agents_for_project_engine` returns
# `patch`.
FAKE_PROJECT_CANON="$(cd "$FAKE_PROJECT" && git -C . rev-parse --show-toplevel | sed 's#/*$##')"

# Write a minimal local roster that registers a single static `patch`
# claude agent rooted at the fake project. The static agent need not
# exist on tmux — `bridge_static_agents_for_project_engine` only walks
# the in-memory roster maps, so a registration without a live session
# is enough to reproduce the bug preconditions.
cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
# shellcheck shell=bash
bridge_add_agent_id_if_missing patch
BRIDGE_AGENT_DESC[patch]='Admin static role for fake-project'
BRIDGE_AGENT_ENGINE[patch]='claude'
BRIDGE_AGENT_SESSION[patch]='patch'
BRIDGE_AGENT_WORKDIR[patch]='$FAKE_PROJECT_CANON'
BRIDGE_AGENT_SOURCE[patch]='static'
BRIDGE_AGENT_LOOP[patch]='0'
BRIDGE_AGENT_CONTINUE[patch]='1'
BRIDGE_AGENT_ISOLATION_MODE[patch]='shared'
EOF

# Helper: invoke the actual `agent-bridge` wrapper with the smoke's
# isolated env. Force non-TTY by redirecting stdin from /dev/null (the
# wrapper's `is_tty` check requires both -t 0 and -t 1; the explicit
# fd-0 redirect plus pipeline-captured fd-1 guarantees both are denied
# even when the smoke runs from an interactive terminal).
#
# Captures combined stdout+stderr to LAST_SPAWN_OUT and the wrapper's
# exit code (or `timeout`'s 124 on bound expiry) to LAST_SPAWN_RC.
# Both are populated as globals; the function itself always returns 0
# so the caller can sequence assertions without an interleaved `|| true`.
LAST_SPAWN_OUT=""
LAST_SPAWN_RC=0
run_spawn() {
  local agent_name="$1"
  shift
  local tmpfile
  tmpfile="$(mktemp "${SMOKE_TMP_ROOT}/run-spawn-out.XXXXXX")"
  local rc=0
  # r4 (codex PR #955 r3, P2): route through a tmpfile + explicit rc
  # capture so we can assert on BOTH the captured output and the wrapper
  # exit code. `$(...) || true` would discard rc, which is exactly the
  # gap codex flagged: a future regression that aborts the wrapper
  # before the dispatch decision would leave LAST_SPAWN_OUT empty and
  # silently pass the negative `assert_not_contains` checks. With rc
  # captured we can distinguish "timed out past the dispatch decision"
  # (rc=124, expected) from "wrapper bailed pre-dispatch" (rc != 124 +
  # rc != 0, regression).
  #
  # NOTE: `set -e` is OFF for this file (`set -uo pipefail` only, no
  # `-e`), but we still must not chain `|| rc=$?` directly onto the
  # multi-line `\` continuation — that breaks the line continuation
  # parse. Use a bare invocation followed by `rc=$?` captured on the
  # very next line; nothing must run between them.
  "$TIMEOUT_BIN" "$INVOKE_TIMEOUT_SECONDS" \
    "$BASH4_BIN" "$REPO_ROOT/agent-bridge" \
    --claude \
    --name "$agent_name" \
    --workdir "$FAKE_PROJECT_CANON" \
    --no-attach \
    "$@" </dev/null >"$tmpfile" 2>&1 || rc=$?
  LAST_SPAWN_OUT="$(cat "$tmpfile")"
  LAST_SPAWN_RC="$rc"
  rm -f "$tmpfile" >/dev/null 2>&1 || true
  return 0
}

# The exact hijack marker the wrapper prints at agent-bridge:1141 right
# before it invokes `start_static_agent`. If this string changes in the
# wrapper, the smoke must be updated in lockstep.
HIJACK_MARKER="대신 정적 역할 'patch'를 깨웁니다"

# r4 (codex PR #955 r3, P2): positive control for each should-spawn
# case. The negative `assert_not_contains` checks pass on ANY output
# that lacks the marker — including timeouts, env init failures, and
# regressions that abort the wrapper before the dispatch decision is
# reached. To distinguish "shared-dispatch correctly chose not to
# hijack" from "wrapper crashed pre-dispatch", assert the wrapper
# proceeded at least as far as the post-dispatch downstream stage.
#
# The wrapper's `bridge-daemon.sh ensure` invocation at
# agent-bridge:1218 hangs in the smoke environment (no live daemon, no
# real tmux), so a healthy non-hijack run hits the 15s `$TIMEOUT_BIN`
# bound and rc=124. The hijack branch routes into `start_static_agent`
# which in turn invokes `bridge-start.sh patch`, which also hangs →
# also rc=124. So rc=124 is the cross-branch signal for "wrapper got
# past the dispatch decision". Any other non-zero rc indicates the
# wrapper died early (e.g. roster load failure, missing helper, the
# new sanitize_stale_ephemeral_controller_env code path swallowing
# our env), which the smoke MUST flag.
#
# Why not assert on the per-agent active env file written at
# agent-bridge:1216 (`bridge_write_dynamic_agent_file`)? That side
# effect is materially later — on Bash 5.3.9 macOS the wrapper hits
# the footgun #11 heredoc-stdin deadlock inside
# `bridge_write_agent_state_file` (lib/bridge-state.sh, `content=$(cat
# <<EOF…)` pattern) BEFORE the file is created, so the file-existence
# assertion is brittle on the dev host even when dispatch behavior is
# correct. rc=124 is reliably observable on every Bash version because
# it comes from the `timeout` wrapper, not from the wrapper script.
assert_spawn_reached_post_dispatch() {
  local context="$1"
  # rc=0 (wrapper somehow finished cleanly) is acceptable too — it
  # would mean the smoke environment has enough plumbing to run the
  # whole wrapper to completion, which a regression-tightening test
  # would never want to reject. rc=124 is the expected case in the
  # current smoke environment.
  if [[ "$LAST_SPAWN_RC" != "124" && "$LAST_SPAWN_RC" != "0" ]]; then
    smoke_fail "$context: wrapper exited rc=$LAST_SPAWN_RC before reaching the post-dispatch downstream stage (expected rc=124 from \`$TIMEOUT_BIN $INVOKE_TIMEOUT_SECONDS\` or rc=0 from a complete run; non-124 non-zero indicates an early pre-dispatch failure that would let the negative HIJACK_MARKER check pass on empty output). Captured output: $LAST_SPAWN_OUT"
  fi
}

# ----------------------------------------------------------------------
# C1 — explicit `--name new-dynamic-xyz` must not hijack to `patch`.
# ----------------------------------------------------------------------

run_spawn "new-dynamic-xyz"
smoke_assert_not_contains "$LAST_SPAWN_OUT" "$HIJACK_MARKER" \
  "C1 (admin static present, non-TTY): wrapper must not redirect to static role 'patch'"
assert_spawn_reached_post_dispatch \
  "C1 (admin static present, non-TTY)"
smoke_log "C1 PASS"

# ----------------------------------------------------------------------
# C2 — same expectation with BRIDGE_ADMIN_AGENT_ID explicitly unset.
#
# Hypothesis from the brief: unset BRIDGE_ADMIN_AGENT_ID +
# bridge-init.sh fallback to `patch` is one suspected source of the
# hijack. The dispatch decision is unrelated to BRIDGE_ADMIN_AGENT_ID
# (it only looks at the roster + project_root match), but pinning the
# invariant here means a future "admin-fallback" patch cannot
# accidentally couple them.
# ----------------------------------------------------------------------

unset BRIDGE_ADMIN_AGENT_ID
run_spawn "new-dynamic-c2"
smoke_assert_not_contains "$LAST_SPAWN_OUT" "$HIJACK_MARKER" \
  "C2 (BRIDGE_ADMIN_AGENT_ID unset, non-TTY): wrapper must not redirect to static role"
assert_spawn_reached_post_dispatch \
  "C2 (BRIDGE_ADMIN_AGENT_ID unset, non-TTY)"
smoke_log "C2 PASS"

# ----------------------------------------------------------------------
# C3 — tasks.db ghost row for the operator's name must not trigger
# admin-fallback redirect.
#
# The brief hypothesizes that a stale tasks.db entry for a long-gone
# dynamic agent (the operator's `shopicode` from 11 days prior) could
# trip the admin redirect even after roster/registry are clean. The
# dispatch path does not consult tasks.db at all (it only walks the
# in-memory roster maps), so the ghost row is irrelevant. Pin that
# invariant: a future "smart" admin-fallback that reads tasks.db
# cannot silently regress this case.
# ----------------------------------------------------------------------

if command -v sqlite3 >/dev/null 2>&1; then
  mkdir -p "$(dirname "$BRIDGE_TASK_DB")"
  sqlite3 "$BRIDGE_TASK_DB" <<'SQL' >/dev/null 2>&1 || true
CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  to_agent TEXT,
  from_agent TEXT,
  title TEXT,
  body TEXT,
  state TEXT,
  created_at TEXT
);
INSERT INTO tasks (to_agent, from_agent, title, body, state, created_at)
VALUES ('ghost-agent', 'admin', 'ghost task', 'stale entry from prior dynamic spawn', 'queued', datetime('now'));
SQL
else
  smoke_log "C3: sqlite3 unavailable — running without seeded ghost row (the dispatch path doesn't consult tasks.db; the invariant still holds)"
fi

run_spawn "ghost-agent"
smoke_assert_not_contains "$LAST_SPAWN_OUT" "$HIJACK_MARKER" \
  "C3 (tasks.db ghost row, non-TTY): wrapper must not redirect to static role (dispatch ignores tasks.db)"
assert_spawn_reached_post_dispatch \
  "C3 (tasks.db ghost row, non-TTY)"
smoke_log "C3 PASS"

# ----------------------------------------------------------------------
# Positive control — `--prefer wake` still honored.
#
# Operators who explicitly opted into wake must continue to get the
# static-role wake behavior. Without this control, a sloppy fix could
# drop the wake branch entirely and break the supported explicit-wake
# UX.
# ----------------------------------------------------------------------

run_spawn "wake-target" --prefer wake
smoke_assert_contains "$LAST_SPAWN_OUT" "$HIJACK_MARKER" \
  "positive control: --prefer wake still redirects to the project static role (operator opted in)"
smoke_log "positive control PASS (--prefer wake)"

smoke_log "PASS — task #4813: explicit --name no longer silently hijacks to admin static role"
