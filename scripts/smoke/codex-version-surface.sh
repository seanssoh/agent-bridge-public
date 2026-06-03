#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/codex-version-surface.sh — #8945 Track D: bridge-upgrade.sh
# Codex CLI version surface.
#
# Pins the bridge_upgrade_emit_codex_version_advisory contract:
#   T1: codex ABSENT          -> silent no-op, exit 0, no state file written.
#   T2: first observation     -> record version, NO advisory (no baseline).
#   T3: same MAJOR.MINOR (patch bump only) -> NO advisory, baseline updated.
#   T4: MAJOR/MINOR change     -> advisory printed to stderr, baseline updated.
#   T5: BRIDGE_CODEX_VERSION_ADVISORY=0 -> hard suppressed (no advisory).
#   T6: --dry-run              -> plan line only, no state mutation.
#
# Test seam: extract the function body verbatim from bridge-upgrade.sh by
# literal markers and eval it in this shell (the 1144-upgrade-complete-task
# pattern) so the smoke binds to the shipped code and fails on signature
# drift. A fake `codex` on PATH makes `codex --version` deterministic and
# hermetic — CI never needs a real codex install.
#
# Footgun #11 / lint-heredoc-ban: extraction is `sed -n '/start/,/end/p'`
# (no heredoc-stdin), the fake codex stub is written via printf, and the
# advisory text the function emits is a `cat >&2 <<` fd-redirect (not a
# subprocess interpreter site).

set -uo pipefail

SMOKE_NAME="codex-version-surface"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

UPGRADE_SH="$SMOKE_REPO_ROOT/bridge-upgrade.sh"
smoke_assert_file_exists "$UPGRADE_SH" "bridge-upgrade.sh must exist"

# --- Extract the function body verbatim (test seam) ----------------------
extract_block() {
  local start_pat="$1"
  local end_pat="$2"
  sed -n "/$start_pat/,/$end_pat/p" "$UPGRADE_SH"
}

FN_BODY="$(extract_block '^bridge_upgrade_emit_codex_version_advisory()' '^}$')"
if [[ -z "$FN_BODY" ]]; then
  smoke_fail "bootstrap: could not extract bridge_upgrade_emit_codex_version_advisory from bridge-upgrade.sh"
fi
# Define the real function verbatim — drift in its signature/body fails here.
eval "$FN_BODY"
declare -F bridge_upgrade_emit_codex_version_advisory >/dev/null 2>&1 \
  || smoke_fail "bootstrap: function did not define after eval"

# --- Fake codex stub on PATH --------------------------------------------
# A printf-authored executable so `codex --version` is deterministic. The
# version it reports is read from $FAKE_CODEX_VERSION_FILE at call time so a
# single stub serves every case.
FAKE_BIN_DIR="$SMOKE_TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN_DIR"
FAKE_CODEX_VERSION_FILE="$SMOKE_TMP_ROOT/fake-codex-version.txt"
FAKE_CODEX_RC_FILE="$SMOKE_TMP_ROOT/fake-codex-rc.txt"
FAKE_CODEX="$FAKE_BIN_DIR/codex"
# The stub prints $FAKE_CODEX_VERSION_FILE for `codex --version` and exits
# with the code in $FAKE_CODEX_RC_FILE (default 0). The configurable exit
# code is the errexit-regression seam: a `codex --version` that exits
# nonzero must NOT abort the upgrade (the function runs under set -e).
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "_rc=\"\$(cat \"$FAKE_CODEX_RC_FILE\" 2>/dev/null || printf 0)\""
  printf '%s\n' 'if [[ "${1:-}" == "--version" ]]; then'
  printf '%s\n' "  cat \"$FAKE_CODEX_VERSION_FILE\" 2>/dev/null || true"
  printf '%s\n' '  exit "${_rc:-0}"'
  printf '%s\n' 'fi'
  printf '%s\n' 'exit 0'
} >"$FAKE_CODEX"
chmod +x "$FAKE_CODEX"

set_fake_codex_version() {
  printf '%s\n' "$1" >"$FAKE_CODEX_VERSION_FILE"
  printf '%s\n' "0" >"$FAKE_CODEX_RC_FILE"
}

# Configure the stub to print $1 (may be empty) and exit with code $2.
set_fake_codex_version_rc() {
  printf '%s\n' "$1" >"$FAKE_CODEX_VERSION_FILE"
  printf '%s\n' "$2" >"$FAKE_CODEX_RC_FILE"
}

STATE_REL="state/upgrade/codex-version.last"

new_target() {
  local t="$SMOKE_TMP_ROOT/$1"
  mkdir -p "$t/state/upgrade"
  printf '%s' "$t"
}

# --- T1 — codex ABSENT -> silent no-op, no state file --------------------
# Run the eval'd function with a PATH that resolves no `codex`. We point
# PATH at an empty dir so `command -v codex` fails inside the function.
smoke_log "T1: codex absent -> silent no-op, exit 0, no state written"
T1_TARGET="$(new_target t1)"
EMPTY_BIN_DIR="$SMOKE_TMP_ROOT/emptybin"
mkdir -p "$EMPTY_BIN_DIR"
T1_OUT=""
T1_RC=0
T1_OUT="$(PATH="$EMPTY_BIN_DIR" bridge_upgrade_emit_codex_version_advisory "$T1_TARGET" 0 2>&1)" || T1_RC=$?
[[ $T1_RC -eq 0 ]] || smoke_fail "T1: expected rc=0 with codex absent, got $T1_RC ($T1_OUT)"
[[ ! -f "$T1_TARGET/$STATE_REL" ]] || smoke_fail "T1: state file must NOT be written when codex is absent"
smoke_assert_not_contains "$T1_OUT" "ADVISORY" "T1: no advisory when codex absent"

# --- T2 — first observation -> record, NO advisory -----------------------
smoke_log "T2: first observation -> record version, no advisory"
T2_TARGET="$(new_target t2)"
set_fake_codex_version "codex-cli 0.135.0"
T2_OUT=""
T2_OUT="$(PATH="$FAKE_BIN_DIR:$PATH" bridge_upgrade_emit_codex_version_advisory "$T2_TARGET" 0 2>&1)"
smoke_assert_not_contains "$T2_OUT" "ADVISORY" "T2: first observation must not advise (no baseline)"
smoke_assert_file_exists "$T2_TARGET/$STATE_REL" "T2: version recorded on first observation"
T2_RECORDED="$(cat "$T2_TARGET/$STATE_REL")"
smoke_assert_eq "codex-cli 0.135.0" "$T2_RECORDED" "T2: recorded raw version line"

# --- T3 — same MAJOR.MINOR (patch bump) -> NO advisory -------------------
smoke_log "T3: same major.minor (0.135.0 -> 0.135.2) -> no advisory, baseline updated"
T3_TARGET="$(new_target t3)"
printf '%s\n' "codex-cli 0.135.0" >"$T3_TARGET/$STATE_REL"
set_fake_codex_version "codex-cli 0.135.2"
T3_OUT=""
T3_OUT="$(PATH="$FAKE_BIN_DIR:$PATH" bridge_upgrade_emit_codex_version_advisory "$T3_TARGET" 0 2>&1)"
smoke_assert_not_contains "$T3_OUT" "ADVISORY" "T3: a patch-only bump must not advise"
smoke_assert_eq "codex-cli 0.135.2" "$(cat "$T3_TARGET/$STATE_REL")" "T3: baseline updated to patch version"

# --- T4 — MAJOR/MINOR change -> advisory, baseline updated ---------------
smoke_log "T4: minor change (0.135.0 -> 0.136.0) -> advisory printed, baseline updated"
T4_TARGET="$(new_target t4)"
printf '%s\n' "codex-cli 0.135.0" >"$T4_TARGET/$STATE_REL"
set_fake_codex_version "codex-cli 0.136.0"
T4_OUT=""
T4_OUT="$(PATH="$FAKE_BIN_DIR:$PATH" bridge_upgrade_emit_codex_version_advisory "$T4_TARGET" 0 2>&1)"
smoke_assert_contains "$T4_OUT" "ADVISORY" "T4: a minor change must surface the advisory"
smoke_assert_contains "$T4_OUT" "0.135.0 -> 0.136.0" "T4: advisory names the version transition"
smoke_assert_contains "$T4_OUT" "codex doctor" "T4: advisory recommends 'codex doctor'"
smoke_assert_eq "codex-cli 0.136.0" "$(cat "$T4_TARGET/$STATE_REL")" "T4: baseline updated after advisory"

# T4b — major change (0.136.0 -> 1.0.0) also advises.
T4B_TARGET="$(new_target t4b)"
printf '%s\n' "codex-cli 0.136.0" >"$T4B_TARGET/$STATE_REL"
set_fake_codex_version "codex-cli 1.0.0"
T4B_OUT=""
T4B_OUT="$(PATH="$FAKE_BIN_DIR:$PATH" bridge_upgrade_emit_codex_version_advisory "$T4B_TARGET" 0 2>&1)"
smoke_assert_contains "$T4B_OUT" "ADVISORY" "T4b: a major change must surface the advisory"

# --- T5 — BRIDGE_CODEX_VERSION_ADVISORY=0 hard suppress ------------------
smoke_log "T5: BRIDGE_CODEX_VERSION_ADVISORY=0 hard-suppresses even on a minor change"
T5_TARGET="$(new_target t5)"
printf '%s\n' "codex-cli 0.135.0" >"$T5_TARGET/$STATE_REL"
set_fake_codex_version "codex-cli 0.136.0"
T5_OUT=""
T5_OUT="$(PATH="$FAKE_BIN_DIR:$PATH" BRIDGE_CODEX_VERSION_ADVISORY=0 bridge_upgrade_emit_codex_version_advisory "$T5_TARGET" 0 2>&1)"
smoke_assert_not_contains "$T5_OUT" "ADVISORY" "T5: =0 must suppress the advisory"

# --- T6 — dry-run -> plan line only, no state mutation ------------------
smoke_log "T6: --dry-run -> plan line, no state mutation"
T6_TARGET="$(new_target t6)"
set_fake_codex_version "codex-cli 0.136.0"
T6_OUT=""
T6_OUT="$(PATH="$FAKE_BIN_DIR:$PATH" bridge_upgrade_emit_codex_version_advisory "$T6_TARGET" 1 2>&1)"
smoke_assert_contains "$T6_OUT" "plan:" "T6: dry-run prints a plan line"
[[ ! -f "$T6_TARGET/$STATE_REL" ]] || smoke_fail "T6: dry-run must not write the state file"

# --- T7 / T8 — errexit safety (codex internal-review r1) -----------------
# bridge-upgrade.sh runs under `set -euo pipefail`. A `codex --version`
# that exits nonzero, or output with no parseable version, must be
# "unknown and skipped" — NOT an upgrade-aborting errexit trip. The
# earlier cases above ran the function in this smoke's own shell (no
# set -e); these two re-run the eval'd function under an EXPLICIT
# `set -euo pipefail` so a regression that drops a `|| var=""` guard
# fails CI here.
#
# Driver as a temp FILE (no procsub / here-string into a shell — H3),
# invoked as `bash <driver>`. It evals the verbatim function body, turns
# on errexit, runs the function, and prints a sentinel only if the call
# returned without aborting.
ERREXIT_DRIVER="$SMOKE_TMP_ROOT/errexit-driver.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  # Body of the real function (verbatim — same drift seam).
  printf '%s\n' "$FN_BODY"
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'bridge_upgrade_emit_codex_version_advisory "$1" 0'
  printf '%s\n' 'printf "ERREXIT_SURVIVED\\n"'
} >"$ERREXIT_DRIVER"

# T7: codex --version exits nonzero (e.g. 42) but still prints a banner.
smoke_log "T7: codex --version nonzero exit must not abort the upgrade (errexit)"
T7_TARGET="$(new_target t7)"
set_fake_codex_version_rc "codex-cli 0.135.0" "42"
T7_OUT=""
T7_RC=0
T7_OUT="$(PATH="$FAKE_BIN_DIR:$PATH" bash "$ERREXIT_DRIVER" "$T7_TARGET" 2>&1)" || T7_RC=$?
[[ $T7_RC -eq 0 ]] || smoke_fail "T7: function aborted under errexit (rc=$T7_RC) when codex --version exited nonzero. output: $T7_OUT"
smoke_assert_contains "$T7_OUT" "ERREXIT_SURVIVED" "T7: function returned 0 under errexit despite codex --version nonzero"

# T8: codex --version prints unparseable output (no dotted version).
smoke_log "T8: unparseable codex --version output must not abort the upgrade (errexit)"
T8_TARGET="$(new_target t8)"
set_fake_codex_version_rc "codex: command unavailable in this build" "0"
T8_OUT=""
T8_RC=0
T8_OUT="$(PATH="$FAKE_BIN_DIR:$PATH" bash "$ERREXIT_DRIVER" "$T8_TARGET" 2>&1)" || T8_RC=$?
[[ $T8_RC -eq 0 ]] || smoke_fail "T8: function aborted under errexit (rc=$T8_RC) on unparseable version. output: $T8_OUT"
smoke_assert_contains "$T8_OUT" "ERREXIT_SURVIVED" "T8: function returned 0 under errexit on unparseable version output"

smoke_log "PASS"
