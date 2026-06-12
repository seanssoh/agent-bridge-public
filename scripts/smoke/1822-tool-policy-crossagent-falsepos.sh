#!/usr/bin/env bash
# scripts/smoke/1822-tool-policy-crossagent-falsepos.sh — issue #1822.
#
# Sets up an isolated BRIDGE_HOME fixture with ONE peer agent (`worker`) in the
# legacy (`$BRIDGE_AGENT_HOME_ROOT/worker`) tree, plus a shared/wiki page and a
# shared/secrets file, then drives the cross-agent gate assertions in the
# companion Python module-file (file-as-argv — NO heredoc-stdin to a
# subprocess, footgun #11). Covers the #1822 false-positive corrections —
# balanced-backtick unwrap (Fix 1b), component-wise glob containment (Fix 2),
# obfuscation message (Fix 3), admin Bash WRITE parity #1711 (Fix 4), md5
# read-intent (Fix 5), and the QUOTED-heredoc BODY exclusion (Fix 6, codex
# re-review of PR #1838). Fix 6 carries DENY teeth for every smuggle route the
# body exclusion must NOT open: unquoted/expanding delimiter, unbalanced
# marker, multi-EOF payload, and a protected redirect TARGET.
#
# Scope: #1822 false positives ONLY. The v2 peer-home CONTAINMENT gap is issue
# #1823, owned by PR #1831 — its coverage lives in
# scripts/smoke/1823-v2-peer-home-containment.sh and is NOT duplicated here.
#
# Host-independent: no Linux/sudo/iso requirement — the gate logic resolves
# entirely from the exported BRIDGE_* fixture paths, so this runs on macOS and
# Linux alike (unlike the OS-permission `v2-cross-class-read.sh`).

set -euo pipefail

SMOKE_NAME="1822-tool-policy-crossagent-falsepos"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT INT TERM

# Isolated v2 layout: exports BRIDGE_HOME, BRIDGE_AGENT_HOME_ROOT,
# BRIDGE_DATA_ROOT, BRIDGE_AGENT_ROOT_V2, BRIDGE_AUDIT_LOG, etc.
smoke_setup_bridge_home "$SMOKE_NAME"

PEER="worker"

# Legacy peer home (the tree the cross-agent gate covers).
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$PEER"
: >"$BRIDGE_AGENT_HOME_ROOT/$PEER/CLAUDE.md"
: >"$BRIDGE_AGENT_HOME_ROOT/$PEER/MEMORY.md"

# Shared trees referenced by the assertions.
mkdir -p "$BRIDGE_SHARED_DIR/wiki" "$BRIDGE_SHARED_DIR/secrets"
: >"$BRIDGE_SHARED_DIR/wiki/operating-rules.md"
: >"$BRIDGE_SHARED_DIR/secrets/token.txt"

# A couple of top-level *.sh files so the `<bridge>/*.sh` glob has real targets.
: >"$BRIDGE_HOME/bridge-core.sh"
: >"$BRIDGE_HOME/bridge-tmux.sh"

# admin id for the carve-out gates; the calling agent class for the driver's
# non-admin paths is the default ("user").
export BRIDGE_ADMIN_AGENT_ID="admin"
# Ensure the hook resolves HOME-anchored aliases against the fixture, not the
# operator's real $HOME.
export HOME="$BRIDGE_HOME"

# Controller-roster snapshot (the strict-predicate test seam). The #1711 admin
# Bash peer-home WRITE parity (Fix 4 / Fix 6a) is a cross-agent MUTATION, so —
# per #1806 — it gates on the STRICT `trusted_admin` predicate, not the
# spoofable loose `admin` OR-leg. Inject a controller-published roster naming
# `admin` as the admin static role (and the peers as non-admin) so the genuine
# admin's peer-WRITE is trusted; a SESSION-TYPE/env-only spoofer with no such
# roster row stays NON-admin and its peer write is DENIED (covered end-to-end by
# scripts/smoke/1806-admin-guard-allow-audit.sh Tooth 1). Honored only because
# BRIDGE_HOME resolves under a temp prefix; inert in production.
ROSTER_JSON="$SMOKE_TMP_ROOT/controller-roster.json"
printf -- '%s\n' \
  '[' \
  '  {"agent": "admin", "admin": true, "source": "static"},' \
  '  {"agent": "worker", "admin": false, "source": "static"},' \
  '  {"agent": "intruder", "admin": false, "source": "dynamic"}' \
  ']' \
  >"$ROSTER_JSON"
export BRIDGE_GUARD_ADMIN_ROSTER_JSON="$ROSTER_JSON"

smoke_log "fixture: BRIDGE_HOME=$BRIDGE_HOME peer=$PEER (legacy tree)"

OUT="$(BRIDGE_AGENT_ID="$PEER" PYTHONPATH="$SMOKE_REPO_ROOT/hooks" \
  python3 "$SCRIPT_DIR/1822-tool-policy-crossagent-falsepos.py" \
    "$SMOKE_REPO_ROOT" "$BRIDGE_HOME" "$BRIDGE_DATA_ROOT" 2>&1)" || {
  printf '%s\n' "$OUT" >&2
  smoke_fail "tool-policy cross-agent assertions FAILED"
}
printf '%s\n' "$OUT"
smoke_assert_contains "$OUT" "[smoke:1822] PASS" "tool-policy cross-agent fixes"

smoke_log "PASS — #1822 cross-agent false-positive corrections verified"
