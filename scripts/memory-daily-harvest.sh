#!/usr/bin/env bash
# memory-daily harvester stub — thin CLI adapter between cron runner and
# bridge-memory.py. Keep this script policy-free; Python owns all decisions.
# Under linux-user isolation the stub probes passwordless sudo and either
# re-execs Python as the target OS user or signals --skipped-permission.
set -euo pipefail

AGENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$AGENT" ]] || { echo "error: --agent required" >&2; exit 2; }

: "${BRIDGE_HOME:=$HOME/.agent-bridge}"
BRIDGE_AGB="${BRIDGE_AGB:-$BRIDGE_HOME/agb}"
BRIDGE_PYTHON="${BRIDGE_PYTHON:-python3}"

json="$("$BRIDGE_AGB" agent show "$AGENT" --json 2>/dev/null)" \
  || { echo "error: agent show failed for $AGENT" >&2; exit 2; }
[[ -n "$json" ]] || { echo "error: empty agent show output for $AGENT" >&2; exit 2; }

# Issue #376 Track C: defense-in-depth source-class refusal. Track A filters
# memory-daily-<agent> registration to static-only agents, but an operator
# might create a cron manually or a future helper might forget to filter.
# Exit 0 (success / no-op) — NOT exit 2 — so the cron's run-state stays
# "success" and the daemon does not generate a [cron-followup] task.
agent_source="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get("source") or "")')"
if [[ "$agent_source" == "dynamic" ]]; then
  printf '[memory-daily-harvest] dynamic agent %s has no per-agent daily-note pipeline; nothing to harvest. exiting cleanly.\n' "$AGENT" >&2
  exit 0
fi

# Parse JSON twice to stay whitespace-safe (paths may contain spaces).
workdir="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("workdir", ""))')"
home="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("profile", {}).get("home", ""))')"
isolation_mode="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("isolation", {}).get("mode", ""))')"
os_user="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("isolation", {}).get("os_user", ""))')"

[[ -n "$workdir" && -n "$home" ]] \
  || { echo "error: missing workdir/home for $AGENT" >&2; exit 2; }

# Sidecar path: runner-exported CRON_REQUEST_DIR (cron path). Fallback is an
# agent-scoped state dir for manual/ad-hoc invocation outside the runner.
# Under v2 layout the per-agent state lives inside the v2 per-agent root, so
# the fallback resolves through the v2 helper when the layout is active.
if [[ -n "${CRON_REQUEST_DIR:-}" ]]; then
  sidecar_out="$CRON_REQUEST_DIR/authoritative-memory-daily.json"
else
  v2_md_root=""
  if [[ "${BRIDGE_LAYOUT:-legacy}" == "v2" ]] \
      && [[ -n "${BRIDGE_DATA_ROOT:-}" ]] \
      && [[ -d "${BRIDGE_DATA_ROOT}" ]] \
      && [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
    v2_md_root="$BRIDGE_AGENT_ROOT_V2/$AGENT/runtime/memory-daily"
  fi
  if [[ -n "$v2_md_root" ]]; then
    sidecar_out="$v2_md_root/adhoc.authoritative.json"
  else
    sidecar_out="$BRIDGE_HOME/state/memory-daily/$AGENT/adhoc.authoritative.json"
  fi
  mkdir -p "$(dirname "$sidecar_out")"
fi

# PR-C: under v2 layout the per-agent manifest must land under the per-agent
# private root and admin aggregates must land under shared/, not under the
# legacy controller state. Pass the resolved paths so bridge-memory.py
# writes manifests + aggregates into the v2 locations instead of falling
# back to BRIDGE_STATE_DIR/memory-daily. Without these flags the Python
# harvester would silently keep using the legacy controller tree (issue:
# PR-C r1 review finding P1 #1).
v2_extra_args=()
# Issue #418 codex r2 item 8: gate v2 extra args on data-root populated,
# matching the sidecar gate above. Transitional installs (marker present
# but BRIDGE_DATA_ROOT not yet populated) must fall back to legacy
# invocation — without this check, the harvester would pass v2 paths that
# don't exist on disk and bridge-memory.py would silently skip writes.
# The contract is: v2 extra args only when (a) layout is v2,
# (b) BRIDGE_DATA_ROOT is set, (c) BRIDGE_DATA_ROOT exists on disk, AND
# (d) BRIDGE_AGENT_ROOT_V2 is set. Mirrors the wiki harvester gate at
# scripts/wiki-daily-ingest.sh:174-176.
if [[ "${BRIDGE_LAYOUT:-legacy}" == "v2" ]] \
    && [[ -n "${BRIDGE_DATA_ROOT:-}" ]] \
    && [[ -d "${BRIDGE_DATA_ROOT}" ]] \
    && [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
  v2_extra_args+=(--per-agent-state-dir "$BRIDGE_AGENT_ROOT_V2/$AGENT/runtime/memory-daily")
  if [[ -n "${BRIDGE_SHARED_ROOT:-}" ]]; then
    v2_extra_args+=(--shared-aggregate-dir "$BRIDGE_SHARED_ROOT/memory-daily/aggregate")
  fi
elif [[ "${BRIDGE_LAYOUT:-legacy}" == "v2" ]]; then
  # Marker says v2 but data-root not populated — transitional install.
  # Emit a debug breadcrumb so the operator can see the fallback.
  printf '[memory-daily-harvest] data root not populated; running legacy enumeration (BRIDGE_DATA_ROOT=%s)\n' \
    "${BRIDGE_DATA_ROOT:-unset}" >&2
fi

current_user="$(id -un 2>/dev/null || echo '')"
current_uid="$(id -u 2>/dev/null || echo '')"

# linux-user isolation (issue #219 v1.3 design): Python harvester always runs
# as the controller UID so queue DB reads (task_events), dedupe lookups
# (_task_status), and backfill writes (bridge-task.sh create) remain in the
# controller context. When the target agent is isolated and the os_user
# differs, we instead grant the controller r-X on the target's transcripts
# tree (ACL added by bridge_linux_prepare_agent_isolation) and pass
# --transcripts-home so _scan_transcripts reads the correct store. If the
# transcripts dir is unreadable (ACL not yet re-applied, or operator has not
# ensured the target home exists), fall back to --skipped-permission so the
# admin aggregate surfaces the gap.
if [[ "$isolation_mode" == "linux-user" \
      && -n "$os_user" \
      && -n "$current_user" \
      && "$os_user" != "$current_user" \
      && "$current_uid" != "0" ]]; then
  target_home="${BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT:-/home}/$os_user"
  transcripts_dir="$target_home/.claude/projects"
  if [[ -r "$transcripts_dir" && -x "$transcripts_dir" ]]; then
    exec "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" harvest-daily \
      --agent "$AGENT" \
      --home "$home" \
      --workdir "$workdir" \
      --os-user "$os_user" \
      --transcripts-home "$target_home" \
      --sidecar-out "$sidecar_out" \
      "${v2_extra_args[@]}" \
      --json
  else
    exec "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" harvest-daily \
      --agent "$AGENT" \
      --home "$home" \
      --workdir "$workdir" \
      --os-user "$os_user" \
      --skipped-permission \
      --sidecar-out "$sidecar_out" \
      "${v2_extra_args[@]}" \
      --json
  fi
fi

exec "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" harvest-daily \
  --agent "$AGENT" \
  --home "$home" \
  --workdir "$workdir" \
  --sidecar-out "$sidecar_out" \
  "${v2_extra_args[@]}" \
  --json
