#!/usr/bin/env bash
# Issue #1021 regression smoke — isolation-v2 apply must not mutate shared
# plugin material.
#
# Bug: `bridge_isolation_v2_chgrp_setgid_recursive` (driven by the
# isolation-v2 reapply path at lib/bridge-isolation-v2-reapply.sh:401-435)
# recursively chgrp/chmod's an isolated agent's writable subtrees. When a
# shared plugin dependency tree (e.g. `plugins/teams/node_modules`) is
# reachable inside that subtree, the recursive pass re-grouped it to the
# target agent's private `ab-agent-<name>` group and dropped world/group
# read — which broke every OTHER isolated agent that loads the same
# shared plugin source.
#
# Fix: the helper learned `--exclude-path <abs-path>` and the reapply
# caller fences the shared plugin roots out of the recursion.
#
# Two-agent shared-plugin fixture (codex r1 acceptance):
#   - a shared plugin `node_modules` tree both agents reference,
#   - isolated agent A whose writable subtree reaches the shared tree,
#   - run the recursive apply for agent A with the shared-tree exclusion,
#   - assert the shared tree's group + mode are UNCHANGED,
#   - assert the agent's own tree WAS re-grouped/re-moded,
#   - assert a second isolated agent B can still read the shared file.
#
# Observability: the helper's chgrp/chmod runs rootless against the
# caller's own files; mode is the deterministic signal here (group on a
# rootless host can only be the caller's groups). The exclude-path prune
# is verified by the shared tree keeping its pre-apply mode while the
# agent tree flips to the v2 contract mode.
#
# Footgun #11 (Bash 5.3.9 heredoc-class deadlock): all driver bodies are
# emitted via printf-to-file — no heredocs, no here-strings.

set -uo pipefail

SMOKE_NAME="1021-isolation-v2-shared-plugin-perms"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# --- Fixture ---------------------------------------------------------
# Layout:
#   $FIX/agent-A-workdir/                  agent A's recursive-repair root
#     plugins/teams/node_modules/debug/    SHARED plugin tree (must not move)
#       package.json
#     own/agent-private.txt                agent A's own file (must move)
#   $FIX/agent-B-marker/can-read           agent B read-probe target
FIX="$SMOKE_TMP_ROOT/fixture"
SHARED_PLUGINS="$FIX/agent-A-workdir/plugins"
SHARED_NM="$SHARED_PLUGINS/teams/node_modules/debug"
AGENT_OWN="$FIX/agent-A-workdir/own"
mkdir -p "$SHARED_NM" "$AGENT_OWN"

SHARED_FILE="$SHARED_NM/package.json"
AGENT_FILE="$AGENT_OWN/agent-private.txt"
printf '{"name":"debug"}\n' >"$SHARED_FILE"
printf 'agent A private state\n' >"$AGENT_FILE"

# Pre-apply baseline: shared material is world/group-readable (0644 files,
# 0755 dirs) — the `ab-shared` contract. The agent-private file starts at
# the same baseline so the only thing that can change it is the apply.
chmod 0755 "$SHARED_PLUGINS" "$SHARED_PLUGINS/teams" \
  "$SHARED_PLUGINS/teams/node_modules" "$SHARED_NM"
chmod 0644 "$SHARED_FILE"
chmod 0755 "$AGENT_OWN"
chmod 0644 "$AGENT_FILE"

SHARED_FILE_MODE_BEFORE="$(stat -c '%a' "$SHARED_FILE" 2>/dev/null || stat -f '%Lp' "$SHARED_FILE")"
SHARED_DIR_MODE_BEFORE="$(stat -c '%a' "$SHARED_NM" 2>/dev/null || stat -f '%Lp' "$SHARED_NM")"

# --- Driver: run the recursive helper with --exclude-path -------------
DRIVER="$SMOKE_TMP_ROOT/driver.sh"
OUT="$SMOKE_TMP_ROOT/driver.out"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf 'cd %q\n' "$REPO_ROOT"
  # Force isolation enforcement so the helper actually runs on a macOS
  # dev host (bridge_isolation_v2_enforce returns 1 on non-Linux without
  # this, and the helper would early-return 0 as a no-op).
  printf '%s\n' 'export BRIDGE_ISOLATION_REQUIRED=yes'
  printf '%s\n' 'export _BRIDGE_ISOLATION_PRIMITIVES_READY_CACHED=yes'
  printf '%s\n' 'bridge_warn() { printf "[stub_warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_die() { printf "[stub_die] %s\n" "$*" >&2; exit 1; }'
  printf '%s\n' 'source "$0_REPO_ROOT/lib/bridge-isolation-v2.sh" 2>&1'
  # The agent's recursive-repair root is its workdir. The shared plugin
  # tree lives inside it (the #1021 vector). Without --exclude-path the
  # recursion would re-group/re-mode the shared tree; with it, the
  # shared tree must be left untouched.
  printf 'AGENT_WORKDIR=%q\n' "$FIX/agent-A-workdir"
  printf 'SHARED_PLUGINS=%q\n' "$SHARED_PLUGINS"
  printf '%s\n' 'CALLER_GROUP="$(id -gn)"'
  printf '%s\n' 'if bridge_isolation_v2_chgrp_setgid_recursive "$CALLER_GROUP" 2770 0660 "$AGENT_WORKDIR" --exclude-path "$SHARED_PLUGINS"; then echo "HELPER_RC=0"; else echo "HELPER_RC=$?"; fi'
} | sed "s#\$0_REPO_ROOT#$REPO_ROOT#g" >"$DRIVER"
chmod +x "$DRIVER"
"$BRIDGE_BASH" "$DRIVER" >"$OUT" 2>&1 || true
rm -f "$DRIVER"

grep -q '^HELPER_RC=0$' "$OUT" || {
  cat "$OUT"
  smoke_fail "recursive helper returned non-zero with --exclude-path"
}
smoke_log "helper ran rc=0 with --exclude-path"

# --- Assertion 1: shared plugin tree is UNCHANGED ---------------------
SHARED_FILE_MODE_AFTER="$(stat -c '%a' "$SHARED_FILE" 2>/dev/null || stat -f '%Lp' "$SHARED_FILE")"
SHARED_DIR_MODE_AFTER="$(stat -c '%a' "$SHARED_NM" 2>/dev/null || stat -f '%Lp' "$SHARED_NM")"

if [[ "$SHARED_FILE_MODE_AFTER" != "$SHARED_FILE_MODE_BEFORE" ]]; then
  cat "$OUT"
  smoke_fail "shared plugin file mode changed ($SHARED_FILE_MODE_BEFORE -> $SHARED_FILE_MODE_AFTER) — apply recursed into shared material"
fi
if [[ "$SHARED_DIR_MODE_AFTER" != "$SHARED_DIR_MODE_BEFORE" ]]; then
  cat "$OUT"
  smoke_fail "shared plugin dir mode changed ($SHARED_DIR_MODE_BEFORE -> $SHARED_DIR_MODE_AFTER) — apply recursed into shared material"
fi
smoke_log "shared plugin node_modules tree left untouched (file=$SHARED_FILE_MODE_AFTER dir=$SHARED_DIR_MODE_AFTER)"

# --- Assertion 2: the agent's own tree WAS re-moded -------------------
# The v2 file contract chmod is exec-aware symbolic (g+rwX,o-rwx); a
# plain-text file at 0644 lands at 0660 (group write, no other bits).
AGENT_FILE_MODE_AFTER="$(stat -c '%a' "$AGENT_FILE" 2>/dev/null || stat -f '%Lp' "$AGENT_FILE")"
if [[ "$AGENT_FILE_MODE_AFTER" == "644" ]]; then
  cat "$OUT"
  smoke_fail "agent-private file mode unchanged ($AGENT_FILE_MODE_AFTER) — recursive apply did not run on the agent tree (exclude-path over-pruned)"
fi
case "$AGENT_FILE_MODE_AFTER" in
  660|*60)
    smoke_log "agent's own file was re-moded by the apply ($AGENT_FILE_MODE_AFTER)"
    ;;
  *)
    cat "$OUT"
    smoke_fail "agent-private file unexpected mode after apply: $AGENT_FILE_MODE_AFTER (expected v2 contract g+rw, o-rwx)"
    ;;
esac

# --- Assertion 3: a second agent can still read the shared file -------
# Agent B is modeled by the world/group-read contract surviving on the
# shared tree. On a rootless host the strongest portable check is that
# the shared file is still readable (its mode kept the read bits a
# different-UID process needs). Assert the `other` read bit is intact.
case "$SHARED_FILE_MODE_AFTER" in
  *4|*5|*6|*7)
    smoke_log "agent B read contract intact — shared file keeps other-read ($SHARED_FILE_MODE_AFTER)"
    ;;
  *)
    cat "$OUT"
    smoke_fail "shared file lost the other-read bit ($SHARED_FILE_MODE_AFTER) — agent B can no longer load shared plugin material"
  ;;
esac
test -r "$SHARED_FILE" || smoke_fail "shared plugin file is not readable after apply"

# --- Assertion 4: control — without --exclude-path the shared tree IS
# mutated (proves the smoke actually exercises the prune, not a no-op).
CTRL_FIX="$SMOKE_TMP_ROOT/control"
CTRL_NM="$CTRL_FIX/workdir/plugins/teams/node_modules/debug"
mkdir -p "$CTRL_NM"
CTRL_SHARED_FILE="$CTRL_NM/package.json"
printf '{"name":"debug"}\n' >"$CTRL_SHARED_FILE"
chmod 0644 "$CTRL_SHARED_FILE"

CTRL_DRIVER="$SMOKE_TMP_ROOT/ctrl-driver.sh"
CTRL_OUT="$SMOKE_TMP_ROOT/ctrl-driver.out"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf 'cd %q\n' "$REPO_ROOT"
  printf '%s\n' 'export BRIDGE_ISOLATION_REQUIRED=yes'
  printf '%s\n' 'export _BRIDGE_ISOLATION_PRIMITIVES_READY_CACHED=yes'
  printf '%s\n' 'bridge_warn() { printf "[stub_warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_die() { printf "[stub_die] %s\n" "$*" >&2; exit 1; }'
  printf '%s\n' 'source "$0_REPO_ROOT/lib/bridge-isolation-v2.sh" 2>&1'
  printf 'CTRL_WORKDIR=%q\n' "$CTRL_FIX/workdir"
  printf '%s\n' 'CALLER_GROUP="$(id -gn)"'
  printf '%s\n' 'bridge_isolation_v2_chgrp_setgid_recursive "$CALLER_GROUP" 2770 0660 "$CTRL_WORKDIR" >/dev/null 2>&1 || true'
  printf '%s\n' 'echo "CTRL_DONE=1"'
} | sed "s#\$0_REPO_ROOT#$REPO_ROOT#g" >"$CTRL_DRIVER"
chmod +x "$CTRL_DRIVER"
"$BRIDGE_BASH" "$CTRL_DRIVER" >"$CTRL_OUT" 2>&1 || true
rm -f "$CTRL_DRIVER"

CTRL_MODE_AFTER="$(stat -c '%a' "$CTRL_SHARED_FILE" 2>/dev/null || stat -f '%Lp' "$CTRL_SHARED_FILE")"
if [[ "$CTRL_MODE_AFTER" == "644" ]]; then
  cat "$CTRL_OUT"
  smoke_fail "control case: recursive helper did not mutate the tree at all — smoke is not exercising the code path"
fi
smoke_log "control confirmed — without --exclude-path the shared file IS mutated ($CTRL_MODE_AFTER), so the prune is the load-bearing guard"

smoke_log "PASS — isolation-v2 apply scopes recursive perm changes away from shared plugin material (#1021)"
exit 0
