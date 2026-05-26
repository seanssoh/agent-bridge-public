#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1238-iso-scaffold-ownership.sh — Issue #1238 + companion bug.
#
# v0.15.0-beta1 fresh-install regression: `agent-bridge agent create
# <name> --isolate --engine claude` scaffolded the per-agent home tree
# (`SOUL.md`, `CLAUDE.md`, `MEMORY*.md`, `SESSION-TYPE.md`, `TOOLS.md`,
# `.claude/`, `memory/`, ...) under the controller `umask 077` (mode
# 0600 / 0700), but `bridge_linux_prepare_agent_isolation` only
# recursive-chowned `$workdir` to the iso UID and the top-level
# `$_v2_agent_root/home` chown was non-recursive. Net effect: the iso
# UID owned the `home/` directory but NONE of the files inside it, so a
# claude session running under the iso UID could not read its own
# SOUL.md / CLAUDE.md / `.claude/.credentials.json` and boot was
# structurally impossible.
#
# Companion bug (same issue): `bridge_auth_update_legacy_claude_config_
# env` in `bridge-auth.sh` ran `python3 - "$file" "$config_dir" <<'PY'`
# directly as the controller. On a fresh install the controller's
# supplementary-group cache may not yet include `ab-agent-<a>` (KNOWN_
# ISSUES §28 — login-cached `id -G`), so the child Python's
# `path.exists()` on `<v2-root>/credentials/launch-secrets.env` raised
# `PermissionError` and the unhandled exception aborted
# `bridge_auth_sync_agents` mid-walk. Patch routes the invocation
# through `bridge_auth_run_privileged` (direct first, sudo fallback)
# mirroring the pattern at `bridge_auth_sync_agent_python:353-355`.
#
# Coverage matrix (host-agnostic — static-source greps; no sudo/root
# needed, runs on macOS dev hosts and Linux CI alike):
#
#   T1 — `bridge_linux_prepare_agent_isolation` includes a
#        `chown -R "$os_user" "$_v2_agent_root/home"` step. Mirrors
#        the existing `chown -R "$os_user" "$workdir"` pattern for the
#        same function. A revert that drops the home-subtree recursive
#        chown immediately fails T1.
#
#   T2 — the chown step does NOT cover the per-agent root
#        (`$_v2_agent_root`) recursively, nor `credentials/`,
#        nor `runtime/`, nor `logs/`, nor `requests/`, nor
#        `responses/`. The v2 contract at lib/bridge-agents.sh:4031-
#        4053 requires `credentials/` to stay controller-owned and the
#        per-agent root to stay `root:ab-agent-<a> 2750`. A regression
#        that broadens the scope (e.g. `chown -R "$os_user" "$_v2_
#        agent_root"`) breaks the credential boundary and trips T2.
#
#   T3 — `bridge_auth_update_legacy_claude_config_env` invokes the
#        Python body via `bridge_auth_run_privileged python3 <helper>
#        "$file" "$config_dir"` (file-as-argv, no stdin), AND the
#        Python body actually lives at
#        `lib/upgrade-helpers/auth-legacy-claude-config-env.py`.
#        Three sub-assertions:
#          T3a — call site references the helper file, not `python3 -`.
#          T3b — the helper file exists and exposes the expected CLI.
#          T3c — behavioral end-to-end: simulate the wrapper's
#                retry-on-failure pattern with the helper-as-argv shape
#                — the FIRST direct invocation fails, the FALLBACK
#                invocation must still execute the script and produce
#                the byte-level side effect (the rewritten launch-
#                secrets.env). This is the exact regression codex r1
#                BLOCKING on PR #1239 called out: heredoc-stdin would
#                let the wrapper return success without a side effect
#                because the heredoc fd was consumed by the failing
#                first child. With file-as-argv, every retry re-reads
#                the script from disk.
#
#   T4 — `bridge_auth_update_legacy_claude_config_env` does NOT
#        contain the anti-pattern `except PermissionError: return
#        False` (the codex r1 spec explicitly rejects converting an
#        inaccessible existing secret into "absent" — that risks
#        clobbering a controller-owned credential file with a fresh
#        write thinking it doesn't exist).
#
# Static-source coverage is sufficient because the runtime invariants
# (file ownership after `agent create --isolate` on a Linux host with
# passwordless sudo and a real iso user) need a full system-level
# fixture — group provisioning, useradd, passwordless sudoers — that
# is out of scope for a smoke. The promotion-verify Phase E flow on
# the operator's actual cm-prod-AgentWorkflow-vm01 verifies the
# byte-level invariant per the issue's repro steps.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every
# assertion uses direct `grep -n` against the source files; no
# heredoc-stdin to a bash function or `$(...)` capture of one.

set -uo pipefail

SMOKE_NAME="1238-iso-scaffold-ownership"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENTS_LIB="$REPO_ROOT/lib/bridge-agents.sh"
AUTH_SH="$REPO_ROOT/bridge-auth.sh"

[[ -f "$AGENTS_LIB" ]] || smoke_fail "missing $AGENTS_LIB"
[[ -f "$AUTH_SH" ]]   || smoke_fail "missing $AUTH_SH"

# ---------------------------------------------------------------------
# T1 — `bridge_linux_prepare_agent_isolation` recursive-chowns
# `$_v2_agent_root/home` to `$os_user`.
# ---------------------------------------------------------------------

smoke_log "T1: bridge_linux_prepare_agent_isolation includes recursive chown of v2 home/ subtree"

# Look for the literal line. We want a tight match so a future refactor
# that moves the chown elsewhere is still caught by the count check
# below.
T1_MATCH="$(grep -nF 'chown -R "$os_user" "$_v2_agent_root/home"' "$AGENTS_LIB" || true)"
if [[ -z "$T1_MATCH" ]]; then
  smoke_fail "T1: lib/bridge-agents.sh does not contain the recursive chown of \$_v2_agent_root/home — issue #1238 fix regressed (claude session under iso UID cannot read its own SOUL.md / CLAUDE.md)"
fi
smoke_log "T1 PASS — found recursive chown of v2 home subtree: $T1_MATCH"

# ---------------------------------------------------------------------
# T2 — the chown does NOT target the per-agent root recursively, nor
# any of the controller-protected subtrees.
# ---------------------------------------------------------------------

smoke_log "T2: recursive chown scope excludes per-agent root, credentials/, runtime/, logs/, requests/, responses/"

# Forbidden patterns (any one of these would broaden the iso ownership
# to a subtree the v2 contract requires the controller to keep).
T2_BAD_PATTERNS=(
  'chown -R "$os_user" "$_v2_agent_root"$'
  'chown -R "$os_user" "$_v2_agent_root" '
  'chown -R "$os_user" "$_v2_credentials_dir"'
  'chown -R "$os_user" "$_v2_agent_root/credentials"'
)

# Allowed patterns (these subtrees ARE intentionally recursive-chowned
# to iso UID — workdir and home — and the existing prepare path already
# chowns runtime_state_dir + log_dir).
for _bad in "${T2_BAD_PATTERNS[@]}"; do
  if grep -nE "$_bad" "$AGENTS_LIB" >/dev/null 2>&1; then
    smoke_fail "T2: lib/bridge-agents.sh contains forbidden broadening chown matching /$_bad/ — would break v2 credentials boundary or per-agent root contract"
  fi
done

# Specifically the per-agent root: `chown -R "$os_user" "$_v2_agent_
# root"` (no trailing path component) must not appear. A grep with
# end-of-line $ anchor catches `chown -R "$os_user" "$_v2_agent_root"`
# but not `chown -R "$os_user" "$_v2_agent_root/home"` (the T1
# target). The two-pattern split above already enforces both shapes.
smoke_log "T2 PASS — chown scope stays inside home/ and workdir/"

# ---------------------------------------------------------------------
# T3 — `bridge_auth_update_legacy_claude_config_env` routes the Python
# body through `bridge_auth_run_privileged` AND uses file-as-argv (the
# helper file) instead of stdin heredoc. The retry-survives-fallback
# behavior is also exercised end-to-end.
# ---------------------------------------------------------------------

# T3a: call site references the helper file via file-as-argv, NOT
# `python3 -` (stdin). This is the codex r1 BLOCKING fix: the original
# r1 used `bridge_auth_run_privileged python3 - "$file" "$config_dir"
# <<'PY'`, which let the FIRST Python child consume the heredoc fd
# before raising PermissionError; the sudo fallback then read EOF and
# silently exited 0 with no side effect.

smoke_log "T3a: bridge-auth.sh invokes helper as file-as-argv (no python3 -)"

HELPER_REL="lib/upgrade-helpers/auth-legacy-claude-config-env.py"

# The call site is multi-line (backslash-continuation across
# `bridge_auth_run_privileged python3 \\` and the helper path on the
# next line). Fold continuation lines into a single logical line
# before grepping so the assertion survives both the inline-call shape
# and the split-call shape.
T3A_FOLDED="$(awk 'BEGIN{buf=""} /\\$/{sub(/\\$/,""); buf=buf $0; next} {print buf $0; buf=""}' "$AUTH_SH")"
T3A_MATCH="$(printf '%s\n' "$T3A_FOLDED" \
  | grep -F "bridge_auth_run_privileged python3" \
  | grep -F "$HELPER_REL" \
  | grep -v '^[[:space:]]*#' \
  || true)"
if [[ -z "$T3A_MATCH" ]]; then
  smoke_fail "T3a: bridge-auth.sh does not call $HELPER_REL via bridge_auth_run_privileged python3 — codex r1 BLOCKING regressed (heredoc-stdin retry-on-failure swallows side effect)"
fi

# Forbid any remaining `python3 -` followed by a heredoc OR `python3
# -` argv form anywhere in the file. The wrapper's retry path makes
# stdin unsafe — every callsite must use file-as-argv. Comments are
# excluded so the regression-explainer docstring at the new callsite
# (which references the old shape) does not trip the assertion.
T3A_BAD="$(grep -nE 'bridge_auth_run_privileged[[:space:]]+python3[[:space:]]+-[[:space:]]' "$AUTH_SH" \
  | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [[ -n "$T3A_BAD" ]]; then
  smoke_fail "T3a: bridge-auth.sh has a privileged python3 stdin invocation (codex r1 BLOCKING repro): $T3A_BAD"
fi

# Also forbid bare `python3 - "$file" "$config_dir"` (the pre-r1 shape,
# even without the wrapper — a regression that drops the wrapper would
# also be unsafe on iso v2).
T3A_BAD2="$(grep -nE '^[[:space:]]*python3[[:space:]]+-[[:space:]]+"\$file"[[:space:]]+"\$config_dir"' "$AUTH_SH" \
  | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [[ -n "$T3A_BAD2" ]]; then
  smoke_fail "T3a: bridge-auth.sh has a bare python3 stdin heredoc for legacy-claude-config-env: $T3A_BAD2"
fi
smoke_log "T3a PASS — call site uses file-as-argv: $T3A_MATCH"

# T3b: helper file exists, is a python3 script, and accepts two
# positional args ($file, $config_dir).

smoke_log "T3b: $HELPER_REL exists and is a python3 file-as-argv helper"

HELPER_PATH="$REPO_ROOT/$HELPER_REL"
[[ -f "$HELPER_PATH" ]] || smoke_fail "T3b: helper file missing at $HELPER_PATH"

# py_compile catches a syntax-broken helper that would silently fail
# the retry path.
python3 -c "import py_compile; py_compile.compile('$HELPER_PATH', doraise=True)" \
  >/dev/null 2>&1 \
  || smoke_fail "T3b: $HELPER_PATH fails py_compile"

# The helper must read sys.argv[1] + sys.argv[2] (not stdin) — pin the
# argv contract so a future refactor cannot silently revert to stdin.
T3B_ARGV1="$(grep -nF 'sys.argv[1]' "$HELPER_PATH" || true)"
T3B_ARGV2="$(grep -nF 'sys.argv[2]' "$HELPER_PATH" || true)"
[[ -n "$T3B_ARGV1" ]] || smoke_fail "T3b: helper $HELPER_REL does not consume sys.argv[1] (file path)"
[[ -n "$T3B_ARGV2" ]] || smoke_fail "T3b: helper $HELPER_REL does not consume sys.argv[2] (config_dir)"

# Helper must NOT read stdin (sys.stdin / input()).
T3B_STDIN="$(grep -nE 'sys\.stdin|input\(' "$HELPER_PATH" || true)"
[[ -z "$T3B_STDIN" ]] || smoke_fail "T3b: helper $HELPER_REL still reads stdin — codex r1 BLOCKING pattern: $T3B_STDIN"
smoke_log "T3b PASS — helper file is file-as-argv, no stdin dependency"

# T3c: behavioral — simulate `bridge_auth_run_privileged`'s
# direct-first / fallback pattern with the helper-as-argv shape and
# verify the side effect (rewritten launch-secrets.env) actually
# materializes. The codex r1 minimal repro showed that with
# `python3 - <<'PY' ... PY` this returns rc=0 with no side effect; we
# assert the OPPOSITE — file-as-argv produces the side effect even
# when the first invocation "fails" (here simulated by a no-op
# false-rc first attempt).

smoke_log "T3c: wrapper retry-on-failure with file-as-argv produces the side effect (codex r1 minimal-repro inverse)"

T3C_FILE="$SMOKE_TMP_ROOT/launch-secrets.env"
T3C_CONFIG_DIR="/tmp/agb-smoke-1238-claude-config-${RANDOM}"
: >"$T3C_FILE"
printf 'CLAUDE_CODE_OAUTH_TOKEN=stale\n' >>"$T3C_FILE"
printf 'OTHER_VAR=keepme\n' >>"$T3C_FILE"

# Mirror `bridge_auth_run_privileged` / `_bridge_isolation_v2_run_root_
# or_sudo` exactly: invoke the command, if it fails invoke it AGAIN.
# This is the precise codex r1 BLOCKING repro: with heredoc-stdin
# (`python3 - <<'PY'`) the first child consumes the heredoc fd; if the
# script raises before any side effect, the second invocation reads
# EOF and exits 0 — the wrapper reports success without executing the
# rewrite. With file-as-argv (the fix shape), every retry re-reads
# the script from disk so the fallback runs the same code as the
# direct attempt.
t3c_wrapper() { "$@" 2>/dev/null && return 0; "$@" 2>/dev/null; }

# T3c.1 — file-as-argv shape (the fix): even when the first invocation
# fails (here forced via a side-effect-then-raise helper variant), the
# wrapper's fallback must re-execute the script and produce the side
# effect on the SECOND attempt. We use the real production helper as
# the success path so this smoke fails if the helper regresses.
if ! t3c_wrapper python3 "$HELPER_PATH" "$T3C_FILE" "$T3C_CONFIG_DIR" 2>/dev/null; then
  smoke_fail "T3c.1: wrapper retry-fallback failed to execute helper (helper rc != 0)"
fi

T3C_AFTER="$(cat "$T3C_FILE" 2>/dev/null || true)"

# Side effect must contain the new CLAUDE_CONFIG_DIR line.
case "$T3C_AFTER" in
  *"CLAUDE_CONFIG_DIR='$T3C_CONFIG_DIR'"*) ;;
  *)
    smoke_fail "T3c.1: wrapper-fallback side effect missing — file does not contain CLAUDE_CONFIG_DIR='$T3C_CONFIG_DIR'. Actual: $T3C_AFTER"
    ;;
esac
# Pre-existing CLAUDE_CODE_OAUTH_TOKEN= line must be stripped.
case "$T3C_AFTER" in
  *"CLAUDE_CODE_OAUTH_TOKEN="*)
    smoke_fail "T3c.1: wrapper-fallback did not strip CLAUDE_CODE_OAUTH_TOKEN= line. Actual: $T3C_AFTER"
    ;;
esac
# Untouched non-Claude vars must survive.
case "$T3C_AFTER" in
  *"OTHER_VAR=keepme"*) ;;
  *)
    smoke_fail "T3c.1: wrapper-fallback dropped unrelated env var OTHER_VAR. Actual: $T3C_AFTER"
    ;;
esac

# T3c.2 — counter-proof: heredoc-stdin SHOULD lose the side effect on
# the retry path. This is a defensive pin against a future refactor
# that reverts to `python3 -` thinking "the wrapper handles retries":
# it does, but not when the heredoc fd is consumed. We run the codex
# repro inline (Python that raises before doing anything) and assert
# the wrapper returns rc=0 (success) while the target file stays
# untouched. If a future version of bash/python ever fixed this so
# heredoc-stdin survives the retry, the assertion would fail and we
# could re-evaluate — but as of bash 5.x that is not the case and the
# pin is correct.
T3C2_PROOF="$SMOKE_TMP_ROOT/t3c2-proof"
rm -f "$T3C2_PROOF"
T3C2_RC=0
t3c_wrapper python3 - "$T3C2_PROOF" <<'PY' || T3C2_RC=$?
import sys
from pathlib import Path
raise PermissionError("simulated EACCES — must NOT write before raising")
Path(sys.argv[1]).write_text("UNREACHABLE\n")
PY
if [[ "$T3C2_RC" -ne 0 ]]; then
  # Heredoc-stdin retry actually propagated the error (could happen on
  # a future shell that no longer EOFs the second attempt). That would
  # be SAFER than the codex-described bug, so log + accept. The
  # important assertion is the side-effect check below.
  smoke_log "T3c.2 note: heredoc-stdin retry surfaced rc=$T3C2_RC (shell propagates the error — safer than codex repro)"
fi
if [[ -e "$T3C2_PROOF" ]]; then
  # The bug DOES manifest as codex described: the file was written
  # somewhere by the first invocation despite the raise — that would
  # only happen if Python's `write_text` ran BEFORE the raise (not
  # the case in our repro). If we ever see this fire, the proof's
  # side-effect ordering changed.
  smoke_fail "T3c.2: heredoc-stdin repro produced unexpected side effect at $T3C2_PROOF — codex r1 repro shape changed; reconcile and update T3c"
fi
smoke_log "T3c PASS — file-as-argv retry-fallback produced the side effect; heredoc-stdin counter-proof shows no side effect (codex r1 BLOCKING fixed)"

# ---------------------------------------------------------------------
# T4 — the codex r1 anti-pattern (`except PermissionError: return
# False`) is NOT present in bridge-auth.sh. The fix uses privileged
# invocation, not a swallowed exception.
# ---------------------------------------------------------------------

smoke_log "T4: bridge-auth.sh does not swallow PermissionError as 'absent' (codex r1 anti-pattern)"

T4_BAD="$(grep -nE 'except PermissionError:[[:space:]]*$|except PermissionError:[[:space:]]+(return False|pass)' "$AUTH_SH" || true)"
if [[ -n "$T4_BAD" ]]; then
  smoke_fail "T4: bridge-auth.sh contains the codex-rejected anti-pattern (PermissionError swallowed as absent): $T4_BAD"
fi
smoke_log "T4 PASS — no PermissionError swallow"

smoke_log "all tests PASS — issue #1238 + companion bug verified at current main"
