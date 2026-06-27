#!/usr/bin/env bash
# scripts/smoke/lts-line-ancestry-self.sh — unit/self-test for
# scripts/ci/lts-line-ancestry-check.sh (Issue #19043).
#
# Builds throwaway git repos with a known tag + history shape and asserts the
# check script's two pieces of logic in isolation:
#   1. stable-tag SELECTOR — must pick the highest bare vX.Y.z and EXCLUDE
#      rc/beta tags; the line glob must not cross minor lines (0.17 != 0.16).
#   2. ANCESTRY assertion — a HEAD descending from the stable tag PASSES; a
#      sibling-history HEAD (simulated drift) FAILS non-zero with the documented
#      message; a line with no stable tag fails EXPLICITLY (never green-skip).
#
# Run:
#   bash scripts/smoke/lts-line-ancestry-self.sh
#
# CI: invoked by the lts-line-ancestry-check job (and runnable standalone).

set -euo pipefail

SMOKE_NAME="lts-line-ancestry-self"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
CHECK="$REPO_ROOT/scripts/ci/lts-line-ancestry-check.sh"

# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd git
smoke_make_temp_root "$SMOKE_NAME"

[[ -f "$CHECK" ]] || smoke_fail "check script missing: $CHECK"

# run_check <repo-dir> <args...> -> sets OUT (stdout+stderr) and RC (exit code)
OUT=""
RC=0
run_check() {
  local repo="$1"
  shift
  set +e
  OUT="$(cd "$repo" && bash "$CHECK" "$@" 2>&1)"
  RC=$?
  set -e
}

git_init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "smoke@example.test"
  git -C "$dir" config user.name "smoke"
  git -C "$dir" config commit.gpgsign false
}

# ---------------------------------------------------------------------------
# Fixture A — a line with stable + rc/beta tags and a legit vs drifted head.
#
#   A (v0.16.16, v0.16.17-rc1)
#   └─ B (v0.16.17, v0.16.18-beta1)
#      └─ C   legit backport on top of the tag head  -> descends from v0.16.17
#   A
#   └─ D   sibling history off the OLD base          -> does NOT descend
# ---------------------------------------------------------------------------
line_repo="$SMOKE_TMP_ROOT/line-repo"
git_init_repo "$line_repo"
(
  cd "$line_repo"
  echo a >f && git add -A && git commit -qm A
  A="$(git rev-parse HEAD)"
  git tag v0.16.16
  git tag v0.16.17-rc1
  echo b >f && git commit -qam B
  git tag v0.16.17
  git tag v0.16.18-beta1
  echo c >f && git commit -qam C        # legit backport, child of B
  git rev-parse HEAD >"$SMOKE_TMP_ROOT/C.sha"
  git checkout -q "$A"                   # detach at the old base
  echo d >g && git add -A && git commit -qm D
  git rev-parse HEAD >"$SMOKE_TMP_ROOT/D.sha"
)
C_SHA="$(cat "$SMOKE_TMP_ROOT/C.sha")"
D_SHA="$(cat "$SMOKE_TMP_ROOT/D.sha")"

# 1. Selector picks the highest BARE stable tag, not the rc/beta.
run_check "$line_repo" --print-stable-tag release/0.16-lts
smoke_assert_eq 0 "$RC" "selector exit code"
smoke_assert_eq "v0.16.17" "$OUT" "selector picks highest bare stable tag (rc/beta excluded)"
smoke_log "selector: release/0.16-lts -> $OUT (rc1/beta1 excluded) [PASS]"

# 1b. A full refs/heads/ ref is tolerated and derives the same line.
run_check "$line_repo" --print-stable-tag refs/heads/release/0.16-lts
smoke_assert_eq "v0.16.17" "$OUT" "selector tolerates a full refs/heads/ ref"
smoke_log "selector: refs/heads/release/0.16-lts -> $OUT [PASS]"

# 1c. Line glob does NOT cross minor lines — a 0.17 line sees no v0.16.* tag.
run_check "$line_repo" --print-stable-tag release/0.17-lts
[[ "$RC" -ne 0 ]] || smoke_fail "0.17 line must not match v0.16.* tags (got rc=$RC, out='$OUT')"
smoke_assert_contains "$OUT" "no stable vX.Y.Z tag found for the v0.17 line" "0.17 line glob isolation"
smoke_log "selector: release/0.17-lts -> explicit non-zero (no v0.17 tag; v0.16.* not cross-matched) [PASS]"

# 2. Ancestry PASS — HEAD (C) descends from the stable tag (v0.16.17 = B).
run_check "$line_repo" release/0.16-lts "$C_SHA"
smoke_assert_eq 0 "$RC" "ancestry PASS exit code"
smoke_assert_contains "$OUT" "descends from v0.16.17" "ancestry PASS message"
smoke_log "ancestry: legit backport head descends from v0.16.17 -> rc=0 [PASS]"

# 3. Ancestry FAIL — sibling-history HEAD (D, off the old base) is drift.
run_check "$line_repo" release/0.16-lts "$D_SHA"
smoke_assert_eq 1 "$RC" "ancestry drift exit code"
smoke_assert_contains "$OUT" \
  "release/0.16-* HEAD has drifted from v0.16.17; reset-to-tag required" \
  "ancestry drift message"
smoke_log "ancestry: sibling-history head -> rc=1 drift message [PASS]"

# ---------------------------------------------------------------------------
# Fixture B — zero-tag repo. The gate must fail EXPLICITLY, not green-skip.
# ---------------------------------------------------------------------------
empty_repo="$SMOKE_TMP_ROOT/empty-repo"
git_init_repo "$empty_repo"
(
  cd "$empty_repo"
  echo x >f && git add -A && git commit -qm init
)
run_check "$empty_repo" release/0.16-lts
[[ "$RC" -ne 0 ]] || smoke_fail "zero-tag repo must fail explicitly (got rc=$RC)"
smoke_assert_contains "$OUT" "no stable vX.Y.Z tag found for the v0.16 line" "zero-tag explicit diagnostic"
smoke_assert_contains "$OUT" "refusing to pass" "zero-tag is non-green, not a silent skip"
smoke_log "empty-tag: zero stable tags -> explicit non-zero (no green-skip) [PASS]"

# ---------------------------------------------------------------------------
# Fixture C — rc/beta tags ONLY (no bare stable). Selection must be empty ->
# the rc/beta of a not-yet-released patch never counts as the stable base.
# ---------------------------------------------------------------------------
rc_only_repo="$SMOKE_TMP_ROOT/rc-only-repo"
git_init_repo "$rc_only_repo"
(
  cd "$rc_only_repo"
  echo x >f && git add -A && git commit -qm init
  git tag v0.16.17-rc1
  git tag v0.16.18-beta1
)
run_check "$rc_only_repo" --print-stable-tag release/0.16-lts
[[ "$RC" -ne 0 ]] || smoke_fail "rc/beta-only repo must not select a stable tag (got rc=$RC, out='$OUT')"
smoke_assert_contains "$OUT" "no stable vX.Y.Z tag found" "rc/beta-only selects no stable base"
smoke_log "rc-only: only rc/beta tags -> explicit non-zero (rc/beta != stable) [PASS]"

# ---------------------------------------------------------------------------
# Fixture D — malformed branch name -> branch-parse error, not a silent pass.
# ---------------------------------------------------------------------------
run_check "$line_repo" not-a-release-branch
[[ "$RC" -ne 0 ]] || smoke_fail "malformed branch must error (got rc=$RC)"
smoke_assert_contains "$OUT" "could not derive a vX.Y minor line" "malformed-branch diagnostic"
smoke_log "branch-parse: 'not-a-release-branch' -> explicit non-zero [PASS]"

smoke_log "ALL lts-line-ancestry self-tests passed"
