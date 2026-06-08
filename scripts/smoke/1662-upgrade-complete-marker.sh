#!/usr/bin/env bash
# scripts/smoke/1662-upgrade-complete-marker.sh
#
# Issue #1662 — `agb upgrade --apply` (default --restart-daemon/--restart-agents)
# self-restarts its own invoking session on a sudo-self systemd install →
# SIGKILL → exit 137, even though the upgrade SUCCEEDED. Fix (codex consensus,
# marker+notice — NOT skip-self-restart): bridge-upgrade.sh writes a DURABLE
# success marker (state/upgrade/upgrade-complete.json) AFTER all
# apply/migrate/reclassify work and BEFORE the restart phase begins, and emits a
# clear notice that exit 137 is EXPECTED-success. The marker distinguishes
# phase=work-complete (written before restart) from phase=restart-complete
# (every restart step survived). Success is observable INDEPENDENT of the
# session SIGKILL because the marker is flushed before the restart starts.
#
# Test seam: the marker/notice block AND its two helper functions are extracted
# VERBATIM from bridge-upgrade.sh by literal BEGIN/END markers (deleting/renaming
# trips this test) and eval'd in a subshell against an isolated $TMP TARGET_ROOT.
# We assert the marker is written, carries the right phase + status + version,
# and that the notice text appears — without triggering a real systemd self-kill
# (impossible in CI). Every assertion has teeth: pre-fix (no marker block / no
# helper) the marker-write + notice checks FAIL.
#
# Footgun #11: no heredoc-fed subprocess — printf only. Runs entirely under an
# isolated $TMP; never touches operator state.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
UPGRADE_SH="$ROOT_DIR/bridge-upgrade.sh"

[[ -f "$UPGRADE_SH" ]] || { printf 'FAIL (bootstrap): missing %s\n' "$UPGRADE_SH" >&2; exit 2; }

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP="$(mktemp -d -t agb-1662-upgrade-complete-marker.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Extract the helper functions + the marker/notice block by literal markers.
HELPERS_BLOCK="$(sed -n '/^# BEGIN: Issue #1662 upgrade-complete marker helpers$/,/^# END: Issue #1662 upgrade-complete marker helpers$/p' "$UPGRADE_SH")"
MARKER_BLOCK="$(sed -n '/^# BEGIN: Issue #1662 upgrade-complete marker + restart notice$/,/^# END: Issue #1662 upgrade-complete marker + restart notice$/p' "$UPGRADE_SH")"

if [[ -z "$HELPERS_BLOCK" ]]; then
  printf 'FAIL (bootstrap): could not extract issue #1662 helper block — regression?\n' >&2
  exit 2
fi
if [[ -z "$MARKER_BLOCK" ]]; then
  printf 'FAIL (bootstrap): could not extract issue #1662 marker/notice block — regression?\n' >&2
  exit 2
fi

# Read a top-level string field from the marker JSON without a JSON parser
# (keeps this smoke heredoc-free + dependency-light). Greps `"key": "value"`.
marker_field() {
  # $1=marker-file $2=key
  sed -n 's/.*"'"$2"'": *"\([^"]*\)".*/\1/p' "$1" | head -n1
}

# Drive the extracted block in a subshell with the upgrade-block's required
# runtime context. The block references DRY_RUN, RESTART_DAEMON, RESTART_AGENTS,
# TARGET_ROOT, SOURCE_VERSION, UPGRADE_RUN_ID, and the helpers (sourced from
# HELPERS_BLOCK). Writes the marker under $TARGET_ROOT/state/upgrade/.
run_block() {
  # $1=DRY_RUN $2=RESTART_DAEMON $3=RESTART_AGENTS $4=TARGET_ROOT
  (
    DRY_RUN="$1"
    RESTART_DAEMON="$2"
    RESTART_AGENTS="$3"
    TARGET_ROOT="$4"
    SOURCE_VERSION="9.9.9"
    UPGRADE_RUN_ID="20990101T000000Z-12345"
    _BRIDGE_UPGRADE_COMPLETE_MARKER_PATH=""
    # Invoked indirectly by the eval'd helper block on its WARN paths.
    # shellcheck disable=SC2329
    bridge_warn() { printf '[shim warn] %s\n' "$*" >&2; }
    eval "$HELPERS_BLOCK"
    eval "$MARKER_BLOCK"
  ) >"$TMP/block.out" 2>"$TMP/block.err"
}

# ---------------------------------------------------------------------------
# T1 — --apply with restart: marker written (phase=work-complete) BEFORE the
# restart phase, carrying the right status + version; notice emitted.
# ---------------------------------------------------------------------------
printf '== T1 — marker written + notice emitted on a restarting apply ==\n'
T1_ROOT="$TMP/t1-target"; mkdir -p "$T1_ROOT/state"
MARKER="$T1_ROOT/state/upgrade/upgrade-complete.json"
run_block 0 1 1 "$T1_ROOT"

step "marker file exists after the work-complete write"
if [[ -f "$MARKER" ]]; then ok; else err "marker not written at $MARKER"; fi

step "marker phase == work-complete (written before the restart phase)"
if [[ "$(marker_field "$MARKER" phase)" == "work-complete" ]]; then ok; else err "phase=$(marker_field "$MARKER" phase)"; fi

step "marker status == ok"
if [[ "$(marker_field "$MARKER" status)" == "ok" ]]; then ok; else err "status=$(marker_field "$MARKER" status)"; fi

step "marker carries the upgrade version"
if [[ "$(marker_field "$MARKER" version)" == "9.9.9" ]]; then ok; else err "version=$(marker_field "$MARKER" version)"; fi

step "marker note names the exit-137-is-expected contract"
if grep -q 'exit 137' "$MARKER"; then ok; else err "marker note missing the exit-137 contract: $(cat "$MARKER")"; fi

step "marker is valid JSON (parses)"
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MARKER" 2>/dev/null; then ok; else err "marker is not valid JSON: $(cat "$MARKER")"; fi

step "notice tells the caller the upgrade is COMPLETE"
case "$(cat "$TMP/block.err")" in
  *"upgrade COMPLETE"*) ok ;;
  *) err "missing COMPLETE notice on stderr: $(cat "$TMP/block.err")" ;;
esac

step "notice tells the caller exit 137 is EXPECTED, not a failure"
case "$(cat "$TMP/block.err")" in
  *"exit 137"*"EXPECTED"*) ok ;;
  *) err "missing exit-137-expected notice on stderr: $(cat "$TMP/block.err")" ;;
esac

step "notice points the caller at the marker as the source of truth"
case "$(cat "$TMP/block.err")" in
  *"upgrade-complete.json"*) ok ;;
  *) err "notice does not reference the marker path: $(cat "$TMP/block.err")" ;;
esac

step "notice goes to STDERR (keeps --json stdout parseable)"
if [[ ! -s "$TMP/block.out" ]]; then ok; else err "block wrote to stdout (would corrupt --json): $(cat "$TMP/block.out")"; fi

# ---------------------------------------------------------------------------
# T2 — --no-restart-daemon AND --no-restart-agents: marker STILL written (the
# work completed) but the exit-137 NOTICE is suppressed (nothing cycles the
# session, so the caveat does not apply).
# ---------------------------------------------------------------------------
printf '== T2 — no-restart: marker written, exit-137 notice suppressed ==\n'
T2_ROOT="$TMP/t2-target"; mkdir -p "$T2_ROOT/state"
T2_MARKER="$T2_ROOT/state/upgrade/upgrade-complete.json"
run_block 0 0 0 "$T2_ROOT"

step "marker still written when no restart was requested"
if [[ -f "$T2_MARKER" ]]; then ok; else err "marker not written for no-restart apply"; fi

step "no exit-137 notice when neither daemon nor agents restart"
case "$(cat "$TMP/block.err")" in
  *"exit 137"*) err "emitted exit-137 notice with --no-restart-daemon --no-restart-agents" ;;
  *) ok ;;
esac

step "marker records restart_daemon=false / restart_agents=false"
if grep -q '"restart_daemon": false' "$T2_MARKER" && grep -q '"restart_agents": false' "$T2_MARKER"; then
  ok
else
  err "restart flags not recorded as false: $(cat "$T2_MARKER")"
fi

# ---------------------------------------------------------------------------
# T3 — --dry-run: NO marker written, NO notice (no work was applied).
# ---------------------------------------------------------------------------
printf '== T3 — dry-run writes no marker, no notice ==\n'
T3_ROOT="$TMP/t3-target"; mkdir -p "$T3_ROOT/state"
T3_MARKER="$T3_ROOT/state/upgrade/upgrade-complete.json"
run_block 1 1 1 "$T3_ROOT"

step "no marker written under --dry-run"
if [[ -e "$T3_MARKER" ]]; then err "marker written on dry-run: $(cat "$T3_MARKER")"; else ok; fi

step "no notice emitted under --dry-run"
if [[ -s "$TMP/block.err" ]]; then err "dry-run emitted notice text: $(cat "$TMP/block.err")"; else ok; fi

# ---------------------------------------------------------------------------
# T4 — restart-complete promotion: a second write with phase=restart-complete
# (the post-restart promotion) overwrites the marker in place.
# ---------------------------------------------------------------------------
printf '== T4 — restart-complete phase promotion ==\n'
T4_ROOT="$TMP/t4-target"; mkdir -p "$T4_ROOT/state"
T4_MARKER="$T4_ROOT/state/upgrade/upgrade-complete.json"
(
  TARGET_ROOT="$T4_ROOT"
  SOURCE_VERSION="9.9.9"
  UPGRADE_RUN_ID="r"
  _BRIDGE_UPGRADE_COMPLETE_MARKER_PATH=""
  # Invoked indirectly by the eval'd helper block on its WARN paths.
  # shellcheck disable=SC2329
  bridge_warn() { :; }
  eval "$HELPERS_BLOCK"
  # work-complete first, then promote to restart-complete (mirrors the prod
  # ordering: pre-restart write, then post-restart promotion).
  _bridge_upgrade_write_complete_marker "$T4_ROOT" "work-complete" "9.9.9" "1" "1"
  _bridge_upgrade_write_complete_marker "$T4_ROOT" "restart-complete" "9.9.9" "1" "1"
) >/dev/null 2>&1

step "marker phase promoted to restart-complete"
if [[ "$(marker_field "$T4_MARKER" phase)" == "restart-complete" ]]; then ok; else err "phase=$(marker_field "$T4_MARKER" phase)"; fi

step "exactly one marker file (promotion overwrites in place, not appended)"
_count="$(find "$T4_ROOT/state/upgrade" -maxdepth 1 -name 'upgrade-complete.json' | wc -l | tr -d ' ')"
if [[ "$_count" == "1" ]]; then ok; else err "expected 1 marker file, found $_count"; fi

step "no stray temp file left behind by the atomic write"
if find "$T4_ROOT/state/upgrade" -maxdepth 1 -name '.upgrade-complete.*' | grep -q .; then
  err "atomic-write temp file left behind"
else
  ok
fi

# ---------------------------------------------------------------------------
# T5 — JSON envelope wiring: bridge-upgrade.sh surfaces the marker as the
# `upgrade_complete_marker` field, sourced from the on-disk marker file.
# ---------------------------------------------------------------------------
printf '== T5 — --json surfaces the upgrade_complete_marker field ==\n'
step "JSON payload dict includes the upgrade_complete_marker key"
if grep -q '"upgrade_complete_marker": upgrade_complete_payload' "$UPGRADE_SH"; then ok; else err "envelope missing upgrade_complete_marker field wiring"; fi

step "JSON emit copies the on-disk marker into the payload dir"
if grep -q 'state/upgrade/upgrade-complete.json' "$UPGRADE_SH"; then ok; else err "JSON emit does not read the on-disk marker"; fi

# ---------------------------------------------------------------------------
# T6 — ordering: the marker END marker precedes the daemon stop/restart it
# guards (success is flushed BEFORE the restart that can SIGKILL the session).
# Anchor to the FIRST `stop --force` that appears AFTER the marker block — an
# earlier `stop --force` exists on the analyze/check early path and is unrelated.
# ---------------------------------------------------------------------------
printf '== T6 — marker write precedes the restart phase in source order ==\n'
_marker_end_line="$(grep -n '^# END: Issue #1662 upgrade-complete marker + restart notice$' "$UPGRADE_SH" | head -n1 | cut -d: -f1)"
# First daemon stop/restart at or after the marker END line.
_restart_line="$(grep -n 'bridge-daemon.sh" stop --force' "$UPGRADE_SH" \
  | awk -F: -v m="$_marker_end_line" '$1 > m { print $1; exit }')"
step "work-complete marker block is BEFORE the daemon stop/restart it guards"
if [[ -n "$_marker_end_line" && -n "$_restart_line" && "$_marker_end_line" -lt "$_restart_line" ]]; then
  ok
else
  err "marker block END (line $_marker_end_line) not before the guarded restart (line $_restart_line)"
fi

# ---------------------------------------------------------------------------
printf '\n== 1662-upgrade-complete-marker: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
