#!/usr/bin/env bash

# Issue #872: bridge_cleanup_render_summary previously surfaced
# json.JSONDecodeError verbatim ("Could not parse cleanup payload:
# Expecting value: line 1 column 1 (char 0)") into the
# [upgrade-complete] task body when the cleanup helper returned empty
# stdout on a successful exit. Lock the contract that:
#   T1: empty stdin renders a friendly noop block, not the raw
#       exception text;
#   T2: invalid JSON stdin renders a generic placeholder, not the raw
#       exception text;
#   T3: valid JSON stdin still renders the structured summary block.

set -euo pipefail

SMOKE_NAME="cleanup-payload-empty-stdin-872"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap 'smoke_cleanup_temp_root' EXIT

smoke_require_cmd python3
smoke_require_cmd bash

CLEANUP_LIB="$SMOKE_REPO_ROOT/lib/bridge-cleanup.sh"
[[ -f "$CLEANUP_LIB" ]] || smoke_fail "missing $CLEANUP_LIB"

smoke_make_temp_root "$SMOKE_NAME"

# Wrap bridge_cleanup_render_summary in a sourced shell so the function
# under test runs in the same Bash environment the upgrader uses.
render() {
  bash -c "set -euo pipefail; source '$CLEANUP_LIB'; bridge_cleanup_render_summary"
}

# T1: empty stdin must not leak json.JSONDecodeError text.
T1_OUT="$(printf '' | render)"
case "$T1_OUT" in
  *"Expecting value"*|*"JSONDecodeError"*|*"Could not parse cleanup payload"*)
    smoke_fail "T1: empty stdin still leaks raw exception text: $T1_OUT"
    ;;
esac
case "$T1_OUT" in
  *"## Backup residue cleanup"*) ;;
  *) smoke_fail "T1: empty stdin output missing section header: $T1_OUT" ;;
esac
smoke_log "T1 ok — empty stdin renders friendly noop block"

# T2: invalid JSON must not leak the raw exception text either.
T2_OUT="$(printf 'not-json-at-all' | render)"
case "$T2_OUT" in
  *"Expecting value"*|*"JSONDecodeError"*|*"Could not parse cleanup payload"*)
    smoke_fail "T2: invalid JSON still leaks raw exception text: $T2_OUT"
    ;;
esac
case "$T2_OUT" in
  *"## Backup residue cleanup"*) ;;
  *) smoke_fail "T2: invalid JSON output missing section header: $T2_OUT" ;;
esac
smoke_log "T2 ok — invalid JSON renders generic placeholder"

# T3: valid JSON renders the structured summary block.
VALID_JSON='{
  "stale_tmp_removed": ["a"],
  "daily_pruned": [],
  "snapshots_pruned": [],
  "upgrade_backups": {"pruned": [], "preserved": []},
  "claude_config": {"status": "ok"},
  "cleanup_failures": [],
  "bytes_freed_human": "1.2 KB",
  "free_bytes_before_human": "10 GB",
  "free_bytes_after_human": "10 GB"
}'
T3_OUT="$(printf '%s' "$VALID_JSON" | render)"
case "$T3_OUT" in
  *"Stale "*"reaped: **1**"*) ;;
  *) smoke_fail "T3: valid JSON output missing stale count line: $T3_OUT" ;;
esac
case "$T3_OUT" in
  *"Disk free before"*"1.2 KB"*) ;;
  *) smoke_fail "T3: valid JSON output missing freed bytes line: $T3_OUT" ;;
esac
smoke_log "T3 ok — valid JSON renders structured summary"

smoke_log "PASS"
