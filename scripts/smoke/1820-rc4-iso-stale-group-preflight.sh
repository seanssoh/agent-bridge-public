#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1820-rc4-iso-stale-group-preflight.sh
#
# Issue #1820 rc4 — the SETTLED root cause + fix. cm-prod (first real Linux
# iso-v2 production host) soaked v0.16.10-rc3 and surfaced 6 Errno13 warnings.
# Root cause (CONFIRMED on the real host): NOT topology — the controller
# `awfmanager` IS an on-disk member of every `ab-agent-<a>` group, the iso homes
# are `2770` (group-readable), and a FRESH process reads them fine. The agb
# upgrade invoker was a 15-day-old login shell whose LOGIN-TIME supplementary
# group set predated the 6/4-created bot groups, so the reconcile child inherited
# a STALE group set → os.scandir(2770 home) threw Errno13. This is the
# KNOWN_ISSUES §28 / #1836 stale-supp-group pattern.
#
# The rc4 fix (this rig gates it):
#   1. A SHARED fresh-group preflight (bridge_controller_supp_group_refresh in
#      lib/bridge-agents.sh) used by BOTH the reconcile driver (item 1) and the
#      watchdog entry (item 2): detect the controller's live group set missing a
#      rostered iso agent's on-disk ab-agent-<a> group, then re-exec under `sg`
#      (or, when impossible, WARN — never silently mask).
#   3. The retracted whole-home --host-iso-active belt is REMOVED.
#   4. (A2) File-level 0600 owner-only skip is the SOLE skip mechanism; the rc3
#      #1876 up-front iso-map whole-agent skip is REMOVED. The reconcile ALWAYS
#      traverses the home and reconciles ALL group-readable content; only a
#      genuine 0600 owner-only file is structured-skipped (reason
#      file-owner-only) — at FILE granularity, independent of iso-map
#      completeness (the cm-prod cosmax_sales_mdj no-meta case).
#
# What this rig asserts (portably; the real dual-UID stale-group + 2770 teeth
# are deferred to gate-2):
#   PREFLIGHT — bridge_controller_supp_group_stale_groups / _refresh detect the
#               stale set from a stubbed `id`/`getent`/group-name surface, emit
#               only refreshable (on-disk-member, missing-from-live) groups, and
#               do NOT mask a genuine provisioning gap (non-member group). detect
#               mode returns 10 on stale, 0 on fresh.
#   FILE      — the reconcile file-level skip: an iso agent with a genuine 0600
#               owner-only memory file (chmod 000 file = non-root unreadable
#               stand-in) records a STRUCTURED file-owner-only skip WITH --iso-host
#               (0 warnings), while WITHOUT --iso-host it stays a warning. Its
#               OTHER group-readable content reconciles normally (drift on the
#               group-readable file, only the 0600 file skipped) — the home is
#               ALWAYS traversed, never whole-skipped.
#   NOMETA    — an iso agent ABSENT from the iso-map (the mdj no-agent-meta.env
#               case) still gets the file-level skip WITH --iso-host — proving
#               correctness does NOT depend on iso-map completeness.
#   WD        — the watchdog downgrades a registry-classified permission_denied
#               iso row into the auditable iso_skipped bucket (Linux), keeps a
#               shared-mode denial a problem, downgrades NOTHING off Linux, and —
#               with the stale-group env fallback BRIDGE_WATCHDOG_ISO_GROUP_STALE=1
#               — downgrades an iso-uid-side permission_denied row even when the
#               registry classification is incomplete (the transient restart
#               window the preflight could not refresh).
#   TRIP      — static tripwires bind the preflight + file-level skip + removals
#               + watchdog fallback to source.
#
# Portability: chmod-000 gives a non-root user the same EACCES the real 0600
# boundary does; root bypasses it, so the FILE/NOMETA teeth are skipped under
# uid 0 (the real dual-UID Linux re-gate runs at patch-dev gate-2). The host
# platform is stubbed via BRIDGE_HOST_PLATFORM_OVERRIDE.
#
# Footgun #11: NO heredoc-stdin to any subprocess; fixtures via printf, JSON
# probed file-as-argv. Run under Bash 5.x (macOS system bash is 3.2).

set -uo pipefail
SMOKE_NAME="1820-rc4-iso-stale-group-preflight"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"
ENGINE="$REPO_ROOT/lib/upgrade-helpers/layout-v2-reconcile.py"
WATCHDOG="$REPO_ROOT/bridge-watchdog.py"
COMMON="$REPO_ROOT/lib/bridge_iso_boundary.py"
AGENTS_LIB="$REPO_ROOT/lib/bridge-agents.sh"
RECONCILE_SH="$REPO_ROOT/lib/bridge-layout-v2-reconcile.sh"
RECONCILE_DRIVER="$REPO_ROOT/lib/bridge-layout-v2-reconcile-driver.sh"
WATCHDOG_SH="$REPO_ROOT/bridge-watchdog.sh"
PROBE="$REPO_ROOT/scripts/smoke/1820-rc4-iso-stale-group-probe.py"

UNREADABLE_FILES=()
cleanup() {
  local f
  for f in "${UNREADABLE_FILES[@]:-}"; do
    [[ -n "$f" && -e "$f" ]] && chmod 0644 "$f" 2>/dev/null || true
  done
  smoke_cleanup_temp_root 2>/dev/null || true
  [[ -n "${SMOKE_TMP_ROOT:-}" && -d "$SMOKE_TMP_ROOT" ]] && rm -rf "$SMOKE_TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_make_temp_root "$SMOKE_NAME"
smoke_assert_file_exists "$ENGINE"          "reconcile engine"
smoke_assert_file_exists "$WATCHDOG"        "watchdog"
smoke_assert_file_exists "$COMMON"          "common iso-boundary helper"
smoke_assert_file_exists "$AGENTS_LIB"      "bridge-agents lib"
smoke_assert_file_exists "$RECONCILE_SH"    "reconcile wrapper"
smoke_assert_file_exists "$RECONCILE_DRIVER" "reconcile driver"
smoke_assert_file_exists "$WATCHDOG_SH"     "watchdog entry"
smoke_assert_file_exists "$PROBE"           "rc4 stale-group probe"

IS_ROOT=0
[[ "$(id -u 2>/dev/null || echo 1)" == "0" ]] && IS_ROOT=1

run_engine() {
  # run_engine <bridge_home> <data_root> <agents_csv> <backup_root> \
  #            [iso_host=0|1] [iso_agents_json_file=""]
  local bh="$1" dr="$2" agents="$3" bkp="$4" iso_host="${5:-0}" iso_map="${6:-}"
  local -a argv=(
    "$ENGINE"
    --bridge-home "$bh"
    --data-root "$dr"
    --agents-csv "$agents"
    --mode apply
    --backup-root "$bkp"
  )
  [[ -n "$iso_map" ]] && argv+=(--iso-agents-json "$iso_map")
  [[ "$iso_host" == "1" ]] && argv+=(--iso-host)
  python3 "${argv[@]}" 2>/dev/null
}

# ===========================================================================
# PREFLIGHT — the shared fresh-group classifier + detect mode (item 1 + 2 core).
# Stub `id`, `getent`, and the group-name resolver so a macOS dev host can drive
# the Linux-only logic. We source bridge-agents.sh and shadow the externals via
# functions / a PATH shim.
# ===========================================================================
PRE_STUB_DIR="$SMOKE_TMP_ROOT/preflight-stubs"
mkdir -p "$PRE_STUB_DIR"
# A stubbed `getent group` surface: ab-agent-iso1 (controller IS a member),
# ab-agent-iso2 (controller is NOT a member — a provisioning gap, must NOT be
# emitted as stale). `id -nG` returns a live set that LACKS both iso groups
# (stale). `id -un` returns the controller user.
cat >"$PRE_STUB_DIR/getent" <<'GETENT'
#!/usr/bin/env bash
# stub: getent group <name>
if [[ "$1" == "group" ]]; then
  case "$2" in
    ab-agent-iso1) printf 'ab-agent-iso1:x:6001:awfmanager\n'; exit 0 ;;
    ab-agent-iso2) printf 'ab-agent-iso2:x:6002:someone-else\n'; exit 0 ;;
    *) exit 2 ;;
  esac
fi
exit 2
GETENT
chmod +x "$PRE_STUB_DIR/getent"
cat >"$PRE_STUB_DIR/id" <<'IDSTUB'
#!/usr/bin/env bash
# stub: id -nG (live group set, stale — lacks the iso groups), id -un (user)
case "$1" in
  -nG) printf 'awfmanager staff\n'; exit 0 ;;
  -un) printf 'awfmanager\n'; exit 0 ;;
  -u)  printf '1000\n'; exit 0 ;;
esac
exit 0
IDSTUB
chmod +x "$PRE_STUB_DIR/id"

PRE_DRIVER="$SMOKE_TMP_ROOT/preflight-driver.sh"
cat >"$PRE_DRIVER" <<PREEOF
#!/usr/bin/env bash
set -uo pipefail
export PATH="$PRE_STUB_DIR:\$PATH"
# Force the Linux path; stub the iso-classification + group-name resolvers so
# the unit logic runs without a real roster.
uname() { [[ "\$1" == "-s" ]] && { printf 'Linux\n'; return 0; }; command uname "\$@"; }
export -f uname
bridge_warn() { printf 'WARN: %s\n' "\$*" >&2; }
bridge_agent_linux_user_isolation_effective() { return 0; }
bridge_isolation_v2_agent_group_name() {
  case "\$1" in
    iso1) printf 'ab-agent-iso1' ;;
    iso2) printf 'ab-agent-iso2' ;;
    *) return 1 ;;
  esac
}
# Pull in ONLY the two helpers under test (avoid sourcing the whole lib, which
# pulls heavy deps). Extract them with awk by function boundary.
source <(awk '/^bridge_controller_supp_group_stale_groups\(\)/,/^}/' "$AGENTS_LIB")
source <(awk '/^bridge_controller_supp_group_refresh\(\)/,/^}/' "$AGENTS_LIB")

case "\$1" in
  stale)
    bridge_controller_supp_group_stale_groups "iso1,iso2"
    ;;
  detect)
    bridge_controller_supp_group_refresh --agents "iso1,iso2" --reason test --mode detect
    printf 'rc=%s\n' "\$?"
    ;;
esac
PREEOF
chmod +x "$PRE_DRIVER"

PRE_STALE="$(/opt/homebrew/bin/bash "$PRE_DRIVER" stale 2>/dev/null || bash "$PRE_DRIVER" stale 2>/dev/null)"
# iso1 IS an on-disk member + missing from live set → emitted. iso2 is NOT a
# member → a provisioning gap, must NOT be emitted (no silent mask of a real gap).
printf '%s\n' "$PRE_STALE" | grep -Fxq 'ab-agent-iso1' \
  || smoke_fail "PREFLIGHT FAIL: stale classifier must emit ab-agent-iso1 (on-disk member, missing from live set)\n$PRE_STALE"
if printf '%s\n' "$PRE_STALE" | grep -Fxq 'ab-agent-iso2'; then
  smoke_fail "PREFLIGHT FAIL: ab-agent-iso2 (NOT an on-disk member) must NOT be emitted as stale — that is a provisioning gap, not a refreshable cache\n$PRE_STALE"
fi
PRE_DETECT="$(/opt/homebrew/bin/bash "$PRE_DRIVER" detect 2>&1 || bash "$PRE_DRIVER" detect 2>&1)"
printf '%s' "$PRE_DETECT" | grep -q 'rc=10' \
  || smoke_fail "PREFLIGHT FAIL: detect mode must return 10 when the live set is stale\n$PRE_DETECT"
printf '%s' "$PRE_DETECT" | grep -q 'WARN:.*STALE' \
  || smoke_fail "PREFLIGHT FAIL: detect mode must emit a clear operator WARN on the stale path (no silent mask)\n$PRE_DETECT"
smoke_log "PREFLIGHT PASS: shared classifier emits only the refreshable on-disk-member group, never the non-member gap; detect mode returns 10 + WARNs on stale"

# ===========================================================================
# FILE — file-level 0600 owner-only skip (item 4) on a MAP-COVERED iso agent.
# v1 has a group-readable MEMORY.md (superset of v2 → adopt) AND a genuine 0600
# memory/secret.md (chmod 000). The home is ALWAYS traversed; only the 0600 file
# is skipped (structured file-owner-only WITH --iso-host; a warning WITHOUT).
# ===========================================================================
BH="$SMOKE_TMP_ROOT/bh"
DR="$SMOKE_TMP_ROOT/dr"
mkdir -p "$BH/agents/isobot/memory" "$DR/agents/isobot/home"
printf 'shared-line\nv1-only-line\n' >"$BH/agents/isobot/MEMORY.md"
printf 'shared-line\n' >"$DR/agents/isobot/home/MEMORY.md"
printf 'secret-bytes\n' >"$BH/agents/isobot/memory/secret.md"
chmod 000 "$BH/agents/isobot/memory/secret.md"
UNREADABLE_FILES+=("$BH/agents/isobot/memory/secret.md")
V2_MEM="$DR/agents/isobot/home/MEMORY.md"
# Baseline: the v2 MEMORY.md state BEFORE reconcile (used to detect drift on the
# group-readable file — which SHOULD be adopted to the v1 superset).
V2_BASELINE_PRE="$SMOKE_TMP_ROOT/v2-baseline-pre.md"
cp "$V2_MEM" "$V2_BASELINE_PRE"
# An iso map that DOES classify isobot (map-covered control).
ISO_MAP="$SMOKE_TMP_ROOT/iso-map.json"
printf '{"isobot":"agent-bridge-isobot"}' >"$ISO_MAP"

if [[ "$IS_ROOT" == "1" ]]; then
  smoke_log "FILE/NOMETA SKIP: running as root (chmod 000 file is root-readable; needs a non-root run or the gate-2 dual-UID rig)"
else
  # WITHOUT --iso-host: the 0600 file backup raises PermissionError → a warning
  # (shared-mode / off-iso contract preserved). The group-readable MEMORY.md is
  # still adopted (home traversed, never whole-skipped).
  PRE_OUT="$(run_engine "$BH" "$DR" isobot "$SMOKE_TMP_ROOT/bkp-pre" 0 "$ISO_MAP")"
  printf '%s' "$PRE_OUT" >"$SMOKE_TMP_ROOT/file-pre.json"
  read -r F_ERRNO _ _ _ _ F_DRIFT < <(python3 "$PROBE" "$SMOKE_TMP_ROOT/file-pre.json" isobot "$V2_MEM" "$V2_BASELINE_PRE")
  [[ "$F_ERRNO" == "1" ]] || smoke_fail "FILE PRE FAIL: WITHOUT --iso-host a genuine 0600 owner-only file must surface as a warning, got none\n$PRE_OUT"
  [[ "$F_DRIFT" == "1" ]] || smoke_fail "FILE PRE FAIL: the group-readable MEMORY.md must STILL be reconciled (home traversed, not whole-skipped) — expected v2 drift, got drift 0\n$PRE_OUT"
  smoke_log "FILE PRE PASS: off --iso-host the 0600 file is a warning; the group-readable MEMORY.md still reconciles (home traversed)"

  # Reset v2 for the POST run.
  printf 'shared-line\n' >"$V2_MEM"
  POST_OUT="$(run_engine "$BH" "$DR" isobot "$SMOKE_TMP_ROOT/bkp-post" 1 "$ISO_MAP")"
  printf '%s' "$POST_OUT" >"$SMOKE_TMP_ROOT/file-post.json"
  read -r P_ERRNO P_ISOCOUNT P_ACTION P_REASON P_AGENTSKIP P_DRIFT < <(python3 "$PROBE" "$SMOKE_TMP_ROOT/file-post.json" isobot "$V2_MEM" "$V2_BASELINE_PRE")
  [[ "$P_ERRNO" == "0" ]] || smoke_fail "FILE POST FAIL: WITH --iso-host the 0600 file must NOT warn (structured skip), got a warning\n$POST_OUT"
  [[ "$P_ISOCOUNT" -ge 1 ]] || smoke_fail "FILE POST FAIL: expected >=1 isolation_v2_migration entry, got $P_ISOCOUNT\n$POST_OUT"
  [[ "$P_ACTION" == "skipped-iso-private" ]] || smoke_fail "FILE POST FAIL: expected action skipped-iso-private, got '$P_ACTION'\n$POST_OUT"
  [[ "$P_REASON" == "file-owner-only" ]] || smoke_fail "FILE POST FAIL: expected reason file-owner-only (per-FILE skip), got '$P_REASON'\n$POST_OUT"
  [[ "$P_AGENTSKIP" == "1" ]] || smoke_fail "FILE POST FAIL: isobot must have a file-owner-only skip entry\n$POST_OUT"
  [[ "$P_DRIFT" == "1" ]] || smoke_fail "FILE POST FAIL: the group-readable MEMORY.md must STILL be adopted to the v1 superset (drift expected) — only the 0600 file is skipped, not the whole agent\n$POST_OUT"
  smoke_log "FILE POST PASS: only the 0600 file is structured-skipped (file-owner-only); the group-readable MEMORY.md reconciles — file granularity, home traversed"

  # =========================================================================
  # NOMETA — the cm-prod cosmax_sales_mdj case: an iso agent with NO iso-map
  # entry (no agent-meta.env) still gets the file-level skip WITH --iso-host,
  # proving correctness does NOT depend on iso-map completeness. We pass NO
  # --iso-agents-json at all (empty map).
  # =========================================================================
  mkdir -p "$BH/agents/mdj/memory" "$DR/agents/mdj/home"
  printf 'shared-line\nv1-only-line\n' >"$BH/agents/mdj/MEMORY.md"
  printf 'shared-line\n' >"$DR/agents/mdj/home/MEMORY.md"
  printf 'mdj-secret\n' >"$BH/agents/mdj/memory/secret.md"
  chmod 000 "$BH/agents/mdj/memory/secret.md"
  UNREADABLE_FILES+=("$BH/agents/mdj/memory/secret.md")
  MDJ_V2="$DR/agents/mdj/home/MEMORY.md"
  MDJ_BASE="$SMOKE_TMP_ROOT/mdj-baseline.md"
  cp "$MDJ_V2" "$MDJ_BASE"
  # NO iso map (the no-meta case). --iso-host on (Linux iso host).
  NOMETA_OUT="$(run_engine "$BH" "$DR" mdj "$SMOKE_TMP_ROOT/bkp-nometa" 1 "")"
  printf '%s' "$NOMETA_OUT" >"$SMOKE_TMP_ROOT/nometa.json"
  read -r N_ERRNO N_ISOCOUNT _N_ACTION N_REASON N_AGENTSKIP N_DRIFT < <(python3 "$PROBE" "$SMOKE_TMP_ROOT/nometa.json" mdj "$MDJ_V2" "$MDJ_BASE")
  [[ "$N_ERRNO" == "0" ]] || smoke_fail "NOMETA FAIL: the no-iso-map (mdj) agent's 0600 file must be a structured skip (0 warnings), got a warning\n$NOMETA_OUT"
  [[ "$N_AGENTSKIP" == "1" ]] || smoke_fail "NOMETA FAIL: mdj must have a file-owner-only skip entry DESPITE being absent from the iso map (proves map-independence)\n$NOMETA_OUT"
  [[ "$N_DRIFT" == "1" ]] || smoke_fail "NOMETA FAIL: mdj's group-readable MEMORY.md must STILL reconcile (home traversed) — drift expected, got 0\n$NOMETA_OUT"
  smoke_log "NOMETA PASS: the no-agent-meta.env (mdj) agent gets the file-level skip with an EMPTY iso map — correctness independent of iso-map completeness"
fi

# ===========================================================================
# WD — watchdog registry downgrade + Darwin no-op + stale-group env fallback.
# ===========================================================================
WD_BH="$SMOKE_TMP_ROOT/wd/bh"
mkdir -p "$WD_BH/agents/isobot/workdir" "$WD_BH/agents/plainbot/workdir" "$WD_BH/state"
chmod 000 "$WD_BH/agents/isobot/workdir"
chmod 000 "$WD_BH/agents/plainbot/workdir"
UNREADABLE_FILES+=("$WD_BH/agents/isobot/workdir" "$WD_BH/agents/plainbot/workdir")
REG="$SMOKE_TMP_ROOT/wd/reg.json"
mkdir -p "$SMOKE_TMP_ROOT/wd"
printf '%s\n' \
  '[' \
  "  {\"id\":\"isobot\",\"engine\":\"claude\",\"agent_source\":\"static\",\"workdir\":\"$WD_BH/agents/isobot/workdir\",\"home\":\"$WD_BH/agents/isobot\",\"isolation_mode\":\"linux-user\",\"os_user\":\"agent-bridge-isobot\"}," \
  "  {\"id\":\"plainbot\",\"engine\":\"claude\",\"agent_source\":\"static\",\"workdir\":\"$WD_BH/agents/plainbot/workdir\",\"home\":\"$WD_BH/agents/plainbot\",\"isolation_mode\":\"\",\"os_user\":\"\"}" \
  ']' >"$REG"
# An iso agent ABSENT from any os_user resolution (the stale-group window): its
# permission_denied row only downgrades under the env fallback.
REG_NOMETA="$SMOKE_TMP_ROOT/wd/reg-nometa.json"
mkdir -p "$WD_BH/agents/mdj/workdir"
chmod 000 "$WD_BH/agents/mdj/workdir"
UNREADABLE_FILES+=("$WD_BH/agents/mdj/workdir")
printf '%s\n' \
  '[' \
  "  {\"id\":\"mdj\",\"engine\":\"claude\",\"agent_source\":\"static\",\"workdir\":\"$WD_BH/agents/mdj/workdir\",\"home\":\"$WD_BH/agents/mdj\",\"isolation_mode\":\"\",\"os_user\":\"\"}" \
  ']' >"$REG_NOMETA"

if [[ "$IS_ROOT" == "1" ]]; then
  smoke_log "WD SKIP: running as root (chmod 000 workdir is root-readable; real denial needs a non-root run / the gate-2 rig)"
else
  WD_LINUX="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Linux python3 "$WATCHDOG" scan --bridge-home "$WD_BH" --agent-registry-json "$REG" --json 2>/dev/null)"
  read -r WD_PROB WD_SKIP < <(printf '%s' "$WD_LINUX" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["problem_count"], d["iso_skipped_count"])')
  [[ "$WD_SKIP" == "1" ]] || smoke_fail "WD FAIL (Linux): expected 1 iso_skipped (isobot permission_denied downgraded), got $WD_SKIP\n$WD_LINUX"
  [[ "$WD_PROB" == "1" ]] || smoke_fail "WD FAIL (Linux): plainbot's denial must STAY a problem (problem_count=1), got $WD_PROB\n$WD_LINUX"
  smoke_log "WD PASS (Linux): registry-classified isobot denial → iso_skipped; plainbot (shared) denial stays a problem"

  WD_MAC="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Darwin python3 "$WATCHDOG" scan --bridge-home "$WD_BH" --agent-registry-json "$REG" --json 2>/dev/null)"
  read -r WD_MPROB WD_MSKIP < <(printf '%s' "$WD_MAC" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["problem_count"], d["iso_skipped_count"])')
  [[ "$WD_MSKIP" == "0" ]] || smoke_fail "WD FAIL (Darwin): nothing must downgrade off Linux, got iso_skipped=$WD_MSKIP\n$WD_MAC"
  [[ "$WD_MPROB" == "2" ]] || smoke_fail "WD FAIL (Darwin): both denials stay problems off Linux (problem_count=2), got $WD_MPROB\n$WD_MAC"
  smoke_log "WD PASS (Darwin): no iso downgrade off Linux — both denials stay problems"

  # Stale-group env fallback: an iso-uid-side permission_denied row with NO
  # os_user (registry incomplete) is NOT downgraded by the registry classifier
  # alone, BUT downgrades under BRIDGE_WATCHDOG_ISO_GROUP_STALE=1.
  WD_NOFLAG="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Linux python3 "$WATCHDOG" scan --bridge-home "$WD_BH" --agent-registry-json "$REG_NOMETA" --json 2>/dev/null)"
  read -r WD_NF_PROB WD_NF_SKIP < <(printf '%s' "$WD_NOFLAG" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["problem_count"], d["iso_skipped_count"])')
  [[ "$WD_NF_SKIP" == "0" ]] || smoke_fail "WD FAIL (no-flag): a registry-incomplete iso row must NOT downgrade without the stale env flag, got iso_skipped=$WD_NF_SKIP\n$WD_NOFLAG"
  [[ "$WD_NF_PROB" == "1" ]] || smoke_fail "WD FAIL (no-flag): the registry-incomplete denial must stay a problem without the flag, got $WD_NF_PROB\n$WD_NOFLAG"
  WD_FLAG="$(BRIDGE_HOST_PLATFORM_OVERRIDE=Linux BRIDGE_WATCHDOG_ISO_GROUP_STALE=1 python3 "$WATCHDOG" scan --bridge-home "$WD_BH" --agent-registry-json "$REG_NOMETA" --json 2>/dev/null)"
  read -r WD_F_PROB WD_F_SKIP < <(printf '%s' "$WD_FLAG" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["problem_count"], d["iso_skipped_count"])')
  [[ "$WD_F_SKIP" == "1" ]] || smoke_fail "WD FAIL (flag): with BRIDGE_WATCHDOG_ISO_GROUP_STALE=1 the transient iso-uid-side row must downgrade to iso_skipped, got $WD_F_SKIP\n$WD_FLAG"
  [[ "$WD_F_PROB" == "0" ]] || smoke_fail "WD FAIL (flag): the transient row must leave the problem count, got problem_count=$WD_F_PROB\n$WD_FLAG"
  smoke_log "WD PASS (stale env fallback): a registry-incomplete iso-uid-side denial stays a problem WITHOUT the flag, downgrades to iso_skipped WITH BRIDGE_WATCHDOG_ISO_GROUP_STALE=1 (the transient restart-window)"
fi

# ===========================================================================
# TRIP — static tripwires bind the rc4 behavior to source.
# ===========================================================================
grep -q 'bridge_controller_supp_group_refresh' "$AGENTS_LIB" \
  || smoke_fail "TRIP FAIL: shared fresh-group preflight helper missing from bridge-agents.sh"
grep -q 'bridge_controller_supp_group_stale_groups' "$AGENTS_LIB" \
  || smoke_fail "TRIP FAIL: stale-group classifier missing from bridge-agents.sh"
grep -q 'bridge_controller_supp_group_refresh' "$RECONCILE_DRIVER" \
  || smoke_fail "TRIP FAIL: reconcile driver lost the fresh-group preflight (item 1)"
grep -q 'bridge_controller_supp_group_refresh' "$WATCHDOG_SH" \
  || smoke_fail "TRIP FAIL: watchdog entry lost the fresh-group preflight (item 2)"
grep -q 'BRIDGE_WATCHDOG_ISO_GROUP_STALE' "$WATCHDOG_SH" \
  || smoke_fail "TRIP FAIL: watchdog entry lost the info-downgrade env fallback signal"
grep -q 'is_iso_group_stale_downgrade_row' "$WATCHDOG" \
  || smoke_fail "TRIP FAIL: watchdog lost the stale-group info-downgrade classifier"
grep -q 'file-owner-only\|ISO_FILE_OWNER_ONLY_REASON' "$ENGINE" \
  || smoke_fail "TRIP FAIL: engine lost the file-level owner-only skip reason"
grep -q '\-\-iso-host' "$ENGINE" \
  || smoke_fail "TRIP FAIL: engine lost the --iso-host file-level gate"
# The retracted whole-home belt must be GONE from both py + sh (item 3). Match
# CODE tokens (the attribute / argparse arg / method def), not prose mentions of
# the removed names in historical comments.
if grep -Eq 'self\.host_iso_active|add_argument\(.*host-iso-active|def _record_iso_belt_skip|_record_iso_belt_skip\(' "$ENGINE"; then
  smoke_fail "TRIP FAIL: the retracted whole-home belt (host_iso_active attr / --host-iso-active arg / _record_iso_belt_skip) is STILL live in the engine — item 3 removal incomplete"
fi
if grep -Eq 'bridge_layout_v2_reconcile_host_iso_active|host_iso_flag|host_iso_active=' "$RECONCILE_SH"; then
  smoke_fail "TRIP FAIL: the retracted whole-home belt signal is STILL in the reconcile wrapper — item 3 removal incomplete"
fi
# The #1876 up-front iso-map whole-agent skip must be GONE (item 4). Match the
# CODE skip-reason tokens, not the comment that documents the removal.
if grep -Eq '"reason": "iso-agent-private"|"iso_agent_private"' "$ENGINE"; then
  smoke_fail "TRIP FAIL: the rc3 #1876 up-front iso-map whole-agent skip (iso-agent-private) is STILL live in the engine — item 4 removal incomplete"
fi
grep -q 'bridge_layout_v2_reconcile_iso_host' "$RECONCILE_SH" \
  || smoke_fail "TRIP FAIL: reconcile wrapper lost the file-level iso-host gate helper"
smoke_log "TRIP PASS: preflight + file-level skip + watchdog fallback bound to source; whole-home belt + #1876 map-skip removed"

smoke_log "all 1820-rc4-iso-stale-group-preflight tests PASS"
