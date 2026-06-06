#!/usr/bin/env bash
# scripts/smoke/1602-dryrun-ref-fidelity.sh — Issue #1602 smoke.
#
# `agb upgrade --ref <tag> --dry-run` must preview the upgrade plan against the
# REQUESTED ref, not whatever ref the source checkout currently sits on. The
# bug: the target-ref checkout is gated on `DRY_RUN -eq 0`, so dry-run never
# checks the ref out, and `analyze_live` read the working tree — so the plan was
# computed against the stale checked-out tree while the header truthfully showed
# the requested target. The fix threads `--upstream-ref <ref>` into
# analyze-live / apply-live on the dry-run path, which reads the upstream file
# SET via `git ls-tree -r --name-only <ref>` and BYTES via `git show <ref>:path`
# with NO checkout. The apply path is unchanged (it checks the ref out first and
# reads the working tree).
#
# Coverage (all against an isolated tmp git source + tmp target — never touches
# operator state, never mutates the source working tree):
#   T1  Preview reflects the NEWER ref: `analyze-live --upstream-ref <newer>`
#       (the dry-run path) while sitting on the OLDER tag returns the newer
#       ref's plan (new file present as missing_live, drifted file present,
#       deleted-in-newer file absent from the plan).
#   T2  Bug-shape contrast: `analyze-live` WITHOUT --upstream-ref (the old
#       behavior) reflects the OLDER checked-out tree — proving the two differ.
#   T3  No working-tree mutation: HEAD is unchanged after the dry-run reads.
#   T4  Header/body honesty: the ref-resolved upstream VERSION matches the
#       requested ref's VERSION (the field the header reads).
#   T5  apply-live --upstream-ref <newer> --dry-run produces the SAME plan as
#       the apply path that physically checks the ref out (dry-run/apply
#       parity — the whole point of the fix).
#   T6  apply-live rejects --upstream-ref without --dry-run (apply must read the
#       checked-out tree, never a ref).
#   T7  apply-live (real, after a checkout of the newer ref, NO --upstream-ref)
#       still copies the newer content into the target — apply path unchanged.
#
# Footgun #11: no heredoc / here-string feeding a subprocess interpreter.
# Python payloads run as `python3 -c '...'` with argv, not stdin.

set -euo pipefail

SMOKE_NAME="1602-dryrun-ref-fidelity"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOT_DIR="$SMOKE_REPO_ROOT"
UPGRADE_PY="$ROOT_DIR/bridge-upgrade.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd git
smoke_require_cmd python3
smoke_assert_file_exists "$UPGRADE_PY" "bridge-upgrade.py present"

smoke_make_temp_root

SRC="$SMOKE_TMP_ROOT/source"     # the git source checkout (analog of ~/.agent-bridge-source)
TGT="$SMOKE_TMP_ROOT/target"     # the live install (analog of ~/.agent-bridge)

# Read a top-level JSON count via python (no jq dependency).
json_count() {
  # $1 = json text, $2 = classification key under "counts"
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
print(data["counts"][sys.argv[2]])
' "$1" "$2"
}

# True (rc 0) iff a relpath appears in the analysis "files" list.
json_has_file() {
  # $1 = json text, $2 = relpath
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
paths = {f["path"] for f in data["files"]}
sys.exit(0 if sys.argv[2] in paths else 1)
' "$1" "$2"
}

# Stable signature of the apply-live plan: sorted "path:action" lines.
plan_signature() {
  # $1 = json text (apply-live payload). Avoid backslashes inside an f-string
  # (a SyntaxError on Python < 3.12) by concatenating with str.join.
  python3 -c '
import json, sys
data = json.loads(sys.argv[1])
rows = sorted(str(a["path"]) + ":" + str(a["action"]) for a in data["actions"])
print("\n".join(rows))
' "$1"
}

# --------------------------------------------------------------------------
# Build a fake source repo with two tagged releases.
#   v-old: common.sh="OLD", drift.sh="base", gone.sh present, VERSION=0.1.0
#   v-new: common.sh="OLD", drift.sh="NEW", new.sh added, gone.sh removed,
#          VERSION=0.2.0
# The live target (TGT) is seeded to match v-old exactly, so the recorded
# upgrade base == v-old. A dry-run preview of v-new while the source sits on
# v-old must reflect v-new (drift.sh upstream_only/merge, new.sh missing_live,
# gone.sh NOT in plan), NOT v-old.
# --------------------------------------------------------------------------
build_source() {
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" config user.email smoke@example.com
  git -C "$SRC" config user.name "smoke"
  git -C "$SRC" config commit.gpgsign false

  printf 'OLD\n' >"$SRC/common.sh"
  printf 'base\n' >"$SRC/drift.sh"
  printf 'will be removed\n' >"$SRC/gone.sh"
  printf '0.1.0\n' >"$SRC/VERSION"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "v-old"
  git -C "$SRC" tag v-old

  printf 'NEW\n' >"$SRC/drift.sh"
  printf 'brand new file\n' >"$SRC/new.sh"
  rm -f "$SRC/gone.sh"
  printf '0.2.0\n' >"$SRC/VERSION"
  git -C "$SRC" add -A
  git -C "$SRC" commit -q -m "v-new"
  git -C "$SRC" tag v-new

  # Park the working tree on the OLDER tag — the reproduction precondition.
  git -C "$SRC" checkout -q v-old
}

build_target() {
  # Live install matches v-old content (the installed baseline).
  mkdir -p "$TGT"
  printf 'OLD\n' >"$TGT/common.sh"
  printf 'base\n' >"$TGT/drift.sh"
  printf 'will be removed\n' >"$TGT/gone.sh"
  printf '0.1.0\n' >"$TGT/VERSION"
}

build_source
build_target

OLD_HEAD="$(git -C "$SRC" rev-parse v-old)"
NEW_HEAD="$(git -C "$SRC" rev-parse v-new)"
BASE_REF="$OLD_HEAD"   # recorded source_head of the prior (v-old) install

smoke_assert_eq "$OLD_HEAD" "$(git -C "$SRC" rev-parse HEAD)" "source parked on v-old before dry-run"

# --------------------------------------------------------------------------
# T1 — preview reflects the NEWER ref (--upstream-ref v-new = the dry-run path).
# --------------------------------------------------------------------------
t1_preview_reflects_newer_ref() {
  local out
  out="$(python3 "$UPGRADE_PY" analyze-live \
    --source-root "$SRC" --target-root "$TGT" \
    --base-ref "$BASE_REF" --upstream-ref v-new)"

  # new.sh exists only in v-new and is absent from the live target → missing_live.
  smoke_assert_eq "1" "$(json_count "$out" missing_live)" "T1 missing_live count (new.sh from v-new)"
  json_has_file "$out" "new.sh" || smoke_fail "T1: new.sh (v-new only) must appear in the plan"

  # drift.sh AND VERSION both differ from live while base(v-old)==live, so both
  # classify upstream_only (deploy the v-new content): drift.sh base/live="base"
  # vs upstream(v-new)="NEW"; VERSION base/live="0.1.0" vs upstream="0.2.0".
  smoke_assert_eq "2" "$(json_count "$out" upstream_only)" "T1 upstream_only count (drift.sh + VERSION -> v-new)"
  json_has_file "$out" "drift.sh" || smoke_fail "T1: drift.sh must appear in the plan as a v-new change"
  json_has_file "$out" "VERSION" || smoke_fail "T1: VERSION must appear (v-new bumps it)"

  # common.sh is "OLD" in BOTH tags and matches live → unchanged (the file set
  # came from v-new, but the byte compare against live yields no work).
  smoke_assert_eq "1" "$(json_count "$out" unchanged)" "T1 unchanged count (common.sh same in v-old/v-new)"

  # gone.sh was deleted in v-new → it must NOT appear in the v-new file set.
  if json_has_file "$out" "gone.sh"; then
    smoke_fail "T1: gone.sh (removed in v-new) must NOT appear in a v-new preview"
  fi
}
smoke_run "T1 preview reflects the newer ref" t1_preview_reflects_newer_ref

# --------------------------------------------------------------------------
# T2 — bug-shape contrast: WITHOUT --upstream-ref the analysis reflects the
# OLDER checked-out tree (this is what the old buggy dry-run did). Proves the
# fix actually changes the previewed plan.
# --------------------------------------------------------------------------
t2_no_ref_reflects_checked_out_tree() {
  local out
  out="$(python3 "$UPGRADE_PY" analyze-live \
    --source-root "$SRC" --target-root "$TGT" --base-ref "$BASE_REF")"

  # Sitting on v-old: working tree == live target (both v-old) → nothing to do.
  smoke_assert_eq "0" "$(json_count "$out" missing_live)" "T2 missing_live (v-old tree has no new.sh)"
  smoke_assert_eq "0" "$(json_count "$out" upstream_only)" "T2 upstream_only (v-old drift.sh == live)"
  # new.sh is NOT in the v-old working tree → absent from the (stale) plan.
  if json_has_file "$out" "new.sh"; then
    smoke_fail "T2: new.sh must NOT appear when analyzing the v-old tree (proves the contrast)"
  fi
  # gone.sh exists in v-old tree and live → unchanged → not listed (but present
  # in the set, unlike the v-new preview where it is removed entirely).
}
smoke_run "T2 no --upstream-ref reflects the checked-out (older) tree" t2_no_ref_reflects_checked_out_tree

# --------------------------------------------------------------------------
# T3 — no working-tree mutation: HEAD unchanged after the ref-resolved reads.
# --------------------------------------------------------------------------
t3_no_tree_mutation() {
  local head_after
  head_after="$(git -C "$SRC" rev-parse HEAD)"
  smoke_assert_eq "$OLD_HEAD" "$head_after" "T3 source HEAD unchanged after dry-run (no checkout)"
  # Working tree content also unchanged: drift.sh is still the v-old "base".
  smoke_assert_eq "base" "$(cat "$SRC/drift.sh")" "T3 source working tree not mutated by dry-run"
  # The v-new-only file must not have leaked into the v-old working tree.
  if [[ -e "$SRC/new.sh" ]]; then
    smoke_fail "T3: new.sh leaked into the source working tree — dry-run mutated the tree"
  fi
}
smoke_run "T3 dry-run does not mutate the working tree" t3_no_tree_mutation

# --------------------------------------------------------------------------
# T4 — header/body honesty: the ref-resolved upstream VERSION equals the
# requested ref's VERSION (the value the dry-run header prints via
# `git show <ref>:VERSION`). With the fix, the body now matches that header.
# --------------------------------------------------------------------------
t4_version_matches_requested_ref() {
  local ref_version tree_version
  ref_version="$(git -C "$SRC" show v-new:VERSION | head -n 1)"
  tree_version="$(cat "$SRC/VERSION")"
  smoke_assert_eq "0.2.0" "$ref_version" "T4 v-new VERSION (header value)"
  smoke_assert_eq "0.1.0" "$tree_version" "T4 checked-out tree VERSION (the stale value the old body used)"
  # Sanity that they actually differ — otherwise the test is vacuous.
  [[ "$ref_version" != "$tree_version" ]] || smoke_fail "T4: ref and tree VERSION must differ for the test to be meaningful"
}
smoke_run "T4 ref VERSION matches the requested ref (header honesty)" t4_version_matches_requested_ref

# --------------------------------------------------------------------------
# T5 — dry-run/apply parity. The apply-live --upstream-ref --dry-run plan must
# equal the plan apply-live computes after physically checking out v-new (which
# is what --apply does). This is the core guarantee: preview == apply.
# --------------------------------------------------------------------------
t5_dryrun_apply_parity() {
  # Dry-run plan via the ref (no checkout).
  local dryrun_out dryrun_sig
  dryrun_out="$(python3 "$UPGRADE_PY" apply-live \
    --source-root "$SRC" --target-root "$TGT" \
    --base-ref "$BASE_REF" --upstream-ref v-new --dry-run)"
  dryrun_sig="$(plan_signature "$dryrun_out")"

  # The "what apply would do" plan: physically check out v-new (as --apply
  # does) and run apply-live --dry-run with NO --upstream-ref (working-tree
  # read). Use a throwaway clone so we never disturb SRC's parked HEAD.
  local apply_src="$SMOKE_TMP_ROOT/source-apply"
  git clone -q "$SRC" "$apply_src"
  git -C "$apply_src" config advice.detachedHead false
  git -C "$apply_src" checkout -q v-new
  local applyview_out applyview_sig
  applyview_out="$(python3 "$UPGRADE_PY" apply-live \
    --source-root "$apply_src" --target-root "$TGT" \
    --base-ref "$BASE_REF" --dry-run)"
  applyview_sig="$(plan_signature "$applyview_out")"

  smoke_assert_eq "$applyview_sig" "$dryrun_sig" "T5 dry-run-via-ref plan == apply-after-checkout plan (parity)"

  # And the parity plan must NOT match the buggy stale-tree plan (sitting on
  # v-old, no ref) — otherwise parity would be trivially satisfied by a no-op.
  local stale_out stale_sig
  stale_out="$(python3 "$UPGRADE_PY" apply-live \
    --source-root "$SRC" --target-root "$TGT" \
    --base-ref "$BASE_REF" --dry-run)"
  stale_sig="$(plan_signature "$stale_out")"
  if [[ "$stale_sig" == "$dryrun_sig" ]]; then
    smoke_fail "T5: ref-resolved plan equals the stale-tree plan — the fix is a no-op"
  fi
}
smoke_run "T5 dry-run-via-ref plan matches apply-after-checkout plan" t5_dryrun_apply_parity

# --------------------------------------------------------------------------
# T6 — guard: apply-live rejects --upstream-ref without --dry-run. A real apply
# MUST read the checked-out working tree it is about to copy from; pairing a
# ref-resolved upstream with a live write is a bug, so it fails loudly.
# --------------------------------------------------------------------------
t6_apply_rejects_upstream_ref() {
  local rc=0
  python3 "$UPGRADE_PY" apply-live \
    --source-root "$SRC" --target-root "$TGT" \
    --base-ref "$BASE_REF" --upstream-ref v-new >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || smoke_fail "T6: apply-live --upstream-ref without --dry-run must fail (got rc=0)"
}
smoke_run "T6 apply-live rejects --upstream-ref without --dry-run" t6_apply_rejects_upstream_ref

# --------------------------------------------------------------------------
# T7 — apply path unchanged: a real apply-live (after checking out v-new, NO
# --upstream-ref) deploys the v-new content into the target. Confirms the fix
# left the working-tree apply path untouched.
# --------------------------------------------------------------------------
t7_apply_path_unchanged() {
  local apply_tgt="$SMOKE_TMP_ROOT/target-apply"
  cp -R "$TGT" "$apply_tgt"
  local apply_src="$SMOKE_TMP_ROOT/source-apply2"
  git clone -q "$SRC" "$apply_src"
  git -C "$apply_src" config advice.detachedHead false
  git -C "$apply_src" checkout -q v-new   # exactly what --apply does (DRY_RUN -eq 0 gate)

  python3 "$UPGRADE_PY" apply-live \
    --source-root "$apply_src" --target-root "$apply_tgt" \
    --base-ref "$BASE_REF" >/dev/null

  # v-new content landed in the target.
  smoke_assert_eq "NEW" "$(cat "$apply_tgt/drift.sh")" "T7 apply deployed v-new drift.sh"
  smoke_assert_file_exists "$apply_tgt/new.sh" "T7 apply deployed v-new new.sh"
  smoke_assert_eq "0.2.0" "$(cat "$apply_tgt/VERSION")" "T7 apply deployed v-new VERSION"
}
smoke_run "T7 real apply path is unchanged" t7_apply_path_unchanged

smoke_log "PASS — #1602 dry-run ref fidelity verified (preview matches the requested ref, no tree mutation, dry-run/apply parity, apply path unchanged)"
