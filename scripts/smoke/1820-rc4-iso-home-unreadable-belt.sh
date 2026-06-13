#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1820-rc4-iso-home-unreadable-belt.sh
#
# Issue #1820 rc4 — the systemic iso-boundary graceful-skip across controller
# scanners, AND the test-rig TOPOLOGY fix.
#
# cm-prod (first real Linux iso-v2 production host) soaked rc3 + the #1876 iso
# reconcile skip and it covered only 2 of 8 iso bots. Root cause: on a properly
# isolated v2 agent the agent HOME itself is `2770 owner=agent-bridge-<a>:
# ab-agent-<a>` with the controller NOT a group member — so `os.scandir(home)`
# throws `[Errno 13] Permission denied` BEFORE any per-file skip. 6 of 8 bots
# were ALSO absent from the engine's iso map (incomplete registry metadata in
# the reconcile driver context), so the up-front `iso_agents.get(agent)` skip
# never fired and the home traversal threw Errno13 → an unstructured perm
# WARNING, with NO isolation_v2_migration entry.
#
# The previous rc3 rig (1820-iso-reconcile-permission.sh) chmod-000'd the
# agent-private FILE, leaving the HOME controller-traversable — which is exactly
# why gate-2 gave a false "zero Errno13": os.scandir(home) succeeded. THIS smoke
# fixes the topology: it makes the iso bot HOME ITSELF unreadable (chmod 000 dir
# = the controller-non-member stand-in for 2770), so `os.scandir(home)` throws
# Errno13 for this (non-root) user — reproducing cm-prod.
#
# Asserts:
#   PRE  — engine over the HOME-unreadable iso bot WITHOUT --host-iso-active
#          (shared-mode contract) reproduces the cm-prod symptom: >=1 Errno13
#          perm-warning, 0 isolation_v2_migration entries.
#   POST — the SAME fixture WITH --host-iso-active (iso-v2-active host, the
#          defensive belt) records 0 warnings + exactly 1 structured
#          isolation_v2_migration entry (action skipped-iso-private, reason
#          home-unreadable-controller), and the v2 memory is UNTOUCHED.
#          Crucially the bot is NOT in the iso map — proving the belt covers the
#          cm-prod 6/8 "absent from map" case, not just the cleanly-classified
#          agents.
#   WD   — the watchdog downgrades a permission_denied scan_error on a
#          registry-classified iso agent out of the problem count into the
#          auditable iso_skipped bucket on a Linux host, while a shared-mode
#          agent's identical denial stays a problem; on a Darwin host NOTHING is
#          downgraded (byte-identical legacy behavior).
#   TRIP — static tripwires bind the belt + downgrade + common helper to source.
#
# Portability (macOS / CI have no real cross-UID boundary): chmod-000 on a dir
# gives a non-root user the same Errno13 as the real 2770 boundary; the host
# platform is stubbed via BRIDGE_HOST_PLATFORM_OVERRIDE. Root can read 000, so
# the rig teeth that need a real denial are skipped when run as uid 0; the real
# dual-UID Linux re-gate runs at patch-dev gate-2.
#
# Footgun #11: NO heredoc-stdin to any subprocess; fixtures via printf, JSON
# probed file-as-argv. Run under Bash 5.x (macOS system bash is 3.2).

set -uo pipefail
SMOKE_NAME="1820-rc4-iso-home-unreadable-belt"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"
ENGINE="$REPO_ROOT/lib/upgrade-helpers/layout-v2-reconcile.py"
WATCHDOG="$REPO_ROOT/bridge-watchdog.py"
COMMON="$REPO_ROOT/lib/bridge_iso_boundary.py"
PROBE="$REPO_ROOT/scripts/smoke/1820-iso-reconcile-permission-probe.py"

UNREADABLE_DIR=""
UNREADABLE_DIR2=""
cleanup() {
  [[ -n "$UNREADABLE_DIR"  && -e "$UNREADABLE_DIR"  ]] && chmod 0755 "$UNREADABLE_DIR"  2>/dev/null || true
  [[ -n "$UNREADABLE_DIR2" && -e "$UNREADABLE_DIR2" ]] && chmod 0755 "$UNREADABLE_DIR2" 2>/dev/null || true
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_make_temp_root "$SMOKE_NAME"
smoke_assert_file_exists "$ENGINE"   "reconcile engine"
smoke_assert_file_exists "$WATCHDOG" "watchdog"
smoke_assert_file_exists "$COMMON"   "common iso-boundary helper"
smoke_assert_file_exists "$PROBE"    "iso-reconcile probe helper"

IS_ROOT=0
[[ "$(id -u 2>/dev/null || echo 1)" == "0" ]] && IS_ROOT=1

probe_result() {
  python3 "$PROBE" "$1" "$2" "$3"
}

run_engine() {
  # run_engine <bridge_home> <data_root> <agents_csv> <backup_root> [host_iso_active=0|1]
  local bh="$1" dr="$2" agents="$3" bkp="$4" host_iso="${5:-0}"
  local -a argv=(
    "$ENGINE"
    --bridge-home "$bh"
    --data-root "$dr"
    --agents-csv "$agents"
    --mode apply
    --backup-root "$bkp"
  )
  [[ "$host_iso" == "1" ]] && argv+=(--host-iso-active)
  python3 "${argv[@]}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Fixture: iso bot `isobot` whose v1 agent HOME ITSELF is unreadable (chmod 000
# dir) — the 2770 controller-non-member stand-in. The bot is intentionally NOT
# passed in any --iso-agents-json (reproducing cm-prod's 6/8 "absent from the
# map" case). v2 home present with its own memory.
# ---------------------------------------------------------------------------
BH="$SMOKE_TMP_ROOT/bh"
DR="$SMOKE_TMP_ROOT/dr"
mkdir -p "$BH/agents/isobot" "$DR/agents/isobot/home"
printf 'shared-line\nv1-only-line\n' >"$BH/agents/isobot/MEMORY.md"
printf 'shared-line\n' >"$DR/agents/isobot/home/MEMORY.md"
V2_MEM="$DR/agents/isobot/home/MEMORY.md"
V2_BASELINE="$SMOKE_TMP_ROOT/v2-baseline.md"
cp "$V2_MEM" "$V2_BASELINE"

# Make the HOME directory itself unreadable/un-scandir-able for this user.
chmod 000 "$BH/agents/isobot"
UNREADABLE_DIR="$BH/agents/isobot"

if [[ "$IS_ROOT" == "1" ]]; then
  smoke_log "PRE/POST SKIP: running as root (chmod 000 does not block root scandir; needs a non-root run or the real dual-UID Linux rig — see gate-2 re-gate)"
else
  # PRE — shared-mode contract (no --host-iso-active): cm-prod symptom reproduced.
  PRE_OUT="$(run_engine "$BH" "$DR" isobot "$SMOKE_TMP_ROOT/bkp-pre" 0)"
  printf '%s' "$PRE_OUT" >"$SMOKE_TMP_ROOT/pre.json"
  read -r PRE_ERRNO PRE_ISOCOUNT _PRE_ACT _PRE_DRIFT < <(probe_result "$SMOKE_TMP_ROOT/pre.json" "$V2_MEM" "$V2_BASELINE")
  [[ "$PRE_ERRNO" == "1" ]] || smoke_fail "PRE FAIL: HOME-unreadable iso bot must raise >=1 Errno13 warning WITHOUT --host-iso-active (the cm-prod symptom the rig must reproduce); got none\n$PRE_OUT"
  [[ "$PRE_ISOCOUNT" == "0" ]] || smoke_fail "PRE FAIL: WITHOUT --host-iso-active there must be no isolation_v2_migration entry, got $PRE_ISOCOUNT"
  smoke_log "PRE PASS: rig reproduces cm-prod — os.scandir(home) Errno13 surfaces as a warning, 0 structured iso entries (shared-mode contract)"

  # POST — iso-v2-active host (--host-iso-active): belt downgrades to a skip.
  POST_OUT="$(run_engine "$BH" "$DR" isobot "$SMOKE_TMP_ROOT/bkp-post" 1)"
  printf '%s' "$POST_OUT" >"$SMOKE_TMP_ROOT/post.json"
  read -r POST_ERRNO POST_ISOCOUNT POST_ACTION POST_DRIFT < <(probe_result "$SMOKE_TMP_ROOT/post.json" "$V2_MEM" "$V2_BASELINE")
  [[ "$POST_ERRNO" == "0" ]] || smoke_fail "POST FAIL: an Errno13 warning was emitted WITH --host-iso-active (expected 0 — the belt must absorb it)\n$POST_OUT"
  [[ "$POST_ISOCOUNT" == "1" ]] || smoke_fail "POST FAIL: expected exactly 1 isolation_v2_migration entry (one structured skip per iso agent), got $POST_ISOCOUNT\n$POST_OUT"
  [[ "$POST_ACTION" == "skipped-iso-private" ]] || smoke_fail "POST FAIL: expected action skipped-iso-private, got '$POST_ACTION'\n$POST_OUT"
  [[ "$POST_DRIFT" == "0" ]] || smoke_fail "POST FAIL: iso agent's v2 memory DRIFTED (must be untouched / drift 0)"
  # Assert the belt-specific reason (distinct from the clean up-front skip).
  python3 "$PROBE" "$SMOKE_TMP_ROOT/post.json" "$V2_MEM" "$V2_BASELINE" >/dev/null
  REASON="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["isolation_v2_migration"][0].get("reason","-"))' "$SMOKE_TMP_ROOT/post.json")"
  [[ "$REASON" == "home-unreadable-controller" ]] || smoke_fail "POST FAIL: expected belt reason home-unreadable-controller, got '$REASON'"
  smoke_log "POST PASS: belt absorbs the home-unreadable Errno13 — 0 warnings, 1 structured skip (skipped-iso-private / home-unreadable-controller), v2 drift 0, bot NOT in any iso map (covers cm-prod 6/8)"
fi

# ---------------------------------------------------------------------------
# WD — watchdog downgrades the pure expected-iso-boundary row out of the
# problem count; not_found/os_error and shared-mode denials stay problems.
# ---------------------------------------------------------------------------
WD_BH="$SMOKE_TMP_ROOT/wd/bh"
mkdir -p "$WD_BH/agents/isobot/workdir" "$WD_BH/agents/plainbot/workdir" "$WD_BH/state"
# Both workdirs unreadable (chmod 000) → permission_denied scan_error rows.
chmod 000 "$WD_BH/agents/isobot/workdir"
chmod 000 "$WD_BH/agents/plainbot/workdir"
UNREADABLE_DIR2="$WD_BH/agents/isobot/workdir"
REG="$SMOKE_TMP_ROOT/wd/reg.json"
mkdir -p "$SMOKE_TMP_ROOT/wd"
printf '%s\n' \
  '[' \
  "  {\"id\":\"isobot\",\"engine\":\"claude\",\"agent_source\":\"static\",\"workdir\":\"$WD_BH/agents/isobot/workdir\",\"home\":\"$WD_BH/agents/isobot\",\"isolation_mode\":\"linux-user\",\"os_user\":\"agent-bridge-isobot\"}," \
  "  {\"id\":\"plainbot\",\"engine\":\"claude\",\"agent_source\":\"static\",\"workdir\":\"$WD_BH/agents/plainbot/workdir\",\"home\":\"$WD_BH/agents/plainbot\",\"isolation_mode\":\"\",\"os_user\":\"\"}" \
  ']' >"$REG"

if [[ "$IS_ROOT" == "1" ]]; then
  smoke_log "WD SKIP: running as root (chmod 000 workdir is root-readable; real denial needs a non-root run / the gate-2 rig)"
else
  WD_LINUX="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Linux python3 "$WATCHDOG" scan --bridge-home "$WD_BH" --agent-registry-json "$REG" --json 2>/dev/null)"
  read -r WD_PROB WD_SKIP < <(printf '%s' "$WD_LINUX" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["problem_count"], d["iso_skipped_count"])')
  [[ "$WD_SKIP" == "1" ]] || smoke_fail "WD FAIL (Linux): expected 1 iso_skipped (isobot permission_denied downgraded), got $WD_SKIP\n$WD_LINUX"
  [[ "$WD_PROB" == "1" ]] || smoke_fail "WD FAIL (Linux): expected plainbot's denial to STAY a problem (problem_count=1), got $WD_PROB\n$WD_LINUX"
  WD_AGENTS="$(printf '%s' "$WD_LINUX" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["iso_skipped_agents"]))')"
  [[ "$WD_AGENTS" == "isobot" ]] || smoke_fail "WD FAIL (Linux): only isobot should be downgraded, got '$WD_AGENTS'"
  smoke_log "WD PASS (Linux): isobot permission_denied downgraded to iso_skipped; plainbot (shared-mode) denial stays a problem"

  WD_MAC="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin python3 "$WATCHDOG" scan --bridge-home "$WD_BH" --agent-registry-json "$REG" --json 2>/dev/null)"
  read -r WD_MPROB WD_MSKIP < <(printf '%s' "$WD_MAC" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["problem_count"], d["iso_skipped_count"])')
  [[ "$WD_MSKIP" == "0" ]] || smoke_fail "WD FAIL (Darwin): nothing must be downgraded off Linux, got iso_skipped=$WD_MSKIP\n$WD_MAC"
  [[ "$WD_MPROB" == "2" ]] || smoke_fail "WD FAIL (Darwin): both denials must stay problems off Linux (problem_count=2), got $WD_MPROB\n$WD_MAC"
  smoke_log "WD PASS (Darwin): no iso downgrade off Linux — both denials stay problems (byte-identical legacy behavior)"
fi

# ---------------------------------------------------------------------------
# TRIP — static tripwires bind the rc4 behavior to source.
# ---------------------------------------------------------------------------
grep -q 'host_iso_active' "$ENGINE" \
  || smoke_fail "TRIP FAIL: engine lost the --host-iso-active belt gate"
grep -q 'home-unreadable-controller' "$COMMON" \
  || smoke_fail "TRIP FAIL: common helper lost the home-unreadable-controller skip reason"
grep -q 'iso_boundary_applies' "$COMMON" \
  || smoke_fail "TRIP FAIL: common helper lost the registry classifier iso_boundary_applies"
grep -q 'is_expected_iso_permission_boundary' "$COMMON" \
  || smoke_fail "TRIP FAIL: common helper lost the watchdog downgrade predicate"
grep -q 'iso_skipped_count' "$WATCHDOG" \
  || smoke_fail "TRIP FAIL: watchdog lost the iso_skipped downgrade bucket"
grep -q 'is_expected_iso_boundary_row' "$WATCHDOG" \
  || smoke_fail "TRIP FAIL: watchdog lost the per-row iso-boundary classifier"
grep -q 'host-iso-active' "$REPO_ROOT/lib/bridge-layout-v2-reconcile.sh" \
  || smoke_fail "TRIP FAIL: reconcile wrapper no longer passes the host-iso-active signal to the engine"
grep -q 'bridge_layout_v2_reconcile_host_iso_active' "$REPO_ROOT/lib/bridge-layout-v2-reconcile.sh" \
  || smoke_fail "TRIP FAIL: reconcile wrapper lost the host-iso-active classifier"
smoke_log "TRIP PASS: rc4 belt + watchdog downgrade + common helper + wrapper wiring all bound to source"

smoke_log "all 1820-rc4-iso-home-unreadable-belt tests PASS"
