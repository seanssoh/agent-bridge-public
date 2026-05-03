#!/usr/bin/env bash
# Bulk PreCompact hook registration — canary-first rollout.
#
# Usage:
#   bulk-register.sh --canary     # phase 1, register on `patch` only
#   bulk-register.sh --phase2     # phase 2, three non-customer-facing agents
#   bulk-register.sh --all        # phase 3, every claude-engine agent (post-gate)
#   bulk-register.sh --include-stopped   # alias for --all; explicit intent to
#                                        # cover stopped (not just active) claude
#                                        # agents. Kept for clarity at call site.
#   bulk-register.sh --dry-run ... # show the plan, take no action
#
# All phases append one ndjson record per agent to
#   $BRIDGE_HOME/state/precompact-registration/<stamp>.jsonl
# and snapshot the old .claude/settings.json to backups/ before touching it.
#
# Idempotent: re-running a phase on already-registered agents yields
# status="unchanged" entries and no settings.json write.

set -euo pipefail

BRIDGE_HOME="${BRIDGE_HOME:-$HOME/.agent-bridge}"
AGENT_BRIDGE_BIN="${AGENT_BRIDGE_BIN:-$BRIDGE_HOME/agent-bridge}"
PYTHON_BIN="${BRIDGE_PYTHON_BIN:-$(command -v python3 || echo /usr/bin/python3)}"
STATE_DIR="$BRIDGE_HOME/state/precompact-registration"
BACKUP_DIR="$STATE_DIR/backups"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$STATE_DIR/$STAMP.jsonl"

PHASE=""
DRY_RUN=0

usage() {
    sed -n '2,12p' "$0"
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --canary)          PHASE="canary"; shift ;;
        --phase2)          PHASE="phase2"; shift ;;
        --all)             PHASE="all";    shift ;;
        --include-stopped) PHASE="all";    shift ;;
        --dry-run)         DRY_RUN=1;      shift ;;
        -h|--help) usage ;;
        *) echo "bulk-register: unknown flag: $1" >&2; usage ;;
    esac
done

if [ -z "$PHASE" ]; then
    echo "bulk-register: one of --canary|--phase2|--all is required" >&2
    usage
fi

CANARY_AGENTS=(patch)
PHASE2_AGENTS=(newsbot syrs-calendar syrs-creative)

list_all_claude_agents() {
    # Roster rows from `agent list --json` carry the live workdir for each
    # claude agent (static or dynamic). Issue #509 phase3 finding: the prior
    # text-parse path missed dynamic agents because their workdir lives
    # outside $BRIDGE_HOME/agents/<name>, so register_one() saw them as
    # "missing_home" and skipped them. Use the JSON view as the authoritative
    # source so dynamic agents are reachable from --all (and --canary /
    # --phase2 still resolve their static workdirs via the same path).
    #
    # The Python heredoc shells `agent list --json` itself (subprocess.check_output)
    # instead of via shell pipe so the heredoc stays the only stdin consumer —
    # same shape codex pinned in PR #512 r2 for the OPERATOR_ACTIONS_PENDING
    # v0.7.3 snippets.
    AGENT_BRIDGE_BIN="$AGENT_BRIDGE_BIN" "$PYTHON_BIN" - <<'PY'
import json
import os
import subprocess
import sys

cli = os.environ.get("AGENT_BRIDGE_BIN", "")
try:
    raw = subprocess.check_output([cli, "agent", "list", "--json"], stderr=subprocess.DEVNULL)
except (OSError, subprocess.CalledProcessError):
    sys.exit(0)
try:
    data = json.loads(raw or b"[]")
except (ValueError, json.JSONDecodeError):
    sys.exit(0)
for row in data:
    if row.get("engine") != "claude":
        continue
    agent = str(row.get("agent") or "").strip()
    workdir = str(row.get("workdir") or "").strip()
    if not agent or agent in ("shared", "_template"):
        continue
    if not workdir:
        continue
    # Tab is the field delimiter consumed by the main loop; agent ids and
    # workdir paths never contain tabs in valid roster output.
    print(f"{agent}\t{workdir}")
PY
}

resolve_static_target_workdir() {
    # For canary/phase2 (static names hardcoded above), look up the live
    # workdir from the same JSON view. Falls back to BRIDGE_HOME/agents/<name>
    # so a host that has not yet bootstrapped the agent still gets a deterministic
    # path (matches the prior register_one() default).
    local agent="$1"
    AGENT="$agent" AGENT_BRIDGE_BIN="$AGENT_BRIDGE_BIN" "$PYTHON_BIN" - <<'PY'
import json
import os
import subprocess
import sys

cli = os.environ.get("AGENT_BRIDGE_BIN", "")
target = os.environ.get("AGENT", "")
try:
    raw = subprocess.check_output([cli, "agent", "list", "--json"], stderr=subprocess.DEVNULL)
except (OSError, subprocess.CalledProcessError):
    sys.exit(1)
try:
    data = json.loads(raw or b"[]")
except (ValueError, json.JSONDecodeError):
    sys.exit(1)
for row in data:
    if row.get("agent") == target and row.get("engine") == "claude":
        workdir = str(row.get("workdir") or "").strip()
        if workdir:
            print(workdir)
            sys.exit(0)
sys.exit(1)
PY
}

emit_target_with_workdir() {
    # Print "<agent>\t<workdir>" for static-phase rosters; fall back to
    # $BRIDGE_HOME/agents/<agent> when the agent isn't in the live roster
    # (matches register_one's pre-fix default — "missing home" cases get
    # surfaced inside register_one rather than dropped here).
    local agent="$1"
    local workdir
    workdir="$(resolve_static_target_workdir "$agent" 2>/dev/null || true)"
    if [ -z "$workdir" ]; then
        workdir="$BRIDGE_HOME/agents/$agent"
    fi
    printf '%s\t%s\n' "$agent" "$workdir"
}

pick_targets() {
    case "$PHASE" in
        canary)
            for agent in "${CANARY_AGENTS[@]}"; do
                emit_target_with_workdir "$agent"
            done
            ;;
        phase2)
            for agent in "${PHASE2_AGENTS[@]}"; do
                emit_target_with_workdir "$agent"
            done
            ;;
        all)
            list_all_claude_agents
            ;;
    esac
}

json_escape() {
    # Minimal JSON string escaper for embedding in ndjson.
    python3 - "$1" <<'PY'
import json, sys
print(json.dumps(sys.argv[1]))
PY
}

record() {
    # record <agent> <action> <status> <command> <backup> [<error>]
    local agent="$1" action="$2" status="$3" command="$4" backup="$5" err="${6:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local a c b e
    a="$(json_escape "$agent")"
    c="$(json_escape "$command")"
    b="$(json_escape "$backup")"
    e="$(json_escape "$err")"
    printf '{"ts":"%s","phase":"%s","dry_run":%s,"agent":%s,"action":"%s","status":"%s","command":%s,"backup":%s,"error":%s}\n' \
        "$ts" "$PHASE" "$([ $DRY_RUN -eq 1 ] && echo true || echo false)" \
        "$a" "$action" "$status" "$c" "$b" "$e" \
        >> "$LOG_FILE"
}

backup_settings() {
    local agent="$1"
    local settings="$2"
    if [ ! -f "$settings" ]; then
        echo ""
        return 0
    fi
    local dest="$BACKUP_DIR/${agent}-${STAMP}.json"
    if [ $DRY_RUN -eq 0 ]; then
        mkdir -p "$BACKUP_DIR"
        cp -p "$settings" "$dest"
    fi
    echo "$dest"
}

register_one() {
    local agent="$1"
    local workdir="${2:-$BRIDGE_HOME/agents/$agent}"
    local settings="$workdir/.claude/settings.json"

    if [ ! -d "$workdir" ]; then
        record "$agent" "skip" "missing_workdir" "" "" "no workdir: $workdir"
        echo "skip   $agent (no workdir: $workdir)"
        return 0
    fi

    # Pre-check
    local pre_status="missing"
    if [ -f "$settings" ] && grep -q 'pre-compact.py' "$settings" 2>/dev/null; then
        pre_status="present"
    fi

    local backup
    backup="$(backup_settings "$agent" "$settings")"

    # Canonical invocation: call bridge-hooks.py directly. The top-level
    # `agent-bridge hooks` subcommand does not exist (bootstrap-memory-system.sh
    # and bridge-agent.sh's safety net both use this same direct path).
    local cmd_for_log
    cmd_for_log="$PYTHON_BIN $BRIDGE_HOME/bridge-hooks.py ensure-pre-compact-hook --workdir $workdir --bridge-home $BRIDGE_HOME --python-bin $PYTHON_BIN --settings-file $settings"

    if [ $DRY_RUN -eq 1 ]; then
        record "$agent" "register" "dry_run" "$cmd_for_log" "$backup" ""
        printf 'dry    %-20s pre=%s backup=%s\n' "$agent" "$pre_status" "$backup"
        return 0
    fi

    local out status
    if out="$("$PYTHON_BIN" "$BRIDGE_HOME/bridge-hooks.py" ensure-pre-compact-hook \
            --workdir "$workdir" \
            --bridge-home "$BRIDGE_HOME" \
            --python-bin "$PYTHON_BIN" \
            --settings-file "$settings" 2>&1)"; then
        status="ok"
    else
        status="error"
    fi

    if [ "$status" = "ok" ]; then
        printf 'ok     %-20s pre=%s backup=%s\n' "$agent" "$pre_status" "$backup"
        record "$agent" "register" "ok" "$cmd_for_log" "$backup" ""
    else
        printf 'ERR    %-20s: %s\n' "$agent" "$out" >&2
        record "$agent" "register" "error" "$cmd_for_log" "$backup" "$out"
    fi
}

main() {
    if [ $DRY_RUN -eq 0 ]; then
        mkdir -p "$STATE_DIR" "$BACKUP_DIR"
        : > "$LOG_FILE"
    else
        # Dry-run: route log to a tmp path so the real state dir stays clean.
        LOG_FILE="$(mktemp -t precompact-dryrun.XXXXXX).jsonl"
    fi

    local targets
    targets="$(pick_targets)"
    if [ -z "$targets" ]; then
        echo "bulk-register: no targets for phase=$PHASE" >&2
        exit 1
    fi

    echo "# phase=$PHASE dry_run=$DRY_RUN log=$LOG_FILE"
    local agent workdir
    while IFS=$'\t' read -r agent workdir; do
        [ -z "$agent" ] && continue
        register_one "$agent" "$workdir"
        # Gentle pause to avoid racing settings.json writes.
        if [ $DRY_RUN -eq 0 ] && [ "$PHASE" = "all" ]; then
            sleep 5
        fi
    done <<< "$targets"

    echo "# done. log: $LOG_FILE"
}

main "$@"
