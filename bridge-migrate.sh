#!/usr/bin/env bash
# bridge-migrate.sh — workspace migration planning helpers

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
# shellcheck source=lib/bridge-isolation-v2-migrate.sh
source "$SCRIPT_DIR/lib/bridge-isolation-v2-migrate.sh"
# shellcheck source=lib/bridge-isolation-v2-reapply.sh
source "$SCRIPT_DIR/lib/bridge-isolation-v2-reapply.sh"
bridge_load_roster

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-migrate.sh runtime inventory [--json] [--report <path>]
  bash $SCRIPT_DIR/bridge-migrate.sh runtime sync [--dry-run]
  bash $SCRIPT_DIR/bridge-migrate.sh runtime canonicalize [--dry-run] [--runtime-root <path>]
  bash $SCRIPT_DIR/bridge-migrate.sh runtime rewrite-cron [--dry-run] [--json]
  bash $SCRIPT_DIR/bridge-migrate.sh runtime rewrite-files [--dry-run] [--json]
  bash $SCRIPT_DIR/bridge-migrate.sh docs audit [--all] [agent...]
  bash $SCRIPT_DIR/bridge-migrate.sh docs apply [--all] [agent...] [--dry-run] [--report <path>]
  bash $SCRIPT_DIR/bridge-migrate.sh workspace plan <agent>
  bash $SCRIPT_DIR/bridge-migrate.sh workspace copy <agent> [--dry-run]
  bash $SCRIPT_DIR/bridge-migrate.sh workspace cutover <agent> --dry-run
  bash $SCRIPT_DIR/bridge-migrate.sh overhead pre-migrate [--output <file>] [--json]
  bash $SCRIPT_DIR/bridge-migrate.sh overhead dry-run [--agent <name>|--all] [--json]
  bash $SCRIPT_DIR/bridge-migrate.sh isolation-v2 dry-run --data-root <path>
  bash $SCRIPT_DIR/bridge-migrate.sh isolation-v2 apply   --data-root <path> --yes
  bash $SCRIPT_DIR/bridge-migrate.sh isolation-v2 rollback --yes
  bash $SCRIPT_DIR/bridge-migrate.sh isolation-v2 commit  --yes
  bash $SCRIPT_DIR/bridge-migrate.sh isolation-v2 status
  bash $SCRIPT_DIR/bridge-migrate.sh isolation v2 [--check|--dry-run|--apply] [--agent <name>] [--json]
  bash $SCRIPT_DIR/bridge-migrate.sh overhead apply [--agent <name>|--all] --yes [--dry-run] [--json]
  bash $SCRIPT_DIR/bridge-migrate.sh overhead rollback --stamp <YYYYMMDD-HHMMSS-<pid>> [--json]
EOF
}

run_docs_helper() {
  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-docs.py" "$@"
}

run_runtime_helper() {
  bridge_require_python
  python3 "$SCRIPT_DIR/bridge-runtime-inventory.py" "$@"
}

runtime_count_files() {
  local path="$1"
  [[ -d "$path" ]] || {
    printf '0'
    return 0
  }
  find "$path" -type f | wc -l | tr -d ' '
}

runtime_copy_tree() {
  local source_root="$1"
  local target_root="$2"

  bridge_require_python
  python3 - "$source_root" "$target_root" <<'PY'
import os
import shutil
import sys
from pathlib import Path

src = Path(sys.argv[1]).expanduser()
dst = Path(sys.argv[2]).expanduser()
ignore_names = {".git", "__pycache__", ".DS_Store"}

def should_ignore_name(name: str) -> bool:
    if name in ignore_names:
        return True
    if name.endswith((".pyc", ".pyo", ".bak", ".orig", ".rej")):
        return True
    if ".bak-" in name:
        return True
    return False

def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)

def same_file(left: Path, right: Path) -> bool:
    try:
        return right.exists() and os.path.samefile(left, right)
    except OSError:
        return False

def copy_entry(source: Path, target: Path) -> None:
    if should_ignore_name(source.name):
        return
    if source.is_symlink():
        link_target = os.readlink(source)
        if target.is_symlink() and os.readlink(target) == link_target:
            return
        if target.exists() or target.is_symlink():
            remove_path(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(link_target)
        return
    if source.is_dir():
        target.mkdir(parents=True, exist_ok=True)
        for child in source.iterdir():
            copy_entry(child, target / child.name)
        return
    if same_file(source, target):
        return
    if target.exists() or target.is_symlink():
        remove_path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target, follow_symlinks=False)

dst.mkdir(parents=True, exist_ok=True)
for item in src.iterdir():
    copy_entry(item, dst / item.name)
PY
}

runtime_secure_private_tree() {
  local root="$1"
  local path=""

  [[ -e "$root" ]] || return 0
  if [[ -d "$root" ]]; then
    chmod 700 "$root"
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      if [[ -d "$path" ]]; then
        chmod 700 "$path"
      elif [[ -f "$path" ]]; then
        chmod 600 "$path"
      fi
    done < <(find "$root" -mindepth 1 \( -type d -o -type f \))
  elif [[ -f "$root" ]]; then
    chmod 600 "$root"
  fi
}

runtime_sync_one() {
  local label="$1"
  local source_root="$2"
  local target_root="$3"
  local backup_root="$4"
  local dry_run="$5"
  local source_files=0
  local target_files=0
  local target_parent=""

  [[ -e "$source_root" ]] || return 0

  if [[ -d "$source_root" ]]; then
    source_files="$(runtime_count_files "$source_root")"
  else
    source_files=1
  fi
  if [[ -d "$target_root" ]]; then
    target_files="$(runtime_count_files "$target_root")"
  elif [[ -e "$target_root" ]]; then
    target_files=1
  fi
  printf 'item[%s]: %s -> %s\n' "$label" "$source_root" "$target_root"
  printf '  source_files: %s\n' "$source_files"
  printf '  target_files_before: %s\n' "$target_files"

  if [[ "$dry_run" == "1" ]]; then
    if [[ -d "$source_root" ]]; then
      printf '  action: merge-copy (dry-run)\n'
    else
      printf '  action: copy-file (dry-run)\n'
    fi
    return 0
  fi

  target_parent="$(dirname "$target_root")"
  mkdir -p "$target_parent" "$backup_root"
  if [[ -e "$target_root" && ! -e "$backup_root/$label" ]]; then
    cp -RP "$target_root" "$backup_root/$label"
  fi
  if [[ -d "$source_root" ]]; then
    mkdir -p "$target_root"
    runtime_copy_tree "$source_root" "$target_root"
    if [[ "$label" == "credentials" || "$label" == "secrets" ]]; then
      runtime_secure_private_tree "$target_root"
    fi
    printf '  target_files_after: %s\n' "$(runtime_count_files "$target_root")"
  else
    cp -RP "$source_root" "$target_root"
    if [[ "$label" == "credentials" || "$label" == "secrets" ]]; then
      runtime_secure_private_tree "$target_root"
    fi
    printf '  target_files_after: 1\n'
  fi
}

runtime_ensure_legacy_config_link() {
  local runtime_root="$1"
  local backup_root="$2"
  local dry_run="$3"
  local canonical_config="$runtime_root/bridge-config.json"
  local legacy_config="$runtime_root/openclaw.json"

  [[ -e "$canonical_config" ]] || return 0

  printf 'compat[config-link]: %s -> %s\n' "$legacy_config" "$canonical_config"
  if [[ "$dry_run" == "1" ]]; then
    printf '  action: symlink (dry-run)\n'
    return 0
  fi

  mkdir -p "$backup_root"
  if [[ -L "$legacy_config" ]]; then
    local current_target
    current_target="$(readlink "$legacy_config" || true)"
    if [[ "$current_target" == "bridge-config.json" ]]; then
      printf '  action: already_linked\n'
      return 0
    fi
  fi

  if [[ -e "$legacy_config" && ! -e "$backup_root/config-legacy-link" ]]; then
    cp -RP "$legacy_config" "$backup_root/config-legacy-link"
  fi
  rm -rf "$legacy_config"
  ln -s "bridge-config.json" "$legacy_config"
  printf '  action: linked\n'
}

cmd_runtime_sync() {
  local dry_run=0
  local legacy_home="$BRIDGE_OPENCLAW_HOME"
  local runtime_root="$BRIDGE_RUNTIME_ROOT"
  local backup_root=""
  local stamp=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      --legacy-home)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        legacy_home="$2"
        shift 2
        ;;
      --runtime-root)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        runtime_root="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 runtime sync 옵션입니다: $1"
        ;;
    esac
  done

  stamp="$(date '+%Y%m%d-%H%M%S')"
  backup_root="$BRIDGE_STATE_DIR/runtime-sync/$stamp"

  printf 'mode: %s\n' "$([[ "$dry_run" == "1" ]] && printf 'dry-run' || printf 'sync')"
  printf 'legacy_home: %s\n' "$legacy_home"
  printf 'runtime_root: %s\n' "$runtime_root"
  printf 'backup_root: %s\n' "$backup_root"
  printf '\n'

  runtime_sync_one "scripts" "$legacy_home/scripts" "$runtime_root/scripts" "$backup_root" "$dry_run"
  runtime_sync_one "skills" "$legacy_home/skills" "$runtime_root/skills" "$backup_root" "$dry_run"
  runtime_sync_one "patches" "$legacy_home/patches" "$runtime_root/patches" "$backup_root" "$dry_run"
  runtime_sync_one "media" "$legacy_home/media" "$runtime_root/media" "$backup_root" "$dry_run"
  runtime_sync_one "assets" "$legacy_home/assets" "$runtime_root/assets" "$backup_root" "$dry_run"
  runtime_sync_one "vault" "$legacy_home/vault" "$runtime_root/vault" "$backup_root" "$dry_run"
  runtime_sync_one "extensions" "$legacy_home/extensions" "$runtime_root/extensions" "$backup_root" "$dry_run"
  runtime_sync_one "data" "$legacy_home/data" "$runtime_root/data" "$backup_root" "$dry_run"
  runtime_sync_one "shared-tools" "$legacy_home/shared/tools" "$runtime_root/shared/tools" "$backup_root" "$dry_run"
  runtime_sync_one "shared-references" "$legacy_home/shared/references" "$runtime_root/shared/references" "$backup_root" "$dry_run"
  runtime_sync_one "memory" "$legacy_home/memory" "$runtime_root/memory" "$backup_root" "$dry_run"
  runtime_sync_one "credentials" "$legacy_home/credentials" "$runtime_root/credentials" "$backup_root" "$dry_run"
  runtime_sync_one "secrets" "$legacy_home/secrets" "$runtime_root/secrets" "$backup_root" "$dry_run"
  runtime_sync_one "config" "$legacy_home/openclaw.json" "$runtime_root/bridge-config.json" "$backup_root" "$dry_run"
  runtime_ensure_legacy_config_link "$runtime_root" "$backup_root" "$dry_run"
}

cmd_runtime_canonicalize() {
  local dry_run=0
  local runtime_root="$BRIDGE_RUNTIME_ROOT"
  local template_root="$SCRIPT_DIR/runtime-templates"
  local rel=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=1
        shift
        ;;
      --runtime-root)
        [[ $# -lt 2 ]] && bridge_die "$1 뒤에 값을 지정하세요."
        runtime_root="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        bridge_die "지원하지 않는 runtime canonicalize 옵션입니다: $1"
        ;;
    esac
  done

  [[ -d "$template_root" ]] || bridge_die "runtime template root가 없습니다: $template_root"

  printf 'mode: %s\n' "$([[ "$dry_run" == "1" ]] && printf 'dry-run' || printf 'apply')"
  printf 'template_root: %s\n' "$template_root"
  printf 'runtime_root: %s\n' "$runtime_root"
  printf '\n'

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    printf 'overlay[%s]: %s -> %s\n' "$rel" "$template_root/$rel" "$runtime_root/$rel"
  done < <(cd "$template_root" && find . \( -type f -o -type l \) | sed 's#^\./##' | LC_ALL=C sort)

  if [[ "$dry_run" == "1" ]]; then
    return 0
  fi

  mkdir -p "$runtime_root"
  runtime_copy_tree "$template_root" "$runtime_root"
  runtime_secure_private_tree "$runtime_root/credentials"
  runtime_secure_private_tree "$runtime_root/secrets"
}

MIGRATE_AGENT=""
MIGRATE_CURRENT_WORKDIR=""
MIGRATE_EXPLICIT_PROFILE_HOME=""
MIGRATE_EFFECTIVE_PROFILE_HOME=""
MIGRATE_TARGET_HOME=""
MIGRATE_STATUS=""

resolve_workspace_context() {
  local agent="$1"

  bridge_require_agent "$agent"

  MIGRATE_AGENT="$agent"
  MIGRATE_CURRENT_WORKDIR="$(bridge_agent_workdir "$agent")"
  MIGRATE_EXPLICIT_PROFILE_HOME="$(bridge_agent_profile_home "$agent")"
  if [[ -n "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    MIGRATE_EFFECTIVE_PROFILE_HOME="$MIGRATE_EXPLICIT_PROFILE_HOME"
  else
    MIGRATE_EFFECTIVE_PROFILE_HOME="$(bridge_agent_default_profile_home "$agent")"
  fi
  MIGRATE_TARGET_HOME="$(bridge_agent_default_home "$agent")"
  MIGRATE_STATUS="already_standard"

  if [[ "$MIGRATE_CURRENT_WORKDIR" != "$MIGRATE_TARGET_HOME" || "$MIGRATE_EFFECTIVE_PROFILE_HOME" != "$MIGRATE_TARGET_HOME" ]]; then
    MIGRATE_STATUS="needs_migration"
  fi
}

backup_root_for() {
  local agent="$1"
  local stamp="$2"

  printf '%s/migrations/%s-%s' "$BRIDGE_STATE_DIR" "$agent" "$stamp"
}

path_kind() {
  local path="$1"

  if [[ -L "$path" ]]; then
    printf 'link'
  elif [[ -d "$path" ]]; then
    printf 'dir'
  elif [[ -e "$path" ]]; then
    printf 'file'
  else
    printf 'missing'
  fi
}

remove_path() {
  local path="$1"

  if [[ -L "$path" || -f "$path" ]]; then
    rm -f "$path"
    return 0
  fi
  if [[ -d "$path" ]]; then
    rm -rf "$path"
  fi
}

copy_roots_tsv() {
  if [[ -d "$MIGRATE_CURRENT_WORKDIR" && "$MIGRATE_CURRENT_WORKDIR" != "$MIGRATE_TARGET_HOME" ]]; then
    printf 'workdir\t%s\n' "$MIGRATE_CURRENT_WORKDIR"
  fi

  if [[ -n "$MIGRATE_EXPLICIT_PROFILE_HOME" && "$MIGRATE_EXPLICIT_PROFILE_HOME" != "$MIGRATE_CURRENT_WORKDIR" && "$MIGRATE_EXPLICIT_PROFILE_HOME" != "$MIGRATE_TARGET_HOME" && -d "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    printf 'profile_home\t%s\n' "$MIGRATE_EXPLICIT_PROFILE_HOME"
  fi
}

write_backup_manifest() {
  local backup_root="$1"
  local stamp="$2"

  mkdir -p "$backup_root"
  cat >"$backup_root/manifest.txt" <<EOF
agent=$MIGRATE_AGENT
timestamp=$stamp
current_workdir=$MIGRATE_CURRENT_WORKDIR
current_profile_home=$MIGRATE_EFFECTIVE_PROFILE_HOME
target_home=$MIGRATE_TARGET_HOME
status=$MIGRATE_STATUS
EOF
}

list_top_level_entries() {
  local dir="$1"
  local entry=""
  local name=""

  [[ -d "$dir" ]] || return 0

  shopt -s nullglob dotglob
  for entry in "$dir"/* "$dir"/.*; do
    [[ "$entry" == "$dir/." || "$entry" == "$dir/.." ]] && continue
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry")"
    printf '%s\n' "$name"
  done | LC_ALL=C sort -u
  shopt -u nullglob dotglob
}

classify_entry() {
  local name="$1"

  case "$name" in
    MEMORY.md|memory|compound|.discord|.openclaw|STATUS.md|WORKFLOW.md|HEARTBEAT.md|CLAUDE.md)
      printf 'preserve'
      ;;
    tmp|output|.cache|preview|previews)
      printf 'live_only'
      ;;
    *)
      printf 'other'
      ;;
  esac
}

print_entry_group() {
  local dir="$1"
  local label="$2"
  local wanted="$3"
  local name=""
  local printed=0

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$(classify_entry "$name")" != "$wanted" ]]; then
      continue
    fi
    if [[ $printed -eq 0 ]]; then
      printf '%s\n' "$label"
      printed=1
    fi
    printf '  - %s\n' "$name"
  done < <(list_top_level_entries "$dir")

  if [[ $printed -eq 0 ]]; then
    printf '%s\n' "$label"
    printf '  - (none)\n'
  fi
}

cmd_workspace_plan() {
  local agent="$1"
  resolve_workspace_context "$agent"

  printf 'agent: %s\n' "$MIGRATE_AGENT"
  printf 'engine: %s\n' "$(bridge_agent_engine "$agent")"
  printf 'status: %s\n' "$MIGRATE_STATUS"
  printf 'current_workdir: %s\n' "$MIGRATE_CURRENT_WORKDIR"
  printf 'current_profile_home: %s\n' "$MIGRATE_EFFECTIVE_PROFILE_HOME"
  printf 'target_home: %s\n' "$MIGRATE_TARGET_HOME"
  printf 'target_profile_home: %s\n' "$MIGRATE_TARGET_HOME"
  printf '\n'

  printf 'recommended_roster_changes:\n'
  if [[ "$MIGRATE_CURRENT_WORKDIR" == "$MIGRATE_TARGET_HOME" ]]; then
    printf '  - workdir already points at the standard home\n'
  else
    printf '  - BRIDGE_AGENT_WORKDIR["%s"]="$BRIDGE_AGENT_HOME_ROOT/%s"\n' "$agent" "$agent"
  fi
  if [[ -z "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    printf '  - BRIDGE_AGENT_PROFILE_HOME["%s"] is not set; default already resolves to target\n' "$agent"
  elif [[ "$MIGRATE_EXPLICIT_PROFILE_HOME" == "$MIGRATE_TARGET_HOME" ]]; then
    printf '  - unset '\''BRIDGE_AGENT_PROFILE_HOME[%s]'\'' to use the default standard home\n' "$agent"
  else
    printf '  - BRIDGE_AGENT_PROFILE_HOME["%s"]="$BRIDGE_AGENT_HOME_ROOT/%s" or unset the override after cutover\n' "$agent" "$agent"
  fi
  printf '\n'

  printf 'copy_sources:\n'
  if [[ -d "$MIGRATE_CURRENT_WORKDIR" ]]; then
    printf '  - workdir: %s\n' "$MIGRATE_CURRENT_WORKDIR"
  else
    printf '  - workdir: %s (missing)\n' "$MIGRATE_CURRENT_WORKDIR"
  fi
  if [[ -n "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    if [[ "$MIGRATE_EXPLICIT_PROFILE_HOME" == "$MIGRATE_CURRENT_WORKDIR" ]]; then
      printf '  - profile home is the same path as workdir\n'
    elif [[ -d "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
      printf '  - profile_home: %s\n' "$MIGRATE_EXPLICIT_PROFILE_HOME"
    else
      printf '  - profile_home: %s (missing)\n' "$MIGRATE_EXPLICIT_PROFILE_HOME"
    fi
  else
    printf '  - profile_home: (default target; no separate legacy override)\n'
  fi
  printf '\n'

  if [[ -d "$MIGRATE_CURRENT_WORKDIR" ]]; then
    printf 'workdir_inventory: %s\n' "$MIGRATE_CURRENT_WORKDIR"
    print_entry_group "$MIGRATE_CURRENT_WORKDIR" "preserve:" "preserve"
    print_entry_group "$MIGRATE_CURRENT_WORKDIR" "live_only:" "live_only"
    print_entry_group "$MIGRATE_CURRENT_WORKDIR" "other:" "other"
    printf '\n'
  fi

  if [[ -n "$MIGRATE_EXPLICIT_PROFILE_HOME" && "$MIGRATE_EXPLICIT_PROFILE_HOME" != "$MIGRATE_CURRENT_WORKDIR" && -d "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    printf 'profile_inventory: %s\n' "$MIGRATE_EXPLICIT_PROFILE_HOME"
    print_entry_group "$MIGRATE_EXPLICIT_PROFILE_HOME" "preserve:" "preserve"
    print_entry_group "$MIGRATE_EXPLICIT_PROFILE_HOME" "live_only:" "live_only"
    print_entry_group "$MIGRATE_EXPLICIT_PROFILE_HOME" "other:" "other"
    printf '\n'
  fi

  printf 'next_steps:\n'
  printf '  1. review this plan and confirm the target root is correct\n'
  printf '  2. copy live-home files into %s without deleting the source\n' "$MIGRATE_TARGET_HOME"
  printf '  3. switch roster paths to the standard home\n'
  printf '  4. deploy tracked profile material into the new live home\n'
}

copy_one_entry() {
  local source_root="$1"
  local name="$2"
  local target_root="$3"
  local backup_root="$4"
  local dry_run="$5"
  local src="$source_root/$name"
  local dst="$target_root/$name"
  local backup_path="$backup_root/target-before/$name"
  local src_kind=""
  local dst_kind=""

  [[ -e "$src" || -L "$src" ]] || return 0

  src_kind="$(path_kind "$src")"
  dst_kind="$(path_kind "$dst")"

  if [[ "$dry_run" == "1" ]]; then
    if [[ "$dst_kind" != "missing" ]]; then
      printf '  - backup existing %s -> %s\n' "$dst" "$backup_path"
    fi
    if [[ "$src_kind" == "dir" ]]; then
      printf '  - merge %s/. -> %s/\n' "$src" "$dst"
    else
      printf '  - copy %s -> %s\n' "$src" "$dst"
    fi
    return 0
  fi

  mkdir -p "$target_root" "$backup_root/target-before"
  if [[ "$dst_kind" != "missing" && ! -e "$backup_path" && ! -L "$backup_path" ]]; then
    mkdir -p "$(dirname "$backup_path")"
    cp -RP "$dst" "$backup_path"
  fi

  if [[ "$src_kind" == "dir" ]]; then
    if [[ "$dst_kind" != "missing" && "$dst_kind" != "dir" ]]; then
      remove_path "$dst"
    fi
    mkdir -p "$dst"
    cp -RP "$src/." "$dst/"
    return 0
  fi

  if [[ "$dst_kind" == "dir" ]]; then
    remove_path "$dst"
  fi
  mkdir -p "$(dirname "$dst")"
  cp -RP "$src" "$dst"
}

cmd_workspace_copy() {
  local agent="$1"
  local dry_run="${2:-0}"
  local stamp=""
  local backup_root=""
  local label=""
  local source_root=""
  local copied_count=0
  local seen_any=0
  local name=""

  resolve_workspace_context "$agent"

  stamp="$(date '+%Y%m%d-%H%M%S')"
  backup_root="$(backup_root_for "$agent" "$stamp")"

  printf 'agent: %s\n' "$MIGRATE_AGENT"
  printf 'mode: %s\n' "$([[ "$dry_run" == "1" ]] && printf 'dry-run' || printf 'copy')"
  printf 'status: %s\n' "$MIGRATE_STATUS"
  printf 'target_home: %s\n' "$MIGRATE_TARGET_HOME"
  printf 'backup_root: %s\n' "$backup_root"
  printf 'source_deleted: no\n'
  printf '\n'

  while IFS=$'\t' read -r label source_root; do
    [[ -n "$label" && -n "$source_root" ]] || continue
    seen_any=1
    printf 'source[%s]: %s\n' "$label" "$source_root"
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      copy_one_entry "$source_root" "$name" "$MIGRATE_TARGET_HOME" "$backup_root" "$dry_run"
      copied_count=$((copied_count + 1))
    done < <(list_top_level_entries "$source_root")
    printf '\n'
  done < <(copy_roots_tsv)

  if [[ $seen_any -eq 0 ]]; then
    printf 'actions:\n'
    printf '  - no legacy source directories need copying\n'
    return 0
  fi

  if [[ "$dry_run" == "0" ]]; then
    write_backup_manifest "$backup_root" "$stamp"
  fi

  printf 'summary:\n'
  printf '  - top_level_entries: %s\n' "$copied_count"
  if [[ "$dry_run" == "1" ]]; then
    printf '  - dry-run only; target was not modified\n'
  else
    printf '  - backup manifest: %s/manifest.txt\n' "$backup_root"
  fi
}

cmd_workspace_cutover() {
  local agent="$1"
  local dry_run="${2:-0}"
  local session=""
  local active="no"

  resolve_workspace_context "$agent"

  if [[ "$dry_run" != "1" ]]; then
    bridge_die "actual cutover is not implemented yet. Use --dry-run."
  fi

  session="$(bridge_agent_session "$agent")"
  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi

  printf 'agent: %s\n' "$MIGRATE_AGENT"
  printf 'mode: dry-run\n'
  printf 'engine: %s\n' "$(bridge_agent_engine "$agent")"
  printf 'session: %s\n' "$session"
  printf 'active: %s\n' "$active"
  printf 'current_workdir: %s\n' "$MIGRATE_CURRENT_WORKDIR"
  printf 'current_profile_home: %s\n' "$MIGRATE_EFFECTIVE_PROFILE_HOME"
  printf 'target_home: %s\n' "$MIGRATE_TARGET_HOME"
  printf '\n'

  printf 'cutover_steps:\n'
  printf '  1. inspect: agent-bridge migrate workspace plan %s\n' "$agent"
  printf '  2. stage data: agent-bridge migrate workspace copy %s\n' "$agent"
  if [[ "$MIGRATE_CURRENT_WORKDIR" == "$MIGRATE_TARGET_HOME" ]]; then
    printf '  3. roster workdir: already at standard home\n'
  else
    printf '  3. roster workdir: set BRIDGE_AGENT_WORKDIR["%s"]="$BRIDGE_AGENT_HOME_ROOT/%s"\n' "$agent" "$agent"
  fi
  if [[ -z "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    printf '  4. roster profile: no explicit override today; keep default or set BRIDGE_AGENT_PROFILE_HOME["%s"]="$BRIDGE_AGENT_HOME_ROOT/%s"\n' "$agent" "$agent"
  elif [[ "$MIGRATE_EXPLICIT_PROFILE_HOME" == "$MIGRATE_TARGET_HOME" ]]; then
    printf '  4. roster profile: already points at standard home; optional cleanup is unset BRIDGE_AGENT_PROFILE_HOME["%s"]\n' "$agent"
  else
    printf '  4. roster profile: set BRIDGE_AGENT_PROFILE_HOME["%s"]="$BRIDGE_AGENT_HOME_ROOT/%s" or unset after cutover\n' "$agent" "$agent"
  fi
  printf '  5. deploy tracked profile: agent-bridge profile deploy %s\n' "$agent"
  printf '  6. restart session: bash %s/bridge-start.sh %s --replace\n' "$BRIDGE_HOME" "$agent"
  printf '  7. sync daemon: bash %s/bridge-daemon.sh sync\n' "$BRIDGE_HOME"
  printf '\n'

  printf 'rollback:\n'
  printf '  - restore BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$MIGRATE_CURRENT_WORKDIR"
  if [[ -n "$MIGRATE_EXPLICIT_PROFILE_HOME" ]]; then
    printf '  - restore BRIDGE_AGENT_PROFILE_HOME["%s"]="%s"\n' "$agent" "$MIGRATE_EXPLICIT_PROFILE_HOME"
  else
    printf '  - remove any BRIDGE_AGENT_PROFILE_HOME["%s"] override that was added during cutover\n' "$agent"
  fi
  printf '  - restart from legacy path: bash %s/bridge-start.sh %s --replace\n' "$BRIDGE_HOME" "$agent"
}

subcommand="${1:-}"
shift || true

case "$subcommand" in
  runtime)
    action="${1:-}"
    shift || true
    case "$action" in
      inventory)
        run_runtime_helper inventory "$@"
        ;;
      sync)
        cmd_runtime_sync "$@"
        ;;
      canonicalize)
        cmd_runtime_canonicalize "$@"
        ;;
      rewrite-cron)
        run_runtime_helper rewrite-cron "$@"
        ;;
      rewrite-files)
        run_runtime_helper rewrite-files "$@"
        ;;
      ""|-h|--help|help)
        usage
        ;;
      *)
        bridge_die "지원하지 않는 migrate runtime 명령입니다: $action"
        ;;
    esac
    ;;
  docs)
    action="${1:-}"
    shift || true
    case "$action" in
      audit|apply)
        run_docs_helper "$action" "$@"
        ;;
      ""|-h|--help|help)
        usage
        ;;
      *)
        bridge_die "지원하지 않는 migrate docs 명령입니다: $action"
        ;;
    esac
    ;;
  overhead)
    bridge_require_python
    exec python3 "$SCRIPT_DIR/bridge-migrate.py" overhead "$@"
    ;;
  workspace)
    case "${1:-}" in
      plan)
        shift
        [[ $# -eq 1 ]] || bridge_die "Usage: bash $SCRIPT_DIR/bridge-migrate.sh workspace plan <agent>"
        cmd_workspace_plan "$1"
        ;;
      copy)
        shift
        dry_run=0
        agent=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --dry-run)
              dry_run=1
              shift
              ;;
            -*)
              bridge_die "알 수 없는 옵션: $1"
              ;;
            *)
              if [[ -n "$agent" ]]; then
                bridge_die "agent는 하나만 지정할 수 있습니다."
              fi
              agent="$1"
              shift
              ;;
          esac
        done
        [[ -n "$agent" ]] || bridge_die "Usage: bash $SCRIPT_DIR/bridge-migrate.sh workspace copy <agent> [--dry-run]"
        cmd_workspace_copy "$agent" "$dry_run"
        ;;
      cutover)
        shift
        dry_run=0
        agent=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --dry-run)
              dry_run=1
              shift
              ;;
            -*)
              bridge_die "알 수 없는 옵션: $1"
              ;;
            *)
              if [[ -n "$agent" ]]; then
                bridge_die "agent는 하나만 지정할 수 있습니다."
              fi
              agent="$1"
              shift
              ;;
          esac
        done
        [[ -n "$agent" ]] || bridge_die "Usage: bash $SCRIPT_DIR/bridge-migrate.sh workspace cutover <agent> --dry-run"
        cmd_workspace_cutover "$agent" "$dry_run"
        ;;
      ""|-h|--help|help)
        usage
        ;;
      *)
        bridge_die "지원하지 않는 migrate workspace 명령입니다: $1"
        ;;
    esac
    ;;
  isolation-v2)
    bridge_isolation_v2_migrate_cli "$@"
    ;;
  isolation)
    # `agent-bridge migrate isolation v2 ...` — repair tool for installs
    # that drifted from the canonical v2 contract during a v0.7 → v0.8
    # `agent-bridge upgrade --apply` chain (issue #737). Distinct from the
    # `isolation-v2` (hyphenated) initial-migration tool above.
    inner="${1:-}"
    shift || true
    case "$inner" in
      v2)
        bridge_isolation_v2_reapply_cli "$@"
        ;;
      ""|-h|--help|help)
        usage
        ;;
      *)
        bridge_die "지원하지 않는 migrate isolation 명령입니다: $inner (예: 'migrate isolation v2 --check')"
        ;;
    esac
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    bridge_die "지원하지 않는 migrate 명령입니다: $subcommand"
    ;;
esac
