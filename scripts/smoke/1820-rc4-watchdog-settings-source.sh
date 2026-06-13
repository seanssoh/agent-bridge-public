#!/usr/bin/env bash
# scripts/smoke/1820-rc4-watchdog-settings-source.sh — #1820 rc4 supplement.
#
# The controller-run watchdog walks the agent's DATA-TREE MIRROR workdir
# (`$BRIDGE_DATA_ROOT/agents/<a>/workdir`) for broken symlinks. On an original
# anomaly agent whose data-tree mirror render is incomplete, the
# `.claude/settings.json -> settings.effective.json` mirror symlink DANGLES even
# though the agent's REAL runtime HOME effective settings are fully rendered and
# loaded (all hook events + enabledPlugins active, bot healthy). Pre-fix the
# watchdog inferred "operating without hooks/plugins" from the unresolved
# data-tree-mirror symlink and raised a pure false-positive (cm-prod #7277,
# test_clean).
#
# The fix: decide "does this agent have hooks/plugins configured" from the
# agent's RUNTIME HOME effective settings (`<home>/.claude/settings.effective.
# json`, falling back to settings.json) — iso-aware (an iso agent's real OS
# home), NOT from whether the data-tree-mirror symlink resolves. The dangling
# mirror symlink is filtered out of the broken-link list IFF the runtime HOME
# effective settings actually carry hooks/plugins; an agent that genuinely lacks
# them is still flagged; an iso home the controller can't read routes through
# the common iso-boundary classifier as a graceful skip.
#
# Cases (shared-mode / macOS-runnable axis):
#   C1. Dangling data-tree-mirror `.claude/settings.json` +
#       runtime HOME effective settings HAVE hooks/plugins
#       → NOT flagged: broken_links does NOT contain the settings mirror,
#         status=ok, problem_count derived without it.
#   C2. Dangling data-tree-mirror `.claude/settings.json` +
#       runtime HOME effective settings genuinely LACK hooks/plugins
#       → still flagged: broken_links contains the settings mirror, status=warn
#         (the check is NOT blanket-suppressed).
#   C3. A genuinely-dangling UNRELATED symlink in the mirror workdir is always
#       flagged regardless of runtime-home hooks/plugins state (control: the
#       filter is scoped to the settings-effective mirror symlink only).
#
# Iso cross-UID (an iso agent's `os_user` real OS home is 0700/2770 and
# unreadable by the controller → graceful iso-skip via bridge_iso_boundary)
# cannot be exercised on macOS without a real linux-user rig — deferred to
# gate-2 real rig. The unit-level iso-unreadable branch is covered by the
# common-classifier mechanism this PR already ships.
#
# Uses an isolated BRIDGE_HOME via smoke_setup_bridge_home — never touches the
# operator's live runtime.

set -uo pipefail

SMOKE_NAME="1820-rc4-watchdog-settings-source"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

# Seed a well-formed Claude profile into a mirror workdir so missing_files is
# empty (the only drift signal under test is the broken settings symlink).
seed_profile() {
  local dir="$1"
  mkdir -p "$dir/.claude"
  cat >"$dir/CLAUDE.md" <<'EOF'
<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
managed
<!-- END AGENT BRIDGE DOC MIGRATION -->
EOF
  : >"$dir/SOUL.md"
  : >"$dir/MEMORY-SCHEMA.md"
  : >"$dir/MEMORY.md"
  cat >"$dir/SESSION-TYPE.md" <<'EOF'
# Session Type

- Session Type: static-claude
- Onboarding State: complete
EOF
}

# Render the runtime HOME `.claude/settings.effective.json` carrying hooks +
# enabledPlugins (the fully-rendered runtime home the agent actually loads).
seed_runtime_home_with_hooks() {
  local home="$1"
  mkdir -p "$home/.claude"
  cat >"$home/.claude/settings.effective.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "echo hi"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "echo guard"}]}]
  },
  "enabledPlugins": ["teams@local", "cosmax-crm@local"]
}
EOF
  # Mirror the real layout: settings.json is a symlink to the effective file.
  ln -sf "settings.effective.json" "$home/.claude/settings.json"
}

# Render the runtime HOME with effective settings that genuinely lack any
# hooks/plugins (empty objects/lists).
seed_runtime_home_without_hooks() {
  local home="$1"
  mkdir -p "$home/.claude"
  cat >"$home/.claude/settings.effective.json" <<'EOF'
{
  "hooks": {},
  "enabledPlugins": []
}
EOF
  ln -sf "settings.effective.json" "$home/.claude/settings.json"
}

# Make the data-tree-mirror `.claude/settings.json` a DANGLING symlink (the
# incomplete-mirror-render shape: the mirror never had settings.effective.json
# materialized, so its settings.json symlink target is absent).
seed_dangling_mirror_settings() {
  local workdir="$1"
  ln -sf "settings.effective.json" "$workdir/.claude/settings.json"
  # Deliberately do NOT create settings.effective.json in the mirror — the
  # symlink dangles.
}

run_scan() {
  local registry_json="$1"
  "$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
    --agent-registry-json "$registry_json" 2>"$SMOKE_TMP_ROOT/stderr.log"
}

# ---------------------------------------------------------------------------
# C1: dangling mirror settings.json + runtime HOME effective HAS hooks/plugins
#     → NOT flagged.
# ---------------------------------------------------------------------------
smoke_log "C1: dangling mirror settings symlink + runtime home has hooks/plugins → not flagged"
C1_AGENT="anomaly_has_hooks"
C1_WORKDIR="$BRIDGE_DATA_ROOT/agents/$C1_AGENT/workdir"
C1_HOME="$BRIDGE_DATA_ROOT/agents/$C1_AGENT/home"
# The watchdog enumerates tracked-tree dirs under $BRIDGE_AGENT_HOME_ROOT and
# intersects with the registry ids; resolve_scan_path then redirects the actual
# scan to the registry `workdir`. So a tracked-tree dir must exist for the agent
# to be enumerated at all (mirrors the v2 layout on the operator host).
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$C1_AGENT/.claude"
seed_profile "$C1_WORKDIR"
seed_dangling_mirror_settings "$C1_WORKDIR"
seed_runtime_home_with_hooks "$C1_HOME"

C1_REGISTRY="$SMOKE_TMP_ROOT/c1-registry.json"
cat >"$C1_REGISTRY" <<EOF
[
  {
    "id": "$C1_AGENT",
    "class": "static",
    "agent_source": "static",
    "engine": "claude",
    "workdir": "$C1_WORKDIR",
    "home": "$C1_HOME"
  }
]
EOF

C1_JSON="$(run_scan "$C1_REGISTRY")"
"$PY_BIN" - "$C1_JSON" "$C1_AGENT" <<'PY' || smoke_fail "C1 assertions failed: settings-mirror false-positive NOT filtered when runtime home has hooks/plugins"
import json, sys
payload = json.loads(sys.argv[1])
agent = sys.argv[2]
row = next(r for r in payload["agents"] if r["agent"] == agent)
mirror_rows = [b for b in row["broken_links"] if "settings.json" in b and "settings.effective.json" in b]
assert not mirror_rows, f"settings mirror symlink must be filtered out, got broken_links={row['broken_links']}"
assert row["status"] == "ok", f"expected status=ok with the settings mirror filtered, got {row['status']} broken_links={row['broken_links']}"
assert payload["problem_count"] == 0, f"expected problem_count=0, got {payload['problem_count']}"
PY
smoke_log "C1 PASS: settings mirror symlink filtered; agent classifies ok"

# ---------------------------------------------------------------------------
# C2: dangling mirror settings.json + runtime HOME effective LACKS hooks/plugins
#     → still flagged (don't blanket-suppress the check).
# ---------------------------------------------------------------------------
smoke_log "C2: dangling mirror settings symlink + runtime home lacks hooks/plugins → still flagged"
C2_AGENT="genuine_no_hooks"
C2_WORKDIR="$BRIDGE_DATA_ROOT/agents/$C2_AGENT/workdir"
C2_HOME="$BRIDGE_DATA_ROOT/agents/$C2_AGENT/home"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$C2_AGENT/.claude"
seed_profile "$C2_WORKDIR"
seed_dangling_mirror_settings "$C2_WORKDIR"
seed_runtime_home_without_hooks "$C2_HOME"

C2_REGISTRY="$SMOKE_TMP_ROOT/c2-registry.json"
cat >"$C2_REGISTRY" <<EOF
[
  {
    "id": "$C2_AGENT",
    "class": "static",
    "agent_source": "static",
    "engine": "claude",
    "workdir": "$C2_WORKDIR",
    "home": "$C2_HOME"
  }
]
EOF

C2_JSON="$(run_scan "$C2_REGISTRY")"
"$PY_BIN" - "$C2_JSON" "$C2_AGENT" <<'PY' || smoke_fail "C2 assertions failed: settings-mirror dangling symlink was suppressed even though runtime home genuinely lacks hooks/plugins"
import json, sys
payload = json.loads(sys.argv[1])
agent = sys.argv[2]
row = next(r for r in payload["agents"] if r["agent"] == agent)
mirror_rows = [b for b in row["broken_links"] if "settings.json" in b and "settings.effective.json" in b]
assert mirror_rows, f"settings mirror symlink must STILL be flagged when runtime home lacks hooks/plugins, got broken_links={row['broken_links']}"
assert row["status"] == "warn", f"expected status=warn (broken link surfaces drift), got {row['status']}"
PY
smoke_log "C2 PASS: settings mirror symlink still flagged when runtime home genuinely lacks hooks/plugins"

# ---------------------------------------------------------------------------
# C3: a genuinely-dangling UNRELATED symlink is always flagged (control — the
#     filter is scoped to the settings-effective mirror symlink only).
# ---------------------------------------------------------------------------
smoke_log "C3: unrelated dangling symlink always flagged even when runtime home has hooks/plugins"
C3_AGENT="anomaly_other_drift"
C3_WORKDIR="$BRIDGE_DATA_ROOT/agents/$C3_AGENT/workdir"
C3_HOME="$BRIDGE_DATA_ROOT/agents/$C3_AGENT/home"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$C3_AGENT/.claude"
seed_profile "$C3_WORKDIR"
seed_dangling_mirror_settings "$C3_WORKDIR"
seed_runtime_home_with_hooks "$C3_HOME"
# An unrelated genuinely-broken symlink in the workdir.
ln -sf "/nonexistent/some-real-target" "$C3_WORKDIR/dangling-other.link"

C3_REGISTRY="$SMOKE_TMP_ROOT/c3-registry.json"
cat >"$C3_REGISTRY" <<EOF
[
  {
    "id": "$C3_AGENT",
    "class": "static",
    "agent_source": "static",
    "engine": "claude",
    "workdir": "$C3_WORKDIR",
    "home": "$C3_HOME"
  }
]
EOF

C3_JSON="$(run_scan "$C3_REGISTRY")"
"$PY_BIN" - "$C3_JSON" "$C3_AGENT" <<'PY' || smoke_fail "C3 assertions failed: unrelated dangling symlink was wrongly suppressed, or settings mirror leaked through"
import json, sys
payload = json.loads(sys.argv[1])
agent = sys.argv[2]
row = next(r for r in payload["agents"] if r["agent"] == agent)
# The settings mirror symlink IS filtered (runtime home has hooks/plugins).
mirror_rows = [b for b in row["broken_links"] if "settings.json" in b and "settings.effective.json" in b]
assert not mirror_rows, f"settings mirror should still be filtered in C3, got broken_links={row['broken_links']}"
# The unrelated dangling symlink is NOT filtered.
other_rows = [b for b in row["broken_links"] if "dangling-other.link" in b]
assert other_rows, f"unrelated dangling symlink must stay flagged, got broken_links={row['broken_links']}"
assert row["status"] == "warn", f"expected status=warn from the unrelated broken link, got {row['status']}"
PY
smoke_log "C3 PASS: unrelated dangling symlink stays flagged; settings mirror still filtered (filter is scoped)"

smoke_log "all 3 cases PASS (#1820 rc4 settings-source correction); iso cross-UID home-unreadable deferred to gate-2 real rig"
