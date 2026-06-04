#!/usr/bin/env bash
# scripts/smoke/1520c-create-isolate-profile-publish.sh — issue #1520c
# (v0.16.0-beta3 residual): create→isolate workdir profile-perm publish
# gap + the watchdog publish-gap misclassification (PR-C).
#
# Background. On a first-time `agent create --isolate` for a linux-user
# iso Claude agent, the six Claude identity profile files
# (SOUL/CLAUDE/SESSION-TYPE/MEMORY/MEMORY-SCHEMA/TOOLS.md) under the
# workdir ended up `iso-uid:<controller-primary-group> 0600` instead of
# the iso v2 contract `iso-uid:ab-agent-<a> 0660`. The workdir DIR was
# correctly 2770; only the pre-scaffolded profile FILES were missed.
#
# PINNED MECHANISM (empirical create-time stat trace on agb-node-a,
# v0.16.0-beta3): `bridge_linux_prepare_agent_isolation` creates the
# `ab-agent-<a>` group and `chown -R`s the workdir to the iso UID. The
# controller process that invoked `agent create` carries a STALE
# supplementary-group cache that excludes the just-created group
# (KNOWN_ISSUES §28), so the #1506 recursive normalize's DIRECT-FIRST
# `find … -exec chgrp/chmod` cannot traverse the freshly-chowned
# `2770 ab-agent-<a>` workdir and never reaches the profile FILES.
#
# PR-C closes the residual with a NARROW, ROOT-FORCED publish
# (`bridge_isolation_v2_publish_workdir_profile_files`) of ONLY the six
# profile basenames AFTER the #1506 normalize, plus a metadata-aware
# watchdog classification (`publish-gap` vs `controller-cache-stale`).
#
# Cases (all run in a temp dir; never touches live runtime). The shell
# publish helper is exercised on macOS too by stubbing the v2-enforce
# gate ON and the agent-group resolver to the operator's own primary
# group — `bridge_linux_sudo_root` falls through to a direct invocation
# off Linux, so the chgrp/chmod runs without sudo.
#
#   C1  create-only per-FILE metadata: after one publish pass, EACH of
#       the six profile files is mode 0660 + group-readable. A dir-level
#       assertion FALSE-PASSES the gap — every file is stat'd by name.
#   C2  negative control — HEARTBEAT.md (controller-owned 0600) and the
#       v3 channel-state `.teams/.env` (0600) are NOT published.
#   C3  negative control — CHANGE-POLICY.md symlink is REFUSED (never
#       followed); the external target is unchanged.
#   C4  enforce gate OFF (shared-mode / non-Linux) → publish is a no-op;
#       files keep their 0600 mode.
#   C5  idempotency — a second publish pass on an already-published tree
#       leaves the files at 0660 (no over-mutation, returns 0).
#   C6  forced publish FAILURE → the function still returns 0 (create
#       SUCCEEDS) and emits a non-silent warn (G3 non-fatal contract).
#   C7  watchdog classification — a profile file at wrong-group / owner-
#       only is `publish-gap` (NOT controller-cache-stale); a file
#       matching the published contract + iso-readable stays
#       `controller-cache-stale` (no false-positive regression); the
#       HEARTBEAT.md negative control is never `publish-gap`. Includes the
#       C11 LONG-name regression guard: the expected group is anchored to
#       the workdir DIR's own group (setgid contract), so a long agent name
#       whose OS user (32-char trunc) and group (hash-trunc) DIVERGE is not
#       misclassified — the old prefix-swap derivation would have misfired.
#   C8  TOCTOU / no-follow PROPERTY: the root mutation is fd-based (open
#       O_NOFOLLOW + fchown/fchmod on the OPEN FD) so a profile basename
#       swapped for a symlink AFTER prepare's `chown -R` cannot redirect the
#       root chgrp/chmod; the lib publish fn no longer re-resolves a
#       profile pathname for a path-based root chgrp/chmod.
#
# Teeth (regression-revert simulation):
#   C1-teeth.  Drop the fchmod 0660 from the publish helper and C1's
#              group-read assertion fails (the dir-level shape would have
#              false-passed).
#   C2-teeth.  Add HEARTBEAT.md to the helper's basename list and C2
#              fails (HEARTBEAT.md becomes group-readable).
#   C6-teeth.  Make the publish failure fatal (return 1 instead of warn)
#              and C6's "returns 0" assertion fails.
#   C7-teeth.  Move the publish-gap metadata check AFTER the iso-probe
#              and C7's wrong-group case regresses to cache-stale.
#   C8-teeth.  Revert the root mutation to a path-based
#              `bridge_linux_sudo_root chgrp/chmod <path>` (or drop the
#              O_NOFOLLOW open) and C8 fails — the TOCTOU window reopens.
#
# Footgun #11 mitigation: zero heredoc-stdin to a subprocess; every
# python assertion runs via `python3 <file>` with argv-only arguments.

set -uo pipefail

SMOKE_NAME="1520c-create-isolate-profile-publish"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

# The publish helper emits a `profile_publish_failed` audit row on a
# publish failure (C6, G3 non-fatal contract). Point BRIDGE_AUDIT_LOG at
# the isolated temp root so `bridge_audit_log` writes there instead of
# tripping its python/path resolution on a bare environment (which would
# `bridge_die` inside the command-substitution subshell before the rc is
# printed).
export BRIDGE_AUDIT_LOG="$SMOKE_TMP_ROOT/audit.jsonl"
: >"$BRIDGE_AUDIT_LOG"

HELPER_DIR="$REPO_ROOT/scripts/smoke/1520c-create-isolate-helpers"
[[ -d "$HELPER_DIR" ]] || smoke_fail "missing $HELPER_DIR (PR-C helpers)"

OPERATOR_GROUP="$(id -gn 2>/dev/null || printf '')"
[[ -n "$OPERATOR_GROUP" ]] || smoke_fail "could not resolve operator primary group"

PROFILE_FILES="SOUL.md,CLAUDE.md,SESSION-TYPE.md,MEMORY.md,MEMORY-SCHEMA.md,TOOLS.md"

# ---------------------------------------------------------------------
# Build a workdir fixture mirroring the post-chown create-time state:
# six profile files + HEARTBEAT.md + a .teams/.env channel file, all at
# 0600, plus a CHANGE-POLICY.md symlink to an external target.
# ---------------------------------------------------------------------
make_fixture() {
  local wd="$1"
  mkdir -p "$wd/.teams"
  local f
  for f in SOUL.md CLAUDE.md SESSION-TYPE.md MEMORY.md MEMORY-SCHEMA.md \
           TOOLS.md HEARTBEAT.md; do
    : >"$wd/$f"
    chmod 0600 "$wd/$f"
  done
  : >"$wd/.teams/.env"
  chmod 0600 "$wd/.teams/.env"
}

# Invoke the publish helper with the v2-enforce gate stubbed ON and the
# agent-group resolver stubbed to the operator's primary group, so the
# root-forced chgrp/chmod (direct off Linux) succeeds without sudo.
# Extra positional args after the workdir are eval'd as additional stub
# overrides (used by C6 to force a failure).
run_publish() {
  local wd="$1"
  local enforce_rc="${2:-0}"
  local group="${3:-$OPERATOR_GROUP}"
  local extra_stub="${4:-}"
  (
    set +e
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1
    # shellcheck disable=SC2329
    bridge_isolation_v2_enforce() { return "$enforce_rc"; }
    # shellcheck disable=SC2329
    bridge_isolation_v2_agent_group_name() { printf '%s' "$group"; }
    if [[ -n "$extra_stub" ]]; then
      eval "$extra_stub"
    fi
    bridge_isolation_v2_publish_workdir_profile_files "test_agent" "$wd" "$group"
    printf 'rc=%s\n' "$?"
  )
}

# =====================================================================
# C1 — create-only per-FILE metadata: six profile files published 0660
# C2 — HEARTBEAT.md + .teams/.env (+ CHANGE-POLICY.md symlink) NOT touched
# =====================================================================
C1_WD="$SMOKE_TMP_ROOT/c1-workdir"
make_fixture "$C1_WD"
# CHANGE-POLICY.md is a shared symlink NOT in the publish basename set —
# the helper must ignore it entirely (it is never even examined). Point it
# at an external target and assert that target is never republished.
C1_EXT="$SMOKE_TMP_ROOT/c1-external-change-policy.md"
: >"$C1_EXT"
chmod 0600 "$C1_EXT"
ln -s "$C1_EXT" "$C1_WD/CHANGE-POLICY.md"

C1_LOG="$SMOKE_TMP_ROOT/c1.log"
run_publish "$C1_WD" >"$C1_LOG" 2>&1
smoke_assert_contains "$(cat "$C1_LOG")" "rc=0" "C1 publish helper rc"

"$PY_BIN" "$HELPER_DIR/assert-profile-publish-modes.py" "$C1_WD" "0660" \
  --published "$PROFILE_FILES" \
  --owner-only "HEARTBEAT.md,.teams/.env" \
  --symlink "CHANGE-POLICY.md" \
  || smoke_fail "C1/C2 FAIL — per-file publish / negative controls (see $C1_LOG)"

# CHANGE-POLICY.md is NOT a publish basename → the helper must not even
# emit a symlink-refusal warn for it, and its external target stays 0600.
C1_EXT_MODE="$(stat -c '%a' "$C1_EXT" 2>/dev/null || stat -f '%Lp' "$C1_EXT" 2>/dev/null)"
smoke_assert_eq "600" "$C1_EXT_MODE" "C2 CHANGE-POLICY external target mode (must stay 0600)"
smoke_assert_not_contains "$(cat "$C1_LOG")" "CHANGE-POLICY" "C2 CHANGE-POLICY never examined"
smoke_log "C1/C2 PASS — six profile files @ 0660; HEARTBEAT/.teams/.env/CHANGE-POLICY untouched"

# =====================================================================
# C3 — symlink REFUSAL: a PROFILE basename (CLAUDE.md) that is itself a
#      symlink is refused (never followed); its external target is
#      untouched; the OTHER five profile files still publish.
# =====================================================================
C3_WD="$SMOKE_TMP_ROOT/c3-workdir"
make_fixture "$C3_WD"
C3_EXT="$SMOKE_TMP_ROOT/c3-external-claude.md"
: >"$C3_EXT"
chmod 0600 "$C3_EXT"
rm -f "$C3_WD/CLAUDE.md"
ln -s "$C3_EXT" "$C3_WD/CLAUDE.md"

C3_LOG="$SMOKE_TMP_ROOT/c3.log"
run_publish "$C3_WD" >"$C3_LOG" 2>&1
smoke_assert_contains "$(cat "$C3_LOG")" "rc=0" "C3 publish helper rc"
smoke_assert_contains "$(cat "$C3_LOG")" "refusing symlink" "C3 symlink refusal warn"
# External CLAUDE.md target untouched (publish refused to follow the link).
C3_EXT_MODE="$(stat -c '%a' "$C3_EXT" 2>/dev/null || stat -f '%Lp' "$C3_EXT" 2>/dev/null)"
smoke_assert_eq "600" "$C3_EXT_MODE" "C3 symlink external target mode (must stay 0600)"
[[ -L "$C3_WD/CLAUDE.md" ]] || smoke_fail "C3 FAIL — CLAUDE.md symlink was followed/replaced"
# The other five profile files still published to 0660.
"$PY_BIN" "$HELPER_DIR/assert-profile-publish-modes.py" "$C3_WD" "0660" \
  --published "SOUL.md,SESSION-TYPE.md,MEMORY.md,MEMORY-SCHEMA.md,TOOLS.md" \
  --owner-only "HEARTBEAT.md,.teams/.env" \
  || smoke_fail "C3 FAIL — non-symlink profile files were not published"
smoke_log "C3 PASS — symlinked profile basename refused; siblings still published"

# =====================================================================
# C4 — enforce gate OFF → publish is a no-op (files stay 0600)
# =====================================================================
C4_WD="$SMOKE_TMP_ROOT/c4-workdir"
make_fixture "$C4_WD"
run_publish "$C4_WD" 1 >/dev/null 2>&1
"$PY_BIN" "$HELPER_DIR/assert-profile-publish-modes.py" "$C4_WD" "0600" \
  --published "$PROFILE_FILES" \
  || smoke_fail "C4 FAIL — enforce-OFF publish was not a no-op (file mode changed)"
smoke_log "C4 PASS — enforce gate OFF makes publish a no-op"

# =====================================================================
# C5 — idempotency: second pass leaves files at 0660
# =====================================================================
C5_LOG="$SMOKE_TMP_ROOT/c5.log"
run_publish "$C1_WD" >"$C5_LOG" 2>&1
smoke_assert_contains "$(cat "$C5_LOG")" "rc=0" "C5 idempotent rc"
"$PY_BIN" "$HELPER_DIR/assert-profile-publish-modes.py" "$C1_WD" "0660" \
  --published "$PROFILE_FILES" \
  --owner-only "HEARTBEAT.md,.teams/.env" \
  || smoke_fail "C5 FAIL — idempotent re-publish changed the published state"
smoke_log "C5 PASS — re-publish is idempotent (files stay 0660)"

# =====================================================================
# C6 — forced publish failure → create SUCCEEDS (helper returns 0) +
#      a non-silent warn is emitted (G3 non-fatal contract).
# =====================================================================
C6_WD="$SMOKE_TMP_ROOT/c6-workdir"
make_fixture "$C6_WD"
C6_LOG="$SMOKE_TMP_ROOT/c6.log"
# The root mutation now runs via `bridge_linux_sudo_root python3 <helper>`.
# Force the helper invocation to FAIL (return non-zero) so the lib helper
# takes its non-fatal warn+audit path. Pass-through everything else.
C6_STUB='bridge_linux_sudo_root() { case "$1" in python3|python|*/python3|*/python) return 1;; *) command "$@";; esac; }'
: >"$BRIDGE_AUDIT_LOG"
run_publish "$C6_WD" 0 "$OPERATOR_GROUP" "$C6_STUB" >"$C6_LOG" 2>&1
smoke_assert_contains "$(cat "$C6_LOG")" "rc=0" "C6 forced-failure helper still returns 0 (non-fatal)"
smoke_assert_contains "$(cat "$C6_LOG")" "publish helper failed" "C6 non-silent warn on publish failure"
# The G3 contract also emits a `profile_publish_failed` audit row.
smoke_assert_contains "$(cat "$BRIDGE_AUDIT_LOG")" "profile_publish_failed" \
  "C6 profile_publish_failed audit row emitted"
smoke_log "C6 PASS — forced publish failure is non-fatal (create succeeds) + non-silent + audited"

# =====================================================================
# C7 — watchdog publish-gap classification + cache-stale preservation
#      (incl. C11 long-name dir-group-anchor regression guard).
# =====================================================================
"$PY_BIN" "$HELPER_DIR/assert-watchdog-publish-gap.py" "$REPO_ROOT" \
  || smoke_fail "C7 FAIL — watchdog publish-gap classification / cache-stale preservation"
smoke_log "C7 PASS — watchdog classifies publish-gap; genuine cache-stale preserved"

# =====================================================================
# C8 — TOCTOU / no-follow PROPERTY tooth (BLOCKING #1 regression guard).
#      The root mutation must be fd-based (open O_NOFOLLOW + fchown/fchmod
#      on the OPEN FD), NEVER a path-based root chgrp/chmod that a rename
#      could race after prepare's `chown -R` hands the workdir to the iso
#      UID. Assert the helper opens with O_NOFOLLOW and mutates the fd, and
#      that the lib publish path no longer re-resolves a profile pathname
#      for a root chgrp/chmod.
# =====================================================================
PUB_HELPER="$REPO_ROOT/scripts/python-helpers/isolation-publish-profile-files.py"
[[ -f "$PUB_HELPER" ]] || smoke_fail "C8 FAIL — publish helper missing: $PUB_HELPER"
grep -q "O_NOFOLLOW" "$PUB_HELPER" \
  || smoke_fail "C8 FAIL — helper does not open with O_NOFOLLOW (TOCTOU-unsafe)"
grep -q "os.fchown" "$PUB_HELPER" \
  || smoke_fail "C8 FAIL — helper does not fchown the open fd"
grep -q "os.fchmod" "$PUB_HELPER" \
  || smoke_fail "C8 FAIL — helper does not fchmod the open fd"
# The publish FUNCTION body in the lib must delegate to the helper, not
# re-introduce a path-based `bridge_linux_sudo_root chgrp/chmod <path>`.
# Extract just that function's body via awk (no heredoc — footgun #11):
# print from the function header to its first column-0 closing brace.
PUBLISH_FN_BODY="$SMOKE_TMP_ROOT/publish-fn-body.txt"
awk '
  /^bridge_isolation_v2_publish_workdir_profile_files\(\)[[:space:]]*\{/ { f=1 }
  f { print }
  f && /^\}/ { exit }
' "$REPO_ROOT/lib/bridge-isolation-v2.sh" >"$PUBLISH_FN_BODY"
[[ -s "$PUBLISH_FN_BODY" ]] || smoke_fail "C8 FAIL — could not extract publish fn body"
if grep -Eq 'bridge_linux_sudo_root[[:space:]]+(chgrp|chmod)[[:space:]]' "$PUBLISH_FN_BODY"; then
  smoke_fail "C8 FAIL — publish fn re-introduced a path-based root chgrp/chmod (TOCTOU)"
fi
grep -q "isolation-publish-profile-files.py" "$PUBLISH_FN_BODY" \
  || smoke_fail "C8 FAIL — publish fn does not delegate to the fd-based root helper"
smoke_log "C8 PASS — root publish is fd-based O_NOFOLLOW (no path-based chgrp/chmod race)"

smoke_log "ALL PASS"
