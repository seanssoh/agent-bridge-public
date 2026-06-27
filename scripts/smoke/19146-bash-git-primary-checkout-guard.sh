#!/usr/bin/env bash
# scripts/smoke/19146-bash-git-primary-checkout-guard.sh — issue #19146.
#
# Verifies the PreToolUse Bash guard that blocks destructive git mutations in
# the operator's PRIMARY checkout from a dispatched-fixer (worktree-confined)
# session (hooks/tool-policy.py::_bash_git_primary_checkout_guard_reason — the
# Bash/git counterpart of the Edit/Write #341 gate). The companion Python
# module-file (file-as-argv — NO heredoc-stdin to a subprocess, footgun #11)
# builds a repo + worktree + symlink fixture under the isolated temp root and
# drives the FULL accumulated bypass matrix against the real guard plus two
# end-to-end handle_pretool assertions.
#
# Allowlist model: a destructive git verb in a confined context is ALLOWED only
# in the canonical safe shape (bare `git <verb>`, no env-wrapper / VAR= prefix /
# -C|--git-dir|--work-tree|--git-common-dir|--chdir redirect flag, cwd-only
# preludes whose REALPATH stays inside the worktree), else fail-closed DENY.
# Operator sessions (cwd = repo root, not under .claude/worktrees) are
# STRUCTURALLY exempt — proven here as the over-block-0 regression set.
#
# Host-independent: the guard resolves entirely from the in-process payload cwd
# + os.path.realpath of the fixture paths (no git subprocess, no Linux/sudo/iso
# requirement), so this runs on macOS and Linux alike.

set -euo pipefail

SMOKE_NAME="19146-bash-git-primary-checkout-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT INT TERM

# Isolated v2 layout: exports BRIDGE_HOME, BRIDGE_AUDIT_LOG, SMOKE_TMP_ROOT, etc.
smoke_setup_bridge_home "$SMOKE_NAME"

# The guard is cwd-derived; ensure the hook resolves HOME-anchored aliases
# against the fixture, not the operator's real $HOME.
export HOME="$BRIDGE_HOME"

smoke_log "fixture: SMOKE_TMP_ROOT=$SMOKE_TMP_ROOT (repo + worktree + symlink)"

OUT="$(BRIDGE_AGENT_ID="fixer" PYTHONPATH="$SMOKE_REPO_ROOT/hooks" \
  python3 "$SCRIPT_DIR/19146-bash-git-primary-checkout-guard.py" \
    "$SMOKE_REPO_ROOT" "$SMOKE_TMP_ROOT" 2>&1)" || {
  printf '%s\n' "$OUT" >&2
  smoke_fail "bash git primary-checkout guard assertions FAILED"
}
printf '%s\n' "$OUT"
smoke_assert_contains "$OUT" "[smoke:19146] PASS" "bash git primary-checkout guard"

smoke_log "PASS — #19146 destructive-git primary-checkout guard verified"
