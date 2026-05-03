#!/usr/bin/env bash
# bridge-skills-cli.sh — `agent-bridge skills` subcommand dispatcher.
#
# Implements the `agb skills list [--agent NAME] [--json]` query CLI
# proposed in issue #509 C5: a structured replacement for "open
# shared/SKILLS.md to figure out which agent has which plugin." Reads
# Claude Code's authoritative ~/.claude/plugins/installed_plugins.json
# and the bridge roster (`agent-bridge agent list --json`) and emits
# a per-agent installed-plugin view.
#
# This is independent of BRIDGE_SKILLS_DOC_MODE — the CLI works in any
# mode (legacy-catalog / plugin-routing / disabled).

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

CLI_NAME="agent-bridge skills"
PYTHON_BIN="${BRIDGE_PYTHON_BIN:-$(command -v python3 || echo /usr/bin/python3)}"

usage() {
  cat <<EOF
Usage:
  $CLI_NAME list [--agent <name>] [--json]

Subcommands:
  list                       List installed plugins per claude agent
                             (user-scope plugins are listed once as a
                             "shared" header; project/local-scope plugins
                             are attributed to the agent whose workdir
                             matches projectPath).
                             --agent <name>  show only the named agent
                             --json          emit JSON instead of a table
EOF
  exit "${1:-2}"
}

cmd_list() {
  local agent_filter=""
  local format="table"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -ge 2 ]] || bridge_die "Usage: $CLI_NAME list --agent <name>"
        agent_filter="$2"
        shift 2
        ;;
      --json)
        format="json"
        shift
        ;;
      -h|--help)
        usage 0
        ;;
      *)
        bridge_die "지원하지 않는 옵션입니다: $1"
        ;;
    esac
  done

  local roster_json
  if ! roster_json="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/agent-bridge" agent list --json 2>/dev/null)"; then
    bridge_die "agent list --json failed"
  fi

  AGENT_FILTER="$agent_filter" \
  FORMAT="$format" \
  "$PYTHON_BIN" - <<'PY' "$roster_json"
import json
import os
import sys
from pathlib import Path

agent_filter = os.environ.get("AGENT_FILTER", "").strip()
fmt = os.environ.get("FORMAT", "table")
roster = json.loads(sys.argv[1]) if sys.argv[1] else []

# Roster restricted to claude-engine rows; engines other than claude
# don't carry Claude Code plugins.
agents: list[dict[str, str]] = []
for row in roster:
    if row.get("engine") != "claude":
        continue
    agent = str(row.get("agent") or "")
    if not agent:
        continue
    if agent_filter and agent != agent_filter:
        continue
    workdir = str(row.get("workdir") or "")
    agents.append({
        "agent": agent,
        "source": str(row.get("source") or ""),
        "workdir": workdir,
    })

if agent_filter and not agents:
    print(f"agent '{agent_filter}' is not a claude-engine agent in the live roster", file=sys.stderr)
    sys.exit(1)

# Claude Code's installed-plugins record. CLAUDE_PLUGINS_FILE is honoured
# for tests; the operator path is ~/.claude/plugins/installed_plugins.json.
plugins_file_env = os.environ.get("CLAUDE_PLUGINS_FILE", "").strip()
if plugins_file_env:
    plugins_path = Path(plugins_file_env).expanduser()
else:
    plugins_path = Path.home() / ".claude" / "plugins" / "installed_plugins.json"

installed: dict[str, list[dict]] = {}
if plugins_path.exists():
    try:
        data = json.loads(plugins_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        data = {}
    raw = data.get("plugins") if isinstance(data, dict) else None
    if isinstance(raw, dict):
        for key, entries in raw.items():
            if isinstance(entries, list):
                installed[str(key)] = [e for e in entries if isinstance(e, dict)]


def resolve(p: str) -> str:
    try:
        return str(Path(p).resolve())
    except OSError:
        return p


user_scope: set[str] = set()
per_agent: dict[str, set[str]] = {row["agent"]: set() for row in agents}

resolved_workdirs = {row["agent"]: resolve(row["workdir"]) for row in agents if row["workdir"]}

for full_key, entries in installed.items():
    plugin_name = full_key.split("@", 1)[0]
    for entry in entries:
        scope = str(entry.get("scope") or "")
        if scope == "user":
            user_scope.add(plugin_name)
            continue
        if scope not in {"project", "local"}:
            continue
        project_path = str(entry.get("projectPath") or "").strip()
        if not project_path:
            continue
        rp = resolve(project_path)
        for agent, wd in resolved_workdirs.items():
            if rp == wd:
                per_agent[agent].add(plugin_name)
                break

if fmt == "json":
    payload = {
        "user_scope": sorted(user_scope),
        "agents": [
            {
                "agent": row["agent"],
                "source": row["source"],
                "workdir": row["workdir"],
                "plugins": sorted(per_agent.get(row["agent"], set())),
            }
            for row in agents
        ],
        "plugins_file": str(plugins_path),
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    sys.exit(0)

# table form
# Codex r1 on PR #513: prior code only printed the user-scope header when
# `--agent` was unset, so `agb skills list --agent patch` was silent on
# user-scope plugins even though they apply to that agent. Always show
# the user-scope header (when any user-scope plugins exist) so the
# operator sees the same plugin universe whether or not they filtered.
if user_scope:
    if agent_filter:
        print(f"user-scope (also available to {agent_filter}):")
    else:
        print("user-scope (every agent):")
    print("  " + ", ".join(sorted(user_scope)))
    print()

if not agents:
    print("(no claude agents in roster)")
    sys.exit(0)

agent_w = max(len(row["agent"]) for row in agents)
src_w = max(len(row["source"]) for row in agents)
print(f"{'agent':<{agent_w}}  {'source':<{src_w}}  plugins")
for row in agents:
    plugins = sorted(per_agent.get(row["agent"], set()))
    cell = ", ".join(plugins) if plugins else "—"
    print(f"{row['agent']:<{agent_w}}  {row['source']:<{src_w}}  {cell}")
PY
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
  fi
  case "$1" in
    list)
      shift
      cmd_list "$@"
      ;;
    -h|--help|help)
      usage 0
      ;;
    *)
      bridge_die "지원하지 않는 skills 명령입니다: $1"
      ;;
  esac
}

main "$@"
