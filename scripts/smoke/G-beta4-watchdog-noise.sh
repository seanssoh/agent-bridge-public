#!/usr/bin/env bash
# scripts/smoke/G-beta4-watchdog-noise.sh — issues #1266 + #1270 + #1254
# (v0.15.0-beta4 Lane G watchdog-noise + scan_error cleanup wave).
#
# Background. Three operator-UX bugs in the same drift-task family
# converged during the patch@cm-prod-agentworkflow-vm01 fresh-install on
# 2026-05-27:
#
#   #1266 — Fresh install's very first watchdog tick filed
#           `[watchdog] agent profile drift (onboarding_state=pending)`
#           at priority=high into the admin inbox. SESSION-TYPE.md was
#           legitimately at `Onboarding State: pending` (the admin
#           template default — the admin must walk the operator through
#           onboarding before flipping it). High-priority OOTB alert as
#           the first impression.
#   #1270 — Isolated workdir's CLAUDE.md ended up group=controller-user
#           mode 0600 (vs every other iso file's group=ab-agent-<a>
#           mode 0660). Controller-side `grep` on CLAUDE.md emitted
#           `Permission denied` warnings during agent start.
#   #1254 — Mid-restart agents and controller-side stale-supp-group
#           cache misses both surfaced as `status=scan_error,
#           error_kind=permission_denied`, drowning real iso-UID-side
#           drift in noise.
#
# Lane G ships the watchdog-side resolution: fresh-install drift gets
# priority=low, restart-in-progress agents get drift suppressed, and
# scan_error rows split into two operator-actionable buckets. Lane G
# also wires bridge-init.sh to drop the onboarding-pending marker so
# the watchdog has a fresh-install signal to read.
#
# Cases (all run in an isolated BRIDGE_HOME via scripts/smoke/lib.sh —
# never touches live runtime). Every case asserts via a python helper
# (no heredoc-stdin to subprocess; footgun #11 mitigation).
#
#   T1. #1266 — fresh-install onboarding drift is `priority=low`
#       upstream signal. With the `onboarding-pending` marker in
#       state/agents/<a>/, the watchdog JSON payload's
#       `fresh_install_only=true` and the per-row `fresh_install=true`.
#       The daemon's drift task writer reads `fresh_install_only` and
#       sets priority=low; the same payload with an `onboarding-complete`
#       marker (or no marker on an old agent home) yields
#       `fresh_install_only=false`.
#
#   T2. #1266 — static session_type suppresses the `onboarding_state`
#       line in the markdown render. The JSON payload still carries the
#       parsed value (so downstream consumers can read it), but the
#       markdown body the operator sees in `shared/watchdog/latest.md`
#       does NOT show the always-`complete` row.
#
#   T3. #1270 — `bridge_isolation_v2_normalize_workdir_profile_group`
#       chgrps + chmods each materialized profile file under workdir/.
#       Stub the v2-enforce gate ON and the agent-group resolver to a
#       writable per-test group; verify CLAUDE.md / SOUL.md / etc. all
#       land at the iso group + mode 0660 after one normalize call.
#
#   T4. #1270 — the normalize helper is a no-op on non-Linux hosts /
#       shared-mode agents (`bridge_isolation_v2_enforce` returns
#       non-zero). Stub the enforce gate OFF; assert the file group +
#       mode are UNCHANGED so a macOS / shared-mode install never
#       touches its files.
#
#   T5. #1254 — `restart.in-progress` marker active in state/agents/<a>/
#       suppresses drift entirely. The watchdog JSON shows
#       `restart_in_progress=true` on the row AND the payload's
#       `problem_count` is 0 (the effective problem set excludes
#       restart-in-progress agents). The daemon's drift-task writer
#       short-circuits on problem_count=0.
#
#   T6. #1254 — scan_error splits into `controller-cache-stale` vs
#       `iso-uid-side`. A workdir that the controller can stat (parent
#       traversable) but not read inside → category=controller-cache-
#       stale. A workdir whose ancestor is mode 0000 (controller cannot
#       stat the workdir at all) → category=iso-uid-side.
#
#   T7. #1266 — bridge-init.sh's `bridge_init_write_onboarding_marker`
#       writes `state/agents/<admin>/onboarding-pending` with the
#       expected schema (agent / written / reason). Idempotent — a
#       re-invocation refreshes the timestamp without erroring.
#
#   T8 / T9 (r2 codex r1 BLOCKING #1) — detect_fresh_install
#       precedence + pending-marker TTL across 5 cases (A-E): complete-
#       marker precedence, SESSION-TYPE auto-detect, pending TTL
#       active, pending TTL expired, pending + SESSION-TYPE complete.
#
#   T10 (r2 codex r1 BLOCKING #1) — bridge_init_write_onboarding_
#       complete_marker schema + pending sibling cleanup + dry-run skip.
#
#   T_no_marker_no_session_recent_home (r3 codex r2 BLOCKING quiet-by-
#       default — Case F) — no markers, no SESSION-TYPE.md, recent
#       home mtime → fresh_install=False. Pre-r3 the home-mtime
#       fallthrough returned True here on every recent home,
#       silently demoting legitimate drift on legacy installs to
#       priority=low.
#
#   T_malformed_pending (r3 codex r2 BLOCKING quiet-by-default —
#       Case G) — pending marker exists but `written` field missing /
#       unparseable + recent home → fresh_install=False. A pending
#       marker we cannot parse is NOT a valid positive signal. Pre-r3
#       this fell through to the mtime branch.
#
# Teeth (regression-revert simulation):
#
#   T1-teeth. Re-read the same payload after rewriting it to
#             `fresh_install_only=false`; the daemon helper must return
#             `0` (no priority downgrade). Proves the helper actually
#             gates on the field and is not just printing `1`.
#   T3-teeth. Force the v2-enforce gate ON but stub the agent-group
#             resolver to return empty; assert the normalize helper
#             returns 0 (the "no group resolvable" no-op path) and the
#             file's group is unchanged. Proves the chgrp/chmod is
#             actually gated on a resolvable group, not silently
#             applied with an empty value.
#   T_no_marker_no_session_recent_home / T_malformed_pending teeth
#             (r3 codex r2 BLOCKING quiet-by-default): re-introduce the
#             home-mtime fallthrough at the end of
#             bridge-watchdog.detect_fresh_install and Case F's
#             assertion fails. Re-introduce "trust malformed pending
#             via mtime" and Case G's assertion fails. The teeth prove
#             that the quiet-by-default contract is enforced — absence
#             of every positive signal MUST return False; recent home
#             mtime alone is NOT a positive signal.
#
# Footgun #11 mitigation: zero heredoc-stdin to a subprocess. The
# python assertions all run via `python3 <file>` with argv-only
# arguments; payload bodies travel via temp files.

set -uo pipefail

SMOKE_NAME="G-beta4-watchdog-noise"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

cleanup() {
  # Restore any 0000-mode blocker so smoke_cleanup_temp_root can rm -rf.
  if [[ -n "${BLOCKED_PARENT:-}" && -d "$BLOCKED_PARENT" ]]; then
    chmod 0700 "$BLOCKED_PARENT" 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

HELPER_DIR="$REPO_ROOT/scripts/smoke/G-beta4-helpers"
[[ -d "$HELPER_DIR" ]] || smoke_fail "missing $HELPER_DIR (G-beta4 helpers)"

# ---------------------------------------------------------------------
# Fixture: one fresh-install admin (pending onboarding), one healthy
# static-claude (complete onboarding), one mid-restart agent (marker
# active), one workdir-perm-denied agent (scan_error iso-uid-side).
# ---------------------------------------------------------------------

# Agent 1: admin in pending state with onboarding-pending marker
ADMIN_AGENT="patch_g"
ADMIN_HOME="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_AGENT"
mkdir -p "$ADMIN_HOME"
cat >"$ADMIN_HOME/CLAUDE.md" <<'EOF'
<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
managed
<!-- END AGENT BRIDGE DOC MIGRATION -->
EOF
: >"$ADMIN_HOME/SOUL.md"
: >"$ADMIN_HOME/MEMORY-SCHEMA.md"
: >"$ADMIN_HOME/MEMORY.md"
cat >"$ADMIN_HOME/SESSION-TYPE.md" <<'EOF'
# Session Type
- Session Type: admin
- Onboarding State: pending
EOF
mkdir -p "$BRIDGE_STATE_DIR/agents/$ADMIN_AGENT"
cat >"$BRIDGE_STATE_DIR/agents/$ADMIN_AGENT/onboarding-pending" <<EOF
agent=$ADMIN_AGENT
written=$(date +%s)
reason=fresh-install
EOF

# Agent 2: complete static-claude (no marker; SESSION-TYPE complete)
STATIC_AGENT="agent_complete"
STATIC_HOME="$BRIDGE_AGENT_HOME_ROOT/$STATIC_AGENT"
mkdir -p "$STATIC_HOME"
cat >"$STATIC_HOME/CLAUDE.md" <<'EOF'
<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
managed
<!-- END AGENT BRIDGE DOC MIGRATION -->
EOF
: >"$STATIC_HOME/SOUL.md"
: >"$STATIC_HOME/MEMORY-SCHEMA.md"
: >"$STATIC_HOME/MEMORY.md"
cat >"$STATIC_HOME/SESSION-TYPE.md" <<'EOF'
# Session Type
- Session Type: static-claude
- Onboarding State: complete
EOF
# Push the home mtime back so detect_fresh_install's mtime branch
# returns False (the marker branch is the only fresh-install signal
# present in this fixture; this agent has neither marker nor recent
# mtime).
touch -t 202401010000 "$STATIC_HOME" 2>/dev/null || true

# Agent 3: mid-restart agent (state=in_progress, alive PID, fresh)
RESTART_AGENT="agent_restarting"
RESTART_HOME="$BRIDGE_AGENT_HOME_ROOT/$RESTART_AGENT"
mkdir -p "$RESTART_HOME"
cat >"$RESTART_HOME/CLAUDE.md" <<'EOF'
<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
managed
<!-- END AGENT BRIDGE DOC MIGRATION -->
EOF
: >"$RESTART_HOME/SOUL.md"
: >"$RESTART_HOME/MEMORY-SCHEMA.md"
: >"$RESTART_HOME/MEMORY.md"
cat >"$RESTART_HOME/SESSION-TYPE.md" <<'EOF'
# Session Type
- Session Type: static-claude
- Onboarding State: complete
EOF
mkdir -p "$BRIDGE_STATE_DIR/agents/$RESTART_AGENT"
cat >"$BRIDGE_STATE_DIR/agents/$RESTART_AGENT/restart.in-progress" <<EOF
pid=$$
started=$(date +%s)
ttl=60
state=in_progress
EOF

# Agent 4: scan_error (workdir's parent is mode 0000 → iso-uid-side)
BLOCKED_AGENT="agent_blocked"
BLOCKED_PARENT="$BRIDGE_AGENT_ROOT_V2/$BLOCKED_AGENT"
mkdir -p "$BLOCKED_PARENT/workdir"
: >"$BLOCKED_PARENT/workdir/CLAUDE.md"
chmod 0000 "$BLOCKED_PARENT"
# Stub a tracked-tree dir so registry-anchored enumeration sees the agent.
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$BLOCKED_AGENT"

# Sanity guard: if we run as root, mode 0000 is bypassed and T6's
# iso-uid-side assertion can't fire. Skip the whole smoke.
if "$PY_BIN" -c "from pathlib import Path; import sys; sys.exit(0 if Path('$BLOCKED_PARENT/workdir').is_dir() else 1)" 2>/dev/null; then
  smoke_log "skip: running as root (UID 0) bypasses 0000-mode denial; cannot exercise T6 iso-uid-side path"
  exit 0
fi

# Agent 5: scan_error with iso-uid-side shape (CLAUDE.md mode 0000) —
# r2 recategorization (codex r1 BLOCKING #2). Workdir is statable
# (parent traversable, workdir 0700 owned by us) BUT CLAUDE.md inside
# is mode 0000 → neither the controller nor the iso UID can read it.
# Pre-r2 this was misclassified as controller-cache-stale (any
# statable workdir + permission_denied → cache-stale, no iso UID
# readability check). r2 fixes the classification to iso-uid-side by
# probing the iso UID. We use the BRIDGE_WATCHDOG_TEST_ISO_PROBE_JSON
# test seam to stub the probe answer because real isolated-uid
# sudo is unavailable on macOS / OSS dev hosts.
ISO_BROKEN_AGENT="agent_iso_broken"
ISO_BROKEN_PARENT="$BRIDGE_AGENT_ROOT_V2/$ISO_BROKEN_AGENT"
mkdir -p "$ISO_BROKEN_PARENT/workdir"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$ISO_BROKEN_AGENT"
: >"$ISO_BROKEN_PARENT/workdir/CLAUDE.md"
chmod 0000 "$ISO_BROKEN_PARENT/workdir/CLAUDE.md"
ISO_BROKEN_FILE="$ISO_BROKEN_PARENT/workdir/CLAUDE.md"

# Agent 6 (T6b — new, codex r1 BLOCKING #2): real controller-cache-
# stale shape. Workdir + file are present and statable; the supp-group
# cache miss is mocked via the test seam ("iso UID can read this
# path"). Pre-r2 the smoke could not distinguish T6 (real iso-side
# corruption) from T6b (real supp-group cache stale) because both
# produced identical classification. r2 makes the classifier
# definitive: file mode 0000 vs. mocked-readable-by-iso-UID yields
# distinct buckets.
ISO_CACHE_AGENT="agent_iso_cache"
ISO_CACHE_PARENT="$BRIDGE_AGENT_ROOT_V2/$ISO_CACHE_AGENT"
mkdir -p "$ISO_CACHE_PARENT/workdir"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$ISO_CACHE_AGENT"
# Place a mode 0000 CLAUDE.md so the controller's read raises
# PermissionError (driving the scan into the classify branch). The
# test seam below tells the classifier "iso UID CAN read this path"
# — exactly the production controller-cache-stale shape.
: >"$ISO_CACHE_PARENT/workdir/CLAUDE.md"
chmod 0000 "$ISO_CACHE_PARENT/workdir/CLAUDE.md"
ISO_CACHE_FILE="$ISO_CACHE_PARENT/workdir/CLAUDE.md"

# Test seam: BRIDGE_WATCHDOG_TEST_ISO_PROBE_JSON tells the classifier
# what the iso UID readability probe would return for each absolute
# path. Keys are absolute paths; values are "readable" or "denied".
# Used by classify_scan_error_category as a portable substitute for
# the real `sudo -n -u <iso> test -r <path>` probe (which only works
# on a Linux v2-isolation install).
ISO_PROBE_JSON="$SMOKE_TMP_ROOT/iso-probe.json"
"$PY_BIN" -c "
import json, sys
data = {
    sys.argv[1]: 'denied',     # iso-broken: iso UID also can't read
    sys.argv[2]: 'readable',   # cache-stale: iso UID CAN read
}
with open(sys.argv[3], 'w', encoding='utf-8') as h:
    json.dump(data, h)
" "$ISO_BROKEN_FILE" "$ISO_CACHE_FILE" "$ISO_PROBE_JSON"

# Registry that exercises all six agents.
REGISTRY_JSON="$SMOKE_TMP_ROOT/registry.json"
cat >"$REGISTRY_JSON" <<EOF
[
  {"id": "$ADMIN_AGENT", "class": "static", "agent_source": "static", "engine": "claude"},
  {"id": "$STATIC_AGENT", "class": "static", "agent_source": "static", "engine": "claude"},
  {"id": "$RESTART_AGENT", "class": "static", "agent_source": "static", "engine": "claude"},
  {"id": "$BLOCKED_AGENT", "class": "static", "agent_source": "static", "engine": "claude", "workdir": "$BLOCKED_PARENT/workdir"},
  {"id": "$ISO_BROKEN_AGENT", "class": "static", "agent_source": "static", "engine": "claude", "workdir": "$ISO_BROKEN_PARENT/workdir"},
  {"id": "$ISO_CACHE_AGENT", "class": "static", "agent_source": "static", "engine": "claude", "workdir": "$ISO_CACHE_PARENT/workdir"}
]
EOF

# Drive a watchdog scan against the fixture and persist the JSON +
# markdown render for the assertion helpers below. Export the iso
# probe test seam so classify_scan_error_category honors the mocked
# readability answers.
export BRIDGE_WATCHDOG_TEST_ISO_PROBE_JSON="$ISO_PROBE_JSON"

JSON_OUT="$SMOKE_TMP_ROOT/watchdog.json"
MD_OUT="$SMOKE_TMP_ROOT/watchdog.md"
"$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
  --bridge-home "$BRIDGE_HOME" \
  --agent-home-root "$BRIDGE_AGENT_HOME_ROOT" \
  --state-dir "$BRIDGE_STATE_DIR" \
  --agent-registry-json "$REGISTRY_JSON" \
  >"$JSON_OUT" 2>"$SMOKE_TMP_ROOT/scan-stderr.log" \
  || smoke_fail "watchdog scan --json exited non-zero (stderr at $SMOKE_TMP_ROOT/scan-stderr.log)"
"$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan \
  --bridge-home "$BRIDGE_HOME" \
  --agent-home-root "$BRIDGE_AGENT_HOME_ROOT" \
  --state-dir "$BRIDGE_STATE_DIR" \
  --agent-registry-json "$REGISTRY_JSON" \
  >"$MD_OUT" 2>>"$SMOKE_TMP_ROOT/scan-stderr.log" \
  || smoke_fail "watchdog scan (markdown) exited non-zero"

# ---------------------------------------------------------------------
# T1 — fresh_install_only=true upstream signal + daemon-helper readout
# ---------------------------------------------------------------------
# The fresh-install admin row is the only "warn" problem in the
# effective set (restart-in-progress is excluded from the effective
# set; the blocked agents are scan_error and don't carry fresh_install
# necessarily). Assert payload's fresh_install_only reflects "every
# effective problem is fresh-install" only when that holds.
"$PY_BIN" "$HELPER_DIR/assert-fresh-install.py" \
  "$JSON_OUT" "$ADMIN_AGENT" "$STATIC_AGENT" \
  || smoke_fail "T1 FAIL — fresh_install_only signal or per-row flag mis-set"
smoke_log "T1 PASS — fresh-install signal threads through payload"

# T1 daemon-helper readout: the watchdog-fresh-install-only command
# reads the payload field correctly.
FRESH_ONLY_RC="$("$PY_BIN" "$REPO_ROOT/bridge-daemon-helpers.py" \
  watchdog-fresh-install-only "$(cat "$JSON_OUT")")"
[[ "$FRESH_ONLY_RC" =~ ^[0-1]$ ]] || smoke_fail "T1 daemon helper returned non-binary: $FRESH_ONLY_RC"
smoke_log "T1 PASS — daemon helper readout: $FRESH_ONLY_RC"

# T1-teeth: rewrite payload to fresh_install_only=false, helper must
# print 0 (no priority downgrade). Proves the helper actually gates on
# the field, not silently always-1.
TEETH_PAYLOAD="$SMOKE_TMP_ROOT/teeth-fresh.json"
"$PY_BIN" "$HELPER_DIR/flip-fresh-install-flag.py" \
  "$JSON_OUT" "$TEETH_PAYLOAD" \
  || smoke_fail "T1-teeth payload flip helper failed"
TEETH_RC="$("$PY_BIN" "$REPO_ROOT/bridge-daemon-helpers.py" \
  watchdog-fresh-install-only "$(cat "$TEETH_PAYLOAD")")"
[[ "$TEETH_RC" == "0" ]] \
  || smoke_fail "T1-teeth FAIL — flipped fresh_install_only=false but helper returned $TEETH_RC (expected 0)"
smoke_log "T1-teeth PASS — daemon helper gates on the field"

# ---------------------------------------------------------------------
# T2 — static session_type suppresses onboarding_state in markdown
# ---------------------------------------------------------------------
"$PY_BIN" "$HELPER_DIR/assert-static-onboarding-suppressed.py" \
  "$MD_OUT" "$STATIC_AGENT" "$ADMIN_AGENT" \
  || smoke_fail "T2 FAIL — static session_type onboarding_state suppression broken"
smoke_log "T2 PASS — static onboarding_state suppressed in markdown"

# ---------------------------------------------------------------------
# T3 / T4 / T3-teeth — bridge_isolation_v2_normalize_workdir_profile_group
# ---------------------------------------------------------------------
# Use a temp workdir + stubbed enforce gate + stubbed group resolver so
# we can exercise the chgrp/chmod path on macOS too. The chgrp target
# is the operator's own primary group (always group-writable for the
# current process) so no sudo is needed.
T3_WORKDIR="$SMOKE_TMP_ROOT/t3-workdir"
mkdir -p "$T3_WORKDIR"
for f in CLAUDE.md AGENTS.md SOUL.md SESSION-TYPE.md MEMORY.md \
         MEMORY-SCHEMA.md HEARTBEAT.md CHANGE-POLICY.md TOOLS.md; do
  : >"$T3_WORKDIR/$f"
  chmod 0600 "$T3_WORKDIR/$f"
done

OPERATOR_GROUP="$(id -gn 2>/dev/null || printf '')"
[[ -n "$OPERATOR_GROUP" ]] || smoke_fail "could not resolve operator primary group for T3"

# Source iso-v2 + bridge-lib so the function is callable; the lib
# module needs bridge_warn (bridge-core.sh).
T3_LOG="$SMOKE_TMP_ROOT/t3.log"
(
  set +e
  export BRIDGE_AGENT_GROUP_PREFIX="${OPERATOR_GROUP}-"
  # Source the minimum so we have bridge_warn + the normalize helper.
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1
  # Stub the v2-enforce gate ON and the agent-group resolver to the
  # operator's primary group so chgrp succeeds without sudo. The
  # functions ARE invoked — by bridge_isolation_v2_normalize_workdir_
  # profile_group below, which calls them via name lookup after the
  # source replaces the lib's originals with these stubs.
  # shellcheck disable=SC2329
  bridge_isolation_v2_enforce() { return 0; }
  # shellcheck disable=SC2329
  bridge_isolation_v2_agent_group_name() { printf '%s' "$OPERATOR_GROUP"; }
  bridge_isolation_v2_normalize_workdir_profile_group "test_agent" "$T3_WORKDIR"
  printf 'rc=%s\n' "$?"
) >"$T3_LOG" 2>&1

# Verify mode 0660 on each file (chgrp is a no-op when group is already
# the operator's primary; the visible signal is the mode change).
"$PY_BIN" "$HELPER_DIR/assert-normalize-modes.py" "$T3_WORKDIR" "0660" \
  || smoke_fail "T3 FAIL — normalize_workdir_profile_group did not apply mode 0660 (see $T3_LOG)"
smoke_log "T3 PASS — normalize applies mode 0660 to materialize fileset"

# T4 — enforce gate OFF, files unchanged
T4_WORKDIR="$SMOKE_TMP_ROOT/t4-workdir"
mkdir -p "$T4_WORKDIR"
: >"$T4_WORKDIR/CLAUDE.md"
chmod 0600 "$T4_WORKDIR/CLAUDE.md"
(
  set +e
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1
  # shellcheck disable=SC2329
  bridge_isolation_v2_enforce() { return 1; }  # enforce OFF
  bridge_isolation_v2_normalize_workdir_profile_group "test_agent" "$T4_WORKDIR" >/dev/null 2>&1
) || true
"$PY_BIN" "$HELPER_DIR/assert-normalize-modes.py" "$T4_WORKDIR" "0600" \
  || smoke_fail "T4 FAIL — non-Linux/shared-mode normalize was not a no-op (file mode changed)"
smoke_log "T4 PASS — normalize is a no-op when enforce gate is OFF"

# T3-teeth — enforce ON but group resolver returns empty → no-op.
T3_TEETH_WORKDIR="$SMOKE_TMP_ROOT/t3-teeth-workdir"
mkdir -p "$T3_TEETH_WORKDIR"
: >"$T3_TEETH_WORKDIR/CLAUDE.md"
chmod 0600 "$T3_TEETH_WORKDIR/CLAUDE.md"
(
  set +e
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1
  # shellcheck disable=SC2329
  bridge_isolation_v2_enforce() { return 0; }
  # shellcheck disable=SC2329
  bridge_isolation_v2_agent_group_name() { printf ''; }  # empty → no-op
  bridge_isolation_v2_normalize_workdir_profile_group "test_agent" "$T3_TEETH_WORKDIR" >/dev/null 2>&1
) || true
"$PY_BIN" "$HELPER_DIR/assert-normalize-modes.py" "$T3_TEETH_WORKDIR" "0600" \
  || smoke_fail "T3-teeth FAIL — empty group resolver still applied chmod (regression: should be no-op)"
smoke_log "T3-teeth PASS — empty agent-group resolver short-circuits the chgrp/chmod"

# ---------------------------------------------------------------------
# T5 — restart.in-progress active suppresses drift
# ---------------------------------------------------------------------
"$PY_BIN" "$HELPER_DIR/assert-restart-skip.py" "$JSON_OUT" "$RESTART_AGENT" \
  || smoke_fail "T5 FAIL — restart_in_progress row not excluded from problem_count"
smoke_log "T5 PASS — restart-in-progress agent excluded from drift problem_count"

# ---------------------------------------------------------------------
# T6 / T6b — scan_error category split (iso-uid-side vs
# controller-cache-stale), now driven by the iso UID readability probe
# (r2 codex r1 BLOCKING #2 fix).
# ---------------------------------------------------------------------
# T6: BLOCKED_AGENT — workdir parent mode 0000 → iso-uid-side (workdir
#     itself not statable).
# T6 r2 (renamed): ISO_BROKEN_AGENT — workdir statable + CLAUDE.md
#     mode 0000 + test seam reports "denied" for iso UID →
#     iso-uid-side. Pre-r2 this was misclassified as cache-stale.
# T6b: ISO_CACHE_AGENT — workdir statable + CLAUDE.md mode 0000 + test
#     seam reports "readable" for iso UID → controller-cache-stale.
"$PY_BIN" "$HELPER_DIR/assert-scan-error-categories.py" \
  "$JSON_OUT" "$BLOCKED_AGENT" "$ISO_BROKEN_AGENT" "$ISO_CACHE_AGENT" \
  || smoke_fail "T6 FAIL — scan_error category split broken"
smoke_log "T6 PASS — scan_error 3-way split (parent-0000 / iso-broken / cache-stale)"

# ---------------------------------------------------------------------
# T7 — bridge_init_write_onboarding_marker writes the expected schema
# ---------------------------------------------------------------------
# bridge-init.sh has top-level execution (arg parser + body), so we
# can't `source` it without running the full init flow. Extract just
# the helper function definition via `sed` from the canonical source,
# then invoke it from a clean subshell that defines the WARNINGS array
# and the `bridge_init_append_warning` stub the helper expects.
T7_HOME="$SMOKE_TMP_ROOT/t7-bridge-home"
T7_ADMIN="patchy_t7"
mkdir -p "$T7_HOME/state/agents"
T7_FN_SRC="$SMOKE_TMP_ROOT/t7-fn.sh"
# Extract from the `bridge_init_write_onboarding_marker()` opener line
# up to its closing `}` (the next standalone `}` after the opener).
# This stays in lockstep with the actual source — if a future PR moves
# or renames the function, this smoke fails fast on extraction rather
# than silently testing dead code.
awk '/^bridge_init_write_onboarding_marker\(\)/{flag=1} flag{print; if (/^}$/) exit}' \
  "$REPO_ROOT/bridge-init.sh" >"$T7_FN_SRC"
[[ -s "$T7_FN_SRC" ]] \
  || smoke_fail "T7 FAIL — could not extract bridge_init_write_onboarding_marker from bridge-init.sh"

T7_LOG="$SMOKE_TMP_ROOT/t7.log"
(
  set +e
  export BRIDGE_HOME="$T7_HOME"
  export BRIDGE_STATE_DIR="$T7_HOME/state"
  WARNINGS=()
  # shellcheck disable=SC2329
  bridge_init_append_warning() { WARNINGS+=("$1"); }
  # shellcheck disable=SC1090
  source "$T7_FN_SRC"
  bridge_init_write_onboarding_marker "$T7_ADMIN" "1" "0"
  # Idempotent re-invocation: must not error, must refresh `written`.
  bridge_init_write_onboarding_marker "$T7_ADMIN" "1" "0"
  # Guard: dry_run=1 must skip the write entirely.
  T7_DRYRUN_HOME="$SMOKE_TMP_ROOT/t7-dryrun"
  BRIDGE_HOME="$T7_DRYRUN_HOME" BRIDGE_STATE_DIR="$T7_DRYRUN_HOME/state" \
    bridge_init_write_onboarding_marker "$T7_ADMIN" "1" "1"
  [[ ! -e "$T7_DRYRUN_HOME/state/agents/$T7_ADMIN/onboarding-pending" ]] \
    || { printf 'T7 dry-run skip FAIL\n' >&2; exit 1; }
) >"$T7_LOG" 2>&1
T7_RC=$?
(( T7_RC == 0 )) || smoke_fail "T7 helper run failed (rc=$T7_RC, log at $T7_LOG)"

"$PY_BIN" "$HELPER_DIR/assert-onboarding-marker.py" \
  "$T7_HOME/state/agents/$T7_ADMIN/onboarding-pending" "$T7_ADMIN" \
  || smoke_fail "T7 FAIL — bridge_init_write_onboarding_marker schema regression"
smoke_log "T7 PASS — onboarding-pending marker schema + dry-run-skip honored"

# ---------------------------------------------------------------------
# T8 / T9 (r2 codex r1 BLOCKING #1) + T_no_marker_no_session_recent_home
# / T_malformed_pending (r3 codex r2 BLOCKING quiet-by-default): one
# helper exercises the full r3 decision matrix. The fresh-install
# signal must NOT stick after onboarding completes, a stale pending
# marker must expire so a paused install does not stay at priority=low
# forever, and absence of every positive signal must return False
# (legacy installs without a pending marker are NOT fresh just because
# the home directory was recently touched — the r2 home-mtime
# fallthrough was removed).
#
# Cases A-E close T8/T9 (r2 BLOCKING). Cases F-G close
# T_no_marker_no_session_recent_home + T_malformed_pending (r3
# BLOCKING quiet-by-default contract).
#
# Teeth (regression-revert simulation): re-introduce the home-mtime
# fallthrough at the end of bridge-watchdog.detect_fresh_install and
# Case F's assertion fails. Re-introduce trust-malformed-via-mtime
# and Case G's assertion fails.
# ---------------------------------------------------------------------
T8_STATE_DIR="$SMOKE_TMP_ROOT/t8-state"
T8_HOME_ROOT="$SMOKE_TMP_ROOT/t8-home-root"
mkdir -p "$T8_STATE_DIR" "$T8_HOME_ROOT"
"$PY_BIN" "$HELPER_DIR/assert-detect-fresh-install.py" \
  "$REPO_ROOT" "$T8_STATE_DIR" "$T8_HOME_ROOT" \
  || smoke_fail "T8/T9/T_no_marker_no_session_recent_home/T_malformed_pending FAIL — detect_fresh_install precedence / TTL / quiet-by-default regression"
smoke_log "T8 + T9 + T_no_marker_no_session_recent_home + T_malformed_pending PASS — fresh_install r3 quiet-by-default contract (7 cases)"

# ---------------------------------------------------------------------
# T10 (r2 codex r1 BLOCKING #1): bridge_init_write_onboarding_complete_
# marker writes the schema, sets mode 0600, and removes the sibling
# onboarding-pending marker.
# ---------------------------------------------------------------------
T10_HOME="$SMOKE_TMP_ROOT/t10-bridge-home"
T10_AGENT="patch_t10"
mkdir -p "$T10_HOME/state/agents/$T10_AGENT"
# Pre-seed an existing pending marker so we can verify the writer
# cleans it up.
cat >"$T10_HOME/state/agents/$T10_AGENT/onboarding-pending" <<EOF
agent=$T10_AGENT
written=$(date +%s)
reason=fresh-install
EOF

T10_FN_SRC="$SMOKE_TMP_ROOT/t10-fn.sh"
# Extract bridge_init_write_onboarding_complete_marker — same awk
# pattern as T7 so the smoke fails fast if the function is renamed
# or moved.
awk '/^bridge_init_write_onboarding_complete_marker\(\)/{flag=1} flag{print; if (/^}$/) exit}' \
  "$REPO_ROOT/bridge-init.sh" >"$T10_FN_SRC"
[[ -s "$T10_FN_SRC" ]] \
  || smoke_fail "T10 FAIL — could not extract bridge_init_write_onboarding_complete_marker from bridge-init.sh"

T10_LOG="$SMOKE_TMP_ROOT/t10.log"
(
  set +e
  export BRIDGE_HOME="$T10_HOME"
  export BRIDGE_STATE_DIR="$T10_HOME/state"
  WARNINGS=()
  # shellcheck disable=SC2329
  bridge_init_append_warning() { WARNINGS+=("$1"); }
  # shellcheck disable=SC1090
  source "$T10_FN_SRC"
  bridge_init_write_onboarding_complete_marker "$T10_AGENT" "0"
  # Idempotent re-invocation must not error.
  bridge_init_write_onboarding_complete_marker "$T10_AGENT" "0"
  # dry_run=1 must skip the write entirely.
  T10_DRYRUN_HOME="$SMOKE_TMP_ROOT/t10-dryrun"
  BRIDGE_HOME="$T10_DRYRUN_HOME" BRIDGE_STATE_DIR="$T10_DRYRUN_HOME/state" \
    bridge_init_write_onboarding_complete_marker "${T10_AGENT}_dry" "1"
  [[ ! -e "$T10_DRYRUN_HOME/state/agents/${T10_AGENT}_dry/onboarding-complete" ]] \
    || { printf 'T10 dry-run skip FAIL\n' >&2; exit 1; }
) >"$T10_LOG" 2>&1
T10_RC=$?
(( T10_RC == 0 )) || smoke_fail "T10 helper run failed (rc=$T10_RC, log at $T10_LOG)"

"$PY_BIN" "$HELPER_DIR/assert-complete-marker.py" \
  "$T10_HOME/state/agents/$T10_AGENT" "$T10_AGENT" \
  || smoke_fail "T10 FAIL — bridge_init_write_onboarding_complete_marker schema or pending cleanup regression"
smoke_log "T10 PASS — complete marker schema + pending sibling cleanup + dry-run-skip"

smoke_log "all 10 tests + 2 teeth + r3 quiet-by-default cases F/G PASS (#1266 + #1270 + #1254 v0.15.0-beta4 Lane G r3)"
