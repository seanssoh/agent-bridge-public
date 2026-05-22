#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1028-isolated-workdir-check.sh — Issue #1028.
#
# Pins the contract that `bridge-start.sh`'s workdir-existence decision is
# privilege-aware for a linux-user isolated agent.
#
# The bug (#1028): for an isolated agent the agent root
# (`<data-root>/agents/<agent>/`) is `root:ab-agent-<agent>` mode 0750 and
# `workdir/` is 2770. The controller process is not in the agent group, so
# a plain `[[ -d "$WORK_DIR" ]]` cannot traverse the 0750 parent and
# false-negates even though `workdir/` exists. Result: every post-create
# `start_dry_run` for an isolated agent printed a spurious
#   [info] '<agent>' static workdir 누락, 자동 재생성: ...
#   [오류] workdir 자동 재생성 후에도 존재하지 않음: ...
# and reported `start_dry_run: warn (rc=1)` — a confusing false alarm even
# though the agent (incl. `workdir/`) was scaffolded correctly.
#
# The fix makes BOTH the upstream "is workdir missing" decision AND the
# post-regen re-check probe existence through `bridge_linux_sudo_root
# test -d` when the agent is a linux-user isolated agent. Non-isolated
# agents keep the plain `[[ -d ]]` controller-side test.
#
# Test plan (in-process bash — no live tmux / Claude / sudo). The smoke
# extracts just the workdir-check block from `bridge-start.sh` and drives
# it with stubbed `bridge_agent_linux_user_isolation_effective` +
# `bridge_linux_sudo_root` so the decision can be asserted on any host:
#
#   T1. Isolated agent, `workdir/` EXISTS but is unreadable to the
#       controller (plain `[[ -d ]]` would false-negate). The block must
#       NOT enter the regen branch — no spurious "누락" line, no
#       bridge_die, exit 0.
#   T2. Isolated agent, `workdir/` genuinely MISSING. The block enters the
#       regen branch, the sudo-handoff mkdir creates it, the privilege-
#       aware post-regen re-check passes, exit 0.
#   T3. Non-isolated agent, `workdir/` MISSING. The plain `[[ -d ]]` test
#       still routes into the default-home mkdir branch and materializes
#       it (the non-isolated path is unchanged by the fix).
#
# `bridge_linux_sudo_root` is stubbed to run the command directly (the
# smoke host is not root and has no ab-agent-* groups). The stub also
# records the `test -d` probe so the smoke can prove the privilege-aware
# branch — not the plain controller test — drove the decision.
#
# Footgun #11 (heredoc_write deadlock class): the driver is emitted with
# `printf '%s\n' >file` — no command substitution feeding heredoc-stdin,
# no `<<<` here-strings into bridge functions.

set -uo pipefail

SMOKE_NAME="1028-isolated-workdir-check"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# --- locate the workdir-check block in bridge-start.sh -----------------------
# The block is bounded by a stable comment anchor and the matching `fi`.
# Extracting by anchor (not a hard-coded line range) keeps the smoke from
# silently going stale if the surrounding script shifts.
BLOCK_START="$(grep -n '^# workdir existence: for a linux-user isolated agent' \
  "$REPO_ROOT/bridge-start.sh" | head -n1 | cut -d: -f1)"
[[ -n "$BLOCK_START" ]] \
  || smoke_fail "could not locate workdir-check block anchor in bridge-start.sh"
# The block ends at the first `^fi$` at or after the `if [[ $WORK_DIR_PRESENT`
# guard. Find that guard, then the next bare `fi`.
GUARD_LINE="$(grep -n '^if \[\[ \$WORK_DIR_PRESENT -eq 0 \]\]; then' \
  "$REPO_ROOT/bridge-start.sh" | head -n1 | cut -d: -f1)"
[[ -n "$GUARD_LINE" ]] \
  || smoke_fail "could not locate WORK_DIR_PRESENT guard in bridge-start.sh"
BLOCK_END="$(awk -v start="$GUARD_LINE" 'NR>=start && $0=="fi"{print NR; exit}' \
  "$REPO_ROOT/bridge-start.sh")"
[[ -n "$BLOCK_END" ]] \
  || smoke_fail "could not locate end of workdir-check block in bridge-start.sh"
smoke_log "extracting bridge-start.sh workdir-check block lines $BLOCK_START..$BLOCK_END"

BLOCK_FILE="$SMOKE_TMP_ROOT/workdir-check-block.sh"
sed -n "${BLOCK_START},${BLOCK_END}p" "$REPO_ROOT/bridge-start.sh" >"$BLOCK_FILE"

# --- driver builder ----------------------------------------------------------
# The driver stubs the privilege helpers + bridge_die, sets the small env
# the block reads ($AGENT, $WORK_DIR, $DEFAULT_WORK_DIR, $BRIDGE_AGENT_ROOT_V2),
# sources the extracted block, and reports the outcome on stdout.
write_driver_script() {
  local out="$1"

  : >"$out"
  local line
  for line in \
    '#!/usr/bin/env bash' \
    'set -uo pipefail' \
    'PROBE_LOG="$DRIVER_PROBE_LOG"' \
    ': >"$PROBE_LOG"' \
    '# bridge_die: record + abort the block (mimics the real fatal exit).' \
    'bridge_die() { echo "BRIDGE_DIE: $*"; exit 70; }' \
    '# Isolation predicate: ISO_EFFECTIVE=1 → isolated agent.' \
    'bridge_agent_linux_user_isolation_effective() {' \
    '  [[ "${ISO_EFFECTIVE:-0}" == "1" ]]' \
    '}' \
    '# sudo-handoff helper: record `test -d` probes so the smoke can prove' \
    '# the privilege-aware path drove the decision, then run the command' \
    '# directly (no sudo — smoke host is unprivileged).' \
    'bridge_linux_sudo_root() {' \
    '  if [[ "$1" == "test" ]]; then' \
    '    printf "PROBE %s\n" "$*" >>"$PROBE_LOG"' \
    '  fi' \
    '  "$@"' \
    '}' \
    'echo "=== block start ==="' \
    'source "$BLOCK_FILE"' \
    'echo "=== block end rc=$? ==="'
  do
    printf '%s\n' "$line" >>"$out"
  done
  chmod +x "$out"
}

DRIVER="$SMOKE_TMP_ROOT/driver.sh"
PROBE_LOG="$SMOKE_TMP_ROOT/probe.log"
write_driver_script "$DRIVER"

run_block() {
  # run_block <iso_effective> <agent> <work_dir> <default_work_dir> <v2_root>
  ISO_EFFECTIVE="$1" \
  AGENT="$2" \
  WORK_DIR="$3" \
  DEFAULT_WORK_DIR="$4" \
  BRIDGE_AGENT_ROOT_V2="$5" \
  BLOCK_FILE="$BLOCK_FILE" \
  DRIVER_PROBE_LOG="$PROBE_LOG" \
  "$BRIDGE_BASH" "$DRIVER" 2>&1
}

# --- T1: isolated agent, workdir EXISTS → no regen, no spurious 누락 ----------
smoke_log "T1: isolated agent with an existing workdir does not enter the regen/누락 branch"

T1_V2_ROOT="$SMOKE_TMP_ROOT/t1-v2"
T1_AGENT="iso_t1"
T1_WORKDIR="$T1_V2_ROOT/$T1_AGENT/workdir"
mkdir -p "$T1_WORKDIR"

T1_OUT="$(run_block 1 "$T1_AGENT" "$T1_WORKDIR" "$T1_V2_ROOT/$T1_AGENT/home" "$T1_V2_ROOT")"
T1_RC=$?

smoke_assert_eq "0" "$T1_RC" "T1: workdir-check block exits 0 for an isolated agent with an existing workdir"
smoke_assert_not_contains "$T1_OUT" "누락" \
  "T1: no spurious 'workdir 누락' info line when the workdir already exists"
smoke_assert_not_contains "$T1_OUT" "BRIDGE_DIE" \
  "T1: block does not false-die for an isolated agent whose workdir exists"
# Prove the decision went through the privilege-aware probe, not the plain
# controller `[[ -d ]]` test.
if ! grep -q "^PROBE test -d $T1_WORKDIR" "$PROBE_LOG"; then
  echo "--- probe log ---" >&2
  cat "$PROBE_LOG" >&2
  smoke_fail "T1: expected a 'bridge_linux_sudo_root test -d' probe for the isolated workdir"
fi
smoke_log "T1 PASS — isolated existing-workdir path is privilege-aware, no false alarm"

# --- T2: isolated agent, workdir MISSING → regen succeeds, no false-die ------
smoke_log "T2: isolated agent with a genuinely missing workdir is regenerated, post-regen re-check passes"

T2_V2_ROOT="$SMOKE_TMP_ROOT/t2-v2"
T2_AGENT="iso_t2"
T2_WORKDIR="$T2_V2_ROOT/$T2_AGENT/workdir"
mkdir -p "$T2_V2_ROOT/$T2_AGENT"   # parent exists; workdir/ deliberately absent
[[ ! -d "$T2_WORKDIR" ]] || smoke_fail "T2 pre-condition: workdir should not exist yet"

T2_OUT="$(run_block 1 "$T2_AGENT" "$T2_WORKDIR" "$T2_V2_ROOT/$T2_AGENT/home" "$T2_V2_ROOT")"
T2_RC=$?

smoke_assert_eq "0" "$T2_RC" "T2: workdir-check block exits 0 after regenerating a missing isolated workdir"
smoke_assert_contains "$T2_OUT" "누락" \
  "T2: a genuinely missing workdir still emits the '누락, 자동 재생성' info line"
smoke_assert_not_contains "$T2_OUT" "BRIDGE_DIE" \
  "T2: post-regen privilege-aware re-check does not false-die after the workdir is created"
[[ -d "$T2_WORKDIR" ]] || smoke_fail "T2: workdir was not created by the regen branch"
smoke_log "T2 PASS — genuine-missing path still regenerates and the re-check is privilege-aware"

# --- T3: non-isolated agent, workdir MISSING → plain path unchanged ----------
smoke_log "T3: non-isolated agent keeps the plain [[ -d ]] check and default-home mkdir"

T3_AGENT="shared_t3"
T3_DEFAULT_HOME="$SMOKE_TMP_ROOT/t3-default-home"
[[ ! -d "$T3_DEFAULT_HOME" ]] || smoke_fail "T3 pre-condition: default home should not exist yet"
: >"$PROBE_LOG"

# WORK_DIR == DEFAULT_WORK_DIR → the plain default-home mkdir branch.
T3_OUT="$(run_block 0 "$T3_AGENT" "$T3_DEFAULT_HOME" "$T3_DEFAULT_HOME" "$SMOKE_TMP_ROOT/t3-v2")"
T3_RC=$?

smoke_assert_eq "0" "$T3_RC" "T3: workdir-check block exits 0 for a non-isolated agent (plain mkdir branch)"
smoke_assert_not_contains "$T3_OUT" "BRIDGE_DIE" "T3: non-isolated path does not die"
[[ -d "$T3_DEFAULT_HOME" ]] || smoke_fail "T3: default home was not created by the plain mkdir branch"
# The non-isolated path must NOT route through the sudo-backed probe.
if grep -q '^PROBE ' "$PROBE_LOG"; then
  echo "--- probe log ---" >&2
  cat "$PROBE_LOG" >&2
  smoke_fail "T3: non-isolated agent must not invoke the privilege-aware sudo probe"
fi
smoke_log "T3 PASS — non-isolated path unchanged (plain controller-side check)"

smoke_log "all tests PASS — bridge-start.sh workdir-check is privilege-aware for isolated agents (#1028)"
exit 0
