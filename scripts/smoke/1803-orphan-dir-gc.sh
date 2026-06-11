#!/usr/bin/env bash
# scripts/smoke/1803-orphan-dir-gc.sh — Issue #1803 orphan agent-dir GC.
#
# Validates the action-safe GC layer (bridge-orphan-gc.py) that consumes the
# shared classifier (bridge_orphan_classifier.py). The detector half is
# covered by scripts/smoke/orphan-agent-dir.sh (T1-T10, behavior-preserving
# after the #1803 refactor); this smoke covers the codex-named teeth for the
# CLASSIFIER keep-set + the GC MOVE / TOCTOU / PRUNE safety contract.
#
# Teeth (codex's required 8):
#   1. `agents/shared` target → kept (referenced-symlink-target).
#   2. a NON-shared target referenced by a live agent doc symlink → kept.
#   3. relative symlink target one level up → kept / safely refused (no move).
#   4. case-variant of a registered dir name → not moved (case-insensitive fs).
#   5. samefile-indeterminate → produces NO move.
#   6. fresh dir below the age gate → not moved.
#   7. a candidate that is itself a symlink → moved as LINK only, target intact.
#   8. prune cannot cross `backups/orphan-agents-*` containment.
# Plus: aged test-artifact-named, registry-absent dir → quarantined when
#   BRIDGE_ORPHAN_GC_AUTO_QUARANTINE=1, only NOTICED (not moved) when =0.
#
# Uses an isolated BRIDGE_HOME via smoke_setup_bridge_home — never touches the
# operator's live runtime. Registry is supplied via --registry-json so this
# fixture does not depend on the bridge CLI being runnable in the test scope.

set -euo pipefail

SMOKE_NAME="1803-orphan-dir-gc"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

ORPHAN_LOCKED_DIR=""
cleanup() {
  if [[ -n "${ORPHAN_LOCKED_DIR:-}" && -e "$ORPHAN_LOCKED_DIR" ]]; then
    chmod -R u+rwX "$ORPHAN_LOCKED_DIR" 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1803-orphan-dir-gc"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

GC="$REPO_ROOT/bridge-orphan-gc.py"
smoke_assert_file_exists "$GC" "GC helper present"

HOME_ROOT="$BRIDGE_AGENT_HOME_ROOT"
BACKUPS_DIR="$BRIDGE_HOME/backups"
AUDIT_LOG="$BRIDGE_HOME/logs/audit.jsonl"

reset_tree() {
  if [[ -n "${ORPHAN_LOCKED_DIR:-}" && -e "$ORPHAN_LOCKED_DIR" ]]; then
    chmod -R u+rwX "$ORPHAN_LOCKED_DIR" 2>/dev/null || true
    ORPHAN_LOCKED_DIR=""
  fi
  rm -rf "$HOME_ROOT" "$BACKUPS_DIR"
  mkdir -p "$HOME_ROOT" "$BACKUPS_DIR"
  : >"$AUDIT_LOG"
}

# write_registry <out> [id:home ...] — minimal `agent registry --json` shape.
# Each arg is `id` (home defaults to $HOME_ROOT/<id>) or `id=home`.
write_registry() {
  local out="$1"; shift
  "$PY_BIN" - "$HOME_ROOT" "$out" "$@" <<'PY'
import json, sys
home_root, out = sys.argv[1], sys.argv[2]
rows = []
for spec in sys.argv[3:]:
    if "=" in spec:
        agent_id, home = spec.split("=", 1)
    else:
        agent_id, home = spec, f"{home_root}/{spec}"
    rows.append({"id": agent_id, "class": "dynamic", "home": home,
                 "workdir": home, "engine": "claude", "is_alive": True,
                 "source": "dynamic-active-env"})
open(out, "w", encoding="utf-8").write(json.dumps(rows))
PY
}

run_quarantine() {
  # run_quarantine <registry> -> JSON summary on stdout
  local registry="$1"
  "$PY_BIN" "$GC" quarantine \
    --agent-home-root "$HOME_ROOT" \
    --backups-dir "$BACKUPS_DIR" \
    --audit-log "$AUDIT_LOG" \
    --registry-json "$registry"
}

run_prune() {
  local registry="$1"
  shift
  "$PY_BIN" "$GC" prune \
    --backups-dir "$BACKUPS_DIR" \
    --audit-log "$AUDIT_LOG" \
    --registry-json "$registry" "$@"
}

# json_names <summary-json> <key> -> space-joined .name values for summary[key]
json_names() {
  local payload="$1"
  local key="$2"
  printf '%s' "$payload" | "$PY_BIN" -c '
import json, sys
key = sys.argv[1]
d = json.loads(sys.stdin.read() or "{}")
print(" ".join(e.get("name", "") for e in d.get(key, [])))
' "$key"
}

age_dir_past_gate() {
  # Backdate a dir well past the default 7d age gate.
  touch -t 202501010000 "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Tooth 1 — `agents/shared` target referenced by a kept tree → kept.
# ---------------------------------------------------------------------------
t1_shared_target_kept() {
  reset_tree
  mkdir -p "$HOME_ROOT/shared"
  printf 'tools\n' >"$HOME_ROOT/shared/TOOLS.md"
  mkdir -p "$HOME_ROOT/agent-a"
  ln -s ../shared/TOOLS.md "$HOME_ROOT/agent-a/TOOLS.md"
  age_dir_past_gate "$HOME_ROOT/shared"
  local registry="$SMOKE_TMP_ROOT/r.t1.json"
  write_registry "$registry" "agent-a"

  local out; out="$(run_quarantine "$registry")"
  local would; would="$(json_names "$out" would_quarantine)"
  smoke_assert_not_contains "$would" "shared" "T1 shared is NOT a quarantine candidate"
  [[ -d "$HOME_ROOT/shared" ]] || smoke_fail "T1 shared dir was removed"
}

# ---------------------------------------------------------------------------
# Tooth 2 — a NON-shared symlink target referenced by a live agent doc → kept.
# ---------------------------------------------------------------------------
t2_nonshared_target_kept() {
  reset_tree
  mkdir -p "$HOME_ROOT/common-docs"
  printf 'policy\n' >"$HOME_ROOT/common-docs/POLICY.md"
  mkdir -p "$HOME_ROOT/agent-b"
  ln -s ../common-docs/POLICY.md "$HOME_ROOT/agent-b/POLICY.md"
  age_dir_past_gate "$HOME_ROOT/common-docs"
  local registry="$SMOKE_TMP_ROOT/r.t2.json"
  write_registry "$registry" "agent-b"

  local out; out="$(run_quarantine "$registry")"
  local would; would="$(json_names "$out" would_quarantine)"
  smoke_assert_not_contains "$would" "common-docs" \
    "T2 a non-'shared'-named referenced target is kept (generic keep-set)"
  [[ -d "$HOME_ROOT/common-docs" ]] || smoke_fail "T2 common-docs removed"
}

# ---------------------------------------------------------------------------
# Tooth 3 — relative symlink target one level up → kept (resolves correctly).
# ---------------------------------------------------------------------------
t3_relative_uplevel_target_kept() {
  reset_tree
  mkdir -p "$HOME_ROOT/uptarget"
  printf 'x\n' >"$HOME_ROOT/uptarget/file.md"
  mkdir -p "$HOME_ROOT/agent-c/nested"
  # Two-levels-up relative link from a nested dir.
  ln -s ../../uptarget/file.md "$HOME_ROOT/agent-c/nested/file.md"
  age_dir_past_gate "$HOME_ROOT/uptarget"
  local registry="$SMOKE_TMP_ROOT/r.t3.json"
  write_registry "$registry" "agent-c"

  local out; out="$(run_quarantine "$registry")"
  local would; would="$(json_names "$out" would_quarantine)"
  smoke_assert_not_contains "$would" "uptarget" \
    "T3 a relative one-level-up symlink target is kept"
  [[ -d "$HOME_ROOT/uptarget" ]] || smoke_fail "T3 uptarget removed"
}

# ---------------------------------------------------------------------------
# Tooth 4 — case-variant of a registered dir name → not moved on APFS.
# ---------------------------------------------------------------------------
t4_case_variant_not_moved() {
  reset_tree
  mkdir -p "$HOME_ROOT/CRM-AGENT"
  printf 'live\n' >"$HOME_ROOT/CRM-AGENT/marker.txt"
  age_dir_past_gate "$HOME_ROOT/CRM-AGENT"
  local lower="$HOME_ROOT/crm-agent"
  if ! [[ -d "$lower" ]] || ! [[ "$lower" -ef "$HOME_ROOT/CRM-AGENT" ]]; then
    smoke_log "T4 skip: case-sensitive fs — case-variant collision not reproducible"
    return 0
  fi
  local registry="$SMOKE_TMP_ROOT/r.t4.json"
  write_registry "$registry" "crm-agent"

  local out; out="$(run_quarantine "$registry")"
  local would; would="$(json_names "$out" would_quarantine)"
  smoke_assert_not_contains "$would" "CRM-AGENT" \
    "T4 case-variant of a registered agent is not a candidate (samefile)"
}

# ---------------------------------------------------------------------------
# Tooth 5 — samefile-indeterminate → produces NO move.
# ---------------------------------------------------------------------------
t5_indeterminate_no_move() {
  reset_tree
  local locked_parent="$SMOKE_TMP_ROOT/locked-parent.t5"
  local reg_home="$locked_parent/locked-home"
  mkdir -p "$reg_home"
  mkdir -p "$HOME_ROOT/LOCKED-CANDIDATE"
  age_dir_past_gate "$HOME_ROOT/LOCKED-CANDIDATE"
  local registry="$SMOKE_TMP_ROOT/r.t5.json"
  write_registry "$registry" "locked=$reg_home"

  chmod 000 "$locked_parent"
  ORPHAN_LOCKED_DIR="$locked_parent"
  local out; out="$(run_quarantine "$registry")"
  chmod 755 "$locked_parent"
  ORPHAN_LOCKED_DIR=""

  local kept; kept="$(json_names "$out" kept_indeterminate)"
  if [[ -z "$kept" ]]; then
    smoke_log "T5 skip: registered home stayed statable (likely root) — indeterminate not reproducible"
    return 0
  fi
  local would; would="$(json_names "$out" would_quarantine)"
  smoke_assert_not_contains "$would" "LOCKED-CANDIDATE" \
    "T5 indeterminate candidate is NOT a move candidate (fail-safe)"
  smoke_assert_contains "$kept" "LOCKED-CANDIDATE" \
    "T5 indeterminate candidate surfaces in kept_indeterminate"
}

# ---------------------------------------------------------------------------
# Tooth 6 — fresh dir below the age gate → not moved.
# ---------------------------------------------------------------------------
t6_fresh_dir_not_moved() {
  reset_tree
  mkdir -p "$HOME_ROOT/fresh-orphan"   # now mtime, below 7d gate
  local registry="$SMOKE_TMP_ROOT/r.t6.json"
  write_registry "$registry"

  local out; out="$(run_quarantine "$registry")"
  local would; would="$(json_names "$out" would_quarantine)"
  local young; young="$(json_names "$out" skipped_too_young)"
  smoke_assert_not_contains "$would" "fresh-orphan" "T6 fresh dir is not a candidate"
  smoke_assert_contains "$young" "fresh-orphan" "T6 fresh dir surfaces as too-young"
}

# ---------------------------------------------------------------------------
# Tooth 7 — a candidate that is itself a symlink → moved as LINK only, target intact.
# ---------------------------------------------------------------------------
t7_symlink_candidate_moved_as_link() {
  reset_tree
  # A real dir OUTSIDE the home root, and a dir-shaped symlink candidate under
  # the home root pointing at it. The candidate is unregistered + aged.
  local real_target="$SMOKE_TMP_ROOT/real-target.t7"
  mkdir -p "$real_target"
  printf 'precious\n' >"$real_target/keepme.md"
  ln -s "$real_target" "$HOME_ROOT/link-orphan"
  age_dir_past_gate "$HOME_ROOT/link-orphan"
  local registry="$SMOKE_TMP_ROOT/r.t7.json"
  write_registry "$registry"

  local out
  out="$(BRIDGE_ORPHAN_GC_AUTO_QUARANTINE=1 run_quarantine "$registry")"
  local moved; moved="$(json_names "$out" quarantined)"
  smoke_assert_contains "$moved" "link-orphan" "T7 symlink candidate IS quarantined (auto on)"
  # The link is gone from the home root, the TARGET is untouched.
  [[ ! -e "$HOME_ROOT/link-orphan" ]] || smoke_fail "T7 link still present at home root"
  [[ -f "$real_target/keepme.md" ]] || smoke_fail "T7 link TARGET was followed/destroyed"
  # The moved entry in backups is itself a symlink (link moved as link).
  local dest
  dest="$(find "$BACKUPS_DIR" -name 'link-orphan' -maxdepth 3 2>/dev/null | head -n1)"
  [[ -n "$dest" ]] || smoke_fail "T7 quarantined link not found under backups"
  [[ -L "$dest" ]] || smoke_fail "T7 quarantined entry is not a symlink (target was copied)"
}

# ---------------------------------------------------------------------------
# Tooth 8 — prune cannot cross `backups/orphan-agents-*` containment.
# ---------------------------------------------------------------------------
t8_prune_containment() {
  reset_tree
  # A legit aged quarantine dir (eligible to prune) and a crafted sibling
  # OUTSIDE the orphan-agents-* prefix that must NEVER be pruned.
  local legit="$BACKUPS_DIR/orphan-agents-20200101"
  local outsider="$BACKUPS_DIR/daily"   # not orphan-agents-* — must survive
  mkdir -p "$legit/some-orphan" "$outsider"
  printf 'archive\n' >"$outsider/important.tgz"
  age_dir_past_gate "$legit"
  age_dir_past_gate "$outsider"
  local registry="$SMOKE_TMP_ROOT/r.t8.json"
  write_registry "$registry"

  # Force a real prune with a 0-day retain so the aged legit dir is eligible.
  local out
  out="$(BRIDGE_ORPHAN_GC_AUTO_QUARANTINE=1 run_prune "$registry" --retain-days 0 --force-prune)"
  local pruned
  pruned="$(printf '%s' "$out" | "$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(" ".join(e.get("name","") for e in d.get("pruned",[])))')"
  smoke_assert_contains "$pruned" "orphan-agents-20200101" \
    "T8 an aged orphan-agents-* dir IS pruned"
  # The outsider (not orphan-agents-*) is never even considered → still there.
  [[ -f "$outsider/important.tgz" ]] || smoke_fail \
    "T8 a non-orphan-agents-* dir under backups/ was deleted (containment breach)"
  [[ ! -d "$legit" ]] || smoke_fail "T8 the eligible orphan-agents-* dir was not pruned"
}

# ---------------------------------------------------------------------------
# Plus — aged test-artifact orphan: quarantined when AUTO=1, only noticed when AUTO=0.
# ---------------------------------------------------------------------------
t9_auto_gate() {
  reset_tree
  mkdir -p "$HOME_ROOT/smoke-leftover/raw"
  printf 'data\n' >"$HOME_ROOT/smoke-leftover/raw/note.md"
  age_dir_past_gate "$HOME_ROOT/smoke-leftover"
  local registry="$SMOKE_TMP_ROOT/r.t9.json"
  write_registry "$registry"

  # AUTO off (default): noticed, NOT moved.
  local out_off; out_off="$(run_quarantine "$registry")"
  local would_off; would_off="$(json_names "$out_off" would_quarantine)"
  local moved_off; moved_off="$(json_names "$out_off" quarantined)"
  smoke_assert_contains "$would_off" "smoke-leftover" "T9 (off) aged artifact is a would-quarantine"
  smoke_assert_eq "" "$moved_off" "T9 (off) nothing actually moved"
  [[ -d "$HOME_ROOT/smoke-leftover" ]] || smoke_fail "T9 (off) dir was moved while AUTO off"

  # AUTO on: actually quarantined + an audit row written.
  local out_on; out_on="$(BRIDGE_ORPHAN_GC_AUTO_QUARANTINE=1 run_quarantine "$registry")"
  local moved_on; moved_on="$(json_names "$out_on" quarantined)"
  smoke_assert_contains "$moved_on" "smoke-leftover" "T9 (on) aged artifact IS quarantined"
  [[ ! -e "$HOME_ROOT/smoke-leftover" ]] || smoke_fail "T9 (on) dir not moved out of home root"
  if ! grep -q 'orphan_agent_dir_gc_quarantined' "$AUDIT_LOG" 2>/dev/null; then
    smoke_fail "T9 (on) no quarantine audit row written"
  fi
}

# ---------------------------------------------------------------------------
# Doctor regression guard — the refactor kept the detector behavior-preserving.
# ---------------------------------------------------------------------------
t10_doctor_regression() {
  local doctor_smoke="$SCRIPT_DIR/orphan-agent-dir.sh"
  if [[ -x "$doctor_smoke" || -f "$doctor_smoke" ]]; then
    if ! bash "$doctor_smoke" >/dev/null 2>&1; then
      smoke_fail "T10 doctor smoke orphan-agent-dir.sh regressed after #1803 refactor"
    fi
    smoke_log "T10 doctor smoke orphan-agent-dir.sh stays GREEN (behavior-preserving)"
  else
    smoke_skip "T10 doctor regression" "orphan-agent-dir.sh not found"
  fi
}

# ---------------------------------------------------------------------------
# Drive.
# ---------------------------------------------------------------------------
smoke_run "T1 shared target kept" t1_shared_target_kept
smoke_run "T2 non-shared target kept" t2_nonshared_target_kept
smoke_run "T3 relative uplevel target kept" t3_relative_uplevel_target_kept
smoke_run "T4 case-variant not moved" t4_case_variant_not_moved
smoke_run "T5 indeterminate no move" t5_indeterminate_no_move
smoke_run "T6 fresh dir not moved" t6_fresh_dir_not_moved
smoke_run "T7 symlink candidate moved as link" t7_symlink_candidate_moved_as_link
smoke_run "T8 prune containment" t8_prune_containment
smoke_run "T9 auto-quarantine gate" t9_auto_gate
smoke_run "T10 doctor regression" t10_doctor_regression

smoke_log "all 1803-orphan-dir-gc teeth passed"
