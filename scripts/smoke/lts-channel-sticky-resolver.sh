#!/usr/bin/env bash
# v0.16.3 Lane F — `lts` upgrade channel: version-line pin + sticky persistence.
#
# Feature: a bare `upgrade --apply` on the default `stable` channel resolves
# to the highest GLOBAL vX.Y.Z tag, so once v0.17.0 ships every install jumps
# off the v0.16 line. The new `lts` channel pins to the highest stable tag
# WITHIN a fixed major.minor series (read from the root tracked LTS_SERIES
# file) AND is sticky per-install (recorded in state/upgrade/channel) so the
# hold survives bare upgrades.
#
# Design source: the codex design-consensus in the Lane F brief.
#
# Coverage (the 6 required teeth):
#   T1 — resolver: bridge_upgrade_latest_lts_tag picks the highest v<series>.x
#        tag (v0.16.3) and SKIPS the higher global v0.17.0 and any pre-release
#        within the series (v0.16.4-beta1). Throwaway git repo + tag set — does
#        NOT depend on the real repo's tags.
#   T2 — resolver FAILS CLOSED (bridge_die) on a missing LTS_SERIES, a
#        malformed LTS_SERIES, and a series with no stable tag — never a silent
#        global-stable fallback.
#   T3 — precedence (default unchanged): no sticky file + tags v0.16.3/v0.17.0
#        → a bare apply/check resolves the global stable v0.17.0.
#   T4 — precedence (sticky lts): sticky file `lts` + same tags + LTS_SERIES
#        0.16 → a bare apply/check resolves v0.16.3, not v0.17.0.
#   T5 — sticky read/write helpers: write `lts` then read it back; an explicit
#        `--channel stable` rewrites the sticky to `stable`; --version/--ref are
#        one-shot and do NOT overwrite an existing `lts` sticky (the
#        CHANNEL_FLAG_EXPLICIT-gated write path is exercised); an INVALID sticky
#        file FAILS CLOSED (non-zero rc + remediation, no stable fallback).
#   T6 — `lts` participates in the issue #1516 downgrade guard (a backward move
#        to the held LTS tag from a newer line ABORTS unless --allow-downgrade).
#
# Footgun #11: no heredoc-fed subprocess. The resolver's own `python3 -c '...'`
# (a -c string, not a heredoc on stdin) is extracted verbatim from the shipped
# code, not authored here. Runs entirely under an isolated $TMP; never touches
# operator state.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
UPGRADE_SH="$ROOT_DIR/bridge-upgrade.sh"

[[ -f "$UPGRADE_SH" ]] || { printf 'FAIL (bootstrap): missing %s\n' "$UPGRADE_SH" >&2; exit 2; }

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

command -v git >/dev/null 2>&1 || { printf 'SKIP (bootstrap): git not on PATH\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'SKIP (bootstrap): python3 not on PATH\n' >&2; exit 0; }

TMP="$(mktemp -d -t agb-lts-channel.XXXXXX)" || { printf 'SKIP (bootstrap): mktemp -d failed (sandboxed read-only fs?)\n' >&2; exit 0; }
[[ -n "$TMP" && -d "$TMP" ]] || { printf 'FAIL (bootstrap): TMP not a directory\n' >&2; exit 2; }
# chmod -R u+rwX before rm so the T8 0400/0500 fixtures (if an early exit lands
# between the chmod-deny and the restore) cannot leave an undeletable tree.
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

# A stub bridge_die so the eval'd resolver/helper functions terminate the
# *subshell* with exit 1 (matching the shipped semantics: bridge_die prints to
# stderr and exits non-zero) without dragging in lib/bridge-core.sh.
DIE_STUB='bridge_die() { echo "[die] $*" >&2; exit 1; }'

# Extract a shipped function/block by literal markers so the smoke binds to the
# real surface — renaming the resolver or deleting the guard trips this test.
extract_block() {
  local start_pat="$1" end_pat="$2"
  sed -n "/$start_pat/,/$end_pat/p" "$UPGRADE_SH"
}

LTS_RESOLVER="$(extract_block '^bridge_upgrade_latest_lts_tag()' '^}$')"
STICKY_READ="$(extract_block '^bridge_upgrade_read_sticky_channel()' '^}$')"
STICKY_WRITE="$(extract_block '^bridge_upgrade_write_sticky_channel()' '^}$')"
STABLE_RESOLVER="$(extract_block '^bridge_upgrade_latest_stable_tag()' '^}$')"
PRECEDENCE_BLOCK="$(extract_block '^# v0.16.3 Lane F: sticky-channel precedence' '^# END: v0.16.3 Lane F sticky-channel precedence')"
COMPARE_HELPER="$(extract_block '^bridge_upgrade_compare_versions()' '^}$')"
GUARD_BLOCK="$(extract_block '^[[:space:]]*# Issue #1516: refuse a SILENT BACKWARD downgrade' '^[[:space:]]*# END: Issue #1516 downgrade guard')"
# The contiguous --channel/--version/--ref parser arms (bound to the shipped
# case dispatch). Extract from `--channel)` through the sentinel
# `--restart-daemon)` and drop that trailing sentinel line so we are left with
# exactly the three target-selector arms.
PARSER_ARMS="$(extract_block '^    --channel)' '^    --restart-daemon)' | sed '$d')"

for _name in LTS_RESOLVER STICKY_READ STICKY_WRITE STABLE_RESOLVER PRECEDENCE_BLOCK COMPARE_HELPER GUARD_BLOCK PARSER_ARMS; do
  if [[ -z "${!_name}" ]]; then
    printf 'FAIL (bootstrap): could not extract %s from bridge-upgrade.sh — regression?\n' "$_name" >&2
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# Throwaway "source checkout": a git repo with a tag set + an LTS_SERIES file.
# Built once; T2's failure cases use sibling repos with deliberately broken
# LTS_SERIES files.
# ---------------------------------------------------------------------------
mk_repo_with_tags() {
  # $1=repo-dir  $2=LTS_SERIES content ("" = no file)  rest=tags to create
  local repo="$1" series="$2"; shift 2
  mkdir -p "$repo"
  git -c init.defaultBranch=main -C "$repo" init -q
  git -C "$repo" config user.email smoke@example.com
  git -C "$repo" config user.name "lts smoke"
  printf 'seed\n' >"$repo/VERSION"
  [[ -n "$series" ]] && printf '%s\n' "$series" >"$repo/LTS_SERIES"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m seed
  local t
  for t in "$@"; do
    git -C "$repo" tag "$t"
  done
}

SRC="$TMP/src"
# Series 0.16; v0.16.3 is the highest STABLE in-series, v0.16.4-beta1 must be
# skipped, v0.17.0 is a higher global stable that lts must NOT pick.
mk_repo_with_tags "$SRC" "0.16" \
  v0.15.4 v0.16.0 v0.16.1 v0.16.2 v0.16.3 v0.16.4-beta1 v0.17.0

# ---------------------------------------------------------------------------
# T1 — resolver picks the highest in-series stable tag, skipping global stable
# and in-series pre-release.
# ---------------------------------------------------------------------------
printf '== T1 — bridge_upgrade_latest_lts_tag resolves the in-series stable tag ==\n'

run_lts_resolver() {
  # $1=source-root  -> prints resolved tag on stdout (subshell so bridge_die exit
  # is captured rather than killing the smoke)
  ( eval "$DIE_STUB"; eval "$LTS_RESOLVER"; bridge_upgrade_latest_lts_tag "$1" )
}

step "lts resolver returns v0.16.3 (highest v0.16.x stable), not v0.17.0 / v0.16.4-beta1"
got="$(run_lts_resolver "$SRC" 2>"$TMP/t1.err")"; rc=$?
if [[ $rc -eq 0 && "$got" == "v0.16.3" ]]; then ok; else err "got '$got' (rc=$rc) err=$(cat "$TMP/t1.err")"; fi

# Cross-check: the global stable resolver picks v0.17.0 on the SAME repo, proving
# lts and stable diverge.
step "stable resolver on the same repo returns v0.17.0 (lts and stable diverge)"
got="$( ( eval "$DIE_STUB"; eval "$STABLE_RESOLVER"; bridge_upgrade_latest_stable_tag "$SRC" ) 2>/dev/null )"
if [[ "$got" == "v0.17.0" ]]; then ok; else err "got '$got'"; fi

# ---------------------------------------------------------------------------
# T2 — resolver FAILS CLOSED (never a silent global-stable fallback).
# ---------------------------------------------------------------------------
printf '== T2 — lts resolver fails closed on bad LTS_SERIES / empty series ==\n'

# Missing LTS_SERIES file.
SRC_NOFILE="$TMP/src-nofile"
mk_repo_with_tags "$SRC_NOFILE" "" v0.16.1 v0.17.0
step "missing LTS_SERIES -> non-zero rc, no fallback to v0.17.0"
got="$(run_lts_resolver "$SRC_NOFILE" 2>"$TMP/t2a.err")"; rc=$?
if [[ $rc -ne 0 && -z "$got" ]] && grep -q 'LTS_SERIES' "$TMP/t2a.err"; then ok; else err "rc=$rc got='$got' err=$(cat "$TMP/t2a.err")"; fi

# Malformed LTS_SERIES (not major.minor).
SRC_BAD="$TMP/src-bad"
mk_repo_with_tags "$SRC_BAD" "garbage" v0.16.1 v0.17.0
step "malformed LTS_SERIES -> non-zero rc + 'major.minor' remediation"
got="$(run_lts_resolver "$SRC_BAD" 2>"$TMP/t2b.err")"; rc=$?
if [[ $rc -ne 0 && -z "$got" ]] && grep -q 'major.minor' "$TMP/t2b.err"; then ok; else err "rc=$rc got='$got' err=$(cat "$TMP/t2b.err")"; fi

# Valid series but NO stable tag in that series (only a higher global stable +
# an in-series pre-release that must be skipped).
SRC_EMPTY="$TMP/src-emptyseries"
mk_repo_with_tags "$SRC_EMPTY" "0.16" v0.16.0-beta1 v0.17.0
step "series with no in-series stable tag -> non-zero rc, does NOT pick v0.17.0"
got="$(run_lts_resolver "$SRC_EMPTY" 2>"$TMP/t2c.err")"; rc=$?
if [[ $rc -ne 0 && -z "$got" ]]; then ok; else err "rc=$rc got='$got' (must fail closed) err=$(cat "$TMP/t2c.err")"; fi

# ---------------------------------------------------------------------------
# Precedence harness — drive the extracted precedence block + per-channel
# resolution against a throwaway TARGET_ROOT (the install) + SRC (the source).
# ---------------------------------------------------------------------------
# Replicates the shipped resolution order around the extracted block: set the
# invocation flags, run the precedence block (which may consult the sticky
# file), then resolve TARGET_REF the way the per-channel `case` does for the
# resolved CHANNEL. Returns "<channel>|<target_ref>".
resolve_bare() {
  # $1=target-root  -> echoes "CHANNEL|TARGET_REF"
  #
  # Runs under `set -euo pipefail` to faithfully replicate the shipped
  # bridge-upgrade.sh environment: the precedence block does
  # `_sticky_channel="$(bridge_upgrade_read_sticky_channel ...)"`, and the
  # fail-closed on an invalid sticky relies on `set -e` aborting the parent
  # when that command substitution exits non-zero (a non-set-e shell would
  # silently swallow the exit and fall through to stable — exactly the
  # regression this tooth guards against).
  (
    set -euo pipefail
    eval "$DIE_STUB"
    eval "$LTS_RESOLVER"
    eval "$STABLE_RESOLVER"
    eval "$STICKY_READ"
    SUBCOMMAND="apply"
    CHANNEL_EXPLICIT=0
    SOURCE_EXPLICIT=0
    CHANNEL="stable"          # legacy default before sticky resolution
    TARGET_ROOT="$1"
    SOURCE_ROOT="$SRC"
    eval "$PRECEDENCE_BLOCK"
    case "$CHANNEL" in
      lts)    TARGET_REF="$(bridge_upgrade_latest_lts_tag "$SOURCE_ROOT")" ;;
      stable) TARGET_REF="$(bridge_upgrade_latest_stable_tag "$SOURCE_ROOT")" ;;
      *)      TARGET_REF="" ;;
    esac
    printf '%s|%s' "$CHANNEL" "$TARGET_REF"
  )
}

# T3 — no sticky file -> default unchanged (stable -> v0.17.0).
printf '== T3 — no sticky file: bare run stays stable (v0.17.0) ==\n'
TGT_NONE="$TMP/install-nosticky"
mkdir -p "$TGT_NONE/state/upgrade"
step "no state/upgrade/channel -> CHANNEL=stable, TARGET_REF=v0.17.0"
got="$(resolve_bare "$TGT_NONE" 2>"$TMP/t3.err")"; rc=$?
if [[ $rc -eq 0 && "$got" == "stable|v0.17.0" ]]; then ok; else err "got '$got' (rc=$rc) err=$(cat "$TMP/t3.err")"; fi

# T4 — sticky file 'lts' -> bare run resolves the held v0.16.3.
printf '== T4 — sticky lts: bare run holds the LTS line (v0.16.3) ==\n'
TGT_LTS="$TMP/install-lts"
mkdir -p "$TGT_LTS/state/upgrade"
printf 'lts\n' >"$TGT_LTS/state/upgrade/channel"
step "sticky 'lts' -> CHANNEL=lts, TARGET_REF=v0.16.3 (NOT v0.17.0)"
got="$(resolve_bare "$TGT_LTS" 2>"$TMP/t4.err")"; rc=$?
if [[ $rc -eq 0 && "$got" == "lts|v0.16.3" ]]; then ok; else err "got '$got' (rc=$rc) err=$(cat "$TMP/t4.err")"; fi

# ---------------------------------------------------------------------------
# T5 — sticky read/write helpers + the CHANNEL_FLAG_EXPLICIT write gate +
# invalid-sticky fail-closed.
# ---------------------------------------------------------------------------
printf '== T5 — sticky read/write + write gate + invalid fail-closed ==\n'

# write then read round-trip
TGT_RW="$TMP/install-rw"
mkdir -p "$TGT_RW"
( eval "$DIE_STUB"; eval "$STICKY_WRITE"; bridge_upgrade_write_sticky_channel "$TGT_RW" "lts" )
step "write 'lts' then read returns 'lts'"
got="$( ( eval "$DIE_STUB"; eval "$STICKY_READ"; bridge_upgrade_read_sticky_channel "$TGT_RW" ) 2>/dev/null )"
if [[ "$got" == "lts" ]]; then ok; else err "got '$got'"; fi

# Simulate the apply-path write gate: explicit --channel stable rewrites the
# sticky; --ref / --version (CHANNEL_FLAG_EXPLICIT=0) must NOT.
apply_write_gate() {
  # $1=target  $2=channel-to-record  $3=CHANNEL_FLAG_EXPLICIT(0/1)
  (
    eval "$DIE_STUB"; eval "$STICKY_WRITE"
    CHANNEL="$2"; CHANNEL_FLAG_EXPLICIT="$3"; TARGET_ROOT="$1"
    # Mirror the shipped gate: write only when the literal --channel flag was set.
    if [[ $CHANNEL_FLAG_EXPLICIT -eq 1 ]]; then
      bridge_upgrade_write_sticky_channel "$TARGET_ROOT" "$CHANNEL"
    fi
  )
}

step "explicit --channel stable on an lts-pinned install rewrites sticky to 'stable'"
apply_write_gate "$TGT_RW" "stable" 1
got="$( ( eval "$DIE_STUB"; eval "$STICKY_READ"; bridge_upgrade_read_sticky_channel "$TGT_RW" ) 2>/dev/null )"
if [[ "$got" == "stable" ]]; then ok; else err "got '$got'"; fi

# Re-pin to lts, then prove --ref/--version (flag-explicit 0) do NOT overwrite it.
( eval "$DIE_STUB"; eval "$STICKY_WRITE"; bridge_upgrade_write_sticky_channel "$TGT_RW" "lts" )
step "--ref/--version one-shot (CHANNEL_FLAG_EXPLICIT=0) does NOT overwrite the 'lts' sticky"
apply_write_gate "$TGT_RW" "ref" 0
apply_write_gate "$TGT_RW" "stable" 0   # a --version run records CHANNEL=stable internally; still must not write
got="$( ( eval "$DIE_STUB"; eval "$STICKY_READ"; bridge_upgrade_read_sticky_channel "$TGT_RW" ) 2>/dev/null )"
if [[ "$got" == "lts" ]]; then ok; else err "sticky was clobbered by a one-shot run: got '$got'"; fi

# Absent sticky file: read echoes nothing, rc 0 (caller keeps the legacy default).
TGT_ABSENT="$TMP/install-absent"
mkdir -p "$TGT_ABSENT/state/upgrade"
step "absent sticky file -> empty output, rc 0 (legacy default applies)"
got="$( ( eval "$DIE_STUB"; eval "$STICKY_READ"; bridge_upgrade_read_sticky_channel "$TGT_ABSENT" ) 2>/dev/null )"; rc=$?
if [[ $rc -eq 0 && -z "$got" ]]; then ok; else err "rc=$rc got='$got'"; fi

# Invalid sticky file -> FAIL CLOSED (non-zero rc + remediation, no stable fallback).
TGT_BAD="$TMP/install-badsticky"
mkdir -p "$TGT_BAD/state/upgrade"
printf 'bogus\n' >"$TGT_BAD/state/upgrade/channel"
step "invalid sticky value -> non-zero rc + remediation, NOT a silent stable fallback"
got="$( ( eval "$DIE_STUB"; eval "$STICKY_READ"; bridge_upgrade_read_sticky_channel "$TGT_BAD" ) 2>"$TMP/t5.err" )"; rc=$?
if [[ $rc -ne 0 && -z "$got" ]] && grep -qi 'stable|dev|current|lts' "$TMP/t5.err"; then ok; else err "rc=$rc got='$got' err=$(cat "$TMP/t5.err")"; fi

# Prove the precedence path itself fails closed on an invalid sticky (it must
# NOT silently resolve to stable/v0.17.0).
TGT_BAD2="$TMP/install-badsticky2"
mkdir -p "$TGT_BAD2/state/upgrade"
printf 'bogus\n' >"$TGT_BAD2/state/upgrade/channel"
step "bare resolution on an invalid sticky FAILS CLOSED (does not resolve v0.17.0)"
got="$(resolve_bare "$TGT_BAD2" 2>"$TMP/t5b.err")"; rc=$?
if [[ $rc -ne 0 && "$got" != "stable|v0.17.0" ]]; then ok; else err "rc=$rc got='$got' (must fail closed)"; fi

# ---------------------------------------------------------------------------
# T6 — `lts` participates in the issue #1516 downgrade guard.
# ---------------------------------------------------------------------------
printf '== T6 — lts channel participates in the downgrade guard ==\n'

run_guard() {
  # $1=installed $2=target $3=allow_downgrade $4=channel
  (
    eval "$DIE_STUB"
    SOURCE_ROOT="$ROOT_DIR"   # real repo so bridge_upgrade_compare_versions finds bridge-release.py
    INSTALLED_VERSION="$1"
    TARGET_VERSION="$2"
    ALLOW_DOWNGRADE="$3"
    CHANNEL="$4"
    eval "$COMPARE_HELPER"
    eval "$GUARD_BLOCK"
  ) 2>"$TMP/guard.err"
}

step "lts backward move (installed 0.17.0 -> target 0.16.3) ABORTS without --allow-downgrade"
run_guard "0.17.0" "0.16.3" "0" "lts"; rc=$?
if [[ $rc -eq 64 ]]; then ok; else err "expected exit 64, got $rc (err=$(cat "$TMP/guard.err"))"; fi

step "lts backward move with --allow-downgrade PROCEEDS"
run_guard "0.17.0" "0.16.3" "1" "lts"; rc=$?
if [[ $rc -eq 0 ]]; then ok; else err "expected exit 0 (proceed), got $rc"; fi

step "lts forward move (installed 0.16.1 -> target 0.16.3) PROCEEDS"
run_guard "0.16.1" "0.16.3" "0" "lts"; rc=$?
if [[ $rc -eq 0 ]]; then ok; else err "forward lts move was blocked (rc=$rc)"; fi

# ---------------------------------------------------------------------------
# T7 — mixed selector parser order (codex r1 catch): a one-shot --version/--ref
# combined with an earlier --channel must NOT leave CHANNEL_FLAG_EXPLICIT
# latched, or the apply path would clobber/poison the sticky pin. Drive the
# REAL parser arms (extracted from bridge-upgrade.sh) so a parser-order
# regression is caught — the direct write-gate teeth above do not exercise the
# parser.
# ---------------------------------------------------------------------------
printf '== T7 — mixed --channel + --version/--ref parser does not clobber/poison sticky ==\n'

# Assemble a parse_args() wrapping the SHIPPED --channel/--version/--ref case
# arms (extracted into $PARSER_ARMS) and source it. The function body is built
# with `printf` into a temp file — NOT a heredoc with shell interpolation —
# because the case-arm bodies contain their own quotes/`$2`/`bridge_die` calls
# that make heredoc escaping fragile across bash versions (a heredoc form
# silently mis-evaluated under bash 3.2). `printf '%s\n' "$PARSER_ARMS"` writes
# the arms verbatim, so the parser under test stays the shipped code, not a
# hand-copy.
PARSE_FILE="$TMP/parse_args.sh"
{
  printf '%s\n' "$DIE_STUB"
  printf '%s\n' 'parse_args() ('
  printf '%s\n' '  CHANNEL="stable"; CHANNEL_EXPLICIT=0; CHANNEL_FLAG_EXPLICIT=0'
  printf '%s\n' '  REQUESTED_VERSION=""; REQUESTED_REF=""'
  printf '%s\n' '  while [[ $# -gt 0 ]]; do'
  printf '%s\n' '    case "$1" in'
  printf '%s\n' "$PARSER_ARMS"
  printf '%s\n' '      *) shift ;;'
  printf '%s\n' '    esac'
  printf '%s\n' '  done'
  printf '%s\n' '  printf "%s|%s" "$CHANNEL" "$CHANNEL_FLAG_EXPLICIT"'
  printf '%s\n' ')'
} >"$PARSE_FILE"
# shellcheck source=/dev/null
. "$PARSE_FILE"

step "--channel lts --version 0.16.3 -> flag cleared (does not rewrite the lts pin)"
got="$(parse_args --channel lts --version 0.16.3)"
# CHANNEL ends 'stable' (--version sets it) but the FLAG must be 0 so the write
# gate skips — the existing lts pin survives.
if [[ "${got##*|}" == "0" ]]; then ok; else err "CHANNEL_FLAG_EXPLICIT not cleared: got '$got'"; fi

step "--channel stable --ref v0.16.3 -> flag cleared (never persists invalid 'ref')"
got="$(parse_args --channel stable --ref v0.16.3)"
if [[ "${got##*|}" == "0" ]]; then ok; else err "CHANNEL_FLAG_EXPLICIT not cleared: got '$got'"; fi

step "plain --channel lts -> flag set (a real pin IS persisted)"
got="$(parse_args --channel lts)"
if [[ "$got" == "lts|1" ]]; then ok; else err "expected 'lts|1', got '$got'"; fi

step "plain --channel stable -> flag set (switch back to stable IS persisted)"
got="$(parse_args --channel stable)"
if [[ "$got" == "stable|1" ]]; then ok; else err "expected 'stable|1', got '$got'"; fi

# Defense-in-depth: even if a 'ref'/garbage value reached the writer with the
# flag set, the writer must refuse to poison the sticky file.
step "write helper refuses to persist a non-sticky value ('ref')"
TGT_POISON="$TMP/install-poison"
mkdir -p "$TGT_POISON/state/upgrade"
printf 'lts\n' >"$TGT_POISON/state/upgrade/channel"
( eval "$DIE_STUB"; eval "$STICKY_WRITE"; bridge_upgrade_write_sticky_channel "$TGT_POISON" "ref" )
got="$( ( eval "$DIE_STUB"; eval "$STICKY_READ"; bridge_upgrade_read_sticky_channel "$TGT_POISON" ) 2>/dev/null )"
if [[ "$got" == "lts" ]]; then ok; else err "writer poisoned the sticky with 'ref': got '$got'"; fi

# ---------------------------------------------------------------------------
# T8 — the PERSISTENT-channel write must FAIL CLOSED (Phase-4 codex catch): a
# mkdir/write failure must abort (non-zero) with a clear remediation, NEVER
# return rc=0 while leaving the sticky stale/missing. A silent success would let
# the operator believe `--channel lts --apply` pinned the install while the next
# bare upgrade sees no `lts` sticky and escapes to the global stable line.
# ---------------------------------------------------------------------------
printf '== T8 — persistent-channel write fails closed on mkdir/write failure ==\n'

# Run the write helper as a real command (DIE_STUB exits non-zero), capturing rc.
run_write() {
  # $1=target $2=channel  -> stderr to $TMP/write.err, prints nothing, returns rc
  ( eval "$DIE_STUB"; eval "$STICKY_WRITE"; bridge_upgrade_write_sticky_channel "$1" "$2" ) 2>"$TMP/write.err"
}

# Regression: a normal writable target records 'lts' and returns rc 0.
TGT_OK="$TMP/install-write-ok"
mkdir -p "$TGT_OK"
step "writable target -> records 'lts', rc 0"
run_write "$TGT_OK" "lts"; rc=$?
got="$( ( eval "$DIE_STUB"; eval "$STICKY_READ"; bridge_upgrade_read_sticky_channel "$TGT_OK" ) 2>/dev/null )"
if [[ $rc -eq 0 && "$got" == "lts" ]]; then ok; else err "rc=$rc got='$got' err=$(cat "$TMP/write.err")"; fi

# The two denial cases rely on filesystem mode bits, which root bypasses. Skip
# them under uid 0 (CI sometimes runs as root) — they cannot fail-close there.
if [[ "$(id -u)" -eq 0 ]]; then
  step "unwritable/non-creatable sticky fail-closed (SKIPPED under root — mode bits bypassed)"
  ok
else
  # Existing state/upgrade/channel at mode 0400 (unwritable) + --channel lts
  # must FAIL CLOSED and NOT silently leave the old value.
  TGT_RO_FILE="$TMP/install-ro-file"
  mkdir -p "$TGT_RO_FILE/state/upgrade"
  printf 'stable\n' >"$TGT_RO_FILE/state/upgrade/channel"
  chmod 0400 "$TGT_RO_FILE/state/upgrade/channel"
  step "unwritable existing sticky (0400) + write 'lts' -> FAILS CLOSED (non-zero), not silent rc 0"
  run_write "$TGT_RO_FILE" "lts"; rc=$?
  # Read the raw file (reader would also accept the stale 'stable', but the point
  # is the WRITE aborted rather than reporting success).
  raw="$(head -n 1 "$TGT_RO_FILE/state/upgrade/channel" 2>/dev/null | tr -d '[:space:]')"
  if [[ $rc -ne 0 ]] && grep -qi 'state/upgrade/channel' "$TMP/write.err" && [[ "$raw" == "stable" ]]; then
    ok
  else
    err "rc=$rc (must be non-zero) raw='$raw' err=$(cat "$TMP/write.err")"
  fi
  chmod 0700 "$TGT_RO_FILE/state/upgrade" 2>/dev/null || true

  # Non-creatable state/upgrade dir (parent state/ at 0500) + --channel lts must
  # FAIL CLOSED.
  TGT_RO_DIR="$TMP/install-ro-dir"
  mkdir -p "$TGT_RO_DIR/state"
  chmod 0500 "$TGT_RO_DIR/state"
  step "non-creatable state/upgrade dir (parent 0500) + write 'lts' -> FAILS CLOSED"
  run_write "$TGT_RO_DIR" "lts"; rc=$?
  if [[ $rc -ne 0 ]] && grep -qi 'state/upgrade' "$TMP/write.err"; then ok; else err "rc=$rc err=$(cat "$TMP/write.err")"; fi
  # Confirm nothing was written (dir not created / channel absent).
  step "non-creatable dir case left NO stale/partial sticky"
  if [[ ! -f "$TGT_RO_DIR/state/upgrade/channel" ]]; then ok; else err "a sticky file was created despite the failure"; fi
  chmod 0700 "$TGT_RO_DIR/state" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
printf '\n== lts-channel-sticky-resolver: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
