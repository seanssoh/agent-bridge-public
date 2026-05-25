#!/usr/bin/env bash
# bridge-agent.sh — static role lifecycle helpers

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
# shellcheck source=lib/bridge-doctor.sh
source "$SCRIPT_DIR/lib/bridge-doctor.sh"

# Issue #598 Track 1 r2: the `agent registry` endpoint must be read-only,
# but bridge_load_roster runs unconditionally at script load. Detect the
# registry subcommand early and export BRIDGE_REGISTRY_READ_ONLY=1 so the
# guards in lib/bridge-state.sh skip the dynamic active-env writes that
# the recovery loaders would otherwise perform during registry enumeration.
if [[ "${1:-}" == "registry" ]]; then
  export BRIDGE_REGISTRY_READ_ONLY=1
fi

bridge_load_roster

usage() {
  cat <<EOF
Usage:
  $(basename "$0") create <agent> [options]
  $(basename "$0") <verb> [<agent>] [options]

Subcommands:
  create             Scaffold a new static role (agent home + roster block).
  update             Typed audited mutation of protected managed-role fields.
  delete             Remove a static role (with optional --purge-home / --purge-crons).
  retire             Retire a static role with quarantine + audit trail.
  list               List registered agents.
  registry           Read-only JSON inventory of registered agents.
  show               Show one agent's roster + runtime state.
  reclassify         Promote a runtime-detected admin to a static role.
  doctor             Run a 7-step CRUD self-check (create/update/registry/
                     show/reclassify/retire/delete) against an isolated fixture.
  rerender-settings  Re-render per-agent settings.effective.json.
  start              Launch <agent> in tmux.
  safe-mode          Launch <agent> in safe-mode (no auto-resume).
  stop               Stop <agent>'s tmux session.
  restart            Restart <agent> with channel-banner verification.
  forget-session     Clear the persisted Claude/Codex resume id.
  attach             Attach to <agent>'s tmux session.
  compact            Trigger an admin-driven /compact for <agent>.
  handoff            Capture a handoff note for <agent>.
  ack-crash          Clear the crash-state marker for <agent>.

Examples:
  $(basename "$0") create reviewer --engine claude
  $(basename "$0") create coder --engine codex --session codex-main --always-on
  $(basename "$0") create ops --engine claude --channels plugin:discord@claude-plugins-official --discord-channel 123456789012345678 --json
  $(basename "$0") list --json
  $(basename "$0") registry --json
  $(basename "$0") show reviewer --json
  $(basename "$0") reclassify --apply
  $(basename "$0") rerender-settings --apply
  $(basename "$0") start reviewer --dry-run
  $(basename "$0") restart reviewer --attach
  $(basename "$0") safe-mode reviewer --attach
  $(basename "$0") stop reviewer
  $(basename "$0") attach reviewer
  $(basename "$0") compact reviewer
  $(basename "$0") handoff reviewer --note "context critical"

Update flags (typed audited mutation path for protected managed-role
fields, issue #528). Caller must be the admin agent (BRIDGE_ADMIN_AGENT_ID)
AND from an operator-trusted source (TTY-detected or BRIDGE_CALLER_SOURCE
override) — same trust model as 'agent-bridge config set'. Repeatable.

  --from <agent>                       caller agent id (required when
                                       BRIDGE_AGENT_ID env is unset)
  --set-launch-cmd <full string>       full replace of BRIDGE_AGENT_LAUNCH_CMD
  --launch-cmd-add-env KEY=VALUE       idempotent prepend in env-prefix
  --launch-cmd-remove-env KEY          remove every KEY=... env-prefix token
  --launch-cmd-add-dev-channel <spec>  append --dangerously-load-development-channels <spec>
  --launch-cmd-remove-dev-channel <spec>
  --channels-set <csv>                 full replace of BRIDGE_AGENT_CHANNELS
  --channels-add <token>               append unique CSV token
  --channels-remove <token>            remove matching CSV token
  --desc <text>                        set BRIDGE_AGENT_DESC
  --engine claude|codex                set BRIDGE_AGENT_ENGINE
  --workdir <path>                     set BRIDGE_AGENT_WORKDIR
  --loop on|off|yes|no                 set BRIDGE_AGENT_LOOP (off persists explicitly)
  --continue on|off                    set BRIDGE_AGENT_CONTINUE
  --class user|system                  set BRIDGE_AGENT_CLASS (privilege boundary)
  --idle-timeout <seconds>             set BRIDGE_AGENT_IDLE_TIMEOUT (integer ≥0; 0 = always on)
  --always-on yes                      sugar for --idle-timeout 0 (records expressed_intent=always_on_yes)
  --always-on no                       requires --idle-timeout <positive>; records expressed_intent=always_on_no
  --json                               emit JSON envelope
  --dry-run                            do not mutate; emit planned diff

Create options:
  --engine claude|codex        Agent runtime engine (default: claude)
  --session <name>             tmux session name (default: <agent>)
  --workdir <path>             live home / workdir (default: \$BRIDGE_AGENT_HOME_ROOT/<agent>)
  --profile-home <path>        tracked profile target when different from workdir
  --description <text>         roster description
  --display-name <text>        scaffold display name (default: <agent>)
  --role <text>                scaffold role summary
  --session-type <type>        admin|static-claude|static-codex|dynamic|cron
  --user <id[:display-name]>   scaffold one user memory partition (repeatable; defaults to shared users)
  --launch-cmd <cmd>           explicit launch command
  --channels <csv>             required Claude channels metadata
  --discord-channel <id>       primary Discord channel metadata
  --notify-kind <kind>         out-of-band notify transport metadata
  --notify-target <target>     notify target metadata
  --notify-account <account>   notify account metadata
  --isolation <mode>           shared|linux-user (default: shared)
  --isolate                    shorthand for --isolation linux-user
  --os-user <user>             explicit Linux service user for linux-user isolation
  --loop [yes|no|on|off]       mark the role as loop-enabled (bare form ≡ yes; "no" persists LOOP="0")
  --always-on [yes|no]         direction-declared policy flip; "no" requires --idle-timeout <positive>;
                               records expressed_intent on the audit row
  --idle-timeout <seconds>     set BRIDGE_AGENT_IDLE_TIMEOUT (integer ≥0; 0 = always on)
  --continue|--no-continue     explicit continue mode (default: continue)
  --dry-run                    print the planned role block without writing
  --json                       emit JSON instead of human text
  --test-fixture               opt into test-artifact name patterns
                               (smoke-/test-/bootstrap-/created-agent-/pref-,
                               *-repro-<N>); cleanup tooling may reap these

Policy: admin operates exclusively through these typed verbs. Direct edits
to protected-roster files (\$BRIDGE_ROSTER_LOCAL_FILE) are intentionally
blocked because the audit chain depends on the typed-write path. Any
out-of-band edits will be reverted by the daemon's reconciliation pass on
next sync — bring changes through 'agent update' / 'config set' instead.
EOF
}

bridge_agent_manage_python() {
  bridge_require_python
  python3 - "$@"
}

# bridge_scaffold_codex_entrypoint and bridge_ensure_codex_agent_hooks are
# defined in lib/bridge-agents.sh and lib/bridge-hooks.sh respectively,
# which bridge-lib.sh sources before this script runs. They are available
# to smoke drivers via bridge-lib.sh without sourcing bridge-agent.sh.
# See issue #1067 (S03, S08) for the contract.

# bridge_agent_create_rollback — issue #1076. Unwind a partial `agent create`
# when a mid-flow step raises so the agent does NOT end up "registered but
# half-scaffolded". Called from run_create's EXIT trap; the trap is armed
# before the first mutation and disarmed only on successful completion.
#
# Inputs are conveyed via the matching _CREATE_ROLLBACK_* shell variables
# (run_create's locals). Best-effort: every step is independent and
# failures are logged via bridge_warn but never re-raise. Order: roster
# excision first (so the agent stops showing up in `agb status` /
# `agb agent list`), then scaffold/workdir rm, then v2 sibling rm — match
# the inverse of the create-time ordering.
#
# Safety: every path is validated against the known agent-root prefixes
# (BRIDGE_AGENT_HOME_ROOT, BRIDGE_AGENT_ROOT_V2) before recursive rm.
# Anything outside those roots is a resolver bug we'd rather leave on
# disk than rm.
bridge_agent_create_rollback() {
  local agent="${_CREATE_ROLLBACK_AGENT:-}"
  local roster_path="${_CREATE_ROLLBACK_ROSTER:-}"
  local scaffold_target="${_CREATE_ROLLBACK_SCAFFOLD_TARGET:-}"
  local workdir="${_CREATE_ROLLBACK_WORKDIR:-}"
  local v2_root="${_CREATE_ROLLBACK_V2_ROOT:-}"
  local roster_written="${_CREATE_ROLLBACK_ROSTER_WRITTEN:-0}"
  local scaffold_created="${_CREATE_ROLLBACK_SCAFFOLD_CREATED:-0}"
  local workdir_created="${_CREATE_ROLLBACK_WORKDIR_CREATED:-0}"

  [[ -n "$agent" ]] || return 0

  bridge_warn "agent create: rolling back partial create for '$agent' (mid-flow failure)"

  # 1. Roster excision — undo bridge_write_role_block if it ran.
  if [[ "$roster_written" == "1" && -n "$roster_path" && -f "$roster_path" ]]; then
    if [[ -n "${SCRIPT_DIR:-}" ]] \
        && [[ -f "$SCRIPT_DIR/lib/agent-cli-helpers/roster-excise-block.py" ]]; then
      python3 "$SCRIPT_DIR/lib/agent-cli-helpers/roster-excise-block.py" \
        "$roster_path" "$agent" >/dev/null 2>&1 \
        || bridge_warn "agent create rollback: roster excision failed for '$agent' in $roster_path"
    fi
    # Drop the daemon auto-start state file so the next daemon tick does
    # not warn about a roster-removed agent (same pattern as run_delete).
    if [[ -n "${BRIDGE_STATE_DIR:-}" ]]; then
      rm -f "$BRIDGE_STATE_DIR/daemon-autostart/$agent.env" 2>/dev/null || true
    fi
  fi

  # 2. Scaffold target — the per-agent identity source / home tree.
  if [[ "$scaffold_created" == "1" && -n "$scaffold_target" ]]; then
    bridge_agent_create_rollback_rmtree "$scaffold_target"
  fi

  # 3. Workdir — only if create authored it (default v2 workdir/ default).
  # Skip when workdir equals scaffold_target (legacy install) so we don't
  # double-rm, and skip explicit operator --workdir paths which we did
  # NOT create. The _CREATE_ROLLBACK_WORKDIR_CREATED flag is set only
  # when the workdir was empty / autoderived under BRIDGE_AGENT_ROOT_V2.
  if [[ "$workdir_created" == "1" && -n "$workdir" && "$workdir" != "$scaffold_target" ]]; then
    bridge_agent_create_rollback_rmtree "$workdir"
  fi

  # 4. v2 per-agent root parent (only when we created it). bridge_scaffold_
  # agent_home pre-creates $BRIDGE_AGENT_ROOT_V2/<agent>/ before the v2 home/
  # and workdir/ children, and run_delete --purge-home does not see this
  # parent on a non-rolled-back delete — so rollback owns the parent rm to
  # match the inverse-of-create contract.
  if [[ -n "$v2_root" && "$scaffold_created" == "1" ]]; then
    bridge_agent_create_rollback_rmtree "$v2_root"
  fi

  # 5. Tracked-profile-source residue. bridge_scaffold_agent_home does not
  # write under $BRIDGE_HOME/agents/<a>/ for v2 installs (it writes under
  # $BRIDGE_AGENT_ROOT_V2/<agent>/), but a prior partial create or legacy
  # migration may have left a stub there. Only remove when the dir is empty
  # so we never blow away a legitimate tracked-profile source.
  if [[ -n "${BRIDGE_AGENT_HOME_ROOT:-}" ]]; then
    local profile_src="$BRIDGE_AGENT_HOME_ROOT/$agent"
    if [[ -d "$profile_src" ]] \
        && [[ -z "$(find "$profile_src" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]]; then
      rmdir "$profile_src" 2>/dev/null \
        || bridge_warn "agent create rollback: rmdir failed for empty $profile_src"
    fi
  fi
}

# bridge_agent_create_rollback_rmtree — guarded recursive rm. Refuses any
# path that is not under one of the known agent-root prefixes. Uses sudo
# when the controller cannot rm directly (isolated parents from a prior
# linux-user create that didn't get to bridge_linux_prepare_agent_isolation).
bridge_agent_create_rollback_rmtree() {
  local target="$1"
  [[ -n "$target" ]] || return 0
  [[ -d "$target" ]] || return 0

  case "$target" in
    "${BRIDGE_AGENT_HOME_ROOT:-/dev/null/none}"/*|"${BRIDGE_AGENT_ROOT_V2:-/dev/null/none}"/*) ;;
    *)
      bridge_warn "agent create rollback: refusing to rm target outside agent roots: $target"
      return 0
      ;;
  esac

  if rm -rf -- "$target" 2>/dev/null; then
    return 0
  fi
  if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
    bridge_linux_sudo_root rm -rf -- "$target" 2>/dev/null \
      || bridge_warn "agent create rollback: rm -rf failed for $target (manual cleanup may be required)"
  else
    bridge_warn "agent create rollback: rm -rf failed for $target (manual cleanup may be required)"
  fi
}

# bridge_ensure_memory_precompact_hook — wire the Plan-D PreCompact hook
# into an agent's .claude/settings.json. Safe to call repeatedly; the
# bridge-hooks.py helper already short-circuits when the hook is present.
#
# Called from:
#   - agent create (claude engine path)
#   - agent restart (as a safety net for pre-Plan-D installs)
bridge_ensure_memory_precompact_hook() {
  local agent="$1"
  local workdir="$2"
  local settings
  settings="$workdir/.claude/settings.json"
  if [[ -z "$workdir" || ! -f "$settings" ]]; then
    return 0
  fi
  # Issue #1151 (DEFER policy): under v2 isolation Claude launches with
  # CLAUDE_CONFIG_DIR pointed at the isolated home's `.claude/` (see
  # `bridge_run_agent_claude_root` at bridge-run.sh:491-496), not at the
  # workdir's `.claude/`. The PreCompact hook is rendered into the
  # isolated-home settings tree by the shared-settings linker
  # (`bridge_link_claude_settings_to_shared` already guards via the same
  # helper). Calling bridge-hooks.py against `$workdir/.claude/settings.json`
  # as the controller would either no-op (file under controller-write but
  # Claude doesn't read it under v2) or trip Permission denied if the
  # workdir tree is owned by the isolated UID. Defer cleanly — the
  # isolated-home rendering path handles the load-bearing case.
  if [[ -n "$agent" ]] \
      && command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null \
      && ! bridge_agent_workdir_step_a_complete "$agent" "$workdir"; then
    return 0
  fi
  # Post-Step-A v2 isolated path: same reasoning — settings the controller
  # writes here are not what Claude reads at launch under v2.
  if [[ -n "$agent" ]] \
      && command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    return 0
  fi
  local python_bin
  python_bin="${BRIDGE_PYTHON_BIN:-$(command -v python3 || echo /usr/bin/python3)}"
  if ! "$python_bin" "$SCRIPT_DIR/bridge-hooks.py" status-pre-compact-hook \
        --workdir "$workdir" \
        --bridge-home "$SCRIPT_DIR" \
        --python-bin "$python_bin" \
        --settings-file "$settings" >/dev/null 2>&1; then
    "$python_bin" "$SCRIPT_DIR/bridge-hooks.py" ensure-pre-compact-hook \
      --workdir "$workdir" \
      --bridge-home "$SCRIPT_DIR" \
      --python-bin "$python_bin" \
      --settings-file "$settings" >/dev/null 2>&1 || true
  fi
}

bridge_agent_default_launch_cmd() {
  local engine="$1"

  case "$engine" in
    claude)
      printf '%s' 'claude --dangerously-skip-permissions'
      ;;
    codex)
      # v0.8.6 hotfix: every codex agent launches with fast_mode enabled by
      # default. The codex CLI ships fast_mode as a stable=true feature, but
      # an operator config.toml that sets `features.fast_mode=false` (or a
      # downstream policy that flips it) would silently drop every agent off
      # the fast inference path. Pin it explicitly here so admin-pair
      # backfill, isolated agent create, and v0.7→v0.8 migration all carry
      # the same flag and the policy is auditable from the roster's
      # launch_cmd. codex_hooks stays paired (both features go through the
      # same injection helper in lib/bridge-state.sh).
      printf '%s' 'codex -c features.fast_mode=true --dangerously-bypass-approvals-and-sandbox --no-alt-screen'
      ;;
    *)
      bridge_die "지원하지 않는 engine 입니다: $engine"
      ;;
  esac
}

bridge_render_template_string() {
  local source_file="$1"
  local agent_id="$2"
  local display_name="$3"
  local role_text="$4"
  local engine="$5"
  local session_type="$6"

  bridge_agent_manage_python "$source_file" "$agent_id" "$display_name" "$role_text" "$engine" "$session_type" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
agent_id, display_name, role_text, engine, session_type = sys.argv[2:]
runtime = "Claude Code CLI" if engine == "claude" else "Codex CLI"
text = source.read_text(encoding="utf-8")
replacements = {
    "<Agent Name>": display_name,
    "<agent-id>": agent_id,
    "<Role>": role_text,
    "<Role Summary>": role_text,
    "<Runtime>": runtime,
    "<Boss>": "관리자 에이전트",
    "<한 줄 역할 설명>": role_text,
    "<표시 이름>": display_name,
    "<Session Type>": session_type,
    "<핵심 책임>": role_text,
    "<주 요청자>": "관리자 에이전트",
    "<Claude Code CLI | Codex CLI>": runtime,
    "<반드시 지킬 운영 규칙>": "큐를 source of truth로 삼고, claim/done note를 생략하지 않는다.",
    "<위험 작업 제한>": "크리티컬 변경 전에는 dry-run 또는 관련 상태 확인을 먼저 수행한다.",
    "<보고 방식>": "결과는 요청자 채널 또는 task queue로 반드시 남긴다.",
}
for old, new in replacements.items():
    text = text.replace(old, new)
print(text, end="")
PY
}

# bridge_ensure_auto_memory_isolation — seed per-agent autoMemoryDirectory.
#
# Claude Code's auto-memory is shared per git repository. Since all Agent
# Bridge agents live under a single git repo (~/.agent-bridge), every
# agent writes to the same ~/.claude/projects/<repo-slug>/memory/ dir by
# default. This leaks one agent's memory to the others.
#
# Anthropic exposes an official override — `autoMemoryDirectory` — that
# is only accepted from user/local/policy settings (NOT from project
# `settings.json`). We seed `.claude/settings.local.json` inside each
# agent's home so every agent writes to its own per-agent directory:
#
#   ~/.claude/auto-memory/<bridge-home-slug>/<agent>/
#
# The slug is derived from the resolved $BRIDGE_HOME path (Claude-style
# replacement of "/" with "-"), matching the naming Anthropic already uses
# under ~/.claude/projects/. That keeps two bridge installs on the same
# machine from colliding even when they share agent ids — and it keeps
# the slug stable whether bridge-agent.sh is invoked from the live runtime
# (~/.agent-bridge) or from a source checkout managing that same runtime.
#
# Merge policy (fail-closed):
#   - no file           → create with { autoMemoryDirectory: <path> }
#   - blank content     → fail (operator must inspect; no silent reset)
#   - valid JSON, no    → upsert autoMemoryDirectory
#   - valid JSON, same  → no-op
#   - valid JSON, diff  → fail (operator must resolve)
#   - parse failure     → fail (operator must inspect; no silent reset)
#
# Safe to call multiple times; fails loudly if another tool left the
# file in an unexpected state. Only applies to claude engine.
bridge_ensure_auto_memory_isolation() {
  local agent="$1"
  local workdir="$2"
  local bridge_home="${BRIDGE_HOME:-}"
  local settings_local="$workdir/.claude/settings.local.json"

  if [[ -z "$agent" || -z "$workdir" || -z "$bridge_home" ]]; then
    return 0
  fi
  if [[ ! -d "$workdir" ]]; then
    return 0
  fi

  # Issue #1151 (DEFER policy): controller-direct `mkdir -p "$workdir/.claude"`
  # races `bridge_linux_prepare_agent_isolation` (Step A) under v2 isolation.
  # When Step A has already chowned the workdir to the isolated UID, this
  # mkdir fails with Permission denied. Auto-memory will re-trigger on the
  # first claude session start AFTER Step A completes, so deferring loses
  # no data — the hook is idempotent and the next bridge_ensure_auto_memory_
  # isolation call will land cleanly with the isolated tree already owned
  # by the agent. See `lib/bridge-agents.sh::bridge_agent_workdir_step_a_complete`.
  if command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null \
      && ! bridge_agent_workdir_step_a_complete "$agent" "$workdir"; then
    return 0
  fi

  mkdir -p "$workdir/.claude"

  bridge_agent_manage_python "$settings_local" "$agent" "$bridge_home" <<'PY'
import json
import os
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
agent = sys.argv[2]
bridge_home = sys.argv[3]

resolved_home = os.path.realpath(bridge_home)

# Issue #185: reject ephemeral BRIDGE_HOME values before deriving the
# per-agent auto-memory slug. Claude Code's built-in `fewer-permission-
# prompts` smoke test ran this path with `BRIDGE_HOME=$(mktemp -d)` and
# then — because the agent workdir was the live path — wrote a
# settings.local.json into the live agent home whose autoMemoryDirectory
# pointed at a tmp slug. The tmp dir disappeared after the smoke, leaving
# pref-smoke stuck on a dangling auto-memory target. Any caller that
# invokes bridge-agent from an ephemeral BRIDGE_HOME without also scoping
# the agent workdir to that same ephemeral root is violating the
# isolation contract; refuse here so the leak cannot reach live state.
_EPHEMERAL_ROOTS = [
    "/tmp",
    "/private/tmp",
    "/var/folders",
    "/private/var/folders",
]
tmpdir = os.environ.get("TMPDIR")
if tmpdir:
    _EPHEMERAL_ROOTS.append(os.path.realpath(tmpdir).rstrip("/") or "/")

def _is_ephemeral(path: str) -> bool:
    # Match the root itself (BRIDGE_HOME=/tmp) AND any descendant
    # (BRIDGE_HOME=/tmp/xyz). Plain startswith() with a trailing slash
    # would miss the exact-root case, letting a caller bypass the guard.
    for root in _EPHEMERAL_ROOTS:
        if path == root or path.startswith(root + os.sep):
            return True
    return False

resolved_settings = os.path.realpath(settings_path)

if _is_ephemeral(resolved_home) and not _is_ephemeral(resolved_settings):
    sys.stderr.write(
        f"[bridge-agent] refusing to seed autoMemoryDirectory for "
        f"'{agent}' from ephemeral BRIDGE_HOME {resolved_home!r}. "
        "If a smoke test wants isolation, scope BOTH BRIDGE_HOME and the "
        "agent workdir to the same tmp root; do not call bridge-agent "
        "with a live workdir under a tmp BRIDGE_HOME (issue #185).\n"
    )
    sys.exit(1)

# Match Anthropic's ~/.claude/projects/ slug convention: replace both
# os.sep and "." with "-" so two installs never share a directory.
slug = resolved_home.replace(os.sep, "-").replace(".", "-")
expected = f"~/.claude/auto-memory/{slug}/{agent}"

if not settings_path.exists():
    settings_path.write_text(
        json.dumps({"autoMemoryDirectory": expected}, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    sys.exit(0)

raw = settings_path.read_text(encoding="utf-8")
if not raw.strip():
    sys.stderr.write(
        f"[bridge-agent] {settings_path} is empty. "
        "Refusing to overwrite blank content; inspect or remove the file, "
        "then retry.\n"
    )
    sys.exit(1)

try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    sys.stderr.write(
        f"[bridge-agent] {settings_path} is not valid JSON ({exc}). "
        "Not touching it. Fix or remove the file, then retry.\n"
    )
    sys.exit(1)

if not isinstance(data, dict):
    sys.stderr.write(
        f"[bridge-agent] {settings_path} is not a JSON object. "
        "Not touching it. Fix or remove the file, then retry.\n"
    )
    sys.exit(1)

current = data.get("autoMemoryDirectory")
if current == expected:
    sys.exit(0)

if current not in (None, ""):
    sys.stderr.write(
        f"[bridge-agent] {settings_path} already sets autoMemoryDirectory "
        f"to {current!r}; expected {expected!r}. Refusing to overwrite. "
        "Resolve manually.\n"
    )
    sys.exit(1)

data["autoMemoryDirectory"] = expected
tmp_path = settings_path.with_suffix(settings_path.suffix + ".tmp")
tmp_path.write_text(
    json.dumps(data, indent=2, ensure_ascii=False) + "\n",
    encoding="utf-8",
)
os.replace(tmp_path, settings_path)
PY
}

bridge_scaffold_agent_home() {
  local agent="$1"
  local home="$2"
  local display_name="$3"
  local role_text="$4"
  local engine="$5"
  local session_type="$6"
  # v0.8.5 #693 (Wave-3): explicit isolation_mode + os_user passed by the
  # caller (run_create) so the scaffold's sudo-handoff predicate does not
  # rely on the in-memory roster. At scaffold time the new agent has not
  # yet been written to agent-roster.local.sh (bridge_write_role_block
  # runs AFTER scaffold) and `bridge_load_roster` has not been re-invoked,
  # so `bridge_agent_linux_user_isolation_effective` — which reads
  # `BRIDGE_AGENT_ISOLATION_MODE[<agent>]` / `BRIDGE_AGENT_OS_USER[<agent>]`
  # — always returns false for a fresh `agent create --isolate ...` and
  # the entire PR #688 sudo-handoff block (added for #677) silently
  # no-ops. Plain `mkdir -p "$home"` then fails with `Permission denied`
  # because `data/agents/` is `root:root mode 755`. Surface the values
  # directly from the caller so the predicate works regardless of when
  # the roster reload happens. Defaults preserve the legacy single-param
  # signature for any internal callsite that does not (yet) opt in.
  local explicit_isolation_mode="${7:-}"
  local explicit_os_user="${8:-}"
  local template_root="$SCRIPT_DIR/agents/_template"
  local session_template="$template_root/session-types/$session_type.md"
  local session_files_root="$template_root/session-type-files/$session_type"
  local file=""
  local rel=""
  local target=""

  # v2 layout (issue #686): the canonical per-agent layout has two sibling
  # subdirs — `home/` (isolated process HOME) and `workdir/` (the project
  # tree the agent operates in, and the resolver-resolved runtime cwd).
  # `$home` (this function's $2) is whichever one the create flow chose as
  # the scaffold target. #1045/#1046: the create flow now defaults that to
  # the resolved `workdir/` so the profile lands where the runtime looks.
  # The OTHER sibling must still exist as a directory so resolvers and
  # tooling (doctor/status/start --dry-run) do not bomb with `... 없습니다`.
  # Compute that sibling up-front so the isolated/non-isolated branches
  # below can both pre-create it alongside `$home`. Legacy installs (no
  # BRIDGE_AGENT_ROOT_V2) keep `home == workdir`, so this stays empty and
  # is a no-op.
  local _scaffold_v2_sibling=""
  if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" && -n "$agent" ]]; then
    local _scaffold_v2_home="$BRIDGE_AGENT_ROOT_V2/$agent/home"
    local _scaffold_v2_workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
    if [[ "$home" == "$_scaffold_v2_workdir" ]]; then
      _scaffold_v2_sibling="$_scaffold_v2_home"
    else
      _scaffold_v2_sibling="$_scaffold_v2_workdir"
    fi
  fi

  # v0.8.5 #677: when the agent will be linux-user isolated under v2,
  # `$home` lives under `$BRIDGE_AGENT_ROOT_V2/<agent>/...`. The
  # `agents/` ancestor is root-owned (mode 755) and a stale per-agent
  # root from a prior failed `agent create` may already exist as
  # root:ab-agent-<name> mode 2750 — neither gives the controller mkdir
  # permission, so the plain `mkdir -p "$home"` below would fail with
  # `Permission denied` and abort the scaffold before
  # `bridge_linux_prepare_agent_isolation` (which normally lays this
  # tree down via sudo) ever runs.
  #
  # Pre-create the per-agent root and `$home` via sudo with controller
  # ownership so the rest of the scaffold (template renders, mkdirs,
  # chmods) executes as plain controller writes. `bridge_linux_prepare_agent_isolation`
  # runs after scaffold (bridge-agent.sh:2287) and normalizes
  # ownership/mode to the canonical `root:ab-agent-<name> 2750` per-agent
  # root + `<isolated>:ab-agent-<name> 2770` subdirs, then `chown -R
  # $os_user $workdir` transfers the scaffolded contents to the
  # isolated UID. Mirrors PR #675's `bridge_state_sudo_install_v2_file`
  # sudo-handoff pattern in lib/bridge-state.sh.
  # v0.8.5 #693 (Wave-3): replicate `bridge_agent_linux_user_isolation_effective`
  # using the explicitly-passed args + host-platform check, instead of
  # querying the in-memory roster which has not yet seen this agent (see
  # the "explicit_isolation_mode" comment block above). Falls back to the
  # roster-driven predicate when the caller did not pass explicit args
  # (any pre-#693 callsite), so the legacy code path keeps functioning
  # for callers that already had the agent registered before scaffold
  # (admin-pair backfill via `agent create --allow-shared-workdir`, etc.).
  local _scaffold_isolation_active=0
  if [[ -n "$explicit_isolation_mode" || -n "$explicit_os_user" ]]; then
    if [[ "$explicit_isolation_mode" == "linux-user" ]] \
        && [[ -n "$explicit_os_user" ]] \
        && [[ "$(bridge_host_platform 2>/dev/null || uname -s 2>/dev/null || printf '')" == "Linux" ]]; then
      _scaffold_isolation_active=1
    fi
  elif command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    _scaffold_isolation_active=1
  fi
  if [[ -n "$home" ]] \
      && [[ $_scaffold_isolation_active -eq 1 ]] \
      && command -v bridge_linux_sudo_root >/dev/null 2>&1; then
    local _scaffold_v2_root=""
    local _scaffold_controller=""
    if command -v bridge_isolation_v2_agent_root >/dev/null 2>&1; then
      _scaffold_v2_root="$(bridge_isolation_v2_agent_root "$agent" 2>/dev/null || printf '')"
    fi
    _scaffold_controller="$(bridge_current_user 2>/dev/null || id -un 2>/dev/null || printf '')"
    if [[ -n "$_scaffold_v2_root" && -n "$_scaffold_controller" ]]; then
      # Wave-5 #4282 hardening: every sudo-handoff step here is now
      # strict. Pre-Wave-5 the block silenced stderr and `|| true`-
      # swallowed every failure (mkdir/chown/chmod) and fell through to
      # the plain `mkdir -p "$home"` below. On a fresh install where
      # sudo NOPASSWD does not whitelist `mkdir/chown/chmod` (the
      # `bridge_migration_install_sudoers` entry only whitelists
      # `tmux + bash`), the entire block silently no-op'd and the plain
      # mkdir surfaced raw `Permission denied` instead of an actionable
      # "sudo configuration is wrong for v2 isolation" error. Surface
      # each failure via `bridge_die` so the caller can fix the
      # underlying sudo policy rather than chasing the secondary mkdir
      # symptom (Scenario A.b root cause analysis, task #4282 retest).
      #
      # Scope is intentionally limited to the per-agent root +
      # `$home` + v2 sibling workdir/ — i.e., paths the predicate has
      # ALREADY confirmed are isolated-managed. The v2 ancestor parents
      # (`$BRIDGE_DATA_ROOT`, `$BRIDGE_AGENT_ROOT_V2`) are NOT
      # normalized here even though the canonical contract in
      # lib/bridge-isolation-v2.sh:36-47 says `agents/` should be
      # `root:root 0755`. Locking the parents to root:root would break
      # the non-isolated v2 path: `bridge_agent_default_home`
      # (lib/bridge-agents.sh:3226-3232) resolves shared-mode agents'
      # home to `$BRIDGE_AGENT_ROOT_V2/<agent>/home` too, and the
      # non-isolated branch reaches plain `mkdir -p "$home"` below
      # without a sudo handoff — that mkdir would suddenly require
      # write on a root-owned parent. The pre-Wave-5 `bridge_init_dirs`
      # umask-derived parent perms (typically `sean:sean 0700` or
      # `0755`) keep the non-isolated path working. Operators who want
      # the full canonical layout should use the migration tool, which
      # owns parent normalization (#4282 codex review, PR #701 r2).
      #
      # Per-agent root: idempotent. If a prior failed run left it as
      # root:ab-agent-<name> 2750, retake it as controller-owned 0755 so
      # we (and any nested mkdirs) can write into it. Prepare will reset
      # ownership/mode to the canonical contract.
      bridge_linux_sudo_root mkdir -p "$_scaffold_v2_root" \
        || bridge_die "scaffold sudo mkdir failed: $_scaffold_v2_root (verify sudo NOPASSWD whitelist for the controller)"
      bridge_linux_sudo_root chown "$_scaffold_controller" "$_scaffold_v2_root" \
        || bridge_die "scaffold sudo chown $_scaffold_controller failed: $_scaffold_v2_root"
      bridge_linux_sudo_root chmod 0755 "$_scaffold_v2_root" \
        || bridge_die "scaffold sudo chmod 0755 failed: $_scaffold_v2_root"
      # Scaffold target ($home is typically $_scaffold_v2_root/home but
      # may be overridden via BRIDGE_AGENT_WORKDIR). Pre-create via sudo
      # in case it lives under a path the controller cannot mkdir
      # directly (same parent-owned-by-root problem as above).
      bridge_linux_sudo_root mkdir -p "$home" \
        || bridge_die "scaffold sudo mkdir failed: $home"
      bridge_linux_sudo_root chown "$_scaffold_controller" "$home" \
        || bridge_die "scaffold sudo chown $_scaffold_controller failed: $home"
      bridge_linux_sudo_root chmod 0755 "$home" \
        || bridge_die "scaffold sudo chmod 0755 failed: $home"
      # v2 sibling dir (issue #686) — the home/ or workdir/ that is NOT
      # the scaffold target. Same parent-owned-by-root problem applies.
      # Pre-create via sudo with controller ownership so the resolver
      # lookup succeeds; prepare's `chown -R $os_user $workdir` will
      # retake ownership for the isolated UID after scaffold completes.
      if [[ -n "$_scaffold_v2_sibling" ]]; then
        bridge_linux_sudo_root mkdir -p "$_scaffold_v2_sibling" \
          || bridge_die "scaffold sudo mkdir failed: $_scaffold_v2_sibling"
        bridge_linux_sudo_root chown "$_scaffold_controller" "$_scaffold_v2_sibling" \
          || bridge_die "scaffold sudo chown $_scaffold_controller failed: $_scaffold_v2_sibling"
        bridge_linux_sudo_root chmod 0755 "$_scaffold_v2_sibling" \
          || bridge_die "scaffold sudo chmod 0755 failed: $_scaffold_v2_sibling"
      fi
      # #1165 Gap 4: legacy per-agent tracked-profile dir at
      # $BRIDGE_AGENT_HOME_ROOT/<agent>/ (e.g.
      # ~/.agent-bridge/agents/<a>/). On a markerless-existing-install
      # upgrade path, this dir was scaffolded by an older code path
      # under the controller's umask (mode 0700 awfmanager-owned). The
      # legacy-teams-mcp pruner and other Python helpers walk into it
      # later (looking for residual .mcp.json files) and trip
      # `PermissionError: '/home/awfmanager/.agent-bridge/agents/<a>/.mcp.json'`
      # because the isolated UID running the pruner can't even stat the
      # parent. The v2 _scaffold_v2_root above only normalizes the
      # `data/agents/<a>/` v2 layout — the legacy `agents/<a>/` is not
      # the same path. Idempotent: pre-create + chown + chmod 0755 so
      # the controller can write into it (template renders, JSON files)
      # AND any other UID on the box can traverse into it for read-only
      # inventories. Contents stay non-secret (channel state files live
      # under workdir/.<channel>/ with their own ACLs).
      if [[ -n "${BRIDGE_AGENT_HOME_ROOT:-}" && -n "$agent" ]]; then
        local _scaffold_legacy_root="$BRIDGE_AGENT_HOME_ROOT/$agent"
        bridge_linux_sudo_root mkdir -p "$_scaffold_legacy_root" \
          || bridge_die "scaffold sudo mkdir failed: $_scaffold_legacy_root"
        bridge_linux_sudo_root chown "$_scaffold_controller" "$_scaffold_legacy_root" \
          || bridge_die "scaffold sudo chown $_scaffold_controller failed: $_scaffold_legacy_root"
        bridge_linux_sudo_root chmod 0755 "$_scaffold_legacy_root" \
          || bridge_die "scaffold sudo chmod 0755 failed: $_scaffold_legacy_root"
      fi
    fi
  fi

  mkdir -p "$home"
  if [[ -n "$_scaffold_v2_sibling" ]]; then
    mkdir -p "$_scaffold_v2_sibling"
  fi
  [[ -d "$template_root" ]] || bridge_die "agent template root가 없습니다: $template_root"
  [[ -f "$session_template" ]] || bridge_die "session type template가 없습니다: $session_type"

  while IFS= read -r file; do
    rel="${file#"$template_root"/}"
    target="$home/$rel"
    mkdir -p "$(dirname "$target")"
    if [[ -e "$target" ]]; then
      continue
    fi
    bridge_render_template_string "$file" "$agent" "$display_name" "$role_text" "$engine" "$session_type" >"$target"
  done < <(find "$template_root" \
    -path "$template_root/session-types" -prune -o \
    -path "$template_root/session-type-files" -prune -o \
    -type f -print | LC_ALL=C sort)

  if [[ ! -e "$home/SESSION-TYPE.md" ]]; then
    bridge_render_template_string "$session_template" "$agent" "$display_name" "$role_text" "$engine" "$session_type" >"$home/SESSION-TYPE.md"
  fi

  if [[ "$session_type" == "static-claude" ]]; then
    python3 - "$home/SESSION-TYPE.md" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
updated = re.sub(
    r"(^- Onboarding State:\s*)([A-Za-z0-9._-]+)",
    r"\1complete",
    text,
    count=1,
    flags=re.MULTILINE,
)
path.write_text(updated, encoding="utf-8")
PY
  fi

  while IFS= read -r rel; do
    mkdir -p "$home/$rel"
  done < <(cd "$template_root" && find . \
    -path './session-types' -prune -o \
    -path './session-type-files' -prune -o \
    -type d -print | sed 's#^\./##' | grep -v '^$' | LC_ALL=C sort)

  if [[ -d "$session_files_root" ]]; then
    while IFS= read -r file; do
      rel="${file#"$session_files_root"/}"
      target="$home/$rel"
      mkdir -p "$(dirname "$target")"
      if [[ -e "$target" ]]; then
        continue
      fi
      bridge_render_template_string "$file" "$agent" "$display_name" "$role_text" "$engine" "$session_type" >"$target"
    done < <(find "$session_files_root" -type f -print | LC_ALL=C sort)

    while IFS= read -r rel; do
      mkdir -p "$home/$rel"
    done < <(cd "$session_files_root" && find . -type d -print | sed 's#^\./##' | grep -v '^$' | LC_ALL=C sort)
  fi
}

bridge_normalize_user_specs_json() {
  bridge_agent_manage_python "$@" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")

items = []
seen = set()

def display_name_from_user_file(path: Path, fallback: str) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return fallback
    preferred = ""
    name = ""
    for line in text.splitlines():
        if line.startswith("- Preferred name:"):
            preferred = line.split(":", 1)[1].strip()
        elif line.startswith("- Name:"):
            name = line.split(":", 1)[1].strip()
    return preferred or name or fallback

def add_user(user_id: str, display_name: str) -> None:
    user_id = user_id.strip()
    display_name = display_name.strip() or user_id
    if not user_id:
        raise SystemExit("empty user id is not allowed")
    if not NAME_RE.match(user_id):
        raise SystemExit(f"invalid user id: {user_id}")
    if user_id in seen:
        return
    seen.add(user_id)
    items.append({"id": user_id, "display_name": display_name})

for raw in sys.argv[1:]:
    if ":" in raw:
        user_id, display_name = raw.split(":", 1)
    else:
        user_id, display_name = raw, raw
    add_user(user_id, display_name)

def discover_shared_users() -> None:
    shared_dir = Path(os.environ.get("BRIDGE_SHARED_DIR") or Path(os.environ.get("BRIDGE_HOME", "~/.agent-bridge")).expanduser() / "shared")
    users_root = shared_dir / "users"
    if not users_root.exists():
        return
    for user_root in sorted(path for path in users_root.iterdir() if path.is_dir()):
        if not NAME_RE.match(user_root.name):
            continue
        display = display_name_from_user_file(user_root / "USER.md", user_root.name)
        add_user(user_root.name, display)

def discover_existing_agent_users() -> None:
    agents_root = Path(os.environ.get("BRIDGE_AGENT_HOME_ROOT") or Path(os.environ.get("BRIDGE_HOME", "~/.agent-bridge")).expanduser() / "agents")
    if not agents_root.exists():
        return
    for user_file in sorted(agents_root.glob("*/users/*/USER.md")):
        user_id = user_file.parent.name
        if not NAME_RE.match(user_id):
            continue
        display = display_name_from_user_file(user_file, user_id)
        if user_id == "default" and display == "default":
            continue
        add_user(user_id, display)

if not items:
    discover_shared_users()
if not items:
    discover_existing_agent_users()
if not items:
    add_user("default", "default")

print(json.dumps(items, ensure_ascii=False))
PY
}

bridge_scaffold_user_partitions() {
  local home="$1"
  local users_json="$2"
  local shared_users_root="${3:-${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}/users}"

  bridge_agent_manage_python "$home" "$users_json" "$shared_users_root" <<'PY'
from pathlib import Path
import json
import shutil
import sys

home = Path(sys.argv[1])
users = json.loads(sys.argv[2])
shared_users_root = Path(sys.argv[3])
users_root = home / "users"
default_root = users_root / "default"

if not default_root.exists():
    raise SystemExit(f"missing template user skeleton: {default_root}")

def patch_user_file(path: Path, user_id: str, display_name: str) -> None:
    text = path.read_text(encoding="utf-8")
    text = text.replace("- Name:\n", f"- Name: {display_name}\n")
    text = text.replace("- Preferred name:\n", f"- Preferred name: {display_name}\n")
    path.write_text(text, encoding="utf-8")

def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)

def link_or_copy(canonical: Path, target: Path) -> None:
    if target.exists() or target.is_symlink():
        remove_path(target)
    try:
        target.symlink_to(canonical, target_is_directory=True)
    except OSError:
        shutil.copytree(canonical, target, symlinks=True)

def ensure_canonical_user(user_id: str, display_name: str) -> Path:
    canonical = shared_users_root / user_id
    if not canonical.exists():
        canonical.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(default_root, canonical, symlinks=True)
    patch_user_file(canonical / "USER.md", user_id, display_name)
    return canonical

for user in users:
    user_id = user["id"]
    display_name = user.get("display_name") or user_id
    canonical = ensure_canonical_user(user_id, display_name)
    target = users_root / user_id
    if target.exists() and not target.is_symlink() and user_id != "default":
        continue
    link_or_copy(canonical, target)

if all(user["id"] != "default" for user in users) and (default_root.exists() or default_root.is_symlink()):
    remove_path(default_root)

index_path = home / "memory" / "index.md"
if index_path.exists():
    lines = index_path.read_text(encoding="utf-8").splitlines()
    out = []
    inserted = False
    for line in lines:
        out.append(line)
        if line.strip() == "## Users":
            inserted = True
            continue
        if inserted and line.strip() == "- `../users/`":
            for user in users:
                out.append(f"- `../users/{user['id']}/`")
            inserted = False
    index_path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}

bridge_write_role_block() {
  local agent="$1"
  local description="$2"
  local engine="$3"
  local session="$4"
  local workdir="$5"
  local profile_home="$6"
  local launch_cmd="$7"
  local channels="$8"
  local discord_channel="$9"
  local notify_kind="${10}"
  local notify_target="${11}"
  local notify_account="${12}"
  local loop_mode="${13}"
  local continue_mode="${14}"
  local always_on="${15}"
  local isolation_mode="${16:-}"
  local os_user="${17:-}"
  local replace_existing="${18:-0}"
  # Issue #580 Track 2: optional positionals 19/20 used by `agent update`.
  # Existing callers that pass <19 args MUST continue to produce
  # byte-identical role-block output, so both default to empty/0 and the
  # writer below preserves the legacy emission shape when they are unset.
  local agent_class="${19:-}"
  local loop_explicit_off="${20:-0}"
  # Issue #1093: optional positional 21 carries an explicit
  # BRIDGE_AGENT_IDLE_TIMEOUT value (string of digits). Empty means "no
  # explicit value supplied" — the legacy always_on==1 → IDLE_TIMEOUT="0"
  # path still triggers, and no IDLE_TIMEOUT line is emitted otherwise.
  # When non-empty, the explicit value overrides always_on so `--always-on`
  # (which sets always_on=1) and `--idle-timeout 0` produce the same byte
  # emission, and `--idle-timeout 300` writes the literal `"300"`.
  local idle_timeout_value="${21:-}"

  bridge_agent_manage_python \
    "$BRIDGE_ROSTER_LOCAL_FILE" \
    "$agent" \
    "$description" \
    "$engine" \
    "$session" \
    "$workdir" \
    "$profile_home" \
    "$launch_cmd" \
    "$channels" \
    "$discord_channel" \
    "$notify_kind" \
    "$notify_target" \
    "$notify_account" \
    "$loop_mode" \
    "$continue_mode" \
    "$always_on" \
    "$isolation_mode" \
    "$os_user" \
    "$replace_existing" \
    "$agent_class" \
    "$loop_explicit_off" \
    "$idle_timeout_value" <<'PY'
from pathlib import Path
import shlex
import sys
import re

(
    path_str,
    agent,
    description,
    engine,
    session,
    workdir,
    profile_home,
    launch_cmd,
    channels,
    discord_channel,
    notify_kind,
    notify_target,
    notify_account,
    loop_mode,
    continue_mode,
    always_on,
    isolation_mode,
    os_user,
    replace_existing,
    agent_class,
    loop_explicit_off,
    idle_timeout_value,
) = sys.argv[1:]

path = Path(path_str)
if path.exists():
    text = path.read_text(encoding="utf-8")
else:
    text = "#!/usr/bin/env bash\n# shellcheck shell=bash disable=SC2034\n"

begin = f"# BEGIN AGENT BRIDGE MANAGED ROLE: {agent}"
end = f"# END AGENT BRIDGE MANAGED ROLE: {agent}"
if replace_existing != "1" and (begin in text or end in text):
    raise SystemExit(f"managed block already exists for {agent}: {path}")

def sq(value: str) -> str:
    return shlex.quote(value)

lines = [
    begin,
    f'bridge_add_agent_id_if_missing {sq(agent)}',
    f'BRIDGE_AGENT_DESC["{agent}"]={sq(description)}',
    f'BRIDGE_AGENT_ENGINE["{agent}"]={sq(engine)}',
    f'BRIDGE_AGENT_SESSION["{agent}"]={sq(session)}',
    f'BRIDGE_AGENT_WORKDIR["{agent}"]={sq(workdir)}',
    f'BRIDGE_AGENT_SOURCE["{agent}"]="static"',
    f'BRIDGE_AGENT_LAUNCH_CMD["{agent}"]={sq(launch_cmd)}',
]
if profile_home:
    lines.append(f'BRIDGE_AGENT_PROFILE_HOME["{agent}"]={sq(profile_home)}')
if channels:
    lines.append(f'BRIDGE_AGENT_CHANNELS["{agent}"]={sq(channels)}')
if discord_channel:
    lines.append(f'BRIDGE_AGENT_DISCORD_CHANNEL_ID["{agent}"]={sq(discord_channel)}')
if notify_kind:
    lines.append(f'BRIDGE_AGENT_NOTIFY_KIND["{agent}"]={sq(notify_kind)}')
if notify_target:
    lines.append(f'BRIDGE_AGENT_NOTIFY_TARGET["{agent}"]={sq(notify_target)}')
if notify_account:
    lines.append(f'BRIDGE_AGENT_NOTIFY_ACCOUNT["{agent}"]={sq(notify_account)}')
if loop_mode == "1":
    lines.append(f'BRIDGE_AGENT_LOOP["{agent}"]="1"')
elif loop_explicit_off == "1":
    # Issue #580 Track 2: `agent update --loop off` opt-in. The legacy
    # writer only emitted LOOP="1" and silently dropped LOOP="0", which
    # made `--loop off` a no-op against bridge_agent_loop's default-1
    # fallback (lib/bridge-agents.sh:6439). Emit the explicit-off line
    # only when the caller opted in via the new positional, so existing
    # `agent create` / `reclassify` callers (which pass <19 args or
    # leave loop_explicit_off empty) keep producing byte-identical role
    # blocks.
    lines.append(f'BRIDGE_AGENT_LOOP["{agent}"]="0"')
if continue_mode == "1":
    lines.append(f'BRIDGE_AGENT_CONTINUE["{agent}"]="1"')
else:
    lines.append(f'BRIDGE_AGENT_CONTINUE["{agent}"]="0"')
# Issue #1093: explicit idle_timeout_value (any non-empty digit string)
# takes precedence over the legacy always_on flag. `--idle-timeout 0` and
# `--always-on` therefore emit the same `"0"` line; `--idle-timeout 300`
# writes `"300"`. The legacy path (always_on=="1", value empty) keeps the
# byte-identical pre-#1093 emission for the create / reclassify callers
# that do not supply positional 21.
if idle_timeout_value:
    lines.append(f'BRIDGE_AGENT_IDLE_TIMEOUT["{agent}"]="{idle_timeout_value}"')
elif always_on == "1":
    lines.append(f'BRIDGE_AGENT_IDLE_TIMEOUT["{agent}"]="0"')
if isolation_mode:
    # Emit the isolation mode verbatim (including "shared") so roster
    # round-trips preserve explicit configuration. Downstream tooling that
    # distinguishes "unset" from "shared" relies on this being present.
    lines.append(f'BRIDGE_AGENT_ISOLATION_MODE["{agent}"]={sq(isolation_mode)}')
if os_user:
    lines.append(f'BRIDGE_AGENT_OS_USER["{agent}"]={sq(os_user)}')
if agent_class:
    # Issue #580 Track 2: agent class is the privilege boundary
    # (lib/bridge-agents.sh:397-405). Operator-supplied values are
    # validated against bridge_validate_agent_classes (closed
    # {user, system}); the writer only sees pre-validated input.
    lines.append(f'BRIDGE_AGENT_CLASS["{agent}"]={sq(agent_class)}')
lines.append(end)

block = "\n".join(lines) + "\n"
if begin in text or end in text:
    pattern = re.compile(
        rf"^# BEGIN AGENT BRIDGE MANAGED ROLE: {re.escape(agent)}\n.*?^# END AGENT BRIDGE MANAGED ROLE: {re.escape(agent)}\n?",
        flags=re.MULTILINE | re.DOTALL,
    )
    if not pattern.search(text):
        raise SystemExit(f"managed block is malformed for {agent}: {path}")
    text = pattern.sub(block, text)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    if text and not text.endswith("\n\n"):
        text += "\n"
    text += block

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(text, encoding="utf-8")
print(path)
PY
}

bridge_agent_session_type_from_home() {
  local agent="$1"
  local path=""
  local line=""

  for path in \
      "$(bridge_agent_workdir "$agent")/SESSION-TYPE.md" \
      "$(bridge_agent_default_home "$agent")/SESSION-TYPE.md" \
      "$BRIDGE_AGENT_HOME_ROOT/$agent/SESSION-TYPE.md"; do
    [[ -f "$path" ]] || continue
    line="$(grep -E 'Session Type:[[:space:]]*[A-Za-z0-9._-]+' "$path" 2>/dev/null | head -n 1 || true)"
    if [[ "$line" =~ Session[[:space:]]+Type:[[:space:]]*([A-Za-z0-9._-]+) ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done

  return 1
}

bridge_agent_canonical_dir() {
  local path="$1"
  local resolved=""
  # Issue #731: under linux-user isolation the controller user has stat
  # permission on the parent + lookup on the entry (so `[[ -d ]]` is true)
  # but not traverse on the directory itself when the workdir is owned by
  # a separate Linux user with mode 2750. The plain `cd -P` aborts the
  # subshell silently and the caller hands an empty payload to downstream
  # JSON parsers (`bridge-upgrade.sh` SHARED_SETTINGS_RERENDER_JSON), which
  # then surfaces as a raw JSONDecodeError traceback. Mirror the v0.8
  # sudo-handoff trio (PR #718) by retrying through `bridge_linux_sudo_root`
  # before falling back to a path passthrough.
  if [[ -d "$path" ]]; then
    resolved="$( (cd -P "$path" 2>/dev/null && pwd -P) || true)"
    if [[ -z "$resolved" ]] && command -v bridge_linux_sudo_root >/dev/null 2>&1; then
      resolved="$(bridge_linux_sudo_root sh -c 'cd -P "$1" && pwd -P' _ "$path" 2>/dev/null || true)"
    fi
    if [[ -n "$resolved" ]]; then
      printf '%s' "$resolved"
    else
      printf '%s' "$path"
    fi
  else
    printf '%s' "$path"
  fi
}

bridge_agent_has_static_admin_shape() {
  local agent="$1"
  local workdir=""
  local default_home=""
  local legacy_home=""
  local v2_workdir=""
  local session_type=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 1
  session_type="$(bridge_agent_session_type_from_home "$agent" 2>/dev/null || true)"
  [[ "$session_type" == "admin" ]] || return 1

  workdir="$(bridge_agent_canonical_dir "$(bridge_expand_user_path "$(bridge_agent_workdir "$agent")")")"
  default_home="$(bridge_agent_canonical_dir "$(bridge_expand_user_path "$(bridge_agent_default_home "$agent")")")"
  legacy_home="$(bridge_agent_canonical_dir "$(bridge_expand_user_path "$BRIDGE_AGENT_HOME_ROOT/$agent")")"
  if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
    v2_workdir="$(bridge_agent_canonical_dir "$(bridge_expand_user_path "$BRIDGE_AGENT_ROOT_V2/$agent/workdir")")"
  fi
  [[ -n "$workdir" && ( "$workdir" == "$default_home" || "$workdir" == "$legacy_home" || "$workdir" == "$v2_workdir" ) ]] || return 1

  [[ -f "$workdir/SOUL.md" || -f "$default_home/SOUL.md" || -f "$legacy_home/SOUL.md" ]] || return 1
  return 0
}

bridge_roster_local_mentions_agent() {
  local agent="$1"
  local file="$BRIDGE_ROSTER_LOCAL_FILE"

  bridge_agent_manage_python "$file" "$agent" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
agent = sys.argv[2]
text = path.read_text(encoding="utf-8", errors="ignore") if path.exists() else ""
patterns = [
    rf"^# BEGIN AGENT BRIDGE MANAGED ROLE: {re.escape(agent)}$",
    rf"^BRIDGE_AGENT_[A-Z_]+\[[\"']{re.escape(agent)}[\"']\]=",
]
raise SystemExit(0 if any(re.search(pattern, text, re.M) for pattern in patterns) else 1)
PY
}

bridge_roster_local_upsert_scalar() {
  local key="$1"
  local value="$2"
  local file="$BRIDGE_ROSTER_LOCAL_FILE"

  bridge_agent_manage_python "$file" "$key" "$value" <<'PY'
from pathlib import Path
import re
import shlex
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
text = path.read_text(encoding="utf-8") if path.exists() else "#!/usr/bin/env bash\n# shellcheck shell=bash disable=SC2034\n"
rendered = f"{key}={shlex.quote(value)}"
pattern = re.compile(rf"^{re.escape(key)}=.*$", flags=re.MULTILINE)
if pattern.search(text):
    text = pattern.sub(rendered, text)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += rendered + "\n"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(text, encoding="utf-8")
PY
}

bridge_agent_reclassify_static_admin() {
  local agent="$1"
  local old_source="$2"
  local reason="$3"
  local description engine session workdir profile_home launch_cmd channels discord_channel
  local notify_kind notify_target notify_account loop_mode continue_mode always_on isolation_mode os_user

  description="$(bridge_agent_desc "$agent")"
  [[ -n "$description" ]] || description="$agent static admin role"
  engine="$(bridge_agent_engine "$agent")"
  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || session="$agent"
  workdir="$(bridge_expand_user_path "$(bridge_agent_workdir "$agent")")"
  profile_home="$(bridge_expand_user_path "$(bridge_agent_profile_home "$agent")")"
  launch_cmd="$(bridge_agent_launch_cmd_raw "$agent")"
  [[ -n "$launch_cmd" ]] || launch_cmd="$(bridge_agent_default_launch_cmd "$engine")"
  channels="$(bridge_agent_channels_csv "$agent")"
  discord_channel="$(bridge_agent_discord_channel_id "$agent")"
  notify_kind="$(bridge_agent_notify_kind "$agent")"
  notify_target="$(bridge_agent_notify_target "$agent")"
  notify_account="$(bridge_agent_notify_account "$agent")"
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  always_on=0
  [[ "$(bridge_agent_idle_timeout "$agent")" == "0" ]] && always_on=1
  isolation_mode="$(bridge_agent_isolation_mode "$agent")"
  os_user="$(bridge_agent_os_user "$agent")"

  bridge_write_role_block \
    "$agent" \
    "$description" \
    "$engine" \
    "$session" \
    "$workdir" \
    "$profile_home" \
    "$launch_cmd" \
    "$channels" \
    "$discord_channel" \
    "$notify_kind" \
    "$notify_target" \
    "$notify_account" \
    "$loop_mode" \
    "$continue_mode" \
    "$always_on" \
    "$isolation_mode" \
    "$os_user" \
    1 >/dev/null

  BRIDGE_AGENT_SOURCE["$agent"]="static"
  # Issue #4769 (reverts #517): reclassify no longer writes
  # BRIDGE_ADMIN_AGENT_ID. The previous behavior fired both from the
  # operator-invoked `agent reclassify --apply` path AND from
  # `bridge-upgrade.sh`'s automatic reclassify pass on every non-dry-run
  # upgrade (bridge-upgrade.sh:1396-1400) — which is the exact
  # silent-backfill regression #4769 removes. Reclassify is now strictly
  # source-classification repair: it flips the in-memory + roster
  # `BRIDGE_AGENT_SOURCE[$agent]` to `static` and emits the audit row.
  # The admin scalar is written exclusively by `agent-bridge setup admin
  # <agent>` (bridge-setup.sh:run_admin). Operators recovering from a
  # stale dynamic-vs-static misclassification on an admin agent run
  # `agent reclassify --apply` THEN `setup admin <agent>` — see
  # docs/agent-runtime/admin-protocol.md §"Admin pair contract".
  bridge_audit_log "$(bridge_admin_agent_id 2>/dev/null || printf bridge-upgrade)" "agent_source_reclassified" "$agent" \
    --detail old_source="$old_source" \
    --detail new_source=static \
    --detail reason="$reason" >/dev/null 2>&1 || true
}

emit_create_json() {
  local agent="$1"
  local engine="$2"
  local session="$3"
  local workdir="$4"
  local profile_home="$5"
  local launch_cmd="$6"
  local channels="$7"
  local roster_file="$8"
  local dry_run="$9"
  local users_json="${10}"
  local session_type="${11}"
  local isolation_mode="${12}"
  local os_user="${13}"
  # Issue #1093: surface the persisted idle_timeout / loop policy in the
  # JSON envelope so the caller can verify what landed in the roster.
  # Optional positionals (default empty) keep existing callers working.
  # `idle_timeout` mirrors what the writer emitted: empty for "no
  # IDLE_TIMEOUT line" (i.e. default-0 fallback), "0" for always-on, or
  # the explicit value supplied to `--idle-timeout <seconds>`. `loop`
  # mirrors the writer: "yes" when LOOP="1" line is present, "no" when
  # LOOP="0", empty when the line was omitted (default-1 fallback).
  local idle_timeout_persisted="${14:-}"
  local loop_persisted="${15:-}"
  # Issue #1136: declarative direction the operator passed via
  # `--always-on yes|no` (legacy bare `--always-on` is `yes`). Empty when
  # the flag wasn't used. Surfaced as `policy.expressed_intent` in the
  # JSON envelope; omitted entirely when empty so callers that didn't
  # pass the flag see a byte-stable envelope.
  local expressed_intent="${16:-}"
  # Beta20 L2 Variant 3A — daemon supplementary-groups refresh status
  # surfaced to JSON callers. One of: ok / skipped-non-linux /
  # skipped-daemon-not-running / skipped-daemon-already-has-group /
  # manual-required-sudoers / manual-required-sudo-refresh-no-gid /
  # failed-restart / failed-timeout / "" (no refresh attempted, e.g.
  # shared-mode agent). When status is in the manual-required-* /
  # failed-* family, the envelope also carries `manual_command` with
  # the exact recovery command.
  local daemon_group_refresh="${17:-}"

  bridge_agent_manage_python "$agent" "$engine" "$session" "$workdir" "$profile_home" "$launch_cmd" "$channels" "$roster_file" "$dry_run" "$users_json" "$session_type" "$isolation_mode" "$os_user" "$idle_timeout_persisted" "$loop_persisted" "$expressed_intent" "$daemon_group_refresh" <<'PY'
import json
import sys

agent, engine, session, workdir, profile_home, launch_cmd, channels, roster_file, dry_run, users_json, session_type, isolation_mode, os_user, idle_timeout_persisted, loop_persisted, expressed_intent, daemon_group_refresh = sys.argv[1:]
policy = {
    "idle_timeout": idle_timeout_persisted,
    "loop": loop_persisted,
}
if expressed_intent:
    policy["expressed_intent"] = expressed_intent
payload = {
    "agent": agent,
    "engine": engine,
    "session_type": session_type,
    "session": session,
    "workdir": workdir,
    "profile_home": profile_home,
    "launch_cmd": launch_cmd,
    "channels": channels,
    "isolation": {
        "mode": isolation_mode,
        "os_user": os_user,
    },
    "roster_file": roster_file,
    "dry_run": dry_run == "1",
    "users": json.loads(users_json),
    "policy": policy,
    "next_steps": [
        f"agent-bridge setup agent {agent}",
        f"agent-bridge status --all-agents",
        f"bash bridge-start.sh {agent} --dry-run",
    ],
}
# Beta20 L2 Variant 3A — only emit the field when refresh was actually
# attempted (linux-user isolation on Linux). Shared-mode / macOS callers
# see a byte-stable envelope without the new key.
if daemon_group_refresh:
    payload["daemon_group_refresh"] = daemon_group_refresh
    if daemon_group_refresh == "manual-required-sudoers":
        payload["manual_command"] = "agent-bridge init sudoers daemon-refresh --apply"
    elif daemon_group_refresh == "manual-required-sudo-refresh-no-gid":
        payload["manual_command"] = "bash bridge-daemon.sh restart --force"
    elif daemon_group_refresh in ("failed-restart", "failed-timeout"):
        payload["manual_command"] = "bash bridge-daemon.sh restart --force"
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

bridge_agent_queue_maps() {
  local -n queued_ref="$1"
  local -n claimed_ref="$2"
  local -n blocked_ref="$3"
  local summary_output=""
  local agent_name=""
  local queued=""
  local claimed=""
  local blocked=""

  if ! summary_output="$(bridge_queue_cli summary --format tsv 2>/dev/null || true)"; then
    return 0
  fi

  while IFS=$'\t' read -r agent_name queued claimed blocked _active _idle _last_seen _last_nudge _session _engine _workdir; do
    [[ -n "$agent_name" ]] || continue
    queued_ref["$agent_name"]="${queued:-0}"
    claimed_ref["$agent_name"]="${claimed:-0}"
    blocked_ref["$agent_name"]="${blocked:-0}"
  done <<<"$summary_output"
}

bridge_agent_activity_state() {
  local agent="$1"
  local session=""
  local engine=""

  if ! bridge_agent_is_active "$agent"; then
    printf '%s' "stopped"
    return 0
  fi

  session="$(bridge_agent_session "$agent")"
  engine="$(bridge_agent_engine "$agent")"
  if bridge_tmux_session_has_prompt "$session" "$engine"; then
    printf '%s' "idle"
    return 0
  fi

  # Issue #835 Wave B: tmux exists but no claude/codex descendant in the
  # pane process tree → starting/stalled before engine. Without this,
  # `agb agent show` showed `working` for a wedged static admin (operator
  # 2026-05-14 incident, #835).
  if bridge_tmux_engine_requires_prompt "$engine" \
      && ! bridge_agent_engine_process_alive "$agent" "$engine"; then
    printf '%s' "starting"
    return 0
  fi

  printf '%s' "working"
}

bridge_agent_actions_csv() {
  local agent="$1"
  local actions=""

  actions="$(bridge_list_actions "$agent" | paste -sd ',' -)"
  printf '%s' "${actions:--}"
}

bridge_agent_records_tsv() {
  local selected_agent="${1:-}"
  local agent=""
  local active=""
  local profile_home=""
  local profile_source=""
  local always_on=""
  local admin=""
  local -A queued_counts=()
  local -A claimed_counts=()
  local -A blocked_counts=()

  bridge_agent_queue_maps queued_counts claimed_counts blocked_counts
  echo -e "agent\tdescription\tengine\tsource\tsession\tsession_id\tworkdir\tprofile_home\tprofile_source\tactive\tactivity_state\tloop\tcontinue\talways_on\tidle_timeout\twake_status\tnotify_status\tchannel_status\tchannels\tnotify_kind\tnotify_target\tnotify_account\tdiscord_channel_id\tisolation_mode\tos_user\tqueue_queued\tqueue_claimed\tqueue_blocked\tactions\tadmin"

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ -n "$selected_agent" && "$agent" != "$selected_agent" ]]; then
      continue
    fi

    active="no"
    if bridge_agent_is_active "$agent"; then
      active="yes"
    fi

    profile_home="$(bridge_agent_profile_home "$agent")"
    if [[ -z "$profile_home" ]]; then
      profile_home="$(bridge_resolve_profile_target "$agent" 2>/dev/null || true)"
    fi

    profile_source="no"
    if bridge_profile_has_source "$agent"; then
      profile_source="yes"
    fi

    always_on="no"
    if bridge_agent_is_always_on "$agent"; then
      always_on="yes"
    fi

    admin="no"
    if [[ "$agent" == "$(bridge_admin_agent_id)" ]]; then
      admin="yes"
    fi

    echo -e "${agent}\t$(bridge_agent_desc "$agent")\t$(bridge_agent_engine "$agent")\t$(bridge_agent_source "$agent")\t$(bridge_agent_session "$agent")\t$(bridge_agent_session_id "$agent")\t$(bridge_agent_workdir "$agent")\t${profile_home}\t${profile_source}\t${active}\t$(bridge_agent_activity_state "$agent")\t$(bridge_agent_loop "$agent")\t$(bridge_agent_continue "$agent")\t${always_on}\t$(bridge_agent_idle_timeout "$agent")\t$(bridge_agent_wake_status "$agent")\t$(bridge_agent_notify_status "$agent")\t$(bridge_agent_channel_status "$agent")\t$(bridge_agent_channels_csv "$agent")\t$(bridge_agent_notify_kind "$agent")\t$(bridge_agent_notify_target "$agent")\t$(bridge_agent_notify_account "$agent")\t$(bridge_agent_discord_channel_id "$agent")\t$(bridge_agent_isolation_mode "$agent")\t$(bridge_agent_os_user_display "$agent")\t${queued_counts[$agent]-0}\t${claimed_counts[$agent]-0}\t${blocked_counts[$agent]-0}\t$(bridge_agent_actions_csv "$agent")\t${admin}"
  done
}

emit_agent_records_json() {
  local mode="$1"
  local tsv="$2"
  # v0.8.0 T5: snapshot the runtime isolation state once per emit (it
  # is a controller-process-wide value, not per-agent) and pass it as a
  # third argv so every JSON record carries the same string. The
  # alternative — adding a TSV column — would touch the schema in 4
  # places (header, row builder, local-var declaration, JSON
  # conversion) for a value that is identical across all rows.
  local runtime_state
  runtime_state="$(bridge_isolation_runtime_state)"

  bridge_agent_manage_python "$mode" "$tsv" "$runtime_state" <<'PY'
import csv
import io
import json
import sys

mode = sys.argv[1]
rows = list(csv.DictReader(io.StringIO(sys.argv[2]), delimiter="\t"))
runtime_state = sys.argv[3] if len(sys.argv) > 3 else ""
bool_fields = {"active", "profile_source", "always_on", "admin"}
int_fields = {"loop", "continue", "idle_timeout", "queue_queued", "queue_claimed", "queue_blocked"}

def convert_value(key: str, value: str):
    if key in bool_fields:
        return value == "yes"
    if key in int_fields:
        try:
            return int(value)
        except Exception:
            return 0
    return value

def convert_row(row: dict) -> dict:
    converted = {key: convert_value(key, value) for key, value in row.items()}
    return {
        "agent": converted["agent"],
        "description": converted["description"],
        "engine": converted["engine"],
        "source": converted["source"],
        "session": converted["session"],
        "session_id": converted["session_id"],
        "workdir": converted["workdir"],
        "profile": {
            "home": converted["profile_home"],
            "source_present": converted["profile_source"],
        },
        "active": converted["active"],
        "activity_state": converted["activity_state"],
        "loop": converted["loop"],
        "continue": converted["continue"],
        "always_on": converted["always_on"],
        "idle_timeout": converted["idle_timeout"],
        "wake_status": converted["wake_status"],
        "notify": {
            "status": converted["notify_status"],
            "kind": converted["notify_kind"],
            "target": converted["notify_target"],
            "account": converted["notify_account"],
        },
        "channels": {
            "status": converted["channel_status"],
            "required": converted["channels"],
            "discord_channel_id": converted["discord_channel_id"],
        },
        "isolation": {
            "mode": converted["isolation_mode"],
            "os_user": converted["os_user"],
            "runtime_state": runtime_state,
        },
        "queue": {
            "queued": converted["queue_queued"],
            "claimed": converted["queue_claimed"],
            "blocked": converted["queue_blocked"],
        },
        "actions": [] if converted["actions"] in ("", "-") else converted["actions"].split(","),
        "admin": converted["admin"],
    }

payload = [convert_row(row) for row in rows]
if mode == "show":
    if len(payload) != 1:
        raise SystemExit("expected exactly one agent record")
    print(json.dumps(payload[0], ensure_ascii=False, indent=2))
else:
    print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

run_list() {
  local json_mode=0
  local output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json_mode=1
        shift
        ;;
      -h|--help|help)
        # Issue #1114: `agent list --help` was caught by the `*)` arm
        # as a "지원하지 않는 옵션" error.
        cat <<'AGENT_LIST_HELP'
Usage: agent-bridge agent list [--json]

List every agent known on this host (active sessions and roster
entries) as a human-readable table, or as JSON with --json.
AGENT_LIST_HELP
        return 0
        ;;
      *)
        bridge_die "지원하지 않는 agent list 옵션입니다: $1"
        ;;
    esac
  done

  output="$(bridge_agent_records_tsv)"
  if [[ $json_mode -eq 1 ]]; then
    emit_agent_records_json list "$output"
    return 0
  fi
  # Bash 5.3.9 deadlock (footgun #11, KNOWN_ISSUES.md §26 — refs queue
  # task #4773): the original form
  # `bridge_agent_manage_python "$(emit_agent_records_json list "$output")" <<'PY'`
  # nested two heredoc-stdin python3 subprocesses (emit_agent_records_json
  # itself is a `python3 - "$tsv" <<'PY'` consumer), and the
  # function-wrapper + heredoc-stdin combination wedged `read_comsub` on
  # operator hosts (7-17 hour hangs on `agent list`). Spool the JSON to a
  # tempfile and dispatch to a standalone helper script — no
  # heredoc-stdin anywhere on the call path. Same precedent as
  # lib/upgrade-helpers/agent-restart-json.py.
  bridge_require_python
  local _list_dir _list_rc
  _list_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-agent-list-json.XXXXXX")"
  emit_agent_records_json list "$output" >"$_list_dir/records.json"
  # codex PR #940 r2 BLOCKING: RETURN trap does NOT fire on `set -e`
  # errexit abort (Bash 5.3.9 forced-failure probe confirmed). Use the
  # explicit set +e / capture-rc / set -e pattern so cleanup ALWAYS runs
  # regardless of helper rc, and propagate the helper's exit status.
  set +e
  python3 "$SCRIPT_DIR/lib/agent-cli-helpers/list-format-text.py" "$_list_dir/records.json"
  _list_rc=$?
  set -e
  rm -rf "$_list_dir"
  return "$_list_rc"
}

# run_registry — issue #598 Track 1. Read-only enumeration of every
# agent id known on this host (static + dynamic + system) with the
# provenance tag for the loader that surfaced each id. Intended for
# tooling that needs class + provenance together (cleanup detectors,
# retirement scripts) without re-implementing roster parsing. Sibling
# to `agent list` — does not modify state and does not replace
# `agent list`'s human/JSON shape.
#
# Output schema (JSON array sorted by `id` for stable diffs):
#   id              agent name
#   class           cleanup-class: system > dynamic > static
#                   (system wins so cleanup tools never reap a
#                   privileged static agent purely on source=static)
#   agent_source    raw bridge_agent_source: static | dynamic
#   privilege_class raw bridge_agent_class: user | system
#   home            bridge_agent_default_home (live agent home root)
#   workdir         bridge_agent_workdir
#   engine          bridge_agent_engine
#   session         bridge_agent_session
#   is_alive        bridge_agent_is_active (tmux session exists)
#   source          provenance: static-roster | dynamic-active-env |
#                   dynamic-history-live-session | dynamic-tmux-recovered
run_registry() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        # Currently the only output mode. Accept the flag for
        # symmetry with `agent list --json` so callers can keep a
        # single argv shape across both endpoints.
        shift
        ;;
      -h|--help|help)
        # Issue #1114: `agent registry --help` was caught by the `*)`
        # arm as a "지원하지 않는 옵션" error.
        cat <<'AGENT_REGISTRY_HELP'
Usage: agent-bridge agent registry [--json]

Read-only enumeration of every agent id known on this host
(static + dynamic + system) with cleanup-class and provenance.
JSON-only by design — the human shape is `agent list`.
AGENT_REGISTRY_HELP
        return 0
        ;;
      *)
        bridge_die "지원하지 않는 agent registry 옵션입니다: $1"
        ;;
    esac
  done

  local agent
  local agent_source
  local privilege_class
  local cleanup_class
  local home
  local workdir
  local engine
  local session
  local provenance
  local is_alive
  local rows=""

  if declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 && (( ${#BRIDGE_AGENT_IDS[@]} > 0 )); then
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      agent_source="$(bridge_agent_source "$agent")"
      privilege_class="$(bridge_agent_class "$agent")"
      # cleanup_class: system > dynamic > static. Operators consuming
      # `class` to decide reap-or-keep see "system" for privileged
      # agents regardless of how the roster surfaced them. The raw
      # static/dynamic split stays available via agent_source.
      if [[ "$privilege_class" == "system" ]]; then
        cleanup_class="system"
      elif [[ "$agent_source" == "dynamic" ]]; then
        cleanup_class="dynamic"
      else
        cleanup_class="static"
      fi
      home="$(bridge_agent_default_home "$agent")"
      workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || printf '')"
      engine="$(bridge_agent_engine "$agent")"
      session="$(bridge_agent_session "$agent")"
      provenance="$(bridge_agent_provenance "$agent")"
      if bridge_agent_is_active "$agent"; then
        is_alive="1"
      else
        is_alive="0"
      fi
      rows+=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$agent" \
        "$cleanup_class" \
        "$agent_source" \
        "$privilege_class" \
        "$home" \
        "$workdir" \
        "$engine" \
        "$session" \
        "$is_alive" \
        "$provenance")
      rows+=$'\n'
    done
  fi

  # Bash 5.3.9 deadlock (footgun #11 — refs queue task #4773): the
  # original form `bridge_agent_manage_python "$rows" <<'PY'` wedged
  # `read_comsub` on the operator host even though no `$()` capture
  # surrounded the call. The function-wrapper indirection through
  # `bridge_agent_manage_python` (which expands to `python3 - "$@"`)
  # combined with heredoc-stdin reliably hung 7-17 hours during
  # `bridge-agent.sh registry` on bash 5.3.9. Spool rows to a tempfile
  # and dispatch to a standalone helper — same precedent as
  # lib/upgrade-helpers/agent-restart-json.py.
  bridge_require_python
  local _registry_dir _registry_rc
  _registry_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-agent-registry.XXXXXX")"
  printf '%s' "$rows" >"$_registry_dir/rows.tsv"
  # codex PR #940 r2 BLOCKING: see run_list above for the RETURN-trap-
  # bypass rationale. Same explicit set +e / capture-rc / set -e pattern
  # ensures the tempdir is removed regardless of helper rc.
  set +e
  python3 "$SCRIPT_DIR/lib/agent-cli-helpers/registry-format-json.py" "$_registry_dir/rows.tsv"
  _registry_rc=$?
  set -e
  rm -rf "$_registry_dir"
  return "$_registry_rc"
}

# Issue #780 — multi-signal alive determination for `agent show --json`.
#
# Controller-side health probe historically only checked tmux session
# existence. That yields `alive=null` (or implicit-false) when the agent
# itself is running outside a tmux session (systemd-direct, dynamic
# detach, custom launcher) but its channel servers / claude session are
# alive. The new `alive` field is the OR of three signals so any one
# being live is enough to report `alive=true`:
#
#   1. tmux  — `bridge_agent_is_active` (existing single signal)
#   2. pid   — `<agent_home>/runtime/agent.pid` exists + the PID is alive
#              (kill -0). Future systemd-unit signal can be folded in
#              here by adding more sources of truth without changing the
#              public field shape.
#   3. channel — at least one channel plugin port from
#                `bridge_agent_plugin_ports` is in LISTEN state. Delegates
#                to `bridge_port_is_listening` (Track D / #779, lives in
#                lib/bridge-agents.sh) so the LISTEN probe stays a single
#                source of truth. We treat *any* port that this agent is
#                supposed to bind as a positive channel signal — channel
#                plugins only listen while the agent runtime is alive.
#
# Zombie tmux protection: when the tmux session exists but agent
# processes are dead, we still report alive=true based on the tmux
# signal. That's an accepted residue — `agent-bridge doctor` is the
# path to detect zombies.
bridge_agent_alive_pid_signal() {
  local agent="$1"
  local home=""
  local pid_file=""
  local pid_raw=""

  home="$(bridge_agent_default_home "$agent" 2>/dev/null || true)"
  [[ -n "$home" ]] || return 1
  pid_file="$home/runtime/agent.pid"
  [[ -f "$pid_file" ]] || return 1
  pid_raw="$(head -n 1 "$pid_file" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$pid_raw" && "$pid_raw" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid_raw" 2>/dev/null
}

bridge_agent_alive_port_is_listening() {
  # Delegate to the canonical LISTEN probe shipped by Track D (#779) in
  # lib/bridge-agents.sh. bridge-agent.sh loads bridge-lib.sh →
  # bridge-agents.sh at startup, so the helper is always defined here.
  # No defensive fallback: keeping a forbidden heredoc-stdin Python
  # callsite around as "just in case" violates the #800 deadlock-class
  # convention (PR #801) and the branch can never reach it in practice.
  local port="$1"
  [[ -n "$port" ]] || return 1
  bridge_port_is_listening "$port"
}

bridge_agent_alive_channel_signal() {
  local agent="$1"
  local line=""
  local port=""

  if ! type bridge_agent_plugin_ports >/dev/null 2>&1; then
    return 1
  fi
  # bridge_agent_plugin_ports emits one "<port>\t<binary>\t<plugin>" per
  # known long-lived listener for the agent. Any one in LISTEN is enough.
  while IFS=$'\t' read -r port _ _; do
    [[ -n "$port" ]] || continue
    if bridge_agent_alive_port_is_listening "$port"; then
      return 0
    fi
  done < <(bridge_agent_plugin_ports "$agent" 2>/dev/null || true)
  return 1
}

bridge_agent_alive_signals_json() {
  local agent="$1"
  local tmux_signal="false"
  local pid_signal="false"
  local channel_signal="false"
  local alive="false"

  if bridge_agent_is_active "$agent" 2>/dev/null; then
    tmux_signal="true"
  fi
  if bridge_agent_alive_pid_signal "$agent" 2>/dev/null; then
    pid_signal="true"
  fi
  if bridge_agent_alive_channel_signal "$agent" 2>/dev/null; then
    channel_signal="true"
  fi
  if [[ "$tmux_signal" == "true" || "$pid_signal" == "true" || "$channel_signal" == "true" ]]; then
    alive="true"
  fi
  printf '{"alive":%s,"signals":{"tmux":%s,"pid":%s,"channel":%s}}' \
    "$alive" "$tmux_signal" "$pid_signal" "$channel_signal"
}

run_show() {
  local agent="${1:-}"
  local json_mode=0
  local output=""

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") show <agent> [--json]"
  bridge_require_agent "$agent"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json_mode=1
        shift
        ;;
      *)
        bridge_die "지원하지 않는 agent show 옵션입니다: $1"
        ;;
    esac
  done

  output="$(bridge_agent_records_tsv "$agent")"
  if [[ $json_mode -eq 1 ]]; then
    # session_source surfaces which authoritative state file currently
    # supplies AGENT_SESSION_ID for this agent (issue #268). Default text
    # output is intentionally unchanged; only --json exposes the path so
    # operators can pipe it into recovery scripts (e.g. forget-session
    # follow-ups) without parsing the human format.
    #
    # alive (issue #780): multi-signal OR (tmux | pid | channel LISTEN)
    # written alongside the existing `active` field. `active` stays as
    # the tmux-only signal so callers that depend on the old meaning
    # are unchanged; `alive` is the new operator-facing health value.
    #
    # Bash 5.3.9 deadlock (footgun #11 — refs queue task #4773): the
    # original form chained four nested `$()` captures (three of which
    # were themselves `python3 - <<'PY'` heredoc-stdin consumers) into a
    # `bridge_agent_manage_python ... <<'PY'` parent heredoc reader. The
    # combination wedged `read_comsub` on the operator host. Spool each
    # input to a tempfile and dispatch to a standalone helper —
    # same precedent as lib/upgrade-helpers/agent-restart-json.py.
    bridge_require_python
    local _show_dir _show_rc
    _show_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-agent-show.XXXXXX")"
    emit_agent_records_json show "$output" >"$_show_dir/records.json"
    bridge_agent_channel_diagnostics_json "$agent" >"$_show_dir/diagnostics.json"
    bridge_agent_session_health_json "$agent" >"$_show_dir/session-health.json"
    bridge_agent_alive_signals_json "$agent" >"$_show_dir/alive.json"
    bridge_agent_session_source_path "$agent" >"$_show_dir/session-source.txt"
    # codex PR #940 r2 BLOCKING: see run_list above for the RETURN-trap-
    # bypass rationale. Same explicit set +e / capture-rc / set -e pattern
    # ensures the tempdir is removed regardless of helper rc. Cleanup
    # lives INSIDE this json_mode branch so the text-mode path (which
    # never created _show_dir) does not try to rm a non-existent dir.
    set +e
    python3 "$SCRIPT_DIR/lib/agent-cli-helpers/show-format-json.py" \
      "$_show_dir/records.json" \
      "$_show_dir/diagnostics.json" \
      "$_show_dir/session-health.json" \
      "$_show_dir/session-source.txt" \
      "$_show_dir/alive.json"
    _show_rc=$?
    set -e
    rm -rf "$_show_dir"
    return "$_show_rc"
  fi

  # Issue 6 (v0.11.0): tab-separated rows with potentially-empty middle
  # fields (notably session_id) cannot be parsed with `IFS=$'\t' read`
  # — tab is whitespace, so Bash collapses adjacent tabs and every
  # field after the empty one shifts by a slot. Symptom: `session_id:`
  # showed the workdir path. Fix: translate tab to a non-whitespace
  # sentinel (US, 0x1F), then split on the sentinel so empty fields
  # round-trip correctly. Pure Bash 4 (no `readarray -d`).
  local _tsv_line=""
  local _tsv_sep
  _tsv_sep=$'\x1f'
  local -a _fields=()
  while IFS= read -r _tsv_line; do
    [[ -n "$_tsv_line" ]] || continue
    _fields=()
    IFS="$_tsv_sep" read -r -a _fields <<<"${_tsv_line//$'\t'/$_tsv_sep}"
    # Guard against producer/consumer drift. The header in
    # bridge_agent_records_tsv emits exactly 30 columns; any other
    # count means a schema change landed in the producer without an
    # update here — bail loudly rather than print shifted garbage
    # (the very class of bug this fix repairs).
    if (( ${#_fields[@]} != 30 )); then
      bridge_die "agent show: unexpected TSV column count (${#_fields[@]} != 30); refusing to render"
    fi
    row_agent="${_fields[0]}"
    description="${_fields[1]}"
    engine="${_fields[2]}"
    source="${_fields[3]}"
    session="${_fields[4]}"
    session_id="${_fields[5]}"
    workdir="${_fields[6]}"
    profile_home="${_fields[7]}"
    profile_source="${_fields[8]}"
    active="${_fields[9]}"
    activity_state="${_fields[10]}"
    loop_mode="${_fields[11]}"
    continue_mode="${_fields[12]}"
    always_on="${_fields[13]}"
    idle_timeout="${_fields[14]}"
    wake_status="${_fields[15]}"
    notify_status="${_fields[16]}"
    channel_status="${_fields[17]}"
    channels="${_fields[18]}"
    notify_kind="${_fields[19]}"
    notify_target="${_fields[20]}"
    notify_account="${_fields[21]}"
    discord_channel_id="${_fields[22]}"
    isolation_mode="${_fields[23]}"
    os_user="${_fields[24]}"
    queue_queued="${_fields[25]}"
    queue_claimed="${_fields[26]}"
    queue_blocked="${_fields[27]}"
    actions="${_fields[28]}"
    admin="${_fields[29]}"
    [[ "$row_agent" == "agent" ]] && continue
    printf 'agent: %s\n' "$row_agent"
    printf 'description: %s\n' "$description"
    printf 'engine: %s\n' "$engine"
    printf 'source: %s\n' "$source"
    printf 'admin: %s\n' "$admin"
    printf 'session: %s\n' "$session"
    printf 'session_id: %s\n' "${session_id:--}"
    # Issue #1060 D2: the three-layer agent-layout model exposed as three
    # distinct, resolver-derived lines so `agent show` stops conflating
    # them. `agent_home` is the IDENTITY SOURCE (layer 2 — the authored
    # canonical identity tree); `workdir` is the WORKSPACE (layer 3 — the
    # process cwd the runtime launches in, the value already carried by
    # the TSV `workdir` column = `bridge_agent_workdir`). On a v2 install
    # the two diverge (`<agent-root>/home` vs `<agent-root>/workdir`);
    # before #1060 only `workdir` was shown, so the operator could not
    # tell which tree held the authored identity.
    printf 'workdir: %s\n' "$workdir"
    if declare -F bridge_layout_agent_home >/dev/null 2>&1; then
      printf 'agent_home: %s\n' "$(bridge_layout_agent_home "$row_agent")"
    fi
    printf 'profile_home: %s\n' "${profile_home:--}"
    printf 'profile_source: %s\n' "$profile_source"
    printf 'active: %s\n' "$active"
    printf 'activity_state: %s\n' "$activity_state"
    printf 'loop: %s\n' "$loop_mode"
    printf 'continue: %s\n' "$continue_mode"
    printf 'always_on: %s\n' "$always_on"
    printf 'idle_timeout: %s\n' "$idle_timeout"
    printf 'wake_status: %s\n' "$wake_status"
    printf 'notify_status: %s\n' "$notify_status"
    printf 'notify_kind: %s\n' "${notify_kind:--}"
    printf 'notify_target: %s\n' "${notify_target:--}"
    printf 'notify_account: %s\n' "${notify_account:--}"
    printf 'channel_status: %s\n' "$channel_status"
    printf 'channels: %s\n' "${channels:--}"
    printf 'discord_channel_id: %s\n' "${discord_channel_id:--}"
    printf 'isolation_mode: %s\n' "${isolation_mode:--}"
    # v0.8.0 T5: surface the runtime isolation state alongside the
    # configured isolation_mode. `disabled-by-env` indicates that
    # `BRIDGE_DISABLE_ISOLATION=1` is in the controller environment and
    # the v2 wraps are short-circuited; `v2-active` is the normal
    # post-migration state. Field is additive — existing parsers ignore
    # unknown keys.
    printf 'isolation: %s\n' "$(bridge_isolation_runtime_state)"
    printf 'os_user: %s\n' "${os_user:--}"
    printf 'queue: queued=%s claimed=%s blocked=%s\n' "$queue_queued" "$queue_claimed" "$queue_blocked"
    printf 'actions: %s\n' "$actions"
    printf 'channel_diagnostics:\n'
    bridge_agent_channel_diagnostics_text "$agent" | sed 's/^/  /'
    printf 'session_health:\n'
    bridge_agent_session_guidance_text "$agent" | sed 's/^/  /'
  done <<<"$output"
}

run_reclassify() {
  local selected_agent=""
  local apply=0
  local json_mode=0
  local agent=""
  local old_source=""
  local action=""
  local reason=""
  local workdir=""
  local rows=$'agent\told_source\tnew_source\taction\treason\tworkdir\n'
  local count=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        [[ $# -ge 2 ]] || bridge_die "--agent 뒤에 값을 지정하세요."
        selected_agent="$2"
        shift 2
        ;;
      --apply)
        apply=1
        shift
        ;;
      --dry-run)
        apply=0
        shift
        ;;
      --json)
        json_mode=1
        shift
        ;;
      -h|--help)
        printf 'Usage: %s reclassify [--agent <agent>] [--apply] [--json]\n' "$(basename "$0")"
        return 0
        ;;
      *)
        bridge_die "지원하지 않는 agent reclassify 옵션입니다: $1"
        ;;
    esac
  done

  if [[ -n "$selected_agent" ]]; then
    bridge_require_agent "$selected_agent"
  fi

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ -n "$selected_agent" && "$agent" != "$selected_agent" ]]; then
      continue
    fi

    bridge_agent_has_static_admin_shape "$agent" || continue
    old_source="$(bridge_agent_source "$agent")"
    action=""
    reason=""
    if [[ "$old_source" == "dynamic" ]]; then
      action="reclassify"
      reason="static-admin-shape"
    elif [[ "$old_source" == "static" ]] && ! bridge_roster_local_mentions_agent "$agent"; then
      action="persist"
      reason="static-admin-local-preserve"
    fi
    [[ -n "$action" ]] || continue

    workdir="$(bridge_agent_workdir "$agent")"
    rows+="${agent}"$'\t'"${old_source}"$'\t'"static"$'\t'"${action}"$'\t'"${reason}"$'\t'"${workdir}"$'\n'
    count=$((count + 1))

    if [[ $apply -eq 1 ]]; then
      bridge_agent_reclassify_static_admin "$agent" "$old_source" "$reason"
    fi
  done

  if [[ $json_mode -eq 1 ]]; then
    bridge_agent_manage_python "$apply" "$rows" <<'PY'
import csv
import io
import json
import sys

apply = sys.argv[1] == "1"
rows = list(csv.DictReader(io.StringIO(sys.argv[2]), delimiter="\t"))
print(json.dumps({"mode": "apply" if apply else "dry-run", "count": len(rows), "candidates": rows}, ensure_ascii=False, indent=2))
PY
    return 0
  fi

  printf 'mode: %s\n' "$([[ $apply -eq 1 ]] && printf apply || printf dry-run)"
  if [[ $count -eq 0 ]]; then
    echo "reclassify: no candidates"
    return 0
  fi

  while IFS=$'\t' read -r row_agent row_old row_new row_action row_reason row_workdir; do
    [[ "$row_agent" == "agent" || -z "$row_agent" ]] && continue
    printf '%s: %s old_source=%s new_source=%s reason=%s workdir=%s\n' \
      "$row_action" "$row_agent" "$row_old" "$row_new" "$row_reason" "$row_workdir"
  done <<<"$rows"
}

bridge_agent_shared_settings_plan_json() {
  local agent="$1"
  local workdir="$2"
  local launch_cmd
  local agent_class=""
  local effective_file
  local settings_path_override=""
  local _isolated_active=0
  launch_cmd="$(bridge_agent_launch_cmd_raw "$agent" 2>/dev/null || true)"
  # Issue #593: pass the agent's source class through to the resolver so
  # the plan/diff helper computes the same managed default the renderer
  # will (static→400_000, dynamic→1_000_000). Without this the doctor
  # path would always evaluate the unknown-class fallback (1_000_000) and
  # report `needs-rerender` for every static agent on every run. Gate
  # the lookup so the helper still works when callers haven't loaded
  # the roster (the inline plan-json subprocess treats empty as unknown).
  if declare -p BRIDGE_AGENT_SOURCE >/dev/null 2>&1; then
    agent_class="$(bridge_agent_source "$agent" 2>/dev/null || true)"
  fi

  effective_file="$(bridge_hook_per_agent_settings_effective_file "$agent")"

  # Wave-5 #4282 Scenario B: for v2 linux-user-isolated agents the
  # canonical post-apply settings live under `<isolated-home>/.claude/`,
  # not under `$workdir`. `bridge_install_isolated_home_settings`
  # writes both `settings.json` (root-owned symlink) and
  # `settings.effective.json` (root-owned regular file) into the foreign
  # UID's home, mode 0750 root:os_user — the controller (other) cannot
  # stat or read it without sudo. Reading the workdir-relative paths
  # would always return `link.ok=false` and `effective.matches_expected
  # =false`, so the rerender row reports `needs-rerender` after every
  # successful apply (task #4280 Scenario B `bob` agent surfaced this:
  # rerender --apply rc=0 twice, but bob still showed needs-rerender /
  # link_ok=false / effective_ok=false). Override the python's read
  # targets to the isolated paths and run under sudo so the plan
  # reports the actual post-install state.
  if [[ "$agent" != "_template" ]] \
      && command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    local _os_user _isolated_home
    _os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    if [[ -n "$_os_user" ]]; then
      _isolated_home="$(bridge_agent_linux_user_home "$_os_user" 2>/dev/null || true)"
      if [[ -n "$_isolated_home" ]] \
          && command -v bridge_linux_sudo_root >/dev/null 2>&1; then
        settings_path_override="$_isolated_home/.claude/settings.json"
        effective_file="$_isolated_home/.claude/settings.effective.json"
        _isolated_active=1
      fi
    fi
  fi

  # Issue #555: the rerender now writes the effective file at the
  # per-agent path ($BRIDGE_AGENT_HOME_ROOT/<agent>/.claude/
  # settings.effective.json) for non-isolated agents. For isolated
  # agents the path is overridden to <isolated-home>/.claude/
  # settings.effective.json by the Wave-5 block above. In either case
  # the plan/diff helper must compare against the path the renderer
  # writes to — comparing against the install-wide path would
  # forever report `needs-rerender` after a successful apply.
  #
  # Wave-5 #4282: stage the python body to a temp file so the
  # isolated branch (which must traverse the foreign UID's home and
  # therefore runs the read under sudo) and the non-isolated branch
  # share a single source of truth. Without this the bash function
  # would either duplicate the python verbatim across both branches
  # (which drifts) or only one branch would benefit from future
  # python-side fixes.
  local _plan_py
  # BSD-portable template: macOS BSD `mktemp` only expands trailing `X`
  # sequences. A `.XXXXXX.py` template returns the literal `XXXXXX.py`
  # path, which creates a static file the first time and `File exists`
  # every call after. Patch task #4648 surfaced this after the v0.14.0
  # upgrade on operator's mac — all 8 shared-settings rerender targets
  # failed and required manual cleanup. Drop the `.py` extension; the
  # python heredoc body is executed via `python3 "$_plan_py"` which does
  # not require a `.py` suffix.
  _plan_py="$(mktemp "${TMPDIR:-/tmp}/bridge-rerender-plan.XXXXXX")" || return 1
  cat >"$_plan_py" <<'PY'
import importlib.util
import json
import os
import sys
from pathlib import Path

argv = sys.argv[1:]
hooks_py, agent, workdir, base_file, overlay_file, effective_file, launch_cmd, agent_class = argv[:8]
settings_path_override = argv[8] if len(argv) > 8 else ""
spec = importlib.util.spec_from_file_location("bridge_hooks", hooks_py)
if spec is None or spec.loader is None:
    raise SystemExit(f"could not load {hooks_py}")
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)

if settings_path_override:
    settings_path = Path(settings_path_override).expanduser()
else:
    settings_path = Path(workdir).expanduser() / ".claude" / "settings.json"
base_path = Path(base_file).expanduser()
overlay_path = Path(overlay_file).expanduser()
effective_path = Path(effective_file).expanduser()

errors: list[str] = []

def load_object(path: Path, label: str, *, absent_ok: bool = True) -> dict:
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"{label} invalid JSON: {path}: {exc}")
        return {}
    if payload in (None, ""):
        return {}
    if not isinstance(payload, dict):
        errors.append(f"{label} must be a JSON object: {path}")
        return {}
    return payload

base_payload = load_object(base_path, "base")
overlay_payload = load_object(overlay_path, "overlay")
managed_defaults = hooks.managed_claude_settings_defaults(launch_cmd or None, agent_class or None)
expected = hooks.merge_settings(managed_defaults, base_payload)
expected = hooks.merge_settings(expected, overlay_payload)
# PR #970: `cmd_render_shared_settings` rewrites `~/.agent-bridge/hooks/`
# prefixes in the merged settings to absolute `<BRIDGE_HOME>/hooks/` paths
# before writing the effective file. The plan must apply the same rewrite
# to `expected` so the post-apply `effective_payload == expected` check
# (driving `effective.matches_expected` and ultimately the apply-row
# `rerendered` vs `needs-rerender` status) stays symmetric. Without this,
# every install whose base `agents/.claude/settings.json` ships the legacy
# `~/.agent-bridge/hooks/...` literals (the tracked source default) would
# report `needs-rerender` after a successful apply on every run.
if hasattr(hooks, "_normalize_bridge_hook_paths") and hasattr(hooks, "_bridge_home_from_base_settings"):
    hooks._normalize_bridge_hook_paths(expected, hooks._bridge_home_from_base_settings(base_path))

current_error = ""
try:
    current_payload = load_object(settings_path, "current")
except OSError as exc:
    current_error = str(exc)
    current_payload = {}

effective_payload = load_object(effective_path, "effective")
effective_exists = effective_path.exists()
effective_matches = effective_exists and effective_payload == expected

changes = []
for key in managed_defaults:
    expected_value = expected.get(key)
    if key not in current_payload:
        changes.append({"key": key, "from": None, "to": expected_value, "reason": "missing"})
    elif current_payload.get(key) != expected_value:
        changes.append({
            "key": key,
            "from": current_payload.get(key),
            "to": expected_value,
            "reason": "differs",
        })

is_symlink = settings_path.is_symlink()
link_target = os.readlink(settings_path) if is_symlink else ""
link_ok = is_symlink and os.path.realpath(settings_path) == os.path.realpath(effective_path)
needs_rerender = bool(changes) or not link_ok or not effective_matches or bool(errors) or bool(current_error)

payload = {
    "agent": agent,
    "workdir": str(Path(workdir).expanduser()),
    "settings_file": str(settings_path),
    "base_settings_file": str(base_path),
    "overlay_settings_file": str(overlay_path),
    "effective_settings_file": str(effective_path),
    "status": "needs-rerender" if needs_rerender else "unchanged",
    "changes": changes,
    "link": {
        "ok": link_ok,
        "is_symlink": is_symlink,
        "target": link_target,
    },
    "effective": {
        "exists": effective_exists,
        "matches_expected": effective_matches,
    },
    "errors": errors,
    "current_error": current_error,
}
print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
PY

  local _plan_rc=0
  if [[ $_isolated_active -eq 1 ]]; then
    bridge_require_python
    bridge_linux_sudo_root python3 "$_plan_py" \
      "$SCRIPT_DIR/bridge-hooks.py" \
      "$agent" \
      "$workdir" \
      "$(bridge_hook_shared_settings_base_file)" \
      "$(bridge_hook_shared_settings_overlay_file)" \
      "$effective_file" \
      "$launch_cmd" \
      "$agent_class" \
      "$settings_path_override"
    _plan_rc=$?
  else
    bridge_require_python
    python3 "$_plan_py" \
      "$SCRIPT_DIR/bridge-hooks.py" \
      "$agent" \
      "$workdir" \
      "$(bridge_hook_shared_settings_base_file)" \
      "$(bridge_hook_shared_settings_overlay_file)" \
      "$effective_file" \
      "$launch_cmd" \
      "$agent_class" \
      "$settings_path_override"
    _plan_rc=$?
  fi
  rm -f "$_plan_py"
  return $_plan_rc
}

bridge_agent_rerender_row_json() {
  local mode="$1"
  local before_json="$2"
  local after_json="$3"
  local error="$4"

  bridge_agent_manage_python "$mode" "$before_json" "$after_json" "$error" <<'PY'
import json
import sys

mode, before_raw, after_raw, error = sys.argv[1:]
before = json.loads(before_raw)
after = json.loads(after_raw) if after_raw else before
row = dict(after)
row["mode"] = mode
row["before"] = before
if error:
    row["status"] = "failed"
    row["error"] = error
elif mode == "apply" and before.get("status") == "needs-rerender":
    row["status"] = "rerendered" if after.get("status") == "unchanged" else after.get("status", "rerendered")
else:
    row["status"] = after.get("status", "unchanged")
print(json.dumps(row, ensure_ascii=False, sort_keys=True))
PY
}

bridge_agent_print_rerender_json() {
  local mode="$1"
  local rows_file="$2"
  local failed_count="$3"

  bridge_agent_manage_python "$mode" "$rows_file" "$failed_count" <<'PY'
import json
import sys
from pathlib import Path

mode, rows_file, failed_count = sys.argv[1:]
rows = []
path = Path(rows_file)
if path.exists():
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            rows.append(json.loads(line))
print(json.dumps({
    "mode": mode,
    "count": len(rows),
    "failed_count": int(failed_count),
    "candidates": rows,
}, ensure_ascii=False, indent=2))
PY
}

bridge_agent_print_rerender_text() {
  local mode="$1"
  local rows_file="$2"
  local failed_count="$3"

  bridge_agent_manage_python "$mode" "$rows_file" "$failed_count" <<'PY'
import json
import sys
from pathlib import Path

mode, rows_file, failed_count = sys.argv[1:]
rows = []
path = Path(rows_file)
if path.exists():
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
print(f"mode: {mode}")
if not rows:
    print("rerender-settings: no managed Claude settings targets")
    raise SystemExit(0)
for row in rows:
    changes = row.get("before", row).get("changes") or row.get("changes") or []
    change_text = ", ".join(
        f"{item.get('key')}: {item.get('from')!r} -> {item.get('to')!r}"
        for item in changes
    ) or "-"
    link = row.get("link") or {}
    effective = row.get("effective") or {}
    print(
        f"{row.get('status')}: {row.get('agent')} "
        f"changes={change_text} "
        f"link_ok={str(bool(link.get('ok'))).lower()} "
        f"effective_ok={str(bool(effective.get('matches_expected'))).lower()} "
        f"workdir={row.get('workdir')}"
    )
    if row.get("error"):
        print(f"  error: {row.get('error')}")
    for error in row.get("errors") or []:
        print(f"  error: {error}")
if int(failed_count):
    print(f"failed_count: {failed_count}")
PY
}

run_rerender_settings() {
  local apply=0
  local json_mode=0
  local agent=""
  local workdir=""
  local canonical=""
  local before_json=""
  local after_json=""
  local row_json=""
  local apply_output=""
  local error=""
  local rows_file=""
  local failed_count=0
  local target_launch_cmd=""
  local -a selected_agents=()
  local -a targets=()
  local -A seen_workdirs=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply)
        apply=1
        shift
        ;;
      --dry-run)
        apply=0
        shift
        ;;
      --json)
        json_mode=1
        shift
        ;;
      -h|--help)
        printf 'Usage: %s rerender-settings [<agent>...] [--apply|--dry-run] [--json]\n' "$(basename "$0")"
        return 0
        ;;
      --*)
        bridge_die "지원하지 않는 agent rerender-settings 옵션입니다: $1"
        ;;
      *)
        selected_agents+=("$1")
        shift
        ;;
    esac
  done

  add_target() {
    local target_agent="$1"
    local target_workdir="$2"
    [[ -n "$target_agent" && -n "$target_workdir" ]] || return 0
    [[ -d "$target_workdir" ]] || return 0
    canonical="$(bridge_agent_canonical_dir "$target_workdir")"
    [[ -n "$canonical" ]] || return 0
    if [[ -n "${seen_workdirs[$canonical]:-}" ]]; then
      return 0
    fi
    seen_workdirs["$canonical"]=1
    targets+=("${target_agent}"$'\t'"${target_workdir}")
  }

  if [[ ${#selected_agents[@]} -gt 0 ]]; then
    for agent in "${selected_agents[@]}"; do
      if [[ "$agent" == "_template" ]]; then
        add_target "$agent" "$BRIDGE_AGENT_HOME_ROOT/_template"
        continue
      fi
      bridge_require_agent "$agent"
      [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || bridge_die "Claude agent가 아닙니다: $agent"
      add_target "$agent" "$(bridge_expand_user_path "$(bridge_agent_workdir "$agent")")"
    done
  else
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
      add_target "$agent" "$(bridge_expand_user_path "$(bridge_agent_workdir "$agent")")"
    done

    if [[ -d "$BRIDGE_AGENT_HOME_ROOT/_template" ]]; then
      add_target "_template" "$BRIDGE_AGENT_HOME_ROOT/_template"
    fi

    if [[ -d "$BRIDGE_AGENT_HOME_ROOT" ]]; then
      for workdir in "$BRIDGE_AGENT_HOME_ROOT"/*; do
        [[ -d "$workdir" ]] || continue
        agent="$(basename "$workdir")"
        [[ "$agent" == ".claude" || "$agent" == "_template" ]] && continue
        if [[ -f "$workdir/SESSION-TYPE.md" ]]; then
          if grep -Eq 'Session Type:[[:space:]]*(admin|static-claude)' "$workdir/SESSION-TYPE.md"; then
            add_target "$agent" "$workdir"
          fi
        elif [[ -e "$workdir/.claude/settings.json" ]]; then
          add_target "$agent" "$workdir"
        fi
      done
    fi
  fi

  rows_file="$(mktemp "${TMPDIR:-/tmp}/bridge-rerender-settings.XXXXXX")"
  local _probe_stderr=""
  local _probe_err=""
  local _probe_mode=""
  for target in "${targets[@]}"; do
    agent="${target%%$'\t'*}"
    workdir="${target#*$'\t'}"
    # Issue #752 M4: under `set -e`, a single per-target probe failure
    # (python crash, sudo denial on isolated read, mktemp ENOSPC) would
    # abort the whole loop and leave later targets un-rerendered with no
    # signal which agents were skipped. Capture rc explicitly, emit a
    # structured error row that satisfies the bridge_agent_print_rerender_*
    # consumers (status/agent/workdir/mode), warn, and continue.
    _probe_stderr="$(mktemp "${TMPDIR:-/tmp}/bridge-rerender-probe-err.XXXXXX")"
    if ! before_json="$(bridge_agent_shared_settings_plan_json "$agent" "$workdir" 2>"$_probe_stderr")"; then
      _probe_err="$(<"$_probe_stderr")"
      rm -f "$_probe_stderr"
      bridge_warn "rerender-settings: probe 실패로 target='$agent' 건너뜁니다 (workdir=$workdir): ${_probe_err:-no stderr captured}"
      _probe_mode="$([[ $apply -eq 1 ]] && printf apply || printf dry-run)"
      row_json="$(BRIDGE_PROBE_AGENT="$agent" BRIDGE_PROBE_WORKDIR="$workdir" \
        BRIDGE_PROBE_MODE="$_probe_mode" BRIDGE_PROBE_ERROR="${_probe_err:-probe failed}" \
        python3 -c 'import json,os; print(json.dumps({"agent":os.environ["BRIDGE_PROBE_AGENT"],"workdir":os.environ["BRIDGE_PROBE_WORKDIR"],"mode":os.environ["BRIDGE_PROBE_MODE"],"status":"error","reason":"probe_failed","error":os.environ["BRIDGE_PROBE_ERROR"]}, ensure_ascii=False, sort_keys=True))')"
      printf '%s\n' "$row_json" >>"$rows_file"
      failed_count=$((failed_count + 1))
      continue
    fi
    rm -f "$_probe_stderr"
    error=""
    if [[ $apply -eq 1 ]]; then
      # Issue #570: managed autoCompactWindow default is unconditionally
      # 1_000_000; launch_cmd is forwarded only for caller-signature parity
      # with helpers that still accept it (no longer consulted by the renderer).
      target_launch_cmd="$(bridge_agent_launch_cmd_raw "$agent" 2>/dev/null || true)"
      # Issue #669: for v2 linux-user-isolated agents the `<workdir>/.claude/`
      # tree lives under the foreign UID (mode 0700), so the controller
      # cannot create or symlink files there. The workdir-side render is
      # also dead work for these agents — the running Claude session reads
      # `<isolated-home>/.claude/settings.json` from its own HOME, not the
      # workdir. Skip the workdir-side render and route directly to the
      # cross-UID handler (`bridge_install_isolated_home_settings`, which
      # uses `bridge_linux_sudo_root` to write under the foreign UID).
      # Net effect: rc=0 on first run for cross-UID isolated agents,
      # which is what the v0.8.3 release-note "idempotent on rerun" promise
      # was supposed to deliver but didn't (it stayed rc=1 → rc=1 because
      # this branch never had a cross-UID path).
      #
      # PR #673 r2 (codex BLOCKING, refs #669/#666):
      # `bridge_install_isolated_home_settings` now returns 1 on real
      # internal failure (mkdir/render/install/mv). On the rerender
      # path the install IS the load-bearing step (the workdir-side
      # render is dead work for cross-UID isolated agents — see the
      # comment block above), so a nonzero rc must flip this row to
      # error and increment `failed_count`, mirroring the non-isolated
      # branch. Capture stderr so the warn line surfaces in the row's
      # error field. On success, audit the rerender as
      # `cross_uid_isolated_home` strategy (matches the v0.8.3
      # CHANGELOG promise that re-runs converge to rc=0).
      if [[ "$agent" != "_template" ]] \
          && command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
          && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
        if apply_output="$(bridge_install_isolated_home_settings "$agent" "$target_launch_cmd" 2>&1)"; then
          # Wave-5 #4282 Scenario B: re-probe via the isolation-aware
          # plan_json so the row reports the actual post-install state
          # (link.ok / effective.matches_expected / status). Prior to
          # Wave-5 the success branch reused `before_json` verbatim,
          # which left the row stuck at `needs-rerender` even after the
          # install converged — bob agent on task #4280 retest reported
          # rerender --apply rc=0 twice with link_ok=false /
          # effective_ok=false on both runs.
          after_json="$(bridge_agent_shared_settings_plan_json "$agent" "$workdir")"
          bridge_audit_log "$(bridge_admin_agent_id 2>/dev/null || printf bridge-upgrade)" "shared_settings_rerendered" "$agent" \
            --detail workdir="$workdir" --detail strategy=cross_uid_isolated_home >/dev/null 2>&1 || true
        else
          error="$apply_output"
          after_json="$before_json"
          failed_count=$((failed_count + 1))
        fi
      # Issue #555: forward agent id so the rerender writes to the
      # per-agent effective file ($BRIDGE_AGENT_HOME_ROOT/<agent>/.claude/
      # settings.effective.json). Mixed-model installs no longer fight
      # over a single install-wide file; each agent's autoCompactWindow
      # (and any future per-agent managed default) is independent.
      elif apply_output="$(bridge_link_claude_settings_to_shared "$workdir" "$target_launch_cmd" "$agent" 2>&1)"; then
        after_json="$(bridge_agent_shared_settings_plan_json "$agent" "$workdir")"
        bridge_audit_log "$(bridge_admin_agent_id 2>/dev/null || printf bridge-upgrade)" "shared_settings_rerendered" "$agent" \
          --detail workdir="$workdir" >/dev/null 2>&1 || true
        # Issue #544 PR2 — also render the per-isolated-home
        # `<isolated-home>/.claude/settings.effective.json` + symlink so
        # isolated agents pick up the bridge hook entries on rerender.
        # No-op for non-isolated agents and on non-Linux hosts.
        # Best-effort: a failure here is logged via bridge_warn inside
        # the helper and does not flip this row to error — the workdir
        # shared rerender (above) already succeeded.
        if [[ "$agent" != "_template" ]] \
            && command -v bridge_install_isolated_home_settings >/dev/null 2>&1; then
          bridge_install_isolated_home_settings "$agent" "$target_launch_cmd" >/dev/null 2>&1 || true
        fi
      else
        error="$apply_output"
        after_json="$before_json"
        failed_count=$((failed_count + 1))
      fi
      row_json="$(bridge_agent_rerender_row_json apply "$before_json" "$after_json" "$error")"
    else
      row_json="$(bridge_agent_rerender_row_json dry-run "$before_json" "" "")"
    fi
    printf '%s\n' "$row_json" >>"$rows_file"
  done

  if [[ $json_mode -eq 1 ]]; then
    bridge_agent_print_rerender_json "$([[ $apply -eq 1 ]] && printf apply || printf dry-run)" "$rows_file" "$failed_count"
  else
    bridge_agent_print_rerender_text "$([[ $apply -eq 1 ]] && printf apply || printf dry-run)" "$rows_file" "$failed_count"
  fi
  rm -f "$rows_file"
  [[ $failed_count -eq 0 ]]
}

run_create() {
  local agent="${1:-}"
  local engine="claude"
  local session_type=""
  local session=""
  local workdir=""
  local profile_home=""
  local description=""
  local display_name=""
  local role_text=""
  local launch_cmd=""
  local channels=""
  local discord_channel=""
  local notify_kind=""
  local notify_target=""
  local notify_account=""
  local isolation_mode="shared"
  local os_user=""
  local loop_mode=0
  # Issue #1093: explicit-off support on `agent add --loop no`. Used as
  # positional 20 in bridge_write_role_block (loop_explicit_off) so the
  # writer emits BRIDGE_AGENT_LOOP="0" instead of dropping the line and
  # letting bridge_agent_loop default it back to "1" on next load.
  local loop_explicit_off=0
  local continue_mode=1
  local always_on=0
  # Issue #1093: explicit idle_timeout value supplied via --idle-timeout.
  # Empty means "no override" — the legacy always_on=1 → IDLE_TIMEOUT=0
  # path still triggers for `agent add --always-on`. When non-empty, the
  # writer emits BRIDGE_AGENT_IDLE_TIMEOUT="<value>" verbatim.
  local idle_timeout_value=""
  # Issue #1136: declarative direction the operator passed via
  # `--always-on yes|no` (including the legacy bare `--always-on` shape,
  # which is treated as `yes`). Threaded through to the audit emit's
  # `expressed_intent` field so the create-side audit row carries the
  # same searchable receipt the update-side does.
  local always_on_intent=""
  local always_on_no_present=0
  local dry_run=0
  local json_mode=0
  local user_specs=()
  local users_json=""
  local default_home=""
  local start_dry_run=""
  local start_dry_run_status="ok"
  # Issue #598 Track 4: opt-in for test-artifact-prefix names.
  local test_fixture=0
  # Issue #691: opt-in for callers that legitimately share a workdir with
  # another already-managed agent (e.g. the admin-pair backfill spawning
  # `<admin>-dev` into the admin's workdir, where bootstrap_project_skill has
  # already populated `.agents/`). Skips the non-empty-workdir guard.
  local allow_shared_workdir=0

  shift || true

  # Issue #526: short-circuit help BEFORE the positional <agent> binding
  # so `bridge-agent.sh create --help` (or via `agent-bridge agent create
  # --help`) prints usage instead of scaffolding an agent named `--help`.
  case "$agent" in
    -h|--help|help)
      usage
      return 0
      ;;
  esac

  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") create <agent> [...]"
  if ! bridge_validate_agent_name "$agent"; then
    case "$agent" in
      -*)
        bridge_die "에이전트 이름이 CLI 플래그처럼 보입니다: '$agent'. 도움말을 보려면 '$(basename "$0") create --help' 를 실행하세요."
        ;;
      *)
        bridge_die "에이전트 이름은 영문/숫자/._- 만 사용할 수 있고 영문/숫자로 시작해야 하며 'help'/'version' 은 예약어입니다: $agent"
        ;;
    esac
  fi
  if bridge_agent_exists "$agent"; then
    bridge_die "이미 등록된 에이전트입니다: $agent"
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --engine)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        engine="$2"
        shift 2
        ;;
      --session)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        session="$2"
        shift 2
        ;;
      --workdir)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        workdir="$2"
        shift 2
        ;;
      --profile-home)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        profile_home="$2"
        shift 2
        ;;
      --description)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        description="$2"
        shift 2
        ;;
      --display-name)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        display_name="$2"
        shift 2
        ;;
      --role)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        role_text="$2"
        shift 2
        ;;
      --session-type)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        session_type="$2"
        shift 2
        ;;
      --user)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        user_specs+=("$2")
        shift 2
        ;;
      --launch-cmd)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        launch_cmd="$2"
        shift 2
        ;;
      --channels)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        channels="$2"
        shift 2
        ;;
      --discord-channel)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        discord_channel="$2"
        shift 2
        ;;
      --notify-kind)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        notify_kind="$2"
        shift 2
        ;;
      --notify-target)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        notify_target="$2"
        shift 2
        ;;
      --notify-account)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        notify_account="$2"
        shift 2
        ;;
      --isolation)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        isolation_mode="$2"
        shift 2
        ;;
      --isolate)
        isolation_mode="linux-user"
        shift
        ;;
      --os-user)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        os_user="$2"
        shift 2
        ;;
      --loop)
        # Issue #1093: extended `--loop yes|no` shape. The legacy bare
        # `--loop` (no value, OR followed by another `-` flag) keeps the
        # on-only semantics for callers that predate the value form. A
        # non-flag next argv MUST be a recognised value token
        # (yes/no/on/off, case-insensitive) — anything else is a typo
        # and we refuse it at parse time rather than silently re-interpret
        # `--loop bogus` as bare-on + unknown positional `bogus`.
        if [[ $# -ge 2 && "$2" != -* ]]; then
          case "$2" in
            yes|YES|Yes|on|ON|On)
              loop_mode=1
              loop_explicit_off=0
              shift 2
              continue
              ;;
            no|NO|No|off|OFF|Off)
              loop_mode=0
              loop_explicit_off=1
              shift 2
              continue
              ;;
            *)
              bridge_die "--loop 는 yes|no|on|off 만 가능합니다: $2"
              ;;
          esac
        fi
        loop_mode=1
        loop_explicit_off=0
        shift
        ;;
      --always-on)
        # Issue #1093 / #1136: extended `--always-on yes|no` shape. Legacy
        # bare `--always-on` (no value, OR followed by another flag)
        # remains an on-only toggle (= `yes`). `--always-on no` is the
        # symmetric inverse — must be paired with a positive
        # `--idle-timeout <seconds>`; enforced post-parse so flag
        # ordering doesn't matter. Both directions stamp the audit row's
        # `expressed_intent` field.
        if [[ $# -ge 2 && "$2" != -* ]]; then
          case "$2" in
            yes|YES|Yes)
              if [[ -n "$always_on_intent" && "$always_on_intent" != "always_on_yes" ]]; then
                bridge_die "--always-on yes 와 --always-on no 는 함께 지정할 수 없습니다."
              fi
              always_on=1
              always_on_intent="always_on_yes"
              shift 2
              continue
              ;;
            no|NO|No)
              if [[ -n "$always_on_intent" && "$always_on_intent" != "always_on_no" ]]; then
                bridge_die "--always-on yes 와 --always-on no 는 함께 지정할 수 없습니다."
              fi
              always_on_intent="always_on_no"
              always_on_no_present=1
              shift 2
              continue
              ;;
            *)
              bridge_die "--always-on 는 yes|no 만 가능합니다: $2"
              ;;
          esac
        fi
        # Legacy bare `--always-on` is `yes` (preserved byte-identical
        # to PR #1102 behaviour); still record the intent so audit-log
        # grep on `expressed_intent=always_on_yes` returns the legacy
        # callers too.
        if [[ -n "$always_on_intent" && "$always_on_intent" != "always_on_yes" ]]; then
          bridge_die "--always-on yes 와 --always-on no 는 함께 지정할 수 없습니다."
        fi
        always_on=1
        always_on_intent="always_on_yes"
        shift
        ;;
      --idle-timeout)
        # Issue #1093: integer ≥0 (seconds). 0 is the always-on
        # convention used by bridge_agent_is_always_on. Validate at
        # parse time so a bad value never reaches the writer.
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        if [[ ! "$2" =~ ^[0-9]+$ ]]; then
          bridge_die "--idle-timeout 는 0 이상의 정수여야 합니다: $2"
        fi
        idle_timeout_value="$2"
        if [[ "$2" == "0" ]]; then
          always_on=1
        fi
        shift 2
        ;;
      --continue)
        continue_mode=1
        shift
        ;;
      --no-continue)
        continue_mode=0
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --json)
        json_mode=1
        shift
        ;;
      --test-fixture)
        # Issue #598 Track 4: opt into test-artifact-prefix policy.
        test_fixture=1
        shift
        ;;
      --allow-shared-workdir)
        # Issue #691: skip the non-empty-workdir guard. Sanctioned for the
        # admin-pair backfill (admin + admin-dev share the same workdir per
        # their roles) and any future caller that legitimately layers on top
        # of an existing managed scaffold.
        allow_shared_workdir=1
        shift
        ;;
      *)
        bridge_die "지원하지 않는 agent create 옵션입니다: $1"
        ;;
    esac
  done

  # Issue #1136: validate the `--always-on` combination matrix. Same
  # rules as the update path (see run_update post-parse block) — refuse
  # contradictory direction/idle-timeout pairs and require the explicit
  # positive co-flag on `--always-on no`. The intent string
  # (`always_on_intent`) survives normalisation because the audit emit
  # below threads it through verbatim.
  case "$always_on_intent" in
    always_on_yes)
      if [[ -n "$idle_timeout_value" && "$idle_timeout_value" != "0" ]]; then
        bridge_die "--always-on yes 는 --idle-timeout <positive> 와 함께 사용할 수 없습니다 (의미 충돌). 항상-on 은 --always-on yes 또는 --idle-timeout 0 만 사용하세요."
      fi
      ;;
    always_on_no)
      if [[ -z "$idle_timeout_value" ]]; then
        bridge_die "--always-on no requires --idle-timeout <seconds> (positive integer)"
      fi
      if [[ "$idle_timeout_value" == "0" ]]; then
        bridge_die "--always-on no with --idle-timeout 0 is contradictory; use --always-on yes for always-on, or pass a positive idle-timeout for on-demand"
      fi
      ;;
  esac

  # Issue #598 Track 4: refuse names that match a test-artifact pattern
  # (smoke-, test-, bootstrap-, created-agent-, pref-, *-repro-<N>) unless
  # the operator opted in with --test-fixture. Cleanup tooling (Track 2
  # orphan-agent-dir detector) treats these as test fixtures and may
  # report/reap them.
  if bridge_validate_agent_name_test_artifact "$agent"; then
    if [[ $test_fixture -eq 0 ]]; then
      bridge_die "agent-bridge agent create '$agent' refused: name matches test-artifact pattern.
Use \`--test-fixture\` if this is intentional test setup; cleanup tooling may
report and reap test-fixture agents per their pattern."
    else
      # Audit row so operators (and the future orphan-agent-dir detector)
      # can identify which test-fixture agents to reap.
      bridge_audit_log agent agent_test_fixture_created "$agent" \
        --detail reason=test-fixture-flag \
        --detail entrypoint=create \
        2>/dev/null || true
    fi
  fi

  # Issue #1047: caller-trust gating. `agent create` writes a managed-role
  # block to agent-roster.local.sh — the same protected system-config file
  # `agent update` / `agent delete` mutate. Those verbs reject an
  # `agent-direct` caller via bridge_agent_update_caller_source(); `create`
  # used to be ungated, an incoherent split privilege boundary (an agent
  # process could add a roster entry but not remove or modify one). Gate
  # `create` on the SAME single caller-source contract: the source must be
  # operator-tui / operator-trusted-id (a TTY-detected operator, or a
  # sanctioned non-interactive caller that sets BRIDGE_CALLER_SOURCE). An
  # `agent-direct` caller is denied here just as it is for update/delete.
  # Placed after name validation so a refused-name caller still gets the
  # name-specific error; applies to --dry-run too, mirroring update/delete.
  local create_caller_source
  create_caller_source="$(bridge_agent_update_caller_source)"
  if [[ "$create_caller_source" != "operator-tui" && "$create_caller_source" != "operator-trusted-id" ]]; then
    bridge_die "deny: caller source $create_caller_source is not allowed to mutate system config (need operator-tui or operator-trusted-id)"
  fi

  case "$engine" in
    claude|codex) ;;
    *) bridge_die "지원하지 않는 engine 입니다: $engine" ;;
  esac

  if [[ -z "$session_type" ]]; then
    case "$engine" in
      claude) session_type="static-claude" ;;
      codex) session_type="static-codex" ;;
    esac
  fi
  case "$session_type" in
    admin|static-claude|static-codex|dynamic|cron) ;;
    *) bridge_die "지원하지 않는 session type 입니다: $session_type" ;;
  esac
  case "$isolation_mode" in
    shared|linux-user) ;;
    *) bridge_die "지원하지 않는 isolation mode 입니다: $isolation_mode" ;;
  esac

  if [[ "$isolation_mode" == "shared" && -n "$os_user" ]]; then
    bridge_die "--os-user 는 --isolation linux-user 와 함께만 사용할 수 있습니다."
  fi

  session="${session:-$agent}"
  default_home="$(bridge_agent_default_home "$agent")"
  # Issue #1060: the three-layer agent-layout model. `agent create`
  # authors the canonical per-agent identity (SOUL / SESSION-TYPE /
  # MEMORY* / role payload) into the IDENTITY SOURCE — layer 2,
  # `bridge_layout_agent_home` = v2 `<agent-root>/home`. It is no longer
  # the empty/stale sibling: the create flow scaffolds INTO it, then runs
  # a materialization step that delivers the identity fileset into the
  # engine's materialization target (the workspace `workdir/` for v2
  # static Claude) so the runtime — which keeps reading `workdir/`
  # exactly as before (no reader flip) — receives a populated, current
  # identity. This closes the #1046/#1060 model drift: scaffold no longer
  # treats `home/` as the runtime home while the resolver launches the
  # empty `workdir/`.
  #
  # `workdir` here stays the WORKSPACE (layer 3) — process cwd, the path
  # `bridge_agent_workdir` resolves and the live session launches in.
  # When the operator did not pass an explicit `--workdir`, default it to
  # the resolved v2 `workdir/`. An explicit `--workdir` is honored as-is.
  local _workdir_is_v2_default=0
  if [[ -z "$workdir" && -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
    workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
    _workdir_is_v2_default=1
  fi
  workdir="$(bridge_expand_user_path "${workdir:-$default_home}")"
  profile_home="$(bridge_expand_user_path "${profile_home:-}")"
  description="${description:-$agent static role}"
  display_name="${display_name:-$agent}"
  role_text="${role_text:-Long-lived agent role}"
  launch_cmd="${launch_cmd:-$(bridge_agent_default_launch_cmd "$engine")}"
  channels="$(bridge_normalize_channels_csv "$channels")"
  users_json="$(bridge_normalize_user_specs_json "${user_specs[@]}")"
  if [[ "$isolation_mode" == "linux-user" ]]; then
    if [[ "$(bridge_host_platform)" != "Linux" ]]; then
      bridge_warn "linux-user isolation은 Linux 전용입니다. 현재 호스트에서는 shared mode로 생성합니다."
      isolation_mode="shared"
      os_user=""
    else
      # v0.8.4: enforce the group-name char policy upfront so a name
      # accepted by `agent create` will always compose to a valid Linux
      # group name (length is hash-truncated separately by
      # bridge_isolation_v2_agent_group_name; the chars must still be
      # [a-z_][a-z0-9_-]* per groupadd).
      if [[ ! "$agent" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        bridge_die "linux-user isolation requires agent name to match [a-z_][a-z0-9_-]* (groupadd policy): '$agent'"
      fi
      os_user="${os_user:-$(bridge_agent_default_os_user "$agent")}"
    fi
  fi

  default_home="$(bridge_expand_user_path "$default_home")"
  # Auto-derive profile_home only for a genuinely custom operator-supplied
  # workdir. The canonical v2 `workdir/` (auto-defaulted above) is already
  # the v2 profile-home default (bridge_agent_default_profile_home), so
  # pinning it explicitly here would add roster noise without changing
  # behavior — and #1045/#1046 must not change the profile-deploy contract.
  if [[ -z "$profile_home" && "$workdir" != "$default_home" && $_workdir_is_v2_default -eq 0 ]]; then
    profile_home="$workdir"
  fi

  if [[ "$isolation_mode" == "linux-user" ]]; then
    local existing_agent=""
    local existing_workdir=""
    for existing_agent in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$existing_agent" == "$agent" ]] && continue
      existing_workdir="$(bridge_agent_workdir "$existing_agent")"
      [[ -n "$existing_workdir" ]] || continue
      if [[ "$(bridge_expand_user_path "$existing_workdir")" == "$workdir" ]]; then
        bridge_die "linux-user isolation에서는 workdir를 다른 에이전트와 공유할 수 없습니다: ${existing_agent} -> ${workdir}"
      fi
    done
  fi

  if [[ $dry_run -eq 0 ]]; then
    if [[ -e "$workdir" ]]; then
      if [[ -d "$workdir" ]] && [[ -z "$(find "$workdir" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]]; then
        :
      elif [[ -d "$workdir" && -f "$workdir/CLAUDE.md" ]]; then
        :
      elif [[ -d "$workdir" && $allow_shared_workdir -eq 1 ]]; then
        # Issue #691: caller (admin-pair backfill) explicitly opts into
        # layering onto an existing managed workdir scaffold.
        :
      else
        bridge_die "workdir가 이미 존재하고 비어 있지 않습니다: $workdir"
      fi
    fi
    # Issue #1076: arm the rollback trap BEFORE the first mutation. The
    # trap fires on any non-zero exit (including bridge_die / an unhandled
    # PermissionError in a python helper / set -e propagation) until the
    # success-clear at the end of the create block sets _CREATE_ROLLBACK_
    # COMPLETE=1. Persists the create state through shell vars (locals
    # captured by the rollback helper) so the trap body stays trivial.
    _CREATE_ROLLBACK_AGENT="$agent"
    _CREATE_ROLLBACK_ROSTER="$BRIDGE_ROSTER_LOCAL_FILE"
    _CREATE_ROLLBACK_ROSTER_WRITTEN=0
    _CREATE_ROLLBACK_SCAFFOLD_CREATED=0
    _CREATE_ROLLBACK_WORKDIR_CREATED=0
    _CREATE_ROLLBACK_SCAFFOLD_TARGET=""
    _CREATE_ROLLBACK_WORKDIR=""
    _CREATE_ROLLBACK_V2_ROOT=""
    _CREATE_ROLLBACK_COMPLETE=0
    # Record the v2 per-agent root parent so rollback can rm it too —
    # bridge_scaffold_agent_home pre-creates this on isolated installs and
    # run_delete --purge-home does not see it on a non-rolled-back delete.
    if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" && $_workdir_is_v2_default -eq 1 ]]; then
      _CREATE_ROLLBACK_V2_ROOT="$BRIDGE_AGENT_ROOT_V2/$agent"
    fi
    # _workdir_is_v2_default == 1 means we authored workdir under the v2
    # tree (it wasn't an explicit operator --workdir), so rollback may rm it.
    if [[ $_workdir_is_v2_default -eq 1 ]]; then
      _CREATE_ROLLBACK_WORKDIR="$workdir"
    fi
    # shellcheck disable=SC2064
    trap '[[ "${_CREATE_ROLLBACK_COMPLETE:-0}" == "1" ]] || bridge_agent_create_rollback' EXIT
    # Issue #1060 D1: scaffold the authored identity into the IDENTITY
    # SOURCE (layer 2). On a v2 install the identity source is ALWAYS
    # `bridge_layout_agent_home` = `<agent-root>/home` — regardless of
    # whether the workspace is the v2-default `workdir/` or an explicit
    # `--workdir` (including a *shared* project tree). Authoring the
    # identity into `home/` is what keeps per-agent identity OUT of a
    # shared workspace (the shared-workdir rule): the materialization
    # step below then delivers it into the workspace ONLY when the
    # workspace is not shared. On a legacy install (no BRIDGE_AGENT_ROOT_V2)
    # the identity source and workspace coincide, so the target stays
    # `$workdir` and materialization is a no-op. `bridge_scaffold_agent_home`
    # still creates the v2 sibling, so both `home/` and `workdir/` exist
    # after this call.
    local scaffold_target="$workdir"
    if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]] \
        && declare -F bridge_layout_agent_home >/dev/null 2>&1; then
      scaffold_target="$(bridge_expand_user_path "$(bridge_layout_agent_home "$agent")")"
    fi
    # Issue #1076: record scaffold_target before the mutation so rollback
    # can rm it if a later step fails. Setting _CREATE_ROLLBACK_SCAFFOLD_
    # CREATED=1 BEFORE the call means even a mid-scaffold raise (e.g. sudo
    # mkdir denied) is treated as "we tried to author this tree" — the
    # rollback rmtree is no-op when the tree never materialized, but YES-op
    # when bridge_scaffold_agent_home wrote some templates then aborted.
    _CREATE_ROLLBACK_SCAFFOLD_TARGET="$scaffold_target"
    _CREATE_ROLLBACK_SCAFFOLD_CREATED=1
    if [[ -n "$_CREATE_ROLLBACK_WORKDIR" ]]; then
      _CREATE_ROLLBACK_WORKDIR_CREATED=1
    fi
    # v0.8.5 #693 (Wave-3): pass isolation_mode + os_user so scaffold's
    # sudo-handoff predicate (added by PR #688 for #677) actually fires
    # on `agent create --isolate ...`. Without these explicit args, the
    # in-roster lookup inside scaffold would short-circuit the sudo path
    # — see the comment on `bridge_scaffold_agent_home`'s signature.
    bridge_scaffold_agent_home "$agent" "$scaffold_target" "$display_name" "$role_text" "$engine" "$session_type" "$isolation_mode" "$os_user"
    # Issue #1067 S03: create the engine-native instruction-file entrypoint
    # in the identity source. The template scaffold loop places CLAUDE.md for
    # every engine; for Codex (entrypoint=AGENTS.md) this step copies that
    # payload to AGENTS.md so the Codex runtime finds its role contract under
    # the canonical filename. bridge_layout_materialize_identity (below) then
    # delivers AGENTS.md into the workspace. No-op for Claude (entrypoint is
    # already CLAUDE.md).
    bridge_scaffold_codex_entrypoint "$scaffold_target" "$engine" 2>/dev/null || true
    # Per-user partitions (`users/<id>/USER.md`) are per-agent identity,
    # so they are scaffolded into the IDENTITY SOURCE alongside the rest
    # of the authored identity — the `users/` skeleton template lands
    # under `$scaffold_target`. The materialization step below delivers
    # the populated `users/` tree into the workspace read target.
    bridge_scaffold_user_partitions "$scaffold_target" "$users_json"
    # Issue #1060 D1: deliver the authored identity into the engine's
    # materialization target (the workspace `workdir/` for v2 static
    # Claude) so the runtime read target is never the empty/stale
    # sibling that caused the #1046/#1060 re-onboarding loop. No-op when
    # scaffold_target == the materialization target (legacy / custom
    # --workdir). Honors the shared-workspace rule internally.
    if [[ "$scaffold_target" != "$workdir" ]] \
        && declare -F bridge_layout_materialize_identity >/dev/null 2>&1; then
      # Pass $workdir explicitly: the roster reload that
      # `bridge_agent_workdir` (and therefore the descriptor's target
      # lookup) depends on runs AFTER bridge_write_role_block below, so
      # the create flow hands the already-resolved workspace directly.
      #
      # Codex r1 BLOCKING 1: propagate the operator's --allow-shared-workdir
      # intent into the materializer so a normal project workspace (no
      # marker text) is NOT stamped over. The materializer's marker-based
      # detection alone is insufficient for markerless shared projects.
      if [[ "${allow_shared_workdir:-0}" == "1" ]]; then
        BRIDGE_LAYOUT_WORKSPACE_SHARED=1 \
          bridge_layout_materialize_identity "$agent" "$engine" "$workdir"
      else
        bridge_layout_materialize_identity "$agent" "$engine" "$workdir"
      fi
    fi
    if [[ "$engine" == "claude" ]]; then
      # Issue #1151: thread $agent so the v2-isolation guard polarity fix
      # in bridge_ensure_project_claude_guidance can resolve roster os_user.
      bridge_ensure_project_claude_guidance "$workdir" "$agent" >/dev/null 2>&1 || true
      bridge_ensure_auto_memory_isolation "$agent" "$workdir"
    fi
    # Issue #1155: thread $agent so v2-isolation guard can resolve roster os_user.
    bridge_bootstrap_project_skill "$engine" "$workdir" "$agent" >/dev/null 2>&1 || true
    if [[ "$engine" == "claude" ]]; then
      bridge_bootstrap_claude_shared_skills "$agent" "$workdir" >/dev/null 2>&1 || true
      # Plan-D memory stack: ensure PreCompact hook at scaffold time so new
      # agents come up fully wired without a separate bootstrap pass.
      bridge_ensure_memory_precompact_hook "$agent" "$workdir" >/dev/null 2>&1 || true
    fi
    # Issue #1067 S08: render + verify the Codex hook surface for codex-engine
    # agents. The descriptor-owned path is <agent_home>/.codex/hooks.json —
    # NOT the shared $HOME/.codex/hooks.json. scaffold_target is the resolved
    # identity source (bridge_layout_agent_home on v2). bridge_engine_render_
    # hooks_on_create returns true for codex, so we gate on engine == "codex"
    # to stay forward-compatible without branching on the descriptor (which
    # the descriptor owns for future engines).
    if [[ "$engine" == "codex" ]]; then
      bridge_ensure_codex_agent_hooks "$agent" "$scaffold_target" >/dev/null 2>&1 || true
    fi
    # Issue #1105: capture the roster-file sha BEFORE the write so the
    # system_config_mutation audit row emitted below carries a real
    # before/after sha chain. On a markerless fresh-install the roster
    # file may not exist yet — bridge_agent_update_file_sha256 returns
    # an empty string in that case, which audit-detail-json.py treats as
    # the documented "file did not exist" sentinel.
    local _create_audit_roster_path="$BRIDGE_ROSTER_LOCAL_FILE"
    local _create_audit_before_sha
    _create_audit_before_sha="$(bridge_agent_update_file_sha256 "$_create_audit_roster_path")"
    # Issue #1093: pass positional 20 (loop_explicit_off) and positional
    # 21 (idle_timeout_value) so `agent add --loop no` persists the
    # explicit-off line and `--idle-timeout <seconds>` writes the
    # parameterised value. Positional 18 (replace_existing) stays "0" —
    # add never rewrites — and positional 19 (agent_class) stays empty;
    # agent class is a Track-2 update-only knob.
    bridge_write_role_block \
      "$agent" \
      "$description" \
      "$engine" \
      "$session" \
      "$workdir" \
      "$profile_home" \
      "$launch_cmd" \
      "$channels" \
      "$discord_channel" \
      "$notify_kind" \
      "$notify_target" \
      "$notify_account" \
      "$loop_mode" \
      "$continue_mode" \
      "$always_on" \
      "$isolation_mode" \
      "$os_user" \
      "0" \
      "" \
      "$loop_explicit_off" \
      "$idle_timeout_value" >/dev/null
    # Issue #1076: the agent is now registered. Mark for rollback excision
    # if any later step (shared-settings link, grant-matrix apply,
    # start --dry-run) raises — without this flag, a post-roster failure
    # leaves a registered-but-broken agent (the exact bug).
    _CREATE_ROLLBACK_ROSTER_WRITTEN=1
    # Issue #1105: capture after_sha right after the write so the audit
    # detail emitted at end-of-create (below, after every other mutation
    # has cleared) reflects exactly what landed on disk. We compute it
    # here rather than later so a downstream step that itself touches the
    # roster file (none today, but future-proof) cannot confuse the chain.
    local _create_audit_after_sha
    _create_audit_after_sha="$(bridge_agent_update_file_sha256 "$_create_audit_roster_path")"
    # Issue #848: bridge_write_role_block just appended a new entry to
    # the local roster file; invalidate the per-process cache so the
    # next load re-reads disk instead of replaying the pre-create map.
    bridge_roster_cache_invalidate
    bridge_load_roster
    if [[ "$engine" == "claude" ]]; then
      # Issue #570: managed autoCompactWindow default is unconditionally
      # 1_000_000; launch_cmd is forwarded only for caller-signature parity
      # with helpers that still accept it (no longer consulted by the renderer).
      # Issue #555: pass agent id so the freshly-created agent gets its
      # own per-agent settings.effective.json (not the install-wide one).
      bridge_ensure_claude_shared_settings_for_managed_workdir "$workdir" "$launch_cmd" "$agent" >/dev/null 2>&1 || true
    fi
    bridge_sync_skill_docs "$agent" >/dev/null 2>&1 || true
    if [[ "$isolation_mode" == "linux-user" ]]; then
      bridge_linux_prepare_agent_isolation "$agent" "$os_user" "$workdir"
    elif command -v bridge_isolation_v2_active >/dev/null 2>&1 \
        && bridge_isolation_v2_active 2>/dev/null \
        && command -v bridge_isolation_v2_apply_grant_matrix_for_agent >/dev/null 2>&1; then
      # #909: shared-mode agents on a v2-active install must also leave
      # the matrix in a check-passing state. Without this, the first
      # daemon write through write_agent_state_marker hits ensure_matrix_
      # path → apply_row → chown, and on a tree the controller already
      # owns this is a no-op success. The call is here so a fresh
      # `agent create <X>` on a shared-only v2 install mirrors the
      # bootstrap/upgrade-provisioned shape (patch / librarian survive
      # only because their matrix paths were materialized earlier; a
      # fresh agent has no such head start). `bridge_linux_prepare_
      # agent_isolation` already covers linux-user above so this branch
      # is the shared-mode counterpart.
      #
      # r2 P1 #3: hard-fail on apply error. apply_grant_matrix_for_agent
      # returns rc=1 only when a `required` row is broken (`optional`
      # rows demote to `degraded` and keep rc=0 — see the criticality
      # split in lib/bridge-isolation-v2.sh's apply_grant_matrix_for_
      # agent walker). Required apply failure here means marker writes
      # through ensure_matrix_path will reject on the first daemon pass;
      # swallowing the failure as "degraded continue" was exactly the
      # #909 wedge shape (non-bootable agent with no operator signal).
      # Surface the apply stderr and die so the operator sees the cause
      # and can either remove the agent (`agb agent delete <name>
      # --force`) or fix the underlying identity/permission issue.
      local _v2_apply_err=""
      _v2_apply_err="$(bridge_isolation_v2_apply_grant_matrix_for_agent "$agent" --apply 2>&1 >/dev/null)" \
        || {
          if [[ -n "$_v2_apply_err" ]]; then
            printf '%s\n' "$_v2_apply_err" >&2
          fi
          bridge_die "agent create: v2 shared-mode grant-matrix apply failed for '$agent' — first daemon pass would wedge on missing rows. Inspect output above, then 'agb agent delete $agent --force --purge-home' to roll back (the scaffolded home directory must be removed too)."
        }
    fi
    # Issue #1073 (codex r1 BLOCKING): pre-seed the per-agent
    # CLAUDE_CONFIG_DIR's `.claude.json` AFTER isolation prep so the
    # target dir exists for linux-user isolated agents. Pre-r2 the call
    # ran BEFORE prepare and the isolated home/`.claude` tree did not
    # exist yet, so the seed silently failed and #1073 remained open
    # for the production shape. Now: prepare creates + chowns the home
    # tree first, then the seed writes inside it; the shim is
    # isolation-aware and chowns the seeded file to the isolated UID
    # when isolated, preserving the read path under the isolated user.
    if [[ "$engine" == "claude" ]]; then
      bridge_ensure_claude_first_run_config "$agent" "$workdir" >/dev/null 2>&1 || true
    fi
    # Issue #680: bridge-start.sh --dry-run is purely informational here — its
    # output is reprinted to the user as `start_dry_run:` for diagnostic
    # context. Letting its rc propagate via command-substitution + set -e
    # silently aborts agent-create whenever dry-run reports a non-fatal
    # warning (e.g. v2 fresh-install where the workdir path resolver expects
    # `<agent-root>/workdir/` but bridge_scaffold_agent_home materializes
    # `<agent-root>/home/`). Capture rc separately and surface a clear
    # status field so a real first-run init no longer exits rc=1 with an
    # empty log; the underlying scaffold-vs-resolver mismatch remains visible
    # in the printed start_dry_run output for follow-up.
    if start_dry_run="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --dry-run 2>&1)"; then
      start_dry_run_status="ok"
    else
      start_dry_run_status="warn (rc=$?)"
    fi
    # Issue #1105: emit a system_config_mutation audit row mirroring the
    # `agent update` path's shape so operators get an audit trail for the
    # original create too (not just later updates). PR #1102 added the
    # update-side flags (--idle-timeout / --loop / --always-on) but the
    # create-side asymmetry (write_role_block silently mutating the
    # protected roster without an audit emit) predates that and is the
    # gap this row closes. Emitted just before _CREATE_ROLLBACK_COMPLETE=1
    # so if any earlier step raised, the trap excises the roster entry
    # AND we never reach the emitter — the audit log only ever carries
    # rows for creates that actually landed. before_* fields are empty
    # (the agent did not exist pre-create); after_* mirror the values
    # just persisted. The persisted idle_timeout / loop string derivation
    # is the same one `emit_create_json` uses below so the audit and the
    # --json envelope agree byte-for-byte on what landed on disk.
    local _create_audit_caller_agent _create_audit_actor
    _create_audit_caller_agent="$(bridge_agent_update_caller_agent "")"
    _create_audit_actor="$_create_audit_caller_agent"
    if [[ -z "$_create_audit_actor" ]]; then
      if [[ "$create_caller_source" == "operator-tui" ]]; then
        _create_audit_actor="operator"
      else
        _create_audit_actor="unknown"
      fi
    fi
    local _create_audit_idle_timeout=""
    if [[ -n "$idle_timeout_value" ]]; then
      _create_audit_idle_timeout="$idle_timeout_value"
    elif [[ $always_on -eq 1 ]]; then
      _create_audit_idle_timeout="0"
    fi
    local _create_audit_loop=""
    if [[ $loop_explicit_off -eq 1 ]]; then
      _create_audit_loop="0"
    elif [[ $loop_mode -eq 1 ]]; then
      _create_audit_loop="1"
    fi
    local _create_audit_summary
    _create_audit_summary="$(
      {
        printf 'engine=%s\n' "$engine"
        printf 'session_type=%s\n' "$session_type"
        printf 'isolation_mode=%s\n' "$isolation_mode"
        if [[ -n "$os_user" ]]; then
          printf 'os_user=%s\n' "$os_user"
        fi
        if [[ -n "$_create_audit_idle_timeout" ]]; then
          printf 'idle_timeout=%s\n' "$_create_audit_idle_timeout"
        fi
        if [[ -n "$_create_audit_loop" ]]; then
          printf 'loop=%s\n' "$_create_audit_loop"
        fi
        if [[ $always_on -eq 1 ]]; then
          printf 'always_on=yes\n'
        fi
      } | tr '\n' ',' | sed 's/,$//'
    )"
    bridge_agent_update_emit_audit \
      "agent-create-apply" \
      "$_create_audit_actor" \
      "$create_caller_source" \
      "$agent" \
      "$_create_audit_roster_path" \
      "$_create_audit_before_sha" \
      "$_create_audit_after_sha" \
      "agent_create $_create_audit_summary" \
      "" \
      "" \
      "$launch_cmd" \
      "" \
      "$channels" \
      "[]" \
      "" \
      "$_create_audit_idle_timeout" \
      "" \
      "$_create_audit_loop" \
      "$always_on_intent"
    # Issue #1076: every mutation in the create flow has now completed.
    # Mark complete + disarm the EXIT trap so a normal exit does NOT roll
    # back a successful create. A failure ANYWHERE above this line leaves
    # _CREATE_ROLLBACK_COMPLETE=0, and the trap rolls back on shell exit.
    _CREATE_ROLLBACK_COMPLETE=1
    trap - EXIT
  fi

  # Beta20 L2 Variant 3A — refresh the daemon's supplementary groups so
  # the new per-agent group becomes visible to bridge-send.sh --urgent
  # writes / channel-readiness probes / Stop-hook idle-since checks. The
  # refresh is non-fatal: an already-created agent stays created
  # regardless of refresh result, and the rollback trap is already
  # disarmed above so a refresh failure here CANNOT unwind the agent.
  # Skipped on macOS, when the daemon isn't running, and when the daemon's
  # /proc/<pid>/status Groups already contains the target GID. Status is
  # surfaced via daemon_group_refresh / manual_command fields below.
  local daemon_group_refresh_status=""
  if [[ "$isolation_mode" == "linux-user" ]] \
     && command -v bridge_daemon_refresh_after_group_membership_change >/dev/null 2>&1; then
    local _v2_grp_for_refresh=""
    if command -v bridge_isolation_v2_agent_group_name >/dev/null 2>&1; then
      _v2_grp_for_refresh="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || true)"
    fi
    if [[ -n "$_v2_grp_for_refresh" ]]; then
      daemon_group_refresh_status="$(
        bridge_daemon_refresh_after_group_membership_change \
          --group "$_v2_grp_for_refresh" \
          --reason "agent-create:$agent" \
          2>/dev/null || true
      )"
    fi
  fi

  if [[ $json_mode -eq 1 ]]; then
    # Issue #1093: derive the persisted-policy fields the same way the
    # writer does so the JSON envelope agrees with what landed on disk.
    # idle_timeout_persisted: "0" when --always-on (legacy behavior), the
    # raw --idle-timeout value otherwise, or empty for the default
    # (writer omits the line). loop_persisted: "yes" / "no" / empty,
    # mirroring the LOOP="1" / LOOP="0" / omitted writer paths.
    local _emit_idle_timeout=""
    if [[ -n "$idle_timeout_value" ]]; then
      _emit_idle_timeout="$idle_timeout_value"
    elif [[ $always_on -eq 1 ]]; then
      _emit_idle_timeout="0"
    fi
    local _emit_loop=""
    if [[ $loop_explicit_off -eq 1 ]]; then
      _emit_loop="no"
    elif [[ $loop_mode -eq 1 ]]; then
      _emit_loop="yes"
    fi
    emit_create_json \
      "$agent" "$engine" "$session" "$workdir" "$profile_home" \
      "$launch_cmd" "$channels" "$BRIDGE_ROSTER_LOCAL_FILE" "$dry_run" \
      "$users_json" "$session_type" "$isolation_mode" "$os_user" \
      "$_emit_idle_timeout" "$_emit_loop" "$always_on_intent" \
      "$daemon_group_refresh_status"
    exit 0
  fi

  printf 'agent: %s\n' "$agent"
  printf 'engine: %s\n' "$engine"
  printf 'session_type: %s\n' "$session_type"
  printf 'session: %s\n' "$session"
  printf 'workdir: %s\n' "$workdir"
  if [[ -n "$profile_home" ]]; then
    printf 'profile_home: %s\n' "$profile_home"
  fi
  printf 'launch_cmd: %s\n' "$launch_cmd"
  printf 'users: %s\n' "$users_json"
  if [[ -n "$channels" ]]; then
    printf 'channels: %s\n' "$channels"
  fi
  printf 'isolation_mode: %s\n' "$isolation_mode"
  if [[ -n "$os_user" ]]; then
    printf 'os_user: %s\n' "$os_user"
  fi
  printf 'roster_file: %s\n' "$BRIDGE_ROSTER_LOCAL_FILE"
  if [[ $always_on -eq 1 ]]; then
    echo "always_on: yes"
  fi
  # Issue #1093: surface the persisted idle_timeout / loop policy so the
  # caller's text output reflects what landed in the roster. always_on=yes
  # already implies idle_timeout=0, so the explicit line is suppressed in
  # that case to keep the output minimal.
  if [[ -n "$idle_timeout_value" && $always_on -ne 1 ]]; then
    printf 'idle_timeout: %s\n' "$idle_timeout_value"
  fi
  if [[ $loop_explicit_off -eq 1 ]]; then
    echo "loop: no"
  elif [[ $loop_mode -eq 1 ]]; then
    echo "loop: yes"
  fi
  if [[ $dry_run -eq 1 ]]; then
    echo "dry_run: yes"
  else
    echo "create: ok"
    # Beta20 L2 Variant 3A — surface refresh status + manual recovery
    # path so the operator sees the wedge BEFORE attempting the next
    # urgent-send/restart that would silently fall through to queue-only.
    if [[ -n "$daemon_group_refresh_status" ]]; then
      echo "daemon_group_refresh: $daemon_group_refresh_status"
      case "$daemon_group_refresh_status" in
        manual-required-sudoers)
          echo ""
          echo "[restart-required] daemon supplementary groups stale — automatic refresh failed: sudoers config absent or rejected."
          echo "Run: agent-bridge init sudoers daemon-refresh --apply"
          echo "Then retry: bash bridge-daemon.sh restart --force --internal-reason=group-refresh"
          ;;
        manual-required-sudo-refresh-no-gid)
          echo ""
          echo "[restart-required] daemon supplementary groups stale — sudo/PAM did not refresh groups on this host."
          echo "Verify: sudo -n -u \"$(id -un)\" -H -- bash -c 'id -G'"
          echo "Then run: bash bridge-daemon.sh restart --force"
          ;;
        failed-restart|failed-timeout)
          echo ""
          echo "[restart-required] daemon refresh failed ($daemon_group_refresh_status) — manual restart recommended."
          echo "Run: bash bridge-daemon.sh restart --force"
          ;;
      esac
    fi
    echo "start_dry_run: $start_dry_run_status"
    echo "$start_dry_run"
    echo "next_steps:"
    echo "  - agent-bridge setup agent $agent"
    echo "  - agent-bridge status --all-agents"
  fi
}

# run_update — typed audited update path for protected managed-role
# fields in agent-roster.local.sh (issue #528).
#
# Reuses bridge_write_role_block (the same writer agent-create uses)
# with replace_existing=1 so the managed-role block emission shape stays
# consistent and `# BEGIN/END AGENT BRIDGE MANAGED ROLE: <agent>`
# delimiters round-trip. Computes the new launch_cmd / channels values
# in-memory from typed flags, then hands every other field through from
# the loaded roster so we are not reaching into the file with regex.
#
# Caller validation mirrors bridge-config.py:cmd_set: caller must be the
# admin agent AND the source must be operator-tui / operator-trusted-id.
# Audit row mirrors cmd_set's wrapper-apply detail shape so audit verify
# treats it the same way.
run_update() {
  local agent="${1:-}"
  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") update <agent> [...]"
  bridge_require_agent "$agent"

  local from_agent=""
  local dry_run=0
  local json_mode=0
  local set_launch_cmd_present=0
  local set_launch_cmd_value=""
  local channels_set_present=0
  local channels_set_value=""
  local mutation_present=0
  # TSV streams for the two computers; assembled then piped on stdin.
  local launch_cmd_ops=""
  local channels_ops=""

  # Issue #580 Track 2: typed-flag completion. Each flag tracks
  # presence + value; presence drives whether the writer overrides the
  # current roster value. Loop is encoded as a tri-state (unset / "1" /
  # "0") because the writer needs the explicit-off bit (positional 20)
  # to actually emit LOOP="0" — see bridge_write_role_block.
  local desc_present=0
  local desc_value=""
  local engine_present=0
  local engine_value=""
  local workdir_present=0
  local workdir_value=""
  local loop_present=0
  local loop_value=""        # "1" (on) | "0" (off)
  local continue_present=0
  local continue_value=""    # "1" (on) | "0" (off)
  local class_present=0
  local class_value=""
  # Issue #1093: typed flag for BRIDGE_AGENT_IDLE_TIMEOUT mutation. Same
  # tri-state shape the other typed flags use — presence drives whether
  # the writer overrides the current value, and value is validated
  # against `^[0-9]+$` at parse time so a bad write never lands.
  local idle_timeout_present=0
  local idle_timeout_value=""
  # Issue #1136: declarative direction the operator passed via
  # `--always-on yes|no`. Empty when the flag was not used (bare
  # `--idle-timeout <N>` records the numeric delta only). "always_on_yes"
  # / "always_on_no" otherwise. Surfaced verbatim as the `expressed_intent`
  # field on the audit row + `--json` envelope, including on the
  # `changed=false` no-op mutation case (re-affirming policy still
  # produces a searchable audit receipt).
  local always_on_intent=""
  local always_on_no_present=0

  add_launch_cmd_op() {
    launch_cmd_ops+="$1"$'\t'"$2"$'\n'
    mutation_present=1
  }
  add_channels_op() {
    channels_ops+="$1"$'\t'"$2"$'\n'
    mutation_present=1
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        from_agent="$2"
        shift 2
        ;;
      --set-launch-cmd)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        set_launch_cmd_present=1
        set_launch_cmd_value="$2"
        # Encoded as a TSV op so the stream-driven applier sees it in
        # the same path as the other launch-cmd mutations.
        add_launch_cmd_op "set-launch-cmd" "$2"
        shift 2
        ;;
      --launch-cmd-add-env)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        # Strict KEY=VALUE shape (codex r1 finding 2): the value flows
        # through bridge_write_role_block into BRIDGE_AGENT_LAUNCH_CMD,
        # which bridge-run.sh:574 hands to `bash -lc`. KEY must match the
        # POSIX env-var-name rule; VALUE may be empty but cannot embed
        # newlines or null bytes (those would corrupt the roster line and
        # the bash -lc string). Stricter shell-metachar quoting is the
        # writer's job (the managed-role block writer single-quotes
        # launch_cmd on emission), so we do not reject `'`, `"`, `$`,
        # `` ` `` here — that would refuse legitimate values such as a
        # path containing a dollar sign.
        if [[ ! "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
          bridge_die "--launch-cmd-add-env 는 KEY=VALUE 형식이어야 합니다 (KEY matches ^[A-Za-z_][A-Za-z0-9_]*$): $2"
        fi
        # Reject embedded newlines. Bash strings cannot carry literal
        # NUL bytes (argv truncates at NUL on entry to this process), so
        # there is no separate `*$'\0'*` arm — the kernel-level
        # truncation already enforces the NUL floor. The `*$'\0'*` glob
        # would degenerate to `**` and match every value.
        case "$2" in
          *$'\n'*)
            bridge_die "--launch-cmd-add-env 값에 줄바꿈이 포함될 수 없습니다: $2"
            ;;
        esac
        add_launch_cmd_op "add-env" "$2"
        shift 2
        ;;
      --launch-cmd-remove-env)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        # Same KEY shape on the remove side so a malformed key never
        # reaches the python applier.
        if [[ ! "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          bridge_die "--launch-cmd-remove-env 는 KEY 형식이어야 합니다 (^[A-Za-z_][A-Za-z0-9_]*$): $2"
        fi
        add_launch_cmd_op "remove-env" "$2"
        shift 2
        ;;
      --launch-cmd-add-dev-channel)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        bridge_agent_update_validate_channel_token "--launch-cmd-add-dev-channel" "$2"
        add_launch_cmd_op "add-dev-channel" "$2"
        shift 2
        ;;
      --launch-cmd-remove-dev-channel)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        bridge_agent_update_validate_channel_token "--launch-cmd-remove-dev-channel" "$2"
        add_launch_cmd_op "remove-dev-channel" "$2"
        shift 2
        ;;
      --channels-set)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        # Per-token plugin:NAME@SPEC validation on the CSV (codex r1
        # finding 4). Allow trailing-comma tolerance and skip empty
        # entries, but reject any non-empty token that fails the shape.
        bridge_agent_update_validate_channels_csv "--channels-set" "$2"
        channels_set_present=1
        channels_set_value="$2"
        add_channels_op "channels-set" "$2"
        shift 2
        ;;
      --channels-add)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        bridge_agent_update_validate_channel_token "--channels-add" "$2"
        add_channels_op "channels-add" "$2"
        shift 2
        ;;
      --channels-remove)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        bridge_agent_update_validate_channel_token "--channels-remove" "$2"
        add_channels_op "channels-remove" "$2"
        shift 2
        ;;
      --json)
        json_mode=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --desc)
        # Description flows verbatim into BRIDGE_AGENT_DESC[...] which
        # is rendered as a single roster line; reject embedded
        # newlines for the same reason --launch-cmd-add-env does
        # (managed-role block is line-oriented).
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        case "$2" in
          *$'\n'*)
            bridge_die "--desc 값에 줄바꿈이 포함될 수 없습니다."
            ;;
        esac
        desc_present=1
        desc_value="$2"
        mutation_present=1
        shift 2
        ;;
      --engine)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        case "$2" in
          claude|codex) ;;
          *) bridge_die "--engine 는 claude|codex 만 가능합니다: $2" ;;
        esac
        engine_present=1
        engine_value="$2"
        mutation_present=1
        shift 2
        ;;
      --workdir)
        # Empty workdir is ambiguous and would break bridge-run.sh's
        # `cd "$WORKDIR"` step; refuse it at parse time. We do not
        # validate existence here because `agent create` also accepts
        # not-yet-created paths (it scaffolds them); update keeps the
        # same loose-validation contract.
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        if [[ -z "$2" ]]; then
          bridge_die "--workdir 값이 비어 있습니다."
        fi
        case "$2" in
          *$'\n'*)
            bridge_die "--workdir 값에 줄바꿈이 포함될 수 없습니다."
            ;;
        esac
        workdir_present=1
        workdir_value="$2"
        mutation_present=1
        shift 2
        ;;
      --loop)
        # Issue #1093: `--loop` accepts on|off (Track-2 legacy) AND
        # yes|no (the create-symmetric form). Production reader
        # (bridge_agent_loop) defaults to "1", treats anything truthy as
        # "on". `--loop off` / `--loop no` opts the writer into emitting
        # BRIDGE_AGENT_LOOP="0" via positional 20 (loop_explicit_off=1).
        # Time-window seconds are intentionally out of scope for Track 2
        # — there is no production reader for them today.
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        case "$2" in
          on|yes|YES|Yes|ON|On)   loop_value="1" ;;
          off|no|NO|No|OFF|Off)   loop_value="0" ;;
          *) bridge_die "--loop 는 on|off|yes|no 만 가능합니다: $2" ;;
        esac
        loop_present=1
        mutation_present=1
        shift 2
        ;;
      --idle-timeout)
        # Issue #1093: integer ≥0 (seconds). 0 is the always-on
        # convention used by bridge_agent_is_always_on (no separate
        # field). Validate at parse time so a bad value never reaches
        # the writer; emits BRIDGE_AGENT_IDLE_TIMEOUT="<value>" via
        # positional 21 (idle_timeout_value).
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        if [[ ! "$2" =~ ^[0-9]+$ ]]; then
          bridge_die "--idle-timeout 는 0 이상의 정수여야 합니다: $2"
        fi
        idle_timeout_present=1
        idle_timeout_value="$2"
        mutation_present=1
        shift 2
        ;;
      --always-on)
        # Issue #1093 / #1136: `--always-on yes` is sugar for
        # `--idle-timeout 0`. `--always-on no` (added by #1136) is the
        # symmetric inverse — it MUST be paired with an explicit
        # `--idle-timeout <positive>` so the target value is never
        # implicit. Both directions stamp `expressed_intent` on the audit
        # row (always_on_intent) so audit-log grep returns every
        # operator-declared policy-flip event regardless of numeric delta.
        # The contradictory-combination matrix (yes + --idle-timeout
        # <positive>, no without --idle-timeout, no + --idle-timeout 0,
        # yes after a prior no, no after a prior yes) is enforced after
        # the parse loop so flag ordering doesn't matter.
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        case "$2" in
          yes|YES|Yes)
            if [[ -n "$always_on_intent" && "$always_on_intent" != "always_on_yes" ]]; then
              bridge_die "--always-on yes 와 --always-on no 는 함께 지정할 수 없습니다."
            fi
            always_on_intent="always_on_yes"
            mutation_present=1
            ;;
          no|NO|No)
            if [[ -n "$always_on_intent" && "$always_on_intent" != "always_on_no" ]]; then
              bridge_die "--always-on yes 와 --always-on no 는 함께 지정할 수 없습니다."
            fi
            always_on_intent="always_on_no"
            always_on_no_present=1
            mutation_present=1
            ;;
          *) bridge_die "--always-on 는 yes|no 만 가능합니다: $2" ;;
        esac
        shift 2
        ;;
      --continue)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        case "$2" in
          on)  continue_value="1" ;;
          off) continue_value="0" ;;
          *)   bridge_die "--continue 는 on|off 만 가능합니다: $2" ;;
        esac
        continue_present=1
        mutation_present=1
        shift 2
        ;;
      --class)
        # Closed value space matches bridge_validate_agent_classes
        # (lib/bridge-agents.sh:413). Operator-supplied values that
        # would later trip the load-time validator must be refused at
        # parse time so a bad write never lands.
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        case "$2" in
          user|system) ;;
          *) bridge_die "--class 는 user|system 만 가능합니다: $2" ;;
        esac
        class_present=1
        class_value="$2"
        mutation_present=1
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        bridge_die "지원하지 않는 agent update 옵션입니다: $1"
        ;;
    esac
  done

  # Issue #1136: validate the `--always-on` combination matrix BEFORE
  # the mutual-exclusion checks below, then apply the sugar / co-flag
  # rules so downstream presence/value logic sees a single normalised
  # idle_timeout target. The intent string (`always_on_intent`) survives
  # post-normalisation because it's what threads through to the audit
  # `expressed_intent` field; the numeric mapping is handled inline here.
  case "$always_on_intent" in
    always_on_yes)
      # `--always-on yes` + `--idle-timeout <positive>` are contradictory
      # — yes means "no idle timeout (=0)" and a positive value flips the
      # other direction. Refuse at parse time; the operator should pick
      # one shape.
      if [[ $idle_timeout_present -eq 1 && "$idle_timeout_value" != "0" ]]; then
        bridge_die "--always-on yes 는 --idle-timeout <positive> 와 함께 사용할 수 없습니다 (의미 충돌). 항상-on 은 --always-on yes 또는 --idle-timeout 0 만 사용하세요."
      fi
      # Apply the sugar: --always-on yes -> idle_timeout=0.
      idle_timeout_present=1
      idle_timeout_value="0"
      ;;
    always_on_no)
      # Symmetric inverse requires an explicit positive idle_timeout
      # co-flag. The implicit "default" semantics would be ambiguous
      # because missing BRIDGE_AGENT_IDLE_TIMEOUT reads as 0 (always-on).
      if [[ $idle_timeout_present -ne 1 ]]; then
        bridge_die "--always-on no requires --idle-timeout <seconds> (positive integer)"
      fi
      if [[ "$idle_timeout_value" == "0" ]]; then
        bridge_die "--always-on no with --idle-timeout 0 is contradictory; use --always-on yes for always-on, or pass a positive idle-timeout for on-demand"
      fi
      ;;
  esac

  # Mutual-exclusion: --set-launch-cmd is a full replace; combining it
  # with the additive/removal flags is ambiguous. Same for --channels-set.
  if [[ $set_launch_cmd_present -eq 1 ]]; then
    local non_set_launch=0
    local op=""
    while IFS=$'\t' read -r op _; do
      [[ -n "$op" && "$op" != "set-launch-cmd" ]] && non_set_launch=1
    done <<<"$launch_cmd_ops"
    [[ $non_set_launch -eq 0 ]] || \
      bridge_die "--set-launch-cmd 는 다른 launch-cmd 변경 플래그와 함께 사용할 수 없습니다."
  fi
  if [[ $channels_set_present -eq 1 ]]; then
    local non_set_channels=0
    while IFS=$'\t' read -r op _; do
      [[ -n "$op" && "$op" != "channels-set" ]] && non_set_channels=1
    done <<<"$channels_ops"
    [[ $non_set_channels -eq 0 ]] || \
      bridge_die "--channels-set 는 다른 channels 변경 플래그와 함께 사용할 수 없습니다."
  fi

  if [[ $mutation_present -eq 0 ]]; then
    bridge_die "agent update 변경 플래그가 하나 이상 필요합니다."
  fi

  # Issue #1023: a `--launch-cmd-add-env KEY=VALUE` op carries a raw,
  # possibly comma-containing secret value. Redact each launch op's
  # payload HERE — while the ops are still the discrete TSV stream
  # `launch_cmd_ops` — so a comma inside a value is never confused with
  # an op delimiter. The redactor emits the `launch:<op>=<payload>`
  # lines directly; redacting AFTER the comma-join would strand the
  # value's suffix as a bare token that escapes redaction. Value-only:
  # env key names stay visible so audit readers see which key changed.
  # `launch_cmd_ops` itself is untouched — the applier downstream still
  # sees the real value.
  local launch_ops_summary_lines=""
  if [[ -n "$launch_cmd_ops" ]]; then
    launch_ops_summary_lines="$(
      python3 "$SCRIPT_DIR/scripts/python-helpers/launch-cmd-redact.py" \
        launch-ops "$launch_cmd_ops"
    )"
  fi

  # Capture the operation summary for the audit row (compact one-line
  # description of what the operator asked for).
  local operation_summary=""
  operation_summary="$(
    {
      if [[ -n "$launch_ops_summary_lines" ]]; then
        printf '%s\n' "$launch_ops_summary_lines"
      fi
      printf '%s' "$channels_ops" | sed 's/\t/=/' | sed 's/^/chan:/'
      # Issue #580 Track 2: surface typed-flag mutations in the audit
      # operation summary so audit-log readers see the same shape they
      # do for launch/channel mutations. `if/fi` (rather than `[[ ... ]] &&`)
      # so the trailing test does not exit-1 the command substitution
      # subshell under `set -e` when the flag is absent.
      if [[ $desc_present     -eq 1 ]]; then printf 'desc=set\n'; fi
      if [[ $engine_present   -eq 1 ]]; then printf 'engine=%s\n' "$engine_value"; fi
      if [[ $workdir_present  -eq 1 ]]; then printf 'workdir=set\n'; fi
      if [[ $loop_present     -eq 1 ]]; then
        if [[ "$loop_value" == "1" ]]; then printf 'loop=on\n'; else printf 'loop=off\n'; fi
      fi
      if [[ $continue_present -eq 1 ]]; then
        if [[ "$continue_value" == "1" ]]; then printf 'continue=on\n'; else printf 'continue=off\n'; fi
      fi
      if [[ $class_present    -eq 1 ]]; then printf 'class=%s\n' "$class_value"; fi
      # Issue #1093: idle_timeout mutation surfaces verbatim in the audit
      # summary so log readers see what value the operator persisted.
      if [[ $idle_timeout_present -eq 1 ]]; then
        printf 'idle_timeout=%s\n' "$idle_timeout_value"
      fi
      # Issue #1136: surface the operator-declared `--always-on` direction
      # in the same one-line summary so audit-log readers see policy-flip
      # events without joining on `expressed_intent`. Empty when the flag
      # was not used (bare `--idle-timeout` records the numeric delta
      # only).
      if [[ -n "$always_on_intent" ]]; then
        case "$always_on_intent" in
          always_on_yes) printf 'always_on=yes\n' ;;
          always_on_no)  printf 'always_on=no\n' ;;
        esac
      fi
    } | tr '\n' ',' | sed 's/,$//'
  )"

  # Caller validation: admin identity + operator-trusted source.
  local caller_agent caller_source
  caller_agent="$(bridge_agent_update_caller_agent "$from_agent")"
  caller_source="$(bridge_agent_update_caller_source)"

  local roster_path="$BRIDGE_ROSTER_LOCAL_FILE"
  local before_sha
  before_sha="$(bridge_agent_update_file_sha256 "$roster_path")"

  local actor_label="$caller_agent"
  if [[ -z "$actor_label" ]]; then
    if [[ "$caller_source" == "operator-tui" ]]; then
      actor_label="operator"
    else
      actor_label="unknown"
    fi
  fi

  local deny_reason=""
  if [[ -z "$caller_agent" ]]; then
    deny_reason="caller_agent unspecified — pass --from <admin-agent> or set BRIDGE_AGENT_ID before invoking 'agent-bridge agent update'"
  elif ! bridge_agent_update_caller_is_admin "$caller_agent"; then
    deny_reason="caller agent $caller_agent is not the admin agent — refusing managed-role mutation"
  elif [[ "$caller_source" != "operator-tui" && "$caller_source" != "operator-trusted-id" ]]; then
    deny_reason="caller source $caller_source is not allowed to mutate system config (need operator-tui or operator-trusted-id)"
  fi

  local before_launch_cmd
  before_launch_cmd="$(bridge_agent_launch_cmd_raw "$agent")"
  local before_channels
  before_channels="$(bridge_agent_channels_csv "$agent")"

  if [[ -n "$deny_reason" ]]; then
    bridge_agent_update_emit_audit \
      "agent-update-deny" \
      "$actor_label" \
      "$caller_source" \
      "$agent" \
      "$roster_path" \
      "$before_sha" \
      "" \
      "$operation_summary" \
      "$deny_reason" \
      "$before_launch_cmd" \
      "" \
      "$before_channels" \
      "" \
      "[]" \
      "" \
      "" \
      "" \
      "" \
      "$always_on_intent"
    bridge_die "deny: $deny_reason"
  fi

  # Compute the new launch_cmd value.
  local new_launch_cmd="$before_launch_cmd"
  local launch_actions_json="[]"
  if [[ -n "$launch_cmd_ops" ]]; then
    local lc_output
    lc_output="$(printf '%s' "$launch_cmd_ops" | bridge_agent_update_apply_launch_cmd "$before_launch_cmd")"
    new_launch_cmd="$(printf '%s\n' "$lc_output" | sed -n '1p')"
    launch_actions_json="$(printf '%s\n' "$lc_output" | sed -n '2p')"
  fi

  # Compute the new channels CSV value.
  local new_channels="$before_channels"
  local channels_actions_json="[]"
  if [[ -n "$channels_ops" ]]; then
    local ch_output
    ch_output="$(printf '%s' "$channels_ops" | bridge_agent_update_apply_channels "$before_channels")"
    new_channels="$(printf '%s\n' "$ch_output" | sed -n '1p')"
    channels_actions_json="$(printf '%s\n' "$ch_output" | sed -n '2p')"
  fi

  # Merge actions arrays for the result envelope + audit row.
  local merged_actions_json
  merged_actions_json="$(
    bridge_require_python
    LC_JSON="$launch_actions_json" CH_JSON="$channels_actions_json" python3 - <<'PY'
import json, os
left = json.loads(os.environ.get("LC_JSON") or "[]")
right = json.loads(os.environ.get("CH_JSON") or "[]")
print(json.dumps(left + right, ensure_ascii=False))
PY
  )"

  # Issue #580 Track 2: capture before/after values for the typed-flag
  # set so changed-detection and the audit row reflect the full surface.
  # Issue #1093: idle_timeout added to the captured set so the audit row
  # carries before/after idle_timeout deltas and the no-op short-circuit
  # below recognises a repeated `--idle-timeout` as `changed=false`.
  local before_desc before_engine before_workdir before_loop before_continue before_class
  local before_idle_timeout
  before_desc="$(bridge_agent_desc "$agent")"
  before_engine="$(bridge_agent_engine "$agent")"
  before_workdir="$(bridge_agent_workdir "$agent")"
  before_loop="$(bridge_agent_loop "$agent")"
  before_continue="$(bridge_agent_continue "$agent")"
  before_class="$(bridge_agent_class "$agent")"
  before_idle_timeout="$(bridge_agent_idle_timeout "$agent")"
  # Issue #1093: detect real configured-ness from the roster FILE rather
  # than the in-memory map. bridge-state.sh:1236 backfills
  # BRIDGE_AGENT_IDLE_TIMEOUT for every loaded agent to the default 0, so
  # bridge_agent_idle_timeout_configured (which checks `-v
  # BRIDGE_AGENT_IDLE_TIMEOUT[$agent]`) is always true after load. Grep
  # the protected file for the explicit assignment line so "configure as
  # always-on" on a previously-unconfigured agent reports `changed=true`
  # and the writer persists the IDLE_TIMEOUT="0" line.
  local before_idle_timeout_configured=0
  # Codex r1 BLOCKING: use -F (fixed-string) so a `.` (or any regex
  # metacharacter) in the agent name doesn't act as a wildcard — an
  # agent named `a.b` would otherwise falsely match `axb`'s timeout
  # line. The key form is structurally unique inside the roster, so a
  # fixed-string contains-match is correct.
  if [[ -f "$roster_path" ]] && grep -qF "BRIDGE_AGENT_IDLE_TIMEOUT[\"${agent}\"]=" "$roster_path"; then
    before_idle_timeout_configured=1
  fi

  local new_desc="$before_desc"
  local new_engine="$before_engine"
  local new_workdir="$before_workdir"
  local new_loop="$before_loop"
  local new_continue="$before_continue"
  local new_class="$before_class"
  local new_idle_timeout="$before_idle_timeout"
  local new_idle_timeout_configured="$before_idle_timeout_configured"
  [[ $desc_present -eq 1 ]]         && new_desc="$desc_value"
  [[ $engine_present -eq 1 ]]       && new_engine="$engine_value"
  [[ $workdir_present -eq 1 ]]      && new_workdir="$workdir_value"
  [[ $loop_present -eq 1 ]]         && new_loop="$loop_value"
  [[ $continue_present -eq 1 ]]     && new_continue="$continue_value"
  [[ $class_present -eq 1 ]]        && new_class="$class_value"
  if [[ $idle_timeout_present -eq 1 ]]; then
    new_idle_timeout="$idle_timeout_value"
    new_idle_timeout_configured=1
  fi

  local changed=0
  if [[ "$new_launch_cmd" != "$before_launch_cmd" \
        || "$new_channels" != "$before_channels" \
        || "$new_desc" != "$before_desc" \
        || "$new_engine" != "$before_engine" \
        || "$new_workdir" != "$before_workdir" \
        || "$new_loop" != "$before_loop" \
        || "$new_continue" != "$before_continue" \
        || "$new_class" != "$before_class" \
        || "$new_idle_timeout" != "$before_idle_timeout" \
        || "$new_idle_timeout_configured" != "$before_idle_timeout_configured" ]]; then
    changed=1
  fi

  local after_sha=""
  if [[ $changed -eq 1 && $dry_run -eq 0 ]]; then
    # Reuse the existing managed-role block writer (lines ~606-740).
    # Pass every non-mutated field through unchanged so the rewritten
    # block matches `agent create`'s emission shape byte-for-byte except
    # for the lines we are touching.
    local session profile_home discord_channel
    local notify_kind notify_target notify_account
    local always_on isolation_mode os_user
    session="$(bridge_agent_session "$agent")"
    profile_home="$(bridge_agent_profile_home "$agent")"
    discord_channel="$(bridge_agent_discord_channel_id "$agent")"
    notify_kind="$(bridge_agent_notify_kind "$agent")"
    notify_target="$(bridge_agent_notify_target "$agent")"
    notify_account="$(bridge_agent_notify_account "$agent")"
    isolation_mode="$(bridge_agent_isolation_mode "$agent")"
    os_user="$(bridge_agent_os_user "$agent")"
    # Issue #1093: the writer's `always_on==1 → IDLE_TIMEOUT="0"` legacy
    # path is now subordinate to positional 21 (idle_timeout_value).
    # When idle_timeout is NOT configured in the current roster AND the
    # caller did not pass --idle-timeout, leave always_on=0 so the writer
    # omits the IDLE_TIMEOUT line — preserving byte-identical emission
    # for updates that only touch other fields (e.g. --desc). When the
    # roster has it OR the caller is setting it, the value flows through
    # positional 21 below and always_on is informational only. Use the
    # file-grep configured bit captured above — the in-memory
    # _idle_timeout_configured check is unreliable because the loader
    # backfills the map.
    if [[ "$new_idle_timeout_configured" == "1" ]]; then
      if [[ "$new_idle_timeout" == "0" ]]; then
        always_on=1
      else
        always_on=0
      fi
    else
      always_on=0
    fi
    # The explicit-off bit must be set both when this call requested
    # `--loop off` AND when the current roster already has the
    # explicit-off line set. Without the latter, a second update on an
    # already-loop-off agent would lose the LOOP="0" line and silently
    # flip back to the reader's default-1 behavior on the next load.
    # Other paths (legacy callers, agent create) keep the byte-identical
    # emission shape because they never reach this code site.
    local loop_explicit_off_arg=0
    if [[ "$new_loop" == "0" ]]; then
      loop_explicit_off_arg=1
    fi
    # Issue #1093: positional 21 (idle_timeout_value) carries the
    # post-mutation value. Always pass it on the update path so a
    # rewrite that touches OTHER fields (e.g. --desc) preserves the
    # roster's current IDLE_TIMEOUT line when it had one. Use the
    # file-grep configured bit to determine whether the line should be
    # written (the loader-backfilled in-memory map is unreliable).
    local idle_timeout_writer_arg=""
    if [[ "$new_idle_timeout_configured" == "1" ]]; then
      idle_timeout_writer_arg="$new_idle_timeout"
    fi
    bridge_write_role_block \
      "$agent" \
      "$new_desc" \
      "$new_engine" \
      "$session" \
      "$new_workdir" \
      "$profile_home" \
      "$new_launch_cmd" \
      "$new_channels" \
      "$discord_channel" \
      "$notify_kind" \
      "$notify_target" \
      "$notify_account" \
      "$new_loop" \
      "$new_continue" \
      "$always_on" \
      "$isolation_mode" \
      "$os_user" \
      "1" \
      "$new_class" \
      "$loop_explicit_off_arg" \
      "$idle_timeout_writer_arg" >/dev/null
    after_sha="$(bridge_agent_update_file_sha256 "$roster_path")"

    # Issue #989: bridge_write_role_block just rewrote the roster file —
    # for a linux-user isolated agent the cached `runtime/agent-env.sh`
    # (the only roster snapshot the isolated UID can read) now holds a
    # stale BRIDGE_AGENT_LAUNCH_CMD whose embedded channel state paths
    # may be pre-v2 (`agents/<X>/.teams` instead of
    # `agents/<X>/workdir/.teams`) → EACCES → silent inbound delivery
    # loss (#771 regression). The shared helper invalidates the
    # per-process roster cache, reloads from disk, and regenerates the
    # cached env file. NO-OP for non-isolated agents.
    bridge_refresh_isolated_agent_env_after_channel_mutation "$agent"
  else
    after_sha="$before_sha"
  fi

  local trigger_label="agent-update-apply"
  if [[ $dry_run -eq 1 ]]; then
    trigger_label="agent-update-dry-run"
  fi

  # Issue #1093: surface policy deltas in the audit row and JSON
  # envelope only when this mutation actually touched idle_timeout or
  # loop. The helpers default to dropping empty pairs, so leaving the
  # args empty for unrelated mutations keeps the existing detail shape.
  # The values mirror what `bridge_agent_idle_timeout` / `bridge_agent_loop`
  # would return (default "0" / "1" for unconfigured agents) so audit
  # readers see the runtime-observable value. The first-time configure
  # case (unset → "0") still surfaces because the configured-ness
  # transition trips the `changed` bit above and forces the pair to be
  # emitted, even though the numeric value matches.
  local audit_before_idle="" audit_after_idle=""
  local audit_before_loop="" audit_after_loop=""
  if [[ "$new_idle_timeout" != "$before_idle_timeout" \
        || "$new_idle_timeout_configured" != "$before_idle_timeout_configured" \
        || $idle_timeout_present -eq 1 ]]; then
    audit_before_idle="$before_idle_timeout"
    audit_after_idle="$new_idle_timeout"
  fi
  if [[ "$new_loop" != "$before_loop" || $loop_present -eq 1 ]]; then
    audit_before_loop="$before_loop"
    audit_after_loop="$new_loop"
  fi

  bridge_agent_update_emit_audit \
    "$trigger_label" \
    "$actor_label" \
    "$caller_source" \
    "$agent" \
    "$roster_path" \
    "$before_sha" \
    "$after_sha" \
    "$operation_summary" \
    "" \
    "$before_launch_cmd" \
    "$new_launch_cmd" \
    "$before_channels" \
    "$new_channels" \
    "$merged_actions_json" \
    "$audit_before_idle" \
    "$audit_after_idle" \
    "$audit_before_loop" \
    "$audit_after_loop" \
    "$always_on_intent"

  if [[ $json_mode -eq 1 ]]; then
    bridge_agent_update_emit_json \
      "$agent" \
      "$changed" \
      "$dry_run" \
      "$before_launch_cmd" \
      "$new_launch_cmd" \
      "$before_channels" \
      "$new_channels" \
      "$before_sha" \
      "$after_sha" \
      "$merged_actions_json" \
      "$audit_before_idle" \
      "$audit_after_idle" \
      "$audit_before_loop" \
      "$audit_after_loop" \
      "$always_on_intent"
    return 0
  fi

  # Issue #1023: the plain-text result echoes the full before/after
  # launch command, whose leading env-prefix routinely carries
  # credential-bearing values. Redact secret env values (value-only,
  # key name kept) before printing. Output-rendering only — the stored
  # launch command written above is unchanged.
  local before_launch_cmd_display new_launch_cmd_display
  before_launch_cmd_display="$(
    python3 "$SCRIPT_DIR/scripts/python-helpers/launch-cmd-redact.py" \
      launch-cmd "$before_launch_cmd"
  )"
  new_launch_cmd_display="$(
    python3 "$SCRIPT_DIR/scripts/python-helpers/launch-cmd-redact.py" \
      launch-cmd "$new_launch_cmd"
  )"

  printf 'agent: %s\n' "$agent"
  printf 'changed: %s\n' "$([[ $changed -eq 1 ]] && echo yes || echo no)"
  printf 'dry_run: %s\n' "$([[ $dry_run -eq 1 ]] && echo yes || echo no)"
  printf 'before_launch_cmd: %s\n' "$before_launch_cmd_display"
  printf 'after_launch_cmd: %s\n' "$new_launch_cmd_display"
  printf 'before_channels: %s\n' "$before_channels"
  printf 'after_channels: %s\n' "$new_channels"
  # Issue #1093: surface idle_timeout / loop deltas in plain-text output
  # when the mutation touched them. Empty audit values mean "policy
  # untouched" so the lines are suppressed to keep output minimal.
  if [[ -n "$audit_before_idle" || -n "$audit_after_idle" ]]; then
    printf 'before_idle_timeout: %s\n' "$audit_before_idle"
    printf 'after_idle_timeout: %s\n' "$audit_after_idle"
  fi
  if [[ -n "$audit_before_loop" || -n "$audit_after_loop" ]]; then
    printf 'before_loop: %s\n' "$audit_before_loop"
    printf 'after_loop: %s\n' "$audit_after_loop"
  fi
  printf 'before_sha: %s\n' "$before_sha"
  printf 'after_sha: %s\n' "$after_sha"
}

# run_delete — issue #580 Track 1. Admin-only audited removal of a static
# managed-role block from agent-roster.local.sh. Trust model mirrors
# run_update (admin agent identity + operator-trusted source). Safety
# gates: refuse if agent missing, refuse self-delete of admin, refuse
# active session without --force, refuse open inbox tasks (queued /
# claimed / blocked) without --orphan-tasks. With --orphan-tasks every
# open row assigned to the agent is closed to status `cancelled` with
# closed_ts set (refs #4797) so the row stops counting in `agb task
# summary`. Optional --purge-home / --purge-crons cleanup.
run_delete() {
  local agent=""
  local from_agent=""
  local force=0
  local orphan_tasks=0
  local purge_home=0
  local purge_crons=0
  local dry_run=0
  local json_output=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        from_agent="$2"
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      --orphan-tasks)
        orphan_tasks=1
        shift
        ;;
      --purge-home)
        purge_home=1
        shift
        ;;
      --purge-crons)
        purge_crons=1
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --json)
        json_output=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        bridge_die "지원하지 않는 agent delete 옵션입니다: $1"
        ;;
      *)
        if [[ -z "$agent" ]]; then
          agent="$1"
          shift
        else
          bridge_die "agent delete: 추가 위치 인자는 허용되지 않습니다: $1"
        fi
        ;;
    esac
  done

  [[ -n "$agent" ]] || bridge_die "agent delete: <name> 인자가 필요합니다."

  # Existence — must already be in the local roster (the only file the
  # delete subcommand mutates). bridge_roster_local_mentions_agent is
  # the same probe `reclassify` uses for static-source detection.
  if ! bridge_roster_local_mentions_agent "$agent"; then
    bridge_die "deny: agent '$agent' is not present in the local roster — nothing to delete"
  fi

  # Caller validation — same shape as run_update (#528).
  local caller_agent caller_source
  caller_agent="$(bridge_agent_update_caller_agent "$from_agent")"
  caller_source="$(bridge_agent_update_caller_source)"

  local roster_path="$BRIDGE_ROSTER_LOCAL_FILE"
  local before_sha
  before_sha="$(bridge_agent_update_file_sha256 "$roster_path")"

  local actor_label="$caller_agent"
  if [[ -z "$actor_label" ]]; then
    if [[ "$caller_source" == "operator-tui" ]]; then
      actor_label="operator"
    else
      actor_label="unknown"
    fi
  fi

  local deny_reason=""
  if [[ -z "$caller_agent" ]]; then
    deny_reason="caller_agent unspecified — pass --from <admin-agent> or set BRIDGE_AGENT_ID before invoking 'agent-bridge agent delete'"
  elif ! bridge_agent_update_caller_is_admin "$caller_agent"; then
    deny_reason="caller agent $caller_agent is not the admin agent — refusing managed-role mutation"
  elif [[ "$caller_source" != "operator-tui" && "$caller_source" != "operator-trusted-id" ]]; then
    deny_reason="caller source $caller_source is not allowed to mutate system config (need operator-tui or operator-trusted-id)"
  fi

  # Refuse-if-admin-self: cannot delete the configured admin role from
  # inside it. Strip both sides before comparing — mirror the pattern in
  # lib/bridge-agent-update.sh:104 so a trailing newline / whitespace in
  # BRIDGE_ADMIN_AGENT_ID does not silently bypass the self-delete guard.
  # The admin id may be unset (early bootstrap); in that case there is
  # nothing to refuse.
  if [[ -z "$deny_reason" ]]; then
    local admin_id agent_id
    admin_id="$(bridge_admin_agent_id)"
    admin_id="$(printf '%s' "$admin_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    agent_id="$(printf '%s' "$agent" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -n "$admin_id" && "$agent_id" == "$admin_id" ]]; then
      deny_reason="cannot delete the configured admin agent ($admin_id) from itself — clear BRIDGE_ADMIN_AGENT_ID first"
    fi
  fi

  # Refuse-if-active: only when --force is absent. Reuse the same
  # tmux-backed probe `agent stop` and the daemon use.
  if [[ -z "$deny_reason" && $force -eq 0 ]]; then
    if bridge_agent_is_active "$agent" 2>/dev/null; then
      deny_reason="agent '$agent' has an active session — stop it first or pass --force"
    fi
  fi

  # Refuse-if-open-tasks: count rows in BRIDGE_TASK_DB whose
  # assigned_to=<agent> and status is not terminal, mirroring the queue
  # summary's filters (exclude [cron-dispatch] noise).
  local open_count=0
  if [[ -z "$deny_reason" ]]; then
    if [[ -f "$BRIDGE_TASK_DB" ]]; then
      bridge_require_python
      open_count="$(python3 - "$BRIDGE_TASK_DB" "$agent" <<'PY' 2>/dev/null || printf 0
import sqlite3
import sys

db_path, agent = sys.argv[1], sys.argv[2]
try:
    conn = sqlite3.connect(db_path)
    row = conn.execute(
        """
        SELECT COUNT(*)
        FROM tasks
        WHERE assigned_to = ?
          AND status IN ('queued', 'claimed', 'blocked')
          AND title NOT LIKE '[cron-dispatch]%'
        """,
        (agent,),
    ).fetchone()
    print(int(row[0] or 0))
finally:
    try:
        conn.close()
    except Exception:
        pass
PY
)"
    fi
    [[ "$open_count" =~ ^[0-9]+$ ]] || open_count=0
    if [[ "$open_count" -gt 0 && $orphan_tasks -eq 0 ]]; then
      deny_reason="agent '$agent' has $open_count open inbox task(s) — pass --orphan-tasks to close them"
    fi
  fi

  # Capture before-state (used in both deny and apply audit rows).
  local before_launch_cmd before_channels
  before_launch_cmd="$(bridge_agent_launch_cmd_raw "$agent" 2>/dev/null || true)"
  before_channels="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"

  if [[ -n "$deny_reason" ]]; then
    bridge_agent_update_emit_audit \
      "agent-delete-deny" \
      "$actor_label" \
      "$caller_source" \
      "$agent" \
      "$roster_path" \
      "$before_sha" \
      "" \
      "delete" \
      "$deny_reason" \
      "$before_launch_cmd" \
      "" \
      "$before_channels" \
      "" \
      "[]"
    bridge_die "deny: $deny_reason"
  fi

  if [[ $dry_run -eq 1 ]]; then
    bridge_agent_update_emit_audit \
      "agent-delete-dry-run" \
      "$actor_label" \
      "$caller_source" \
      "$agent" \
      "$roster_path" \
      "$before_sha" \
      "$before_sha" \
      "delete" \
      "" \
      "$before_launch_cmd" \
      "" \
      "$before_channels" \
      "" \
      "[]"

    if [[ $json_output -eq 1 ]]; then
      bridge_require_python
      # Footgun #11: invoke the JSON formatter via file-as-argv (not
      # heredoc-stdin) so the dry-run path does not wedge Bash 5.3.9.
      AGENT="$agent" CALLER_SOURCE="$caller_source" OPEN_COUNT="$open_count" \
      ORPHAN_TASKS="$orphan_tasks" PURGE_HOME="$purge_home" PURGE_CRONS="$purge_crons" \
      DELETED=0 DRY_RUN=1 BEFORE_SHA="" AFTER_SHA="" \
        python3 "$SCRIPT_DIR/lib/agent-cli-helpers/delete-result-json.py"
    else
      printf 'agent: %s\n' "$agent"
      printf 'deleted: no\n'
      printf 'dry_run: yes\n'
      printf 'open_inbox_tasks: %s\n' "$open_count"
      printf 'orphan_tasks: %s\n' "$([[ $orphan_tasks -eq 1 ]] && echo yes || echo no)"
      printf 'purge_home: %s\n' "$([[ $purge_home -eq 1 ]] && echo yes || echo no)"
      printf 'purge_crons: %s\n' "$([[ $purge_crons -eq 1 ]] && echo yes || echo no)"
    fi
    return 0
  fi

  # Side effects, in order: orphan tasks → remove roster block →
  # optional purges. Failures in optional purges are best-effort and
  # logged but do not roll back the roster mutation.

  if [[ $orphan_tasks -eq 1 && "$open_count" -gt 0 && -f "$BRIDGE_TASK_DB" ]]; then
    bridge_require_python
    local _orphan_err _orphan_note _orphan_helper
    _orphan_err="$(mktemp "${TMPDIR:-/tmp}/agb-orphan-err.XXXXXX")"
    # Completion note format (refs #4797): include agent name and the
    # operator-facing trigger so `agb task show <id>` after a ghost GC
    # surfaces *why* the row was closed without reading the audit log.
    _orphan_note="agent ${agent} deleted, task orphaned by --orphan-tasks"
    _orphan_helper="$SCRIPT_DIR/lib/agent-cli-helpers/orphan-tasks-gc.py"
    # Footgun #11: do NOT feed this body via `python3 - <<'PY' … PY`.
    # The previous implementation used a heredoc-stdin and deadlocked
    # Bash 5.3.9 `heredoc_write` the moment any caller exercised the
    # orphan-tasks branch, leaving every --orphan-tasks invocation hung
    # before the SQL ran. Standalone helper invoked file-as-argv keeps
    # the path off the broken surface (same precedent as
    # lib/upgrade-helpers/recorded-source-root.py and
    # lib/agent-cli-helpers/registry-format-json.py).
    if ! python3 "$_orphan_helper" "$BRIDGE_TASK_DB" "$agent" "$_orphan_note" 2>"$_orphan_err"; then
      local _orphan_err_text
      _orphan_err_text="$(cat "$_orphan_err" 2>/dev/null || true)"
      rm -f "$_orphan_err"
      bridge_die "agent delete: failed to cancel orphaned inbox tasks for '$agent'${_orphan_err_text:+ ($_orphan_err_text)}"
    fi
    rm -f "$_orphan_err"
  fi

  # Remove the managed-role block from the roster file. Same regex the
  # block writer in bridge_write_role_block uses, with re.sub("") to
  # excise instead of replace. Helper is invoked file-as-argv (not
  # heredoc-stdin) to dodge the Bash 5.3.9 `heredoc_write` deadlock
  # documented in KNOWN_ISSUES.md §26 (footgun #11). Same shape as
  # PR #940's registry/list/show extraction.
  bridge_require_python
  python3 "$SCRIPT_DIR/lib/agent-cli-helpers/roster-excise-block.py" \
    "$roster_path" "$agent" >/dev/null \
    || bridge_die "agent delete: failed to excise managed-role block for '$agent' from $roster_path"

  # Issue #4795: drop the daemon's auto-start backoff state file for this
  # agent so the daemon's next sync tick does not log a spurious
  # `auto-start backoff <agent>` warning for a roster-removed agent. The
  # daemon also sweeps orphan state defensively, but clearing it here
  # closes the race window between `agent delete` returning and the next
  # daemon tick. Best-effort: missing file or directory is silently ignored.
  if [[ -n "${BRIDGE_STATE_DIR:-}" ]]; then
    rm -f "$BRIDGE_STATE_DIR/daemon-autostart/$agent.env" 2>/dev/null || true
  fi

  # Issue #1010: reap the dedicated OS user + its named-user traversal
  # ACEs for an isolated (linux-user) agent. Unlike --purge-home (which
  # only removes home *files*), the orphan OS user and stale
  # `user:agent-bridge-<name>:--x` ACEs are a host-level leak that
  # accumulates on every isolated create/delete cycle — so this runs
  # unconditionally on the delete path, not behind a flag. The helper is
  # hard-gated (Linux only, exact `agent-bridge-<name>` name match) and
  # fully best-effort: every failure is reported via bridge_warn but
  # never aborts the delete (the roster mutation already succeeded).
  # Non-isolated / macOS / shared-mode agents have no dedicated OS user;
  # the helper skips silently for those.
  if command -v bridge_isolation_v2_reap_isolated_agent_account >/dev/null 2>&1 \
     && command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
     && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    local _delete_os_user
    _delete_os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
    bridge_isolation_v2_reap_isolated_agent_account "$agent" "$_delete_os_user"

    # Beta20 L2 Variant 3A — stale-extra-gid cleanup. The deleted agent's
    # per-agent group has been reaped, but the running daemon's
    # supplementary set still contains the now-stale GID. Refresh so
    # subsequent agent-create on a same-named slot reads a clean group
    # set; non-critical for the add-side bug but tidies the symptom for
    # heavy churn workflows.
    if command -v bridge_daemon_refresh_after_group_membership_change >/dev/null 2>&1 \
       && command -v bridge_isolation_v2_agent_group_name >/dev/null 2>&1; then
      local _v2_grp_for_delete_refresh
      _v2_grp_for_delete_refresh="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || true)"
      if [[ -n "$_v2_grp_for_delete_refresh" ]]; then
        bridge_daemon_refresh_after_group_membership_change \
          --group "$_v2_grp_for_delete_refresh" \
          --reason "agent-delete:$agent" \
          >/dev/null 2>&1 || true
      fi
    fi
  fi

  if [[ $purge_crons -eq 1 ]]; then
    # Best-effort: list native crons for this agent and delete each.
    # Failures are non-fatal — the roster block is already gone and
    # operators can retry the purge.
    bridge_require_python
    BRIDGE_BASH_BIN="$BRIDGE_BASH_BIN" SCRIPT_DIR="$SCRIPT_DIR" \
    python3 - "$agent" <<'PY' || \
      bridge_warn "agent delete: cron purge encountered errors for '$agent' (best-effort)"
import json
import os
import subprocess
import sys

agent = sys.argv[1]
bash_bin = os.environ.get("BRIDGE_BASH_BIN", "bash")
script_dir = os.environ["SCRIPT_DIR"]
cron_sh = os.path.join(script_dir, "bridge-cron.sh")

list_proc = subprocess.run(
    [bash_bin, cron_sh, "list", "--agent", agent, "--json"],
    capture_output=True,
    text=True,
)
if list_proc.returncode != 0:
    sys.exit(0)
try:
    data = json.loads(list_proc.stdout or "{}")
except json.JSONDecodeError:
    sys.exit(0)
for job in data.get("jobs", []) or []:
    if job.get("agent") != agent:
        continue
    job_id = job.get("id")
    if not job_id:
        continue
    subprocess.run(
        [bash_bin, cron_sh, "delete", str(job_id)],
        check=False,
    )
PY
  fi

  if [[ $purge_home -eq 1 ]]; then
    # Resolve via the canonical helper so v1 (`$BRIDGE_AGENT_HOME_ROOT/$agent`)
    # and v2 (`$BRIDGE_AGENT_ROOT_V2/$agent/home`) layouts both work.
    local home_dir
    home_dir="$(bridge_agent_default_home "$agent")"
    # Validate the resolved path is under one of the known agent roots
    # before recursive rm — anything outside is a resolver bug, refuse
    # rather than rm. Roster mutation has already succeeded, so an rm
    # failure is best-effort: warn but do not abort the subcommand.
    case "$home_dir" in
      "$BRIDGE_AGENT_HOME_ROOT"/*|"${BRIDGE_AGENT_ROOT_V2:-/dev/null}"/*)
        if [[ -d "$home_dir" ]]; then
          if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
            bridge_linux_sudo_root rm -rf -- "$home_dir" || \
              bridge_warn "agent delete: --purge-home best-effort rm failed: $home_dir"
          else
            rm -rf -- "$home_dir" || \
              bridge_warn "agent delete: --purge-home best-effort rm failed: $home_dir"
          fi
        fi
        ;;
      *)
        bridge_warn "agent delete: --purge-home refused: resolved home outside expected agent roots: $home_dir"
        ;;
    esac

    # Issue #1076: on a v2 install, `bridge_agent_default_home` resolves
    # to `$BRIDGE_AGENT_ROOT_V2/<agent>/home` — ONE of the two children of
    # the per-agent root. The sibling `workdir/` and the per-agent root
    # itself are NOT covered above and accumulate root-owned residue from
    # a prior isolated create that aborted mid-flow. Without this purge
    # the next `agent create <same-name>` re-hits the same PermissionError
    # the issue documents (`agents/<a>/.claude` mkdir fails because the
    # parent is root-owned 2750). Use the layout accessor when available
    # so the path source is consistent with the create flow.
    if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
      local v2_agent_root="$BRIDGE_AGENT_ROOT_V2/$agent"
      if [[ -d "$v2_agent_root" ]]; then
        # Sibling workdir under the per-agent root.
        local v2_workdir="$v2_agent_root/workdir"
        if [[ -d "$v2_workdir" ]]; then
          if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
            bridge_linux_sudo_root rm -rf -- "$v2_workdir" || \
              bridge_warn "agent delete: --purge-home best-effort rm failed: $v2_workdir"
          else
            rm -rf -- "$v2_workdir" || \
              bridge_warn "agent delete: --purge-home best-effort rm failed: $v2_workdir"
          fi
        fi
        # The per-agent root parent — root-owned 2750 on isolated installs.
        # Rm it last so its children are gone first. Use sudo when the
        # controller cannot rm directly (isolated parent ownership).
        if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
          bridge_linux_sudo_root rm -rf -- "$v2_agent_root" || \
            bridge_warn "agent delete: --purge-home best-effort rm failed: $v2_agent_root"
        else
          rm -rf -- "$v2_agent_root" || \
            bridge_warn "agent delete: --purge-home best-effort rm failed: $v2_agent_root"
        fi
      fi
    fi

    # Issue #1076: the tracked-profile-source location
    # (`$BRIDGE_HOME/agents/<a>/`, via bridge_layout_profile_source_dir)
    # also accumulates residue — managed agents that go through the v2
    # shared-settings render path materialize `agents/<a>/.claude/` even
    # though their canonical home is under the v2 root, and the legacy
    # layout uses this exact dir as the home tree. Purge it too so a
    # subsequent create starts clean. Validate the path resolves under
    # $BRIDGE_AGENT_HOME_ROOT (= $BRIDGE_HOME/agents on a standard
    # install) before rm so we never escape the agent roots.
    local profile_src=""
    if declare -F bridge_layout_profile_source_dir >/dev/null 2>&1; then
      profile_src="$(bridge_layout_profile_source_dir "$agent" 2>/dev/null || printf '')"
    elif [[ -n "${BRIDGE_AGENT_HOME_ROOT:-}" ]]; then
      profile_src="$BRIDGE_AGENT_HOME_ROOT/$agent"
    fi
    if [[ -n "$profile_src" ]] && [[ -d "$profile_src" ]]; then
      case "$profile_src" in
        "${BRIDGE_AGENT_HOME_ROOT:-/dev/null}"/*)
          if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
            bridge_linux_sudo_root rm -rf -- "$profile_src" || \
              bridge_warn "agent delete: --purge-home best-effort rm failed: $profile_src"
          else
            rm -rf -- "$profile_src" || \
              bridge_warn "agent delete: --purge-home best-effort rm failed: $profile_src"
          fi
          ;;
        *)
          bridge_warn "agent delete: --purge-home refused tracked-profile residue outside BRIDGE_AGENT_HOME_ROOT: $profile_src"
          ;;
      esac
    fi

    # Issue #737 Q6: also cover the isolated agent's actual Linux home
    # (`/home/agent-bridge-<agent>/`). `bridge_agent_default_home` only
    # resolves the agents/<agent>/home tree; under linux-user isolation
    # the agent runs as `agent-bridge-<agent>` whose real OS home is a
    # separate path on disk and would otherwise leak after delete.
    #
    # Discovery rules (defensive):
    #  - Must be a linux-user-isolated agent (effective, not just
    #    requested) so we never run sudo+rm on hosts where the agent is
    #    actually shared-mode.
    #  - Resolve the OS user from the roster, then read its home from
    #    `getent passwd` (never hardcode — operator may have customized
    #    the home root).
    #  - Refuse anything that doesn't match `^/home/agent-bridge-<slug>$`.
    #    This blocks operator home, /, /root, /tmp, /var/lib/..., etc.,
    #    even if a misconfigured passwd entry pointed there.
    #  - Use bridge_linux_sudo_root because the tree is owned by the
    #    isolated UID (and dotfiles inside it are often root-owned via
    #    upgrade-time fixups), so the controller alone cannot rm it.
    #  - Failures warn-only; the agent is already removed from the
    #    roster, so an unreachable home is operator-followup, not a
    #    fail-loud condition.
    #
    # Out of scope (separate follow-up): `userdel` of the Linux account.
    # `--purge-home` cleans home files only; account removal is a
    # distinct destructive action that deserves its own opt-in flag.
    if command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
       && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
      local agent_user linux_home
      agent_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
      if [[ -n "$agent_user" ]] && getent passwd "$agent_user" >/dev/null 2>&1; then
        linux_home="$(getent passwd "$agent_user" | cut -d: -f6)"
        if [[ -n "$linux_home" && "$linux_home" =~ ^/home/agent-bridge-[a-zA-Z0-9_-]+$ ]]; then
          if [[ -d "$linux_home" ]]; then
            bridge_warn "agent delete: --purge-home also removing isolated Linux home: $linux_home"
            bridge_linux_sudo_root rm -rf -- "$linux_home" || \
              bridge_warn "agent delete: --purge-home best-effort Linux home rm failed: $linux_home (operator manual cleanup may be required)"
          fi
        elif [[ -n "$linux_home" ]]; then
          bridge_warn "agent delete: --purge-home refused isolated Linux home (does not match /home/agent-bridge-* guard): $linux_home"
        fi
      fi
    fi
  fi

  local after_sha
  after_sha="$(bridge_agent_update_file_sha256 "$roster_path")"

  bridge_agent_update_emit_audit \
    "agent-delete" \
    "$actor_label" \
    "$caller_source" \
    "$agent" \
    "$roster_path" \
    "$before_sha" \
    "$after_sha" \
    "delete" \
    "" \
    "$before_launch_cmd" \
    "" \
    "$before_channels" \
    "" \
    "[]"

  if [[ $json_output -eq 1 ]]; then
    bridge_require_python
    # Footgun #11: invoke the JSON formatter via file-as-argv (not
    # heredoc-stdin) so the apply path does not wedge Bash 5.3.9.
    AGENT="$agent" CALLER_SOURCE="$caller_source" OPEN_COUNT="$open_count" \
    ORPHAN_TASKS="$orphan_tasks" PURGE_HOME="$purge_home" PURGE_CRONS="$purge_crons" \
    DELETED=1 DRY_RUN=0 BEFORE_SHA="$before_sha" AFTER_SHA="$after_sha" \
      python3 "$SCRIPT_DIR/lib/agent-cli-helpers/delete-result-json.py"
  else
    printf 'agent: %s\n' "$agent"
    printf 'deleted: yes\n'
    printf 'dry_run: no\n'
    printf 'before_sha: %s\n' "$before_sha"
    printf 'after_sha: %s\n' "$after_sha"
    printf 'open_inbox_tasks: %s\n' "$open_count"
    printf 'orphan_tasks: %s\n' "$([[ $orphan_tasks -eq 1 ]] && echo yes || echo no)"
    printf 'purge_home: %s\n' "$([[ $purge_home -eq 1 ]] && echo yes || echo no)"
    printf 'purge_crons: %s\n' "$([[ $purge_crons -eq 1 ]] && echo yes || echo no)"
  fi
}

# run_retire — Issue #598 Track 3 cleanup primitive.
#
# Companion to `agent delete` (#580 Track 1). Where `delete` mutates the
# local roster (managed-role removal + optional purges) and is admin-gated,
# `retire` operates purely on RUNTIME artifacts of agents that are NOT in
# the static roster: dynamic-registered agents and orphan home dirs left
# behind by reaped/test-fixture sessions. It never touches the roster
# file, so it does not require operator-tui trust — but it always emits
# an audit row so the action is visible.
#
# Default behavior quarantines the home dir to
# `$BRIDGE_HOME/archive/retired-agents/<timestamp>-<agent>/`. Pass
# `--purge-home` to delete instead.
#
# Refusal cases (per #598 spec Part C):
#   1. Not in registry AND no on-disk home  → nothing to retire.
#   2. privilege_class=system OR agent_source=static → static-roster
#      mutation is #580 Track 2 territory.
#   3. is_alive=true → operator must `agent stop <agent>` first.
#   4. resolved home outside $BRIDGE_AGENT_HOME_ROOT → resolver bug;
#      refuse rather than rm/mv.
run_retire() {
  local agent=""
  local from_agent=""
  local purge_home=0
  local dry_run=0
  local json_output=0
  local reason="manual"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        from_agent="$2"
        shift 2
        ;;
      --purge-home)
        purge_home=1
        shift
        ;;
      --reason)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        reason="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --json)
        json_output=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        bridge_die "지원하지 않는 agent retire 옵션입니다: $1"
        ;;
      *)
        if [[ -z "$agent" ]]; then
          agent="$1"
          shift
        else
          bridge_die "agent retire: 추가 위치 인자는 허용되지 않습니다: $1"
        fi
        ;;
    esac
  done

  [[ -n "$agent" ]] || bridge_die "agent retire: <name> 인자가 필요합니다."

  # Caller label for audit (informational only — no admin gate).
  local caller_agent=""
  if [[ -n "$from_agent" ]]; then
    caller_agent="$from_agent"
  elif [[ -n "${BRIDGE_AGENT_ID:-}" ]]; then
    caller_agent="$BRIDGE_AGENT_ID"
  else
    caller_agent="operator"
  fi

  # Step 1: source resolution.
  # - "dynamic": agent is in BRIDGE_AGENT_IDS via dynamic loader.
  # - "static": agent is in BRIDGE_AGENT_IDS via static roster — refuse.
  # - "unregistered": not in registry, but a home dir exists on disk
  #   (the orphan-agent-dir case from #598 Track 2).
  local agent_source=""
  local privilege_class=""
  local home_dir=""
  local is_alive="0"

  if bridge_agent_exists "$agent"; then
    agent_source="$(bridge_agent_source "$agent")"
    privilege_class="$(bridge_agent_class "$agent")"
    home_dir="$(bridge_agent_default_home "$agent")"
    if bridge_agent_is_active "$agent"; then
      is_alive="1"
    fi
  else
    # Not in registry — fall back to the v1 home root layout (orphan
    # detector enumerates `$BRIDGE_AGENT_HOME_ROOT/*`, so any orphan we
    # could be asked to retire lives directly under that root).
    agent_source="unregistered"
    privilege_class="user"
    home_dir="$BRIDGE_AGENT_HOME_ROOT/$agent"
  fi

  # Step 2: refuse if neither registry nor disk has anything to retire.
  if [[ "$agent_source" == "unregistered" && ! -d "$home_dir" ]]; then
    bridge_die "deny: agent '$agent' is not in the registry and no home dir exists at $home_dir — nothing to retire"
  fi

  # Step 3: refuse static-class. Static roster mutation is #580 Track 2
  # territory; retire is for dynamic + orphan only.
  if [[ "$agent_source" == "static" ]]; then
    bridge_die "deny: agent '$agent' is static-roster — use \`agent-bridge agent delete '$agent'\` (admin-gated) instead"
  fi
  # privilege_class=system is also out-of-scope for retire (issue #539).
  if [[ "$privilege_class" == "system" ]]; then
    bridge_die "deny: agent '$agent' has privilege_class=system — system agents are not retireable"
  fi

  # Step 4: refuse if alive — operator must stop the session first.
  if [[ "$is_alive" == "1" ]]; then
    bridge_die "deny: agent '$agent' has an active tmux session — run \`agent-bridge agent stop '$agent'\` first"
  fi

  # Step 5: --purge-home path validation. Resolved home must live under
  # one of the known agent roots; anything else is a resolver bug, refuse.
  case "$home_dir" in
    "$BRIDGE_AGENT_HOME_ROOT"/*|"${BRIDGE_AGENT_ROOT_V2:-/dev/null}"/*) ;;
    *)
      bridge_die "deny: agent retire refused — resolved home is outside expected agent roots: $home_dir"
      ;;
  esac

  # Compute pre-state for audit + JSON (best-effort; the home dir may not
  # exist yet for a registry-only agent that was reaped before its home
  # was scaffolded).
  local pre_size_bytes="0"
  if [[ -d "$home_dir" ]]; then
    pre_size_bytes="$(du -sk -- "$home_dir" 2>/dev/null | awk '{print $1*1024}')"
    [[ "$pre_size_bytes" =~ ^[0-9]+$ ]] || pre_size_bytes="0"
  fi

  # Quarantine target lives under $BRIDGE_HOME/archive/retired-agents/.
  # Stamped with UTC timestamp to avoid collisions when the same agent id
  # is retired more than once across a host's lifetime.
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)"
  local archive_root="$BRIDGE_HOME/archive/retired-agents"
  local quarantine_path="$archive_root/${stamp}-${agent}"

  # Step 6: dry-run prints the plan and exits.
  if [[ $dry_run -eq 1 ]]; then
    if [[ $json_output -eq 1 ]]; then
      bridge_require_python
      AGENT="$agent" PURGE_HOME="$purge_home" QUARANTINE="$quarantine_path" \
      python3 - <<'PY'
import json
import os

payload = {
    "status": "would-retire",
    "agent": os.environ["AGENT"],
    "purged_home": os.environ["PURGE_HOME"] == "1",
    "quarantined_to": None if os.environ["PURGE_HOME"] == "1" else os.environ["QUARANTINE"],
    "audit_recorded": False,
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
    else
      printf 'agent: %s\n' "$agent"
      printf 'status: would-retire\n'
      printf 'agent_source: %s\n' "$agent_source"
      printf 'home_path: %s\n' "$home_dir"
      printf 'pre_size_bytes: %s\n' "$pre_size_bytes"
      if [[ $purge_home -eq 1 ]]; then
        printf 'plan: rm -rf %s\n' "$home_dir"
      else
        printf 'plan: mv %s -> %s\n' "$home_dir" "$quarantine_path"
      fi
    fi
    return 0
  fi

  # Step 7 (dynamic only): archive state + remove dynamic-active env file
  # + clear runtime markers. Best-effort; failures are warned but do not
  # abort the home-dir step.
  if [[ "$agent_source" == "dynamic" ]]; then
    bridge_archive_dynamic_agent "$agent" >/dev/null 2>&1 || \
      bridge_warn "agent retire: failed to archive dynamic state for '$agent' (best-effort)"
    bridge_remove_dynamic_agent_file "$agent" >/dev/null 2>&1 || \
      bridge_warn "agent retire: failed to remove dynamic active-env file for '$agent' (best-effort)"
    bridge_agent_clear_idle_marker "$agent" >/dev/null 2>&1 || true
    bridge_agent_clear_prompt_ready "$agent" >/dev/null 2>&1 || true
  fi

  # Issue #4795: clear daemon auto-start backoff state file so the daemon
  # does not emit `auto-start backoff <agent>` after retire. Mirrors the
  # cleanup in run_delete; covers the case where a retired static-class
  # entry left a backoff state row behind.
  if [[ -n "${BRIDGE_STATE_DIR:-}" ]]; then
    rm -f "$BRIDGE_STATE_DIR/daemon-autostart/$agent.env" 2>/dev/null || true
  fi

  # Step 8: quarantine OR purge the home dir.
  # Only escalate via bridge_linux_sudo_root when the agent was actually
  # under linux-user isolation — otherwise sudo prompts (macOS) or fails
  # closed (Linux without cached creds) for no reason. The fallback is a
  # plain rm/mv as the controller user.
  local needs_sudo=0
  if [[ "$agent_source" == "dynamic" ]] && \
     command -v bridge_agent_linux_user_isolation_requested >/dev/null 2>&1; then
    if bridge_agent_linux_user_isolation_requested "$agent" 2>/dev/null; then
      needs_sudo=1
    fi
  fi
  local final_quarantine_path=""
  if [[ -d "$home_dir" ]]; then
    if [[ $purge_home -eq 1 ]]; then
      if (( needs_sudo == 1 )); then
        bridge_linux_sudo_root rm -rf -- "$home_dir" || \
          bridge_warn "agent retire: --purge-home best-effort rm failed: $home_dir"
      else
        rm -rf -- "$home_dir" || \
          bridge_warn "agent retire: --purge-home best-effort rm failed: $home_dir"
      fi
    else
      mkdir -p "$archive_root"
      if (( needs_sudo == 1 )); then
        bridge_linux_sudo_root mv -- "$home_dir" "$quarantine_path" && \
          final_quarantine_path="$quarantine_path" || \
          bridge_warn "agent retire: quarantine mv failed for $home_dir → $quarantine_path"
      else
        if mv -- "$home_dir" "$quarantine_path" 2>/dev/null; then
          final_quarantine_path="$quarantine_path"
        else
          bridge_warn "agent retire: quarantine mv failed for $home_dir → $quarantine_path"
        fi
      fi
    fi
  fi

  # Step 9: audit row.
  local audit_quarantine="${final_quarantine_path:-}"
  bridge_audit_log agent agent_retired "$agent" \
    --detail reason="$reason" \
    --detail purge_home="$([[ $purge_home -eq 1 ]] && printf true || printf false)" \
    --detail pre_size_bytes="$pre_size_bytes" \
    --detail home_path="$home_dir" \
    --detail quarantine_path="$audit_quarantine" \
    --detail agent_source="$agent_source" \
    --detail privilege_class="$privilege_class" \
    --detail caller="$caller_agent" \
    2>/dev/null || true

  if [[ $json_output -eq 1 ]]; then
    bridge_require_python
    AGENT="$agent" PURGE_HOME="$purge_home" QUARANTINE="$audit_quarantine" \
    python3 - <<'PY'
import json
import os

quarantined = os.environ["QUARANTINE"]
payload = {
    "status": "retired",
    "agent": os.environ["AGENT"],
    "purged_home": os.environ["PURGE_HOME"] == "1",
    "quarantined_to": quarantined if quarantined else None,
    "audit_recorded": True,
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  else
    printf 'agent: %s\n' "$agent"
    printf 'status: retired\n'
    printf 'purge_home: %s\n' "$([[ $purge_home -eq 1 ]] && echo yes || echo no)"
    if [[ -n "$audit_quarantine" ]]; then
      printf 'quarantined_to: %s\n' "$audit_quarantine"
    fi
    printf 'audit_recorded: yes\n'
  fi
}

run_start() {
  local agent="${1:-}"
  # Issue #1114 (codex r1 follow-up): -h/--help in the agent slot
  # prints usage instead of being passed to bridge_require_agent
  # (which dies with a roster mismatch). Restricted to the dashed
  # forms — bare `help` could be a legitimate agent id.
  case "$agent" in
    -h|--help)
      cat <<'AGENT_START_HELP'
Usage: agent-bridge agent start <agent> [bridge-start.sh forwards...]

Start (or re-attach to) a static or dynamic agent session. Extra
options after <agent> are forwarded verbatim to bridge-start.sh.
AGENT_START_HELP
      return 0
      ;;
  esac
  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") start <agent> [...]"
  bridge_require_agent "$agent"
  exec "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" "$@"
}

run_safe_mode() {
  local agent="${1:-}"
  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") safe-mode <agent> [...]"
  bridge_require_agent "$agent"
  exec "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --safe-mode "$@"
}

run_stop() {
  local agent="${1:-}"
  local session=""

  # Issue #1114 (codex r1 follow-up): -h/--help in the agent slot
  # prints usage instead of being passed to bridge_require_agent
  # (which dies with a roster mismatch). Restricted to the dashed
  # forms — bare `help` could be a legitimate agent id.
  case "$agent" in
    -h|--help)
      cat <<'AGENT_STOP_HELP'
Usage: agent-bridge agent stop <agent>

Stop the live tmux session for <agent>. No-op if the session is
already absent.
AGENT_STOP_HELP
      return 0
      ;;
  esac

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") stop <agent>"
  [[ $# -eq 0 ]] || bridge_die "지원하지 않는 agent stop 옵션입니다: $1"
  bridge_require_agent "$agent"
  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || bridge_die "세션 이름이 없습니다: $agent"
  if ! bridge_tmux_session_exists "$session"; then
    printf '[info] 에이전트 "%s" 세션이 이미 중지된 상태입니다.\n' "$agent"
    return 0
  fi
  bridge_manual_stop_agent_session "$agent"
  bridge_refresh_runtime_state
  printf 'stopped: %s\n' "$agent"
}

run_restart() {
  local agent="${1:-}"
  local session=""
  local start_args=()
  local attach_mode=0
  local dry_run_mode=0
  local engine=""
  local launch_channels=""
  local preflight_reason=""
  # Default raised from 12s to 30s: measured teams-plugin cold-start on a
  # healthy host is ~14s, 12s lost the race deterministically (issue #69
  # Defect B). Operators can still override via the env var.
  local verify_timeout="${BRIDGE_AGENT_RESTART_CHANNEL_VERIFY_SECONDS:-30}"
  # Kill-on-repeated-fail threshold: how many consecutive banner-verify
  # timeouts before we stop the session and let the daemon's cooldown retry
  # later. Previously hardcoded at 2, which combined with a too-short
  # timeout created a death loop (issue #69 Defect C). Default 5.
  local verify_max_attempts="${BRIDGE_AGENT_RESTART_CHANNEL_VERIFY_MAX_ATTEMPTS:-5}"
  local verify_attempts=0
  local os_user=""
  local current_user=""

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") restart <agent> [...]"
  bridge_require_agent "$agent"
  if [[ "${BRIDGE_AGENT_ID:-}" == "$agent" ]] \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    current_user="$(id -un 2>/dev/null || true)"
    if [[ -n "$os_user" && "$current_user" == "$os_user" ]]; then
      bridge_die "isolated agent '$agent' cannot restart itself from inside its linux-user session. Ask a controller/admin agent to run: agent-bridge agent restart $agent"
    fi
  fi
  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || bridge_die "세션 이름이 없습니다: $agent"
  engine="$(bridge_agent_engine "$agent")"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --attach)
        attach_mode=1
        start_args+=("$1")
        shift
        ;;
      --no-attach)
        attach_mode=0
        shift
        ;;
      --continue|--no-continue|--dry-run)
        if [[ "$1" == "--dry-run" ]]; then
          dry_run_mode=1
        fi
        start_args+=("$1")
        shift
        ;;
      *)
        bridge_die "지원하지 않는 agent restart 옵션입니다: $1"
        ;;
    esac
  done

  if [[ ! " ${start_args[*]} " =~ [[:space:]]--attach[[:space:]] ]] && [[ $attach_mode -eq 0 ]]; then
    :
  fi

  if [[ $dry_run_mode -eq 1 ]]; then
    exec "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --replace "${start_args[@]}"
  fi

  preflight_reason="$(bridge_agent_restart_preflight_reason "$agent")"
  if [[ -n "$preflight_reason" ]]; then
    bridge_die "$(bridge_agent_restart_preflight_guidance "$agent" "$preflight_reason")"
  fi

  # #256 Gap 2: clear the rapid-fail quarantine marker only after the
  # dry-run short-circuit (handled above) and the preflight guidance
  # check have both allowed the restart to proceed. An aborted restart
  # must not silently unquarantine the agent — the daemon would then
  # resume auto-starting it and recreate the crash loop before
  # `bridge-run.sh` had a chance to re-trip the circuit breaker.
  bridge_agent_clear_broken_launch "$agent" 2>/dev/null || true

  # #981: snapshot the resume session_id BEFORE the kill so an operator-
  # initiated restart resumes the previous conversation. The abrupt SIGKILL
  # interrupts Claude's transcript writer, after which the post-kill resolver
  # path (`bridge_normalize_agent_session_id` → `bridge_resolve_resume_session_id`)
  # could reject the persisted id and `bridge_clear_agent_session_id` would
  # wipe it. The kill itself doesn't touch the in-memory map, but the new
  # `bridge-start.sh` subprocess re-hydrates from disk and re-runs the
  # resolver gate. Snapshotting here and re-injecting after the kill puts the
  # id back on disk so the first restart attempt's launch builder finds a
  # non-empty `BRIDGE_AGENT_SESSION_ID[$agent]` and emits `--resume <id>`.
  # The existing quarantine / freshness logic still applies on subsequent
  # passes if the id is truly stale, so this is additive — not a bypass.
  local resume_session_snapshot=""
  resume_session_snapshot="$(bridge_agent_session_id "$agent" 2>/dev/null || true)"

  if bridge_tmux_session_exists "$session"; then
    bridge_kill_agent_session "$agent"
    bridge_refresh_runtime_state
    if [[ -n "$resume_session_snapshot" ]]; then
      bridge_set_agent_session_id "$agent" "$resume_session_snapshot" 2>/dev/null || true
    fi
  fi

  if [[ $attach_mode -eq 1 ]]; then
    exec "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --replace "${start_args[@]}"
  fi

  restart_once() {
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --replace "${start_args[@]}"
  }

  if ! restart_once; then
    return 1
  fi

  if [[ "$engine" != "claude" ]]; then
    return 0
  fi

  launch_channels="$(bridge_agent_effective_launch_plugin_channels_csv "$agent")"

  [[ "$verify_max_attempts" =~ ^[0-9]+$ ]] || verify_max_attempts=5
  (( verify_max_attempts >= 1 )) || verify_max_attempts=1

  # Emergency operator kill-switch for the restart-internal verifier.
  # Independent of the daemon-only BRIDGE_SKIP_PLUGIN_LIVENESS knob so
  # operators can leave daemon liveness on while bypassing this loop
  # during incident triage (issue #542).
  if [[ "${BRIDGE_SKIP_RESTART_PLUGIN_LIVENESS:-0}" == "1" ]]; then
    bridge_warn "BRIDGE_SKIP_RESTART_PLUGIN_LIVENESS=1; skipping restart-internal plugin MCP liveness verifier for '$agent'."
    return 0
  fi

  verify_attempts=1
  # Verify via descendant process probe (issue #143). The banner-based
  # verifier read only the last 80 tmux lines, so busy sessions (`--resume`
  # + `/compact` + first task dispatch) scrolled the startup banner off
  # within seconds and restart verify kept returning failure even when
  # every plugin bun was alive. Align with the daemon's steady-state
  # liveness check so the two signals no longer disagree.
  if bridge_tmux_wait_for_claude_plugin_mcp_alive "$agent" "$verify_timeout"; then
    return 0
  fi

  # Retry with fresh sessions up to verify_max_attempts total. Keep going
  # only while the session restarts cleanly. If we exhaust attempts without
  # the plugin MCP coming alive, leave the session running and return
  # non-zero so the daemon's next cooldown cycle can take another look.
  # Previously we killed the session after 2 attempts, which — combined
  # with the too-short 12s default timeout and reparented bun holding the
  # port — produced the observed permanent death loop (issue #69 Defect C).
  while (( verify_attempts < verify_max_attempts )); do
    verify_attempts=$(( verify_attempts + 1 ))
    bridge_warn "Claude plugin MCP liveness missing after restart for '$agent' (attempt ${verify_attempts}/${verify_max_attempts}). Retrying with a fresh session."
    if bridge_tmux_session_exists "$session"; then
      # #981: re-snapshot before each kill — the prior restart_once may have
      # advanced the session_id to a fresh transcript that we still want to
      # resume on the next attempt. See the comment above the first kill
      # block for the full rationale.
      bridge_load_roster >/dev/null 2>&1 || true
      resume_session_snapshot="$(bridge_agent_session_id "$agent" 2>/dev/null || true)"
      bridge_kill_agent_session "$agent" >/dev/null 2>&1 || true
      bridge_refresh_runtime_state
      if [[ -n "$resume_session_snapshot" ]]; then
        bridge_set_agent_session_id "$agent" "$resume_session_snapshot" 2>/dev/null || true
      fi
    fi
    if ! restart_once; then
      return 1
    fi
    if bridge_tmux_wait_for_claude_plugin_mcp_alive "$agent" "$verify_timeout"; then
      return 0
    fi
  done

  bridge_warn "Claude plugin MCP liveness still missing after ${verify_max_attempts} attempts for '$agent'. Leaving the session alive so the daemon's next cycle can re-check (avoids the plugin-port death loop from issue #69)."
  return 1
}

run_ack_crash() {
  local agent="${1:-}"

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") ack-crash <agent>"
  [[ $# -eq 0 ]] || bridge_die "지원하지 않는 agent ack-crash 옵션입니다: $1"
  bridge_require_agent "$agent"
  if bridge_agent_ack_crash_report "$agent"; then
    printf 'ack-crash: %s\n' "$agent"
  else
    bridge_die "ack-crash failed: no crash report or state available for '$agent'"
  fi
}

run_attach() {
  local agent="${1:-}"

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") attach <agent>"
  [[ $# -eq 0 ]] || bridge_die "지원하지 않는 agent attach 옵션입니다: $1"
  bridge_require_agent "$agent"
  exec "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/agent-bridge" attach "$agent"
}

# run_forget_session — clear the persisted Claude/Codex resume id for <agent>
# from every authoritative state file (history env, dynamic active env, and
# the linux-user agent-env.sh overlay when present), so the next normal
# restart launches without `--resume`. The running tmux session is NOT
# killed; an active agent must be restarted manually before the cleared id
# takes effect. Idempotent — running it twice on an already-empty id exits
# 0 with `changed=no`.
#
# This is the supported recovery path for issue #268 (stale Claude resume
# target). The companion warning in bridge-start.sh / bridge-run.sh tells an
# operator who used `--no-continue` that the persisted id is still there.
run_forget_session() {
  local agent="${1:-}"
  local active="no"
  local clear_output=""
  local prior_id_hash=""
  local changed=""
  local cleared_csv=""
  local token=""

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") forget-session <agent>"
  [[ $# -eq 0 ]] || bridge_die "지원하지 않는 agent forget-session 옵션입니다: $1"
  bridge_require_agent "$agent"

  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi

  # Issue 2 (v0.11.0): evaluate the resume-quarantine clear up front, BEFORE
  # the persisted-session early-return. Review #2040 finding 2: the operator
  # may legitimately have an empty persisted id (post-recovery) but a
  # non-empty `resume-quarantine.json` on disk; the prior implementation
  # gated the clear on `changed=yes` and silently left the quarantine in
  # place in that case.
  #
  # Safety rules unchanged: clear only when `active != yes` so a rapid-fail
  # loop in bridge-run.sh cannot reintroduce the quarantined id between the
  # operator's clear and the loop's next quarantine pass. The cleared flag
  # is reported on both the `changed=yes` and `changed=no` output paths so
  # the operator-facing semantics are honest about what was reset.
  local _quarantine_cleared="no"
  local _quarantine_file=""
  _quarantine_file="$(bridge_agent_resume_quarantine_file "$agent" 2>/dev/null || true)"
  if [[ "$active" != "yes" && -n "$_quarantine_file" && -f "$_quarantine_file" ]]; then
    bridge_agent_resume_quarantine_clear "$agent" 2>/dev/null || true
    _quarantine_cleared="yes"
  fi

  # The lock + read-modify-write happens inside bridge_clear_persisted_session_id.
  # When two callers race, only the holder that observes a non-empty prior id
  # comes back with `changed=yes`; the others see `changed=no` and we record
  # a separate `already_forgotten` audit row for them.
  clear_output="$(bridge_clear_persisted_session_id "$agent")"
  for token in $clear_output; do
    case "$token" in
      prior_id_hash=*) prior_id_hash="${token#prior_id_hash=}" ;;
      changed=*)       changed="${token#changed=}" ;;
      cleared_files=*) cleared_csv="${token#cleared_files=}" ;;
    esac
  done
  changed="${changed:-no}"

  if [[ "$changed" != "yes" ]]; then
    bridge_audit_log daemon agent_session_forgotten "$agent" \
      --detail cleared_files= \
      --detail prior_id_hash= \
      --detail active="$active" \
      --detail changed=no \
      --detail resume_quarantine_cleared="$_quarantine_cleared" \
      --detail reason=already_forgotten >/dev/null 2>&1 || true
    printf 'agent: %s\n' "$agent"
    printf 'changed: no\n'
    printf 'reason: already_forgotten\n'
    printf 'active: %s\n' "$active"
    printf 'resume_quarantine_cleared: %s\n' "$_quarantine_cleared"
    if [[ "$active" == "yes" && -n "$_quarantine_file" && -f "$_quarantine_file" ]]; then
      bridge_warn "active=yes — resume-quarantine left intact; run forget-session again after 'agent stop $agent' for a clean slate"
    fi
    return 0
  fi

  bridge_audit_log daemon agent_session_forgotten "$agent" \
    --detail cleared_files="$cleared_csv" \
    --detail prior_id_hash="$prior_id_hash" \
    --detail active="$active" \
    --detail resume_quarantine_cleared="$_quarantine_cleared" \
    --detail changed=yes >/dev/null 2>&1 || true

  printf 'agent: %s\n' "$agent"
  printf 'changed: yes\n'
  printf 'cleared_files: %s\n' "${cleared_csv:--}"
  printf 'prior_id_hash: %s\n' "${prior_id_hash:--}"
  printf 'active: %s\n' "$active"
  printf 'resume_quarantine_cleared: %s\n' "$_quarantine_cleared"
  if [[ "$active" == "yes" ]]; then
    bridge_warn "active=yes — running tmux session must be restarted fresh to pick up cleared id; suggested next: bridge-agent.sh restart $agent --no-continue"
    if [[ -n "$_quarantine_file" && -f "$_quarantine_file" ]]; then
      bridge_warn "active=yes — resume-quarantine left intact; run forget-session again after 'agent stop $agent' for a clean slate"
    fi
  fi
}

# bridge_admin_maintenance_dispatch — issue #304 Track B common path.
#
# Both `agent compact` and `agent handoff` are admin-driven autonomous
# maintenance primitives for *static* agents. The shape is identical:
#
#   1. Resolve target via the roster; reject if dynamic (defense in depth
#      for the role-spec rule in agents/_template/CLAUDE.md
#      "Admin Static vs Dynamic Agent Boundary"). Dynamic agents are
#      operator-managed in the TUI and these primitives must not nudge
#      them — same contract the daemon's [context-pressure] body now
#      states machine-readably.
#   2. Create a synthetic queue task to the static agent's inbox via
#      bridge-task.sh create. The agent processes it on its own — no
#      end-user keystroke required, which is the static-agent contract
#      the issue identifies as the missing primitive.
#   3. Audit row (admin_compact_invoked / admin_handoff_invoked).
#
# We deliberately do NOT synchronously block on agent claim+done or
# drive a tmux send-keys session reset here. The CLI returns once the
# task is enqueued + audited. The follow-up reset (if any) is the
# operator's call after the agent has had a chance to process — keeps
# the primitive cheap and avoids the lib/bridge-tmux.sh busy-gate +
# 10-minute-timeout coupling the brief flagged as future work.
bridge_admin_maintenance_dispatch() {
  local kind="$1"        # compact | handoff
  local agent="$2"
  local note="${3:-}"
  local title=""
  local body=""
  local audit_action=""
  local actor=""
  local stamp=""
  local task_label=""

  bridge_require_agent "$agent"
  if [[ "$(bridge_agent_source "$agent")" != "static" ]]; then
    bridge_die "agent '$agent' is dynamic — operator-managed; refuse to ${kind}. Dynamic agents are managed by the developer at the TUI; admin maintenance primitives only apply to static agents."
  fi

  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  case "$kind" in
    compact)
      task_label="admin-compact"
      title="[admin-compact] $stamp"
      body="Operator-driven context compaction (issue #304 Track B).
Save your work, write a NEXT-SESSION.md handoff per the bridge contract
(<agent-home>/NEXT-SESSION.md, the file SessionStart hook auto-consumes),
and stop at a safe boundary. The bridge will resume the session fresh.
End-user contact is not required and must not be requested."
      audit_action="admin_compact_invoked"
      ;;
    handoff)
      task_label="admin-handoff"
      title="[admin-handoff] $stamp"
      body="Operator-driven session handoff (issue #304 Track B).
Write a structured handoff to <agent-home>/NEXT-SESSION.md — the only
filename SessionStart hook auto-consumes (see
docs/agent-runtime/handoff-protocol.md). Include open queue items,
blockers, current focus, and the last known good state. End-user
contact is not required and must not be requested."
      audit_action="admin_handoff_invoked"
      ;;
    *)
      bridge_die "internal: unknown maintenance kind '$kind'"
      ;;
  esac

  if [[ -n "$note" ]]; then
    body="$body

Operator note: $note"
  fi

  actor="$(bridge_admin_agent_id)"
  [[ -n "$actor" ]] || actor="bridge-admin"

  "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-task.sh" create \
    --to "$agent" \
    --from "$actor" \
    --priority high \
    --title "$title" \
    --body "$body" >/dev/null

  bridge_audit_log "$actor" "$audit_action" "$agent" \
    --detail via=bridge-primitive \
    --detail label="$task_label" \
    --detail stamp="$stamp" >/dev/null 2>&1 || true

  # Issue #304 r2 (codex review): handoff requires post-completion verification
  # of <agent-home>/NEXT-SESSION.md. We don't synchronously block here (fire-
  # and-forget is intentional — keeps the primitive cheap), but we DO enqueue
  # a follow-up verify task to admin's own inbox so the check is observable
  # rather than silent. Admin processes it after the static agent has had time
  # to write the handoff; if the file is missing the admin emits an
  # `admin_handoff_failed` audit row + re-dispatches with a different note.
  if [[ "$kind" == "handoff" ]]; then
    local agent_home=""
    agent_home="$(bridge_agent_home "$agent" 2>/dev/null || true)"
    local verify_title="[admin-handoff-verify] $stamp"
    local verify_body="Verify the static-agent handoff for '$agent'.
Expected file: ${agent_home:-<agent-home>}/NEXT-SESSION.md (the only path
SessionStart hook auto-consumes).
Pass criteria: file exists, non-empty, contains the structured handoff
fields (open queue items, blockers, current focus, last known good
state).
On pass: close this task with note 'verified: NEXT-SESSION.md ok'.
On fail (missing/empty/malformed): audit admin_handoff_failed and
re-dispatch \`agent-bridge agent handoff $agent --note 'handoff retry'\`
with the missing fields in the operator note. (#304 Track B verify path)"
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-task.sh" create \
      --to "$actor" \
      --from "$actor" \
      --priority normal \
      --title "$verify_title" \
      --body "$verify_body" >/dev/null 2>&1 || true
  fi

  printf 'agent: %s\n' "$agent"
  printf 'kind: %s\n' "$kind"
  printf 'task_title: %s\n' "$title"
  printf 'audit_action: %s\n' "$audit_action"
}

run_compact() {
  local agent="${1:-}"
  local note=""

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") compact <agent> [--note <text>]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note)
        [[ $# -lt 2 ]] && bridge_die "--note 뒤에 텍스트를 지정하세요."
        note="$2"
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        bridge_die "지원하지 않는 agent compact 옵션입니다: $1"
        ;;
    esac
  done

  bridge_admin_maintenance_dispatch compact "$agent" "$note"
}

run_handoff() {
  local agent="${1:-}"
  local note=""

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") handoff <agent> [--note <text>]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note)
        [[ $# -lt 2 ]] && bridge_die "--note 뒤에 텍스트를 지정하세요."
        note="$2"
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        bridge_die "지원하지 않는 agent handoff 옵션입니다: $1"
        ;;
    esac
  done

  bridge_admin_maintenance_dispatch handoff "$agent" "$note"
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  create)
    run_create "$@"
    ;;
  update)
    run_update "$@"
    ;;
  delete)
    run_delete "$@"
    ;;
  retire)
    run_retire "$@"
    ;;
  list)
    run_list "$@"
    ;;
  registry)
    run_registry "$@"
    ;;
  show)
    run_show "$@"
    ;;
  reclassify)
    run_reclassify "$@"
    ;;
  doctor)
    bridge_doctor_run "$@"
    ;;
  rerender-settings)
    run_rerender_settings "$@"
    ;;
  start)
    run_start "$@"
    ;;
  safe-mode)
    run_safe_mode "$@"
    ;;
  stop)
    run_stop "$@"
    ;;
  restart)
    run_restart "$@"
    ;;
  ack-crash)
    run_ack_crash "$@"
    ;;
  forget-session)
    run_forget_session "$@"
    ;;
  attach)
    run_attach "$@"
    ;;
  compact)
    run_compact "$@"
    ;;
  handoff)
    run_handoff "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    # Issue #163 Phase 2: surface an intent-recovery hint before dying.
    _hint="$(bridge_suggest_subcommand "$subcommand" \
      "create update delete retire list registry show reclassify doctor rerender-settings start safe-mode stop restart ack-crash forget-session attach compact handoff")"
    [[ -n "$_hint" ]] && bridge_warn "$_hint"
    bridge_die "지원하지 않는 agent 명령입니다: $subcommand"
    ;;
esac
