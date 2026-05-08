#!/usr/bin/env bash
# apply-channel-policy.sh — enforce the agent-bridge singleton channel policy.
#
# Closes upstream #244. Claude Code auto-spawns every user-level enabledPlugins
# entry for every agent session. For "singleton channel" plugins (Telegram,
# Discord) only one process per bot token can poll `getUpdates` or hold the
# gateway websocket — so when multiple agents run concurrently, every restart
# of any agent kicks the previous holder off its lease with a 409 Conflict
# and the last one to restart becomes the sole holder. Under normal multi-
# agent operation this silently leaves the admin / router agent without a
# Telegram channel, and operator DMs go nowhere.
#
# Fix has two parts:
#
# 1. Write the shared overlay (`agents/.claude/settings.local.json`) so every
#    agent whose `.claude/settings.json` resolves to the shared effective
#    settings gets `enabledPlugins[telegram@…]=false` and
#    `enabledPlugins[discord@…]=false`.
# 2. When an admin agent is configured, write a per-agent local overlay at
#    `agents/<admin>/.claude/settings.local.json` that re-enables the same
#    singleton plugins. Claude Code's settings merge order prefers a project
#    `.claude/settings.local.json` over the project `.claude/settings.json`,
#    so the admin keeps the singleton plugins even when its
#    `.claude/settings.json` is the shared-effective symlink. Without this
#    bypass, #242's shared-symlink bootstrap means the admin loses exactly
#    the channels it is supposed to hold — see the PR #246 review.
#
# This script is idempotent. It is safe to re-run on every upgrade.

# Re-exec under bash 4+ if we got picked up by macOS's default /bin/bash (3.2),
# which lacks `${val,,}`-style bash-4 parameter expansions used downstream and
# chokes `bash -n` on the embedded Python heredoc bodies. Mirrors the guard in
# bridge-lib.sh so the script stays runnable standalone from an operator shell
# that isn't loading the bridge library (e.g. post-upgrade bootstrap of #254).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for bridge_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [[ -n "$bridge_candidate_bash" && -x "$bridge_candidate_bash" ]] || continue
    if "$bridge_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$bridge_candidate_bash" "$0" "$@"
    fi
  done

  echo "[apply-channel-policy] Agent Bridge requires Bash 4+ (current: ${BASH_VERSION:-unknown}). Install homebrew bash or set PATH accordingly." >&2
  exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/_common.sh
source "$SCRIPT_DIR/_common.sh"

: "${BRIDGE_AGENT_HOME_ROOT:=$BRIDGE_HOME/agents}"
: "${BRIDGE_AGENTS_CLAUDE_DIR:=$BRIDGE_AGENT_HOME_ROOT/.claude}"

BASE_SETTINGS="$BRIDGE_AGENTS_CLAUDE_DIR/settings.json"
OVERLAY_SETTINGS="$BRIDGE_AGENTS_CLAUDE_DIR/settings.local.json"
EFFECTIVE_SETTINGS="$BRIDGE_AGENTS_CLAUDE_DIR/settings.effective.json"

# Plugins that enforce one-connection-per-bot-token upstream. Adding a plugin
# here is a declaration that "multiple concurrent instances are broken by the
# service the plugin talks to, not by the plugin itself." Plugins that talk to
# stateless HTTP APIs (teams, ms365) do NOT belong here.
SINGLETON_PLUGINS=(
  "telegram@claude-plugins-official"
  "discord@claude-plugins-official"
)

DRY_RUN=0
QUIET=0

# v0.8 layout fix (#720): the per-owner re-enable / allowlist overlays above
# are written to `$OWNER_HOME/.claude/settings.local.json`, but Claude Code is
# launched with `CWD = $OWNER_HOME/workdir` so its project-scope merge reads
# `$OWNER_HOME/workdir/.claude/settings.local.json`. In v0.7 these were the
# same directory; under the v0.8 isolation-v2 layout they are not, and the
# overlay silently never reaches Claude — which kept the singleton plugins
# disabled for the very owners that should hold them and produced the admin
# kill-loop traced in the #720 repro.
#
# Mirror the symlink that `bridge-hooks.py:cmd_link_shared_settings` already
# creates for `settings.json` so `workdir/.claude/settings.local.json` -> the
# real overlay one directory up. `ln -sfn` is idempotent when the target is
# already correct; we refuse to clobber a real file (operator-managed) and
# treat `mkdir`/`ln` failures as soft skips so an isolated-user workdir owned
# by a different uid does not abort the whole policy pass — the controller
# side still gets the overlay it needs and `cmd_link_shared_settings` will
# top up the isolated-side path at agent launch.
_apply_channel_policy_link_workdir_overlay() {
  local owner_home="$1" agent_id="$2"
  local overlay_label="${3:-settings.local.json}"
  local workdir_claude="$owner_home/workdir/.claude"
  local link_path="$workdir_claude/$overlay_label"
  local link_target="../../.claude/$overlay_label"

  [[ -d "$owner_home/workdir" ]] || return 0

  if [[ -e "$link_path" && ! -L "$link_path" ]]; then
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] WARNING: $link_path is a regular file (not a symlink); leaving it in place — operator must remove it for the v0.8 overlay merge to take effect ($agent_id)" >&2
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] would symlink $link_path -> $link_target ($agent_id)"
    return 0
  fi

  if ! mkdir -p "$workdir_claude" 2>/dev/null; then
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] WARNING: cannot mkdir $workdir_claude (likely isolated-user owned); skipping workdir overlay symlink for $agent_id — bridge-hooks.py:cmd_link_shared_settings will fix it at launch" >&2
    return 0
  fi

  if ! ln -sfn "$link_target" "$link_path" 2>/dev/null; then
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] WARNING: cannot symlink $link_path -> $link_target ($agent_id); skipping" >&2
    return 0
  fi

  [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] symlinked $link_path -> $link_target ($agent_id)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --quiet)   QUIET=1 ;;
    --help|-h)
      cat <<'USAGE'
Usage: apply-channel-policy.sh [--dry-run] [--quiet]

Idempotently enforce the singleton channel plugin policy by writing the
shared overlay at $BRIDGE_HOME/agents/.claude/settings.local.json and
re-rendering the effective settings.

With --dry-run, prints the planned action but does not modify any file.
USAGE
      exit 0 ;;
    *) echo "apply-channel-policy.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$BRIDGE_AGENTS_CLAUDE_DIR"

python_plan="$(BRIDGE_PYTHON_HOME="$BRIDGE_HOME" "$BRIDGE_PYTHON" - "$OVERLAY_SETTINGS" "${SINGLETON_PLUGINS[@]}" <<'PY'
import json
import sys
from pathlib import Path

overlay_path = Path(sys.argv[1])
singleton_plugins = sys.argv[2:]

if overlay_path.exists():
    try:
        payload = json.loads(overlay_path.read_text() or "{}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"overlay is not valid JSON: {overlay_path}: {exc}")
else:
    payload = {}

if not isinstance(payload, dict):
    raise SystemExit(f"overlay root must be a JSON object: {overlay_path}")

enabled = payload.get("enabledPlugins")
if not isinstance(enabled, dict):
    enabled = {}

changed = False
for plugin_id in singleton_plugins:
    if enabled.get(plugin_id) is not False:
        enabled[plugin_id] = False
        changed = True

if changed:
    payload["enabledPlugins"] = enabled
    plan = {"changed": True, "payload": payload}
else:
    plan = {"changed": False, "payload": payload}

print(json.dumps(plan))
PY
)"

changed="$(printf '%s' "$python_plan" | "$BRIDGE_PYTHON" -c 'import json,sys;print(json.loads(sys.stdin.read())["changed"])')"

if [[ "$changed" == "True" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] would write $OVERLAY_SETTINGS (disable: ${SINGLETON_PLUGINS[*]})"
  else
    printf '%s' "$python_plan" | "$BRIDGE_PYTHON" -c '
import json,sys,pathlib
plan=json.loads(sys.stdin.read())
p=pathlib.Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(plan["payload"], indent=2, sort_keys=True) + "\n")
' "$OVERLAY_SETTINGS"
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] wrote $OVERLAY_SETTINGS"
  fi
else
  [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] overlay already enforces singleton policy (no change)"
fi

# Re-render the shared effective settings so every non-admin agent's
# `.claude/settings.json` symlink immediately picks up the new overlay. The
# admin agent owns its own non-shared settings.json and is not affected.
if [[ $DRY_RUN -eq 0 ]]; then
  # Prefer the live-runtime copy; fall back to the source-root copy so this
  # script works in smoke tests where BRIDGE_HOME is a scratch dir.
  bridge_hooks_py=""
  if [[ -f "$BRIDGE_HOME/bridge-hooks.py" ]]; then
    bridge_hooks_py="$BRIDGE_HOME/bridge-hooks.py"
  elif [[ -f "$SCRIPT_DIR/../bridge-hooks.py" ]]; then
    bridge_hooks_py="$(cd -P "$SCRIPT_DIR/.." && pwd -P)/bridge-hooks.py"
  fi
  if [[ -n "$bridge_hooks_py" ]]; then
    "$BRIDGE_PYTHON" "$bridge_hooks_py" render-shared-settings \
      --base-settings-file "$BASE_SETTINGS" \
      --overlay-settings-file "$OVERLAY_SETTINGS" \
      --effective-settings-file "$EFFECTIVE_SETTINGS" >/dev/null
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] re-rendered $EFFECTIVE_SETTINGS"
  else
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] warning: bridge-hooks.py not found under BRIDGE_HOME or repo; overlay written but effective not re-rendered" >&2
  fi
fi

# -- Per-agent re-enable bypass --
#
# The shared overlay above disables the singleton plugins for every agent whose
# `.claude/settings.json` resolves to `settings.effective.json`. That is safe as
# long as every singleton plugin is owned by the admin. On installs where the
# roster distributes channel ownership via `BRIDGE_AGENT_CHANNELS["<agent>"]="plugin:..."`
# (one persona per channel), the blanket disable breaks exactly the non-admin
# agent that is supposed to hold that channel — claude silently exits during
# plugin resolution. See #254.
#
# Fix: for every agent (admin or non-admin) that declares ownership of a
# singleton plugin, write a per-agent `.claude/settings.local.json` that
# re-enables the owned plugin(s). Claude Code's settings merge prefers the
# project `.claude/settings.local.json` over the project `.claude/settings.json`
# symlink, so the override re-enables only for that owner.
#
# Multi-owner case (two or more agents declare the same singleton plugin) is
# flagged with a warning: the upstream bot API still enforces one-connection-
# per-token, so whichever agent restarts last grabs the lease. Writing the
# re-enable for both agents does not make the conflict worse — it just means
# the current behaviour (most recent restart wins) surfaces rather than the
# silent-exit mode.
#
# Admin id is still resolved first because (a) the admin is always a valid
# owner of every singleton plugin by convention and (b) the per-agent loop
# below skips an agent whose id matches `admin_agent_id` so the admin bypass
# block that follows does not double-write.
admin_agent_id=""
if [[ -n "${BRIDGE_ADMIN_AGENT_ID:-}" ]]; then
  admin_agent_id="$BRIDGE_ADMIN_AGENT_ID"
else
  # `BRIDGE_ADMIN_AGENT_ID` is optional in the roster (agent-roster.local.example.sh
  # leaves the line commented out), so the grep below must not abort the script
  # when no admin line exists. Without `|| true` the pipeline exits 1 under
  # `set -euo pipefail` and every downstream step — including the non-admin
  # per-agent re-enable — is skipped, which is exactly the #254 symptom we are
  # supposed to prevent.
  for _admin_roster in "$BRIDGE_HOME/agent-roster.local.sh" "$BRIDGE_HOME/agent-roster.sh"; do
    if [[ -r "$_admin_roster" ]]; then
      _admin_line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=' "$_admin_roster" 2>/dev/null | head -n 1 | sed -E 's/^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=//; s/^"([^"]*)".*/\1/; s/^'"'"'([^'"'"']*)'"'"'.*/\1/; s/[[:space:]]*#.*$//' || true)"
      if [[ -n "${_admin_line:-}" ]]; then
        admin_agent_id="$_admin_line"
        break
      fi
    fi
  done
fi

if [[ -n "$admin_agent_id" ]]; then
  ADMIN_HOME="$BRIDGE_AGENT_HOME_ROOT/$admin_agent_id"
  ADMIN_LOCAL_SETTINGS="$ADMIN_HOME/.claude/settings.local.json"

  # Only write the bypass if the admin home already exists. During upgrade the
  # admin is already bootstrapped; in smoke fixtures or pre-bootstrap hosts the
  # directory is absent and we must stay a no-op rather than materialise an
  # empty agent dir from an env var that might be a stale default.
  if [[ ! -d "$ADMIN_HOME" ]]; then
    [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] skip admin re-enable: '$admin_agent_id' home not present under $BRIDGE_AGENT_HOME_ROOT"
  else
    admin_plan="$("$BRIDGE_PYTHON" - "$ADMIN_LOCAL_SETTINGS" "${SINGLETON_PLUGINS[@]}" <<'PY'
import json
import sys
from pathlib import Path

overlay_path = Path(sys.argv[1])
singleton_plugins = sys.argv[2:]

if overlay_path.exists():
    try:
        payload = json.loads(overlay_path.read_text() or "{}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"admin overlay is not valid JSON: {overlay_path}: {exc}")
else:
    payload = {}

if not isinstance(payload, dict):
    raise SystemExit(f"admin overlay root must be a JSON object: {overlay_path}")

enabled = payload.get("enabledPlugins")
if not isinstance(enabled, dict):
    enabled = {}

changed = False
for plugin_id in singleton_plugins:
    if enabled.get(plugin_id) is not True:
        enabled[plugin_id] = True
        changed = True

payload["enabledPlugins"] = enabled
print(json.dumps({"changed": changed, "payload": payload}))
PY
)"

    admin_changed="$(printf '%s' "$admin_plan" | "$BRIDGE_PYTHON" -c 'import json,sys;print(json.loads(sys.stdin.read())["changed"])')"

    if [[ "$admin_changed" == "True" ]]; then
      if [[ $DRY_RUN -eq 1 ]]; then
        [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] would write $ADMIN_LOCAL_SETTINGS (re-enable for admin '$admin_agent_id': ${SINGLETON_PLUGINS[*]})"
      else
        printf '%s' "$admin_plan" | "$BRIDGE_PYTHON" -c '
import json,sys,pathlib
plan=json.loads(sys.stdin.read())
p=pathlib.Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(plan["payload"], indent=2, sort_keys=True) + "\n")
' "$ADMIN_LOCAL_SETTINGS"
        [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] wrote $ADMIN_LOCAL_SETTINGS (admin re-enable)"
      fi
    else
      [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] admin overlay for '$admin_agent_id' already re-enables singleton policy (no change)"
    fi

    # #720: ensure workdir/.claude/settings.local.json -> ../../.claude/settings.local.json
    # so Claude (CWD=workdir) actually merges the admin re-enable overlay.
    _apply_channel_policy_link_workdir_overlay "$ADMIN_HOME" "$admin_agent_id"
  fi
fi

# -- Non-admin per-agent re-enable (closes #254) --
#
# Walk the roster and, for each non-admin agent that declares ownership of a
# singleton plugin via `BRIDGE_AGENT_CHANNELS["<agent>"]="plugin:..."`, write
# a per-agent `.claude/settings.local.json` that selectively re-enables only
# the plugins that agent actually owns. Agents that declare no singleton
# plugin inherit the shared disable and remain quiet polling-wise.
#
# Python does the roster read because bash assoc-array handling across
# sourced files is fragile and we want to stay compatible with installs that
# do not have `bridge-lib.sh` reachable from BRIDGE_HOME (smoke fixtures).

roster_files=()
for _candidate in \
  "$BRIDGE_HOME/agent-roster.local.sh" \
  "$BRIDGE_HOME/agent-roster.sh" \
  "$SCRIPT_DIR/../agent-roster.local.sh" \
  "$SCRIPT_DIR/../agent-roster.sh"; do
  if [[ -r "$_candidate" ]]; then
    roster_files+=("$_candidate")
  fi
done

if (( ${#roster_files[@]} == 0 )); then
  [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] no roster file found; non-admin per-agent bypass skipped"
else
  owner_json="$("$BRIDGE_PYTHON" - "$admin_agent_id" "${#SINGLETON_PLUGINS[@]}" "${SINGLETON_PLUGINS[@]}" "${roster_files[@]}" <<'PY'
import json
import re
import sys
from pathlib import Path

argv = sys.argv[1:]
admin_id = argv[0]
singleton_count = int(argv[1])
singleton_plugins = argv[2 : 2 + singleton_count]
roster_files = argv[2 + singleton_count :]

# Regex picks up lines of the form:
#   BRIDGE_AGENT_CHANNELS["agent"]="plugin:x@y,plugin:z@w"
#   BRIDGE_AGENT_CHANNELS[agent]='plugin:x@y'
# With either single or double quotes around the value. We keep this
# tolerant because the roster file is hand-edited and may grow extra
# whitespace or `export` prefixes.
# Agent id charset matches bridge_validate_agent_name (lib/bridge-core.sh):
# `[A-Za-z0-9._-]+` — includes dots so dotted agent ids like `foo.bar` are
# parsed here. The earlier pattern dropped dots, leaving a valid singleton
# owner in the exact silent-disable state this PR is meant to fix (see PR
# #255 round-1 review, finding #1).
channels_line = re.compile(
    r'^\s*(?:export\s+)?BRIDGE_AGENT_CHANNELS\[\s*["\']?([A-Za-z0-9._\-]+)["\']?\s*\]\s*='
    r'\s*["\']([^"\']*)["\']\s*(?:#.*)?$'
)

agent_channels: dict[str, str] = {}
for path_str in roster_files:
    path = Path(path_str)
    try:
        text = path.read_text(errors="replace")
    except OSError:
        continue
    for raw in text.splitlines():
        match = channels_line.match(raw)
        if not match:
            continue
        agent = match.group(1)
        value = match.group(2)
        # First-read wins. The bash layer feeds roster files in local-first
        # priority order (`agent-roster.local.sh` before `agent-roster.sh`
        # before the source-root fallbacks), so honouring the first entry we
        # see is how local overrides the tracked roster. Do not flip this to
        # last-read-wins without also reversing the file order above.
        if agent not in agent_channels:
            agent_channels[agent] = value

# Build owner map: singleton_plugin_id -> [agent_ids that declare it]
owners: dict[str, list[str]] = {pid: [] for pid in singleton_plugins}
for agent, channels in agent_channels.items():
    if agent == admin_id:
        # Admin is handled by the admin bypass above; skip here.
        continue
    tokens = [tok.strip() for tok in channels.split(",") if tok.strip()]
    for tok in tokens:
        # Tokens may be "plugin:telegram@claude-plugins-official" or raw ids.
        plugin_id = tok[len("plugin:") :] if tok.startswith("plugin:") else tok
        if plugin_id in owners:
            owners[plugin_id].append(agent)

# Invert: agent_id -> [plugin_ids to re-enable for that agent]
agent_enables: dict[str, list[str]] = {}
multi_owner_warnings: list[str] = []
for plugin_id, declared_by in owners.items():
    if len(declared_by) >= 2:
        multi_owner_warnings.append(
            f"[apply-channel-policy] WARNING: '{plugin_id}' declared by multiple "
            f"agents ({', '.join(declared_by)}); upstream bot API enforces "
            "one-connection-per-token so only the most recently restarted "
            "agent will hold the lease at runtime. Re-enable will be written "
            "for each owner, but the conflict will still surface."
        )
    for agent in declared_by:
        agent_enables.setdefault(agent, []).append(plugin_id)

print(
    json.dumps(
        {
            "agent_enables": agent_enables,
            "warnings": multi_owner_warnings,
        }
    )
)
PY
)"

  # Emit multi-owner warnings line-by-line to stderr. Use `while read` with
  # explicit IFS so embedded spaces inside each warning survive intact.
  "$BRIDGE_PYTHON" -c 'import json,sys; [print(w) for w in json.loads(sys.stdin.read())["warnings"]]' <<<"$owner_json" \
    | while IFS= read -r _warn; do
        [[ -n "$_warn" ]] && printf '%s\n' "$_warn" >&2
      done

  # Iterate owners: agent_id, plugins-it-owns. One call per owner to reuse the
  # same per-agent write logic used for the admin bypass.
  "$BRIDGE_PYTHON" -c 'import json,sys; [print(a+"\t"+",".join(p)) for a,p in json.loads(sys.stdin.read())["agent_enables"].items()]' <<<"$owner_json" | \
  while IFS=$'\t' read -r owner_id owner_plugins_csv; do
    [[ -z "$owner_id" ]] && continue
    IFS=',' read -r -a owner_plugins <<<"$owner_plugins_csv"
    OWNER_HOME="$BRIDGE_AGENT_HOME_ROOT/$owner_id"
    OWNER_LOCAL="$OWNER_HOME/.claude/settings.local.json"
    if [[ ! -d "$OWNER_HOME" ]]; then
      [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] skip owner re-enable: '$owner_id' home not present under $BRIDGE_AGENT_HOME_ROOT"
      continue
    fi

    owner_plan="$("$BRIDGE_PYTHON" - "$OWNER_LOCAL" "${owner_plugins[@]}" <<'PY'
import json
import sys
from pathlib import Path

overlay_path = Path(sys.argv[1])
plugins_to_enable = sys.argv[2:]

if overlay_path.exists():
    try:
        payload = json.loads(overlay_path.read_text() or "{}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"owner overlay is not valid JSON: {overlay_path}: {exc}")
else:
    payload = {}

if not isinstance(payload, dict):
    raise SystemExit(f"owner overlay root must be a JSON object: {overlay_path}")

enabled = payload.get("enabledPlugins")
if not isinstance(enabled, dict):
    enabled = {}

changed = False
for plugin_id in plugins_to_enable:
    if enabled.get(plugin_id) is not True:
        enabled[plugin_id] = True
        changed = True

payload["enabledPlugins"] = enabled
print(json.dumps({"changed": changed, "payload": payload}))
PY
)"

    owner_changed="$(printf '%s' "$owner_plan" | "$BRIDGE_PYTHON" -c 'import json,sys;print(json.loads(sys.stdin.read())["changed"])')"

    if [[ "$owner_changed" == "True" ]]; then
      if [[ $DRY_RUN -eq 1 ]]; then
        [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] would write $OWNER_LOCAL (re-enable for owner '$owner_id': ${owner_plugins[*]})"
      else
        printf '%s' "$owner_plan" | "$BRIDGE_PYTHON" -c '
import json,sys,pathlib
plan=json.loads(sys.stdin.read())
p=pathlib.Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(plan["payload"], indent=2, sort_keys=True) + "\n")
' "$OWNER_LOCAL"
        [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] wrote $OWNER_LOCAL (owner re-enable: ${owner_plugins[*]})"
      fi
    else
      [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] owner overlay for '$owner_id' already re-enables singleton policy (no change)"
    fi

    # #720: ensure workdir/.claude/settings.local.json -> ../../.claude/settings.local.json
    # so Claude (CWD=workdir) actually merges the per-owner re-enable.
    _apply_channel_policy_link_workdir_overlay "$OWNER_HOME" "$owner_id"
  done
fi

# -- Per-agent plugin allowlist (closes #272) --
#
# The singleton policy above only handles telegram/discord. For the broader
# "every agent inherits every globally-installed plugin" problem, an operator
# can declare a per-agent allowlist via the roster:
#
#   BRIDGE_AGENT_PLUGINS["mailbot"]="syrs-gmail@syrs-local syrs-gcal@syrs-local"
#
# When set, every globally-installed plugin (per
# `~/.claude/plugins/installed_plugins.json`) that is NOT in the allowlist
# (and is NOT already declared as a channel via `BRIDGE_AGENT_CHANNELS`) is
# disabled in the agent's per-agent `settings.local.json` overlay so the
# Claude session does not spawn its MCP server. Plugins in the allowlist or
# in BRIDGE_AGENT_CHANNELS are explicitly re-enabled.
#
# Agents without `BRIDGE_AGENT_PLUGINS` set keep the legacy global behaviour
# (no overlay written for the allowlist policy), so existing rosters do not
# regress. The previously-applied singleton policy still owns telegram and
# discord for those agents.
#
# Discovery of "globally installed plugins" reads
# `${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-~/.claude/plugins/installed_plugins.json}`.
# If unreadable, this section is a no-op (no destructive default). The
# settings.local.json write path is durable across `agb agent restart`
# because Claude Code's settings merge prefers local overlays over the
# project settings.json that the bridge regenerates on restart.

INSTALLED_PLUGINS_FILE="${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-$HOME/.claude/plugins/installed_plugins.json}"

if [[ ! -r "$INSTALLED_PLUGINS_FILE" ]]; then
  [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] no installed_plugins registry at $INSTALLED_PLUGINS_FILE; per-agent allowlist policy skipped"
elif (( ${#roster_files[@]} == 0 )); then
  [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] no roster file found; per-agent allowlist policy skipped"
else
  allowlist_json="$("$BRIDGE_PYTHON" - "$INSTALLED_PLUGINS_FILE" "${roster_files[@]}" <<'PY'
import json
import re
import sys
from pathlib import Path

argv = sys.argv[1:]
installed_plugins_path = Path(argv[0])
roster_files = argv[1:]

# Load the global plugin registry (whichever plugins Claude would auto-spawn
# in every session if no per-agent overlay disabled them).
try:
    registry = json.loads(installed_plugins_path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"installed_plugins registry unreadable: {installed_plugins_path}: {exc}")
installed = list((registry.get("plugins") or {}).keys())

# Both arrays use the same agent-id charset as bridge_validate_agent_name
# (lib/bridge-core.sh): `[A-Za-z0-9._-]+`. Dotted ids like `foo.bar` must
# parse correctly — see #255 r1 finding 1.
plugins_line = re.compile(
    r'^\s*(?:export\s+)?BRIDGE_AGENT_PLUGINS\[\s*["\']?([A-Za-z0-9._\-]+)["\']?\s*\]\s*='
    r'\s*["\']([^"\']*)["\']\s*(?:#.*)?$'
)
channels_line = re.compile(
    r'^\s*(?:export\s+)?BRIDGE_AGENT_CHANNELS\[\s*["\']?([A-Za-z0-9._\-]+)["\']?\s*\]\s*='
    r'\s*["\']([^"\']*)["\']\s*(?:#.*)?$'
)

agent_allowlist: dict[str, str] = {}
agent_channels: dict[str, str] = {}
for path_str in roster_files:
    try:
        text = Path(path_str).read_text(errors="replace")
    except OSError:
        continue
    for raw in text.splitlines():
        m = plugins_line.match(raw)
        if m:
            agent, value = m.group(1), m.group(2)
            # First-read wins (local roster overrides tracked roster).
            if agent not in agent_allowlist:
                agent_allowlist[agent] = value
            continue
        m = channels_line.match(raw)
        if m:
            agent, value = m.group(1), m.group(2)
            if agent not in agent_channels:
                agent_channels[agent] = value


def normalize_plugin_token(token: str) -> str:
    token = token.strip()
    # Allow either `plugin:foo@bar` (channel-style) or raw `foo@bar`.
    if token.startswith("plugin:"):
        token = token[len("plugin:"):]
    return token


# Build per-agent enable/disable plan.
#
# Allowlist tokens may be either fully-qualified (`syrs-gmail@syrs-local`) or
# short names (`syrs-gmail`). A short name matches every installed plugin
# whose id starts with `<token>@` (i.e. `syrs-gmail` matches
# `syrs-gmail@syrs-local` and `syrs-gmail@some-other-marketplace`). The
# operator-friendly short form is what the issue body uses (`"discord
# syrs-gmail syrs-judgeme ..."`), so we accept it here without forcing the
# operator to spell out the marketplace suffix on every line.
agent_plan: dict[str, dict[str, bool]] = {}
installed_set = set(installed)
for agent, allowlist_raw in agent_allowlist.items():
    raw_tokens: set[str] = set()
    for chunk in re.split(r"[\s,]+", allowlist_raw):
        norm = normalize_plugin_token(chunk)
        if norm:
            raw_tokens.add(norm)

    # Channel tokens (always re-enabled — operator declared them as a
    # required transport, so honouring channels regardless of allowlist
    # avoids breaking a channel by an oversight in the allowlist itself).
    channels_raw = agent_channels.get(agent, "")
    for tok in re.split(r"[\s,]+", channels_raw):
        norm = normalize_plugin_token(tok)
        if norm:
            raw_tokens.add(norm)

    # Resolve short names to installed-plugin ids; keep fully-qualified
    # tokens as-is. `unresolved` tracks tokens that did not match any
    # installed plugin; we surface them as a warning so the operator can
    # either install the plugin or trim the roster line.
    resolved: set[str] = set()
    unresolved: set[str] = set()
    for token in raw_tokens:
        if "@" in token:
            if token in installed_set:
                resolved.add(token)
            else:
                unresolved.add(token)
            continue
        # Short name: include every installed plugin whose id starts with
        # `<token>@`. We use prefix-with-`@` rather than bare prefix so a
        # short name like `syrs-gmail` does not accidentally match
        # `syrs-gmail-extras@…`.
        prefix = token + "@"
        matches = [pid for pid in installed if pid.startswith(prefix)]
        if matches:
            resolved.update(matches)
        else:
            unresolved.add(token)

    plan: dict[str, bool] = {}
    for plugin_id in installed:
        plan[plugin_id] = plugin_id in resolved
    agent_plan[agent] = plan

    if unresolved:
        print(
            f"[apply-channel-policy] WARNING: agent '{agent}' allowlist references "
            f"plugins not in {installed_plugins_path}: {', '.join(sorted(unresolved))}",
            file=sys.stderr,
        )

print(json.dumps({"agent_plan": agent_plan, "installed_count": len(installed)}))
PY
)"

  installed_count="$(printf '%s' "$allowlist_json" | "$BRIDGE_PYTHON" -c 'import json,sys;print(json.loads(sys.stdin.read())["installed_count"])')"
  [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] per-agent allowlist policy enumerated $installed_count installed plugins"

  "$BRIDGE_PYTHON" -c '
import json, sys
plan = json.loads(sys.stdin.read())["agent_plan"]
for agent, mapping in plan.items():
    enables = [pid for pid, val in mapping.items() if val]
    disables = [pid for pid, val in mapping.items() if not val]
    print(agent + "\t" + ",".join(sorted(enables)) + "\t" + ",".join(sorted(disables)))
' <<<"$allowlist_json" | \
  while IFS=$'\t' read -r allow_agent_id allow_enables_csv allow_disables_csv; do
    [[ -z "$allow_agent_id" ]] && continue
    ALLOW_HOME="$BRIDGE_AGENT_HOME_ROOT/$allow_agent_id"
    ALLOW_LOCAL="$ALLOW_HOME/.claude/settings.local.json"
    if [[ ! -d "$ALLOW_HOME" ]]; then
      [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] skip allowlist overlay: '$allow_agent_id' home not present under $BRIDGE_AGENT_HOME_ROOT"
      continue
    fi

    allow_plan="$("$BRIDGE_PYTHON" - "$ALLOW_LOCAL" "$allow_enables_csv" "$allow_disables_csv" <<'PY'
import json
import sys
from pathlib import Path

overlay_path = Path(sys.argv[1])
enables_csv = sys.argv[2]
disables_csv = sys.argv[3]
to_enable = [tok for tok in enables_csv.split(",") if tok]
to_disable = [tok for tok in disables_csv.split(",") if tok]

if overlay_path.exists():
    try:
        payload = json.loads(overlay_path.read_text() or "{}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"allowlist overlay is not valid JSON: {overlay_path}: {exc}")
else:
    payload = {}

if not isinstance(payload, dict):
    raise SystemExit(f"allowlist overlay root must be a JSON object: {overlay_path}")

enabled = payload.get("enabledPlugins")
if not isinstance(enabled, dict):
    enabled = {}

changed = False
for plugin_id in to_enable:
    if enabled.get(plugin_id) is not True:
        enabled[plugin_id] = True
        changed = True
for plugin_id in to_disable:
    if enabled.get(plugin_id) is not False:
        enabled[plugin_id] = False
        changed = True

payload["enabledPlugins"] = enabled
print(json.dumps({"changed": changed, "payload": payload}))
PY
)"

    allow_changed="$(printf '%s' "$allow_plan" | "$BRIDGE_PYTHON" -c 'import json,sys;print(json.loads(sys.stdin.read())["changed"])')"

    if [[ "$allow_changed" == "True" ]]; then
      if [[ $DRY_RUN -eq 1 ]]; then
        [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] would write $ALLOW_LOCAL (allowlist overlay for '$allow_agent_id')"
      else
        printf '%s' "$allow_plan" | "$BRIDGE_PYTHON" -c '
import json,sys,pathlib
plan=json.loads(sys.stdin.read())
p=pathlib.Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(plan["payload"], indent=2, sort_keys=True) + "\n")
' "$ALLOW_LOCAL"
        [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] wrote $ALLOW_LOCAL (allowlist overlay for '$allow_agent_id')"
      fi
    else
      [[ $QUIET -eq 1 ]] || echo "[apply-channel-policy] allowlist overlay for '$allow_agent_id' already matches policy (no change)"
    fi

    # #720: ensure workdir/.claude/settings.local.json -> ../../.claude/settings.local.json
    # so Claude (CWD=workdir) actually merges the per-agent allowlist overlay.
    _apply_channel_policy_link_workdir_overlay "$ALLOW_HOME" "$allow_agent_id"
  done
fi
