#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1985-operator-global-settings-hijack-cleanup.sh — Issue #1985.
#
# Remediation half of the operator-global settings hijack (#1981 / PR #1984 was
# the launch-time PREVENTION guard). `bridge-upgrade.py cleanup-residue` now
# detects an EXISTING `~/.claude/settings.json` symlink that already points at a
# bridge-managed `settings.effective.json`, REPORTS it by default (no mutation,
# does not fail the upgrade), and REPAIRS it only with an explicit flag AND only
# after a complete, non-overwriting backup. Restore target is a neutral `{}`
# unless an explicit trusted restore-file is supplied.
#
# This smoke is HOST-AGNOSTIC (macOS dev hosts + Linux CI). It drives the real
# `cleanup-residue` subcommand against a fake HOME + a fake
# `<target_root>/...settings.effective.json` so the ONLY thing that can mutate
# the filesystem is the repair path under the explicit flag.
#
# Cases (design §"Required Smokes"):
#   1 — report-only v2 hijack -> status=detected, symlink UNCHANGED.
#   2 — repair v2 hijack      -> backup dir + symlink backup + neutral {} 0600.
#   3 — dangling/orphan v2    -> still detected (report-only).
#   4 — legacy v1 hijack      -> detected + repaired.
#   5 — shared install-wide   -> detected.
#   6 — non-bridge symlink    -> symlink_non_bridge, NO repair even with flag.
#   7 — backup failure        -> repair_failed, symlink UNCHANGED (refuse before
#        mutation).
#   8 — explicit restore-file -> trusted bytes installed, backup still captures
#        the original symlink.
#
# Footgun #11 (heredoc_write deadlock class): no `<<<` / `<<EOF` feeds bash
# functions; the fixtures are built with mkdir/ln/printf and the assertions read
# the JSON via a standalone python file (scripts/smoke/<this>-helper.py).

set -uo pipefail

SMOKE_NAME="1985-operator-global-settings-hijack-cleanup"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_make_temp_root "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"
UPGRADE_PY="$REPO_ROOT/bridge-upgrade.py"
HELPER="$SCRIPT_DIR/1985-operator-global-settings-hijack-cleanup-helper.py"
smoke_assert_file_exists "$UPGRADE_PY" "bridge-upgrade.py present"
smoke_assert_file_exists "$HELPER" "smoke helper present"

# Build a fresh fixture: an isolated fake HOME + a fake bridge target root.
# Sets BASE / HOME_DIR / TARGET_ROOT / OP_GLOBAL globals directly (no subshell,
# no here-string) so the assignment survives under bash 3.2 and the smoke avoids
# any `<<<` / heredoc into a bash function (footgun #11). `mktemp -d` makes each
# case's tree unique.
fresh_fixture() {
  BASE="$(mktemp -d "$SMOKE_TMP_ROOT/case.XXXXXX")"
  HOME_DIR="$BASE/home"
  TARGET_ROOT="$BASE/bridge"
  OP_GLOBAL="$HOME_DIR/.claude/settings.json"
  mkdir -p "$HOME_DIR/.claude" "$TARGET_ROOT"
}

# Create a fake bridge effective file at <target_root>/<rel> and echo its path.
mk_effective() {
  local tr="$1" rel="$2"
  local path="$tr/$rel"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '{"hooks":{"PreToolUse":[]},"enabledPlugins":{}}' >"$path"
  printf '%s' "$path"
}

# Run cleanup-residue against the fixture and capture JSON on stdout.
run_cleanup() {
  local home="$1" tr="$2"
  shift 2
  HOME="$home" python3 "$UPGRADE_PY" cleanup-residue \
    --target-root "$tr" \
    --operator-global-settings-file "$home/.claude/settings.json" \
    "$@"
}

# Extract one field from the operator_global_settings_hijack block.
hijack_field() {
  local json="$1" field="$2"
  printf '%s' "$json" | python3 "$HELPER" "$field"
}

# ---------------------------------------------------------------------------
# Case 1 — report-only v2 hijack: detected, symlink unchanged.
fresh_fixture
EFF="$(mk_effective "$TARGET_ROOT" "data/agents/sys-monitor/home/.claude/settings.effective.json")"
ln -s "$EFF" "$OP_GLOBAL"
JSON="$(run_cleanup "$HOME_DIR" "$TARGET_ROOT")"
smoke_assert_eq "$(hijack_field "$JSON" status)" "detected" "case1: report-only v2 detected"
smoke_assert_eq "$(hijack_field "$JSON" matched_layout)" "v2-agent" "case1: layout v2-agent"
smoke_assert_eq "$(hijack_field "$JSON" matched_agent)" "sys-monitor" "case1: agent sys-monitor"
smoke_assert_eq "$(hijack_field "$JSON" repair_requested)" "False" "case1: repair not requested"
[[ -L "$OP_GLOBAL" ]] || smoke_fail "case1: operator global must remain the same symlink"
[[ "$(readlink "$OP_GLOBAL")" == "$EFF" ]] || smoke_fail "case1: symlink target must be unchanged"
# Report-only detection must NOT add a cleanup failure.
smoke_assert_eq "$(printf '%s' "$JSON" | python3 "$HELPER" --cleanup-failures-for-step operator_global_settings_hijack)" "0" "case1: no cleanup_failure on report-only"
# Standalone manual runs may not read the JSON: a detected hijack must also warn
# on stderr (stdout stays pure JSON).
STDERR_OUT="$(HOME="$HOME_DIR" python3 "$UPGRADE_PY" cleanup-residue \
  --target-root "$TARGET_ROOT" \
  --operator-global-settings-file "$OP_GLOBAL" 2>&1 1>/dev/null)"
smoke_assert_contains "$STDERR_OUT" "#1985" "case1: stderr warns on detected"
smoke_assert_contains "$STDERR_OUT" "report-only" "case1: stderr names report-only"
smoke_log "case1 PASS (report-only v2 detected, symlink untouched, stderr warned)"

# ---------------------------------------------------------------------------
# Case 2 — repair v2 hijack.
fresh_fixture
EFF="$(mk_effective "$TARGET_ROOT" "data/agents/sys-monitor/home/.claude/settings.effective.json")"
ln -s "$EFF" "$OP_GLOBAL"
JSON="$(run_cleanup "$HOME_DIR" "$TARGET_ROOT" --repair-operator-global-settings-hijack)"
smoke_assert_eq "$(hijack_field "$JSON" status)" "repaired" "case2: repaired"
BACKUP_DIR="$(hijack_field "$JSON" backup_dir)"
[[ -d "$BACKUP_DIR" ]] || smoke_fail "case2: backup dir must exist: $BACKUP_DIR"
[[ -L "$BACKUP_DIR/operator-global-settings.symlink" ]] || smoke_fail "case2: symlink backup must be a symlink"
[[ "$(readlink "$BACKUP_DIR/operator-global-settings.symlink")" == "$EFF" ]] || smoke_fail "case2: symlink backup must point at original raw target"
smoke_assert_file_exists "$BACKUP_DIR/ROLLBACK.txt" "case2: rollback text exists"
smoke_assert_file_exists "$BACKUP_DIR/manifest.json" "case2: manifest exists"
[[ ! -L "$OP_GLOBAL" ]] || smoke_fail "case2: final operator global must NOT be a symlink"
[[ -f "$OP_GLOBAL" ]] || smoke_fail "case2: final operator global must be a regular file"
[[ "$(cat "$OP_GLOBAL")" == "{}" ]] || smoke_fail "case2: final content must be neutral {} (got: $(cat "$OP_GLOBAL"))"
FINAL_MODE="$(python3 "$HELPER" --mode-of "$OP_GLOBAL")"
smoke_assert_eq "$FINAL_MODE" "600" "case2: final file mode 0600"
smoke_log "case2 PASS (backup + neutral 0600 replace)"

# ---------------------------------------------------------------------------
# Case 3 — dangling/orphan target (link points at a missing effective file).
fresh_fixture
DEAD="$TARGET_ROOT/agents/dead/.claude/settings.effective.json"
ln -s "$DEAD" "$OP_GLOBAL"
[[ -e "$DEAD" ]] && smoke_fail "case3: target must be missing (dangling) for this case"
JSON="$(run_cleanup "$HOME_DIR" "$TARGET_ROOT")"
smoke_assert_eq "$(hijack_field "$JSON" status)" "detected" "case3: dangling target still detected"
[[ -L "$OP_GLOBAL" ]] || smoke_fail "case3: operator global must remain the symlink"
smoke_log "case3 PASS (dangling/orphan detected report-only)"

# ---------------------------------------------------------------------------
# Case 4 — legacy v1 target: detect + repair.
fresh_fixture
EFF="$(mk_effective "$TARGET_ROOT" "agents/patch/.claude/settings.effective.json")"
ln -s "$EFF" "$OP_GLOBAL"
JSON="$(run_cleanup "$HOME_DIR" "$TARGET_ROOT")"
smoke_assert_eq "$(hijack_field "$JSON" status)" "detected" "case4: legacy v1 detected"
smoke_assert_eq "$(hijack_field "$JSON" matched_layout)" "legacy-agent" "case4: layout legacy-agent"
smoke_assert_eq "$(hijack_field "$JSON" matched_agent)" "patch" "case4: agent patch"
JSON2="$(run_cleanup "$HOME_DIR" "$TARGET_ROOT" --repair-operator-global-settings-hijack)"
smoke_assert_eq "$(hijack_field "$JSON2" status)" "repaired" "case4: legacy v1 repaired"
[[ ! -L "$OP_GLOBAL" && -f "$OP_GLOBAL" ]] || smoke_fail "case4: final must be regular file"
smoke_log "case4 PASS (legacy v1 detect + repair)"

# ---------------------------------------------------------------------------
# Case 5 — shared install-wide target.
fresh_fixture
EFF="$(mk_effective "$TARGET_ROOT" "agents/.claude/settings.effective.json")"
ln -s "$EFF" "$OP_GLOBAL"
JSON="$(run_cleanup "$HOME_DIR" "$TARGET_ROOT")"
smoke_assert_eq "$(hijack_field "$JSON" status)" "detected" "case5: shared install-wide detected"
smoke_assert_eq "$(hijack_field "$JSON" matched_layout)" "shared" "case5: layout shared"
smoke_log "case5 PASS (shared install-wide detected)"

# ---------------------------------------------------------------------------
# Case 6 — non-bridge symlink: classified symlink_non_bridge, NO repair even
# with the flag.
fresh_fixture
DOTFILES="$BASE/dotfiles"
mkdir -p "$DOTFILES"
printf '%s\n' '{"theme":"system"}' >"$DOTFILES/settings.json"
ln -s "$DOTFILES/settings.json" "$OP_GLOBAL"
JSON="$(run_cleanup "$HOME_DIR" "$TARGET_ROOT" --repair-operator-global-settings-hijack)"
smoke_assert_eq "$(hijack_field "$JSON" status)" "symlink_non_bridge" "case6: non-bridge symlink classified"
[[ -L "$OP_GLOBAL" ]] || smoke_fail "case6: non-bridge symlink must NOT be repaired"
[[ "$(readlink "$OP_GLOBAL")" == "$DOTFILES/settings.json" ]] || smoke_fail "case6: non-bridge symlink target unchanged"
smoke_log "case6 PASS (non-bridge symlink left untouched even with --repair flag)"

# ---------------------------------------------------------------------------
# Case 7 — backup failure: repair refuses BEFORE mutation, symlink unchanged.
fresh_fixture
EFF="$(mk_effective "$TARGET_ROOT" "data/agents/sys-monitor/home/.claude/settings.effective.json")"
ln -s "$EFF" "$OP_GLOBAL"
BACKUP_PARENT="$TARGET_ROOT/backups/operator-global-settings-hijack"
mkdir -p "$BACKUP_PARENT"
chmod 0500 "$BACKUP_PARENT"  # read+exec, no write -> exclusive mkdir of run dir fails
JSON="$(run_cleanup "$HOME_DIR" "$TARGET_ROOT" --repair-operator-global-settings-hijack)"
chmod 0700 "$BACKUP_PARENT"  # restore so cleanup can remove it
STATUS7="$(hijack_field "$JSON" status)"
if [[ "$STATUS7" == "repair_failed" ]]; then
  [[ -L "$OP_GLOBAL" ]] || smoke_fail "case7: operator global must remain the symlink after backup failure"
  [[ "$(readlink "$OP_GLOBAL")" == "$EFF" ]] || smoke_fail "case7: symlink target must be unchanged after backup failure"
  smoke_log "case7 PASS (backup failure -> repair refused before mutation)"
elif [[ "$STATUS7" == "repaired" && "$EUID" == "0" ]]; then
  # Running as root, the 0500 dir is still writable -> the unwritable-parent
  # fault model does not apply; skip rather than assert a false negative.
  smoke_skip "case7" "running as root: 0500 backup parent still writable"
else
  smoke_fail "case7: expected repair_failed (or skip-as-root), got: $STATUS7"
fi

# ---------------------------------------------------------------------------
# Case 8 — explicit restore-file: trusted bytes installed, backup still captures
# the original symlink.
fresh_fixture
EFF="$(mk_effective "$TARGET_ROOT" "data/agents/sys-monitor/home/.claude/settings.effective.json")"
ln -s "$EFF" "$OP_GLOBAL"
RESTORE_FILE="$BASE/restore.json"
printf '%s\n' '{"autoCompactWindow":400000}' >"$RESTORE_FILE"
JSON="$(run_cleanup "$HOME_DIR" "$TARGET_ROOT" --repair-operator-global-settings-hijack --operator-global-settings-restore-file "$RESTORE_FILE")"
smoke_assert_eq "$(hijack_field "$JSON" status)" "repaired" "case8: explicit restore repaired"
smoke_assert_eq "$(hijack_field "$JSON" restore_mode)" "explicit-restore-file" "case8: restore_mode explicit"
[[ ! -L "$OP_GLOBAL" && -f "$OP_GLOBAL" ]] || smoke_fail "case8: final must be regular file"
python3 "$HELPER" --json-eq "$OP_GLOBAL" '{"autoCompactWindow":400000}' \
  || smoke_fail "case8: installed bytes must match the trusted restore file"
BACKUP_DIR="$(hijack_field "$JSON" backup_dir)"
[[ "$(readlink "$BACKUP_DIR/operator-global-settings.symlink")" == "$EFF" ]] || smoke_fail "case8: backup must capture the original symlink raw target"
smoke_log "case8 PASS (explicit restore-file installed, original symlink backed up)"

# ---------------------------------------------------------------------------
# Case 9 — non-regular restore-file (a directory): must be rejected as
# repair_failed BEFORE any mutation; the operator global stays the symlink.
fresh_fixture
EFF="$(mk_effective "$TARGET_ROOT" "data/agents/sys-monitor/home/.claude/settings.effective.json")"
ln -s "$EFF" "$OP_GLOBAL"
RESTORE_DIR="$BASE/a-restore-dir"
mkdir -p "$RESTORE_DIR"
JSON="$(run_cleanup "$HOME_DIR" "$TARGET_ROOT" --repair-operator-global-settings-hijack --operator-global-settings-restore-file "$RESTORE_DIR")"
smoke_assert_eq "$(hijack_field "$JSON" status)" "repair_failed" "case9: directory restore-file rejected"
smoke_assert_contains "$(hijack_field "$JSON" message)" "regular file" "case9: rejection names regular-file requirement"
[[ -L "$OP_GLOBAL" ]] || smoke_fail "case9: operator global must remain the symlink after a rejected restore-file"
[[ "$(readlink "$OP_GLOBAL")" == "$EFF" ]] || smoke_fail "case9: symlink target unchanged after rejected restore-file"
smoke_log "case9 PASS (non-regular restore-file rejected before mutation)"

smoke_log "$SMOKE_NAME: all cases passed"
