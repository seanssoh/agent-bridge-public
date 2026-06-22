#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/68-live-leak-foreign-checkout-guard.sh
#
# Issue #68 (v0.16 safety class) — a wave-orchestration fixer / CI checkout
# isolates FILES (a git worktree) but INHERITS the controller env, so
# BRIDGE_HOME still points at the operator's LIVE `~/.agent-bridge`. A fixer
# that runs an individual daemon smoke (or `bridge-daemon.sh run` to reconcile
# a tick) DIRECTLY — bypassing scripts/smoke-test.sh's sandboxed harness — then
# ticks the LIVE runtime from a /private/tmp or .claude/worktrees scratch tree.
# On cleanup of that tree the live daemon's BRIDGE_SCRIPT_DIR dangles (#946
# cascade) and the operator's daemon goes down. This actually happened
# (2026-06-22 live-leak incident).
#
# The structural cure: a fail-closed guard at the daemon verb dispatch that
# REFUSES a state-mutating verb when the source checkout is TRANSIENT (mktemp /
# system tmp / fixer worktree) but BRIDGE_HOME is a PERSISTENT (real) install.
# Implemented in bridge-lib.sh as three composable functions:
#   bridge_path_is_transient        — classify a path
#   bridge_foreign_checkout_verdict — pure allow/refuse decision (args only)
#   bridge_guard_foreign_checkout   — enforcing wrapper (exit 3 + remediation)
# and wired into bridge-daemon.sh's `case "$CMD"` dispatch.
#
# This smoke proves, with no daemon tick and without touching the live home:
#   1. the transient classifier is correct across system-tmp / worktree / real
#      install paths (and empty);
#   2. the verdict refuses ONLY the leak signature and the decision is
#      non-vacuous — flipping the verb (run->status), the home (real->sandbox),
#      or the escape hatch each flips refuse->allow;
#   3. the enforcing wrapper fails closed (exit 3 + banner) on the leak and
#      lets the escape hatch through;
#   4. the guard is actually WIRED into the dispatch, BEFORE the verb case.

set -euo pipefail

SMOKE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
source "$SMOKE_DIR/lib.sh"

# bridge-lib.sh re-execs into a Bash 4+ shell when sourced under Bash <4
# (macOS /bin/bash 3.2). The re-exec replaces the process, so an inner
# `bash -c 'source bridge-lib.sh; ...'` run under 3.2 never reaches the test
# body. Pin a Bash 4+ interpreter for every inner subshell (mirrors the
# 1454-reexec-canary smoke).
BASH_BIN=""
for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
  if [[ -x "$_c" ]] && "$_c" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' 2>/dev/null; then
    BASH_BIN="$_c"; break
  fi
done
[[ -n "$BASH_BIN" ]] || smoke_fail "no Bash 4+ interpreter found (required to source bridge-lib.sh)"
LIB="$SMOKE_REPO_ROOT/bridge-lib.sh"
DAEMON="$SMOKE_REPO_ROOT/bridge-daemon.sh"
smoke_assert_file_exists "$LIB" "bridge-lib.sh present"
smoke_assert_file_exists "$DAEMON" "bridge-daemon.sh present"

# Belt-and-suspenders: even the pure-function subshells must never default
# BRIDGE_HOME to the operator's live runtime. Pin it at a sandbox up front.
smoke_make_temp_root "68-guard"
export BRIDGE_HOME="$SMOKE_TMP_ROOT/sandbox-home"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"

# ---------------------------------------------------------------------------
# 1 + 2: pure-function tables — sourced once, emit KEY=value lines.
# ---------------------------------------------------------------------------
PURE_OUT="$("$BASH_BIN" -c '
  source "'"$LIB"'" >/dev/null 2>&1
  t() { if bridge_path_is_transient "$1"; then printf "%s=transient\n" "$2"; else printf "%s=persistent\n" "$2"; fi; }
  v() { printf "%s=%s\n" "$4" "$(bridge_foreign_checkout_verdict "$1" "$2" "$3")"; }

  # transient classifier
  t "/tmp/agb-wt"                                              C_TMP
  t "/private/tmp/agb-clone"                                   C_PRIVTMP
  t "/var/tmp/agb-x"                                           C_VARTMP
  t "/var/folders/aa/bb/T/tmp.ABC/sandbox"                     C_VARFOLDERS
  t "/private/var/folders/aa/bb/T/agent-bridge-x.AB/stage"     C_PRIVVARFOLDERS
  t "/Users/op/Projects/agent-bridge-public/.claude/worktrees/agent-1" C_WORKTREE
  t "/Users/op/.agent-bridge/worktrees/agent-bridge-public-deadbeef/fixer" C_BRIDGE_WT
  t "/tmp/tmp.DEADBEEF"                                        C_MKTEMP
  t "/Users/op/.agent-bridge"                                  C_LIVE_MAC
  t "/home/op/.agent-bridge"                                   C_LIVE_LINUX
  t "/opt/agb-68-fake-live/.agent-bridge"                      C_OPT
  t "/home/op/.agent-bridge-source"                            C_SOURCE
  t ""                                                         C_EMPTY

  # verdict: refuse ONLY for state-mutating verb + transient src + persistent home
  v run     "/tmp/agb-wt"                  "/opt/agb-68-fake-live/.agent-bridge" V_LEAK_TMP
  v run     "/h/x/.claude/worktrees/agent-9" "/home/op/.agent-bridge"           V_LEAK_WT
  v run     "/Users/op/.agent-bridge/worktrees/proj/agent" "/Users/op/.agent-bridge" V_LEAK_BRIDGE_WT
  v run-cron-worker "/tmp/agb-wt"          "/opt/agb-68-fake-live/.agent-bridge" V_LEAK_CRON
  v ensure  "/private/tmp/agb-clone"       "/Users/op/.agent-bridge"            V_LEAK_ENSURE
  v restart "/tmp/agb-wt"                  "/home/op/.agent-bridge"             V_LEAK_RESTART
  v sync    "/tmp/agb-wt"                  "/home/op/.agent-bridge"             V_LEAK_SYNC
  v run     "/tmp/agb-wt"                  "/tmp/tmp.AAA/sandbox"               V_ISO_HOME
  v status  "/tmp/agb-wt"                  "/opt/agb-68-fake-live/.agent-bridge" V_STATUS
  v stop    "/tmp/agb-wt"                  "/opt/agb-68-fake-live/.agent-bridge" V_STOP
  v run     "/Users/op/Projects/agent-bridge-public" "/Users/op/.agent-bridge" V_DEV_SRC
  v sync    "/home/op/.agent-bridge-source" "/home/op/.agent-bridge"           V_UPGRADE_SRC
' 2>&1)"

# classifier
smoke_assert_contains "$PURE_OUT" "C_TMP=transient"         "/tmp is transient"
smoke_assert_contains "$PURE_OUT" "C_PRIVTMP=transient"     "/private/tmp is transient"
smoke_assert_contains "$PURE_OUT" "C_VARTMP=transient"      "/var/tmp is transient"
smoke_assert_contains "$PURE_OUT" "C_VARFOLDERS=transient"  "/var/folders (macOS TMPDIR) is transient"
smoke_assert_contains "$PURE_OUT" "C_PRIVVARFOLDERS=transient" "canonicalized /private/var/folders is transient (macOS cd -P)"
smoke_assert_contains "$PURE_OUT" "C_WORKTREE=transient"    ".claude/worktrees is transient"
smoke_assert_contains "$PURE_OUT" "C_BRIDGE_WT=transient"   "managed ~/.agent-bridge/worktrees checkout is transient (#68 codex r1)"
smoke_assert_contains "$PURE_OUT" "C_MKTEMP=transient"      "mktemp tmp.* root is transient"
smoke_assert_contains "$PURE_OUT" "C_LIVE_MAC=persistent"   "real macOS install is persistent"
smoke_assert_contains "$PURE_OUT" "C_LIVE_LINUX=persistent" "real Linux install is persistent"
smoke_assert_contains "$PURE_OUT" "C_OPT=persistent"        "/opt install is persistent"
smoke_assert_contains "$PURE_OUT" "C_SOURCE=persistent"     "source checkout is persistent"
smoke_assert_contains "$PURE_OUT" "C_EMPTY=persistent"      "empty path is treated as persistent (return 1)"

# verdict — the leak signature refuses
smoke_assert_contains "$PURE_OUT" "V_LEAK_TMP=refuse"      "run from /tmp -> live home refuses"
smoke_assert_contains "$PURE_OUT" "V_LEAK_WT=refuse"       "run from worktree -> live home refuses"
smoke_assert_contains "$PURE_OUT" "V_LEAK_BRIDGE_WT=refuse" "run from managed ~/.agent-bridge/worktrees -> live home refuses (#68 codex r1)"
smoke_assert_contains "$PURE_OUT" "V_LEAK_CRON=refuse"     "run-cron-worker is a gated mutating verb (#68 codex r1)"
smoke_assert_contains "$PURE_OUT" "V_LEAK_ENSURE=refuse"   "ensure is a mutating verb"
smoke_assert_contains "$PURE_OUT" "V_LEAK_RESTART=refuse"  "restart is a mutating verb"
smoke_assert_contains "$PURE_OUT" "V_LEAK_SYNC=refuse"     "sync is a mutating verb"
# verdict — non-vacuous: each lever flips refuse->allow
smoke_assert_contains "$PURE_OUT" "V_ISO_HOME=allow"      "transient home (isolated smoke) is allowed"
smoke_assert_contains "$PURE_OUT" "V_STATUS=allow"        "status is not gated"
smoke_assert_contains "$PURE_OUT" "V_STOP=allow"          "stop is not gated"
smoke_assert_contains "$PURE_OUT" "V_DEV_SRC=allow"       "persistent dev checkout is allowed"
smoke_assert_contains "$PURE_OUT" "V_UPGRADE_SRC=allow"   "persistent source checkout (upgrade) is allowed"

# An explicit BRIDGE_WORKTREE_ROOT under a NON-standard path (not matched by the
# ~/.agent-bridge/worktrees glob) must still classify a worker checkout transient.
WT_OVERRIDE_OUT="$(BRIDGE_WORKTREE_ROOT=/opt/custom-wt "$BASH_BIN" -c '
  source "'"$LIB"'" >/dev/null 2>&1
  if bridge_path_is_transient "/opt/custom-wt/proj/agent"; then printf "WTROOT=transient\n"; else printf "WTROOT=persistent\n"; fi
' 2>&1)"
smoke_assert_contains "$WT_OVERRIDE_OUT" "WTROOT=transient" "explicit BRIDGE_WORKTREE_ROOT worker path is transient (#68 codex r1)"

# ---------------------------------------------------------------------------
# 3: enforcing wrapper — refuse fails closed (exit 3); escape hatch passes.
# ---------------------------------------------------------------------------
ENFORCE_SCRIPT='
  source "'"$LIB"'" >/dev/null 2>&1
  BRIDGE_SCRIPT_DIR="/tmp/agb-fixer-worktree"
  BRIDGE_HOME="/opt/agb-68-fake-live/.agent-bridge"
  bridge_guard_foreign_checkout run
  printf "REACHED_AFTER_GUARD\n"
'
if E1_OUT="$("$BASH_BIN" -c "$ENFORCE_SCRIPT" 2>&1)"; then E1_RC=0; else E1_RC=$?; fi
smoke_assert_eq "3" "$E1_RC" "refuse path exits 3"
smoke_assert_contains "$E1_OUT" "live-leak guard" "refuse path prints the guard banner"
smoke_assert_contains "$E1_OUT" "BRIDGE_HOME=/opt/agb-68-fake-live/.agent-bridge" "refuse path names the live home"
smoke_assert_contains "$E1_OUT" "BRIDGE_SCRIPT_DIR=/tmp/agb-fixer-worktree" "refuse path names the transient checkout"
smoke_assert_not_contains "$E1_OUT" "REACHED_AFTER_GUARD" "refuse path halts before the verb runs"

if E2_OUT="$(BRIDGE_ALLOW_FOREIGN_CHECKOUT=1 "$BASH_BIN" -c "$ENFORCE_SCRIPT" 2>&1)"; then E2_RC=0; else E2_RC=$?; fi
smoke_assert_eq "0" "$E2_RC" "escape hatch returns 0"
smoke_assert_contains "$E2_OUT" "REACHED_AFTER_GUARD" "escape hatch reaches past the guard"
smoke_assert_not_contains "$E2_OUT" "live-leak guard" "escape hatch prints no refusal"

# ---------------------------------------------------------------------------
# 4: wiring — the guard call must precede the verb `case` in the dispatch.
# Static (line-position) check so it survives line-number churn but still
# fails if a mutation drops or misplaces the dispatch call.
# ---------------------------------------------------------------------------
GUARD_LN="$(grep -n 'bridge_guard_foreign_checkout "\$CMD"' "$DAEMON" | tail -1 | cut -d: -f1 || true)"
CASE_LN="$(grep -n '^case "\$CMD" in' "$DAEMON" | tail -1 | cut -d: -f1 || true)"
[[ -n "$GUARD_LN" ]] || smoke_fail "guard call bridge_guard_foreign_checkout \"\$CMD\" not found in $DAEMON"
[[ -n "$CASE_LN" ]] || smoke_fail "verb dispatch 'case \"\$CMD\" in' not found in $DAEMON"
(( GUARD_LN < CASE_LN )) || smoke_fail "guard (line $GUARD_LN) must be wired BEFORE the verb dispatch (line $CASE_LN)"

# The EARLY (raw-arg) guard must precede bridge_load_roster, so the refuse path
# fires before bridge_init_dirs mkdir's the live runtime dirs (#68 codex r1 #2).
EARLY_GUARD_LN="$(grep -n 'bridge_guard_foreign_checkout "\$_bridge_daemon_early_arg"' "$DAEMON" | head -1 | cut -d: -f1 || true)"
LOAD_ROSTER_LN="$(grep -n '^bridge_load_roster$' "$DAEMON" | head -1 | cut -d: -f1 || true)"
[[ -n "$EARLY_GUARD_LN" ]] || smoke_fail "early (pre-roster) guard not found in $DAEMON"
[[ -n "$LOAD_ROSTER_LN" ]] || smoke_fail "bridge_load_roster call not found in $DAEMON"
(( EARLY_GUARD_LN < LOAD_ROSTER_LN )) || smoke_fail "early guard (line $EARLY_GUARD_LN) must precede bridge_load_roster (line $LOAD_ROSTER_LN)"

# ---------------------------------------------------------------------------
# 5: fail-closed BEFORE any live mkdir (#68 codex r1 finding 2). Stage a
# runnable daemon tree under a TRANSIENT root, point BRIDGE_HOME at a
# PERSISTENT but EMPTY fake home, run `bridge-daemon.sh run`, and assert exit 3
# AND that the fake home stays empty — the guard fires before bridge_load_roster
# -> bridge_init_dirs creates state/logs/runtime/shared. This is the real
# dispatch (proves wiring) and never touches the operator's live home.
# ---------------------------------------------------------------------------
STAGE="$SMOKE_TMP_ROOT/stage"   # under SMOKE_TMP_ROOT (mktemp) => transient source
mkdir -p "$STAGE/scripts"
cp "$SMOKE_REPO_ROOT/bridge-daemon.sh" "$SMOKE_REPO_ROOT/bridge-lib.sh" "$STAGE/"
[[ -f "$SMOKE_REPO_ROOT/VERSION" ]] && cp "$SMOKE_REPO_ROOT/VERSION" "$STAGE/"
cp -R "$SMOKE_REPO_ROOT/lib" "$STAGE/lib"
cp -R "$SMOKE_REPO_ROOT/scripts/python-helpers" "$STAGE/scripts/python-helpers"
# Persistent (NOT transient) fake live home, created EMPTY. Under $HOME so the
# classifier treats it as a real install; removed after the assertions.
FAKE_LIVE="$HOME/.cache/agb-68-fakelive.$$"
rm -rf "$FAKE_LIVE"; mkdir -p "$FAKE_LIVE"
if STAGE_OUT="$(BRIDGE_HOME="$FAKE_LIVE" BRIDGE_STATE_DIR="$FAKE_LIVE/state" "$BASH_BIN" "$STAGE/bridge-daemon.sh" run 2>&1)"; then STAGE_RC=0; else STAGE_RC=$?; fi
STAGE_ENTRIES="$(find "$FAKE_LIVE" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$FAKE_LIVE"
smoke_assert_eq "3" "$STAGE_RC" "real bridge-daemon.sh run from a transient checkout vs persistent home exits 3"
smoke_assert_contains "$STAGE_OUT" "live-leak guard" "staged refuse prints the guard banner"
smoke_assert_eq "0" "$STAGE_ENTRIES" "refuse path created NO entries in the live home (proves guard precedes bridge_init_dirs)"

smoke_cleanup_temp_root || true
smoke_log "PASS: #68 live-leak foreign-checkout guard (classifier + verdict + enforce + wiring + pre-mkdir)"
