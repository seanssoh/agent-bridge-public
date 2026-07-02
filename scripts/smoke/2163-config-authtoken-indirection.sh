#!/usr/bin/env bash
# scripts/smoke/2163-config-authtoken-indirection.sh — issue #2163
# (Security-Cycle-A PR 2/3: tight config / auth-token backstop).
#
# Drives the companion Python unit layer for the two hardened surfaces in
# hooks/tool-policy.py:
#
#   F3  — `_bridge_home_is_test_temp` inspects BRIDGE_HOME PLUS every
#         explicitly-set runtime-identity anchor (BRIDGE_RUNTIME_CONFIG_FILE /
#         BRIDGE_STATE_DIR / BRIDGE_RUNTIME_ROOT). A split-root spoof (home
#         temp, another anchor LIVE) no longer reads as "sandbox".
#   C4a/C4b/C6 — `_config_mutation_via_indirection` denies an AUTH-TOKEN
#         mutation hidden behind eval / a `-c` shell (the full interpreter set)
#         / an unresolved `$var`, symmetric with the #1738 config gate, while
#         `global-auth-sync status` (read-only) stays ALLOWED.
#
# The Python module-file is invoked file-as-argv (SMOKE_TMP_ROOT passed as
# argv[1]) — NO heredoc-stdin to a subprocess (footgun #11 / lint-heredoc-ban).
# Host-independent: the predicates resolve entirely in-process from os.environ
# + os.path.realpath, no git/tmux/sudo/iso requirement, so this runs on macOS
# and Linux alike.

set -euo pipefail

SMOKE_NAME="2163-config-authtoken-indirection"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT INT TERM

# Isolated v2 layout: exports BRIDGE_HOME, SMOKE_TMP_ROOT, etc. The Python layer
# manipulates its OWN env anchors per-case (save/restore); the only thing it
# needs from here is a real temp root whose realpath sits under a fixed temp
# prefix (SMOKE_TMP_ROOT), for the F3 sandbox-positive cases.
smoke_setup_bridge_home "$SMOKE_NAME"

smoke_log "fixture: SMOKE_TMP_ROOT=$SMOKE_TMP_ROOT (F3 sandbox-positive root)"

OUT="$(BRIDGE_AGENT_ID="fixer" PYTHONPATH="$SMOKE_REPO_ROOT/hooks" \
  python3 "$SCRIPT_DIR/2163-config-authtoken-indirection.py" \
    "$SMOKE_TMP_ROOT" 2>&1)" || {
  printf '%s\n' "$OUT" >&2
  smoke_fail "config/auth-token indirection + F3 assertions FAILED"
}
printf '%s\n' "$OUT"
smoke_assert_contains "$OUT" "[smoke:2163] PASS" "config/auth-token indirection guard"

smoke_log "PASS — #2163 config/auth-token indirection backstop + F3 verified"
