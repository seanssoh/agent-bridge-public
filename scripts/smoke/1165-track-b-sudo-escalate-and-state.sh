#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1165-track-b-sudo-escalate-and-state.sh — Issue #1165 Track B.
#
# Pins the two code-level fixes that close Gaps 5 and 6 of #1165
# (linux-user isolation × Teams plugin contract gaps). Same family as
# #1145 / #1155 (controller direct touch on isolated tree) and #1149 /
# #1153 (sudo-escalate paradigm for v2 read paths).
#
# Gap 5 — `bridge_agent_runtime_channel_status_reason` calls
# `[[ ! -f "$teams_dir/access.json" ]]` from the controller. Under
# linux-user isolation v2 the workdir is chowned to the isolated UID with
# mode 2750/0700, so the controller's direct `[[ -f ]]` test false-
# negatives and the readiness gate emits "missing Teams access file"
# even when the file is present. Same pattern at the Discord, Telegram,
# and Mattermost branches.
#
# The fix factors a `bridge_channel_access_file_present` helper that
# tries the direct probe first (legacy / non-iso install) and falls
# back to `bridge_linux_sudo_root test -f` (root sudo-escalate, mirrors
# `lib/bridge-agents.sh:1415`). All 4 plugin branches route through the
# helper.
#
# Gap 6 r2 — `bridge_isolation_v2_write_agent_state_marker` previously
# called `ensure_matrix_path "state-agent-dir" "$agent"` before writing
# the `idle-since` / `manual-stop` / `missing-marker-retries` /
# `webhook-port` markers. The matrix row for `state-agent-dir` under
# linux-user mode expects group `ab-agent-<X>`; from the Stop hook
# (which runs as the isolated UID, not the controller), `apply_row
# check` fails whenever the on-disk group is not `ab-agent-<X>` (e.g.,
# drift from a non-prepare path), and the `apply_row apply` fallback
# cannot chown without sudo (the Stop hook spawn has no sudoers entry
# beyond bash/tmux).
#
# The r1 attempt widened the row's group from `agent_grp` (=ab-agent-<X>)
# to `shared_grp` (=ab-shared) so the iso UID could satisfy `check`
# directly via shared group membership. Codex r1 BLOCKING catch: that
# also lets ANY isolated UID create/delete `manual-stop` and
# `broken-launch` files in ANY other agent's `state/agents/<other>/`
# leaf (mere existence of `broken-launch` disables autostart;
# `manual-stop` containing digits suppresses daemon wake). The widening
# therefore opens a cross-agent integrity hole.
#
# The r2 fix preserves the per-agent integrity boundary
# (`controller:ab-agent-<X>:2770`, no widening) and addresses the
# Stop-hook failure mode at the writer instead: when isolation is
# effective for `<agent>`, the writer routes through
# `bridge_isolation_write_file_as_agent_user_via_bash`, which
# sudo-escalates as that agent's OWN os_user (`agent-bridge-<X>`) and
# atomic-writes inside the iso UID's authority. The per-agent sudoers
# entry only whitelists that one os_user, so the writer can never reach
# another agent's leaf — per-agent integrity intact.
#
# This smoke is HOST-AGNOSTIC: stubs sudo, isolation-effective, the
# sudo-as-iso helper, and os_user resolution. No real `agent-bridge-*`
# users or `ab-shared` group on the host required.
#
# Tests:
#   T1 (Gap 5): iso-effective + access.json present under root-only
#               isolated path → bridge_channel_access_file_present
#               returns 0 (success) via sudo-escalate.
#   T2 (Gap 5): iso-effective + access.json ABSENT → helper returns 1
#               (negative gate preserved).
#   T3 (Gap 5): non-iso (legacy) path, file present → helper succeeds
#               on the direct `[[ -f ]]` probe alone (no sudo needed).
#   T4  (Gap 6 r2): static-source — linux-user `state-agent-dir` matrix
#                   row stays `controller:$agent_grp:2770` (per-agent
#                   integrity boundary preserved; r1 widen to
#                   `$shared_grp` reverted per codex BLOCKING).
#   T4a (Gap 6 r2): iso-effective + euid != target writer call routes
#                   through `bridge_isolation_write_file_as_agent_user_via_bash`
#                   with the requesting agent's own identity, mode
#                   0660, and the target under that agent's own
#                   state-agent-dir leaf only.
#   T4a-direct (Gap 6 r3): euid == target os_user → Path A0 direct
#                          atomic write. sudo-as-iso helper MUST NOT be
#                          invoked (Stop-hook-from-isolated-session
#                          reproducer; controller-scoped sudoers makes
#                          Path A rc=2 from the iso UID).
#   T4d (Gap 6 r3): euid != target + sudo helper rc=2 → fall through to
#                   Path B (controller direct write via
#                   ensure_matrix_path). Pins the cross-agent
#                   fall-through chain end-to-end.
#   T4b (Gap 6 r2): the target path passed to the sudo-as-iso helper is
#                   ALWAYS derived from the writer's `$agent` argument
#                   (no shell expansion of caller-controlled content) —
#                   so a caller running as agent Y cannot redirect a
#                   write to agent X's leaf via the writer. The per-
#                   agent sudoers entry (covered separately by
#                   bridge-migration.sh) enforces the rest of the
#                   integrity boundary.
#   T4c (Gap 6 r2): non-iso path → writer falls through to Path B
#                   (controller direct write via `ensure_matrix_path`
#                   + `printf > tmp` + `mv -f`).
#   T5  (Gap 6 r2): shared-mode `state-agent-dir` row preserves
#                   `controller_group` (no collateral regression to the
#                   #909 shared-mode contract).
#
# Footgun #11 (heredoc_write deadlock class): every driver is built
# with `printf '%s\n' >file`; no `<<<` / `<<EOF` feeds into bash
# functions; no `$()` capture of heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1165-track-b-sudo-escalate-and-state"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

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

# ---------- T1 — iso-effective + present file → sudo-escalate succeeds ----------
#
# Fixture: an access.json that the direct `[[ -f ]]` probe CANNOT see
# (we use a path under a 0700 owner-only dir). The driver's stub
# `bridge_linux_sudo_root` is a direct passthrough, so the sudo fallback
# resolves via the same UID's `test -f` on the file (which DOES work
# because the test runs as the file's owner).
#
# To simulate "controller can't stat but sudo-root can", we make the
# parent dir 0700 owned by the test runner AND stub the direct `[[ -f ]]`
# call (in the helper itself we cannot stub; instead we use a separate
# path the direct `[[ -f ]]` legitimately cannot find — e.g. nest behind
# a chmod 0000 dir, then the sudo passthrough chmod 0700 back). The
# cleanest fixture: stub the helper to use a guard function in place of
# `[[ -f ]]` that returns 1 by contract; the smoke then asserts that
# the sudo branch is exercised and the result is 0.
#
# Implementation: rather than mutating the helper, we drive a wrapper
# that mimics the helper's contract and pins the sudo-fallback path by
# stubbing `bridge_linux_sudo_root` to record its invocation. T1
# asserts the helper returns 0 AND sudo was called with `test -f`.

T1_DIR="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_DIR"
T1_ACCESS_FILE="$T1_DIR/access.json"
T1_SUDO_LOG="$T1_DIR/sudo-calls.log"
printf '%s\n' '{}' >"$T1_ACCESS_FILE"
# Hide the file from the direct `[[ -f ]]` probe by stashing it behind a
# dir we'll set 0000 on (test runner can chmod its own dirs).
T1_HIDDEN_DIR="$T1_DIR/hidden"
mkdir -p "$T1_HIDDEN_DIR"
mv "$T1_ACCESS_FILE" "$T1_HIDDEN_DIR/access.json"
T1_ACCESS_FILE="$T1_HIDDEN_DIR/access.json"
chmod 0000 "$T1_HIDDEN_DIR"

T1_DRIVER="$T1_DIR/driver.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$T1_DRIVER"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'set -uo pipefail' >>"$T1_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T1_DRIVER"
printf '%s\n' 'TARGET="$2"' >>"$T1_DRIVER"
printf '%s\n' 'SUDO_LOG="$3"' >>"$T1_DRIVER"
printf '%s\n' 'HIDDEN_DIR="$4"' >>"$T1_DRIVER"
# Stub bridge_linux_sudo_root: log the call AND restore the dir mode
# so `test -f` can succeed (mimics root sudo's traverse ability).
printf '%s\n' 'bridge_linux_sudo_root() {' >>"$T1_DRIVER"
printf '%s\n' '  printf "sudo: %s\n" "$*" >>"$SUDO_LOG"' >>"$T1_DRIVER"
printf '%s\n' '  # Temporarily unhide so the wrapped command can stat.' >>"$T1_DRIVER"
printf '%s\n' '  chmod 0755 "$HIDDEN_DIR" 2>/dev/null || true' >>"$T1_DRIVER"
printf '%s\n' '  "$@"' >>"$T1_DRIVER"
printf '%s\n' '  local _rc=$?' >>"$T1_DRIVER"
printf '%s\n' '  chmod 0000 "$HIDDEN_DIR" 2>/dev/null || true' >>"$T1_DRIVER"
printf '%s\n' '  return $_rc' >>"$T1_DRIVER"
printf '%s\n' '}' >>"$T1_DRIVER"
# Source bridge-agents.sh through a minimum-deps shim: it depends on
# bridge-core.sh. Define BRIDGE_HOME etc. via the smoke setup envelope
# already exported by the parent process.
printf '%s\n' '# shellcheck disable=SC1090' >>"$T1_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"' >>"$T1_DRIVER"
# Don't source the full bridge-agents.sh (its load-time roster scan can
# trip on the smoke harness). Extract and source ONLY the helper under
# test by capturing its definition. We use a sed-extract to keep the
# helper textual definition (lines from
# `bridge_channel_access_file_present()` through the closing `}`) and
# eval it.
printf '%s\n' 'HELPER_DEF="$(awk "/^bridge_channel_access_file_present\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-agents.sh")"' >>"$T1_DRIVER"
printf '%s\n' 'eval "$HELPER_DEF"' >>"$T1_DRIVER"
printf '%s\n' 'bridge_channel_access_file_present "$TARGET"' >>"$T1_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T1_DRIVER"
chmod +x "$T1_DRIVER"

T1_LOG="$T1_DIR/log"
"$BRIDGE_BASH" "$T1_DRIVER" "$REPO_ROOT" "$T1_ACCESS_FILE" "$T1_SUDO_LOG" "$T1_HIDDEN_DIR" >"$T1_LOG" 2>&1 \
  || true

# Restore mode for cleanup.
chmod 0755 "$T1_HIDDEN_DIR" 2>/dev/null || true

grep -q '^RC=0$' "$T1_LOG" \
  || smoke_fail "T1: expected RC=0 (helper returned success via sudo-escalate). log: $(tr '\n' '|' <"$T1_LOG" | tail -c 600)"
grep -q '^sudo: test -f ' "$T1_SUDO_LOG" \
  || smoke_fail "T1: expected sudo-root invocation with 'test -f' but none recorded. sudo log: $(cat "$T1_SUDO_LOG") helper log: $(tr '\n' '|' <"$T1_LOG" | tail -c 600)"
smoke_log "T1 PASS: bridge_channel_access_file_present sudo-escalates to test -f when direct probe fails"

# ---------- T2 — iso-effective + ABSENT file → negative gate preserved ----------
T2_DIR="$SMOKE_TMP_ROOT/t2"
mkdir -p "$T2_DIR"
T2_ABSENT="$T2_DIR/does-not-exist.json"
T2_SUDO_LOG="$T2_DIR/sudo-calls.log"
T2_DRIVER="$T2_DIR/driver.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$T2_DRIVER"
# shellcheck disable=SC2129
printf '%s\n' 'set -uo pipefail' >>"$T2_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T2_DRIVER"
printf '%s\n' 'TARGET="$2"' >>"$T2_DRIVER"
printf '%s\n' 'SUDO_LOG="$3"' >>"$T2_DRIVER"
printf '%s\n' 'bridge_linux_sudo_root() {' >>"$T2_DRIVER"
printf '%s\n' '  printf "sudo: %s\n" "$*" >>"$SUDO_LOG"' >>"$T2_DRIVER"
printf '%s\n' '  "$@"' >>"$T2_DRIVER"
printf '%s\n' '}' >>"$T2_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T2_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"' >>"$T2_DRIVER"
printf '%s\n' 'HELPER_DEF="$(awk "/^bridge_channel_access_file_present\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-agents.sh")"' >>"$T2_DRIVER"
printf '%s\n' 'eval "$HELPER_DEF"' >>"$T2_DRIVER"
printf '%s\n' 'bridge_channel_access_file_present "$TARGET"' >>"$T2_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T2_DRIVER"
chmod +x "$T2_DRIVER"

T2_LOG="$T2_DIR/log"
"$BRIDGE_BASH" "$T2_DRIVER" "$REPO_ROOT" "$T2_ABSENT" "$T2_SUDO_LOG" >"$T2_LOG" 2>&1 \
  || true

grep -q '^RC=1$' "$T2_LOG" \
  || smoke_fail "T2: expected RC=1 (helper rejects absent file — negative gate preserved). log: $(tr '\n' '|' <"$T2_LOG" | tail -c 600)"
# The sudo-escalate branch SHOULD have been tried as a fallback (direct
# `[[ -f ]]` already returned false). Confirm the helper actually
# exercised the fallback path rather than short-circuiting.
grep -q '^sudo: test -f ' "$T2_SUDO_LOG" \
  || smoke_fail "T2: expected sudo-escalate fallback to be tried even on absent file. sudo log: $(cat "$T2_SUDO_LOG")"
smoke_log "T2 PASS: absent file returns 1 (negative gate intact) after sudo-escalate fallback also fails"

# ---------- T3 — non-iso (legacy) install: direct probe wins, no sudo needed ----------
T3_DIR="$SMOKE_TMP_ROOT/t3"
mkdir -p "$T3_DIR"
T3_ACCESS_FILE="$T3_DIR/access.json"
printf '%s\n' '{}' >"$T3_ACCESS_FILE"
T3_SUDO_LOG="$T3_DIR/sudo-calls.log"

T3_DRIVER="$T3_DIR/driver.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$T3_DRIVER"
# shellcheck disable=SC2129
printf '%s\n' 'set -uo pipefail' >>"$T3_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T3_DRIVER"
printf '%s\n' 'TARGET="$2"' >>"$T3_DRIVER"
printf '%s\n' 'SUDO_LOG="$3"' >>"$T3_DRIVER"
# Stub sudo to log + always fail, so any reliance on it would surface.
printf '%s\n' 'bridge_linux_sudo_root() {' >>"$T3_DRIVER"
printf '%s\n' '  printf "sudo: %s\n" "$*" >>"$SUDO_LOG"' >>"$T3_DRIVER"
printf '%s\n' '  return 1' >>"$T3_DRIVER"
printf '%s\n' '}' >>"$T3_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T3_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"' >>"$T3_DRIVER"
printf '%s\n' 'HELPER_DEF="$(awk "/^bridge_channel_access_file_present\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-agents.sh")"' >>"$T3_DRIVER"
printf '%s\n' 'eval "$HELPER_DEF"' >>"$T3_DRIVER"
printf '%s\n' 'bridge_channel_access_file_present "$TARGET"' >>"$T3_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T3_DRIVER"
chmod +x "$T3_DRIVER"

T3_LOG="$T3_DIR/log"
"$BRIDGE_BASH" "$T3_DRIVER" "$REPO_ROOT" "$T3_ACCESS_FILE" "$T3_SUDO_LOG" >"$T3_LOG" 2>&1 \
  || true

grep -q '^RC=0$' "$T3_LOG" \
  || smoke_fail "T3: expected RC=0 (helper succeeds via direct probe on a controller-readable file). log: $(tr '\n' '|' <"$T3_LOG" | tail -c 600)"
# Direct probe should have short-circuited — sudo MUST NOT have been
# invoked (preserves the legacy non-iso fast path).
if [[ -s "$T3_SUDO_LOG" ]]; then
  smoke_fail "T3: sudo path was invoked when the direct probe should have short-circuited. sudo log: $(cat "$T3_SUDO_LOG")"
fi
smoke_log "T3 PASS: non-iso fast path (direct [[ -f ]]) wins; no sudo escalation invoked"

# ---------- T4 — Gap 6 r2: linux-user state-agent-dir row stays $agent_grp ----------
#
# Static-source assertion. The r1 attempt widened the row's group to
# `$shared_grp` (ab-shared) so the Stop hook could satisfy
# `ensure_matrix_path` via shared group membership. Codex r1 BLOCKING
# catch: that lets ANY isolated UID in `ab-shared` create/delete
# `manual-stop` and `broken-launch` markers in ANY other agent's
# `state/agents/<other>/` leaf (mere existence of `broken-launch`
# disables autostart; `manual-stop` containing digits suppresses daemon
# wake) — cross-agent integrity hole.
#
# r2 reverts the matrix row to the per-agent group (`$agent_grp` =
# `ab-agent-<X>`) and addresses the Stop-hook failure mode at the
# writer instead (see T4a / T4b below).

T4_SOURCE="$REPO_ROOT/lib/bridge-isolation-v2.sh"

# Positive assertion: the linux-user row uses $agent_grp (per-agent
# integrity boundary intact).
grep -Fq '"$state_agent_dir" "$agent_grp"' "$T4_SOURCE" \
  || smoke_fail "T4: linux-user state-agent-dir printf args line does not pass \$agent_grp as the group token (per-agent integrity boundary broken). file=$T4_SOURCE"

# Reject the r1 shape: the linux-user row must NOT reference
# `$shared_grp` (the cross-agent widening that codex BLOCKED). The
# shared-mode branch legitimately uses `controller_group` (T5
# confirms); only the linux-user `else` branch is in scope here.
if grep -Fq '"$state_agent_dir" "$shared_grp"' "$T4_SOURCE"; then
  smoke_fail "T4: linux-user state-agent-dir references \$shared_grp (cross-agent integrity hole — r1 widening re-introduced). file=$T4_SOURCE"
fi

# Header anchor: r2 row description must NOT advertise itself as the
# Gap 6 widening (an artifact of the r1 comment). The current line
# describes the per-agent integrity boundary instead.
if grep -q "#1165 Gap 6: ab-shared group lets" "$T4_SOURCE"; then
  smoke_fail "T4: stale r1 row header ('Gap 6: ab-shared group lets...') still present — r1 widening not fully reverted. file=$T4_SOURCE"
fi

smoke_log "T4 PASS: matrix row for linux-user state-agent-dir uses \$agent_grp (ab-agent-<X>) — per-agent integrity boundary preserved"

# ---------- T4a — Gap 6 r2: writer routes iso-effective call through sudo-as-iso helper ----------
#
# Drive `bridge_isolation_v2_write_agent_state_marker` with iso
# effective for the agent. Stub the sudo-as-iso helper to record its
# args (agent, target_path, mode) and return 0. Assert:
#   - The helper was invoked exactly once.
#   - It received the writer's `$agent` argument unchanged.
#   - The target path is `<state-agent-dir>/<marker_name>` (under that
#     agent's OWN leaf — never another agent's path).
#   - Mode is `0660` (matches the matrix file_mode contract).
#   - The writer returned 0 (success).

T4A_DIR="$SMOKE_TMP_ROOT/t4a"
mkdir -p "$T4A_DIR"
T4A_CALL_LOG="$T4A_DIR/sudo-iso-calls.log"
T4A_AGENT_DIR="$T4A_DIR/state/agents/alpha"
mkdir -p "$T4A_AGENT_DIR"

T4A_DRIVER="$T4A_DIR/driver.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$T4A_DRIVER"
# shellcheck disable=SC2129
printf '%s\n' 'set -uo pipefail' >>"$T4A_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T4A_DRIVER"
printf '%s\n' 'AGENT_DIR="$2"' >>"$T4A_DRIVER"
printf '%s\n' 'CALL_LOG="$3"' >>"$T4A_DRIVER"
# Stub: record call + consume stdin (so the producer pipeline does not block) + return 0.
printf '%s\n' 'bridge_isolation_write_file_as_agent_user_via_bash() {' >>"$T4A_DRIVER"
printf '%s\n' '  local agent="$1" dest="$2" mode="${3:-0600}"' >>"$T4A_DRIVER"
printf '%s\n' '  local content' >>"$T4A_DRIVER"
printf '%s\n' '  content="$(cat -)"' >>"$T4A_DRIVER"
printf '%s\n' '  printf "agent=%s dest=%s mode=%s content=%s\n" "$agent" "$dest" "$mode" "$content" >>"$CALL_LOG"' >>"$T4A_DRIVER"
printf '%s\n' '  return 0' >>"$T4A_DRIVER"
printf '%s\n' '}' >>"$T4A_DRIVER"
# Stub: iso effective for ANY agent passed in.
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T4A_DRIVER"
# Stub: marker dir = the agent state dir we control.
printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s" "$AGENT_DIR"; }' >>"$T4A_DRIVER"
# Stub: ensure_matrix_path should NOT be hit on Path A — if it is, fail loud.
printf '%s\n' 'bridge_isolation_v2_ensure_matrix_path() { printf "UNEXPECTED ensure_matrix_path: %s\n" "$*" >>"$CALL_LOG"; return 99; }' >>"$T4A_DRIVER"
# Stub: bridge_warn — visible in driver log.
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*" >&2; }' >>"$T4A_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T4A_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"' >>"$T4A_DRIVER"
# Re-stub bridge_warn after sourcing (bridge-core defines it).
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*" >&2; }' >>"$T4A_DRIVER"
# Extract ONLY the writer function from bridge-isolation-v2.sh.
printf '%s\n' 'WRITER_DEF="$(awk "/^bridge_isolation_v2_write_agent_state_marker\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-isolation-v2.sh")"' >>"$T4A_DRIVER"
printf '%s\n' 'eval "$WRITER_DEF"' >>"$T4A_DRIVER"
# Re-stub after eval — `eval` does not redefine stubs, but the writer
# may now resolve names. The stubs defined above stay in scope.
printf '%s\n' 'bridge_isolation_v2_write_agent_state_marker "alpha" "idle-since" "1700000000"' >>"$T4A_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T4A_DRIVER"
chmod +x "$T4A_DRIVER"

T4A_LOG="$T4A_DIR/log"
"$BRIDGE_BASH" "$T4A_DRIVER" "$REPO_ROOT" "$T4A_AGENT_DIR" "$T4A_CALL_LOG" >"$T4A_LOG" 2>&1 \
  || true

grep -q '^RC=0$' "$T4A_LOG" \
  || smoke_fail "T4a: writer did not return 0. log: $(tr '\n' '|' <"$T4A_LOG" | tail -c 600)"
[[ -s "$T4A_CALL_LOG" ]] \
  || smoke_fail "T4a: sudo-as-iso helper was NOT called when iso effective. driver log: $(tr '\n' '|' <"$T4A_LOG" | tail -c 600)"
# Exactly one call.
T4A_CALL_COUNT="$(wc -l <"$T4A_CALL_LOG" | tr -d ' ')"
[[ "$T4A_CALL_COUNT" == "1" ]] \
  || smoke_fail "T4a: expected exactly 1 sudo-as-iso call, got $T4A_CALL_COUNT. log: $(cat "$T4A_CALL_LOG")"
# Argument shape.
T4A_CALL="$(cat "$T4A_CALL_LOG")"
case "$T4A_CALL" in
  "agent=alpha dest=$T4A_AGENT_DIR/idle-since mode=0660 content=1700000000")
    : # ok
    ;;
  *)
    smoke_fail "T4a: sudo-as-iso call args wrong. want 'agent=alpha dest=$T4A_AGENT_DIR/idle-since mode=0660 content=1700000000', got '$T4A_CALL'"
    ;;
esac
# ensure_matrix_path MUST NOT have fired on the iso path.
if grep -q '^UNEXPECTED ensure_matrix_path' "$T4A_CALL_LOG"; then
  smoke_fail "T4a: ensure_matrix_path was invoked on the iso-effective path (Path A should skip it). log: $(cat "$T4A_CALL_LOG")"
fi

smoke_log "T4a PASS: iso-effective writer routes through bridge_isolation_write_file_as_agent_user_via_bash with agent/target/mode preserved"

# ---------- T4a-direct — Gap 6 r3: Path A0 fires when euid==target os_user ----------
#
# Stop-hook-from-isolated-session reproducer. The Claude/Codex Stop hook
# in an isolated agent process runs as the agent's own os_user
# (`agent-bridge-<X>`). Generated sudoers
# (`lib/bridge-migration.sh` `operator ALL=(os_user)`) is controller-
# scoped, so the iso UID cannot sudo back to itself via Path A's helper
# (rc=2 → Path B → original ensure_matrix_path bug). Path A0 detects
# `id -un == bridge_agent_os_user "$agent"` and does a direct atomic
# write without invoking the sudo helper.
#
# Driver fakes the match by stubbing `id` to print the agent's os_user
# and stubbing `bridge_agent_os_user` to return the same value. Asserts:
#   - Writer returns 0.
#   - The sudo-as-iso helper was NEVER invoked (Path A skipped).
#   - The target file exists with the writer's content.
#   - ensure_matrix_path (Path B) was NEVER hit either.
#   - Regression contract: revert Path A0 → this test fails because the
#     sudo-as-iso helper stub records an invocation.

T4AD_DIR="$SMOKE_TMP_ROOT/t4a-direct"
mkdir -p "$T4AD_DIR"
T4AD_CALL_LOG="$T4AD_DIR/calls.log"
T4AD_AGENT_DIR="$T4AD_DIR/state/agents/gamma"
mkdir -p "$T4AD_AGENT_DIR"
# Bin stub dir to override `id`.
T4AD_BIN="$T4AD_DIR/bin"
mkdir -p "$T4AD_BIN"
printf '%s\n' '#!/usr/bin/env bash' >"$T4AD_BIN/id"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' '# Stub `id` to simulate euid == target os_user for Path A0.' >>"$T4AD_BIN/id"
printf '%s\n' 'if [[ "${1:-}" == "-un" ]]; then' >>"$T4AD_BIN/id"
printf '%s\n' '  printf "agent-bridge-gamma\n"' >>"$T4AD_BIN/id"
printf '%s\n' '  exit 0' >>"$T4AD_BIN/id"
printf '%s\n' 'fi' >>"$T4AD_BIN/id"
printf '%s\n' 'exec /usr/bin/env -u PATH /usr/bin/id "$@" 2>/dev/null || command id "$@"' >>"$T4AD_BIN/id"
chmod +x "$T4AD_BIN/id"

T4AD_DRIVER="$T4AD_DIR/driver.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$T4AD_DRIVER"
# shellcheck disable=SC2129
printf '%s\n' 'set -uo pipefail' >>"$T4AD_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T4AD_DRIVER"
printf '%s\n' 'AGENT_DIR="$2"' >>"$T4AD_DRIVER"
printf '%s\n' 'CALL_LOG="$3"' >>"$T4AD_DRIVER"
printf '%s\n' 'STUB_BIN="$4"' >>"$T4AD_DRIVER"
# Prepend stub bin so the writer's `id -un` resolves to our stub.
printf '%s\n' 'export PATH="$STUB_BIN:$PATH"' >>"$T4AD_DRIVER"
# Stub: bridge_agent_os_user returns the matching os_user for `gamma`.
printf '%s\n' 'bridge_agent_os_user() {' >>"$T4AD_DRIVER"
printf '%s\n' '  if [[ "${1:-}" == "gamma" ]]; then printf "agent-bridge-gamma"; fi' >>"$T4AD_DRIVER"
printf '%s\n' '}' >>"$T4AD_DRIVER"
# Stub: sudo-as-iso helper — MUST NOT be invoked. Record + return 0 so
# any accidental invocation surfaces as a failure assertion below.
printf '%s\n' 'bridge_isolation_write_file_as_agent_user_via_bash() {' >>"$T4AD_DRIVER"
printf '%s\n' '  printf "UNEXPECTED sudo-as-iso call: %s\n" "$*" >>"$CALL_LOG"' >>"$T4AD_DRIVER"
printf '%s\n' '  cat - >/dev/null' >>"$T4AD_DRIVER"
printf '%s\n' '  return 0' >>"$T4AD_DRIVER"
printf '%s\n' '}' >>"$T4AD_DRIVER"
# Stub: iso effective (still true — Path A0 runs regardless of this,
# but Path A is only reached if A0 falls through, so set true to mirror
# the real Stop-hook-from-iso-session topology).
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T4AD_DRIVER"
# Stub: marker dir = the agent state dir we control.
printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s" "$AGENT_DIR"; }' >>"$T4AD_DRIVER"
# Stub: ensure_matrix_path MUST NOT be hit on Path A0 — record loud.
printf '%s\n' 'bridge_isolation_v2_ensure_matrix_path() { printf "UNEXPECTED ensure_matrix_path: %s\n" "$*" >>"$CALL_LOG"; return 99; }' >>"$T4AD_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*" >&2; }' >>"$T4AD_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T4AD_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"' >>"$T4AD_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*" >&2; }' >>"$T4AD_DRIVER"
printf '%s\n' 'WRITER_DEF="$(awk "/^bridge_isolation_v2_write_agent_state_marker\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-isolation-v2.sh")"' >>"$T4AD_DRIVER"
printf '%s\n' 'eval "$WRITER_DEF"' >>"$T4AD_DRIVER"
printf '%s\n' 'bridge_isolation_v2_write_agent_state_marker "gamma" "idle-since" "1700000300"' >>"$T4AD_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T4AD_DRIVER"
chmod +x "$T4AD_DRIVER"

T4AD_LOG="$T4AD_DIR/log"
"$BRIDGE_BASH" "$T4AD_DRIVER" "$REPO_ROOT" "$T4AD_AGENT_DIR" "$T4AD_CALL_LOG" "$T4AD_BIN" >"$T4AD_LOG" 2>&1 \
  || true

grep -q '^RC=0$' "$T4AD_LOG" \
  || smoke_fail "T4a-direct: writer did not return 0. log: $(tr '\n' '|' <"$T4AD_LOG" | tail -c 800)"
# Path A0 fires → sudo-as-iso helper MUST NOT have been called.
if [[ -s "$T4AD_CALL_LOG" ]]; then
  smoke_fail "T4a-direct: sudo-as-iso helper or ensure_matrix_path was invoked when Path A0 should have short-circuited (euid==target os_user). calls: $(cat "$T4AD_CALL_LOG"). driver log: $(tr '\n' '|' <"$T4AD_LOG" | tail -c 800)"
fi
# Target file must exist with the writer's content.
if [[ ! -f "$T4AD_AGENT_DIR/idle-since" ]]; then
  smoke_fail "T4a-direct: Path A0 did not produce $T4AD_AGENT_DIR/idle-since. driver log: $(tr '\n' '|' <"$T4AD_LOG" | tail -c 800)"
fi
T4AD_CONTENT="$(<"$T4AD_AGENT_DIR/idle-since")"
[[ "$T4AD_CONTENT" == "1700000300" ]] \
  || smoke_fail "T4a-direct: idle-since content mismatch. want '1700000300', got '$T4AD_CONTENT'"

smoke_log "T4a-direct PASS: Path A0 direct write fires when euid matches target os_user; sudo-as-iso helper NOT invoked"

# ---------- T4d — Gap 6 r3: Path A0 mismatch + iso effective routes to Path A ----------
#
# Topology: cross-agent write attempt. Process running as
# `agent-bridge-X` (effective UID) tries to write a marker into
# `agent-Y`'s leaf. Path A0 must NOT fire (current user !=
# bridge_agent_os_user "Y"). Writer falls through to Path A (sudo
# helper). Stub the sudo helper to return rc=2 (no sudoers entry for
# this os_user → typical real-world result). Writer then falls through
# to Path B (controller direct write via ensure_matrix_path). Asserts:
#   - Path A0 did NOT short-circuit (sudo helper WAS invoked).
#   - sudo helper rc=2 caused fall-through to Path B (not a hard fail).
#   - Path B succeeded (ensure_matrix_path stub returns 0 + direct write).
#   - Final writer rc=0.
#
# This pins the cross-agent fall-through chain end-to-end so a future
# Path A0 over-broadening (matching when current user != target) would
# regress here.

T4D_DIR="$SMOKE_TMP_ROOT/t4d"
mkdir -p "$T4D_DIR"
T4D_CALL_LOG="$T4D_DIR/calls.log"
T4D_AGENT_DIR="$T4D_DIR/state/agents/delta"
mkdir -p "$T4D_AGENT_DIR"
# Stub `id` to print a DIFFERENT user than the writer's target os_user.
T4D_BIN="$T4D_DIR/bin"
mkdir -p "$T4D_BIN"
printf '%s\n' '#!/usr/bin/env bash' >"$T4D_BIN/id"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 off the table
printf '%s\n' 'if [[ "${1:-}" == "-un" ]]; then' >>"$T4D_BIN/id"
printf '%s\n' '  printf "agent-bridge-other\n"' >>"$T4D_BIN/id"
printf '%s\n' '  exit 0' >>"$T4D_BIN/id"
printf '%s\n' 'fi' >>"$T4D_BIN/id"
printf '%s\n' 'exec /usr/bin/env -u PATH /usr/bin/id "$@" 2>/dev/null || command id "$@"' >>"$T4D_BIN/id"
chmod +x "$T4D_BIN/id"

T4D_DRIVER="$T4D_DIR/driver.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$T4D_DRIVER"
# shellcheck disable=SC2129
printf '%s\n' 'set -uo pipefail' >>"$T4D_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T4D_DRIVER"
printf '%s\n' 'AGENT_DIR="$2"' >>"$T4D_DRIVER"
printf '%s\n' 'CALL_LOG="$3"' >>"$T4D_DRIVER"
printf '%s\n' 'STUB_BIN="$4"' >>"$T4D_DRIVER"
printf '%s\n' 'export PATH="$STUB_BIN:$PATH"' >>"$T4D_DRIVER"
# Target os_user = agent-bridge-delta (does NOT match `id -un` = agent-bridge-other).
printf '%s\n' 'bridge_agent_os_user() {' >>"$T4D_DRIVER"
printf '%s\n' '  if [[ "${1:-}" == "delta" ]]; then printf "agent-bridge-delta"; fi' >>"$T4D_DRIVER"
printf '%s\n' '}' >>"$T4D_DRIVER"
# Stub: sudo-as-iso helper — record call + return rc=2 (no sudoers).
printf '%s\n' 'bridge_isolation_write_file_as_agent_user_via_bash() {' >>"$T4D_DRIVER"
printf '%s\n' '  printf "sudo-as-iso call: %s\n" "$*" >>"$CALL_LOG"' >>"$T4D_DRIVER"
printf '%s\n' '  cat - >/dev/null' >>"$T4D_DRIVER"
printf '%s\n' '  return 2' >>"$T4D_DRIVER"
printf '%s\n' '}' >>"$T4D_DRIVER"
# Stub: iso effective so Path A is attempted.
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }' >>"$T4D_DRIVER"
printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s" "$AGENT_DIR"; }' >>"$T4D_DRIVER"
# Stub: ensure_matrix_path succeeds (Path B reachable).
printf '%s\n' 'bridge_isolation_v2_ensure_matrix_path() { printf "ensure_matrix_path: %s\n" "$*" >>"$CALL_LOG"; return 0; }' >>"$T4D_DRIVER"
# Stub: run_root_or_sudo passthrough — should not be reached when direct
# write under our test runner succeeds.
printf '%s\n' '_bridge_isolation_v2_run_root_or_sudo() { "$@"; }' >>"$T4D_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*" >&2; }' >>"$T4D_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T4D_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"' >>"$T4D_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*" >&2; }' >>"$T4D_DRIVER"
printf '%s\n' 'WRITER_DEF="$(awk "/^bridge_isolation_v2_write_agent_state_marker\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-isolation-v2.sh")"' >>"$T4D_DRIVER"
printf '%s\n' 'eval "$WRITER_DEF"' >>"$T4D_DRIVER"
printf '%s\n' 'bridge_isolation_v2_write_agent_state_marker "delta" "idle-since" "1700000400"' >>"$T4D_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T4D_DRIVER"
chmod +x "$T4D_DRIVER"

T4D_LOG="$T4D_DIR/log"
"$BRIDGE_BASH" "$T4D_DRIVER" "$REPO_ROOT" "$T4D_AGENT_DIR" "$T4D_CALL_LOG" "$T4D_BIN" >"$T4D_LOG" 2>&1 \
  || true

grep -q '^RC=0$' "$T4D_LOG" \
  || smoke_fail "T4d: writer did not return 0 after Path A→rc=2→Path B fall-through. log: $(tr '\n' '|' <"$T4D_LOG" | tail -c 800)"
# Path A (sudo helper) MUST have been invoked — Path A0 should NOT fire
# because `id -un` != target os_user.
grep -q '^sudo-as-iso call:' "$T4D_CALL_LOG" \
  || smoke_fail "T4d: sudo-as-iso helper was NOT invoked — Path A0 may have over-fired across the cross-user boundary. calls: $(cat "$T4D_CALL_LOG")"
# After rc=2, the writer must fall through to Path B (ensure_matrix_path).
grep -q '^ensure_matrix_path:' "$T4D_CALL_LOG" \
  || smoke_fail "T4d: ensure_matrix_path NOT invoked after sudo-as-iso rc=2 (Path B fall-through broken). calls: $(cat "$T4D_CALL_LOG")"
# Path B direct write must have produced the file with our content.
if [[ ! -f "$T4D_AGENT_DIR/idle-since" ]]; then
  smoke_fail "T4d: Path B did not produce $T4D_AGENT_DIR/idle-since. calls: $(cat "$T4D_CALL_LOG"). driver log: $(tr '\n' '|' <"$T4D_LOG" | tail -c 800)"
fi

smoke_log "T4d PASS: cross-user write skips Path A0, sudo-as-iso rc=2 falls through to Path B which writes via ensure_matrix_path"

# ---------- T4b — Gap 6 r2: target path always under writer's $agent leaf ----------
#
# Static-source assertion. The cross-agent integrity boundary lives in
# two layers:
#   (1) per-agent sudoers entries (each `agent-bridge-<X>` os_user can
#       only sudo to its own UID — enforced outside this writer).
#   (2) the writer must pass its `$agent` argument unchanged to the
#       sudo-as-iso helper, so a caller cannot redirect the write to a
#       sibling agent's leaf via the writer.
#
# Verify (2) statically: the writer's call site to
# `bridge_isolation_write_file_as_agent_user_via_bash` must pass `$agent`
# as the first arg (NOT a literal, NOT a computed path that escapes the
# leaf). Likewise the `target` value passed as the second arg must be
# derived from `bridge_agent_idle_marker_dir "$agent"` (which routes
# through `BRIDGE_ACTIVE_AGENT_DIR/$agent`, not a caller-controllable
# path).

T4B_SOURCE="$REPO_ROOT/lib/bridge-isolation-v2.sh"

# Anchor 1: helper invocation must pass `"$agent"` as the first arg
# and `"$target"` as the second arg. Match the producer-pipe call shape.
grep -Eq 'bridge_isolation_write_file_as_agent_user_via_bash[[:space:]]+"\$agent"[[:space:]]+"\$target"[[:space:]]+"0660"' "$T4B_SOURCE" \
  || smoke_fail "T4b: writer's sudo-as-iso call does not pass (\"\$agent\", \"\$target\", \"0660\") in that order. file=$T4B_SOURCE"

# Anchor 2: `$target` must be derived from `$dir/$marker_name`, where
# `$dir` comes from `bridge_agent_idle_marker_dir "$agent"` (or the
# fallback `BRIDGE_ACTIVE_AGENT_DIR/$agent`). The writer must never
# construct `$target` from caller-supplied strings.
grep -Fq 'local target="$dir/$marker_name"' "$T4B_SOURCE" \
  || smoke_fail "T4b: writer's target path is not the canonical \$dir/\$marker_name derivation. file=$T4B_SOURCE"
grep -Fq 'dir="$(bridge_agent_idle_marker_dir "$agent" 2>/dev/null)"' "$T4B_SOURCE" \
  || smoke_fail "T4b: writer's \$dir is not derived from bridge_agent_idle_marker_dir \"\$agent\". file=$T4B_SOURCE"

# Anchor 3: the iso-effective gate must also use the writer's `$agent`
# parameter (not a sibling) — so the iso check and the sudo target are
# the same agent's identity.
grep -Fq 'bridge_agent_linux_user_isolation_effective "$agent"' "$T4B_SOURCE" \
  || smoke_fail "T4b: iso-effective gate does not check the writer's \$agent. file=$T4B_SOURCE"

smoke_log "T4b PASS: writer's target path is always \$agent-derived; sudo-as-iso call passes (\$agent, \$target, 0660) — caller cannot redirect across agent boundaries via this writer"

# ---------- T4c — Gap 6 r2: non-iso path falls through to controller direct write ----------
#
# When iso is NOT effective (legacy install, shared mode, test
# fixtures), the writer must use Path B: `ensure_matrix_path` →
# `mkdir -p $dir` → `printf > tmp` → `mv -f tmp target` → `chmod 0660`.
# Stub the sudo-as-iso helper to record its call (we want to verify
# it is NEVER called); stub iso-effective to return false.

T4C_DIR="$SMOKE_TMP_ROOT/t4c"
mkdir -p "$T4C_DIR"
T4C_CALL_LOG="$T4C_DIR/sudo-iso-calls.log"
T4C_AGENT_DIR="$T4C_DIR/state/agents/beta"
mkdir -p "$T4C_AGENT_DIR"

T4C_DRIVER="$T4C_DIR/driver.sh"
printf '%s\n' '#!/usr/bin/env bash' >"$T4C_DRIVER"
# shellcheck disable=SC2129
printf '%s\n' 'set -uo pipefail' >>"$T4C_DRIVER"
printf '%s\n' 'REPO_ROOT="$1"' >>"$T4C_DRIVER"
printf '%s\n' 'AGENT_DIR="$2"' >>"$T4C_DRIVER"
printf '%s\n' 'CALL_LOG="$3"' >>"$T4C_DRIVER"
# Stub: helper recorded if invoked (it MUST NOT be).
printf '%s\n' 'bridge_isolation_write_file_as_agent_user_via_bash() {' >>"$T4C_DRIVER"
printf '%s\n' '  printf "UNEXPECTED sudo-as-iso call: %s\n" "$*" >>"$CALL_LOG"' >>"$T4C_DRIVER"
printf '%s\n' '  return 0' >>"$T4C_DRIVER"
printf '%s\n' '}' >>"$T4C_DRIVER"
# Stub: iso NOT effective.
printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 1; }' >>"$T4C_DRIVER"
# Stub: marker dir.
printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s" "$AGENT_DIR"; }' >>"$T4C_DRIVER"
# Stub: ensure_matrix_path returns success (we are in non-iso path).
printf '%s\n' 'bridge_isolation_v2_ensure_matrix_path() { return 0; }' >>"$T4C_DRIVER"
# Stub: run_root_or_sudo passthrough (should not be reached if direct write succeeds).
printf '%s\n' '_bridge_isolation_v2_run_root_or_sudo() { "$@"; }' >>"$T4C_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*" >&2; }' >>"$T4C_DRIVER"
printf '%s\n' '# shellcheck disable=SC1090' >>"$T4C_DRIVER"
printf '%s\n' 'source "$REPO_ROOT/lib/bridge-core.sh"' >>"$T4C_DRIVER"
printf '%s\n' 'bridge_warn() { printf "warn: %s\n" "$*" >&2; }' >>"$T4C_DRIVER"
printf '%s\n' 'WRITER_DEF="$(awk "/^bridge_isolation_v2_write_agent_state_marker\\(\\) \\{/,/^\\}/" "$REPO_ROOT/lib/bridge-isolation-v2.sh")"' >>"$T4C_DRIVER"
printf '%s\n' 'eval "$WRITER_DEF"' >>"$T4C_DRIVER"
printf '%s\n' 'bridge_isolation_v2_write_agent_state_marker "beta" "idle-since" "1700000099"' >>"$T4C_DRIVER"
printf '%s\n' 'echo "RC=$?"' >>"$T4C_DRIVER"
chmod +x "$T4C_DRIVER"

T4C_LOG="$T4C_DIR/log"
"$BRIDGE_BASH" "$T4C_DRIVER" "$REPO_ROOT" "$T4C_AGENT_DIR" "$T4C_CALL_LOG" >"$T4C_LOG" 2>&1 \
  || true

grep -q '^RC=0$' "$T4C_LOG" \
  || smoke_fail "T4c: writer did not return 0 on non-iso path. log: $(tr '\n' '|' <"$T4C_LOG" | tail -c 600)"
# sudo-as-iso helper must NOT have been called.
if [[ -s "$T4C_CALL_LOG" ]]; then
  smoke_fail "T4c: sudo-as-iso helper invoked on non-iso path (should fall through to Path B). log: $(cat "$T4C_CALL_LOG")"
fi
# The controller direct write must have produced the target file.
if [[ ! -f "$T4C_AGENT_DIR/idle-since" ]]; then
  smoke_fail "T4c: controller direct write did not create $T4C_AGENT_DIR/idle-since. driver log: $(tr '\n' '|' <"$T4C_LOG" | tail -c 600)"
fi
# And the content is the writer's input.
T4C_CONTENT="$(<"$T4C_AGENT_DIR/idle-since")"
[[ "$T4C_CONTENT" == "1700000099" ]] \
  || smoke_fail "T4c: idle-since content mismatch. want '1700000099', got '$T4C_CONTENT'"

smoke_log "T4c PASS: non-iso (legacy) path falls through to controller direct write — Path B intact"

# ---------- T5 — Shared-mode state-agent-dir row unchanged (no #909 regression) ----------
#
# The Gap 6 r2 fix only touches the linux-user `else` branch of the
# state-agent-dir row and the writer body. The shared-mode `if` branch
# (introduced for #909) must still emit `controller_group` so
# shared-mode agents on a host without `ab-shared` continue to work.

T5_SHARED_LINE="$(grep "printf 'state-agent-dir|%s|dir|controller|controller_group|2770|0660" "$T4_SOURCE" || true)"
[[ -n "$T5_SHARED_LINE" ]] \
  || smoke_fail "T5: shared-mode state-agent-dir row missing the controller_group emit (collateral #909 regression). file=$T4_SOURCE"

# And the shared-mode row must NOT reference $shared_grp (that would
# break shared-only installs without the v2 groups created) or
# $agent_grp (which only exists on linux-user installs).
if echo "$T5_SHARED_LINE" | grep -q '\$shared_grp'; then
  smoke_fail "T5: shared-mode state-agent-dir row references \$shared_grp — Gap 6 widening must not bleed into shared-mode. line: $T5_SHARED_LINE"
fi
if echo "$T5_SHARED_LINE" | grep -q '\$agent_grp'; then
  smoke_fail "T5: shared-mode state-agent-dir row references \$agent_grp — per-agent group only exists on linux-user installs. line: $T5_SHARED_LINE"
fi

smoke_log "T5 PASS: shared-mode state-agent-dir row unchanged (controller_group, no \$shared_grp / \$agent_grp leak) — #909 contract intact"

smoke_log "ALL 9 PASS"
