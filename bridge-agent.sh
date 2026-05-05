#!/usr/bin/env bash
# bridge-agent.sh — static role lifecycle helpers

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

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
  $(basename "$0") update <agent> [options]
  $(basename "$0") delete <agent> [--from <admin>] [--force] [--orphan-tasks] [--purge-home] [--purge-crons] [--dry-run] [--json]
  $(basename "$0") list [--json]
  $(basename "$0") registry [--json]
  $(basename "$0") show <agent> [--json]
  $(basename "$0") reclassify [--agent <agent>] [--apply] [--json]
  $(basename "$0") rerender-settings [<agent>...] [--apply|--dry-run] [--json]
  $(basename "$0") start <agent> [--attach|--no-attach] [--replace] [--continue|--no-continue] [--dry-run]
  $(basename "$0") safe-mode <agent> [--attach|--no-attach] [--replace] [--continue|--no-continue] [--dry-run]
  $(basename "$0") stop <agent>
  $(basename "$0") restart <agent> [--attach|--no-attach] [--continue|--no-continue] [--dry-run]
  $(basename "$0") forget-session <agent>
  $(basename "$0") attach <agent>
  $(basename "$0") compact <agent> [--note <text>]
  $(basename "$0") handoff <agent> [--note <text>]

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
  --json                               emit JSON envelope
  --dry-run                            do not mutate; emit planned diff

Options:
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
  --loop                       mark the role as loop-enabled
  --always-on                  configure IDLE_TIMEOUT=0 for this role
  --continue|--no-continue     explicit continue mode (default: continue)
  --dry-run                    print the planned role block without writing
  --json                       emit JSON instead of human text
  --test-fixture               opt into test-artifact name patterns
                               (smoke-/test-/bootstrap-/created-agent-/pref-,
                               *-repro-<N>); cleanup tooling may reap these

Examples:
  $(basename "$0") create reviewer --engine claude
  $(basename "$0") create coder --engine codex --session codex-main --always-on
  $(basename "$0") create ops --engine claude --channels plugin:discord@claude-plugins-official --discord-channel 123456789012345678 --json
  $(basename "$0") list --json
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
EOF
}

bridge_agent_manage_python() {
  bridge_require_python
  python3 - "$@"
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
      printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen'
      ;;
    *)
      bridge_die "지원하지 않는 engine 입니다: $engine"
      ;;
  esac
}

bridge_expand_user_path() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    printf '%s' ""
    return 0
  fi
  bridge_agent_manage_python "$raw" <<'PY'
from pathlib import Path
import sys

value = sys.argv[1]
print(str(Path(value).expanduser()))
PY
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
  local template_root="$SCRIPT_DIR/agents/_template"
  local session_template="$template_root/session-types/$session_type.md"
  local session_files_root="$template_root/session-type-files/$session_type"
  local file=""
  local rel=""
  local target=""

  mkdir -p "$home"
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
    "$replace_existing" <<'PY'
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
if continue_mode == "1":
    lines.append(f'BRIDGE_AGENT_CONTINUE["{agent}"]="1"')
else:
    lines.append(f'BRIDGE_AGENT_CONTINUE["{agent}"]="0"')
if always_on == "1":
    lines.append(f'BRIDGE_AGENT_IDLE_TIMEOUT["{agent}"]="0"')
if isolation_mode:
    # Emit the isolation mode verbatim (including "shared") so roster
    # round-trips preserve explicit configuration. Downstream tooling that
    # distinguishes "unset" from "shared" relies on this being present.
    lines.append(f'BRIDGE_AGENT_ISOLATION_MODE["{agent}"]={sq(isolation_mode)}')
if os_user:
    lines.append(f'BRIDGE_AGENT_OS_USER["{agent}"]={sq(os_user)}')
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
  if [[ -d "$path" ]]; then
    (cd -P "$path" && pwd -P)
  else
    printf '%s' "$path"
  fi
}

bridge_agent_has_static_admin_shape() {
  local agent="$1"
  local workdir=""
  local default_home=""
  local legacy_home=""
  local session_type=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 1
  session_type="$(bridge_agent_session_type_from_home "$agent" 2>/dev/null || true)"
  [[ "$session_type" == "admin" ]] || return 1

  workdir="$(bridge_agent_canonical_dir "$(bridge_expand_user_path "$(bridge_agent_workdir "$agent")")")"
  default_home="$(bridge_agent_canonical_dir "$(bridge_expand_user_path "$(bridge_agent_default_home "$agent")")")"
  legacy_home="$(bridge_agent_canonical_dir "$(bridge_expand_user_path "$BRIDGE_AGENT_HOME_ROOT/$agent")")"
  [[ -n "$workdir" && ( "$workdir" == "$default_home" || "$workdir" == "$legacy_home" ) ]] || return 1

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
  if [[ -z "${BRIDGE_ADMIN_AGENT_ID:-}" ]]; then
    bridge_roster_local_upsert_scalar "BRIDGE_ADMIN_AGENT_ID" "$agent"
    BRIDGE_ADMIN_AGENT_ID="$agent"
  fi
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

  bridge_agent_manage_python "$agent" "$engine" "$session" "$workdir" "$profile_home" "$launch_cmd" "$channels" "$roster_file" "$dry_run" "$users_json" "$session_type" "$isolation_mode" "$os_user" <<'PY'
import json
import sys

agent, engine, session, workdir, profile_home, launch_cmd, channels, roster_file, dry_run, users_json, session_type, isolation_mode, os_user = sys.argv[1:]
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
    "next_steps": [
        f"agent-bridge setup agent {agent}",
        f"agent-bridge status --all-agents",
        f"bash bridge-start.sh {agent} --dry-run",
    ],
}
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

  if ! bridge_agent_is_active "$agent"; then
    printf '%s' "stopped"
    return 0
  fi

  session="$(bridge_agent_session "$agent")"
  if bridge_tmux_session_has_prompt "$session" "$(bridge_agent_engine "$agent")"; then
    printf '%s' "idle"
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

  bridge_agent_manage_python "$mode" "$tsv" <<'PY'
import csv
import io
import json
import sys

mode = sys.argv[1]
rows = list(csv.DictReader(io.StringIO(sys.argv[2]), delimiter="\t"))
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
  bridge_agent_manage_python "$(emit_agent_records_json list "$output")" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
print("agent | eng | src | active | state | iso | q/c/b | wake | notify | chan | session | workdir")
for item in items:
    suffix = " [admin]" if item.get("admin") else ""
    isolation = item.get("isolation", {}) or {}
    mode = isolation.get("mode") or "shared"
    os_user = isolation.get("os_user") or ""
    iso_text = f"{mode}:{os_user}" if os_user else mode
    queue = item.get("queue", {}) or {}
    notify = item.get("notify", {}) or {}
    channels = item.get("channels", {}) or {}
    print(
        f"{item.get('agent','')}{suffix} | "
        f"{item.get('engine','')} | "
        f"{item.get('source','')} | "
        f"{'yes' if item.get('active') else 'no'} | "
        f"{item.get('activity_state','')} | "
        f"{iso_text} | "
        f"{queue.get('queued',0)}/{queue.get('claimed',0)}/{queue.get('blocked',0)} | "
        f"{item.get('wake_status','')} | "
        f"{notify.get('status','')} | "
        f"{channels.get('status','')} | "
        f"{item.get('session','')} | "
        f"{item.get('workdir','')}"
    )
PY
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

  bridge_agent_manage_python "$rows" <<'PY'
import json
import sys

raw = sys.argv[1] if len(sys.argv) > 1 else ""
records = []
for line in raw.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) < 10:
        continue
    (id_, cls, agent_source, privilege_class, home, workdir,
     engine, session, is_alive, source) = parts[:10]
    records.append({
        "id": id_,
        "class": cls,
        "agent_source": agent_source,
        "privilege_class": privilege_class,
        "home": home,
        "workdir": workdir,
        "engine": engine,
        "session": session,
        "is_alive": is_alive == "1",
        "source": source,
    })

records.sort(key=lambda r: r["id"])
print(json.dumps(records, ensure_ascii=False, indent=2))
PY
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
    bridge_agent_manage_python \
      "$(emit_agent_records_json show "$output")" \
      "$(bridge_agent_channel_diagnostics_json "$agent")" \
      "$(bridge_agent_session_health_json "$agent")" \
      "$(bridge_agent_session_source_path "$agent")" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
payload.setdefault("channels", {})["diagnostics"] = json.loads(sys.argv[2])
payload["session_health"] = json.loads(sys.argv[3])
payload["session_source"] = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
    return 0
  fi

  while IFS=$'\t' read -r row_agent description engine source session session_id workdir profile_home profile_source active activity_state loop_mode continue_mode always_on idle_timeout wake_status notify_status channel_status channels notify_kind notify_target notify_account discord_channel_id isolation_mode os_user queue_queued queue_claimed queue_blocked actions admin; do
    [[ "$row_agent" == "agent" ]] && continue
    printf 'agent: %s\n' "$row_agent"
    printf 'description: %s\n' "$description"
    printf 'engine: %s\n' "$engine"
    printf 'source: %s\n' "$source"
    printf 'admin: %s\n' "$admin"
    printf 'session: %s\n' "$session"
    printf 'session_id: %s\n' "${session_id:--}"
    printf 'workdir: %s\n' "$workdir"
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

  # Issue #555: the rerender now writes the effective file at the
  # per-agent path ($BRIDGE_AGENT_HOME_ROOT/<agent>/.claude/
  # settings.effective.json). The plan/diff helper must compare the
  # workdir symlink against the same per-agent target it will be
  # relinked to — comparing against the install-wide path would
  # forever report `needs-rerender` after a successful apply.
  bridge_agent_manage_python \
    "$SCRIPT_DIR/bridge-hooks.py" \
    "$agent" \
    "$workdir" \
    "$(bridge_hook_shared_settings_base_file)" \
    "$(bridge_hook_shared_settings_overlay_file)" \
    "$(bridge_hook_per_agent_settings_effective_file "$agent")" \
    "$launch_cmd" \
    "$agent_class" <<'PY'
import importlib.util
import json
import os
import sys
from pathlib import Path

hooks_py, agent, workdir, base_file, overlay_file, effective_file, launch_cmd, agent_class = sys.argv[1:]
spec = importlib.util.spec_from_file_location("bridge_hooks", hooks_py)
if spec is None or spec.loader is None:
    raise SystemExit(f"could not load {hooks_py}")
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)

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
  for target in "${targets[@]}"; do
    agent="${target%%$'\t'*}"
    workdir="${target#*$'\t'}"
    before_json="$(bridge_agent_shared_settings_plan_json "$agent" "$workdir")"
    error=""
    if [[ $apply -eq 1 ]]; then
      # Issue #570: managed autoCompactWindow default is unconditionally
      # 1_000_000; launch_cmd is forwarded only for caller-signature parity
      # with helpers that still accept it (no longer consulted by the renderer).
      target_launch_cmd="$(bridge_agent_launch_cmd_raw "$agent" 2>/dev/null || true)"
      # Issue #555: forward agent id so the rerender writes to the
      # per-agent effective file ($BRIDGE_AGENT_HOME_ROOT/<agent>/.claude/
      # settings.effective.json). Mixed-model installs no longer fight
      # over a single install-wide file; each agent's autoCompactWindow
      # (and any future per-agent managed default) is independent.
      if apply_output="$(bridge_link_claude_settings_to_shared "$workdir" "$target_launch_cmd" "$agent" 2>&1)"; then
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
  local continue_mode=1
  local always_on=0
  local dry_run=0
  local json_mode=0
  local user_specs=()
  local users_json=""
  local default_home=""
  local start_dry_run=""
  # Issue #598 Track 4: opt-in for test-artifact-prefix names.
  local test_fixture=0

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
        loop_mode=1
        shift
        ;;
      --always-on)
        always_on=1
        shift
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
      *)
        bridge_die "지원하지 않는 agent create 옵션입니다: $1"
        ;;
    esac
  done

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
      os_user="${os_user:-$(bridge_agent_default_os_user "$agent")}"
    fi
  fi

  default_home="$(bridge_expand_user_path "$default_home")"
  if [[ -z "$profile_home" && "$workdir" != "$default_home" ]]; then
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
      else
        bridge_die "workdir가 이미 존재하고 비어 있지 않습니다: $workdir"
      fi
    fi
    bridge_scaffold_agent_home "$agent" "$workdir" "$display_name" "$role_text" "$engine" "$session_type"
    bridge_scaffold_user_partitions "$workdir" "$users_json"
    if [[ "$engine" == "claude" ]]; then
      bridge_ensure_project_claude_guidance "$workdir" >/dev/null 2>&1 || true
      bridge_ensure_auto_memory_isolation "$agent" "$workdir"
    fi
    bridge_bootstrap_project_skill "$engine" "$workdir" >/dev/null 2>&1 || true
    if [[ "$engine" == "claude" ]]; then
      bridge_bootstrap_claude_shared_skills "$agent" "$workdir" >/dev/null 2>&1 || true
      # Plan-D memory stack: ensure PreCompact hook at scaffold time so new
      # agents come up fully wired without a separate bootstrap pass.
      bridge_ensure_memory_precompact_hook "$agent" "$workdir" >/dev/null 2>&1 || true
    fi
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
      "$os_user" >/dev/null
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
    fi
    start_dry_run="$("$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent" --dry-run 2>&1)"
  fi

  if [[ $json_mode -eq 1 ]]; then
    emit_create_json "$agent" "$engine" "$session" "$workdir" "$profile_home" "$launch_cmd" "$channels" "$BRIDGE_ROSTER_LOCAL_FILE" "$dry_run" "$users_json" "$session_type" "$isolation_mode" "$os_user"
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
  if [[ $dry_run -eq 1 ]]; then
    echo "dry_run: yes"
  else
    echo "create: ok"
    echo "start_dry_run: ok"
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
        # plugin:NAME@SPEC shape (codex r1 finding 3): the spec is appended
        # as an argv token to BRIDGE_AGENT_LAUNCH_CMD which bash -lc
        # executes downstream. Restrict NAME and SPEC to the same
        # `[A-Za-z0-9_.-]+` charset the existing roster fixtures and
        # bridge_qualify_channel_item assume.
        if [[ ! "$2" =~ ^plugin:[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$ ]]; then
          bridge_die "--launch-cmd-add-dev-channel 는 plugin:NAME@SPEC 형식이어야 합니다: $2"
        fi
        add_launch_cmd_op "add-dev-channel" "$2"
        shift 2
        ;;
      --launch-cmd-remove-dev-channel)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        if [[ ! "$2" =~ ^plugin:[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$ ]]; then
          bridge_die "--launch-cmd-remove-dev-channel 는 plugin:NAME@SPEC 형식이어야 합니다: $2"
        fi
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
        if [[ ! "$2" =~ ^plugin:[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$ ]]; then
          bridge_die "--channels-add 는 plugin:NAME@SPEC 형식이어야 합니다: $2"
        fi
        add_channels_op "channels-add" "$2"
        shift 2
        ;;
      --channels-remove)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        if [[ ! "$2" =~ ^plugin:[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$ ]]; then
          bridge_die "--channels-remove 는 plugin:NAME@SPEC 형식이어야 합니다: $2"
        fi
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
      -h|--help)
        usage
        return 0
        ;;
      *)
        bridge_die "지원하지 않는 agent update 옵션입니다: $1"
        ;;
    esac
  done

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

  # Capture the operation summary for the audit row (compact one-line
  # description of what the operator asked for).
  local operation_summary=""
  operation_summary="$(
    {
      printf '%s' "$launch_cmd_ops" | sed 's/\t/=/' | sed 's/^/launch:/'
      printf '%s' "$channels_ops" | sed 's/\t/=/' | sed 's/^/chan:/'
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
      "[]"
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

  local changed=0
  if [[ "$new_launch_cmd" != "$before_launch_cmd" || "$new_channels" != "$before_channels" ]]; then
    changed=1
  fi

  local after_sha=""
  if [[ $changed -eq 1 && $dry_run -eq 0 ]]; then
    # Reuse the existing managed-role block writer (lines ~571-710).
    # Pass every non-mutated field through unchanged so the rewritten
    # block matches `agent create`'s emission shape byte-for-byte except
    # for the LAUNCH_CMD / CHANNELS lines we are touching.
    local description engine session workdir profile_home discord_channel
    local notify_kind notify_target notify_account loop_mode continue_mode
    local idle_timeout always_on isolation_mode os_user
    description="$(bridge_agent_desc "$agent")"
    engine="$(bridge_agent_engine "$agent")"
    session="$(bridge_agent_session "$agent")"
    workdir="$(bridge_agent_workdir "$agent")"
    profile_home="$(bridge_agent_profile_home "$agent")"
    discord_channel="$(bridge_agent_discord_channel_id "$agent")"
    notify_kind="$(bridge_agent_notify_kind "$agent")"
    notify_target="$(bridge_agent_notify_target "$agent")"
    notify_account="$(bridge_agent_notify_account "$agent")"
    loop_mode="$(bridge_agent_loop "$agent")"
    continue_mode="$(bridge_agent_continue "$agent")"
    idle_timeout="$(bridge_agent_idle_timeout "$agent")"
    isolation_mode="$(bridge_agent_isolation_mode "$agent")"
    os_user="$(bridge_agent_os_user "$agent")"
    if [[ "$idle_timeout" == "0" ]]; then
      always_on=1
    else
      always_on=0
    fi
    bridge_write_role_block \
      "$agent" \
      "$description" \
      "$engine" \
      "$session" \
      "$workdir" \
      "$profile_home" \
      "$new_launch_cmd" \
      "$new_channels" \
      "$discord_channel" \
      "$notify_kind" \
      "$notify_target" \
      "$notify_account" \
      "$loop_mode" \
      "$continue_mode" \
      "$always_on" \
      "$isolation_mode" \
      "$os_user" \
      "1" >/dev/null
    after_sha="$(bridge_agent_update_file_sha256 "$roster_path")"
  else
    after_sha="$before_sha"
  fi

  local trigger_label="agent-update-apply"
  if [[ $dry_run -eq 1 ]]; then
    trigger_label="agent-update-dry-run"
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
    "$merged_actions_json"

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
      "$merged_actions_json"
    return 0
  fi

  printf 'agent: %s\n' "$agent"
  printf 'changed: %s\n' "$([[ $changed -eq 1 ]] && echo yes || echo no)"
  printf 'dry_run: %s\n' "$([[ $dry_run -eq 1 ]] && echo yes || echo no)"
  printf 'before_launch_cmd: %s\n' "$before_launch_cmd"
  printf 'after_launch_cmd: %s\n' "$new_launch_cmd"
  printf 'before_channels: %s\n' "$before_channels"
  printf 'after_channels: %s\n' "$new_channels"
  printf 'before_sha: %s\n' "$before_sha"
  printf 'after_sha: %s\n' "$after_sha"
}

# run_delete — issue #580 Track 1. Admin-only audited removal of a static
# managed-role block from agent-roster.local.sh. Trust model mirrors
# run_update (admin agent identity + operator-trusted source). Safety
# gates: refuse if agent missing, refuse self-delete of admin, refuse
# active session without --force, refuse open inbox tasks without
# --orphan-tasks. Optional --purge-home / --purge-crons cleanup.
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
      deny_reason="agent '$agent' has $open_count open inbox task(s) — pass --orphan-tasks to mark them blocked"
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
      AGENT="$agent" CALLER_SOURCE="$caller_source" OPEN_COUNT="$open_count" \
      ORPHAN_TASKS="$orphan_tasks" PURGE_HOME="$purge_home" PURGE_CRONS="$purge_crons" \
      python3 - <<'PY'
import json
import os

payload = {
    "agent": os.environ["AGENT"],
    "deleted": False,
    "dry_run": True,
    "purge_home": os.environ["PURGE_HOME"] == "1",
    "purge_crons": os.environ["PURGE_CRONS"] == "1",
    "orphan_tasks": os.environ["ORPHAN_TASKS"] == "1",
    "open_inbox_tasks": int(os.environ["OPEN_COUNT"] or 0),
    "caller_source": os.environ["CALLER_SOURCE"],
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
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
    local _orphan_err
    _orphan_err="$(mktemp -t agb-orphan-err.XXXXXX)"
    if ! python3 - "$BRIDGE_TASK_DB" "$agent" "agent retired via 'agent delete'" <<'PY' 2>"$_orphan_err"
import sqlite3
import sys
import time

db_path, agent, note = sys.argv[1], sys.argv[2], sys.argv[3]
now_ts = int(time.time())
conn = sqlite3.connect(db_path)
try:
    with conn:
        rows = conn.execute(
            """
            SELECT id FROM tasks
            WHERE assigned_to = ?
              AND status IN ('queued', 'claimed')
              AND title NOT LIKE '[cron-dispatch]%'
            """,
            (agent,),
        ).fetchall()
        for (task_id,) in rows:
            # `blocked` is an open status (bridge-queue.py:22), so leave
            # closed_ts untouched — only cancelled/done set it. Restrict
            # the UPDATE WHERE to the same queued/claimed set so already
            # blocked rows are not redundantly bumped (idempotent).
            conn.execute(
                """
                UPDATE tasks
                SET status = 'blocked', updated_ts = ?
                WHERE id = ?
                  AND status IN ('queued', 'claimed')
                  AND title NOT LIKE '[cron-dispatch]%'
                """,
                (now_ts, task_id),
            )
            conn.execute(
                """
                INSERT INTO task_events (
                  task_id, event_type, actor, created_ts, note_text,
                  note_path, from_agent, to_agent
                ) VALUES (?, 'blocked', 'agent-delete', ?, ?, NULL, NULL, ?)
                """,
                (task_id, now_ts, note, agent),
            )
finally:
    conn.close()
PY
    then
      local _orphan_err_text
      _orphan_err_text="$(cat "$_orphan_err" 2>/dev/null || true)"
      rm -f "$_orphan_err"
      bridge_die "agent delete: failed to mark inbox tasks blocked for '$agent'${_orphan_err_text:+ ($_orphan_err_text)}"
    fi
    rm -f "$_orphan_err"
  fi

  # Remove the managed-role block from the roster file. Same regex the
  # block writer in bridge_write_role_block uses, with re.sub("") to
  # excise instead of replace.
  bridge_agent_manage_python "$roster_path" "$agent" >/dev/null <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
agent = sys.argv[2]
text = path.read_text(encoding="utf-8")
begin = f"# BEGIN AGENT BRIDGE MANAGED ROLE: {agent}"
end = f"# END AGENT BRIDGE MANAGED ROLE: {agent}"
if begin not in text or end not in text:
    raise SystemExit(f"managed block not found for {agent}: {path}")
pattern = re.compile(
    rf"^# BEGIN AGENT BRIDGE MANAGED ROLE: {re.escape(agent)}\n.*?^# END AGENT BRIDGE MANAGED ROLE: {re.escape(agent)}\n?",
    flags=re.MULTILINE | re.DOTALL,
)
# Mirror bridge-agent.sh:717 — verify the regex matches before writing.
# subn returns (new_text, count); refuse to write unless exactly one
# managed block was excised.
new_text, count = pattern.subn("", text, count=1)
if count != 1:
    raise SystemExit(
        f"managed block not found or matched {count} times for {agent}: {path}"
    )
text = new_text
# Collapse the triple-newline left behind by block removal (cosmetic).
text = re.sub(r"\n{3,}", "\n\n", text)
path.write_text(text, encoding="utf-8")
print(path)
PY

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
    AGENT="$agent" CALLER_SOURCE="$caller_source" OPEN_COUNT="$open_count" \
    ORPHAN_TASKS="$orphan_tasks" PURGE_HOME="$purge_home" PURGE_CRONS="$purge_crons" \
    BEFORE_SHA="$before_sha" AFTER_SHA="$after_sha" \
    python3 - <<'PY'
import json
import os

payload = {
    "agent": os.environ["AGENT"],
    "deleted": True,
    "dry_run": False,
    "purge_home": os.environ["PURGE_HOME"] == "1",
    "purge_crons": os.environ["PURGE_CRONS"] == "1",
    "orphan_tasks": os.environ["ORPHAN_TASKS"] == "1",
    "open_inbox_tasks": int(os.environ["OPEN_COUNT"] or 0),
    "caller_source": os.environ["CALLER_SOURCE"],
    "before_sha": os.environ["BEFORE_SHA"],
    "after_sha": os.environ["AFTER_SHA"],
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
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

run_start() {
  local agent="${1:-}"
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

  shift || true
  [[ -n "$agent" ]] || bridge_die "Usage: $(basename "$0") restart <agent> [...]"
  bridge_require_agent "$agent"
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

  if bridge_tmux_session_exists "$session"; then
    bridge_kill_agent_session "$agent"
    bridge_refresh_runtime_state
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
      bridge_kill_agent_session "$agent" >/dev/null 2>&1 || true
      bridge_refresh_runtime_state
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
      --detail reason=already_forgotten >/dev/null 2>&1 || true
    printf 'agent: %s\n' "$agent"
    printf 'changed: no\n'
    printf 'reason: already_forgotten\n'
    printf 'active: %s\n' "$active"
    return 0
  fi

  bridge_audit_log daemon agent_session_forgotten "$agent" \
    --detail cleared_files="$cleared_csv" \
    --detail prior_id_hash="$prior_id_hash" \
    --detail active="$active" \
    --detail changed=yes >/dev/null 2>&1 || true

  printf 'agent: %s\n' "$agent"
  printf 'changed: yes\n'
  printf 'cleared_files: %s\n' "${cleared_csv:--}"
  printf 'prior_id_hash: %s\n' "${prior_id_hash:--}"
  printf 'active: %s\n' "$active"
  if [[ "$active" == "yes" ]]; then
    bridge_warn "active=yes — running tmux session must be restarted fresh to pick up cleared id; suggested next: bridge-agent.sh restart $agent --no-continue"
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
      "create update delete list registry show reclassify rerender-settings start safe-mode stop restart ack-crash forget-session attach compact handoff")"
    [[ -n "$_hint" ]] && bridge_warn "$_hint"
    bridge_die "지원하지 않는 agent 명령입니다: $subcommand"
    ;;
esac
