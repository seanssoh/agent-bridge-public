#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1820-settings-v2-render-symlink.sh — Issue #1820 (writer 3).
#
# Per-agent effective settings rendered to the v1 root
# (`$BRIDGE_AGENT_HOME_ROOT/<a>/.claude/settings.effective.json`) and every v2
# workdir's `.claude/settings.json` symlink pointed into v1 — making the v1 tree
# load-bearing for every session launch.
#
# Verdict gate (writer-3 symlink handling): render the per-agent effective
# settings at the v2 layout-resolved home FIRST, atomically retarget the workdir
# `.claude/settings.json` symlink toward the v2 effective file, and keep the v1
# effective file as NON-load-bearing rollback evidence (do NOT remove it).
#
# Asserts (drives bridge_link_claude_settings_to_shared with v2 active):
#   T1 — the workdir settings.json symlink RESOLVES to the v2 effective file
#        (`$BRIDGE_AGENT_ROOT_V2/<a>/home/.claude/settings.effective.json`).
#   T2 — the symlink does NOT resolve into the v1 tree
#        (`$BRIDGE_AGENT_HOME_ROOT/<a>/...`).
#   T3 — the v2 effective file exists and preserved a pre-existing user key.
#   T4 — the v1 effective file is rendered as rollback evidence but nothing
#        symlinks to it (non-load-bearing).

set -uo pipefail
SMOKE_NAME="1820-settings-v2-render-symlink"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  [[ -x /opt/homebrew/bin/bash ]] && BRIDGE_BASH=/opt/homebrew/bin/bash
  [[ -x /usr/local/bin/bash ]] && BRIDGE_BASH="${BRIDGE_BASH:-/usr/local/bin/bash}"
fi

smoke_setup_bridge_home "$SMOKE_NAME"

AGENT="acme"
# A v2-non-iso managed agent: workdir lives UNDER the v1 HOME_ROOT so
# bridge_claude_settings_mode resolves "shared"; v2 home is the resolver target.
WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$AGENT"
V2_HOME="$BRIDGE_AGENT_ROOT_V2/$AGENT/home"
V2_EFFECTIVE="$V2_HOME/.claude/settings.effective.json"
V1_EFFECTIVE="$BRIDGE_AGENT_HOME_ROOT/$AGENT/.claude/settings.effective.json"
WORKDIR_LINK="$WORKDIR/.claude/settings.json"
mkdir -p "$WORKDIR/.claude" "$V2_HOME/.claude"

# Base install-wide settings + an operator overlay (settings.local.json) the
# renderer must fold into the effective output (the legitimate user/operator
# key surface). A pre-existing workdir settings.json is replaced by the symlink.
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/.claude"
printf '{"model":"sonnet"}\n' >"$BRIDGE_AGENT_HOME_ROOT/.claude/settings.json"
printf '{"env":{"USER_KEEP":"yes"}}\n' >"$BRIDGE_AGENT_HOME_ROOT/.claude/settings.local.json"
printf '{"env":{"WORKDIR_OLD":"x"}}\n' >"$WORKDIR_LINK"

DRIVER="$SMOKE_TMP_ROOT/driver.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf 'cd %q\n' "$REPO_ROOT"
  printf 'source %q >/dev/null 2>&1\n' "$REPO_ROOT/bridge-lib.sh"
  printf '%s\n' 'bridge_reset_roster_maps 2>/dev/null || true'
  printf 'AGENT=%q\n' "$AGENT"
  printf 'WORKDIR=%q\n' "$WORKDIR"
  printf '%s\n' 'BRIDGE_AGENT_IDS=("$AGENT")'
  printf '%s\n' 'BRIDGE_AGENT_SOURCE[$AGENT]="static"'
  # v2 active, non-iso (no isolation mode recorded).
  printf '%s\n' 'bridge_link_claude_settings_to_shared "$WORKDIR" "" "$AGENT" || true'
} >"$DRIVER"
chmod +x "$DRIVER"
"$BRIDGE_BASH" "$DRIVER" >"$SMOKE_TMP_ROOT/driver.out" 2>&1 || true

resolve() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# T1 — workdir symlink resolves to the v2 effective file.
[[ -L "$WORKDIR_LINK" ]] || { cat "$SMOKE_TMP_ROOT/driver.out" >&2; smoke_fail "T1 FAIL: workdir settings.json is not a symlink"; }
RESOLVED="$(resolve "$WORKDIR_LINK")"
EXPECT_V2="$(resolve "$V2_EFFECTIVE")"
smoke_log "symlink resolves to: $RESOLVED"
[[ "$RESOLVED" == "$EXPECT_V2" ]] || { cat "$SMOKE_TMP_ROOT/driver.out" >&2; smoke_fail "T1 FAIL: symlink -> '$RESOLVED', expected v2 '$EXPECT_V2'"; }
smoke_log "T1 PASS: workdir settings.json symlink resolves to v2 effective file"

# T2 — symlink does NOT resolve into the v1 agent tree.
case "$RESOLVED" in
  "$BRIDGE_AGENT_HOME_ROOT/$AGENT/.claude/"*)
    smoke_fail "T2 FAIL: symlink still resolves into the v1 tree: $RESOLVED" ;;
esac
smoke_log "T2 PASS: symlink no longer load-bearing on the v1 tree"

# T3 — v2 effective file exists and preserved the user key.
smoke_assert_file_exists "$V2_EFFECTIVE" "T3 v2 effective file"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
env=d.get("env",{})
assert env.get("USER_KEEP")=="yes", f"user key not preserved: {d}"
' "$V2_EFFECTIVE" || smoke_fail "T3 FAIL: v2 effective did not preserve the user key"
smoke_log "T3 PASS: v2 effective rendered + user key preserved"

# T4 — v1 effective rendered as rollback evidence, but nothing symlinks to it.
smoke_assert_file_exists "$V1_EFFECTIVE" "T4 v1 rollback-evidence file"
[[ "$RESOLVED" != "$(resolve "$V1_EFFECTIVE")" ]] || smoke_fail "T4 FAIL: a live symlink still resolves to the v1 evidence file"
smoke_log "T4 PASS: v1 effective kept as non-load-bearing rollback evidence"

smoke_log "all settings v2 render+symlink tests PASS (#1820)"
