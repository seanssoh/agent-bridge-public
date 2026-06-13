#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1820-rc4-iso-mixed-host-skip.sh
#
# Issue #1820 rc4 gate-2 (#13364) — the file-level iso owner-only skip must be
# gated by a PER-AGENT iso set, NOT a host-wide boolean.
#
# The bug (patch-dev gate-2 on a real Linux rig, /…/13364-1878-gate2.md):
# rc4's file-level skip was authorized by a single host-wide `--iso-host`
# boolean (true whenever ANY rostered agent requested linux-user isolation). On
# a MIXED iso/shared host that silently downgraded a SHARED agent's
# PermissionError into a structured `file-owner-only` / `skipped-iso-private`
# skip instead of surfacing the warning the gate requires:
#
#   > shared-mode / non-iso unchanged: a per-file PermissionError on a shared
#   > agent still surfaces as a warning (no over-skip).
#
# The Linux mixed-host reproducer had one real iso agent + one shared agent;
# both denied files were downgraded to `file-owner-only` because `--iso-host`
# was global. The fix replaces the host-wide gate with a per-agent set
# (--iso-agents, built by the wrapper from the same roster predicate the
# preflight uses — effective OR requested linux-user isolation, NOT requiring a
# resolved os_user). The downgrade fires ONLY for an agent in that set; a shared
# agent's per-file PermissionError stays a warning + data skip, byte-identical
# to main, even on a mixed host.
#
# What this rig asserts (the gate-2 reproducer, portably):
#   MIXED — agents_csv=iso,shared; the iso set has ONLY `iso`; an unreadable 0600
#           file (chmod 000 stand-in for the real 0600-not-owner boundary) under
#           BOTH agents. The ISO agent's denied file becomes a STRUCTURED
#           file-owner-only skip (0 warnings for it); the SHARED agent's denied
#           file stays a WARNING (Errno13) + an unreadable data-skip — NOT
#           downgraded. This is the exact over-skip gate-2 flagged.
#   EMPTY — CONTROL: with an EMPTY iso set BOTH agents' denied files stay
#           warnings (shared-mode contract: nothing is downgraded off the set).
#   TRIP  — static tripwires bind the per-agent gate (not host-wide) to source.
#
# Portability (macOS / CI have no real cross-UID boundary): chmod-000 on a file
# gives a non-root user the same EACCES the real 0600 boundary does; root
# bypasses it, so the per-file teeth are skipped under uid 0 — the real dual-UID
# Linux re-gate runs at patch-dev gate-2 (cross-UID teeth deferred to the real
# rig). No host platform stub is needed: the engine's per-agent gate is driven
# purely by the --iso-agents file the wrapper would build on a Linux host.
#
# Footgun #11: NO heredoc-stdin to any subprocess; fixtures via printf, JSON
# probed file-as-argv. Run under Bash 5.x (macOS system bash is 3.2).

set -uo pipefail
SMOKE_NAME="1820-rc4-iso-mixed-host-skip"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"
ENGINE="$REPO_ROOT/lib/upgrade-helpers/layout-v2-reconcile.py"
RECONCILE_SH="$REPO_ROOT/lib/bridge-layout-v2-reconcile.sh"
PROBE="$SCRIPT_DIR/1820-rc4-iso-mixed-host-skip-probe.py"

UNREADABLE_FILES=()
cleanup() {
  local f
  for f in "${UNREADABLE_FILES[@]:-}"; do
    [[ -n "$f" && -e "$f" ]] && chmod 0644 "$f" 2>/dev/null || true
  done
  smoke_cleanup_temp_root 2>/dev/null || true
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_make_temp_root "$SMOKE_NAME"
smoke_assert_file_exists "$ENGINE"       "reconcile engine"
smoke_assert_file_exists "$RECONCILE_SH" "reconcile wrapper"
smoke_assert_file_exists "$PROBE"        "mixed-host probe helper"

IS_ROOT=0
[[ "$(id -u 2>/dev/null || echo 1)" == "0" ]] && IS_ROOT=1

run_engine() {
  # run_engine <bridge_home> <data_root> <agents_csv> <backup_root> [iso_set_csv=""]
  # iso_set_csv is the PER-AGENT set (CSV) authorized for the file-level skip;
  # empty => no --iso-agents (shared-mode: every per-file PermissionError warns).
  local bh="$1" dr="$2" agents="$3" bkp="$4" iso_set_csv="${5:-}"
  local -a argv=(
    "$ENGINE"
    --bridge-home "$bh"
    --data-root "$dr"
    --agents-csv "$agents"
    --mode apply
    --backup-root "$bkp"
  )
  if [[ -n "$iso_set_csv" ]]; then
    local _set_file
    _set_file="$(mktemp "$SMOKE_TMP_ROOT/.iso-set-XXXXXX")"
    printf '%s\n' "${iso_set_csv//,/$'\n'}" >"$_set_file"
    argv+=(--iso-agents "$_set_file")
  fi
  python3 "${argv[@]}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Fixture: a MIXED host — one iso agent + one shared agent, each with an
# unreadable 0600 v1-only memory file. v2 homes present (empty memory).
# ---------------------------------------------------------------------------
BH="$SMOKE_TMP_ROOT/bh"
DR="$SMOKE_TMP_ROOT/dr"
mkdir -p \
  "$BH/agents/iso/memory" "$BH/agents/shared/memory" \
  "$DR/agents/iso/home" "$DR/agents/shared/home"
printf 'iso-secret\n'    >"$BH/agents/iso/memory/secret.md"
printf 'shared-secret\n' >"$BH/agents/shared/memory/secret.md"
chmod 000 "$BH/agents/iso/memory/secret.md"
chmod 000 "$BH/agents/shared/memory/secret.md"
UNREADABLE_FILES+=("$BH/agents/iso/memory/secret.md" "$BH/agents/shared/memory/secret.md")

if [[ "$IS_ROOT" == "1" ]]; then
  smoke_log "MIXED/EMPTY SKIP: running as root (chmod 000 file is root-readable; needs a non-root run or the gate-2 dual-UID rig — cross-UID teeth deferred to gate-2 real rig)"
else
  # -------------------------------------------------------------------------
  # MIXED — iso set has ONLY `iso`. The gate-2 reproducer.
  # -------------------------------------------------------------------------
  M_OUT="$(run_engine "$BH" "$DR" iso,shared "$SMOKE_TMP_ROOT/bkp-mixed" iso)"
  printf '%s' "$M_OUT" >"$SMOKE_TMP_ROOT/mixed.json"

  # ISO agent: structured file-owner-only skip, NO warning, NO data-skip.
  read -r ISO_WARN ISO_SKIP ISO_DATASKIP < <(python3 "$PROBE" "$SMOKE_TMP_ROOT/mixed.json" iso)
  [[ "$ISO_WARN" == "0" ]] || smoke_fail "MIXED FAIL: the iso agent's 0600 file must NOT warn (it is in the iso set → structured skip), got a warning\n$M_OUT"
  [[ "$ISO_SKIP" == "1" ]] || smoke_fail "MIXED FAIL: the iso agent's 0600 file must be a structured file-owner-only skip, got none\n$M_OUT"
  [[ "$ISO_DATASKIP" == "0" ]] || smoke_fail "MIXED FAIL: the iso agent's 0600 file must NOT also be an unreadable data-skip (the iso skip replaces it)\n$M_OUT"

  # SHARED agent: WARNING + unreadable data-skip, NOT downgraded.
  read -r SH_WARN SH_SKIP SH_DATASKIP < <(python3 "$PROBE" "$SMOKE_TMP_ROOT/mixed.json" shared)
  [[ "$SH_WARN" == "1" ]] || smoke_fail "MIXED FAIL (gate-2 #13364): the SHARED agent's 0600 file must STILL surface as a warning on a mixed host (no over-skip), got none\n$M_OUT"
  [[ "$SH_SKIP" == "0" ]] || smoke_fail "MIXED FAIL (gate-2 #13364): the SHARED agent's 0600 file must NOT be downgraded to a file-owner-only iso skip — that is the exact host-wide over-skip the per-agent gate fixes\n$M_OUT"
  [[ "$SH_DATASKIP" == "1" ]] || smoke_fail "MIXED FAIL: the SHARED agent's 0600 file must stay an unreadable data-skip (the shared-mode contract), got none\n$M_OUT"
  smoke_log "MIXED PASS (gate-2 #13364): on a mixed host the iso agent's 0600 file is a structured file-owner-only skip while the SHARED agent's stays a warning + data-skip — the per-agent gate does NOT over-skip the shared agent"

  # -------------------------------------------------------------------------
  # EMPTY — CONTROL: an EMPTY iso set downgrades nothing; both warn.
  # -------------------------------------------------------------------------
  E_OUT="$(run_engine "$BH" "$DR" iso,shared "$SMOKE_TMP_ROOT/bkp-empty" "")"
  printf '%s' "$E_OUT" >"$SMOKE_TMP_ROOT/empty.json"
  read -r E_ISO_WARN E_ISO_SKIP _E_ISO_DS < <(python3 "$PROBE" "$SMOKE_TMP_ROOT/empty.json" iso)
  read -r E_SH_WARN E_SH_SKIP _E_SH_DS < <(python3 "$PROBE" "$SMOKE_TMP_ROOT/empty.json" shared)
  [[ "$E_ISO_WARN" == "1" && "$E_ISO_SKIP" == "0" ]] || smoke_fail "EMPTY FAIL: with an EMPTY iso set even the iso agent's 0600 file must stay a warning (nothing in the set → no downgrade), got warn=$E_ISO_WARN skip=$E_ISO_SKIP\n$E_OUT"
  [[ "$E_SH_WARN" == "1" && "$E_SH_SKIP" == "0" ]] || smoke_fail "EMPTY FAIL: with an EMPTY iso set the shared agent's 0600 file must stay a warning, got warn=$E_SH_WARN skip=$E_SH_SKIP\n$E_OUT"
  smoke_log "EMPTY PASS: an empty iso set downgrades nothing — both agents' 0600 files stay warnings (shared-mode contract, byte-identical to main)"
fi

# ---------------------------------------------------------------------------
# TRIP — static tripwires bind the PER-AGENT gate (not host-wide) to source.
# ---------------------------------------------------------------------------
grep -q -- '--iso-agents\b' "$ENGINE" \
  || smoke_fail "TRIP FAIL: engine lost the per-agent --iso-agents file-level gate"
grep -q 'iso_agents_set' "$ENGINE" \
  || smoke_fail "TRIP FAIL: engine lost the per-agent iso_agents_set membership"
grep -q 'def _is_iso_file_permission_error(self, agent' "$ENGINE" \
  || smoke_fail "TRIP FAIL: the file-level iso gate is not per-agent (its predicate must take an agent argument)"
grep -q 'bridge_layout_v2_reconcile_iso_agents_set' "$RECONCILE_SH" \
  || smoke_fail "TRIP FAIL: reconcile wrapper lost the per-agent iso-agents-set builder"
grep -q -- '--iso-agents\b' "$RECONCILE_SH" \
  || smoke_fail "TRIP FAIL: reconcile wrapper no longer passes the per-agent --iso-agents set"
# The host-wide gate must be GONE (CODE tokens, not prose).
if grep -Eq 'add_argument\(.*--iso-host|self\.iso_host\b|args\.iso_host\b' "$ENGINE"; then
  smoke_fail "TRIP FAIL: the host-wide --iso-host gate is STILL live in the engine — gate-2 #13364 replaced it with the per-agent set"
fi
if grep -Eq 'bridge_layout_v2_reconcile_iso_host\b|iso_host_flag|\(--iso-host\)' "$RECONCILE_SH"; then
  smoke_fail "TRIP FAIL: the host-wide iso_host gate is STILL in the reconcile wrapper — gate-2 #13364 replaced it with the per-agent set"
fi
smoke_log "TRIP PASS: per-agent --iso-agents gate bound to source (engine predicate takes an agent; wrapper builds the set); host-wide --iso-host removed"

smoke_log "all 1820-rc4-iso-mixed-host-skip tests PASS"
