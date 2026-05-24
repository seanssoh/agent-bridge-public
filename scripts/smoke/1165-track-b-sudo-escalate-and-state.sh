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
# Gap 6 — `bridge_isolation_v2_write_agent_state_marker` calls
# `ensure_matrix_path "state-agent-dir" "$agent"` before writing the
# `idle-since` (and `manual-stop` / `missing-marker-retries` /
# `webhook-port`) markers. The matrix row for `state-agent-dir` under
# linux-user mode previously expected group `ab-agent-<X>`; from the
# Stop hook (which runs as the isolated UID, not the controller),
# `apply_row check` fails whenever the on-disk group is not
# `ab-agent-<X>` (e.g., drift from a non-prepare path), and the
# `apply_row apply` fallback cannot chown without sudo (the Stop hook
# spawn has no sudoers entry beyond bash/tmux).
#
# The fix widens the linux-user `state-agent-dir` row's group from
# `agent_grp` (=ab-agent-<X>) to `shared_grp` (=ab-shared). The
# isolated UID is already a member of `ab-shared` (joined by
# `bridge_migration_create_groups` + `bridge_linux_prepare_agent_
# isolation`); aligning the leaf row to `ab-shared` matches the parent
# rows (`state-root`, `state-agents-root`) and removes the apply-
# fallback dependency.
#
# This smoke is HOST-AGNOSTIC: stubs sudo, isolation-effective, and
# os_user resolution. No real `agent-bridge-*` users or `ab-shared`
# group on the host required.
#
# Tests:
#   T1 (Gap 5): iso-effective + access.json present under root-only
#               isolated path → bridge_channel_access_file_present
#               returns 0 (success) via sudo-escalate.
#   T2 (Gap 5): iso-effective + access.json ABSENT → helper returns 1
#               (negative gate preserved).
#   T3 (Gap 5): non-iso (legacy) path, file present → helper succeeds
#               on the direct `[[ -f ]]` probe alone (no sudo needed).
#   T4 (Gap 6): linux-user matrix row for `state-agent-dir` emits
#               group `ab-shared` (NOT `ab-agent-<X>`). Static-source
#               assertion that future revert to `ab-agent-<X>` makes
#               this smoke fail.
#   T5 (Gap 6): shared-mode `state-agent-dir` row preserves
#               `controller_group` (no collateral regression to the
#               #909 shared-mode contract).
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

# ---------- T4 — Gap 6: matrix row for state-agent-dir (linux-user) emits ab-shared ----------
#
# Static-source assertion. The widening from `ab-agent-<X>` to
# `ab-shared` is the load-bearing change for Gap 6. A future revert
# would re-introduce the Stop hook failure pattern.
#
# Grep the literal printf line under the linux-user `else` branch
# inside `bridge_isolation_v2_matrix_rows_for_agent`. The
# `shared_grp` token in the line confirms the widening.

T4_SOURCE="$REPO_ROOT/lib/bridge-isolation-v2.sh"

# Positive assertion: the linux-user row uses $shared_grp.
grep -q "printf 'state-agent-dir|%s|dir|controller|%s|2770|0660|1|group_setgid|required|#1165 Gap 6" "$T4_SOURCE" \
  || smoke_fail "T4: linux-user state-agent-dir row missing the Gap 6 widening header. expected '#1165 Gap 6' annotation in $T4_SOURCE"

# Anti-pattern: the linux-user `else` branch must NOT reference
# `$agent_grp` (the pre-fix per-agent group). The shared-mode `if`
# branch above legitimately uses `controller_group` (T5 confirms);
# only the linux-user branch is widened.
#
# Use awk to extract just the linux-user else block (the printf line
# right after the `else` inside the state-root section). The full
# matrix function is large; this block is small.
# The linux-user `state-agent-dir` printf is a 2-line statement
# (printf '...' \<newline>"$state_agent_dir" "$shared_grp"). grep the
# args line directly: it must contain `"$state_agent_dir" "$shared_grp"`
# and the matrix file must NOT contain the pre-fix `"$state_agent_dir"
# "$agent_grp"` (which referenced the per-agent group).
grep -Fq '"$state_agent_dir" "$shared_grp"' "$T4_SOURCE" \
  || smoke_fail "T4: linux-user state-agent-dir printf args line does not pass \$shared_grp as the group token. file=$T4_SOURCE"

# Reject the pre-fix shape (passes $agent_grp).
if grep -Fq '"$state_agent_dir" "$agent_grp"' "$T4_SOURCE"; then
  smoke_fail "T4: linux-user state-agent-dir still references \$agent_grp (Gap 6 fix reverted). file=$T4_SOURCE"
fi

smoke_log "T4 PASS: matrix row for linux-user state-agent-dir uses \$shared_grp (ab-shared) — Gap 6 widening intact"

# ---------- T5 — Shared-mode state-agent-dir row unchanged (no #909 regression) ----------
#
# The Gap 6 fix only touches the linux-user `else` branch of the
# state-agent-dir row. The shared-mode `if` branch (introduced for
# #909) must still emit `controller_group` so shared-mode agents on a
# host without `ab-shared` continue to work.

T5_SHARED_LINE="$(grep "printf 'state-agent-dir|%s|dir|controller|controller_group|2770|0660" "$T4_SOURCE" || true)"
[[ -n "$T5_SHARED_LINE" ]] \
  || smoke_fail "T5: shared-mode state-agent-dir row missing the controller_group emit (collateral #909 regression). file=$T4_SOURCE"

# And the shared-mode row must NOT reference $shared_grp (that would
# break shared-only installs without the v2 groups created).
if echo "$T5_SHARED_LINE" | grep -q '\$shared_grp'; then
  smoke_fail "T5: shared-mode state-agent-dir row now references \$shared_grp — Gap 6 widening must not bleed into shared-mode. line: $T5_SHARED_LINE"
fi

smoke_log "T5 PASS: shared-mode state-agent-dir row unchanged (controller_group, no \$shared_grp leak) — #909 contract intact"

smoke_log "ALL 5 PASS"
