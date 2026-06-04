#!/usr/bin/env bash
# Issue #1513 regression smoke — an iso agent with a `plugin:teams`
# channel must not have its launch aborted by the legacy Teams MCP
# prune crashing on an unreadable legacy mirror dir.
#
# Bug: `bridge-run.sh` runs scripts/python-helpers/prune-legacy-teams-
# mcp.py AS the iso UID (`agent-bridge-<a>`) against `--agent-root
# $BRIDGE_AGENT_HOME_ROOT/<a>` — the legacy controller-side
# `<BRIDGE_HOME>/agents/<a>/` mirror — which on the create-shared-then-
# isolate path was scaffolded 0700 (controller umask 077). The iso UID
# (not owner, not in the owning group) cannot traverse a 0700 dir, so
# `Path('.../<a>/.mcp.json').is_file()` inside `prune_file()` raises
# `PermissionError` (errno 13). Python 3.10's `is_file()` only swallows
# ENOENT/ENOTDIR/EBADF/ELOOP — NOT EACCES — so the prune crashes with an
# uncaught traceback, exits non-zero, and `bridge-run.sh` hardens that
# into `aborting launch: stale Teams MCP cleanup failed` → the launch
# dies. A healthy agent's legacy root is 0755 (traversable), so the same
# prune returns `is_file: False` cleanly.
#
# Two-layer fix (as refined by #1518):
#   L1 (defensive) — prune_file() in prune-legacy-teams-mcp.py catches
#      PermissionError/OSError around is_file() and returns a non-fatal
#      `skipped path=… reason=stat-failed:<errno>` instead of raising.
#      A prune that cannot even stat a stale-entry candidate must skip it
#      non-fatally; the helper exit stays 0 so the launch is not aborted.
#   L2 (perms) — bridge_linux_prepare_agent_isolation
#      (lib/bridge-agents.sh) normalizes the legacy
#      `$BRIDGE_AGENT_HOME_ROOT/<a>` mirror DIR to the iso v2 group-traversal
#      contract: `chgrp ab-agent-<a> + chmod 2750` →
#      `drwxr-s--- 2750 root:ab-agent-<a>` (group r-x + setgid, NO "other"
#      access). The iso UID `agent-bridge-<a>` is a member of `ab-agent-<a>`
#      and traverses via the GROUP x-bit. Files inside stay 0600/iso-owned;
#      owner stays root.
#
#      #1518 fixed two defects in #1513's original L2 `chmod 0755`:
#        (a) On a NON-split install (legacy `agents/<a>` IS the v2 root)
#            the later recursive setgid/group normalization CLOBBERED the
#            `0755` to `2750 root:ab-agent-<a>` — the 2-VM observation —
#            so the chmod was dead there.
#        (b) On the DEFAULT split-root v2 layout (BRIDGE_DATA_ROOT =
#            `$BRIDGE_HOME/data`, so the v2 root `$BRIDGE_HOME/data/agents/<a>`
#            is a DIFFERENT dir than this legacy `$BRIDGE_HOME/agents/<a>`
#            mirror), NO matrix normalizes the legacy leaf, so the dir
#            stayed `0700` and the `chmod 0755`, placed BEFORE the
#            reconciler, was the only thing covering the split case — but
#            with the wrong "other"-x contract and at risk of reordering.
#      The fix moves the normalization to run LAST (after the grant-matrix
#      + install-tree reconciler) and sets the narrower `2750 group=ab-agent
#      -<a>` contract, so BOTH layouts converge to the same final state and
#      it can never be clobbered.
#
# This smoke verifies BOTH:
#   (L1) Behavior — invoking the actual prune helper against an
#        agent-root the running process cannot stat into yields exit 0
#        and a `skipped … reason=stat-failed` line, NOT a traceback /
#        non-zero exit. Deterministic on macOS + Linux: a self-owned
#        mode-0000 dir is not traversable even by its owner (no x-bit),
#        so `is_file()` on a child raises EACCES for the test process.
#        A negative check confirms the pre-fix `is_file()` raises.
#   (L2a) Integration — bridge_linux_prepare_agent_isolation normalizes the
#        legacy mirror dir to the `2750`/group-traverse contract (chgrp the
#        agent group + chmod 2750 on `$BRIDGE_AGENT_HOME_ROOT/$agent`), it
#        runs AFTER the install-tree reconciler (so it is not clobbered), it
#        is NOT the dead "other"-x `chmod 0755`, and it is NOT a recursive
#        `-R` widen. Reverting any of these fails the smoke.
#   (L2b) Behavior — modelling the FINAL effective state on the local fs
#        seam: the legacy mirror dir normalized to mode `2750` + setgid +
#        a NON-OWNER group the test process is a member of is traversable
#        via the GROUP x-bit (no "other" access), the prune against it
#        returns `absent`/`unchanged` (NOT `skipped reason=stat-failed`),
#        and the inner 0600 file's mode is untouched. Revert-teeth: the
#        pre-normalization `0700` state blocks the same group-member
#        traversal (negative control).
#
# Footgun #11 (Bash 5.3.9 heredoc-class deadlock): no heredoc-stdin /
# here-string / process-substitution feeds a subprocess here; the L1/L2b
# behavioral checks invoke the real prune helper by argv.

set -uo pipefail

SMOKE_NAME="1513-iso-teams-prune-eacces"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENTS_LIB="$REPO_ROOT/lib/bridge-agents.sh"
PRUNE_HELPER="$REPO_ROOT/scripts/python-helpers/prune-legacy-teams-mcp.py"

# shellcheck disable=SC2329 # invoked via `trap cleanup EXIT`
cleanup() {
  # Restore any 0000 dirs so smoke_cleanup_temp_root can rm -rf them.
  [[ -n "${SMOKE_TMP_ROOT:-}" ]] && chmod -R u+rwx "$SMOKE_TMP_ROOT" 2>/dev/null
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

[[ -f "$AGENTS_LIB" ]]    || smoke_fail "missing $AGENTS_LIB"
[[ -f "$PRUNE_HELPER" ]]  || smoke_fail "missing $PRUNE_HELPER"

PY_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
[[ -n "$PY_BIN" ]] || smoke_fail "python3 not found"

# Portable LOW-bits mode helper: GNU `stat -c '%a'`, BSD `stat -f '%Lp'`.
# NOTE: BSD `%Lp` reports only the permission bits and DROPS the setgid
# bit, so for directories assert the setgid bit separately via _has_setgid.
_mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Portable setgid-bit probe (mirrors scripts/smoke/1506-isolate-normalize.sh).
# GNU `stat -c '%a'` returns a 4-digit mode with a leading 2/3/6/7 when
# setgid is set; BSD drops it, so fall back to the `ls -ld` group-exec slot
# (`s`/`S` at the 6th permission char). Returns 0 when setgid is set.
_has_setgid() {
  local p="$1" gnu_mode perms
  gnu_mode="$(stat -c '%a' "$p" 2>/dev/null || printf '')"
  if [[ -n "$gnu_mode" ]]; then
    case "$gnu_mode" in
      2*|3*|6*|7*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  # shellcheck disable=SC2012 # single known path, not a glob — SC2012 N/A
  perms="$(ls -ld "$p" 2>/dev/null | awk '{print $1}')"
  case "${perms:6:1}" in
    s|S) return 0 ;;
    *) return 1 ;;
  esac
}

# Portable group ('g') and other ('o') execute/traverse-bit probes from the
# `ls -ld` symbolic perms. Position 6 = group-exec, position 9 = other-exec.
# Returns 0 when the bit grants traversal (x/s for group, x/t for other).
_has_group_x() {
  local perms
  # shellcheck disable=SC2012 # single known path, not a glob — SC2012 N/A
  perms="$(ls -ld "$1" 2>/dev/null | awk '{print $1}')"
  case "${perms:6:1}" in x|s) return 0 ;; *) return 1 ;; esac
}
_has_other_x() {
  local perms
  # shellcheck disable=SC2012 # single known path, not a glob — SC2012 N/A
  perms="$(ls -ld "$1" 2>/dev/null | awk '{print $1}')"
  case "${perms:9:1}" in x|t) return 0 ;; *) return 1 ;; esac
}

# Portable group-name-of-path helper: GNU `stat -c '%G'`, BSD `stat -f '%Sg'`.
_group_of() {
  stat -c '%G' "$1" 2>/dev/null || stat -f '%Sg' "$1"
}

# =====================================================================
# (L1) Behavioral — the prune helper skips an unstattable agent-root
#      non-fatally (exit 0, logs `skipped reason=stat-failed`).
# =====================================================================

smoke_log "L1: prune helper skips an unreadable agent-root non-fatally (exit 0, reason=stat-failed)"

L1_ROOT="$SMOKE_TMP_ROOT/l1"
L1_AGENT_ROOT="$L1_ROOT/agent-root"
L1_WORKDIR="$L1_ROOT/workdir"
mkdir -p "$L1_AGENT_ROOT" "$L1_WORKDIR"
# Seed a legacy mirror `.mcp.json` so the only thing standing between the
# prune and a clean read is the parent dir's missing traverse bit.
printf '{"mcpServers":{}}\n' >"$L1_AGENT_ROOT/.mcp.json"

# Negative control: confirm the pre-fix failure mode is real on this host
# — `Path(child).is_file()` under a 0000 parent raises (would crash the
# pre-fix helper). If it does NOT raise here (e.g. the test runs as a UID
# that can always traverse, like root in some containers), L1 cannot be
# exercised deterministically; skip rather than false-pass.
chmod 0000 "$L1_AGENT_ROOT"
L1_PROBE_RC=0
"$PY_BIN" -c "from pathlib import Path; import sys; Path('$L1_AGENT_ROOT/.mcp.json').is_file()" >/dev/null 2>&1 || L1_PROBE_RC=$?
if [[ "$L1_PROBE_RC" -eq 0 ]]; then
  chmod 0755 "$L1_AGENT_ROOT"
  smoke_skip "L1 behavioral" "this process can traverse a 0000 dir (likely root/container); the EACCES path is not reachable here — covered by the PR's manual Linux iso-UID repro"
else
  smoke_log "L1 negative control OK — pre-fix is_file() raises under the 0000 parent (rc=$L1_PROBE_RC)"

  L1_OUT="$SMOKE_TMP_ROOT/l1.out"
  L1_RC=0
  "$PY_BIN" "$PRUNE_HELPER" \
    --agent l1agent \
    --workdir "$L1_WORKDIR" \
    --agent-root "$L1_AGENT_ROOT" \
    >"$L1_OUT" 2>&1 || L1_RC=$?
  chmod 0755 "$L1_AGENT_ROOT"

  if [[ "$L1_RC" -ne 0 ]]; then
    cat "$L1_OUT"
    smoke_fail "L1: prune helper exited non-zero ($L1_RC) on an unreadable agent-root — #1513 layer-1 not fixed (this aborts the launch in bridge-run.sh)"
  fi
  if ! grep -E 'skipped path=.*reason=stat-failed' "$L1_OUT" >/dev/null; then
    cat "$L1_OUT"
    smoke_fail "L1: prune output missing the non-fatal 'skipped … reason=stat-failed' line for the unreadable agent-root"
  fi
  if grep -Ei 'Traceback|PermissionError' "$L1_OUT" >/dev/null; then
    cat "$L1_OUT"
    smoke_fail "L1: prune emitted a traceback/PermissionError instead of a clean skip"
  fi
  smoke_log "L1 PASS — prune skipped the unreadable agent-root non-fatally (exit 0, reason=stat-failed; no traceback)"
fi

# =====================================================================
# (L2a) Integration — prepare_agent_isolation normalizes the legacy
#       mirror dir to the 2750/group-traverse contract, AFTER the
#       install-tree reconciler, NOT the dead "other"-x 0755, NOT -R.
# =====================================================================

smoke_log "L2a: bridge_linux_prepare_agent_isolation normalizes the legacy mirror to 2750/group (after the reconciler, not 0755)"

PREP_START="$(grep -nE '^bridge_linux_prepare_agent_isolation\(\)' "$AGENTS_LIB" | head -1 | cut -d: -f1)"
[[ -n "$PREP_START" ]] || smoke_fail "L2a: cannot locate bridge_linux_prepare_agent_isolation in $AGENTS_LIB"

PREP_BODY="$(awk -v start="$PREP_START" '
  NR < start { next }
  NR == start { in_fn = 1; print; next }
  in_fn { print; if ($0 == "}") { exit } }
' "$AGENTS_LIB")"
[[ -n "$PREP_BODY" ]] || smoke_fail "L2a: extracted prepare_agent_isolation body is empty"

# Non-comment (code) lines only — the assertions below must not trip on the
# explanatory comments (which legitimately mention `0755` / `chmod 2750`).
PREP_CODE="$(printf '%s\n' "$PREP_BODY" | grep -vE '^[[:space:]]*#')"

L2A_FAILS=""

# L2a-1: #1513 anchor present (greppability + future-reader guard).
if ! printf '%s\n' "$PREP_BODY" | grep -F '#1513' >/dev/null; then
  L2A_FAILS+="no #1513 anchor in prepare_agent_isolation; "
fi

# L2a-2: the normalization targets the legacy mirror dir
# `$BRIDGE_AGENT_HOME_ROOT/$agent` and sets the group-traverse contract:
# chgrp the agent group + chmod 2750 (NOT the dead "other"-x 0755). Both
# operations must be on the `$_v2_legacy_mirror_dir` node.
if ! printf '%s\n' "$PREP_CODE" | grep -F '$BRIDGE_AGENT_HOME_ROOT/$agent' >/dev/null; then
  L2A_FAILS+="normalization does not reference \$BRIDGE_AGENT_HOME_ROOT/\$agent; "
fi
if ! printf '%s\n' "$PREP_CODE" \
    | grep -E 'chgrp "\$_v2_agent_group" "\$_v2_legacy_mirror_dir"' >/dev/null; then
  L2A_FAILS+="does not chgrp the legacy mirror dir to the agent group (\$_v2_agent_group); "
fi
if ! printf '%s\n' "$PREP_CODE" \
    | grep -E 'chmod 2750 "\$_v2_legacy_mirror_dir"' >/dev/null; then
  L2A_FAILS+="does not chmod 2750 the legacy mirror dir node (the group-traverse + setgid contract); "
fi

# L2a-3: the dead "other"-x `chmod 0755` on the legacy mirror dir is GONE
# (#1518: it was clobbered on non-split installs and was the wrong, wider
# contract on split installs). Re-adding it fails here.
if printf '%s\n' "$PREP_CODE" \
    | grep -E 'chmod[[:space:]]+0?755[[:space:]].*_v2_legacy_mirror_dir|_v2_legacy_mirror_dir.*chmod[[:space:]]+0?755' >/dev/null; then
  L2A_FAILS+="dead 'other'-x chmod 0755 of the legacy mirror dir is back (#1518: wrong/clobbered contract); "
fi

# L2a-4: no recursive `-R` chmod/chown of the legacy mirror tree — that
# would expose the inner 0600 files (the #1513 contract: files untouched).
if printf '%s\n' "$PREP_CODE" \
    | grep -E 'chmod[[:space:]]+-R[[:space:]].*_v2_legacy_mirror_dir|_v2_legacy_mirror_dir.*chmod[[:space:]]+-R|chgrp[[:space:]]+-R[[:space:]].*_v2_legacy_mirror_dir|_v2_legacy_mirror_dir.*chgrp[[:space:]]+-R' >/dev/null; then
  L2A_FAILS+="introduced a recursive -R chmod/chgrp on the legacy mirror (widens inner 0600 files); "
fi

# L2a-5: the legacy-mirror normalization runs AFTER the install-tree
# reconciler (`bridge_isolation_v2_apply_install_tree_matrix`), so the
# matrix's recursive group normalization on a non-split install cannot
# clobber it (#1518 root cause: original placement was BEFORE it). Compare
# first-occurrence line numbers within the function body.
PREP_RECONCILER_LN="$(printf '%s\n' "$PREP_BODY" | grep -nE 'bridge_isolation_v2_apply_install_tree_matrix' | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)"
PREP_MIRROR_LN="$(printf '%s\n' "$PREP_BODY" | grep -nF 'chmod 2750 "$_v2_legacy_mirror_dir"' | head -1 | cut -d: -f1)"
if [[ -z "$PREP_RECONCILER_LN" ]]; then
  L2A_FAILS+="cannot find the install-tree reconciler call in prepare (ordering check inconclusive); "
elif [[ -z "$PREP_MIRROR_LN" ]]; then
  L2A_FAILS+="cannot find the legacy-mirror chmod 2750 in prepare (ordering check inconclusive); "
elif [[ "$PREP_MIRROR_LN" -le "$PREP_RECONCILER_LN" ]]; then
  L2A_FAILS+="legacy-mirror normalization (line $PREP_MIRROR_LN) runs BEFORE the install-tree reconciler (line $PREP_RECONCILER_LN) — the matrix can clobber it (#1518); "
fi

if [[ -n "$L2A_FAILS" ]]; then
  smoke_fail "L2a: integration regressions: $L2A_FAILS"
fi
smoke_log "L2a PASS — legacy mirror normalized to 2750/group AFTER the reconciler; no dead 0755, no recursive widen"

# =====================================================================
# (L2b) Behavioral — model the FINAL post-normalization state on the
#       local fs seam: the legacy mirror dir at mode 2750 + setgid +
#       a NON-OWNER group the test process is a member of is traversable
#       via the GROUP x-bit (no "other" access); the prune reads its
#       child cleanly; the inner 0600 file's mode is untouched. The
#       pre-normalization 0700 state is the negative control.
# =====================================================================
#
# CI does not provision the real `agent-bridge-<a>` UID / `ab-agent-<a>`
# group, so — exactly as scripts/smoke/1506-isolate-normalize.sh does —
# we surrogate the agent group with the caller's own group `$(id -gn)`
# and surrogate the iso UID's "group-member, not owner" traversal with
# the FINAL effective mode. The live OS-user + ab-agent-<a> iso-UID
# traversal (sudo-driven) is covered by the PR's manual Linux repro.

smoke_log "L2b: FINAL state = 2750 + setgid + group-x (no other-x); prune reads child cleanly; inner 0600 untouched"

L2_ROOT="$SMOKE_TMP_ROOT/l2"
L2_AGENT_ROOT="$L2_ROOT/agents/l2agent"
L2_WORKDIR="$L2_ROOT/workdir"
mkdir -p "$L2_AGENT_ROOT" "$L2_WORKDIR"
# Seed a non-secret legacy mirror `.mcp.json` at 0600 (controller umask),
# then lock the dir to 0700 to mimic the create-shared-then-isolate gap.
printf '{"mcpServers":{}}\n' >"$L2_AGENT_ROOT/.mcp.json"
chmod 0600 "$L2_AGENT_ROOT/.mcp.json"
chmod 0700 "$L2_AGENT_ROOT"

L2_FILE_MODE_BEFORE="$(_mode_of "$L2_AGENT_ROOT/.mcp.json")"
L2_GRP_SURROGATE="$(id -gn)"

# --- Negative control (revert-teeth): the pre-normalization 0700 dir has
#     NO group x-bit. A non-owner member of the dir's group cannot
#     traverse it — which is the exact #1513 abort. Assert the structural
#     gap is real on this host before we normalize.
if _has_group_x "$L2_AGENT_ROOT"; then
  smoke_fail "L2b negative control: seeded 0700 mirror unexpectedly has group-x — cannot exercise the traverse-bit contract on this host"
fi

# --- Apply EXACTLY what bridge_linux_prepare_agent_isolation applies to
#     the legacy mirror dir (the L2a `chgrp $_v2_agent_group` +
#     `chmod 2750`): group = the agent group (here the surrogate), mode
#     2750 (group r-x + setgid, NO other access). This is the FINAL state
#     #1518's 2-VM validation observed (`drwxr-s--- 2750 root:ab-agent-<a>`),
#     NOT the dead "other"-x 0755. As the dir owner a plain chgrp/chmod is
#     the same operation the privileged prepare path performs via sudo.
chgrp "$L2_GRP_SURROGATE" "$L2_AGENT_ROOT" \
  || smoke_fail "L2b: chgrp '$L2_GRP_SURROGATE' on the mirror dir failed (cannot model the final group)"
chmod 2750 "$L2_AGENT_ROOT"

# FINAL effective mode = low-bits 750 + setgid; group-x present; other
# access absent; group == the agent-group surrogate. Reverting the
# normalization mechanism (dir falls back to 0700 / group=<controller>)
# fails one of these.
L2_DIR_MODE="$(_mode_of "$L2_AGENT_ROOT")"
case "$L2_DIR_MODE" in
  750|2750) : ;;
  *) smoke_fail "L2b: legacy mirror dir low-bits not 750 after final-state normalize (got $L2_DIR_MODE) — expected 2750 (group r-x + setgid, no other)" ;;
esac
_has_setgid "$L2_AGENT_ROOT" \
  || smoke_fail "L2b: legacy mirror dir missing setgid after normalize (got $L2_DIR_MODE) — the 2750 contract requires setgid so children inherit the agent group"
_has_group_x "$L2_AGENT_ROOT" \
  || smoke_fail "L2b: legacy mirror dir has NO group x-bit after normalize (got $L2_DIR_MODE) — the iso UID (a group member, not owner) could not traverse → #1513 abort returns"
if _has_other_x "$L2_AGENT_ROOT"; then
  smoke_fail "L2b: legacy mirror dir has the 'other' x-bit (got $L2_DIR_MODE) — the FINAL contract is 2750 (group-traversable only), NOT the dead 0755; an other-x bit means the dead chmod is back"
fi
L2_DIR_GRP="$(_group_of "$L2_AGENT_ROOT")"
if [[ "$L2_DIR_GRP" != "$L2_GRP_SURROGATE" ]]; then
  smoke_fail "L2b: legacy mirror dir group not normalized to the agent group '$L2_GRP_SURROGATE' (got '$L2_DIR_GRP') — traversal relies on the iso UID being a member of THIS group"
fi

# Inner file mode MUST be unchanged by the dir-only normalization.
L2_FILE_MODE_AFTER="$(_mode_of "$L2_AGENT_ROOT/.mcp.json")"
if [[ "$L2_FILE_MODE_AFTER" != "$L2_FILE_MODE_BEFORE" ]]; then
  smoke_fail "L2b: inner .mcp.json mode changed by the dir normalize ($L2_FILE_MODE_BEFORE -> $L2_FILE_MODE_AFTER) — the legacy mirror's inner 0600 files must not be widened"
fi
case "$L2_FILE_MODE_AFTER" in
  600) : ;;
  *) smoke_fail "L2b: inner .mcp.json not 0600 after normalize (got $L2_FILE_MODE_AFTER) — files must stay owner-only" ;;
esac

# Now the prune can traverse the mirror (the running process owns it AND
# is a member of its group) and returns a clean non-skip result (the
# seeded mcpServers has no legacy teams entry → absent/unchanged).
L2_OUT="$SMOKE_TMP_ROOT/l2.out"
L2_RC=0
"$PY_BIN" "$PRUNE_HELPER" \
  --agent l2agent \
  --workdir "$L2_WORKDIR" \
  --agent-root "$L2_AGENT_ROOT" \
  >"$L2_OUT" 2>&1 || L2_RC=$?

if [[ "$L2_RC" -ne 0 ]]; then
  cat "$L2_OUT"
  smoke_fail "L2b: prune exited non-zero ($L2_RC) against the 2750 group-traversable mirror"
fi
if grep -E 'reason=stat-failed' "$L2_OUT" >/dev/null; then
  cat "$L2_OUT"
  smoke_fail "L2b: prune still reports stat-failed against the 2750 mirror — the group-traversability contract did not take"
fi
smoke_log "L2b PASS — dir 2750 + setgid + group-x (no other-x), group=$L2_GRP_SURROGATE, inner file stayed 0600, prune reads it cleanly (no stat-failed)"

if smoke_is_linux; then
  smoke_log "host=Linux — L1/L2b ran against the local fs seam (group=$(id -gn) surrogate); the live OS-user + ab-agent-<a> iso-UID traversal of the 2750 mirror is covered by the PR's manual Linux repro"
else
  smoke_log "host=non-Linux — L1/L2b verified via the local mode/group seam; the live OS-user/group iso-UID prune path is Linux + sudo only (see PR manual repro)"
fi

smoke_log "PASS — #1513/#1518: iso teams launch survives the legacy mirror (L1 prune skips an unstattable root non-fatally; L2 prepare normalizes the mirror to 2750 group=ab-agent-<a> AFTER the reconciler — group-traversable, not the dead 0755, inner 0600 files untouched)"
exit 0
