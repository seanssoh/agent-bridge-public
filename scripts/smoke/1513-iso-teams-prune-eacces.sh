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
# Two-layer fix:
#   L1 (defensive) — prune_file() in prune-legacy-teams-mcp.py catches
#      PermissionError/OSError around is_file() and returns a non-fatal
#      `skipped path=… reason=stat-failed:<errno>` instead of raising.
#      A prune that cannot even stat a stale-entry candidate must skip it
#      non-fatally; the helper exit stays 0 so the launch is not aborted.
#   L2 (perms) — bridge_linux_prepare_agent_isolation
#      (lib/bridge-agents.sh) normalizes the legacy
#      `$BRIDGE_AGENT_HOME_ROOT/<a>` mirror DIR's traverse bit to 0755 on
#      the create-shared-then-isolate path (the scaffold-time #1165 Gap 4
#      fix only fires when isolation is active AT create). Single-node
#      chmod 0755 — files inside stay 0600, owner/group unchanged.
#
# This smoke verifies BOTH:
#   (L1) Behavior — invoking the actual prune helper against an
#        agent-root the running process cannot stat into yields exit 0
#        and a `skipped … reason=stat-failed` line, NOT a traceback /
#        non-zero exit. Deterministic on macOS + Linux: a self-owned
#        mode-0000 dir is not traversable even by its owner (no x-bit),
#        so `is_file()` on a child raises EACCES for the test process.
#        A negative check confirms the pre-fix `is_file()` raises.
#   (L2a) Integration — bridge_linux_prepare_agent_isolation contains the
#        #1513 legacy-mirror traverse-bit normalization
#        (`$BRIDGE_AGENT_HOME_ROOT/$agent` + `chmod 0755`), it is a
#        single-node chmod (NOT a recursive widen), and it is anchored to
#        the issue for greppability.
#   (L2b) Behavior — a `chmod 0755` on a seeded 0700 mirror dir makes its
#        child reachable (the prune then returns `absent`/`unchanged`
#        rather than `skipped reason=stat-failed`), and the inner 0600
#        file's mode is untouched by the single-node chmod.
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

# Portable low-bits mode helper: GNU `stat -c '%a'`, BSD `stat -f '%Lp'`.
_mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
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
#       mirror dir's traverse bit (single-node chmod 0755, #1513 anchor).
# =====================================================================

smoke_log "L2a: bridge_linux_prepare_agent_isolation carries the #1513 legacy-mirror traverse-bit normalization"

PREP_START="$(grep -nE '^bridge_linux_prepare_agent_isolation\(\)' "$AGENTS_LIB" | head -1 | cut -d: -f1)"
[[ -n "$PREP_START" ]] || smoke_fail "L2a: cannot locate bridge_linux_prepare_agent_isolation in $AGENTS_LIB"

PREP_BODY="$(awk -v start="$PREP_START" '
  NR < start { next }
  NR == start { in_fn = 1; print; next }
  in_fn { print; if ($0 == "}") { exit } }
' "$AGENTS_LIB")"
[[ -n "$PREP_BODY" ]] || smoke_fail "L2a: extracted prepare_agent_isolation body is empty"
PREP_BODY_FLAT="$(printf '%s\n' "$PREP_BODY" | tr '\n' ' ' | tr -s ' ')"

L2A_FAILS=""

# L2a-1: #1513 anchor present (greppability + future-reader guard).
if ! printf '%s\n' "$PREP_BODY" | grep -F '#1513' >/dev/null; then
  L2A_FAILS+="no #1513 anchor in prepare_agent_isolation; "
fi

# L2a-2: it targets the legacy mirror dir `$BRIDGE_AGENT_HOME_ROOT/$agent`.
if ! printf '%s\n' "$PREP_BODY" | grep -F '$BRIDGE_AGENT_HOME_ROOT/$agent' >/dev/null; then
  L2A_FAILS+="normalization does not reference \$BRIDGE_AGENT_HOME_ROOT/\$agent; "
fi

# L2a-3: it sets the traverse bit via `chmod 0755` on that dir node.
if ! printf '%s\n' "$PREP_BODY_FLAT" \
    | grep -E 'chmod 0755 "\$_v2_legacy_mirror_dir"' >/dev/null; then
  L2A_FAILS+="does not chmod 0755 the legacy mirror dir node; "
fi

# L2a-4: it is a SINGLE-NODE chmod — no recursive `-R` widen of the
# legacy mirror tree (that would expose the inner 0600 files).
if printf '%s\n' "$PREP_BODY" | grep -vE '^[[:space:]]*#' \
    | grep -E 'chmod[[:space:]]+-R[[:space:]].*_v2_legacy_mirror_dir|_v2_legacy_mirror_dir.*chmod[[:space:]]+-R' >/dev/null; then
  L2A_FAILS+="introduced a recursive chmod -R on the legacy mirror (widens inner 0600 files); "
fi

if [[ -n "$L2A_FAILS" ]]; then
  smoke_fail "L2a: integration regressions: $L2A_FAILS"
fi
smoke_log "L2a PASS — #1513 normalization present, single-node chmod 0755 of the legacy mirror dir (no recursive widen)"

# =====================================================================
# (L2b) Behavioral — chmod 0755 on a seeded 0700 mirror dir restores
#       traversal; the inner 0600 file's mode is untouched.
# =====================================================================

smoke_log "L2b: chmod 0755 on a 0700 legacy mirror dir restores traversal; inner 0600 file mode preserved"

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

# Apply exactly what the L2 fix applies: a single-node chmod 0755 on the
# legacy mirror dir (the prepare path runs this as `bridge_linux_sudo_root
# chmod 0755 "$_v2_legacy_mirror_dir"`; here, as the dir owner, a plain
# chmod is the same operation).
chmod 0755 "$L2_AGENT_ROOT"

L2_DIR_MODE="$(_mode_of "$L2_AGENT_ROOT")"
case "$L2_DIR_MODE" in
  755) : ;;
  *) smoke_fail "L2b: legacy mirror dir not 0755 after normalize (got $L2_DIR_MODE)" ;;
esac

# Inner file mode MUST be unchanged by the single-node dir chmod.
L2_FILE_MODE_AFTER="$(_mode_of "$L2_AGENT_ROOT/.mcp.json")"
if [[ "$L2_FILE_MODE_AFTER" != "$L2_FILE_MODE_BEFORE" ]]; then
  smoke_fail "L2b: inner .mcp.json mode changed by the dir chmod ($L2_FILE_MODE_BEFORE -> $L2_FILE_MODE_AFTER) — a single-node chmod must not widen files"
fi
case "$L2_FILE_MODE_AFTER" in
  600) : ;;
  *) smoke_fail "L2b: inner .mcp.json not 0600 after normalize (got $L2_FILE_MODE_AFTER) — files must stay owner-only" ;;
esac

# Now the prune can traverse the mirror and returns a clean non-skip
# result (the seeded mcpServers has no legacy teams entry → unchanged).
L2_OUT="$SMOKE_TMP_ROOT/l2.out"
L2_RC=0
"$PY_BIN" "$PRUNE_HELPER" \
  --agent l2agent \
  --workdir "$L2_WORKDIR" \
  --agent-root "$L2_AGENT_ROOT" \
  >"$L2_OUT" 2>&1 || L2_RC=$?

if [[ "$L2_RC" -ne 0 ]]; then
  cat "$L2_OUT"
  smoke_fail "L2b: prune exited non-zero ($L2_RC) against the now-traversable mirror"
fi
if grep -E 'reason=stat-failed' "$L2_OUT" >/dev/null; then
  cat "$L2_OUT"
  smoke_fail "L2b: prune still reports stat-failed after the dir was made traversable — traverse-bit normalization did not take"
fi
smoke_log "L2b PASS — dir 0755 (traversable), inner file stayed 0600, prune reads it cleanly (no stat-failed)"

if smoke_is_linux; then
  smoke_log "host=Linux — L1/L2b ran against the local fs seam; the live OS-user + ab-agent-<a> iso-UID path (sudo-driven legacy mirror chmod, iso-UID prune) is covered by the PR's manual Linux repro"
else
  smoke_log "host=non-Linux — L1/L2b verified via the local mode seam; the live OS-user/group iso-UID prune path is Linux + sudo only (see PR manual repro)"
fi

smoke_log "PASS — #1513: iso teams launch survives an unreadable/0700 legacy mirror (L1 prune skips non-fatally; L2 isolate normalizes the mirror dir traverse bit without widening files)"
exit 0
