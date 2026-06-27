#!/usr/bin/env bash
# scripts/ci/lts-line-ancestry-check.sh — CI gate for the LTS-line ancestry
# invariant (Issue #19043, patch-approved #19116).
#
# Recurrence-prevention for the LTS-line drift class: a wholesale force-push
# once reset release/0.16-lts onto a 48-commit parallel cherry-pick line
# instead of fast-forwarding the 13 real backports onto the latest stable tag.
#
# Invariant (docs/release-lines.md §"LTS line ancestry invariant"):
#   the HEAD of a release/<minor>-* maintenance branch MUST remain a
#   fast-forward descendant of the latest STABLE vX.Y.z tag on its minor line.
#   Backports are cherry-picked ONTO that tag-based head; the branch never
#   accumulates a parallel history.
#
# Usage:
#   lts-line-ancestry-check.sh <branch-ref> [<head-ref>]
#   lts-line-ancestry-check.sh --print-stable-tag <branch-ref>
#
#   <branch-ref>  the maintenance branch name (e.g. release/0.16-lts); a full
#                 refs/heads/... ref is tolerated. The minor line is derived
#                 from the branch NAME (release/0.16-lts -> 0.16), structured
#                 so a future release/0.17-lts derives 0.17 with no code change.
#   <head-ref>    the commit to validate (default: HEAD). In CI pass the PR
#                 head / pushed sha so a PR's merge ref is not what gets checked.
#
#   --print-stable-tag  selection-only mode: print the latest stable tag for the
#                 line and exit (used by the self-test to verify selection in
#                 isolation). Still fails non-zero when no stable tag exists.
#
# Exit status:
#   0  HEAD descends from the latest stable tag (invariant holds), or the tag
#      was printed in --print-stable-tag mode.
#   1  drift detected, OR no stable tag exists for the line (see policy below),
#      OR a usage / branch-parse error.
#
# EMPTY-TAG POLICY (explicit, NOT a silent skip): when zero bare vX.Y.z tags
# exist for the line, the script exits NON-ZERO with a diagnostic. A line with
# no stable tag has no ancestry to assert, and green-by-skip would defeat the
# gate the first time the selector regressed to empty. The only supported way
# to make this green is to cut the line's first stable tag.

set -euo pipefail

mode="check"
if [[ "${1:-}" == "--print-stable-tag" ]]; then
  mode="print-stable-tag"
  shift
fi

branch_ref="${1:-}"
head_ref="${2:-HEAD}"

if [[ -z "$branch_ref" ]]; then
  printf 'lts-ancestry: usage: %s [--print-stable-tag] <branch-ref> [<head-ref>]\n' "${0##*/}" >&2
  exit 1
fi

# Derive the minor line from the branch name. Tolerate a full refs/heads/ ref.
#   refs/heads/release/0.16-lts -> release/0.16-lts -> 0.16-lts -> 0.16
branch="${branch_ref#refs/heads/}"
line="${branch#release/}"
minor="${line%%-*}"

if [[ ! "$minor" =~ ^[0-9]+\.[0-9]+$ ]]; then
  printf 'lts-ancestry: could not derive a vX.Y minor line from branch %q (parsed minor=%q); expected a release/<major>.<minor>-* branch.\n' \
    "$branch_ref" "$minor" >&2
  exit 1
fi

# Select the latest STABLE tag for the line.
#   * The git glob v<minor>.* anchors on the literal "v<minor>." prefix, so a
#     future 0.17 line (glob v0.17.*) can never match a v0.16.* tag.
#   * The grep then strips ANY pre-release / build suffix (-rc1, -beta1,
#     +build, ...) so only a bare vX.Y.Z survives — the rc/beta of a
#     not-yet-released higher patch must never be selected as the stable base.
#   * Descending version sort + head -1 yields the highest surviving bare tag.
latest_stable="$(
  git tag --list "v${minor}.*" --sort=-version:refname \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | head -1 || true
)"

if [[ -z "$latest_stable" ]]; then
  printf 'lts-ancestry: no stable vX.Y.Z tag found for the v%s line (rc/beta/build tags do not count).\n' "$minor" >&2
  printf 'lts-ancestry: refusing to pass — a maintenance line with no stable tag has no ancestry to assert (cut the first stable tag to establish the base).\n' >&2
  exit 1
fi

if [[ "$mode" == "print-stable-tag" ]]; then
  printf '%s\n' "$latest_stable"
  exit 0
fi

# Assert the HEAD descends from the latest stable tag. Right after a tag cut
# HEAD==tag, which is its own ancestor -> trivially passes (no bootstrap gap).
# Before a cut, the branch / PR head must descend from the prior stable tag.
set +e
git merge-base --is-ancestor "$latest_stable" "$head_ref"
rc=$?
set -e

case "$rc" in
  0)
    printf 'lts-ancestry: OK — %s descends from %s (v%s line invariant holds).\n' \
      "$head_ref" "$latest_stable" "$minor"
    ;;
  1)
    printf 'lts-ancestry: release/%s-* HEAD has drifted from %s; reset-to-tag required (docs/release-lines.md "LTS line ancestry invariant").\n' \
      "$minor" "$latest_stable" >&2
    exit 1
    ;;
  *)
    printf 'lts-ancestry: git merge-base --is-ancestor failed (rc=%s) comparing %s..%s — confirm the tag + HEAD are fetched (CI needs fetch-depth: 0).\n' \
      "$rc" "$latest_stable" "$head_ref" >&2
    exit "$rc"
    ;;
esac
