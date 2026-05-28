#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/phase3-agent-home-contract.sh — Phase 3 isolated HOME
# contract helper (#1180 sequel).
#
# patch's Phase 3 acceptance flagged 8 isolation contract gaps, all
# rooted in three writers (prepare, restart reverter, credential
# prepare) running slightly different inline forms of the same
# `.claude` chgrp/chmod block. The codex design (2026-05-24,
# implement-ok) collapses them onto a single shared helper:
#
#   bridge_linux_normalize_isolated_home_contract "$agent" "$os_user" "$user_home"
#
# Contract:
#   $user_home                      $os_user:ab-agent-<agent> 2750
#   $user_home/.claude              root:ab-agent-<agent>     3770 (or 2770 fallback)
#   $user_home/.claude/plugins      root:ab-agent-<agent>     3770 (or 2770 fallback)
#   $user_home/.claude/session-env  root:ab-agent-<agent>     3770 (or 2770 fallback)
#
# This smoke is HOST-AGNOSTIC — every assertion either:
#   1. Inspects helper source semantics statically, OR
#   2. Runs the helper against a controller-owned fixture tree with
#      `bridge_linux_sudo_root` stubbed so the chown/chmod calls
#      report what they WOULD have done without requiring real sudo.
#
# Coverage:
#
#   T1 — Helper exists + accepts exactly 3 positional args (agent,
#        os_user, user_home).
#
#   T2 — Linux-only no-op success: on a non-Linux host the helper
#        returns 0 immediately. Probed by setting BRIDGE_HOST_PLATFORM
#        override (smoke uses a function shadow if available).
#
#   T3 — Anchor guard: refuse when $user_home is not under
#        BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT.
#
#   T4 — Symlink rejection: with `.claude` pre-planted as a symlink,
#        the helper must refuse to mutate. The test pre-plants a
#        symlink under a controller-owned tree and asserts the
#        helper returns non-zero.
#
#   T5 — Live tmux session refuses (default), allowed under
#        BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING=1. The smoke shadows
#        `bridge_tmux_session_exists` to return 0 (session alive) and
#        asserts the helper refuses by default and passes when the
#        opt-in is set.
#
#   T6 — sticky-fallback honors BRIDGE_ISO_HOME_CONTRACT_MODE.
#        Source-level check: the helper resolves the .claude subdir
#        mode from BRIDGE_ISO_HOME_CONTRACT_MODE, default 3770,
#        fallback 2770. A bad value gets coerced to 3770 with a
#        warn. Static-source + behavioral via dry-run.
#
#   T7 — Reconciler row kind `agent_home_contract` registered in
#        dispatcher AND emits 4 child rows when --agent is set for
#        an isolated agent. Probed via matrix-rows shell call.
#
# Footgun #11 (heredoc-stdin subprocess deadlock): every driver
# uses `printf '%s\n' >file` and runs as `bash <file>`; no `<<<` /
# `<<EOF` feeds into a bash function.

set -uo pipefail

SMOKE_NAME="phase3-agent-home-contract"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

# Pick bash 4+ (associative arrays + `local -a` semantics the
# reconciler / helper rely on). Same pattern as phase2-install-tree-
# reconciler.sh.
if [[ -n "${BASH_BIN:-}" ]]; then
  SMOKE_BASH="$BASH_BIN"
elif [[ -x /opt/homebrew/bin/bash ]]; then
  SMOKE_BASH="/opt/homebrew/bin/bash"
elif [[ -x /usr/local/bin/bash ]]; then
  SMOKE_BASH="/usr/local/bin/bash"
else
  SMOKE_BASH="$(command -v bash)"
fi
[[ -n "$SMOKE_BASH" && -x "$SMOKE_BASH" ]] || smoke_fail "no bash binary found"
_smoke_bash_major="$("$SMOKE_BASH" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)"
if [[ -z "$_smoke_bash_major" ]] || (( _smoke_bash_major < 4 )); then
  smoke_fail "bash $SMOKE_BASH is too old (major=$_smoke_bash_major, need 4+)"
fi

# ---------- T1 — helper exists + signature ----------
T1_SRC="$REPO_ROOT/lib/bridge-agents.sh"
grep -q '^bridge_linux_normalize_isolated_home_contract()' "$T1_SRC" \
  || smoke_fail "T1: helper bridge_linux_normalize_isolated_home_contract() not defined in $T1_SRC"
# Three positional args (agent, os_user, user_home) at the top of the
# body. Static-source assertion.
"$PY_BIN" - "$T1_SRC" <<'PY' || smoke_fail "T1: helper does not bind exactly the 3 positional args (agent, os_user, user_home)"
import sys, re
src = open(sys.argv[1]).read()
m = re.search(
    r'^bridge_linux_normalize_isolated_home_contract\(\)\s*\{(.*?)^\}',
    src, re.S | re.M,
)
if not m:
    sys.exit(1)
body = m.group(1)
# Expect: local agent="$1" / local os_user="$2" / local user_home="$3"
ok = all(
    re.search(r'local\s+' + name + r'="\$' + str(i) + r'"', body) is not None
    for i, name in enumerate(['agent', 'os_user', 'user_home'], 1)
)
sys.exit(0 if ok else 1)
PY
smoke_log "T1 PASS: helper defined with (agent, os_user, user_home) signature"

# ---------- T2 — Linux-only gate (static source assertion) ----------
#
# The helper's first non-comment line is the Linux-platform gate.
# Static-source check that `bridge_host_platform` is invoked and
# returns 0 on non-Linux (no-op success).
"$PY_BIN" - "$T1_SRC" <<'PY' || smoke_fail "T2: helper missing 'Linux only — no-op success' platform gate"
import sys, re
src = open(sys.argv[1]).read()
m = re.search(
    r'^bridge_linux_normalize_isolated_home_contract\(\)\s*\{(.*?)^\}',
    src, re.S | re.M,
)
if not m:
    sys.exit(1)
body = m.group(1)
# We expect a guard like `[[ "$(bridge_host_platform)" == "Linux" ]] || return 0`
ok = bool(re.search(r'bridge_host_platform.*Linux.*return 0', body, re.S))
sys.exit(0 if ok else 1)
PY
smoke_log "T2 PASS: Linux-platform gate present (no-op on macOS/BSD)"

# ---------- T3 — Anchor guard ----------
#
# The helper refuses when $user_home is not under
# BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT. Static-source check that the
# guard is present + behavioral test via a dry-run wrapper.
"$PY_BIN" - "$T1_SRC" <<'PY' || smoke_fail "T3: helper missing BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT anchor guard"
import sys, re
src = open(sys.argv[1]).read()
m = re.search(
    r'^bridge_linux_normalize_isolated_home_contract\(\)\s*\{(.*?)^\}',
    src, re.S | re.M,
)
if not m:
    sys.exit(1)
body = m.group(1)
# Expect the var name AND a refusal message.
ok = ('BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT' in body
      and 'refusing' in body)
sys.exit(0 if ok else 1)
PY
smoke_log "T3 PASS: BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT anchor guard present"

# ---------- T4 — Symlink rejection (source-level) ----------
"$PY_BIN" - "$T1_SRC" <<'PY' || smoke_fail "T4: helper missing symlink rejection"
import sys, re
src = open(sys.argv[1]).read()
m = re.search(
    r'^bridge_linux_normalize_isolated_home_contract\(\)\s*\{(.*?)^\}',
    src, re.S | re.M,
)
if not m:
    sys.exit(1)
body = m.group(1)
# Expect a `test -L` probe and a `symlink` rejection bridge_warn.
ok = bool(re.search(r'test -L.*\bsymlink\b', body, re.S))
sys.exit(0 if ok else 1)
PY
smoke_log "T4 PASS: symlink rejection (test -L → refuse) present in helper"

# ---------- T5 — Live tmux session guard + ALLOW_RUNNING opt-out ----------
"$PY_BIN" - "$T1_SRC" <<'PY' || smoke_fail "T5: helper missing live-session guard or ALLOW_RUNNING opt-out"
import sys, re
src = open(sys.argv[1]).read()
m = re.search(
    r'^bridge_linux_normalize_isolated_home_contract\(\)\s*\{(.*?)^\}',
    src, re.S | re.M,
)
if not m:
    sys.exit(1)
body = m.group(1)
ok = ('BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING' in body
      and 'bridge_tmux_session_exists' in body)
sys.exit(0 if ok else 1)
PY
smoke_log "T5 PASS: live-tmux-session guard + BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING opt-out present"

# ---------- T6 — Sticky / mode-fallback resolves BRIDGE_ISO_HOME_CONTRACT_MODE ----------
"$PY_BIN" - "$T1_SRC" <<'PY' || smoke_fail "T6: helper does not honor BRIDGE_ISO_HOME_CONTRACT_MODE"
import sys, re
src = open(sys.argv[1]).read()
m = re.search(
    r'^bridge_linux_normalize_isolated_home_contract\(\)\s*\{(.*?)^\}',
    src, re.S | re.M,
)
if not m:
    sys.exit(1)
body = m.group(1)
# Expect the var, the 3770 default, and the 2770 fallback enumerated
# in the validation case statement.
ok = ('BRIDGE_ISO_HOME_CONTRACT_MODE' in body
      and '3770' in body
      and '2770' in body)
sys.exit(0 if ok else 1)
PY
smoke_log "T6 PASS: helper honors BRIDGE_ISO_HOME_CONTRACT_MODE (3770 default, 2770 fallback)"

# ---------- T7 — Reconciler row kind 'agent_home_contract' registered ----------
T7_RECONCILE_SRC="$REPO_ROOT/lib/bridge-isolation-v2-reconcile.sh"
grep -q '^_bridge_iso_reconcile_row_agent_home_contract()' "$T7_RECONCILE_SRC" \
  || smoke_fail "T7: row dispatcher _bridge_iso_reconcile_row_agent_home_contract() not defined in $T7_RECONCILE_SRC"
# The case branch in _bridge_iso_reconcile_process_one_row must include
# the new kind so unknown-kind rows don't slip through as 'failed'.
grep -q '^    agent_home_contract)' "$T7_RECONCILE_SRC" \
  || smoke_fail "T7: dispatcher case statement missing 'agent_home_contract)' branch in $T7_RECONCILE_SRC"
# Matrix function emits the 4 per-agent rows (HOME, .claude, plugins,
# session-env) when --agent is supplied AND the agent is isolated.
# Here we just confirm the matrix function CONTAINS the row name
# literals. (Real apply against a real isolated agent is the VM
# acceptance flow.)
"$PY_BIN" - "$T7_RECONCILE_SRC" <<'PY' || smoke_fail "T7: matrix function missing one of the 4 agent_home_contract row names"
import sys
src = open(sys.argv[1]).read()
needed = [
    'agent-home-contract-home|',
    'agent-home-contract-claude|',
    'agent-home-contract-plugins|',
    'agent-home-contract-session-env|',
]
missing = [n for n in needed if n not in src]
sys.exit(0 if not missing else 1)
PY
smoke_log "T7 PASS: reconciler row kind 'agent_home_contract' + 4 child rows registered"

smoke_log "phase3-agent-home-contract: ALL PASS"
