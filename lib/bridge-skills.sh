#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2153

# Issue #800 regression follow-up: ``bridge_sync_claude_runtime_skills``
# resolved each skill symlink target via ``python3 - "$link" "$runtime" <<'PY'``
# heredoc-stdin — the bash heredoc_write deadlock class PR #801 closed for
# the daemon main loop. The body is two ``os.path.realpath`` calls plus an
# equality check, so we use Pattern B (``python3 -c "$SCRIPT"`` here-string)
# rather than promoting it to ``bridge-daemon-helpers.py``. ``bridge_with_timeout``
# (lib/bridge-state.sh) enforces a 5s ceiling — path resolution should be
# microseconds, the ceiling exists so a wedged filesystem (stuck NFS mount,
# stalled FUSE userspace) cannot freeze every skill sync pass.
_BRIDGE_SKILLS_REALPATH_MATCH_PY='
import os
import sys

link_path = os.path.realpath(sys.argv[1])
runtime_path = os.path.realpath(sys.argv[2])
print("1" if link_path == runtime_path else "0")
'

bridge_project_skill_dir_for() {
  local engine="$1"
  local workdir="$2"

  case "$engine" in
    codex)
      printf '%s/.agents/skills/agent-bridge' "$workdir"
      ;;
    claude)
      printf '%s/.claude/skills/agent-bridge' "$workdir"
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_shared_claude_skill_source_dir() {
  local skill_name="$1"
  local home_path="$BRIDGE_HOME/.claude/skills/$skill_name"
  local repo_path="$BRIDGE_SCRIPT_DIR/.claude/skills/$skill_name"

  if [[ -d "$home_path" ]]; then
    printf '%s' "$home_path"
    return 0
  fi

  printf '%s' "$repo_path"
}

bridge_agent_claude_skill_link_dir() {
  local workdir="$1"
  local skill_name="$2"
  printf '%s/.claude/skills/%s' "$workdir" "$skill_name"
}

bridge_is_shared_claude_skill_name() {
  local skill_name="$1"
  case "$skill_name" in
    agent-bridge-runtime|cron-manager|memory-wiki)
      return 0
      ;;
  esac
  return 1
}

bridge_runtime_claude_skill_source_dir() {
  local skill_name="$1"
  local runtime_path="$BRIDGE_RUNTIME_SKILLS_DIR/$skill_name"
  [[ -d "$runtime_path" ]] || return 1
  printf '%s' "$runtime_path"
}

bridge_link_claude_skill_dir() {
  local source_dir="$1"
  local link_dir="$2"

  bridge_require_python
  python3 - "$source_dir" "$link_dir" <<'PY'
import os
import shutil
import sys
from datetime import datetime
from pathlib import Path

source_dir = Path(sys.argv[1]).expanduser()
link_dir = Path(sys.argv[2]).expanduser()
link_dir.parent.mkdir(parents=True, exist_ok=True)

if link_dir.is_symlink():
    if os.path.realpath(link_dir) == os.path.realpath(source_dir):
        raise SystemExit(0)
    link_dir.unlink()
elif link_dir.exists():
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = link_dir.with_name(f"{link_dir.name}.agent-bridge.bak-{stamp}")
    shutil.move(str(link_dir), str(backup))

rel_target = os.path.relpath(source_dir, start=link_dir.parent)
link_dir.symlink_to(rel_target, target_is_directory=True)
PY
}

bridge_link_shared_claude_skill() {
  local workdir="$1"
  local skill_name="$2"
  local source_dir=""
  local link_dir=""

  [[ "$(bridge_path_is_within_root "$workdir" "$BRIDGE_AGENT_HOME_ROOT")" == "1" ]] || return 0

  source_dir="$(bridge_shared_claude_skill_source_dir "$skill_name")"
  [[ -d "$source_dir" ]] || return 0
  link_dir="$(bridge_agent_claude_skill_link_dir "$workdir" "$skill_name")"
  bridge_link_claude_skill_dir "$source_dir" "$link_dir"
}

bridge_sync_claude_runtime_skills() {
  local agent="$1"
  local workdir="$2"
  local dry_run="${3:-0}"
  local configured=""
  local skill=""
  local skills_dir=""
  local existing=""
  local target=""
  local source_dir=""
  local runtime_target=""
  local found=0
  local configured_skill=""

  [[ "$(bridge_path_is_within_root "$workdir" "$BRIDGE_AGENT_HOME_ROOT")" == "1" ]] || return 0
  skills_dir="$workdir/.claude/skills"
  mkdir -p "$skills_dir"

  configured="$(bridge_agent_skills_csv "$agent")"

  shopt -s nullglob
  for existing in "$skills_dir"/*; do
    [[ -L "$existing" ]] || continue
    skill="$(basename "$existing")"
    bridge_is_shared_claude_skill_name "$skill" && continue
    runtime_target="$(bridge_runtime_claude_skill_source_dir "$skill" || true)"
    [[ -n "$runtime_target" ]] || continue
    # Pattern B per PR #801 / #800 follow-up: ``python3 -c "$SCRIPT"`` here-
    # string + ``bridge_with_timeout``. The previous heredoc-stdin form was
    # the deadlock class documented in #800. ``bridge_with_timeout`` is
    # defined in lib/bridge-state.sh (sourced AFTER this module in
    # bridge-lib.sh); bash resolves the function name at call time so the
    # ordering is safe — same convention as ``bridge_tmux_send_keys_with_timeout``.
    target="$(bridge_with_timeout 5 skills_resolve_target python3 -c "$_BRIDGE_SKILLS_REALPATH_MATCH_PY" "$existing" "$runtime_target" 2>/dev/null || true)"
    [[ "$target" == "1" ]] || continue
    found=0
    for configured_skill in $configured; do
      if [[ "$configured_skill" == "$skill" ]]; then
        found=1
        break
      fi
    done
    (( found == 1 )) && continue
    if [[ "$dry_run" != "1" ]]; then
      rm -f "$existing"
    fi
  done
  shopt -u nullglob

  for skill in $configured; do
    [[ "$skill" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    bridge_is_shared_claude_skill_name "$skill" && continue
    source_dir="$(bridge_runtime_claude_skill_source_dir "$skill" || true)"
    if [[ -z "$source_dir" ]]; then
      bridge_warn "runtime skill '$skill' is configured for '$agent' but missing under $BRIDGE_RUNTIME_SKILLS_DIR"
      continue
    fi
    if [[ "$dry_run" == "1" ]]; then
      continue
    fi
    bridge_link_claude_skill_dir "$source_dir" "$(bridge_agent_claude_skill_link_dir "$workdir" "$skill")"
  done
}

bridge_bootstrap_claude_shared_skills() {
  local agent=""
  local workdir=""

  if [[ $# -ge 2 ]]; then
    agent="$1"
    workdir="$2"
  else
    workdir="$1"
  fi

  bridge_link_shared_claude_skill "$workdir" "agent-bridge-runtime"
  bridge_link_shared_claude_skill "$workdir" "cron-manager"
  bridge_link_shared_claude_skill "$workdir" "memory-wiki"
  # v0.8.6: wave-orchestration is the shared parallel-PR-ship pattern
  # (issue-fixer dispatch into worktrees, codex-rescue review, squash-
  # merge with structured notes). Distribute to every Agent Bridge agent
  # so admin / dynamic / static agents all share the same orchestration
  # spine — operators do not need to copy the skill into per-agent
  # `.claude/skills/` manually.
  bridge_link_shared_claude_skill "$workdir" "wave-orchestration"

  if [[ -n "$agent" ]]; then
    bridge_sync_claude_runtime_skills "$agent" "$workdir"
    # Issue #544 PR3 — isolated agents read ~/.claude/skills/ from the
    # isolated UID's HOME, not from $workdir. The workdir symlinks above
    # serve shared agents only; isolated agents need a parallel rendered
    # copy under the isolated HOME with `~/.agent-bridge/` rewritten to
    # the absolute BRIDGE_HOME path so skill commands resolve regardless
    # of how `~` resolves under the isolated UID. Best-effort: silently
    # skips non-isolated agents and never blocks the start path.
    bridge_sync_isolated_home_claude_skills "$agent" >/dev/null 2>&1 || true
  fi
}

# Issue #544 PR3 — list of bridge-native skills that must be present in an
# isolated agent's HOME `.claude/skills/` directory. This is the parallel
# of the workdir symlink set installed by `bridge_bootstrap_claude_shared_skills`,
# extended with `patch-permission-approval` so admin agents under isolation
# also get the escalation runbook. New shared skills should be added here.
bridge_isolated_home_shared_skill_names() {
  printf '%s\n' \
    "agent-bridge-runtime" \
    "cron-manager" \
    "memory-wiki" \
    "patch-permission-approval" \
    "wave-orchestration"
}

# Render one skill text file from the controller-side source into the
# isolated home copy, substituting `~/.agent-bridge/` with the absolute
# BRIDGE_HOME path so the skill body's `agb` / `agent-bridge` commands
# resolve under the isolated UID regardless of how `~` resolves there.
# Atomic install via temp file + replace.
bridge_render_skill_file_for_isolated() {
  local source_file="$1"
  local target_file="$2"
  local bridge_home_resolved="$3"

  bridge_require_python
  python3 - "$source_file" "$target_file" "$bridge_home_resolved" <<'PY'
import os
import sys

src, dst, home = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, "r", encoding="utf-8") as fh:
    content = fh.read()
# Canonicalize BRIDGE_HOME so that trailing-slash, doubled-slash, and
# symlinked variants of the same logical path all produce identical
# rendered output. realpath resolves symlinks (so a fixture pointing
# BRIDGE_HOME at a symlink renders the underlying real path), normpath
# collapses double slashes, and the trailing-slash strip + re-append
# produces an exact `<canonical>/` substitution string.
home_canonical = os.path.realpath(os.path.normpath(home))
home_norm = home_canonical.rstrip("/") + "/"
content = content.replace("~/.agent-bridge/", home_norm)
tmp = dst + ".tmp"
os.makedirs(os.path.dirname(dst), exist_ok=True)
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(content)
os.replace(tmp, dst)
PY
}

# Decide whether a file under a skill directory is a UTF-8 text file the
# renderer should rewrite, or an opaque binary that should be copied
# verbatim. Heuristic: try to decode as UTF-8; on failure treat as binary.
# Returns 0 (text) or 1 (binary).
bridge_skill_file_is_text() {
  local path="$1"
  bridge_require_python
  python3 - "$path" <<'PY'
import sys
try:
    with open(sys.argv[1], "rb") as fh:
        chunk = fh.read(8192)
    if b"\x00" in chunk:
        sys.exit(1)
    chunk.decode("utf-8")
    sys.exit(0)
except (OSError, UnicodeDecodeError):
    sys.exit(1)
PY
}

# Sync the bridge-native skill set into the isolated UID's HOME
# `.claude/skills/<skill>/` so Claude Code can discover them under the
# isolated UID. No-op for non-isolated agents.
#
# Path text in SKILL.md (and other UTF-8 text files) is normalized:
# `~/.agent-bridge/` → `${BRIDGE_HOME}/` (absolute) so the skill body's
# `agb` / `agent-bridge` references resolve correctly under the isolated
# UID regardless of `~` semantics or per-home symlink presence.
#
# Best-effort: returns 0 silently when the agent is not isolated, when
# the controller cannot sudo to root, when sources are missing, or when
# any individual skill fails to render. Failures inside the loop emit a
# warning but do not abort sibling skills or block the caller.
bridge_sync_isolated_home_claude_skills() {
  local agent="$1"
  local os_user=""
  local isolated_home=""
  local skills_root=""
  local skill_name=""
  local source_dir=""
  local target_dir=""
  local source_file=""
  local rel=""
  local target_file=""

  [[ -n "$agent" ]] || return 0

  # Predicate is fatal-on-zero for non-isolated agents; suppress so this
  # remains a silent no-op when called unconditionally from the start path.
  bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null || return 0

  os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
  [[ -n "$os_user" ]] || return 0
  isolated_home="$(bridge_agent_linux_user_home "$os_user" 2>/dev/null || true)"
  [[ -n "$isolated_home" ]] || return 0

  skills_root="$isolated_home/.claude/skills"

  # Ensure the skills root exists with isolated-UID ownership. The parent
  # `.claude` may already be owned by the isolated UID; mkdir -p as root
  # is the safe primitive (sudo wrap matches every other isolated-home
  # mutation in lib/bridge-agents.sh).
  bridge_linux_sudo_root mkdir -p "$skills_root" 2>/dev/null || {
    bridge_warn "isolated skills sync: cannot mkdir $skills_root for $agent (sudo unavailable?)"
    return 0
  }
  bridge_linux_sudo_root chown "$os_user:$os_user" "$skills_root" 2>/dev/null || true
  bridge_linux_sudo_root chmod 0755 "$skills_root" 2>/dev/null || true

  while IFS= read -r skill_name; do
    [[ -n "$skill_name" ]] || continue
    source_dir="$(bridge_shared_claude_skill_source_dir "$skill_name")"
    if [[ ! -d "$source_dir" ]]; then
      bridge_warn "isolated skills sync: source missing for skill '$skill_name' (looked under $source_dir)"
      continue
    fi
    target_dir="$skills_root/$skill_name"
    bridge_linux_sudo_root mkdir -p "$target_dir" 2>/dev/null || {
      bridge_warn "isolated skills sync: cannot mkdir $target_dir"
      continue
    }

    # Walk every regular file under the source skill dir and either
    # render (text) or copy verbatim (binary). Preserve subdirectory
    # structure under references/ etc.
    while IFS= read -r -d '' source_file; do
      rel="${source_file#"$source_dir/"}"
      target_file="$target_dir/$rel"
      bridge_linux_sudo_root mkdir -p "$(dirname "$target_file")" 2>/dev/null || continue
      # Atomic install via tmp + mv -f inside the isolated tree so any
      # concurrent reader (e.g. an isolated agent already mid-launch)
      # never observes a truncated file. The renderer / source-copy
      # writes a controller-owned temp file, which is sudo-installed to
      # `${target_file}.tmp.$$` (same directory as the final target so
      # the rename stays within one filesystem), and only then renamed
      # over `$target_file`. `mv -f` on POSIX is an atomic rename within
      # a filesystem; if it fails the tmp sibling is removed so the
      # isolated tree never carries a stale `.tmp.$$` artifact. Mirrors
      # the controller-side os.replace pattern used by
      # bridge_render_skill_file_for_isolated.
      local _tmp_target="${target_file}.tmp.$$"
      if bridge_skill_file_is_text "$source_file" 2>/dev/null; then
        # Render to a controller-owned temp file, then sudo-stage into
        # the isolated tree's tmp sibling. Two-step is required because
        # the renderer writes as the controller UID.
        local _tmp_rendered=""
        _tmp_rendered="$(mktemp)" || continue
        if bridge_render_skill_file_for_isolated "$source_file" "$_tmp_rendered" "$BRIDGE_HOME"; then
          if bridge_linux_sudo_root install -m 0644 "$_tmp_rendered" "$_tmp_target" 2>/dev/null; then
            bridge_linux_sudo_root mv -f "$_tmp_target" "$target_file" 2>/dev/null || {
              bridge_linux_sudo_root rm -f "$_tmp_target" 2>/dev/null || true
              bridge_warn "isolated skills sync: atomic mv failed for $target_file"
            }
          else
            bridge_linux_sudo_root rm -f "$_tmp_target" 2>/dev/null || true
            bridge_warn "isolated skills sync: install failed for $target_file"
          fi
        else
          bridge_warn "isolated skills sync: render failed for $source_file"
        fi
        rm -f "$_tmp_rendered"
      else
        if bridge_linux_sudo_root install -m 0644 "$source_file" "$_tmp_target" 2>/dev/null; then
          bridge_linux_sudo_root mv -f "$_tmp_target" "$target_file" 2>/dev/null || {
            bridge_linux_sudo_root rm -f "$_tmp_target" 2>/dev/null || true
            bridge_warn "isolated skills sync: atomic mv failed for $target_file"
          }
        else
          bridge_linux_sudo_root rm -f "$_tmp_target" 2>/dev/null || true
          bridge_warn "isolated skills sync: copy failed for $target_file"
        fi
      fi
    done < <(find "$source_dir" -type f -print0 2>/dev/null)

    bridge_linux_sudo_root chown -R "$os_user:$os_user" "$target_dir" 2>/dev/null || true
  done < <(bridge_isolated_home_shared_skill_names)
}

bridge_agent_skills_registry_json() {
  local entry=()
  local agent=""

  for agent in "${!BRIDGE_AGENT_SKILLS[@]}"; do
    entry+=("$agent=${BRIDGE_AGENT_SKILLS[$agent]-}")
  done

  bridge_require_python
  python3 - "${entry[@]}" <<'PY'
import json
import sys

payload = {}
for raw in sys.argv[1:]:
    agent, _, skills = raw.partition("=")
    normalized = [item for item in skills.replace(",", " ").split() if item]
    if normalized:
        payload[agent] = normalized

print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
PY
}

bridge_agent_workdir_registry_json() {
  # Roster snapshot consumed by bridge-docs.py plugin-routing rendering
  # (issue #509 C1). One entry per claude-engine agent: agent → live
  # workdir. Codex agents are intentionally excluded; Claude Code's
  # plugin tree only attributes installs to claude-engine workdirs.
  local entries=()
  local agent="" engine="" workdir=""

  if declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1; then
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      engine="$(bridge_agent_engine "$agent" 2>/dev/null || true)"
      [[ "$engine" == "claude" ]] || continue
      workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
      [[ -n "$workdir" ]] || continue
      entries+=("$agent=$workdir")
    done
  fi

  bridge_require_python
  python3 - "${entries[@]+"${entries[@]}"}" <<'PY'
import json
import sys

payload = {}
for raw in sys.argv[1:]:
    agent, _, workdir = raw.partition("=")
    if agent and workdir:
        payload[agent] = workdir

print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
PY
}

bridge_sync_skill_docs() {
  local skills_json="" workdir_json=""

  # #946 L1 (r6 — codex P2): stale-source guard MUST run BEFORE any
  # `[[ -f "$BRIDGE_SCRIPT_DIR/..." ]]` early-return. When the source
  # checkout is gone, that file-existence check returns 0 (file is
  # absent) and we'd silently `return 0` as if everything were fine —
  # masking the cascade and skipping the [L1] audit. The guard:
  #   * stale dir → audit fires + return 1.
  #   * dir valid + bridge-docs.py absent (minimal install) → return 0.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  [[ -f "$BRIDGE_SCRIPT_DIR/bridge-docs.py" ]] || return 0
  bridge_require_python
  skills_json="$(bridge_agent_skills_registry_json)"
  workdir_json="$(bridge_agent_workdir_registry_json)"
  BRIDGE_AGENT_SKILLS_JSON="$skills_json" \
  BRIDGE_AGENT_WORKDIR_JSON="$workdir_json" \
    python3 "$BRIDGE_SCRIPT_DIR/bridge-docs.py" apply "$@" \
    --bridge-home "$BRIDGE_HOME" \
    --target-root "$BRIDGE_AGENT_HOME_ROOT" \
    --source-shared "$BRIDGE_OPENCLAW_HOME/shared" >/dev/null
}

bridge_is_managed_markdown() {
  local file="$1"
  grep -Fq "$BRIDGE_MANAGED_MARKER" "$file"
}

bridge_project_claude_file() {
  local workdir="$1"
  printf '%s/CLAUDE.md' "$workdir"
}

bridge_project_claude_marker_start() {
  printf '%s' "<!-- BEGIN AGENT BRIDGE PROJECT GUIDANCE -->"
}

bridge_project_claude_marker_end() {
  printf '%s' "<!-- END AGENT BRIDGE PROJECT GUIDANCE -->"
}

bridge_render_project_claude_guidance() {
  local bridge_home="$1"

  cat <<EOF
$(bridge_project_claude_marker_start)
<!-- ${BRIDGE_MANAGED_MARKER} -->
## Agent Bridge
- When a task involves bridge coordination, use the \`agent-bridge\` skill before improvising commands.
- Do not guess bridge commands. Use \`${bridge_home}/agb --help\`, \`${bridge_home}/agent-bridge --help\`, or the local bridge skill reference.
- Your sender id is your current bridge agent id. Prefer \`\$BRIDGE_AGENT_ID\`; if it is missing, verify the agent from \`${bridge_home}/state/active-roster.md\`.
- When you create or hand off work, set \`--from "\$BRIDGE_AGENT_ID"\` when running outside a bridge-managed wrapper.
- Queue state is source of truth. Use \`${bridge_home}/agb inbox|show|claim|done\` instead of direct sqlite access.
- Do not invent subcommands such as \`agb send\`. If you are unsure, check the bridge skill or CLI help first.
$(bridge_project_claude_marker_end)
EOF
}

bridge_project_claude_guidance_present() {
  local workdir="$1"
  local claude_file=""

  if [[ "$(bridge_path_is_within_root "$workdir" "$BRIDGE_AGENT_HOME_ROOT")" == "1" ]]; then
    return 0
  fi
  claude_file="$(bridge_project_claude_file "$workdir")"
  [[ -f "$claude_file" ]] || return 1
  grep -Fq "$(bridge_project_claude_marker_start)" "$claude_file"
}

bridge_project_claude_guidance_needed() {
  local workdir="$1"
  local claude_file=""

  if [[ "$(bridge_path_is_within_root "$workdir" "$BRIDGE_AGENT_HOME_ROOT")" == "1" ]]; then
    return 1
  fi
  claude_file="$(bridge_project_claude_file "$workdir")"
  [[ -f "$claude_file" ]] || return 1
  ! bridge_project_claude_guidance_present "$workdir"
}

bridge_ensure_project_claude_guidance() {
  local workdir="$1"
  local claude_file=""

  if [[ "$(bridge_path_is_within_root "$workdir" "$BRIDGE_AGENT_HOME_ROOT")" == "1" ]]; then
    return 0
  fi
  claude_file="$(bridge_project_claude_file "$workdir")"
  [[ -f "$claude_file" ]] || return 0

  bridge_require_python
  python3 - "$claude_file" "$BRIDGE_HOME" "$(bridge_project_claude_marker_start)" "$(bridge_project_claude_marker_end)" "$BRIDGE_MANAGED_MARKER" <<'PY'
from pathlib import Path
import re
import sys

claude_file = Path(sys.argv[1])
bridge_home = sys.argv[2]
marker_start = sys.argv[3]
marker_end = sys.argv[4]
managed_marker = sys.argv[5]

original = claude_file.read_text(encoding="utf-8")
block = f"""{marker_start}
<!-- {managed_marker} -->
## Agent Bridge
- When a task involves bridge coordination, use the `agent-bridge` skill before improvising commands.
- Do not guess bridge commands. Use `{bridge_home}/agb --help`, `{bridge_home}/agent-bridge --help`, or the local bridge skill reference.
- Your sender id is your current bridge agent id. Prefer `$BRIDGE_AGENT_ID`; if it is missing, verify the agent from `{bridge_home}/state/active-roster.md`.
- When you create or hand off work, set `--from "$BRIDGE_AGENT_ID"` when running outside a bridge-managed wrapper.
- Queue state is source of truth. Use `{bridge_home}/agb inbox|show|claim|done` instead of direct sqlite access.
- Do not invent subcommands such as `agb send`. If you are unsure, check the bridge skill or CLI help first.
{marker_end}"""

pattern = re.compile(rf"{re.escape(marker_start)}.*?{re.escape(marker_end)}\n*", re.S)
normalized = re.sub(pattern, "", original).rstrip()

if normalized.startswith("# "):
    first, rest = normalized.split("\n", 1) if "\n" in normalized else (normalized, "")
    updated = f"{first}\n\n{block}\n\n{rest.lstrip()}"
else:
    updated = f"{block}\n\n{normalized}\n" if normalized else f"{block}\n"

if updated != original:
    claude_file.write_text(updated, encoding="utf-8")
    print("updated")
else:
    print("unchanged")
PY
}

bridge_project_skill_file_for() {
  local engine="$1"
  local workdir="$2"
  local skill_dir=""

  skill_dir="$(bridge_project_skill_dir_for "$engine" "$workdir")" || return 1
  printf '%s/SKILL.md' "$skill_dir"
}

bridge_project_skill_bootstrap_needed() {
  local engine="$1"
  local workdir="$2"
  local skill_file=""

  skill_file="$(bridge_project_skill_file_for "$engine" "$workdir")" || return 1
  [[ -f "$skill_file" ]] && bridge_is_managed_markdown "$skill_file"
}

# bridge_render_project_bridge_reference — emit the per-project bridge skill
# reference Markdown.
#
# The curated intent-grouped sections (Roster / Start / Task Queue / Cron /
# Urgent / Stop / Share) are always emitted — they are the load-bearing surface
# the skill exposes during normal agent setup.
#
# Issue #828: the trailing "## Full Subcommand Reference" block is generated by
# invoking `agent-bridge --help` (via `bridge_cli_top_level_subcommands` +
# `bridge_cli_subcommand_help_summary`) and re-running every subcommand's help
# entry point. On dynamic agent start this re-enters the CLI stack that is
# trying to start the agent in the first place — recursive startup work, extra
# roster loading, daemon ensure/start checks, and (per #815 failure modes)
# easier wedges. We make that block opt-in:
#
#   BRIDGE_RENDER_SKILL_AUTO_HELP=1
#     Render the full auto-generated subcommand reference. Use this when you
#     are explicitly refreshing skill docs (e.g. a doc upgrade flow) and not
#     during normal start/attach.
#
#   Unset / "0" / anything else (default)
#     Skip the auto-generated block entirely. The curated reference above is
#     already operator-sufficient for normal coordination work.
bridge_render_project_bridge_reference() {
  local bridge_home="$1"

  cat <<EOF
# Agent Bridge Quick Reference

<!-- ${BRIDGE_MANAGED_MARKER} -->

Use this guide when a task involves tmux-based agent coordination through \`${bridge_home}\`.

## Roster

- Bridge dashboard: \`${bridge_home}/agent-bridge status\`
- Live dashboard watch mode: \`${bridge_home}/agent-bridge status --watch\`
- Active bridge agents with numeric indexes: \`${bridge_home}/agent-bridge list\`
- Agent inbox and claimed counts are included in \`agent-bridge list\`
- Static roster: \`bash ${bridge_home}/bridge-start.sh --list\`
- Live roster with active sessions: \`cat ${bridge_home}/state/active-roster.md\`
- Static definitions: \`cat ${bridge_home}/agent-roster.sh\`

## Start Or Resume Agents

- Start a rostered agent: \`bash ${bridge_home}/bridge-start.sh codex-developer\`
- Wake a rostered role through \`agent-bridge\` by using the static agent name directly: \`${bridge_home}/agent-bridge --codex --name codex-developer\`
- Start an ad hoc Codex agent from the current folder: \`${bridge_home}/agent-bridge --codex --name dev\`
- Start an ad hoc Claude agent from the current folder: \`${bridge_home}/agent-bridge --claude --name reviewer\`
- Create an isolated git worktree worker from the current folder: \`${bridge_home}/agent-bridge --codex --name reviewer-a --prefer new\`
- Trigger a predefined resume action: \`bash ${bridge_home}/bridge-action.sh tester resume --wait 5\`

## Task Queue

- Create a queued task: \`${bridge_home}/agent-bridge task create --to developer --title "재테스트" --body-file ${bridge_home}/shared/report.md\`
- Check an inbox: \`${bridge_home}/agent-bridge inbox developer\`
- Claim a task: \`${bridge_home}/agent-bridge claim 12 --agent developer\`
- Mark a task done: \`${bridge_home}/agent-bridge done 12 --agent developer --note "재현 불가"\`
- Hand off a task: \`${bridge_home}/agent-bridge handoff 12 --to tester --note "수정 반영 후 재확인 부탁"\`

## Cron

- Cron is documented in detail in the \`cron-manager\` skill (auto-linked into every static agent's skill set).
- List jobs for an agent: \`${bridge_home}/agent-bridge cron list --agent <agent>\`
- Inspect a job: \`${bridge_home}/agent-bridge cron show <job-name-or-id>\`
- Failed-run report (the answer to "show me cron history / cron logs / cron status" — those do not exist): \`${bridge_home}/agent-bridge cron errors report --agent <agent>\`
- Trigger a job ad-hoc: \`${bridge_home}/agent-bridge cron enqueue <job-name-or-id> --target <agent>\`
- Create / update / delete: see \`cron-manager\` skill or \`${bridge_home}/agent-bridge cron --help\`.

## Urgent Interrupts

- Send a direct urgent message only when interrupting is necessary: \`bash ${bridge_home}/bridge-send.sh --urgent developer "[TESTER] 프로덕션 장애 확인 필요" --wait 5\`
- List available slash-style actions: \`bash ${bridge_home}/bridge-action.sh --list tester\`
- Trigger a predefined action: \`bash ${bridge_home}/bridge-action.sh tester resume --wait 5\`

## Stop Sessions

- Kill one active bridge session by index: \`${bridge_home}/agent-bridge kill 1\`
- Kill every active bridge session managed by the current roster: \`${bridge_home}/agent-bridge kill all\`
- List managed worktrees: \`${bridge_home}/agent-bridge worktree list\`

## Share Larger Files

- Put long notes or QA reports in \`${bridge_home}/shared/\`
- Prefer task queue entries plus file paths over direct message pastes
- Runtime state under \`${bridge_home}/state/\` and logs under \`${bridge_home}/logs/\` are generated files and should not be hand-edited
EOF

  # Issue #283 Track A — root fix for skill staleness. The intent-grouped
  # sections above are still hand-curated narrative (they tell the reader
  # *which* command to reach for given an intent). The section below is the
  # complement: a flat enumeration of every Usage line `agent-bridge --help`
  # currently emits, so newly added subcommands cannot drift out of the skill
  # surface without a corresponding regeneration. If `agent-bridge` is missing
  # or its --help output is malformed, the helpers degrade to empty output
  # and we emit nothing — never an exit failure during skill regeneration.
  #
  # Issue #828: the auto-help block is gated behind
  # `BRIDGE_RENDER_SKILL_AUTO_HELP=1` so dynamic agent start does not recurse
  # into the top-level CLI help path. See the function docstring above and the
  # `bridge_render_project_bridge_auto_help_section` helper below.
  if [[ "${BRIDGE_RENDER_SKILL_AUTO_HELP:-0}" != "1" ]]; then
    return 0
  fi

  bridge_render_project_bridge_auto_help_section "$bridge_home"
}

# bridge_render_project_bridge_auto_help_section — emit the trailing
# "## Full Subcommand Reference" block by invoking the live CLI's `--help`
# surface via `bridge_cli_top_level_subcommands` and
# `bridge_cli_subcommand_help_summary`.
#
# Split out from `bridge_render_project_bridge_reference` (Issue #828) so the
# auto-help generation is independently callable / testable without paying
# the curated-reference heredoc cost on every invocation. The parent function
# only calls this helper when `BRIDGE_RENDER_SKILL_AUTO_HELP=1` — see the
# parent function's docstring for the full rationale.
#
# The CLI source-of-truth is the source-checkout binary
# (`$BRIDGE_SCRIPT_DIR/agent-bridge`) by default, not `${bridge_home}/agent-bridge` —
# the runtime path is a symlink back into the source checkout, so reading
# the source binary keeps the render reproducible from a fresh checkout
# before any live runtime has been linked. Callers can override the CLI
# location via `BRIDGE_CLI_NAME` (the helpers' default fallback). If
# `agent-bridge` is missing or its --help output is malformed, the helpers
# degrade to empty output and we emit nothing — never an exit failure
# during skill regeneration.
bridge_render_project_bridge_auto_help_section() {
  local bridge_home="$1"
  local auto_subcommand=""
  local auto_usage_line=""

  printf '\n## Full Subcommand Reference\n\n'
  printf '_Auto-generated from `agent-bridge --help` at agent setup time. If a command is missing here, run `%s/agent-bridge upgrade --restart-daemon` to refresh the runtime, then `%s/bridge-setup.sh` to regenerate the skill._\n' "$bridge_home" "$bridge_home"
  while IFS= read -r auto_subcommand; do
    [[ -n "$auto_subcommand" ]] || continue
    printf '\n### %s\n\n' "$auto_subcommand"
    while IFS= read -r auto_usage_line; do
      [[ -n "$auto_usage_line" ]] || continue
      printf -- '- `%s`\n' "$auto_usage_line"
    done < <(bridge_cli_subcommand_help_summary "$auto_subcommand")
  done < <(bridge_cli_top_level_subcommands)
}

bridge_render_codex_project_skill() {
  local bridge_home="$1"

  cat <<EOF
---
name: agent-bridge
description: Use when work needs tmux-based multi-agent coordination through \`${bridge_home}\`, including reading the roster, starting ad hoc workers with \`agent-bridge\`, sending messages between agents, triggering predefined actions, or sharing long reports through \`${bridge_home}/shared/\`.
---

<!-- ${BRIDGE_MANAGED_MARKER} -->

Use this skill when the task depends on the shared agent bridge in \`${bridge_home}\`.

## Workflow

1. Read the live roster in \`${bridge_home}/state/active-roster.md\` before coordinating with another agent.
2. Use \`bridge-start.sh\` for static roster entries and \`agent-bridge\` for ad hoc workers tied to the current folder.
3. If \`agent-bridge --name <agent>\` matches a static roster role, it wakes that role instead of creating a new dynamic worker.
4. If the current path belongs to a git project that already has dormant static roles, prefer \`agent-bridge --prefer new\` to create an isolated worktree worker rather than sharing the same checkout.
5. Use \`agent-bridge status\` for an at-a-glance dashboard, or \`agent-bridge status --watch\` for the live TUI.
6. Use the task queue first: \`agent-bridge task create\`, \`agent-bridge inbox\`, \`agent-bridge claim\`, \`agent-bridge done\`, and \`agent-bridge handoff\`.
7. Reserve \`bridge-send.sh --urgent\` for true interrupts and use \`bridge-action.sh\` only for predefined actions.
8. Store long reports in \`${bridge_home}/shared/\` and send only the path.

## Reference

- Load [references/bridge-commands.md](references/bridge-commands.md) for command patterns and examples.

## Guardrails

- Do not hardcode agent metadata into bridge scripts; static roster data belongs in \`${bridge_home}/agent-roster.sh\`.
- Prefer the live roster over guesswork when identifying active tmux sessions.
- Treat \`${bridge_home}/state/\` and \`${bridge_home}/logs/\` as generated runtime artifacts.
- Prefer queued tasks over direct messages so agents can pull work at task boundaries.
- \`agb\` is a compact dispatcher for the queue/inbox subset of \`agent-bridge\` (\`agb inbox|show|claim|done|summary|create\`). Everything else (status, list, cron, watchdog, audit, urgent, action, kill, worktree, ...) is on \`agent-bridge\`. There is no \`agb help\` or \`agb status\` — only \`agb --help\` (with the dashes).
EOF
}

bridge_render_claude_project_skill() {
  local bridge_home="$1"

  cat <<EOF
---
name: agent-bridge
description: Use PROACTIVELY when a task involves tmux-based multi-agent coordination through \`${bridge_home}\`, including roster lookup, inter-agent messaging, ad hoc worker startup with \`agent-bridge\`, predefined bridge actions, or shared handoff files.
---

<!-- ${BRIDGE_MANAGED_MARKER} -->

Use this skill when work depends on the shared agent bridge in \`${bridge_home}\`.

## Workflow

1. Inspect \`${bridge_home}/state/active-roster.md\` for active agents and session ids.
2. Use \`bridge-start.sh\` for static roster roles and \`agent-bridge\` for ad hoc workers in the current folder.
3. If \`agent-bridge --name <agent>\` matches a static roster role, it wakes that role instead of creating a new dynamic worker.
4. In git projects with dormant static roles, prefer \`agent-bridge --prefer new\` so concurrent workers use isolated worktrees instead of the shared checkout.
5. Use \`agent-bridge status\` for a one-shot dashboard or \`agent-bridge status --watch\` for the live TUI.
6. Use the queue first: \`agent-bridge task create\`, \`agent-bridge inbox\`, \`agent-bridge claim\`, \`agent-bridge done\`, and \`agent-bridge handoff\`.
7. Use \`bridge-send.sh --urgent\` only for interruptions that cannot wait for queue pickup, and use \`bridge-action.sh\` for predefined actions.
8. Put long notes in \`${bridge_home}/shared/\` and send the path instead of pasting large blocks.

## Reference

- Read [references/bridge-commands.md](references/bridge-commands.md) for examples and guardrails.

## Guardrails

- Do not edit generated runtime files under \`${bridge_home}/state/\` or \`${bridge_home}/logs/\`.
- Check the static roster in \`${bridge_home}/agent-roster.sh\` before assuming an agent name or action exists.
- Keep urgent interrupts short and move details into task queue entries or shared files.
- \`agb\` is a compact dispatcher for the queue/inbox subset of \`agent-bridge\` (\`agb inbox|show|claim|done|summary|create\`). Everything else (status, list, cron, watchdog, audit, urgent, action, kill, worktree, ...) is on \`agent-bridge\`. There is no \`agb help\` or \`agb status\` — only \`agb --help\` (with the dashes).
EOF
}

bridge_write_managed_markdown() {
  local file="$1"
  local label="$2"
  local tmp

  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp)"
  cat >"$tmp"

  if [[ -f "$file" ]] && ! bridge_is_managed_markdown "$file"; then
    bridge_warn "${label} already exists and is not managed by agent-bridge: $file"
    rm -f "$tmp"
    return 1
  fi

  if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$file"
  bridge_info "[info] ${label}: ${file}"
}

bridge_bootstrap_project_skill() {
  local engine="$1"
  local workdir="$2"
  local skill_dir skill_file reference_file
  local legacy_skill_dir=""

  if ! skill_dir="$(bridge_project_skill_dir_for "$engine" "$workdir")"; then
    return 0
  fi

  case "$engine" in
    codex)
      legacy_skill_dir="$workdir/.agents/skills/agent-bridge-project"
      ;;
    claude)
      legacy_skill_dir="$workdir/.claude/skills/agent-bridge-project"
      ;;
  esac

  skill_file="${skill_dir}/SKILL.md"
  reference_file="${skill_dir}/references/bridge-commands.md"

  case "$engine" in
    codex)
      bridge_render_codex_project_skill "$BRIDGE_HOME" | bridge_write_managed_markdown "$skill_file" "Codex bridge skill" || return 1
      ;;
    claude)
      bridge_render_claude_project_skill "$BRIDGE_HOME" | bridge_write_managed_markdown "$skill_file" "Claude bridge skill" || return 1
      ;;
    *)
      return 0
      ;;
  esac

  bridge_render_project_bridge_reference "$BRIDGE_HOME" | bridge_write_managed_markdown "$reference_file" "bridge reference" || return 1

  if [[ -n "$legacy_skill_dir" && -d "$legacy_skill_dir" && "$legacy_skill_dir" != "$skill_dir" ]]; then
    if [[ -f "$legacy_skill_dir/SKILL.md" ]] && bridge_is_managed_markdown "$legacy_skill_dir/SKILL.md"; then
      rm -rf "$legacy_skill_dir"
    fi
  fi
}
