#!/usr/bin/env bash
# scripts/smoke/2061-convert-migration.sh — FR #2061 Track A migration engine.
#
# Pins the lib/bridge-agent-convert.sh contract against a fabricated operator
# ~/.claude (no live Claude, fully isolated BRIDGE_HOME). The migration engine
# is the data-safety core of `agent convert <a> --to static`: a dynamic vanilla
# Claude agent reads the operator-global ~/.claude, a static agent reads an
# isolated <agent-home>/.claude — flipping the roster without moving the state
# strands every transcript + memory file. This smoke proves the engine moves
# ALL of it, copy-not-move, with backup + internal rollback.
#
# Cases (all in an isolated BRIDGE_HOME; reuses scripts/smoke/lib.sh):
#   T1  dry-run manifest lists EVERY fixture file (two in-workdir cwds incl. a
#       descendant, subagents/workflows/memory, auto-memory) — ZERO omission;
#       an outside-workdir cwd is a SKIPPED candidate, not silently dropped.
#   T1b --include-cwd pulls the outside-workdir cwd into the manifest.
#   T2  apply -> every dest is byte-equal to its src and mtimes are preserved.
#   T3  apply created the on-disk backup dir (state/convert-backups/<a>/<ts>/).
#   T4  source tree is UNTOUCHED after apply (copy, not move).
#   T5  a second apply is a no-op (skip-if-identical; created==0).
#   T6  internal rollback restores the pre-apply target (created files removed).
#   T7  resolve_config_dirs: dynamic-vanilla -> source=operator ~/.claude,
#       target=isolated <agent-home>/.claude (no roster flip needed); an
#       iso-effective target FAILS CLOSED (rc 3, MVP shared-mode only).

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:2061-convert-migration][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="2061-convert-migration"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

# The pure engine functions need only python3 + env; source in-process.
# shellcheck source=lib/bridge-agent-convert.sh
source "$REPO_ROOT/lib/bridge-agent-convert.sh"

BASH4_BIN="${BRIDGE_BASH_BIN:-${BASH:-bash}}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

OPERATOR_HOME="$SMOKE_TMP_ROOT/operator-home"
SRC="$OPERATOR_HOME/.claude"
TARGET="$SMOKE_TMP_ROOT/agent-home/.claude"
WORKDIR="$SMOKE_TMP_ROOT/repo"
CWD_DESC="$WORKDIR/new"          # descendant of workdir -> auto-include
CWD_OUT="$SMOKE_TMP_ROOT/sibling-repo"  # outside workdir -> candidate
mkdir -p "$WORKDIR" "$CWD_DESC" "$CWD_OUT"

# auto-memory slug: realpath($BRIDGE_HOME) with "/" and "." -> "-" (the seed
# convention, scripts/smoke/2014). Track A treats it as an opaque dir name; the
# fixture and the manifest call use the SAME value.
SLUG="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]).replace(os.sep,"-").replace(".","-"))' "$BRIDGE_HOME")"

slug_of() { local p="$1"; p="${p//\//-}"; printf '%s' "$p"; }
SLUG_A="$(slug_of "$WORKDIR")"
SLUG_B="$(slug_of "$CWD_DESC")"
SLUG_C="$(slug_of "$CWD_OUT")"

# --- Fixture: operator ~/.claude with two in-workdir cwds + one outside ------
mkdir -p \
  "$SRC/projects/$SLUG_A/sid1/subagents" \
  "$SRC/projects/$SLUG_A/sid1/workflows" \
  "$SRC/projects/$SLUG_A/memory" \
  "$SRC/projects/$SLUG_B" \
  "$SRC/projects/$SLUG_C" \
  "$SRC/auto-memory/$SLUG/tester"
printf '{"cwd":"%s","sessionId":"sid1"}\n' "$WORKDIR" > "$SRC/projects/$SLUG_A/sid1.jsonl"
printf '{"type":"subagent"}\n'                          > "$SRC/projects/$SLUG_A/sid1/subagents/sub1.jsonl"
printf '{"type":"workflow"}\n'                          > "$SRC/projects/$SLUG_A/sid1/workflows/wf1.jsonl"
printf '# MEMORY\nproject memory\n'                     > "$SRC/projects/$SLUG_A/memory/MEMORY.md"
printf 'a feedback note\n'                              > "$SRC/projects/$SLUG_A/memory/feedback_x.md"
printf '{"cwd":"%s","sessionId":"sid2"}\n' "$CWD_DESC"  > "$SRC/projects/$SLUG_B/sid2.jsonl"
printf '{"cwd":"%s","sessionId":"sid3"}\n' "$CWD_OUT"   > "$SRC/projects/$SLUG_C/sid3.jsonl"
printf 'auto-memory note\n'                             > "$SRC/auto-memory/$SLUG/tester/notes.md"

# Files that MUST appear in a no-include-cwd manifest (zero-omission gate).
# Already in code-point order to match python's sorted() in the manifest query.
EXPECTED_BASENAMES="MEMORY.md feedback_x.md notes.md sid1.jsonl sid2.jsonl sub1.jsonl wf1.jsonl"
EXPECTED_COUNT=7

# Manifest query helper (argv form — no heredoc-stdin, footgun #11 safe).
_MANIFEST_Q='
import json
import os
import sys

manifest = json.load(open(sys.argv[1]))
query = sys.argv[2]
files = manifest["files"]
if query == "total":
    print(manifest["total_files"])
elif query == "basenames":
    print(" ".join(sorted(os.path.basename(f["dest"]) for f in files)))
elif query == "cats":
    print(" ".join(sorted(set(f["category"] for f in files))))
elif query == "skipped_basenames":
    print(" ".join(sorted(os.path.basename(s["cwd"]) for s in manifest["skipped_cwds"])))
elif query == "dest_all_under_target":
    target = manifest["target_config_dir"]
    sys.exit(0 if all(f["dest"].startswith(target + os.sep) for f in files) else 1)
else:
    sys.exit(99)
'
mq() { python3 -c "$_MANIFEST_Q" "$@"; }

# ===========================================================================
# T1 — dry-run manifest is zero-omission; outside-workdir cwd is a candidate.
# ===========================================================================
test_t1_manifest_complete() {
  local manifest="$SMOKE_TMP_ROOT/m1.json"
  bridge_convert_build_manifest tester "$SRC" "$TARGET" "$WORKDIR" "$SLUG" > "$manifest"

  smoke_assert_eq "$EXPECTED_COUNT" "$(mq "$manifest" total)" \
    "T1: manifest total_files != expected (zero-omission gate)"

  local got_names
  got_names="$(mq "$manifest" basenames)"
  smoke_assert_eq "$EXPECTED_BASENAMES" "$got_names" \
    "T1: manifest basenames mismatch (a fixture file was omitted)"

  smoke_assert_eq "auto-memory memory subagent transcript workflow" "$(mq "$manifest" cats)" \
    "T1: manifest categories incomplete (subagents/workflows/memory/auto-memory all required)"

  mq "$manifest" dest_all_under_target \
    || smoke_fail "T1: a manifest dest path is not under the target config dir"

  # The outside-workdir cwd is reported as a SKIPPED candidate, never silently
  # dropped, and its transcript is NOT in the migrate set.
  case " $got_names " in
    *" sid3.jsonl "*) smoke_fail "T1: outside-workdir transcript sid3.jsonl was migrated without --include-cwd";;
  esac
  local skipped; skipped="$(python3 -c "$_MANIFEST_Q" "$manifest" skipped_basenames)"
  smoke_assert_contains "$skipped" "sibling-repo" \
    "T1: outside-workdir cwd not surfaced as a --include-cwd candidate"
  smoke_log "T1 OK — manifest lists all $EXPECTED_COUNT files; outside cwd is a candidate"
}

# ===========================================================================
# T1b — --include-cwd confirmation pulls the outside-workdir cwd in.
# ===========================================================================
test_t1b_include_cwd() {
  local manifest="$SMOKE_TMP_ROOT/m1b.json"
  bridge_convert_build_manifest tester "$SRC" "$TARGET" "$WORKDIR" "$SLUG" "$CWD_OUT" > "$manifest"
  smoke_assert_eq "8" "$(mq "$manifest" total)" \
    "T1b: --include-cwd did not add the outside-workdir transcript"
  case " $(mq "$manifest" basenames) " in
    *" sid3.jsonl "*) : ;;
    *) smoke_fail "T1b: confirmed outside cwd transcript sid3.jsonl still missing";;
  esac
  smoke_log "T1b OK — --include-cwd migrates the confirmed sibling cwd"
}

# ===========================================================================
# T2/T3/T4 — apply: byte-equality + mtime preserved, backup present, source
# untouched (copy not move).
# ===========================================================================
SRC_SUM_BEFORE=""
test_t2_apply_byte_equal() {
  SRC_SUM_BEFORE="$(find "$SRC" -type f -exec shasum {} \; | sort | shasum)"
  local manifest="$SMOKE_TMP_ROOT/m2.json"
  bridge_convert_build_manifest tester "$SRC" "$TARGET" "$WORKDIR" "$SLUG" > "$manifest"

  local result
  result="$(bridge_convert_apply_manifest "$manifest" "TS-T2")"
  local created
  created="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["created"])')"
  smoke_assert_eq "$EXPECTED_COUNT" "$created" "T2: apply did not create every manifest file"

  # Byte-equality + mtime over the MIGRATED set (the manifest's src/dest pairs),
  # NOT the whole source tree — the skipped sibling cwd is deliberately absent.
  local src dest
  while IFS=$'\t' read -r src dest; do
    [[ -n "$src" ]] || continue
    cmp -s "$src" "$dest" || smoke_fail "T2: dest not byte-equal to src: $dest"
  done < <(python3 -c 'import json,sys
m=json.load(open(sys.argv[1]))
for f in m["files"]:
    print(f["src"] + "\t" + f["dest"])' "$manifest")

  python3 -c '
import json, os, sys
m = json.load(open(sys.argv[1]))
for f in m["files"]:
    if int(os.path.getmtime(f["src"])) != int(os.path.getmtime(f["dest"])):
        print("mtime drift: " + f["rel"])
        sys.exit(1)
sys.exit(0)
' "$manifest" || smoke_fail "T2: mtimes not preserved on copy"
  smoke_log "T2 OK — every migrated dest is byte-equal to src; mtimes preserved"
}

test_t3_backup_present() {
  local backup_dir="$BRIDGE_STATE_DIR/convert-backups/tester/TS-T2"
  [[ -d "$backup_dir" ]] || smoke_fail "T3: backup dir not created: $backup_dir"
  smoke_assert_file_exists "$backup_dir/manifest.json" "T3: backup manifest.json missing"
  smoke_assert_file_exists "$backup_dir/apply-log.json" "T3: backup apply-log.json missing"
  # Write-ahead recovery state persisted before the copy loop (crash-safe).
  smoke_assert_file_exists "$backup_dir/apply-meta.json" "T3: apply-meta.json (target) missing"
  smoke_assert_file_exists "$backup_dir/apply-journal.jsonl" "T3: apply-journal.jsonl (WAL) missing"
  smoke_log "T3 OK — backup dir + manifest + apply-log + WAL (meta/journal) present"
}

test_t4_source_untouched() {
  local after
  after="$(find "$SRC" -type f -exec shasum {} \; | sort | shasum)"
  smoke_assert_eq "$SRC_SUM_BEFORE" "$after" \
    "T4: source tree changed after apply (must be copy, not move)"
  smoke_log "T4 OK — source tree untouched (copy-not-move)"
}

# ===========================================================================
# T5 — a second apply is a no-op (skip-if-identical).
# ===========================================================================
test_t5_idempotent() {
  local manifest="$SMOKE_TMP_ROOT/m2.json"
  local result created skipped
  result="$(bridge_convert_apply_manifest "$manifest" "TS-T5")"
  created="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["created"])')"
  skipped="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["skipped"])')"
  smoke_assert_eq "0" "$created" "T5: idempotent re-apply still created files"
  smoke_assert_eq "$EXPECTED_COUNT" "$skipped" "T5: idempotent re-apply did not skip identical files"
  smoke_log "T5 OK — re-apply is a no-op (created=0, skipped=$skipped)"
}

# ===========================================================================
# T6 — internal rollback restores the pre-apply target.
# ===========================================================================
test_t6_rollback() {
  local fresh="$SMOKE_TMP_ROOT/agent-home-fresh/.claude"
  local manifest="$SMOKE_TMP_ROOT/m6.json"
  bridge_convert_build_manifest tester "$SRC" "$fresh" "$WORKDIR" "$SLUG" > "$manifest"
  bridge_convert_apply_manifest "$manifest" "TS-T6" >/dev/null
  [[ "$(find "$fresh" -type f | wc -l | tr -d ' ')" -eq "$EXPECTED_COUNT" ]] \
    || smoke_fail "T6: pre-rollback target is not fully populated"

  bridge_convert_rollback tester "TS-T6" >/dev/null \
    || smoke_fail "T6: internal rollback returned non-zero (verification errors)"
  [[ "$(find "$fresh" -type f 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]] \
    || smoke_fail "T6: rollback did not remove the created target files"
  smoke_log "T6 OK — internal rollback removed every created file (target back to pre-apply)"
}

# ===========================================================================
# T8 — fail-closed when a manifest source vanishes before copy. A partial
# migration must NOT report success (the orchestrator rolls back on nonzero).
# ===========================================================================
test_t8_missing_src_fail_closed() {
  local fresh="$SMOKE_TMP_ROOT/agent-home-t8/.claude"
  local manifest="$SMOKE_TMP_ROOT/m8.json"
  bridge_convert_build_manifest tester "$SRC" "$fresh" "$WORKDIR" "$SLUG" > "$manifest"
  # Drop one source file AFTER the manifest is built (the build->apply window).
  rm -f "$SRC/projects/$SLUG_A/memory/feedback_x.md"

  local result rc=0
  result="$(bridge_convert_apply_manifest "$manifest" "TS-T8")" || rc=$?
  smoke_assert_eq "1" "$rc" "T8: apply must exit nonzero when a manifest source is missing"
  local missing created
  missing="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["missing_src"])')"
  created="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["created"])')"
  smoke_assert_eq "1" "$missing" "T8: the vanished source was not counted as missing_src"
  # The still-present files are copied (rollback-recoverable) — proves we do not
  # abort the whole batch, just report incomplete.
  [[ "$created" -ge 1 ]] || smoke_fail "T8: present files were not copied alongside the missing one"
  bridge_convert_rollback tester "TS-T8" >/dev/null || smoke_fail "T8: rollback of the partial apply failed"
  # Restore the fixture for any later case ordering safety.
  printf 'a feedback note\n' > "$SRC/projects/$SLUG_A/memory/feedback_x.md"
  smoke_log "T8 OK — missing source fails apply closed (rc 1); partial copy is rollback-recoverable"
}

# ===========================================================================
# T9 — fail-closed symlink traversal: a target config dir that is a symlink
# pointing outside is REJECTED; no file is written through the link.
# ===========================================================================
test_t9_symlink_fail_closed() {
  local escape="$SMOKE_TMP_ROOT/evil-escape"
  local evil_home="$SMOKE_TMP_ROOT/evil-agent"
  mkdir -p "$escape" "$evil_home"
  ln -s "$escape" "$evil_home/.claude"   # target config dir is a symlink outside
  local manifest="$SMOKE_TMP_ROOT/m9.json"
  bridge_convert_build_manifest tester "$SRC" "$evil_home/.claude" "$WORKDIR" "$SLUG" > "$manifest"

  local result rc=0
  result="$(bridge_convert_apply_manifest "$manifest" "TS-T9")" || rc=$?
  smoke_assert_eq "1" "$rc" "T9: apply must fail closed on a symlinked target config dir"
  local unsafe created
  unsafe="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["unsafe_dest"])')"
  created="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["created"])')"
  smoke_assert_eq "$EXPECTED_COUNT" "$unsafe" "T9: not every dest was rejected as unsafe"
  smoke_assert_eq "0" "$created" "T9: a file was copied through the symlinked target"
  [[ "$(find "$escape" -type f 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]] \
    || smoke_fail "T9: data was written OUTSIDE the target through the symlink (traversal escape)"
  smoke_log "T9 OK — symlinked target rejected; zero files written through the link"
}

# ===========================================================================
# T10 — overwrite path: a stale pre-existing dest is backed up, overwritten with
# the source, and the internal rollback restores the stale original byte-exact.
# ===========================================================================
test_t10_overwrite_backup_restore() {
  local fresh="$SMOKE_TMP_ROOT/agent-home-t10/.claude"
  local rel="projects/$SLUG_A/sid1.jsonl"
  local manifest="$SMOKE_TMP_ROOT/m10.json"
  bridge_convert_build_manifest tester "$SRC" "$fresh" "$WORKDIR" "$SLUG" > "$manifest"
  # Pre-seed a STALE file at one dest path so apply must overwrite (not create).
  mkdir -p "$fresh/projects/$SLUG_A"
  printf 'STALE PRIOR CONTENT\n' > "$fresh/$rel"

  local result
  result="$(bridge_convert_apply_manifest "$manifest" "TS-T10")"
  local overwrote
  overwrote="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["overwrote"])')"
  [[ "$overwrote" -ge 1 ]] || smoke_fail "T10: stale dest was not overwritten (overwrote=$overwrote)"
  cmp -s "$SRC/$rel" "$fresh/$rel" || smoke_fail "T10: overwritten dest is not byte-equal to src"

  local backup="$BRIDGE_STATE_DIR/convert-backups/tester/TS-T10/overwritten/$rel"
  smoke_assert_file_exists "$backup" "T10: pre-overwrite backup of the stale dest is missing"
  grep -q "STALE PRIOR CONTENT" "$backup" || smoke_fail "T10: backup does not hold the original stale content"

  bridge_convert_rollback tester "TS-T10" >/dev/null || smoke_fail "T10: rollback returned non-zero"
  grep -q "STALE PRIOR CONTENT" "$fresh/$rel" \
    || smoke_fail "T10: rollback did not restore the stale original at the overwritten dest"
  smoke_log "T10 OK — overwrite backs up the original, copies src; rollback restores it byte-exact"
}

# ===========================================================================
# T7 — resolve_config_dirs: dynamic-vanilla source/target derivation + iso
# fail-closed. Roster-driven, so run in a fresh bash that loads bridge-lib.
# ===========================================================================
convert_eval() {
  # convert_eval <agent> <source> <isolation_mode> <os_user> <platform> <snippet>
  local agent="$1" src="$2" mode="$3" os_user="$4" platform="$5" snippet="$6"
  HOME="$OPERATOR_HOME" \
  BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
  BRIDGE_HOST_PLATFORM_OVERRIDE="$platform" \
  "$BASH4_BIN" -c "
    set -uo pipefail
    unset BRIDGE_DISABLE_ISOLATION
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    source '$REPO_ROOT/lib/bridge-agent-convert.sh' >/dev/null 2>&1
    bridge_reset_roster_maps
    a='$agent'
    BRIDGE_AGENT_IDS+=(\$a)
    BRIDGE_AGENT_ENGINE[\$a]=claude
    BRIDGE_AGENT_SESSION[\$a]=\$a
    BRIDGE_AGENT_WORKDIR[\$a]='$WORKDIR'
    BRIDGE_AGENT_SOURCE[\$a]='$src'
    BRIDGE_AGENT_ISOLATION_MODE[\$a]='$mode'
    BRIDGE_AGENT_OS_USER[\$a]='$os_user'
    BRIDGE_AGENT_CREATED_AT[\$a]=\$(date +%s)
    BRIDGE_AGENT_SESSION_ID[\$a]=''
    $snippet
  "
}

test_t7_resolve() {
  local out
  out="$(convert_eval dynv dynamic shared '' Darwin '
    pair="$(bridge_convert_resolve_config_dirs dynv)"
    printf "SRC=%s\n" "$(printf "%s" "$pair" | cut -f1)"
    printf "TGT=%s\n" "$(printf "%s" "$pair" | cut -f2)"
    printf "CFG=%s\n" "$(bridge_agent_claude_config_dir dynv)"
  ')" || smoke_fail "T7: resolve eval failed: $out"

  local src tgt cfg
  src="$(printf '%s\n' "$out" | sed -n 's/^SRC=//p' | head -n1)"
  tgt="$(printf '%s\n' "$out" | sed -n 's/^TGT=//p' | head -n1)"
  cfg="$(printf '%s\n' "$out" | sed -n 's/^CFG=//p' | head -n1)"

  smoke_assert_eq "$OPERATOR_HOME/.claude" "$src" \
    "T7: dynamic-vanilla source is not the operator-global ~/.claude"
  smoke_assert_eq "$cfg" "$tgt" \
    "T7: target is not the as-if-static config dir (bridge_agent_claude_config_dir)"
  [[ "$tgt" != "$src" ]] || smoke_fail "T7: target must differ from operator source (would be a no-op migration)"
  case "$tgt" in
    *"/dynv/"*".claude"|*"/dynv/home/.claude"|*"/dynv/.claude") : ;;
    *) smoke_fail "T7: target config dir is not the isolated per-agent dir: $tgt";;
  esac
  smoke_log "T7 OK — source=$src target=$tgt (no roster flip required)"
}

test_t7_iso_fail_closed() {
  local out rc
  out="$(convert_eval isov dynamic linux-user agent-bridge-isov Linux '
    if bridge_convert_resolve_config_dirs isov >/dev/null 2>&1; then echo RC=0; else echo RC=$?; fi
  ')" || smoke_fail "T7-iso: eval failed: $out"
  rc="$(printf '%s\n' "$out" | sed -n 's/^RC=//p' | head -n1)"
  smoke_assert_eq "3" "$rc" \
    "T7-iso: iso-effective target must FAIL CLOSED with rc 3 (MVP shared-mode only)"
  smoke_log "T7-iso OK — iso-effective target fails closed (rc 3)"
}

# --- run -------------------------------------------------------------------
smoke_run "T1 manifest zero-omission + outside-cwd candidate" test_t1_manifest_complete
smoke_run "T1b --include-cwd migrates confirmed sibling cwd" test_t1b_include_cwd
smoke_run "T2 apply byte-equal + mtime preserved" test_t2_apply_byte_equal
smoke_run "T3 backup dir + manifest + apply-log present" test_t3_backup_present
smoke_run "T4 source untouched (copy not move)" test_t4_source_untouched
smoke_run "T5 idempotent re-apply is a no-op" test_t5_idempotent
smoke_run "T6 internal rollback restores pre-apply target" test_t6_rollback
smoke_run "T8 missing source fails apply closed (rollback-recoverable)" test_t8_missing_src_fail_closed
smoke_run "T9 symlinked target rejected (no traversal escape)" test_t9_symlink_fail_closed
smoke_run "T10 overwrite backs up + rollback restores the original" test_t10_overwrite_backup_restore
smoke_run "T7 resolve dynamic-vanilla source/target derivation" test_t7_resolve
smoke_run "T7 iso-effective target fails closed" test_t7_iso_fail_closed

smoke_log "PASS — #2061 Track A migration engine: zero-omission manifest, copy-not-move byte-equal apply, backup, idempotent, internal rollback, iso fail-closed"
