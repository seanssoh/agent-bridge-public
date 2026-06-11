#!/usr/bin/env bash
# scripts/smoke/orphan-agent-dir.sh — Issue #598 Track 2 smoke.
#
# Validates the new `orphan-agent-dir` detector in bridge-doctor.py.
# The detector enumerates BRIDGE_AGENT_HOME_ROOT direct children,
# subtracts the `agent registry --json` set (Track 1), and emits one
# finding per remainder with an `is_test_artifact` heuristic flag.
#
# Test cases:
#   T1. Empty BRIDGE_AGENT_HOME_ROOT → no findings.
#   T2. Dir not in registry, name matches no test prefix → 1 finding,
#       is_test_artifact=false.
#   T3. Dir matching `smoke-*` prefix → finding with
#       is_test_artifact=true. Same prefix list as Track 4
#       (lib/bridge-core.sh:BRIDGE_TEST_ARTIFACT_PREFIXES).
#   T4. Dir whose basename matches an `agent registry --json` `id` →
#       not flagged (positive control: live dynamic agent must not
#       be reaped).
#   T5. `_template` and `shared` skipped silently.
#   T6. Dir with an unreadable subdir → finding still emitted; no
#       Python traceback (best-effort size_bytes / last_active_at).
#   T7. `*-repro-<digits>` suffix recognized as test artifact.
#
# Uses an isolated BRIDGE_HOME via smoke_setup_bridge_home — never
# touches the operator's live runtime. Registry is supplied via
# `--agent-registry-json` so this fixture does NOT depend on
# bridge-agent.sh registry being runnable in the test scope.

set -euo pipefail

SMOKE_NAME="orphan-agent-dir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  # Restore any chmod we did so rm -rf can clear the temp root.
  if [[ -n "${ORPHAN_LOCKED_DIR:-}" && -d "$ORPHAN_LOCKED_DIR" ]]; then
    chmod -R u+rwX "$ORPHAN_LOCKED_DIR" 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "orphan-agent-dir"

REPO_ROOT="$SMOKE_REPO_ROOT"

PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

DOCTOR="$REPO_ROOT/bridge-doctor.py"
smoke_assert_file_exists "$DOCTOR" "doctor script present"

# Empty agent-list payload — the doctor's other detectors need a roster
# but that's out of scope here. Reuse for every run.
EMPTY_AGENT_LIST="$SMOKE_TMP_ROOT/agent-list.empty.json"
printf '%s\n' '[]' >"$EMPTY_AGENT_LIST"

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

reset_home_root() {
  # Reset agent-home-root to a clean dir between tests so each test
  # starts from a known state.
  if [[ -n "${ORPHAN_LOCKED_DIR:-}" && -d "$ORPHAN_LOCKED_DIR" ]]; then
    chmod -R u+rwX "$ORPHAN_LOCKED_DIR" 2>/dev/null || true
    ORPHAN_LOCKED_DIR=""
  fi
  rm -rf "$BRIDGE_AGENT_HOME_ROOT"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT"
}

write_registry() {
  # write_registry <output-file> <id1> [<id2> ...]
  # Emits a minimal `agent registry --json`-shaped JSON array.
  local out="$1"
  shift
  local ids=("$@")
  if (( ${#ids[@]} == 0 )); then
    printf '%s\n' '[]' >"$out"
    return
  fi
  {
    printf '['
    local first=1
    local id
    for id in "${ids[@]}"; do
      if (( first )); then
        first=0
      else
        printf ','
      fi
      printf '{"id":"%s","class":"dynamic","agent_source":"dynamic","privilege_class":"user","home":"%s/%s","engine":"claude","is_alive":true,"source":"dynamic-active-env"}' \
        "$id" "$BRIDGE_AGENT_HOME_ROOT" "$id"
    done
    printf ']\n'
  } >"$out"
}

run_doctor_orphan() {
  # run_doctor_orphan <registry-json>
  local registry="$1"
  "$PY_BIN" "$DOCTOR" --json \
    --detectors orphan-agent-dir \
    --agent-registry-json "$registry" \
    --agent-list-json "$EMPTY_AGENT_LIST" \
    --agent-home-root "$BRIDGE_AGENT_HOME_ROOT"
}

# Return number of findings (after filtering for orphan-agent-dir kind
# only, so an unrelated detector-error from a fragile subdetector does
# not contaminate the count).
findings_count() {
  local payload="$1"
  "$PY_BIN" -c '
import json, sys
data = json.loads(sys.stdin.read() or "[]")
print(sum(1 for r in data if r.get("kind") == "orphan-agent-dir"))
' <<<"$payload"
}

# Return JSON list of orphan-agent-dir findings only (drops detector-error
# noise so per-test JSON inspection stays simple).
findings_only() {
  local payload="$1"
  "$PY_BIN" -c '
import json, sys
data = json.loads(sys.stdin.read() or "[]")
print(json.dumps([r for r in data if r.get("kind") == "orphan-agent-dir"]))
' <<<"$payload"
}

# Pull a JSON field from the first finding matching `agent`.
finding_field() {
  local payload="$1"
  local agent="$2"
  local field="$3"
  "$PY_BIN" -c '
import json, sys
agent, field = sys.argv[1], sys.argv[2]
data = json.loads(sys.stdin.read() or "[]")
matches = [r for r in data if r.get("kind") == "orphan-agent-dir" and r.get("agent") == agent]
if not matches:
    print("__MISSING__")
    sys.exit(0)
ev = matches[0].get("evidence") or {}
val = ev.get(field, matches[0].get(field, "__MISSING__"))
if isinstance(val, bool):
    print("true" if val else "false")
else:
    print(val)
' "$agent" "$field" <<<"$payload"
}

# ---------------------------------------------------------------------------
# T1 — empty agent-home-root → no findings.
# ---------------------------------------------------------------------------
test_empty_home_root() {
  reset_home_root
  local registry="$SMOKE_TMP_ROOT/registry.t1.json"
  write_registry "$registry"

  local out
  out="$(run_doctor_orphan "$registry")"
  local count
  count="$(findings_count "$out")"
  smoke_assert_eq "0" "$count" "T1 empty home root → no orphan findings"
}

# ---------------------------------------------------------------------------
# T2 — orphan dir with non-test name → 1 finding, is_test_artifact=false.
# ---------------------------------------------------------------------------
test_plain_orphan() {
  reset_home_root
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/shopicode"
  printf 'placeholder\n' >"$BRIDGE_AGENT_HOME_ROOT/shopicode/notes.md"
  local registry="$SMOKE_TMP_ROOT/registry.t2.json"
  write_registry "$registry"

  local out
  out="$(run_doctor_orphan "$registry")"
  local count
  count="$(findings_count "$out")"
  smoke_assert_eq "1" "$count" "T2 one orphan finding"

  local agent_field
  agent_field="$(finding_field "$out" "shopicode" "dir")"
  smoke_assert_contains "$agent_field" "shopicode" "T2 evidence.dir"

  local is_test
  is_test="$(finding_field "$out" "shopicode" "is_test_artifact")"
  smoke_assert_eq "false" "$is_test" "T2 is_test_artifact false for plain name"

  local registry_checked
  registry_checked="$(finding_field "$out" "shopicode" "registry_checked")"
  smoke_assert_eq "agent registry --json" "$registry_checked" \
    "T2 evidence.registry_checked label"
}

# ---------------------------------------------------------------------------
# T3 — `smoke-*` orphan flagged is_test_artifact=true.
# ---------------------------------------------------------------------------
test_smoke_prefix_orphan() {
  reset_home_root
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/smoke-foo"
  local registry="$SMOKE_TMP_ROOT/registry.t3.json"
  write_registry "$registry"

  local out
  out="$(run_doctor_orphan "$registry")"
  local is_test
  is_test="$(finding_field "$out" "smoke-foo" "is_test_artifact")"
  smoke_assert_eq "true" "$is_test" "T3 smoke- prefix flagged is_test_artifact"
}

# ---------------------------------------------------------------------------
# T4 — registry-matching dir is NOT flagged (live dynamic agent control).
# ---------------------------------------------------------------------------
test_registered_agent_not_flagged() {
  reset_home_root
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/agb-dev-claude"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/orphan-leftover"
  local registry="$SMOKE_TMP_ROOT/registry.t4.json"
  write_registry "$registry" "agb-dev-claude"

  local out
  out="$(run_doctor_orphan "$registry")"
  local count
  count="$(findings_count "$out")"
  smoke_assert_eq "1" "$count" "T4 only the unregistered dir is flagged"

  local agb_field
  agb_field="$(finding_field "$out" "agb-dev-claude" "dir")"
  smoke_assert_eq "__MISSING__" "$agb_field" \
    "T4 registered live agent dir is NOT flagged"

  local orphan_dir
  orphan_dir="$(finding_field "$out" "orphan-leftover" "dir")"
  smoke_assert_contains "$orphan_dir" "orphan-leftover" \
    "T4 unregistered dir is flagged"
}

# ---------------------------------------------------------------------------
# T5 — `_template` and `shared` skipped silently.
# ---------------------------------------------------------------------------
test_template_and_shared_skipped() {
  reset_home_root
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/_template"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/shared"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/.claude-projects"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/real-orphan"
  local registry="$SMOKE_TMP_ROOT/registry.t5.json"
  write_registry "$registry"

  local out
  out="$(run_doctor_orphan "$registry")"
  local count
  count="$(findings_count "$out")"
  smoke_assert_eq "1" "$count" \
    "T5 _template / shared / .claude-projects are skipped silently"

  local real_dir
  real_dir="$(finding_field "$out" "real-orphan" "dir")"
  smoke_assert_contains "$real_dir" "real-orphan" \
    "T5 the actual orphan is still flagged"
}

# ---------------------------------------------------------------------------
# T6 — dir with an unreadable subdir still surfaces a finding.
# ---------------------------------------------------------------------------
test_unreadable_subdir_partial_finding() {
  reset_home_root
  local target="$BRIDGE_AGENT_HOME_ROOT/locked-orphan"
  mkdir -p "$target/raw"
  printf 'data\n' >"$target/raw/note.md"
  chmod 000 "$target/raw"
  ORPHAN_LOCKED_DIR="$target"
  local registry="$SMOKE_TMP_ROOT/registry.t6.json"
  write_registry "$registry"

  local out rc=0
  out="$(run_doctor_orphan "$registry")" || rc=$?
  smoke_assert_eq "0" "$rc" "T6 doctor exits 0 even with unreadable subdir"

  local count
  count="$(findings_count "$out")"
  smoke_assert_eq "1" "$count" \
    "T6 unreadable subdir still produces an orphan finding"

  # Restore perms before any further test runs.
  chmod -R u+rwX "$target"
  ORPHAN_LOCKED_DIR=""

  if grep -q 'Traceback' <<<"$out"; then
    smoke_fail "T6 doctor output contains a Python traceback: $out"
  fi
}

# ---------------------------------------------------------------------------
# T7 — `*-repro-<digits>` suffix recognised as test artifact.
# ---------------------------------------------------------------------------
test_repro_suffix_artifact() {
  reset_home_root
  # codex r1 noted that `created-agent-repro-44925` matches the
  # `created-agent-` prefix branch first, so the regex path is never
  # reached. Add a pure-regex name (no matching prefix) to isolate the
  # ORPHAN_TEST_ARTIFACT_REPRO_REGEX branch.
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/created-agent-repro-44925"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/worker-repro-42"
  local registry="$SMOKE_TMP_ROOT/registry.t7.json"
  write_registry "$registry"

  local out
  out="$(run_doctor_orphan "$registry")"
  local is_test
  is_test="$(finding_field "$out" "created-agent-repro-44925" "is_test_artifact")"
  smoke_assert_eq "true" "$is_test" \
    "T7 (a) *-repro-<digits> suffix flagged is_test_artifact (prefix branch)"
  is_test="$(finding_field "$out" "worker-repro-42" "is_test_artifact")"
  smoke_assert_eq "true" "$is_test" \
    "T7 (b) regex-only -repro-<digits> match (no prefix overlap)"
}

# ---------------------------------------------------------------------------
# T8 — Issue #1787: a case-variant spelling of a REGISTERED agent's dir is NOT
#      flagged as an orphan on a case-insensitive filesystem. The registry
#      holds `crm-test-bsh`; the on-disk dir was created `CRM-TEST-BSH` (same
#      dir on APFS). The detector must samefile-match it to the registered
#      agent and skip — never recommend a destructive quarantine of a live
#      agent's settings tree. A genuinely unregistered dir in the same run
#      still fires (detector teeth intact).
# ---------------------------------------------------------------------------
test_case_variant_registered_not_flagged() {
  reset_home_root
  # Create the dir with the UPPERCASE spelling; register the LOWERCASE name.
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/CRM-TEST-BSH"
  printf 'live\n' >"$BRIDGE_AGENT_HOME_ROOT/CRM-TEST-BSH/marker.txt"

  # Gate on case-insensitivity: only reproducible when the lowercase spelling
  # reaches the SAME dir (mirrors the #1759 smoke's APFS gate). On a
  # case-sensitive fs the two are distinct dirs and the collision can't occur.
  local lower_dir="$BRIDGE_AGENT_HOME_ROOT/crm-test-bsh"
  if ! [[ -d "$lower_dir" ]] || ! [[ "$lower_dir" -ef "$BRIDGE_AGENT_HOME_ROOT/CRM-TEST-BSH" ]]; then
    smoke_log "T8 skip: case-sensitive filesystem — case-variant collision not reproducible here"
    return 0
  fi

  # Also drop a genuinely unregistered dir so the teeth-intact control runs.
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/genuine-orphan-zzz"

  local registry="$SMOKE_TMP_ROOT/registry.t8.json"
  # write_registry stores home as $BRIDGE_AGENT_HOME_ROOT/<id> — i.e.
  # $BRIDGE_AGENT_HOME_ROOT/crm-test-bsh, the lowercase (registered) spelling.
  write_registry "$registry" "crm-test-bsh"

  local out
  out="$(run_doctor_orphan "$registry")"

  # The case-variant dir is NOT flagged (samefile match to the registered home).
  local cv_dir
  cv_dir="$(finding_field "$out" "CRM-TEST-BSH" "dir")"
  smoke_assert_eq "__MISSING__" "$cv_dir" \
    "T8 case-variant of a registered agent is NOT flagged as orphan"

  # The genuine orphan IS still flagged.
  local orphan_dir
  orphan_dir="$(finding_field "$out" "genuine-orphan-zzz" "dir")"
  smoke_assert_contains "$orphan_dir" "genuine-orphan-zzz" \
    "T8 genuinely unregistered dir still fires (detector teeth intact)"

  local count
  count="$(findings_count "$out")"
  smoke_assert_eq "1" "$count" \
    "T8 exactly one finding (genuine orphan only; case-variant skipped)"
}

# ---------------------------------------------------------------------------
# T9 — Issue #1787 (codex r1): the skip is INODE identity, NOT an unconditional
#      case-fold. A dir whose basename only case-DIFFERS from a registered id
#      but is a PHYSICALLY DISTINCT directory (different inode) MUST still be
#      flagged — otherwise the detector loses its teeth on a case-sensitive fs
#      (Linux), where `CRM-TEST-BSH` and `crm-test-bsh` are separate dirs and
#      the uppercase one is a genuine orphan. We reproduce the distinct-inode
#      case on ANY fs (incl. case-insensitive APFS) by registering the agent's
#      home at a SEPARATE physical location, so the case-folding on-disk dir is
#      provably NOT the same file as the registered home.
# ---------------------------------------------------------------------------
test_case_folding_but_distinct_inode_still_flagged() {
  reset_home_root
  # Registered agent `widget` whose home lives OUTSIDE the home root, in a
  # dedicated physical dir — so the same-named on-disk dir below is a
  # genuinely different inode even on a case-insensitive volume.
  local real_home="$SMOKE_TMP_ROOT/widget-real-home"
  mkdir -p "$real_home"
  # On-disk dir under the home root whose basename case-folds to `widget` but
  # is NOT the registered home (different inode). On a case-sensitive fs this
  # is the canonical "uppercase variant is a separate orphan" shape.
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT/WIDGET"

  # Custom registry: home points at the dedicated dir, not $HOME_ROOT/widget.
  local registry="$SMOKE_TMP_ROOT/registry.t9.json"
  printf '[{"id":"widget","class":"dynamic","agent_source":"dynamic","privilege_class":"user","home":"%s","workdir":"%s","engine":"claude","is_alive":true,"source":"dynamic-active-env"}]\n' \
    "$real_home" "$real_home" >"$registry"

  local out
  out="$(run_doctor_orphan "$registry")"

  # `WIDGET` is a distinct inode from the registered home → still flagged
  # (the case-fold collision must NOT suppress a genuine orphan).
  local orphan_dir
  orphan_dir="$(finding_field "$out" "WIDGET" "dir")"
  smoke_assert_contains "$orphan_dir" "WIDGET" \
    "T9 a distinct-inode case-folding dir is STILL flagged (no false negative)"

  local count
  count="$(findings_count "$out")"
  smoke_assert_eq "1" "$count" \
    "T9 exactly one finding (the distinct-inode orphan)"
}

# ---------------------------------------------------------------------------
# Drive cases.
# ---------------------------------------------------------------------------
ORPHAN_LOCKED_DIR=""
smoke_run "T1 empty home root" test_empty_home_root
smoke_run "T2 plain orphan" test_plain_orphan
smoke_run "T3 smoke- prefix orphan" test_smoke_prefix_orphan
smoke_run "T4 registered agent not flagged" test_registered_agent_not_flagged
smoke_run "T5 _template/shared skipped" test_template_and_shared_skipped
smoke_run "T6 unreadable subdir partial finding" test_unreadable_subdir_partial_finding
smoke_run "T7 *-repro-<digits> suffix" test_repro_suffix_artifact
smoke_run "T8 case-variant registered not flagged" test_case_variant_registered_not_flagged
smoke_run "T9 distinct-inode case-fold still flagged" test_case_folding_but_distinct_inode_still_flagged

smoke_log "all orphan-agent-dir cases passed"
