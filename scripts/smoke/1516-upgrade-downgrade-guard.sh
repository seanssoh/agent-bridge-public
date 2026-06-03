#!/usr/bin/env bash
# Issue #1516 — `upgrade --apply` must NOT silently downgrade a beta install.
#
# Root cause: the default `stable` channel resolves to the latest vX.Y.Z
# release tag and SKIPS pre-release/beta tags. On a pre-release install
# (e.g. 0.16.0-beta2) a bare `upgrade --apply` therefore resolved
# TARGET_VERSION to a LOWER stable version (e.g. 0.15.4) and applied it
# with no warning — silently reverting the install to stable and
# discarding the beta under test. Found in the v0.16.0-beta2 2-VM beta
# validation.
#
# Fix:
#   1. bridge-release.py gained a `compare` subcommand that prints the
#      full semver 2.0.0 ordering of two versions (-1/0/1), reusing the
#      same compare_semver the release-notification path uses so the two
#      never disagree. A pre-release of 0.16.0 sorts ABOVE 0.15.4 and
#      BELOW 0.16.0 final.
#   2. bridge-upgrade.sh gained a `bridge_upgrade_compare_versions` helper
#      (thin wrapper over `bridge-release.py compare`) and a downgrade
#      guard on the apply path: after the resolved TARGET_VERSION and the
#      INSTALLED_VERSION are both known, but BEFORE any checkout/merge
#      mutates the tree, it aborts (exit 64) when the install would move
#      BACKWARD — unless `--allow-downgrade` is passed.
#
# Coverage:
#   T1 — comparator edges (the teeth): `bridge-release.py compare`
#        returns 1 for 0.16.0-beta2 vs 0.15.4 (a downgrade), -1 for
#        0.16.0-beta2 vs 0.16.0 (forward), 1 for beta2 vs beta1, 0 for
#        equal, -1 for beta1 vs beta2 and beta2 vs beta10 (numeric
#        prerelease ordering), and exits non-zero (no stdout) for an
#        unparseable version.
#   T2 — the bridge_upgrade_compare_versions helper, extracted verbatim
#        from bridge-upgrade.sh and eval'd, returns the same ordering and
#        echoes nothing on an unparseable side.
#   T3 — the downgrade guard, extracted verbatim from bridge-upgrade.sh
#        and eval'd: current=0.16.0-beta2 + target=0.15.4 ABORTS with a
#        non-zero exit and a message naming both versions + the
#        --allow-downgrade remediation.
#   T4 — same scenario with ALLOW_DOWNGRADE=1 PROCEEDS (no abort).
#   T5 — forward upgrade (current=0.15.4 + target=0.16.0-beta2) PROCEEDS;
#        same-version (0.16.0-beta2 == 0.16.0-beta2) PROCEEDS; an
#        unparseable installed version PROCEEDS (a malformed VERSION file
#        must never block a legitimate forward upgrade); the `ref` channel
#        ALSO guards a deliberate backward --ref (authoritative pinned tag).
#   T6 — the moving-line channels `dev` and `current` SKIP the guard: at
#        the guard's location their TARGET_VERSION is the STALE PRE-pull
#        value (the real applied version is settled by a later
#        `git pull --ff-only`), so guarding on it would false-block a
#        legitimate forward dev/current --pull upgrade. Codex r1 catch.
#
# Footgun #11: no heredoc-fed subprocess (`bash -s`/`python3 -`) anywhere.
# The guard's own `cat >&2 <<EOF` (heredoc to cat, not to a subprocess)
# is extracted from the shipped code, not authored here. Runs entirely
# under an isolated $TMP; never touches operator state.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
UPGRADE_SH="$ROOT_DIR/bridge-upgrade.sh"
RELEASE_PY="$ROOT_DIR/bridge-release.py"

[[ -f "$UPGRADE_SH" ]] || { printf 'FAIL (bootstrap): missing %s\n' "$UPGRADE_SH" >&2; exit 2; }
[[ -f "$RELEASE_PY" ]] || { printf 'FAIL (bootstrap): missing %s\n' "$RELEASE_PY" >&2; exit 2; }

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP="$(mktemp -d -t agb-1516-upgrade-downgrade-guard.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Extract helper + guard from bridge-upgrade.sh by literal markers so the
# smoke binds to the shipped surface: deleting the guard or renaming the
# helper trips this test. `sed -n '/start/,/end/p'` is the standard bash
# range-extraction primitive — no temp pipe, no heredoc.
extract_block() {
  local start_pat="$1"
  local end_pat="$2"
  sed -n "/$start_pat/,/$end_pat/p" "$UPGRADE_SH"
}

HELPER_COMPARE="$(extract_block '^bridge_upgrade_compare_versions()' '^}$')"
GUARD_BLOCK="$(extract_block '^[[:space:]]*# Issue #1516: refuse a SILENT BACKWARD downgrade' '^[[:space:]]*# END: Issue #1516 downgrade guard')"

if [[ -z "$HELPER_COMPARE" ]]; then
  printf 'FAIL (bootstrap): could not extract bridge_upgrade_compare_versions — regression?\n' >&2
  exit 2
fi
if [[ -z "$GUARD_BLOCK" ]]; then
  printf 'FAIL (bootstrap): could not extract issue #1516 downgrade guard — regression?\n' >&2
  exit 2
fi

# Defining the helper via eval is the test seam — we want drift in the
# helper signature to fail the test, which only works with the real def.
eval "$HELPER_COMPARE"

# ---------------------------------------------------------------------------
# T1 — comparator edges via `bridge-release.py compare` (the teeth).
# ---------------------------------------------------------------------------
printf '== T1 — bridge-release.py compare semver edges ==\n'

cmp_case() {
  # $1=left $2=right $3=expected-stdout $4=expected-rc
  local left="$1" right="$2" exp_out="$3" exp_rc="$4" got_out got_rc
  got_out="$(python3 "$RELEASE_PY" compare "$left" "$right" 2>/dev/null)"
  got_rc=$?
  step "compare $left $right -> '$exp_out' (rc=$exp_rc)"
  if [[ "$got_out" == "$exp_out" && "$got_rc" -eq "$exp_rc" ]]; then
    ok
  else
    err "got '$got_out' (rc=$got_rc)"
  fi
}

cmp_case "0.16.0-beta2" "0.15.4"        "1"  0   # pre-release of 0.16.0 > prior stable (the downgrade case)
cmp_case "0.16.0-beta2" "0.16.0"        "-1" 0   # pre-release < same-line final (forward upgrade)
cmp_case "0.16.0-beta2" "0.16.0-beta1"  "1"  0   # same-line beta bump
cmp_case "0.16.0-beta2" "0.16.0-beta2"  "0"  0   # equal
cmp_case "0.16.0-beta1" "0.16.0-beta2"  "-1" 0   # beta1 < beta2
cmp_case "0.16.0-beta2" "0.16.0-beta10" "-1" 0   # numeric prerelease ordering (beta2 < beta10)
cmp_case "0.15.4"       "0.16.0-beta2"  "-1" 0   # prior stable < next pre-release (forward)
cmp_case "garbage"      "0.15.4"        ""   2   # unparseable installed -> unknown
cmp_case "0.15.4"       "garbage"       ""   2   # unparseable target -> unknown

# ---------------------------------------------------------------------------
# T2 — bridge_upgrade_compare_versions helper (extracted verbatim).
# ---------------------------------------------------------------------------
printf '== T2 — bridge_upgrade_compare_versions wrapper ==\n'

helper_case() {
  local left="$1" right="$2" exp="$3" got
  got="$(bridge_upgrade_compare_versions "$ROOT_DIR" "$left" "$right")"
  step "helper $left $right -> '$exp'"
  if [[ "$got" == "$exp" ]]; then ok; else err "got '$got'"; fi
}

helper_case "0.16.0-beta2" "0.15.4"       "1"
helper_case "0.16.0-beta2" "0.16.0"       "-1"
helper_case "0.16.0-beta2" "0.16.0-beta2" "0"
helper_case "garbage"      "0.15.4"       ""    # unparseable -> empty (proceed)

# ---------------------------------------------------------------------------
# T3 — the guard ABORTS on a backward move (default, no --allow-downgrade).
# ---------------------------------------------------------------------------
printf '== T3 — guard aborts a silent backward downgrade ==\n'

# Drive the literal guard block in a subshell so its `exit 64` is captured
# rather than terminating the smoke. SOURCE_ROOT points at the real repo
# so the helper resolves bridge-release.py.
run_guard() {
  # $1=installed $2=target $3=allow_downgrade $4=channel(default stable)
  # prints stderr to $TMP/guard.err
  (
    SOURCE_ROOT="$ROOT_DIR"
    INSTALLED_VERSION="$1"
    TARGET_VERSION="$2"
    ALLOW_DOWNGRADE="$3"
    CHANNEL="${4:-stable}"
    eval "$HELPER_COMPARE"
    eval "$GUARD_BLOCK"
  ) 2>"$TMP/guard.err"
}

step "guard exits 64 when installed=0.16.0-beta2 target=0.15.4 (no --allow-downgrade)"
run_guard "0.16.0-beta2" "0.15.4" "0" "stable"
_rc=$?
if [[ "$_rc" -eq 64 ]]; then ok; else err "expected exit 64, got $_rc"; fi

step "guard message names both versions + the --allow-downgrade remediation"
_msg="$(cat "$TMP/guard.err")"
case "$_msg" in
  *"0.16.0-beta2"*"0.15.4"*)
    case "$_msg" in
      *"--allow-downgrade"*"--ref"*) ok ;;
      *"--ref"*"--allow-downgrade"*) ok ;;
      *) err "message missing remediation flags: $_msg" ;;
    esac
    ;;
  *) err "message missing one/both versions: $_msg" ;;
esac

# ---------------------------------------------------------------------------
# T4 — --allow-downgrade lets the backward move PROCEED.
# ---------------------------------------------------------------------------
printf '== T4 — --allow-downgrade overrides the guard ==\n'

step "guard PROCEEDS (rc 0) for the same backward move when ALLOW_DOWNGRADE=1"
run_guard "0.16.0-beta2" "0.15.4" "1" "stable"
_rc=$?
if [[ "$_rc" -eq 0 ]]; then ok; else err "expected exit 0 (proceed), got $_rc"; fi

# ---------------------------------------------------------------------------
# T5 — forward / same-version / unparseable all PROCEED unchanged.
# ---------------------------------------------------------------------------
printf '== T5 — forward + same-version + unparseable proceed ==\n'

step "forward upgrade (0.15.4 -> 0.16.0-beta2) PROCEEDS"
run_guard "0.15.4" "0.16.0-beta2" "0" "stable"
_rc=$?
if [[ "$_rc" -eq 0 ]]; then ok; else err "forward upgrade was blocked (rc=$_rc)"; fi

step "same-version no-op (0.16.0-beta2 == 0.16.0-beta2) PROCEEDS"
run_guard "0.16.0-beta2" "0.16.0-beta2" "0" "stable"
_rc=$?
if [[ "$_rc" -eq 0 ]]; then ok; else err "same-version was blocked (rc=$_rc)"; fi

step "unparseable installed version PROCEEDS (malformed VERSION must not block forward)"
run_guard "garbage" "0.16.0" "0" "stable"
_rc=$?
if [[ "$_rc" -eq 0 ]]; then ok; else err "unparseable installed was blocked (rc=$_rc)"; fi

step "ref channel ALSO guards a deliberate backward --ref (authoritative pinned tag)"
run_guard "0.16.0-beta2" "0.15.4" "0" "ref"
_rc=$?
if [[ "$_rc" -eq 64 ]]; then ok; else err "ref-channel backward move not guarded (rc=$_rc)"; fi

# ---------------------------------------------------------------------------
# T6 — moving-line channels (dev/current) SKIP the guard: their
# TARGET_VERSION here is the stale PRE-pull value, and the actual applied
# version is settled by a later `git pull --ff-only`. Guarding on the
# pre-pull value would false-block a legitimate forward dev/current --pull
# upgrade (local main behind origin/main). Codex r1 catch.
# ---------------------------------------------------------------------------
printf '== T6 — dev/current channels skip the guard (pre-pull version) ==\n'

step "dev channel PROCEEDS even when pre-pull version looks like a backward move"
run_guard "0.16.0-beta2" "0.15.0-beta5-2" "0" "dev"
_rc=$?
if [[ "$_rc" -eq 0 ]]; then ok; else err "dev channel was wrongly blocked on pre-pull version (rc=$_rc)"; fi

step "current channel PROCEEDS even when pre-pull working-tree version looks backward"
run_guard "0.16.0-beta2" "0.15.0-beta5-2" "0" "current"
_rc=$?
if [[ "$_rc" -eq 0 ]]; then ok; else err "current channel was wrongly blocked on pre-pull version (rc=$_rc)"; fi

# ---------------------------------------------------------------------------
printf '\n== 1516-upgrade-downgrade-guard: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
