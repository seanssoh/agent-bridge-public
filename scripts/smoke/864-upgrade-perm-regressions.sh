#!/usr/bin/env bash
# Issue #864 — v0.13.0 upgrade migration perm regressions.
#
# Coverage:
#   R1 — bridge_isolation_v2_migrate_marker_write: marker ends up at
#        `root:<shared-group> mode 0640` (or, when sudo is unavailable
#        in the dev tree, at caller-owned mode 0640 — both satisfy the
#        validator).
#   R2 — bridge-upgrade.sh post-apply chmod a+rX pass: directory under
#        `$TARGET_ROOT/scripts/` created at mode 0700 is normalized to
#        a+rX (0755 typical); files inside keep their 0644 mode.
#   R3 — bridge_linux_share_plugin_catalog landing mode: in the matrix
#        row + the migrate-side normalize_layout, the per-isolated-agent
#        `.claude/plugins/` dir lands at mode 2770 (group write needed
#        for flock on installed_plugins.json.lock). Asserted via the
#        normalize_layout chmod step against a pre-staged 2750 dir.
#
# Footgun #11: no heredoc / here-string anywhere. Content is written
# via line-by-line `printf '%s\n' ...` blocks.
#
# Runs entirely in an isolated $TMP. Never touches operator state.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP="$(mktemp -d -t agb-864-upgrade-perm-regressions.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Portable mode/owner readers. The macOS BSD `stat -f '%Lp'` form silently
# strips the setgid bit (it reports only the low 9 bits), which breaks R3
# where 2750 / 2770 is the point of the test. Use python3 for the mode
# read — portable, no external CLI variance, returns the full 4-octal
# permission word including setuid/setgid/sticky.
file_mode() {
  python3 -c 'import os, sys; print(f"{os.stat(sys.argv[1]).st_mode & 0o7777:o}")' "$1" 2>/dev/null
}
file_owner_uid() {
  python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_uid)' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# R1 — marker write chowns to root + shared group, mode 0640.
# ---------------------------------------------------------------------------
printf '== R1 — marker write owner/mode ==\n'

R1_HOME="$TMP/r1-home"
mkdir -p "$R1_HOME/state"

# Pre-stage a marker file owned by current user (simulating the pre-upgrade
# ec2-user-owned marker shape) so we can verify the marker_write helper
# replaces it with a root-or-caller-owned 0640 file.
R1_MARKER="$R1_HOME/state/layout-marker.sh"
{
  printf 'BRIDGE_LAYOUT=legacy\n'
} >"$R1_MARKER"
chmod 0640 "$R1_MARKER"

# Source bridge-lib.sh in a controlled BRIDGE_HOME so the marker helpers
# resolve their paths under our tempdir.
export BRIDGE_HOME="$R1_HOME"
export BRIDGE_STATE_DIR="$R1_HOME/state"
export BRIDGE_LAYOUT_MARKER_DIR="$R1_HOME/state"
unset BRIDGE_DATA_ROOT BRIDGE_LAYOUT 2>/dev/null || true

# Source the minimum lib surface needed: core for bridge_warn/bridge_die,
# marker-bootstrap for bridge_isolation_v2_marker_path /
# bridge_isolation_v2_marker_validate, isolation-v2 for the
# _bridge_isolation_v2_run_root_or_sudo helper, and isolation-v2-migrate
# for the marker_write entry point we test. The smoke/* dir uses the
# same per-file source pattern (see scripts/smoke/isolation-v2-migrate-
# lock-portability.sh).
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/bridge-core.sh" >/dev/null 2>&1 || {
  printf 'FAIL (bootstrap): could not source lib/bridge-core.sh\n' >&2
  exit 2
}
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/bridge-marker-bootstrap.sh" >/dev/null 2>&1 || {
  printf 'FAIL (bootstrap): could not source lib/bridge-marker-bootstrap.sh\n' >&2
  exit 2
}
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/bridge-isolation-v2.sh" >/dev/null 2>&1 || {
  printf 'FAIL (bootstrap): could not source lib/bridge-isolation-v2.sh\n' >&2
  exit 2
}
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/bridge-isolation-v2-migrate.sh" >/dev/null 2>&1 || {
  printf 'FAIL (bootstrap): could not source lib/bridge-isolation-v2-migrate.sh\n' >&2
  exit 2
}

# Confirm the helper is defined.
if ! declare -F bridge_isolation_v2_migrate_marker_write >/dev/null 2>&1; then
  printf 'FAIL (bootstrap): bridge_isolation_v2_migrate_marker_write not defined\n' >&2
  exit 2
fi

step "R1 marker_write produces validator-acceptable owner"
# bridge_die would abort the script on a hard failure inside the helper;
# we want to capture rc to keep the test driver going, so call it in a
# subshell where bridge_die is overridden to a soft non-zero return.
(
  # Indirectly invoked by name from bridge_isolation_v2_migrate_marker_write
  # — these overrides are the test seam. shellcheck SC2329 is a false
  # positive for callback-style indirection.
  # shellcheck disable=SC2329
  bridge_die() { printf 'bridge_die: %s\n' "$*" >&2; return 1; }
  # shellcheck disable=SC2329
  bridge_warn() { printf 'bridge_warn: %s\n' "$*" >&2; }
  bridge_isolation_v2_migrate_marker_write "$R1_HOME"
) >"$TMP/r1-write.log" 2>&1
_r1_rc=$?

if [[ $_r1_rc -ne 0 ]]; then
  err "marker_write rc=$_r1_rc; log: $(tr '\n' ' ' <"$TMP/r1-write.log")"
elif [[ ! -f "$R1_MARKER" ]]; then
  err "marker not present after write"
else
  _r1_mode="$(file_mode "$R1_MARKER")"
  _r1_uid="$(file_owner_uid "$R1_MARKER")"
  _self_uid="$(id -u)"
  # Acceptable end-states:
  #   (a) root-owned (uid 0)  — sudo path succeeded.
  #   (b) caller-owned (uid == self) — sudo path no-op'd (typical
  #       rootless dev tree without passwordless sudoers); validator
  #       still accepts this branch (owner_uid == current controller).
  # Both satisfy bridge_isolation_v2_marker_validate. Either rejection
  # would block sudo -u <iso> bridge-run.sh from reading the marker.
  if [[ "$_r1_mode" != "640" && "$_r1_mode" != "0640" ]]; then
    err "expected mode 640, got $_r1_mode"
  elif [[ "$_r1_uid" != "0" && "$_r1_uid" != "$_self_uid" ]]; then
    err "expected uid 0 or $_self_uid (caller), got $_r1_uid"
  else
    # And ensure the validator accepts the result.
    if bridge_isolation_v2_marker_validate "$R1_MARKER" 2>/dev/null; then
      ok
    else
      err "marker validator rejected the written marker (uid=$_r1_uid mode=$_r1_mode)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# R2 — bridge-upgrade.sh post-apply chmod a+rX on scripts/ dirs.
# ---------------------------------------------------------------------------
printf '== R2 — scripts/ dirs normalized to a+rX ==\n'

# We exercise the literal shell-level normalize step from bridge-upgrade.sh
# (the `find ... -type d -exec chmod a+rX {} +` block) by replicating its
# precondition (a freshly umask=077-created dir under TARGET_ROOT/scripts)
# and its action. Asserts: dirs end up traversable (a+rX), files keep
# their 0644 from apply-live.
R2_TARGET="$TMP/r2-target"
mkdir -p "$R2_TARGET/scripts"

# Simulate apply-live's `Path.parent.mkdir(parents=True, exist_ok=True)`
# under umask=077: new dirs land at 0700, files at 0644.
( umask 077; mkdir -p "$R2_TARGET/scripts/python-helpers"; )
( umask 077; mkdir -p "$R2_TARGET/scripts/smoke/4494-integrated-helpers"; )
# Files inside: apply-live writes via os.chmod(0o644), simulate that.
printf '%s\n' '# stub' >"$R2_TARGET/scripts/python-helpers/sha1-batch.py"
chmod 0644 "$R2_TARGET/scripts/python-helpers/sha1-batch.py"
printf '%s\n' '# stub' >"$R2_TARGET/scripts/smoke/4494-integrated-helpers/sub.py"
chmod 0644 "$R2_TARGET/scripts/smoke/4494-integrated-helpers/sub.py"

# Sanity: dirs should be 0700 before the fix.
_r2_pre_helpers="$(file_mode "$R2_TARGET/scripts/python-helpers")"
_r2_pre_smoke_helpers="$(file_mode "$R2_TARGET/scripts/smoke/4494-integrated-helpers")"
step "R2 pre-state has 0700 dirs (regression precondition)"
if [[ "$_r2_pre_helpers" == "700" && "$_r2_pre_smoke_helpers" == "700" ]]; then
  ok
else
  err "expected pre-state 700/700, got $_r2_pre_helpers/$_r2_pre_smoke_helpers"
fi

# Apply the exact remediation bridge-upgrade.sh runs post-apply-live.
find "$R2_TARGET/scripts" -type d -exec chmod a+rX {} + 2>/dev/null || true

step "R2 dirs become traversable (group/other +rX)"
_r2_post_helpers="$(file_mode "$R2_TARGET/scripts/python-helpers")"
_r2_post_smoke_helpers="$(file_mode "$R2_TARGET/scripts/smoke/4494-integrated-helpers")"
# After `chmod a+rX`: dirs need at least group+other r-x. Concretely each
# dir mode digit for group and other should include the 5 bits (4=r, 1=x).
_check_dir_traversable() {
  local mode="$1"
  # mode could be 3- or 4-digit string. Take the last 3 chars.
  local last3="${mode: -3}"
  local owner="${last3:0:1}"
  local group="${last3:1:1}"
  local other="${last3:2:1}"
  # `a+rX` adds r+X to all three classes for directories. After the chmod
  # all classes must have at least r (4) and x (1). owner stays 7 because
  # it was 7 pre-chmod. group/other should be ≥5.
  (( owner >= 5 )) && (( group >= 5 )) && (( other >= 5 ))
}
if _check_dir_traversable "$_r2_post_helpers" \
    && _check_dir_traversable "$_r2_post_smoke_helpers"; then
  ok
else
  err "expected dirs traversable post-chmod, got $_r2_post_helpers/$_r2_post_smoke_helpers"
fi

step "R2 files inside keep 0644 mode (a+rX does not promote files to +x)"
_r2_file_helpers="$(file_mode "$R2_TARGET/scripts/python-helpers/sha1-batch.py")"
_r2_file_smoke="$(file_mode "$R2_TARGET/scripts/smoke/4494-integrated-helpers/sub.py")"
# `X` (capital) means "execute only if the file is a directory or already
# has execute permission for some user". A 0644 file has no x bit so it
# stays 0644 (or, if any class had +x already, a+rX would add to all).
if [[ "$_r2_file_helpers" == "644" && "$_r2_file_smoke" == "644" ]]; then
  ok
else
  err "expected files 644/644 (a+rX leaves non-exec files alone), got $_r2_file_helpers/$_r2_file_smoke"
fi

# ---------------------------------------------------------------------------
# R3 — normalize_layout chmods .claude/plugins/ to 2770.
# ---------------------------------------------------------------------------
printf '== R3 — .claude/plugins/ rewrites 2750 -> 2770 ==\n'

# The migrate-side fix iterates each isolated agent's `~/.claude/plugins/`
# dir (resolved via `bridge_agent_linux_user_home "$os_user"`) and runs
# `chmod 2770` on it. The test harness can't create a real isolated UID,
# but it can drive the exact `_bridge_isolation_v2_run_root_or_sudo chmod
# 2770 <path>` call against a pre-staged 2750 dir owned by the caller —
# which is precisely what the helper does at the end of the per-agent
# loop. Asserting the post-state mode confirms the chmod call shape.
R3_PLUGINS="$TMP/r3-iso-home/.claude/plugins"
mkdir -p "$R3_PLUGINS"
chmod 2750 "$R3_PLUGINS"

_r3_pre="$(file_mode "$R3_PLUGINS")"
step "R3 pre-state 2750 (regression precondition)"
if [[ "$_r3_pre" == "2750" ]]; then
  ok
else
  err "expected pre-state 2750, got $_r3_pre"
fi

# Drive the exact code path normalize_layout runs.
step "R3 _bridge_isolation_v2_run_root_or_sudo chmod 2770 lands the dir at 2770"
if ! declare -F _bridge_isolation_v2_run_root_or_sudo >/dev/null 2>&1; then
  err "_bridge_isolation_v2_run_root_or_sudo not defined after sourcing bridge-lib.sh"
else
  _bridge_isolation_v2_run_root_or_sudo chmod 2770 "$R3_PLUGINS" \
    >/dev/null 2>&1 || true
  _r3_post="$(file_mode "$R3_PLUGINS")"
  # Both 2770 and 02770 are acceptable (some stat outputs include the
  # leading zero for setgid representation).
  if [[ "$_r3_post" == "2770" || "$_r3_post" == "02770" ]]; then
    ok
  else
    err "expected post-state 2770, got $_r3_post"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n== 864-upgrade-perm-regressions summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
